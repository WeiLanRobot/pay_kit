import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Installed within the journal's atomic create/upgrade transaction.
Future<void> installAppleArbitrationSchema(DatabaseExecutor db) async {
  final columns = await db.rawQuery('PRAGMA table_info(purchase)');
  if (!columns.any((r) => r['name'] == 'disputeRevision')) {
    await db.execute(
        'ALTER TABLE purchase ADD COLUMN disputeRevision INTEGER NOT NULL DEFAULT 0');
  }
  for (final table in ['claim_fact', 'disposition_fact']) {
    await db.execute('''CREATE TABLE IF NOT EXISTS $table(
      purchaseId TEXT NOT NULL REFERENCES purchase(id), payload TEXT NOT NULL,
      scope TEXT NOT NULL, orderId TEXT NOT NULL, reference TEXT NOT NULL,
      covered INTEGER NOT NULL DEFAULT 0,
      ${table == 'disposition_fact' ? 'outcome TEXT NOT NULL, supersedes TEXT,' : ''}
      PRIMARY KEY(purchaseId,payload))''');
    await db.execute('CREATE INDEX IF NOT EXISTS ${table}_open_order '
        'ON $table(scope,orderId,purchaseId) WHERE covered=0');
  }
  await db.execute('''CREATE TABLE IF NOT EXISTS dispute_review(
    issuer TEXT NOT NULL, id TEXT NOT NULL, purchaseId TEXT NOT NULL REFERENCES purchase(id),
    payload TEXT NOT NULL, PRIMARY KEY(issuer,id))''');
  await db.execute('''CREATE TABLE IF NOT EXISTS detached_submission(
    purchaseId TEXT NOT NULL REFERENCES purchase(id), attemptId TEXT NOT NULL REFERENCES attempt(id),
    reference TEXT NOT NULL, PRIMARY KEY(purchaseId,attemptId))''');
  await db.execute('''CREATE TABLE IF NOT EXISTS purchase_amendment(
    purchaseId TEXT PRIMARY KEY REFERENCES purchase(id))''');
  final history = await db.query('purchase',
      where:
          'verifiedId IS NOT NULL AND (ackRef IS NOT NULL OR claimRef IS NOT NULL)');
  for (final p in history) {
    final identity = [
      p['appId'],
      p['environment'],
      p['scope'],
      p['orderId'],
      p['productId']
    ];
    final receipt = p['ackRef'], claim = p['claimRef'];
    final owner = {
      'purchaseId': p['id'],
      'scope': p['scope'],
      'orderId': p['orderId']
    };
    if (receipt != null && p['disposition'] != null) {
      await db.insert(
          'disposition_fact',
          {
            ...owner,
            'reference': receipt,
            'outcome': p['disposition'],
            'payload': jsonEncode([
              ...identity,
              1,
              p['reportedId'],
              p['verifiedId'],
              receipt,
              p['disposition'],
              null
            ])
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (claim != null) {
      await db.insert(
          'claim_fact',
          {
            ...owner,
            'reference': claim,
            'payload': jsonEncode([
              ...identity,
              p['reportedId'],
              p['verifiedId'],
              claim,
              p['token']
            ])
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
  await db.execute('DROP TRIGGER IF EXISTS purchase_identity');

  // Candidate ledgers stored historical recoveries as synthetic submissions.
  // Retain their rows for provenance, but no longer expose them as real attempts.
  final guard = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name='queue_identity'"))
      .firstOrNull;
  await db.execute('DROP TRIGGER IF EXISTS queue_identity');
  for (final table in ['purchase', 'queue_item']) {
    await db.execute(
        '''UPDATE $table SET attemptId=(SELECT submittedId FROM attempt a
      WHERE a.id=$table.attemptId) WHERE attemptId IN (SELECT id FROM attempt
      WHERE mode='scoped' AND wireToken IS NOT id COLLATE NOCASE)''');
  }
  if (guard != null) await db.execute(guard['sql'] as String);
  await installReviewedIdentityGuard(db);
}

/// Old reconciliation stored a second verified identity only as a generic
/// conflict. Restore its authenticated claim, including disputes previously
/// cleared by replay, before any queue observer can authorize new work.
/// The old format did not persist the attached disposition.
Future<void> restoreAppleIdentityDisputes(DatabaseExecutor db) async {
  final rows =
      await db.rawQuery("""SELECT p.*,f.evidenceRef FROM conflict_fact f
    JOIN purchase p ON p.id=f.purchaseId WHERE f.reason='claimMismatch'
    AND p.verifiedId IS NOT NULL""");
  for (final row in rows) {
    final payload = row['evidenceRef'] as String;
    final Object? claim;
    try {
      claim = jsonDecode(payload);
    } on FormatException {
      // Older records can hold opaque references instead of a recoverable claim.
      continue;
    }
    if (claim is! List ||
        claim.length != 9 ||
        claim[0] != row['appId'] ||
        claim[1] != row['environment'] ||
        claim[4] != row['productId'] ||
        claim[6] == row['verifiedId'] ||
        claim.take(8).any((v) => v is! String || v.trim().isEmpty)) {
      continue;
    }
    final id = row['id'];
    if (row['reportedId'] != claim[5] &&
        (await db.query('purchase_alias',
                columns: ['purchaseId'],
                where: 'purchaseId=? AND reportedId=?',
                whereArgs: [id, claim[5]]))
            .isEmpty) {
      continue;
    }
    final stored = await db.query('claim_fact',
        where: 'purchaseId=? AND payload=?', whereArgs: [id, payload]);
    if (stored.isNotEmpty && stored.single['covered'] == 1) continue;
    await db.insert(
        'claim_fact',
        {
          'purchaseId': id,
          'payload': payload,
          'scope': claim[2],
          'orderId': claim[3],
          'reference': claim[7]
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final indexed = await db.query('conflict_fact',
        columns: ['id'],
        where: 'purchaseId=? AND reason=? AND evidenceRef=?',
        whereArgs: [id, 'claimIdentityConflict', payload]);
    if (indexed.isNotEmpty) continue;
    await db.insert('conflict_fact', {
      'purchaseId': id,
      'reason': 'claimIdentityConflict',
      'evidenceRef': payload
    });
    await db.rawUpdate(
        """UPDATE purchase SET conflict=1,disputeRevision=disputeRevision+1,
      reason=CASE WHEN reason IS NULL OR reason='claimMismatch' THEN 'claimIdentityConflict' ELSE reason END WHERE id=?""",
        [id]);
  }
}

/// Existing v4 databases already have arbitration history and require only
/// the narrowed trigger change, without replaying the historical migration.
Future<void> installReviewedIdentityGuard(DatabaseExecutor db) async {
  await db.execute('DROP TRIGGER IF EXISTS purchase_identity');
  await db.execute('''CREATE TRIGGER purchase_identity BEFORE UPDATE ON purchase
    WHEN OLD.id IS NOT NEW.id OR OLD.productId IS NOT NEW.productId
      OR (OLD.appId IS NOT NULL AND OLD.appId IS NOT NEW.appId)
      OR (OLD.environment IS NOT NULL AND OLD.environment IS NOT NEW.environment)
      OR (OLD.reportedId IS NOT NULL AND OLD.reportedId IS NOT NEW.reportedId)
      OR (OLD.originalId IS NOT NULL AND OLD.originalId IS NOT NEW.originalId)
      OR (OLD.token IS NOT NULL AND OLD.token IS NOT NEW.token)
      OR (NOT EXISTS(SELECT 1 FROM purchase_amendment WHERE purchaseId=OLD.id) AND (
        (OLD.verifiedId IS NOT NULL AND OLD.verifiedId IS NOT NEW.verifiedId)
        OR (OLD.attemptId IS NOT NULL AND OLD.attemptId IS NOT NEW.attemptId)
        OR (OLD.scope IS NOT NULL AND OLD.scope IS NOT NEW.scope)
        OR (OLD.orderId IS NOT NULL AND OLD.orderId IS NOT NEW.orderId)
        OR (OLD.ackRef IS NOT NULL AND OLD.ackRef IS NOT NEW.ackRef)
        OR (OLD.claimRef IS NOT NULL AND OLD.claimRef IS NOT NEW.claimRef)
        OR (OLD.disposition IS NOT NULL AND OLD.disposition IS NOT NEW.disposition)))
    BEGIN SELECT RAISE(ABORT,'Conflicting Apple purchase binding'); END''');
}
