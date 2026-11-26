part of 'apple_payments.dart';

String? _present(String? value) =>
    value == null || value.isEmpty ? null : value;

// StoreKit may normalize the case of a UUID. Legacy arbitrary strings are opaque.
String? _wire(String? value) =>
    value != null && Uuid.isValidUUID(fromString: value)
        ? value.toLowerCase()
        : _present(value);

bool _requiresEnvironmentProof(Object? reason) =>
    reason == 'environmentMismatch' || reason == 'sourceUnproven';

bool _chargeOnHold(_Row? purchase) =>
    purchase?['conflict'] == 1 ||
    _requiresEnvironmentProof(purchase?['reason']);

bool _unpaidPhase(Object? value) =>
    const {'declined', 'failed', 'canceled'}.contains(value);
bool _activePhase(Object? value) => const {
      'prepared',
      'submitting',
      'accepted',
      'pending',
      'uncertain'
    }.contains(value);

Future<_Row?> _row(DatabaseExecutor db, String table, Object? id) async =>
    id == null
        ? null
        : (await db.query(table, where: 'id = ?', whereArgs: [id], limit: 1))
            .firstOrNull;

Future<_Row?> _attemptForToken(DatabaseExecutor db, String? token) async {
  if (token == null) return null;
  final comparison =
      Uuid.isValidUUID(fromString: token) ? ' COLLATE NOCASE' : '';
  return (await db.query('attempt',
          where:
              "wireToken = ?$comparison AND reason IS NOT 'legacyTokenPredatesSubmission' AND (mode='legacy' OR wireToken=id COLLATE NOCASE)",
          whereArgs: [token],
          limit: 1))
      .firstOrNull;
}

// A 1.2.0 business string can reappear after upgrading. A store event
// predating this native submission can never authorize the new receiver.
Future<_Row?> _observedAttempt(
    DatabaseExecutor db, String? rawToken, _Row? queue) async {
  final token = _wire(rawToken);
  final attempt = token == null
      ? await _row(db, 'attempt', queue?['attemptId'])
      : await _attemptForToken(db, token);
  if (attempt?['mode'] == 'legacy' && attempt?['phase'] == 'prepared') {
    await db.update('attempt',
        {'phase': 'declined', 'reason': 'legacyTokenPredatesSubmission'},
        where: 'id=?', whereArgs: [attempt!['id']]);
    return null;
  }
  return attempt;
}

Future<_Row?> _reportedPurchase(DatabaseExecutor db, String? reported) async {
  if (reported == null) return null;
  return (await db.rawQuery('''
    SELECT * FROM purchase WHERE id = (SELECT purchaseId FROM purchase_alias WHERE reportedId = ?)
    UNION ALL SELECT * FROM purchase WHERE reportedId = ? LIMIT 1
  ''', [reported, reported])).firstOrNull;
}

// A recovered legacy attempt has no account on its immutable submission row.
// Keep the authenticated account in the persisted decision or purchase that
// established it. All subsequent recovery messages must agree.
Future<bool> _legacyScopeAgrees(
    DatabaseExecutor db, String id, String scope) async {
  final other = await db.query('purchase',
      columns: ['id'],
      where: 'attemptId=? AND scope IS NOT NULL AND scope!=?',
      whereArgs: [id, scope],
      limit: 1);
  if (other.isNotEmpty) return false;
  final decisions = await db.query('decision',
      columns: ['payload'],
      where: 'attemptId=? AND result!=?',
      whereArgs: [id, 'conflict'],
      limit: 1);
  if (decisions.isEmpty) return true;
  final prior = jsonDecode(decisions.single['payload'] as String) as List;
  return prior[2] == scope;
}

Future<void> _reservePrimary(
        DatabaseExecutor db, String? scope, String order, String id) =>
    db.insert('order_primary',
        {'scope': scope ?? '', 'orderId': order, 'purchaseId': id},
        conflictAlgorithm: ConflictAlgorithm.ignore);

Future<void> _addEvidence(DatabaseExecutor db, String id, String receipt,
    {String source = 'store', String? context}) async {
  if (receipt.isEmpty) return;
  final hash = sha256.convert(utf8.encode(receipt)).toString();
  await db.insert('evidence', {'hash': hash, 'body': receipt},
      conflictAlgorithm: ConflictAlgorithm.ignore);
  context ??= (await db.query('meta', columns: ['environment']))
      .single['environment'] as String?;
  await db.insert('evidence_source',
      {'hash': hash, 'source': source, 'context': context ?? 'legacy'},
      conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert(
      'purchase_evidence',
      {
        'purchaseId': id,
        'hash': hash,
        'storeObserved': source == 'store' ? 1 : 0
      },
      conflictAlgorithm: ConflictAlgorithm.ignore);
  if (source == 'store') {
    await db.update('purchase_evidence', {'storeObserved': 1},
        where: 'purchaseId=? AND hash=? AND storeObserved=0',
        whereArgs: [id, hash]);
  }
}

// Redirects are flattened by the same transaction that moves the evidence.
Future<String> _canonicalPurchaseId(DatabaseExecutor db, String id) async {
  final redirect = await db.query('purchase_redirect',
      columns: ['purchaseId'], where: 'id=?', whereArgs: [id]);
  return redirect.firstOrNull?['purchaseId'] as String? ?? id;
}

Future<void> _conflict(DatabaseExecutor db, _Row? p, _Row? a, String reason,
    String reference) async {
  if (p != null) {
    await db.update('purchase', {'conflict': 1, 'reason': reason},
        where: 'id=?', whereArgs: [p['id']]);
  }
  if (a != null) {
    if (a['phase'] != 'conflict') {
      await db.insert(
          'conflict_fact',
          {
            'purchaseId': p?['id'],
            'attemptId': a['id'],
            'reason': 'previousAttemptPhase',
            'evidenceRef': jsonEncode([a['phase'], a['reason']]),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.update('attempt', {'phase': 'conflict', 'reason': reason},
        where: 'id=?', whereArgs: [a['id']]);
  }
  await db.insert(
      'conflict_fact',
      {
        'purchaseId': p?['id'],
        'attemptId': a?['id'],
        'reason': reason,
        'evidenceRef': reference
      },
      conflictAlgorithm: ConflictAlgorithm.ignore);
}

bool _disagrees(Object? first, Object? second) =>
    first != null && second != null && first != second;

Future<bool> _hasDispute(DatabaseExecutor db, _Row p) async =>
    p['conflict'] == 1 ||
    (await db.query('conflict_fact',
            columns: ['id'],
            where: 'purchaseId=?',
            whereArgs: [p['id']],
            limit: 1))
        .isNotEmpty;

// A negative payment result disputes delivery, not which Apple transaction
// this physical queue object identifies. Keep that dispute through the merge.
Future<bool> _canJoinQueueObservation(
    DatabaseExecutor db, _Row source, _Row target, String key) async {
  if (source['reportedId'] != null ||
      source['verifiedId'] != null ||
      source['disposition'] != null ||
      ['productId', 'scope', 'orderId', 'token', 'originalId']
          .any((field) => _disagrees(source[field], target[field]))) {
    return false;
  }
  return (await db
          .rawQuery('''SELECT 1 FROM queue_item WHERE purchaseId=? AND id!=?
        UNION ALL SELECT 1 FROM conflict_fact WHERE purchaseId=?
        AND reason NOT IN ('previousAttemptPhase','paymentAfterUnpaid','unpaidAfterPayment')
        LIMIT 1''', [source['id'], key, source['id']]))
      .isEmpty;
}

// All callers have proven the destination's identity before moving anything.
// Copy references before deleting them so the evidence GC retains the original bytes.
Future<void> _mergeEvidence(
    DatabaseExecutor db, _Row source, _Row target) async {
  final from = source['id'], to = target['id'];
  await db.update('purchase_redirect', {'purchaseId': to},
      where: 'purchaseId=?', whereArgs: [from]);
  await db.insert('purchase_redirect', {'id': from, 'purchaseId': to});
  await db.rawInsert(
      '''INSERT OR IGNORE INTO purchase_evidence(purchaseId,hash,storeObserved)
    SELECT ?,hash,storeObserved FROM purchase_evidence WHERE purchaseId=? ORDER BY seq''',
      [to, from]);
  await db.rawUpdate('''UPDATE purchase_evidence SET tried=0,rejected=0,
      storeObserved=max(storeObserved,EXISTS(SELECT 1 FROM purchase_evidence s
      WHERE s.purchaseId=? AND s.hash=purchase_evidence.hash AND s.storeObserved=1))
      WHERE purchaseId=?''', [from, to]);
  await db.rawUpdate(
      '''UPDATE purchase SET inputVersion=inputVersion+1,blockedLogin=NULL,
      reason=CASE WHEN conflict=0 AND reason IN
      ('needsReconciliation','invalidEvidence','verificationRetry') THEN NULL ELSE reason END
      WHERE id=?''', [to]);
  final facts = <String, Object?>{
    for (final field in [
      'scope',
      'orderId',
      'attemptId',
      'token',
      'originalId'
    ])
      if (target[field] == null && source[field] != null) field: source[field],
    if (source['conflict'] == 1) ...{
      'conflict': 1,
      if (target['conflict'] != 1) 'reason': source['reason'],
    }
  };
  if (facts.isNotEmpty) {
    await db
        .update('purchase', facts, where: 'id=?', whereArgs: [target['id']]);
  }
  if (source['conflict'] == 1 || await _hasDispute(db, source)) {
    // Keep the original local reference as provenance when re-indexing facts.
    final audit = await db.query('conflict_fact',
        where: 'purchaseId=?', whereArgs: [source['id']], orderBy: 'id');
    await db.insert(
        'conflict_fact',
        {
          'purchaseId': target['id'],
          'reason': 'mergedObservation',
          'evidenceRef':
              jsonEncode({'originalPurchase': source['id'], 'facts': audit})
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update('conflict_fact', {'purchaseId': target['id']},
        where: 'purchaseId=?',
        whereArgs: [source['id']],
        conflictAlgorithm: ConflictAlgorithm.ignore);
    // Only already-identical facts can have hit the deduplication constraint.
    await db.delete('conflict_fact',
        where: 'purchaseId=?', whereArgs: [source['id']]);
  }
  await db.update('order_primary', {'purchaseId': target['id']},
      where: 'purchaseId=?', whereArgs: [source['id']]);
  await db.update('queue_item', {'purchaseId': target['id']},
      where: 'purchaseId=?', whereArgs: [source['id']]);
  await db.delete('purchase_evidence',
      where: 'purchaseId=?', whereArgs: [source['id']]);
  await db.delete('purchase', where: 'id=?', whereArgs: [source['id']]);
}

// An adjudicated charge can close its positive/negative dispute. Other open
// charges, independent decision conflicts and the historical audit stay intact.
Future<void> _closeSettledAttempt(
    DatabaseExecutor db, String purchaseId) async {
  await db.rawUpdate('''UPDATE attempt SET phase='paid', reason=NULL
    WHERE id=(SELECT attemptId FROM purchase WHERE id=? AND verifiedId IS NOT NULL
              AND claimRef IS NOT NULL AND disposition IS NOT NULL AND conflict=0)
      AND phase='conflict' AND reason IN ('paymentAfterUnpaid','unpaidAfterPayment')
      AND NOT EXISTS(SELECT 1 FROM conflict_fact f LEFT JOIN purchase p ON p.id=f.purchaseId
        WHERE f.attemptId=attempt.id AND f.reason!='previousAttemptPhase'
          AND (f.reason NOT IN ('paymentAfterUnpaid','unpaidAfterPayment')
               OR p.claimRef IS NULL OR p.disposition IS NULL OR p.conflict=1))
      AND NOT EXISTS(SELECT 1 FROM purchase p WHERE p.attemptId=attempt.id AND p.conflict=1)''',
      [purchaseId]);
}

String _ackPayload(AppleDisposition a) => jsonEncode([
      a.appId,
      a.environment,
      a.scope,
      a.orderId,
      a.productId,
      a.quantity,
      a.reportedTransactionId,
      a.verifiedTransactionId,
      a.reference,
      a.outcome.name,
      a.supersedes
    ]);

String _claimPayload(AppleClaim c) => jsonEncode([
      c.appId,
      c.environment,
      c.scope,
      c.orderId,
      c.productId,
      c.reportedTransactionId,
      c.verifiedTransactionId,
      c.reference,
      _wire(c.purchaseToken)
    ]);

Future<void> _amend(
    DatabaseExecutor db, String id, Map<String, Object?> values) async {
  await db.insert('purchase_amendment', {'purchaseId': id});
  await db.update('purchase', values, where: 'id=?', whereArgs: [id]);
  await db.delete('purchase_amendment', where: 'purchaseId=?', whereArgs: [id]);
}

Future<bool> _saveDisposition(
    DatabaseExecutor db, _Row p, AppleDisposition ack) async {
  final payload = _ackPayload(ack);
  final existing = await db.query('disposition_fact',
      columns: ['payload'],
      where: 'purchaseId=? AND payload=?',
      whereArgs: [p['id'], payload]);
  if (existing.isNotEmpty) return false;
  await db.insert('disposition_fact', {
    'purchaseId': p['id'],
    'scope': ack.scope,
    'orderId': ack.orderId,
    'reference': ack.reference,
    'outcome': ack.outcome.name,
    'supersedes': ack.supersedes,
    'payload': payload
  });
  return true;
}

Future<void> _saveClaim(DatabaseExecutor db, _Row p, AppleClaim c) => db.insert(
    'claim_fact',
    {
      'purchaseId': p['id'],
      'scope': c.scope,
      'orderId': c.orderId,
      'reference': c.reference,
      'payload': _claimPayload(c)
    },
    conflictAlgorithm: ConflictAlgorithm.ignore);

Future<void> _openDispute(
    DatabaseExecutor db, _Row p, String reason, String evidence) async {
  final existing = await db.query('conflict_fact',
      columns: ['id'],
      where: 'purchaseId=? AND reason=? AND evidenceRef=?',
      whereArgs: [p['id'], reason, evidence]);
  if (existing.isNotEmpty) return;
  if (reason == 'environmentConflict') {
    await db.rawUpdate(
        "UPDATE recovery.observation SET reason=? WHERE originPurchase=? AND reason!='environmentRejected'",
        [reason, p['id']]);
  }
  await _conflict(db, p, null, reason, evidence);
  await db.rawUpdate(
      'UPDATE purchase SET disputeRevision=disputeRevision+1 WHERE id=?',
      [p['id']]);
}

String? _handleKey(StoreEvent event) {
  final handle = event.native;
  return handle is String && handle.isNotEmpty ? 'handle:$handle' : null;
}

extension _AppleDelivery on ApplePayments {
  Future<String> _queueKey(DatabaseExecutor db, StoreEvent e) async {
    final stable = _present(e.queueId);
    final handle = _handleKey(e);
    final alias = _handleAliases[handle];
    if (alias != null) return alias;
    if (stable != null) {
      final persisted = (await db.query('queue_item',
              columns: ['id'],
              where: 'storeQueueId=?',
              whereArgs: [stable],
              limit: 1))
          .firstOrNull;
      if (persisted != null) return persisted['id'] as String;
    }
    if (handle != null) {
      if (stable == null || await _row(db, 'queue_item', handle) != null) {
        return handle;
      }
    }
    if (stable != null) return 'queue:$stable';
    final transaction = _present(e.transactionId);
    if (transaction != null) return 'transaction:$transaction';
    return _observationIds[e] ??= 'observation:${const Uuid().v4()}';
  }

  Future<void> _ingest(StoreEvent e) async {
    if (!_ready || _closed) return;
    final tokenOnFailure = _wire(e.token);
    if ((e.status == StoreStatus.canceled || e.status == StoreStatus.failed) &&
        tokenOnFailure != null &&
        !_submittedHere.contains(tokenOnFailure) &&
        Uuid.isValidUUID(fromString: tokenOnFailure) &&
        await _processUnpaid(e, cold: true)) {
      return;
    }
    if (!await _routeObservation(e)) return;
    if (e.status != StoreStatus.paid) {
      await _processUnpaid(e);
      return;
    }
    final reported = _present(e.transactionId);
    final token = _wire(e.token);
    final id = await _journal.write((db) async {
      final key = await _queueKey(db, e);
      final savedQueue = await _row(db, 'queue_item', key);
      // The stable queue ID may already have arrived through another wrapper.
      // Inspect the exact handle's earlier evidence before choosing that row.
      final handle = _handleKey(e);
      final provisional = savedQueue?['storeQueueId'] != null && key != handle
          ? await _row(db, 'queue_item', handle)
          : null;
      final queue = provisional ?? savedQueue;
      final fromQueue = await _row(db, 'purchase', queue?['purchaseId']);
      final fromId = await _reportedPurchase(db, reported);
      final differentReport = queue?['reportedId'] != null &&
          reported != null &&
          queue?['reportedId'] != reported;
      var p = differentReport ? fromId : fromQueue ?? fromId;
      var a = await _observedAttempt(db, e.token, queue);
      if (p != null &&
          a != null &&
          (p['disputeRevision'] as int) > 0 &&
          (await db.query('detached_submission',
                  columns: ['reference'],
                  where: 'purchaseId=? AND attemptId=?',
                  whereArgs: [p['id'], a['id']]))
              .isNotEmpty) {
        a = null;
      }
      final rawFacts = <String, Object?>{
        'reportedId': reported,
        'originalId': _present(e.originalTransactionId),
        'productId': e.productId,
        'token': token
      };
      // A later update of the exact recorded queue item can identify its
      // provisional receipt with another observation naming the same purchase.
      final split = fromQueue != null &&
          fromId != null &&
          fromQueue['id'] != fromId['id'];
      final canJoin = split &&
          queue?['reportedId'] == null &&
          !_disagrees(fromQueue['token'], token) &&
          !_disagrees(fromQueue['originalId'], e.originalTransactionId) &&
          !_disagrees(fromQueue['attemptId'], a?['id']) &&
          await _canJoinQueueObservation(
              db, fromQueue, fromId, queue!['id'] as String);
      if (canJoin) p = fromId;
      final id = p?['id'] as String? ?? const Uuid().v4();
      final attemptMismatch =
          p != null && a != null && _disagrees(p['attemptId'], a['id']);
      final inconsistent = (split && !canJoin) ||
          (canJoin && _disagrees(fromQueue['attemptId'], p?['attemptId'])) ||
          (provisional != null && _disagrees(savedQueue?['purchaseId'], id)) ||
          [queue, if (provisional != null) savedQueue].whereType<_Row>().any(
              (item) =>
                  item['productId'] != e.productId ||
                  (item['finished'] == 1 && item['status'] != 'paid') ||
                  _disagrees(item['storeQueueId'], _present(e.queueId)) ||
                  _disagrees(item['reportedId'], reported) ||
                  _disagrees(item['originalId'], rawFacts['originalId']) ||
                  _disagrees(item['token'], token ?? queue?['token']) ||
                  _disagrees(item['attemptId'], a?['id'])) ||
          (p != null &&
              (p['productId'] != e.productId ||
                  _disagrees(p['token'], token) ||
                  _disagrees(p['originalId'], e.originalTransactionId) ||
                  attemptMismatch ||
                  _disagrees(p['scope'], a?['scope']) ||
                  _disagrees(p['orderId'], a?['orderId']))) ||
          (a != null && a['productId'] != e.productId);
      if (!inconsistent) {
        if (canJoin) {
          await _mergeEvidence(db, fromQueue, fromId);
          p = await _row(db, 'purchase', id);
        }
      }
      if (p == null) {
        await db.insert('purchase', {
          'id': id,
          ...rawFacts,
          if (a != null && a['productId'] == e.productId) ...{
            'attemptId': a['id'],
            'scope': a['scope'],
            'orderId': a['orderId']
          },
          if (reported == null) 'reason': 'missingTransactionId'
        });
      } else if (!inconsistent) {
        await db.update(
            'purchase',
            {
              if (p['reportedId'] == null &&
                  fromQueue != null &&
                  reported != null)
                'reportedId': reported,
              if (p['token'] == null && token != null) 'token': token,
              if (p['originalId'] == null && e.originalTransactionId != null)
                'originalId': e.originalTransactionId,
              if (p['attemptId'] == null && a != null) ...{
                'attemptId': a['id'],
                if (p['scope'] == null) 'scope': a['scope'],
                'orderId': a['orderId']
              },
              'reason':
                  p['reason'] == 'missingTransactionId' && reported != null
                      ? null
                      : p['reason'],
            },
            where: 'id=?',
            whereArgs: [id]);
      }

      if (savedQueue == null) {
        await db.insert('queue_item', {
          'id': key,
          ...rawFacts,
          'purchaseId': id,
          'status': 'paid',
          'storeQueueId': _present(e.queueId),
          'attemptId': inconsistent ? null : a?['id'] ?? p?['attemptId']
        });
      } else if (!inconsistent) {
        if (provisional != null) {
          // Both observed wrappers now name the same stable StoreKit item.
          // Keep its single finish record and remember the old handle for replay.
          await db.delete('queue_item', where: 'id=?', whereArgs: [handle]);
        }
        final queueToken = token ?? provisional?['token'];
        final original = rawFacts['originalId'] ?? provisional?['originalId'];
        await db.update(
            'queue_item',
            {
              'purchaseId': id,
              'status': 'paid',
              if (savedQueue['storeQueueId'] == null)
                'storeQueueId': _present(e.queueId),
              'reportedId': reported ?? savedQueue['reportedId'],
              if (savedQueue['token'] == null && queueToken != null)
                'token': queueToken,
              if (savedQueue['originalId'] == null && original != null)
                'originalId': original,
              'attemptId':
                  a?['id'] ?? p?['attemptId'] ?? savedQueue['attemptId'],
            },
            where: 'id=?',
            whereArgs: [key]);
      }
      if (inconsistent) {
        final observation = jsonEncode([key, reported, token, e.productId]);
        await _conflict(db, {'id': id}, a, 'identityConflict', observation);
        if (fromQueue != null && fromQueue['id'] != id) {
          await _conflict(db, fromQueue, null, 'identityConflict', observation);
        }
        if (fromId != null && fromId['id'] != id) {
          await _conflict(db, fromId, null, 'identityConflict', key);
        }
        if (provisional != null && _disagrees(savedQueue?['purchaseId'], id)) {
          await _conflict(db, {'id': savedQueue!['purchaseId']}, null,
              'identityConflict', observation);
        }
        // An untrusted, contradictory receipt must not be routed to either account.
        await _addEvidence(db, id, e.receipt);
      } else {
        if (p?['disposition'] == null || queue?['finished'] != 1) {
          await _addEvidence(db, id, e.receipt);
        }
        if (a != null) {
          // Unaccepted legacy queue events are journaled without changing
          // the attempt. Retain a terminal fact that preceded the first charge.
          final priorLegacyTerminal = a['mode'] == 'legacy' &&
              a['legacySubmission'] != 'accepted' &&
              _activePhase(a['phase']) &&
              (_unpaidPhase(queue?['status']) ||
                  (await db.query('queue_item',
                          columns: ['id'],
                          where:
                              "attemptId=? AND status IN ('canceled','failed')",
                          whereArgs: [a['id']],
                          limit: 1))
                      .isNotEmpty);
          if (_unpaidPhase(a['phase']) || priorLegacyTerminal) {
            await _conflict(db, {'id': id}, a, 'paymentAfterUnpaid', key);
          } else if (_activePhase(a['phase']) && !_chargeOnHold(p)) {
            // StoreKit can add evidence, but cannot clear a server hold.
            await db.update('attempt', {'phase': 'paid', 'reason': null},
                where: 'id=?', whereArgs: [a['id']]);
          }
        }
      }
      if (!inconsistent) await _bindExactObservation(db, e, id);
      if (!inconsistent && reported != null) {
        final order = p?['orderId'] as String? ?? a?['orderId'] as String?;
        if (order != null) {
          await _reservePrimary(
              db, p?['scope'] as String? ?? a?['scope'] as String?, order, id);
        }
      }
      return (
        key: key,
        id: id,
        keep: savedQueue?['finished'] != 1,
        absorbed: !inconsistent && provisional != null ? handle : null
      );
    });
    if (id.absorbed case final handle?) {
      _handleAliases[handle] = id.key;
      _live.remove(handle);
    }
    if (id.keep) _live[id.key] = e;
    _changed();
    _schedule(id.id);
  }

  Future<bool> _processUnpaid(StoreEvent e, {bool cold = false}) async {
    final result = await _journal.write((db) async {
      final key = await _queueKey(db, e);
      final queue = await _row(db, 'queue_item', key);
      final a = cold
          ? await _attemptForToken(db, _wire(e.token))
          : await _observedAttempt(db, e.token, queue);
      final sameItem = queue == null ||
          (queue['productId'] == e.productId &&
              !_disagrees(queue['token'], _wire(e.token)) &&
              !_disagrees(queue['reportedId'], _present(e.transactionId)));
      final matches = a != null &&
          a['productId'] == e.productId &&
          !_disagrees(queue?['attemptId'], a['id']);
      if (cold &&
          (!sameItem ||
              !matches ||
              queue?['status'] == 'paid' ||
              !await _canRecoverFailure(db, e, a))) {
        return null;
      }
      if (!sameItem ||
          queue?['status'] == 'paid' ||
          queue?['finished'] == 1 ||
          (e.status == StoreStatus.pending &&
              queue != null &&
              queue['status'] != 'pending')) {
        return (key: key, finish: false, notify: false, id: null as String?);
      }
      if (queue == null) {
        await db.insert('queue_item', {
          'id': key,
          'attemptId': matches ? a['id'] : null,
          'productId': e.productId,
          'token': _wire(e.token),
          'reportedId': _present(e.transactionId),
          'originalId': _present(e.originalTransactionId),
          'status': e.status.name,
          'storeQueueId': _present(e.queueId),
          if (!matches) 'reason': 'unowned'
        });
      } else {
        await db.update(
            'queue_item',
            {
              'status': e.status.name,
              if (queue['storeQueueId'] == null)
                'storeQueueId': _present(e.queueId),
              if (matches) 'attemptId': a['id'],
              'reason': matches ? null : 'unowned'
            },
            where: 'id=?',
            whereArgs: [key]);
      }
      if (!matches) {
        return (
          key: key,
          finish: e.allowsUnownedFinish && e.status != StoreStatus.pending,
          notify: false,
          id: null as String?
        );
      }
      // A replay sharing a legacy business token cannot settle this page until
      // the native enqueue is confirmed. Keep the queue fact for that reply.
      final notify =
          (a['mode'] != 'legacy' || a['legacySubmission'] == 'accepted') &&
              _activePhase(a['phase']) &&
              a['phase'] != e.status.name;
      if (notify) {
        await db.update('attempt',
            {'phase': e.status.name, 'reason': 'store_${e.status.name}'},
            where: 'id=?', whereArgs: [a['id']]);
      }
      return (
        key: key,
        finish: e.status != StoreStatus.pending,
        notify: notify,
        id: a['id'] as String?
      );
    });
    if (result == null) return false;
    final key = result.key;
    _changed();
    if (result.finish) {
      _live[key] = e;
      _background(_finishOne(key, e, null));
    }
    if (result.notify) {
      try {
        _legacy[_origin[result.id]]?.status(e.token, e.status);
      } catch (_) {
        _report(StateError('Legacy status receiver failed'));
      }
    }
    return true;
  }

  Future<void> _finishOne(String key, StoreEvent e, String? id) {
    final busy = _closingItems[key];
    if (busy != null) return busy;
    final work = _finishRecorded(key, e, id).catchError((Object error) {
      _report(StateError('StoreKit finish requires retry'));
      if (id == null) {
        _defer('unpaid/$key', () async {
          final current = _live[key];
          if (current != null &&
              (current.status == StoreStatus.failed ||
                  current.status == StoreStatus.canceled)) {
            _queueEvent(current);
          }
        });
      } else {
        _retryLater(id);
      }
    }).whenComplete(() {
      _closingItems.remove(key);
    });
    _closingItems[key] = work;
    return work;
  }

  bool _sameFinishObject(StoreEvent? live, StoreEvent authorized) =>
      live != null &&
      _objectKey(live) == _objectKey(authorized) &&
      live.status == authorized.status &&
      live.productId == authorized.productId &&
      live.transactionId == authorized.transactionId &&
      live.queueId == authorized.queueId &&
      _wire(live.token) == _wire(authorized.token) &&
      live.needsFinish == authorized.needsFinish &&
      live.allowsUnownedFinish == authorized.allowsUnownedFinish;

  // This records permission to request finish, including the original basis if
  // a later review amends the charge. Only StoreKit can confirm its removal.
  Future<void> _recordFinishAuthority(DatabaseExecutor db, StoreEvent e,
      {required String itemId, _Row? purchase, String? handoff}) async {
    final basis = jsonEncode({
      'status': e.status.name,
      'productId': e.productId,
      'reportedId': e.transactionId,
      'queueId': e.queueId,
      if (purchase != null) ...{
        'charge': purchase['id'],
        'verifiedId': purchase['verifiedId'],
        'scope': purchase['scope'],
        'orderId': purchase['orderId'],
        'disposition': purchase['disposition'],
        'reference': purchase['ackRef'],
        'disputeRevision': purchase['disputeRevision'],
        if (handoff != null) 'handoffHash': handoff,
      },
    });
    await db.rawInsert('''INSERT OR IGNORE INTO recovery.finish_authority
        (generation,objectKey,itemId,environment,basis) VALUES (?,?,?,?,?)''', [
      _generation,
      _objectKey(e),
      itemId,
      _configured ? _environment : 'compat',
      basis
    ]);
  }

  Future<void> _finishRecorded(String key, StoreEvent e, String? id) async {
    String? observation;
    final permitted = await _journal.write((db) async {
      final q = await _row(db, 'queue_item', key);
      if (q == null || q['finished'] == 1 || q['status'] != e.status.name) {
        return false;
      }
      observation = q['observation'] as String?;
      final live = _live[key] ?? _currentUnbound[observation];
      if (live == null) return false;
      if (!_sameFinishObject(live, e)) {
        throw StateError('StoreKit finish observation changed');
      }
      if (id == null) {
        if ((!e.allowsUnownedFinish && q['attemptId'] == null) ||
            (e.status != StoreStatus.canceled &&
                e.status != StoreStatus.failed)) {
          return false;
        }
        await _recordFinishAuthority(db, e, itemId: key);
        return true;
      }
      // Validate the individual item's reported identity again after an alias
      // merge. No earlier receipt can authorize a different or unidentified item.
      final reported = _present(e.transactionId);
      if (reported == null || q['reportedId'] != reported) return false;
      final p = await _reportedPurchase(db, reported);
      if (p == null ||
          p['id'] != id ||
          q['purchaseId'] != id ||
          p['disposition'] == null ||
          _chargeOnHold(p)) {
        return false;
      }
      String? handoff;
      if (p['disposition'] == 'legacyHandedOff') {
        final records = await db.query('legacy_handoff',
            columns: ['hash'],
            where: 'purchaseId=? AND attemptId=?',
            whereArgs: [id, p['attemptId']]);
        handoff = records.firstOrNull?['hash'] as String?;
        if (handoff == null) return false;
      } else if (p['ackRef'] == null || p['verifiedId'] == null) {
        return false;
      }
      await _recordFinishAuthority(db, e,
          itemId: key, purchase: p, handoff: handoff);
      return true;
    });
    final current = _live[key] ?? _currentUnbound[observation];
    if (!permitted || !_ready || _closed || current == null) return;
    if (!_sameFinishObject(current, e)) {
      throw StateError('StoreKit finish observation changed');
    }
    try {
      if (current.needsFinish) await _store.finish(current);
    } catch (_) {
      await _journal.write((db) => db.update(
          'queue_item', {'reason': 'finishRetry'},
          where: 'id=?', whereArgs: [key]));
      _changed();
      if (id != null) _retryLater(id);
      throw StateError('StoreKit finish requires retry');
    }
    await _journal.write((db) async {
      await db.update('queue_item', {'finished': 1, 'reason': null},
          where: id == null
              ? 'id=? AND status=? AND purchaseId IS NULL'
              : 'id=? AND status=? AND purchaseId=?',
          whereArgs: [key, e.status.name, if (id != null) id]);
      if (id != null) {
        await db.rawDelete(
            '''DELETE FROM purchase_evidence WHERE purchaseId=? AND
          EXISTS(SELECT 1 FROM purchase WHERE id=? AND disposition IS NOT NULL AND conflict=0)
          AND NOT EXISTS(SELECT 1 FROM queue_item WHERE purchaseId=? AND finished=0)''',
            [id, id, id]);
        // Bound recovery observations keep identity and the adjudication trail.
        // Their receipt bytes can be released once every exact item is closed.
        await db.rawDelete(
            '''DELETE FROM recovery.candidate WHERE observation IN (
          SELECT id FROM recovery.observation WHERE boundEnvironment=? AND boundPurchase=?
        ) AND EXISTS(SELECT 1 FROM purchase WHERE id=? AND disposition IS NOT NULL AND conflict=0)
          AND NOT EXISTS(SELECT 1 FROM queue_item WHERE purchaseId=? AND finished=0)''',
            [_environment, id, id, id]);
      }
    });
    if (_sameFinishObject(_live[key], current)) _live.remove(key);
    if (id == null) {
      _timers.remove('unpaid/$key')?.cancel();
      _delays.remove('unpaid/$key');
    }
    _changed();
  }

  Future<void> _finishPurchase(String id) async {
    final rows = await _journal.read((db) => db.query('queue_item',
        where: 'purchaseId=? AND finished=0 AND status=?',
        whereArgs: [id, 'paid']));
    for (final row in rows) {
      final key = row['id'] as String;
      final e = _live[key] ?? _currentUnbound[row['observation']];
      if (e != null && e.status == StoreStatus.paid) {
        try {
          await _finishOne(key, e, id);
        } catch (_) {
          _report(StateError('StoreKit finish requires retry'));
          _retryLater(id);
        }
      }
    }
    final unfinished = await _journal.read((db) => db.query('queue_item',
        columns: ['id'],
        where: 'purchaseId=? AND finished=0',
        whereArgs: [id],
        limit: 1));
    if (unfinished.isEmpty) {
      _timers.remove('purchase/$id')?.cancel();
      _delays.remove('purchase/$id');
    }
  }

  Future<void> _processPurchase(String id) async {
    final inputs = await _journal.read((db) async {
      final p = await _row(db, 'purchase', id);
      final evidence = await db.rawQuery('''
        SELECT e.body,x.hash FROM purchase_evidence x JOIN evidence e ON e.hash=x.hash
        WHERE x.purchaseId=? AND x.rejected=0 AND (? IS NOT NULL OR x.storeObserved=1)
        ORDER BY (x.tried=0) DESC,x.seq DESC''', [id, p?['scope']]);
      final primary = p?['orderId'] == null
          ? null
          : (await db.query('order_primary',
                  columns: ['purchaseId'],
                  where: 'scope=? AND orderId=?',
                  whereArgs: [p?['scope'] ?? '', p?['orderId']]))
              .firstOrNull;
      return (
        purchase: p,
        evidence: evidence,
        additional: primary != null && primary['purchaseId'] != id
      );
    });
    final p = inputs.purchase;
    if (_closed || p == null || p['reportedId'] == null || _chargeOnHold(p)) {
      return;
    }
    if (p['disposition'] != null) return _finishPurchase(id);
    final scope = p['scope'] as String?, attempt = p['attemptId'] as String?;
    final version = p['inputVersion'] as int;
    final account = _account;
    if (scope == null) {
      if (attempt == null) return;
      if (inputs.additional) {
        await _journal.write((db) => db.update(
            'purchase', {'reason': 'needsReconciliation'},
            where:
                'id=? AND scope IS NULL AND conflict=0 AND disposition IS NULL AND inputVersion=?',
            whereArgs: [id, version]));
        _changed();
        return;
      }
    } else if (account == null ||
        account.scope != scope ||
        p['blockedLogin'] == account._generation) {
      return;
    }
    final binding = (account?._generation ?? '', version);
    final cooldown = _cooldowns[id];
    if (cooldown == binding) return;
    if (cooldown != null) {
      _cooldowns.remove(id);
      _timers.remove('purchase/$id')?.cancel();
      _delays.remove('purchase/$id');
    }

    var retry = false;
    for (final e in inputs.evidence) {
      final body = e['body'] as String, hash = e['hash'] as String;
      final _CandidateResult step;
      if (scope == null) {
        step = await _handoff(
            id, attempt!, version, hash, body, p['token'] as String?);
      } else {
        final receipt = AppleReceipt(
            scope: scope,
            orderId: p['orderId'] as String,
            productId: p['productId'] as String,
            attemptId: attempt,
            transactionId: p['reportedId'] as String,
            originalTransactionId: p['originalId'] as String?,
            purchaseToken: p['token'] as String?,
            receipt: body,
            additionalCharge: inputs.additional);
        step = await _verifyCandidate(id, account!, version, hash, receipt);
      }
      if (step == _CandidateResult.stop) return;
      retry |= step == _CandidateResult.retry;
    }
    if (retry) {
      _cooldowns[id] = binding;
      _retryLater(id);
    }
  }

  Future<_CandidateResult> _handoff(String id, String attempt, int version,
      String hash, String body, String? token) async {
    final owner = _origin[attempt];
    final legacy = _legacy[owner];
    if (legacy?.receive == null) return _CandidateResult.stop;
    // Reserve inside the journal queue, mutually exclusive with trusted claim.
    final reserved = await _journal.read((db) async {
      final ready = await db.rawQuery('''
        SELECT 1 FROM purchase p JOIN attempt a ON a.id=p.attemptId
        JOIN order_primary o ON o.purchaseId=p.id AND o.scope='' AND o.orderId=a.orderId
        WHERE p.id=? AND p.attemptId=? AND p.scope IS NULL AND p.inputVersion=?
          AND p.claimRef IS NULL AND p.disposition IS NULL AND p.conflict=0
          AND a.legacySubmission='accepted'
          AND NOT EXISTS(SELECT 1 FROM decision WHERE attemptId=a.id AND result!='conflict')
        ''', [id, attempt, version]);
      return ready.isNotEmpty &&
          !_closed &&
          identical(legacy, _legacy[owner]) &&
          _legacyDelivering.add(id);
    });
    if (!reserved) return _CandidateResult.stop;
    try {
      if (_closed || !identical(legacy, _legacy[owner])) {
        return _CandidateResult.stop;
      }
      try {
        await legacy!.receive!(body);
      } catch (_) {
        _report(StateError('Legacy receipt receiver requires retry'));
        await _journal.write((db) => db.update(
            'purchase_evidence', {'tried': 1},
            where: 'purchaseId=? AND hash=?', whereArgs: [id, hash]));
        return _CandidateResult.retry;
      }
      await _journal.write((db) async {
        await db.insert('legacy_handoff',
            {'purchaseId': id, 'attemptId': attempt, 'hash': hash},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await db.rawUpdate('''UPDATE purchase SET disposition='legacyHandedOff',
            reason=CASE WHEN conflict=0 THEN NULL ELSE reason END
            WHERE id=? AND disposition IS NULL AND scope IS NULL AND attemptId=?''',
            [id, attempt]);
      });
      _changed();
      try {
        if (identical(legacy, _legacy[owner])) {
          legacy.status(token, StoreStatus.paid);
        }
      } catch (_) {
        _report(StateError('Legacy status receiver failed'));
      }
      await _finishPurchase(id);
      return _CandidateResult.stop;
    } finally {
      _legacyDelivering.remove(id);
    }
  }

  Future<_CandidateResult> _verifyCandidate(String id, AppleAccount account,
      int version, String hash, AppleReceipt receipt) async {
    final call = _VerificationCall(account, version, hash);
    final p = await _journal.read((db) => _row(db, 'purchase', id));
    if (_closed ||
        !identical(_account, account) ||
        p == null ||
        p['inputVersion'] != version ||
        p['disposition'] != null ||
        _chargeOnHold(p)) {
      return _CandidateResult.stop;
    }
    _calls[id] = call;
    final timeout = _timer(_verificationTimeout, () {
      if (!call.retired.isCompleted) {
        call.retire();
        _cooldowns[id] = (account._generation, version);
        _retryLater(id);
      }
    });
    final response =
        Future.sync(() => account._verify(receipt)).catchError((Object _) {
      _report(StateError('Apple receipt verification requires retry'));
      return const AppleVerification.retryLater();
    }).then((result) {
      if (_closed) return Future.value(_CandidateResult.stop);
      final applying = _applyVerification(id, call, receipt, result)
          .catchError((Object error) {
        _report(error);
        _retryLater(id);
        return _CandidateResult.stop;
      });
      _responding.add(applying);
      return applying.whenComplete(() => _responding.remove(applying));
    });
    try {
      return await Future.any(
          [response, call.retired.future.then((_) => _CandidateResult.stop)]);
    } finally {
      timeout.cancel();
      if (identical(_calls[id], call)) _calls.remove(id);
    }
  }

  Future<_CandidateResult> _applyVerification(String id, _VerificationCall call,
      AppleReceipt receipt, AppleVerification result) async {
    if (result.kind == AppleVerificationKind.delivered) {
      final canonical = await _acceptAck(id, receipt, result.ack!);
      _changed();
      if (canonical != null) await _finishPurchase(canonical);
      return _CandidateResult.stop;
    }
    if (result.kind == AppleVerificationKind.environmentMismatch) {
      await _acceptMismatch(id, receipt, result.mismatch!, call);
      _changed();
      return _CandidateResult.stop;
    }
    final rejected = result.kind == AppleVerificationKind.invalidEvidence;
    final blocked = result.kind == AppleVerificationKind.needsReconciliation;
    // Nonterminal answers can only write to the still-current call and input.
    if (call.retired.isCompleted || !identical(_calls[id], call)) {
      return _CandidateResult.stop;
    }
    final applied = await _journal.write((db) async {
      final p = await _row(db, 'purchase', id);
      if (_closed ||
          call.retired.isCompleted ||
          !identical(_calls[id], call) ||
          !identical(_account, call.account) ||
          p == null ||
          p['inputVersion'] != call.version ||
          p['disposition'] != null ||
          _chargeOnHold(p)) {
        return false;
      }
      await db.update(
          'purchase',
          {
            'reason': blocked
                ? 'needsReconciliation'
                : rejected
                    ? 'invalidEvidence'
                    : 'verificationRetry',
            if (blocked) 'blockedLogin': call.account._generation,
          },
          where: 'id=?',
          whereArgs: [id]);
      if (!blocked) {
        await db.update(
            'purchase_evidence', {'tried': 1, if (rejected) 'rejected': 1},
            where: 'purchaseId=? AND hash=?', whereArgs: [id, call.hash]);
      }
      return true;
    });
    if (applied) _changed();
    if (!applied || blocked) return _CandidateResult.stop;
    return rejected ? _CandidateResult.rejected : _CandidateResult.retry;
  }

  Future<String?> _acceptAck(
          String purchaseId, AppleReceipt input, AppleDisposition ack) =>
      _journal.write((db) async {
        final p = await _row(
            db, 'purchase', await _canonicalPurchaseId(db, purchaseId));
        if (p == null) return null;
        if (ack.appId != _appId ||
            ack.environment != _environment ||
            ack.quantity != 1 ||
            ack.productId != input.productId ||
            ack.reportedTransactionId != input.transactionId ||
            ack.reference.trim().isEmpty ||
            ack.verifiedTransactionId.trim().isEmpty ||
            ack.scope.trim().isEmpty ||
            ack.orderId.trim().isEmpty) {
          await _conflict(db, p, null, 'dispositionMismatch', _ackPayload(ack));
          return null;
        }
        if (_disagrees(p['verifiedId'], ack.verifiedTransactionId)) {
          return _recordIdentityConflict(db, p, disposition: ack);
        }
        final canonical = (await db.query('purchase',
                    where: 'appId=? AND environment=? AND verifiedId=?',
                    whereArgs: [
                      ack.appId,
                      ack.environment,
                      ack.verifiedTransactionId
                    ],
                    limit: 1))
                .firstOrNull ??
            p;
        if (p['scope'] != ack.scope ||
            p['orderId'] != ack.orderId ||
            canonical['scope'] != ack.scope ||
            canonical['orderId'] != ack.orderId ||
            input.scope != ack.scope ||
            input.orderId != ack.orderId ||
            _requiresEnvironmentProof(p['reason'])) {
          final fresh = await _saveDisposition(db, canonical, ack);
          if (fresh) {
            final reason = _requiresEnvironmentProof(p['reason'])
                ? 'environmentConflict'
                : 'dispositionConflict';
            await _openDispute(db, canonical, reason, _ackPayload(ack));
            if (canonical['id'] != p['id']) {
              await _conflict(db, p, null, reason, _ackPayload(ack));
            }
          }
          return null;
        }
        final id = await _trustedIdentity(db, p,
            app: ack.appId,
            environment: ack.environment,
            scope: ack.scope,
            order: ack.orderId,
            sku: ack.productId,
            reported: ack.reportedTransactionId,
            verified: ack.verifiedTransactionId,
            reference: ack.reference);
        if (id == null) return null;
        return _recordDisposition(db, (await _row(db, 'purchase', id))!, ack);
      });

  /// Both trusted entry points preserve contradictory identities on the
  /// originally reported charge. A covered fact replay cannot reopen it.
  Future<String?> _recordIdentityConflict(DatabaseExecutor db, _Row p,
      {AppleClaim? claim, AppleDisposition? disposition}) async {
    if (claim != null) {
      final saved = await db.query('claim_fact',
          columns: ['covered'],
          where: 'purchaseId=? AND payload=?',
          whereArgs: [p['id'], _claimPayload(claim)]);
      if (saved.isEmpty) {
        await _saveClaim(db, p, claim);
        await _openDispute(
            db, p, 'claimIdentityConflict', _claimPayload(claim));
      }
    }
    if (disposition != null && await _saveDisposition(db, p, disposition)) {
      await _openDispute(
          db, p, 'dispositionIdentityConflict', _ackPayload(disposition));
    }
    final current = (await _row(db, 'purchase', p['id']))!;
    return current['conflict'] == 1 ? null : p['id'] as String;
  }

  Future<String?> _recordDisposition(
      DatabaseExecutor db, _Row p, AppleDisposition ack) async {
    final id = p['id'] as String;
    if (_disagrees(p['verifiedId'], ack.verifiedTransactionId)) {
      return _recordIdentityConflict(db, p, disposition: ack);
    }
    final fresh = await _saveDisposition(db, p, ack);
    if (!fresh) return p['conflict'] == 0 ? id : null;
    // Only missing predecessor evidence can resolve itself. An open ownership
    // or disposition dispute requires an explicit revision-bound adjudication.
    if (p['conflict'] == 1 && p['reason'] != 'missingPredecessor') {
      await _openDispute(db, p, 'dispositionConflict', _ackPayload(ack));
      return null;
    }
    final rows = await db
        .query('disposition_fact', where: 'purchaseId=?', whereArgs: [id]);
    final active = rows.where((r) => r['covered'] == 0).toList();
    // A review can cover all older receipts. Compare its current effective
    // receipt as well, without reviving previously overruled facts.
    if (p['ackRef'] != null &&
        !active.any((r) => r['reference'] == p['ackRef'])) {
      active.add({
        'reference': p['ackRef'],
        'outcome': p['disposition'],
        'scope': p['scope'],
        'orderId': p['orderId']
      });
    }
    Future<String?> freeze(String reason) async {
      await _openDispute(db, p, reason, _ackPayload(ack));
      return null;
    }

    final references = <String, _Row>{};
    for (final r in active) {
      final ref = r['reference'] as String;
      final other = references[ref];
      if (r['scope'] != p['scope'] ||
          r['orderId'] != p['orderId'] ||
          other != null &&
              (other['outcome'] != r['outcome'] ||
                  other['supersedes'] != r['supersedes'])) {
        return freeze('dispositionConflict');
      }
      references[ref] = r;
    }
    for (final r in active.where((r) => r['supersedes'] != null)) {
      final prior = references[r['supersedes']];
      if (r['outcome'] != 'refunded' || r['supersedes'] == r['reference']) {
        return freeze('dispositionConflict');
      }
      if (prior == null) return freeze('missingPredecessor');
      if (prior['outcome'] != 'delivered') return freeze('dispositionConflict');
    }
    final refunds = active.where((r) => r['outcome'] == 'refunded');
    if (refunds.isNotEmpty &&
        active.any((r) => r['outcome'] == 'delivered') &&
        !refunds.any((r) => r['supersedes'] != null)) {
      return freeze('dispositionConflict');
    }
    final candidates = refunds.isEmpty ? active : refunds;
    final effective =
        candidates.where((r) => r['reference'] == p['ackRef']).firstOrNull ??
            candidates.first;
    await _amend(db, id, {
      'ackRef': effective['reference'],
      'disposition': effective['outcome'],
      'reason': null,
      'conflict': 0,
    });
    await _closeSettledAttempt(db, id);
    return id;
  }

  Future<void> _refreshEvidence(Future<void> context, Set<String> initial,
      Set<String> unbound, String receipt) async {
    final ids = await _journal.write((db) async {
      if (_closed || !identical(_configuration, context)) return <String>{};
      final targets = await _refreshUnbound(db, receipt, unbound);
      for (final id in initial) {
        targets.add(await _canonicalPurchaseId(db, id));
      }
      final missing = await db.rawQuery('''SELECT id FROM purchase p
        WHERE disposition IS NULL AND NOT EXISTS(
          SELECT 1 FROM purchase_evidence x WHERE x.purchaseId=p.id)''');
      targets.addAll(missing.map((r) => r['id'] as String));
      final pending = <String>{};
      for (final id in targets) {
        final p = await _row(db, 'purchase', id);
        if (p != null && p['disposition'] == null) {
          await _addEvidence(db, id, receipt,
              source: 'refresh', context: _environment);
          pending.add(id);
        }
      }
      return pending;
    });
    _changed();
    for (final id in ids) {
      _schedule(id);
    }
  }

  // Only the trusted verifier or reconciliation service may establish an alias.
  // A shared receipt hash, restored queue id, SKU or original id cannot do so.
  Future<String?> _trustedIdentity(
    DatabaseExecutor db,
    _Row p, {
    required String app,
    required String environment,
    required String scope,
    required String order,
    required String sku,
    required String reported,
    required String verified,
    required String reference,
    String? claimToken,
  }) async {
    final verifiedRow = (await db.query('purchase',
            where: 'appId=? AND environment=? AND verifiedId=?',
            whereArgs: [app, environment, verified],
            limit: 1))
        .firstOrNull;
    final canonical = verifiedRow ?? p;
    if (_legacyDelivering.contains(p['id']) ||
        _legacyDelivering.contains(canonical['id'])) {
      throw StateError('Legacy receipt handoff in progress');
    }
    final target = canonical['id'] as String;
    final alias = (await db.query('purchase_alias',
            where: 'reportedId=?', whereArgs: [reported]))
        .firstOrNull;
    final effectiveToken = claimToken ?? p['token'];
    final mismatch = (alias != null && alias['purchaseId'] != target) ||
        (canonical['scope'] != null && canonical['scope'] != scope) ||
        (canonical['orderId'] != null && canonical['orderId'] != order) ||
        canonical['productId'] != sku ||
        (canonical['token'] != null &&
            effectiveToken != null &&
            canonical['token'] != effectiveToken) ||
        (canonical['conflict'] == 1 && canonical['id'] != p['id']);
    if (mismatch) {
      await _conflict(db, p, null, 'verifiedIdentityConflict', reference);
      return null;
    }
    if (target != p['id']) {
      // The verifier can establish aliases. Their existing submission bindings
      // must still agree, or supplement exactly one recovered placeholder.
      final submission = await _row(db, 'attempt', p['attemptId']) ??
          await _attemptForToken(db, effectiveToken as String?);
      if (p['disposition'] != null ||
          p['verifiedId'] != null ||
          _disagrees(canonical['attemptId'], submission?['id']) ||
          await _hasDispute(db, p)) {
        await _conflict(db, p, null, 'verifiedIdentityConflict', reference);
        return null;
      }
      await _mergeEvidence(db, p, canonical);
    }
    await db.update(
        'purchase',
        {
          'scope': scope,
          'orderId': order,
          'appId': app,
          'environment': environment,
          'verifiedId': verified
        },
        where: 'id=?',
        whereArgs: [target]);
    if (alias == null) {
      await db.insert('purchase_alias', {
        'reportedId': reported,
        'purchaseId': target,
        'claimRef': reference
      });
    }
    return target;
  }

  bool _validClaim(AppleClaim c) =>
      c.appId == _appId &&
      c.environment == _environment &&
      [
        c.scope,
        c.orderId,
        c.productId,
        c.reportedTransactionId,
        c.verifiedTransactionId,
        c.reference
      ].every((v) => v.trim().isNotEmpty) &&
      (c.purchaseToken == null ||
          Uuid.isValidUUID(fromString: c.purchaseToken!));

  Future<String?> _applyClaim(DatabaseExecutor db, AppleClaim c,
      {_Row? decidedAttempt, Set<String>? affected}) async {
    await _bindObservation(db, c);
    var p = await _reportedPurchase(db, c.reportedTransactionId);
    if (p == null) {
      if (decidedAttempt == null) throw StateError('Unknown Apple transaction');
      final id = const Uuid().v4();
      await db.insert('purchase', {
        'id': id,
        'reportedId': c.reportedTransactionId,
        'productId': c.productId,
        'token': _wire(c.purchaseToken),
      });
      p = (await _row(db, 'purchase', id))!;
    }
    final verified = (await db.query('purchase',
            where: 'appId=? AND environment=? AND verifiedId=?',
            whereArgs: [c.appId, c.environment, c.verifiedTransactionId]))
        .firstOrNull;
    final canonical = verified ?? p;
    if (_legacyDelivering.contains(p['id']) ||
        _legacyDelivering.contains(canonical['id'])) {
      throw StateError('Legacy receipt handoff in progress');
    }
    final ack = c.disposition;
    if (ack != null && !_matchesClaim(c, ack)) {
      throw StateError('Invalid recovery disposition');
    }
    if (c.review == null &&
        _disagrees(p['verifiedId'], c.verifiedTransactionId)) {
      return _recordIdentityConflict(db, p, claim: c, disposition: ack);
    }
    if (c.review != null) {
      if (decidedAttempt != null || c.disposition != null || affected == null) {
        throw StateError('Ambiguous Apple review');
      }
      if (verified != null &&
          verified['id'] != p['id'] &&
          p['verifiedId'] != null) {
        throw StateError(
            'Reviewed identity already belongs to another Apple charge');
      }
      return _reviewDispute(db, canonical, p, c, affected);
    }
    if (const {'environmentMismatch', 'environmentConflict'}
            .contains(canonical['reason']) ||
        canonical['reason'] == 'sourceUnproven' &&
            !await _provesSource(db, canonical, c) ||
        (canonical['conflict'] == 1 &&
            (await _disputedEnvironmentProofs(db, canonical['id'] as String))
                .isNotEmpty)) {
      throw StateError(
          'Apple source environment requires independent verification');
    }
    final prior = (await db.query('claim_fact',
            where: 'purchaseId=? AND payload=?',
            whereArgs: [canonical['id'], _claimPayload(c)]))
        .firstOrNull;
    if (prior?['covered'] == 1 && decidedAttempt == null) {
      // Replaying an adjudicated claim cannot re-open ownership. Its attached
      // receipt is an independent fact and may itself be new or already covered.
      if (ack == null) return canonical['id'] as String;
      return _recordDisposition(db, canonical, ack);
    }
    final token = _wire(c.purchaseToken);
    final matched = token == null ? null : await _attemptForToken(db, token);
    // A pre-registered UUID can be observed before this installation submits it.
    final owner = matched?['phase'] == 'prepared' ? null : matched;
    final bound =
        await _row(db, 'attempt', p['attemptId'] ?? canonical['attemptId']);
    // A prior adjudication can separate the historical submission from the
    // corrected owner. Its wire token remains evidence, not a new binding.
    final adjudicated = (canonical['disputeRevision'] as int) > 0 &&
        (await db.query('dispute_review',
                columns: ['id'],
                where: 'purchaseId=?',
                whereArgs: [canonical['id']],
                limit: 1))
            .isNotEmpty;
    final a = decidedAttempt ?? bound ?? (adjudicated ? null : owner);
    final ownersDisagree = _disagrees(canonical['scope'], c.scope) ||
        _disagrees(canonical['orderId'], c.orderId) ||
        _disagrees(p['scope'], c.scope) ||
        _disagrees(p['orderId'], c.orderId);
    if (ownersDisagree || _disagrees(decidedAttempt?['id'], bound?['id'])) {
      await _saveClaim(db, canonical, c);
      await _openDispute(
          db,
          canonical,
          'ownershipConflict',
          jsonEncode([
            _claimPayload(c),
            if (decidedAttempt != null) decidedAttempt['id']
          ]));
      if (ack != null && await _saveDisposition(db, canonical, ack)) {
        await _openDispute(
            db, canonical, 'dispositionConflict', _ackPayload(ack));
      }
      if (canonical['id'] != p['id']) {
        await _conflict(
            db, p, null, 'verifiedIdentityConflict', _claimPayload(c));
      }
      return null;
    }
    final business = await db.rawQuery(
        '''SELECT productId FROM attempt WHERE scope=? AND orderId=?
      UNION SELECT productId FROM purchase WHERE scope=? AND orderId=?''',
        [c.scope, c.orderId, c.scope, c.orderId]);
    final invalid = p['productId'] != c.productId ||
        _disagrees(p['token'], token) ||
        _disagrees(decidedAttempt?['id'], owner?['id']) ||
        a != null &&
            (a['orderId'] != c.orderId ||
                a['productId'] != c.productId ||
                _disagrees(a['scope'], c.scope) ||
                _disagrees(_wire(a['wireToken'] as String?), token) ||
                a['mode'] == 'legacy' &&
                    !await _legacyScopeAgrees(
                        db, a['id'] as String, c.scope)) ||
        business.any((r) => r['productId'] != c.productId);
    if (invalid) {
      await _conflict(db, p, null, 'claimMismatch', _claimPayload(c));
      return null;
    }
    if (canonical['conflict'] == 1 &&
        (canonical['disputeRevision'] as int) > 0) {
      await _saveClaim(db, canonical, c);
      if (ack == null) {
        return decidedAttempt == null ? canonical['id'] as String : null;
      }
      final settled = await _recordDisposition(db, canonical, ack);
      if (settled == null || decidedAttempt == null) return settled;
      // Both facts may arrive together. Once a missing predecessor settles
      // the charge, continue through the normal attempt-binding checks.
    }
    if (p['conflict'] == 1 &&
        (await db.query('conflict_fact',
                columns: ['id'],
                where: 'purchaseId=? AND reason=?',
                whereArgs: [p['id'], 'identityConflict'],
                limit: 1))
            .isNotEmpty) {
      return null;
    }
    final target = await _trustedIdentity(db, p,
        app: c.appId,
        environment: c.environment,
        scope: c.scope,
        order: c.orderId,
        sku: c.productId,
        reported: c.reportedTransactionId,
        verified: c.verifiedTransactionId,
        reference: c.reference,
        claimToken: token);
    if (target == null) return null;
    final current = (await _row(db, 'purchase', target))!;
    final selected = await _row(db, 'attempt', current['attemptId']) ?? a;
    await _saveClaim(db, current, c);
    if (selected != null && _unpaidPhase(selected['phase'])) {
      await _conflict(db, current, selected, 'paymentAfterUnpaid', c.reference);
      return null;
    }
    if (selected != null && _activePhase(selected['phase'])) {
      await db.update('attempt', {'phase': 'paid', 'reason': null},
          where: 'id=?', whereArgs: [selected['id']]);
    }
    await db.update(
        'purchase',
        {
          if (current['attemptId'] == null && selected != null)
            'attemptId': selected['id'],
          if (current['token'] == null && token != null) 'token': token,
          if (current['claimRef'] == null) 'claimRef': c.reference,
          'conflict': 0,
          if (current['reason'] != 'needsReconciliation' ||
              prior == null ||
              current['attemptId'] != selected?['id'])
            'reason': null,
        },
        where: 'id=?',
        whereArgs: [target]);
    final legacyPrimary = selected?['mode'] == 'legacy'
        ? (await db.query('order_primary',
                columns: ['purchaseId'],
                where: 'scope=? AND orderId=?',
                whereArgs: ['', c.orderId]))
            .firstOrNull
        : null;
    await _reservePrimary(db, c.scope, c.orderId,
        legacyPrimary?['purchaseId'] as String? ?? target);
    await _authorizeObservation(db, c, target);
    await _closeSettledAttempt(db, target);
    if (ack != null) {
      return _recordDisposition(db, (await _row(db, 'purchase', target))!, ack);
    }
    return target;
  }

  bool _matchesClaim(AppleClaim c, AppleDisposition a) =>
      a.appId == c.appId &&
      a.environment == c.environment &&
      a.scope == c.scope &&
      a.orderId == c.orderId &&
      a.productId == c.productId &&
      a.quantity == 1 &&
      a.reportedTransactionId == c.reportedTransactionId &&
      a.verifiedTransactionId == c.verifiedTransactionId &&
      a.reference.trim().isNotEmpty;

  Future<bool> _hasReviewIdentity(
      DatabaseExecutor db, String id, AppleClaim c) async {
    for (final table in ['claim_fact', 'disposition_fact']) {
      final rows = await db.query(table,
          columns: ['payload'], where: 'purchaseId=?', whereArgs: [id]);
      for (final row in rows) {
        final fields = jsonDecode(row['payload'] as String) as List;
        final reportIndex = table == 'claim_fact' ? 5 : 6;
        if (fields[0] == c.appId &&
            fields[1] == c.environment &&
            fields[4] == c.productId &&
            fields[reportIndex] == c.reportedTransactionId &&
            fields[reportIndex + 1] == c.verifiedTransactionId) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _mergeReviewedAlias(
      DatabaseExecutor db, _Row source, _Row target, AppleClaim claim) async {
    final from = source['id'], to = target['id'];
    final protected = await db.rawQuery(
        '''SELECT 1 FROM conflict_fact f WHERE purchaseId=?
        AND (reason!='verifiedIdentityConflict' OR NOT EXISTS(SELECT 1 FROM claim_fact c
          WHERE c.purchaseId=? AND c.payload=f.evidenceRef))
      UNION ALL SELECT 1 FROM disposition_fact WHERE purchaseId=?
      UNION ALL SELECT 1 FROM claim_fact WHERE purchaseId=?
      UNION ALL SELECT 1 FROM purchase_alias WHERE reportedId=? OR purchaseId=?
      UNION ALL SELECT 1 FROM legacy_handoff WHERE purchaseId=?
      LIMIT 1''',
        [from, to, from, from, claim.reportedTransactionId, from, from]);
    if (protected.isNotEmpty ||
        source['verifiedId'] != null ||
        source['disposition'] != null ||
        source['reportedId'] != claim.reportedTransactionId ||
        source['productId'] != claim.productId ||
        _disagrees(source['orderId'], claim.orderId) ||
        _disagrees(source['scope'], claim.scope) ||
        ['attemptId', 'originalId', 'token']
            .any((field) => _disagrees(source[field], target[field])) ||
        _disagrees(source['token'], _wire(claim.purchaseToken)) ||
        !await _hasReviewIdentity(db, to as String, claim)) {
      throw StateError(
          'Apple review alias has independent or incompatible evidence');
    }
    await _mergeEvidence(db, source, target);
    await db.insert('purchase_alias', {
      'reportedId': claim.reportedTransactionId,
      'purchaseId': to,
      'claimRef': claim.reference
    });
  }

  Future<String?> _reviewDispute(DatabaseExecutor db, _Row p, _Row source,
      AppleClaim c, Set<String> affected) async {
    final r = c.review!;
    final id = p['id'] as String;
    if ([r.issuer, r.decisionId, r.reference].any((s) => s.trim().isEmpty) ||
        r.disputeId != id ||
        r.revision < 1) {
      throw StateError('Invalid Apple review identity');
    }
    final finalAck = r.finalDisposition;
    final covered = r.coveredReceipts.toSet();
    final payload = jsonEncode([
      _claimPayload(c),
      r.disputeId,
      r.revision,
      r.reference,
      covered.toList()..sort(),
      if (finalAck != null) _ackPayload(finalAck),
      if (r.environmentProofId != null) r.environmentProofId
    ]);
    final prior = (await db.query('dispute_review',
            where: 'issuer=? AND id=?', whereArgs: [r.issuer, r.decisionId]))
        .firstOrNull;
    if (prior != null) {
      if (prior['payload'] == payload && prior['purchaseId'] == id) return id;
      await _openDispute(db, p, 'reviewDecisionConflict', payload);
      if (prior['purchaseId'] != id) {
        final previous = (await _row(db, 'purchase', prior['purchaseId']))!;
        await _openDispute(db, previous, 'reviewDecisionConflict', payload);
      }
      return null;
    }
    final proofs = await _disputedEnvironmentProofs(db, id);
    final foreign = r.environmentProofId != null;
    if (foreign && !proofs.containsKey(r.environmentProofId)) {
      throw StateError(
          'Apple review must select a current linked environment proof');
    }
    final selectedProof = proofs[r.environmentProofId];
    final knownIdentity = p['verifiedId'] == c.verifiedTransactionId ||
        await _hasReviewIdentity(db, id, c) ||
        (foreign &&
            p['verifiedId'] == null &&
            selectedProof != null &&
            selectedProof.reportedTransactionId == c.reportedTransactionId &&
            selectedProof.verifiedTransactionId == c.verifiedTransactionId &&
            selectedProof.purchaseToken == _wire(c.purchaseToken));
    if (p['conflict'] != 1 ||
        p['disputeRevision'] != r.revision ||
        !knownIdentity ||
        p['productId'] != c.productId ||
        _disagrees(p['token'], _wire(c.purchaseToken)) ||
        (await db.query('conflict_fact',
                columns: ['id'],
                where: "purchaseId=? AND reason='identityConflict'",
                whereArgs: [id],
                limit: 1))
            .isNotEmpty) {
      throw StateError('Apple review does not match current dispute');
    }
    final changesIdentity =
        _disagrees(p['verifiedId'], c.verifiedTransactionId) || foreign;
    if (changesIdentity &&
        (await db.rawQuery("""SELECT 1 FROM purchase_alias
        WHERE purchaseId=? AND reportedId IS NOT ?
        UNION ALL SELECT 1 FROM queue_item WHERE purchaseId=? AND reportedId IS NOT ?
        LIMIT 1""", [id, c.reportedTransactionId, id, c.reportedTransactionId]))
            .isNotEmpty) {
      throw StateError(
          'Apple review cannot transfer other reported queue items');
    }
    final facts = await db
        .query('disposition_fact', where: 'purchaseId=?', whereArgs: [id]);
    final receipts = {
      for (final f in facts) f['reference'] as String,
      if (p['ackRef'] != null) p['ackRef'] as String
    };
    final ownerChanges =
        _disagrees(p['scope'], c.scope) || _disagrees(p['orderId'], c.orderId);
    if (foreign && ownerChanges) {
      throw StateError(
          'Destination ownership must be confirmed in its environment');
    }
    final receiptDispute = facts.any((f) =>
            f['covered'] == 0 &&
            (f['scope'] != c.scope ||
                f['orderId'] != c.orderId ||
                f['outcome'] != p['disposition'] ||
                (jsonDecode(f['payload'] as String) as List)[7] !=
                    c.verifiedTransactionId)) ||
        p['reason'] == 'dispositionConflict' ||
        p['reason'] == 'missingPredecessor';
    if (receipts.isNotEmpty &&
            (ownerChanges ||
                changesIdentity ||
                receiptDispute ||
                proofs.isNotEmpty) &&
            finalAck == null ||
        finalAck != null &&
            (!_matchesClaim(c, finalAck) || !covered.containsAll(receipts)) ||
        (foreign &&
            receipts.isNotEmpty &&
            finalAck?.outcome != AppleOutcome.refunded) ||
        !receipts.containsAll(covered)) {
      throw StateError(
          'Apple review requires authenticated disposition covering existing receipts');
    }
    final business = await db.rawQuery(
        '''SELECT 1 FROM purchase WHERE scope=? AND orderId=? AND productId!=?
      UNION SELECT 1 FROM attempt WHERE scope=? AND orderId=? AND productId!=? LIMIT 1''',
        [c.scope, c.orderId, c.productId, c.scope, c.orderId, c.productId]);
    if (business.isNotEmpty) {
      throw StateError('Apple review order product mismatch');
    }
    if (source['id'] != id) {
      await _mergeReviewedAlias(db, source, p, c);
    }
    if (!foreign) await _saveClaim(db, p, c);
    if (finalAck != null) await _saveDisposition(db, p, finalAck);
    for (final table in ['claim_fact', 'disposition_fact']) {
      await db.update(table, {'covered': 1},
          where: 'purchaseId=?', whereArgs: [id]);
    }
    await db.insert('dispute_review', {
      'issuer': r.issuer,
      'id': r.decisionId,
      'purchaseId': id,
      'payload': payload
    });
    if (proofs.isNotEmpty) {
      await db.rawUpdate("""UPDATE recovery.observation SET reason=
        CASE WHEN id=? THEN 'environmentSelected' ELSE 'environmentRejected' END
        WHERE originPurchase=? AND observedContext=? AND reason='environmentConflict'""",
          [r.environmentProofId, id, _environment]);
    }
    // The compatibility snapshot retains its original receipt and queue identity.
    // Its effective environment reservation must follow the adjudication.
    if (changesIdentity) {
      if (foreign) {
        await db.rawUpdate(
            """UPDATE recovery.observation SET reason='compatibilityTransferred'
            WHERE generation='compatibility' AND boundEnvironment=? AND boundPurchase=?""",
            [c.environment, id]);
      } else {
        await db.rawUpdate(
            """UPDATE recovery.observation SET verifiedId=? WHERE
            generation='compatibility' AND boundEnvironment=? AND boundPurchase=? AND reportedId=?""",
            [
              c.verifiedTransactionId,
              c.environment,
              id,
              c.reportedTransactionId
            ]);
      }
    }
    if (foreign && p['attemptId'] != null) {
      await db.update('attempt', {'reason': 'environmentMismatch'},
          where: 'id=?', whereArgs: [p['attemptId']]);
    }
    if (ownerChanges && p['attemptId'] != null) {
      final attempt = (await _row(db, 'attempt', p['attemptId']))!;
      await db.insert(
          'detached_submission',
          {
            'purchaseId': id,
            'attemptId': attempt['id'],
            'reference': r.reference
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await _conflict(db, null, attempt, 'ownershipCorrected', r.reference);
    }
    await _amend(db, id, {
      'appId': c.appId,
      'environment': c.environment,
      if (!foreign) 'verifiedId': c.verifiedTransactionId,
      'scope': c.scope,
      'orderId': c.orderId,
      if (!foreign) 'claimRef': c.reference,
      'conflict': 0,
      'reason': foreign ? 'environmentMismatch' : null,
      if (ownerChanges)
        'attemptId': source['id'] != id &&
                p['attemptId'] == null &&
                source['scope'] == c.scope &&
                source['orderId'] == c.orderId
            ? source['attemptId']
            : null,
      if (finalAck != null) ...{
        'ackRef': finalAck.reference,
        'disposition': finalAck.outcome.name
      }
    });
    if (ownerChanges) {
      await _replacePrimaryAfterReview(db, p, affected);
    }
    await _reservePrimary(db, c.scope, c.orderId, id);
    if (!foreign) await _authorizeObservation(db, c, id);
    return id;
  }

  // additionalCharge is part of the verifier's input. Transfer of an order's
  // primary charge can change that input even if the other charge never moved.
  Future<void> _replacePrimaryAfterReview(
      DatabaseExecutor db, _Row previous, Set<String> affected) async {
    final scope = previous['scope'], order = previous['orderId'];
    final removed = await db.delete('order_primary',
        where: 'purchaseId=? AND scope=? AND orderId=?',
        whereArgs: [previous['id'], scope, order]);
    if (removed == 0) return;
    final next = (await db.query('purchase',
            columns: ['id', 'disposition'],
            where: 'scope=? AND orderId=?',
            whereArgs: [scope, order],
            orderBy: 'rowid',
            limit: 1))
        .firstOrNull;
    if (next == null) return;
    final id = next['id'] as String;
    await _reservePrimary(db, scope as String, order as String, id);
    if (next['disposition'] != null) return;
    await db.rawUpdate('''UPDATE purchase SET inputVersion=inputVersion+1,
        blockedLogin=NULL, reason=CASE WHEN conflict=0 AND reason IN
          ('needsReconciliation','invalidEvidence','verificationRetry') THEN NULL ELSE reason END
        WHERE id=?''', [id]);
    await db.update('purchase_evidence', {'tried': 0, 'rejected': 0},
        where: 'purchaseId=?', whereArgs: [id]);
    affected.add(id);
  }

  Future<void> _reconcile(AppleClaim c) async {
    if (!_validClaim(c)) {
      throw StateError('Invalid Apple claim identity or environment');
    }
    final affected = <String>{};
    final id =
        await _journal.write((db) => _applyClaim(db, c, affected: affected));
    _changed();
    if (id == null) throw StateError('Conflicting Apple claim recorded');
    for (final changed in affected) {
      _schedule(changed);
    }
    _schedule(id);
  }

  Future<void> _resolve(AppleAttemptDecision d) async {
    final c = d.claim;
    if (d.appId != _appId ||
        d.environment != _environment ||
        [d.issuer, d.decisionId, d.attemptId, d.scope, d.orderId, d.reference]
            .any((v) => v.trim().isEmpty) ||
        (d.outcome == AppleAttemptOutcome.paid) != (c != null) ||
        (c != null &&
            (!_validClaim(c) ||
                c.review != null ||
                c.scope != d.scope ||
                c.orderId != d.orderId))) {
      throw StateError('Invalid Apple attempt decision');
    }
    final payload = jsonEncode([
      d.appId,
      d.attemptId,
      d.scope,
      d.orderId,
      d.reference,
      d.outcome.name,
      d.environment,
      d.attemptProof,
      if (c?.disposition case final receipt?) _ackPayload(receipt),
      if (c != null) ...[
        c.appId,
        c.environment,
        c.scope,
        c.orderId,
        c.productId,
        c.reportedTransactionId,
        c.verifiedTransactionId,
        _wire(c.purchaseToken),
        c.reference
      ]
    ]);
    final result = await _journal.write((db) async {
      final a = await _row(db, 'attempt', d.attemptId);
      final prior = (await db.query('decision',
              where: 'issuer=? AND id=?', whereArgs: [d.issuer, d.decisionId]))
          .firstOrNull;
      if (prior != null && prior['payload'] != payload) {
        final original = await _row(db, 'attempt', prior['attemptId']);
        await _conflict(db, null, original, 'decisionConflict', payload);
        if (a != null && original?['id'] != a['id']) {
          await _conflict(db, null, a, 'decisionConflict', payload);
        }
        await db.update('decision', {'result': 'conflict'},
            where: 'issuer=? AND id=?', whereArgs: [d.issuer, d.decisionId]);
        return 'conflict';
      }
      if (prior != null && prior['result'] != 'deferred') {
        return prior['result'] as String;
      }
      if (a == null ||
          a['phase'] == 'prepared' ||
          (a['mode'] == 'scoped' && a['wireToken'] != a['id']) ||
          a['orderId'] != d.orderId ||
          (a['mode'] == 'legacy'
              ? !await _legacyScopeAgrees(db, d.attemptId, d.scope)
              : a['scope'] != d.scope)) {
        throw StateError('Apple attempt identity mismatch');
      }
      if (a['mode'] == 'legacy' &&
          c != null &&
          !(Uuid.isValidUUID(fromString: c.purchaseToken ?? '') &&
              _wire(c.purchaseToken) == _wire(a['wireToken'] as String?)) &&
          ((d.attemptProof?.trim().isEmpty ?? true) ||
              d.attemptProof == d.attemptId)) {
        throw StateError('Independent Apple submission proof required');
      }
      var result = 'recorded';
      if (c != null) {
        if (c.productId != a['productId'] ||
            (c.purchaseToken != null &&
                a['wireToken'] != null &&
                _wire(c.purchaseToken) != _wire(a['wireToken'] as String?))) {
          await _conflict(db, null, a, 'decisionConflict', d.reference);
          result = 'conflict';
        } else {
          final applied = await _applyClaim(db, c, decidedAttempt: a);
          if (applied == null) {
            final dispute = await db.query('purchase',
                columns: ['id'],
                where:
                    'conflict=1 AND disputeRevision>0 AND ((appId=? AND environment=? AND verifiedId=?) OR reportedId=?)',
                whereArgs: [
                  c.appId,
                  c.environment,
                  c.verifiedTransactionId,
                  c.reportedTransactionId
                ],
                limit: 1);
            result = dispute.isEmpty ? 'conflict' : 'deferred';
          } else {
            final charge = await _row(db, 'purchase', applied);
            if (charge?['attemptId'] != d.attemptId) {
              throw StateError(
                  'Apple decision has no confirmed submission binding');
            }
            result = applied;
          }
        }
      } else if (d.outcome == AppleAttemptOutcome.unpaid) {
        if (_launches.containsKey((a['scope'] as String?, d.orderId)) &&
            (a['phase'] == 'prepared' || a['phase'] == 'submitting')) {
          throw StateError('Apple submission is still in progress');
        }
        final positive = await db.query('purchase',
            where: 'attemptId=?', whereArgs: [d.attemptId], limit: 1);
        if (positive.isNotEmpty ||
            a['phase'] == 'paid' ||
            (a['phase'] == 'conflict' && a['reason'] != 'ownershipCorrected')) {
          await _conflict(
              db, positive.firstOrNull, a, 'unpaidAfterPayment', d.reference);
          result = 'conflict';
        } else if (!_unpaidPhase(a['phase'])) {
          await db.update(
              'attempt', {'phase': 'declined', 'reason': 'serverUnpaid'},
              where: 'id=?', whereArgs: [d.attemptId]);
        }
      } else if (_activePhase(a['phase'])) {
        await db.update('attempt', {'reason': 'serverPending'},
            where: 'id=?', whereArgs: [d.attemptId]);
      }
      if (prior == null) {
        await db.insert('decision', {
          'issuer': d.issuer,
          'id': d.decisionId,
          'attemptId': d.attemptId,
          'payload': payload,
          'result': result
        });
      } else {
        await db.update('decision', {'result': result},
            where: 'issuer=? AND id=?', whereArgs: [d.issuer, d.decisionId]);
      }
      return result;
    });
    _changed();
    if (result == 'deferred') {
      throw StateError('Retry Apple attempt decision after dispute review');
    }
    if (result == 'conflict') {
      throw StateError('Conflicting Apple attempt decision recorded');
    }
    if (result != 'recorded') _schedule(result);
  }
}
