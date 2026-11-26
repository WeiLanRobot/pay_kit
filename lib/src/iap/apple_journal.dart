import 'dart:convert';
import 'dart:io';

import 'apple_arbitration_schema.dart';
import 'apple_worker_schema.dart';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// The private SK1 ledger. Operations must contain only database work.
/// SQLite holds the file's exclusive lock until [close], including between
/// transactions. Another connection (even from another engine) cannot write.
class AppleJournal {
  AppleJournal(this._location);

  factory AppleJournal.production() => AppleJournal(() async {
        final support = await getApplicationSupportDirectory();
        return File('${support.path}/pay_kit/apple/ledger.sqlite');
      });

  final Future<File> Function() _location;
  Database? _database;
  String? _selectedPath;

  /// Select one private ledger while holding the common application writer
  /// lock. The original filename remains the first managed environment.
  Future<void> select(String? app, String? environment,
          {Set<String> handoff = const {}}) =>
      _enqueue(() async {
        final base = await _location();
        final previous = _selectedPath;
        final previousFile = _database?.path;
        Future<Database> use(String path) async {
          if (_database?.path == path) return _database!;
          await _database?.close();
          _database = null;
          _selectedPath = path;
          return _open();
        }

        try {
          final main = await use(base.path);
          final header = (await main.query('meta')).single;
          if (app != null &&
              header['appId'] != null &&
              header['appId'] != app) {
            throw StateError('Apple ledger application mismatch');
          }
          await _indexSubmissions(main, base.path, app);
          final String path;
          if (environment == null) {
            path = '${base.path}.compat';
          } else if (header['environment'] == null ||
              header['environment'] == environment) {
            path = base.path;
          } else {
            path = '${base.path}.$environment';
          }
          final target = await use(path);
          final prior = (await target.query('meta')).single;
          if ((prior['appId'] != null && app != prior['appId']) ||
              (prior['environment'] != null &&
                  prior['environment'] != environment)) {
            throw StateError('Apple ledger partition header mismatch');
          }
          final copying = environment != null &&
              previousFile != null &&
              previousFile.endsWith('.compat') &&
              handoff.isNotEmpty;
          if (copying) {
            await target
                .execute('ATTACH DATABASE ? AS compatibility', [previousFile]);
          }
          try {
            await target.transaction((db) async {
              if (copying) {
                await _copySubmissions(db, handoff);
                await _locateCompatibilityCopies(db, 'main', environment);
              }
              if (app != null) {
                await db
                    .update('meta', {'appId': app, 'environment': environment});
              }
            });
          } finally {
            if (copying) await target.execute('DETACH DATABASE compatibility');
          }
        } catch (_) {
          await _database?.close();
          _database = null;
          _selectedPath = previous;
          if (previousFile != null) await use(previousFile);
          rethrow;
        }
      });

  static Future<void> _copySubmissions(
      DatabaseExecutor db, Set<String> ids) async {
    // Only this running legacy receiver generation can move its actual launches.
    for (final id in ids) {
      await db.execute(
          'INSERT INTO attempt SELECT * FROM compatibility.attempt WHERE id=?',
          [id]);
      await db.execute(
          'INSERT INTO purchase SELECT * FROM compatibility.purchase WHERE attemptId=?',
          [id]);
      await db.execute(
          'INSERT OR IGNORE INTO evidence SELECT e.* FROM compatibility.evidence e JOIN compatibility.purchase_evidence x ON e.hash=x.hash JOIN purchase p ON p.id=x.purchaseId WHERE p.attemptId=?',
          [id]);
      await db.execute(
          'INSERT INTO purchase_evidence(purchaseId,hash,rejected,tried,storeObserved) SELECT x.purchaseId,x.hash,x.rejected,x.tried,x.storeObserved FROM compatibility.purchase_evidence x JOIN purchase p ON p.id=x.purchaseId WHERE p.attemptId=?',
          [id]);
      await db.execute(
          'INSERT OR IGNORE INTO evidence_source SELECT e.* FROM compatibility.evidence_source e JOIN purchase_evidence x ON x.hash=e.hash JOIN purchase p ON x.purchaseId=p.id WHERE p.attemptId=?',
          [id]);
      await db.execute(
          'INSERT INTO legacy_handoff SELECT * FROM compatibility.legacy_handoff WHERE attemptId=?',
          [id]);
      await db.execute(
          'INSERT INTO queue_item SELECT * FROM compatibility.queue_item WHERE attemptId=?',
          [id]);
      await db.execute(
          'INSERT INTO order_primary SELECT o.* FROM compatibility.order_primary o JOIN purchase p ON p.id=o.purchaseId WHERE p.attemptId=?',
          [id]);
      await db.execute(
          'INSERT INTO conflict_fact(purchaseId,attemptId,reason,evidenceRef) SELECT f.purchaseId,f.attemptId,f.reason,f.evidenceRef FROM compatibility.conflict_fact f WHERE f.attemptId=? OR f.purchaseId IN (SELECT id FROM purchase WHERE attemptId=?)',
          [id, id]);
    }
  }

  Future<void> _tail = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Database> _open() async {
    final existing = _database;
    if (existing != null) return existing;
    final base = await _location();
    final file = File(_selectedPath ?? base.path);
    await file.parent.create(recursive: true);
    final db = await openDatabase(
      file.path,
      version: 5,
      singleInstance: false,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA busy_timeout = 0');
        await db.rawQuery('PRAGMA locking_mode = EXCLUSIVE');
        await db.rawQuery('PRAGMA journal_mode = DELETE');
        await db.execute('PRAGMA synchronous = FULL');
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA secure_delete = ON');
        await db.execute(
            'ATTACH DATABASE ? AS recovery', ['${base.path}.observations']);
        await db.execute('PRAGMA recovery.synchronous = FULL');
        for (final statement in _recoverySchema) {
          await db.execute(statement);
        }
      },
      onCreate: (db, version) async {
        for (final statement in _schema) {
          await db.execute(statement);
        }
        await _installV3(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 1 || from > 4) {
          throw StateError('Unsupported Apple ledger upgrade');
        }
        if (from == 1) {
          await db.execute(
              'ALTER TABLE attempt ADD COLUMN submittedId TEXT REFERENCES attempt(id)');
          await db.execute(
              "ALTER TABLE attempt ADD COLUMN legacySubmission TEXT CHECK(legacySubmission IN ('accepted','declined','uncertain'))");
          for (final table in ['attempt', 'purchase', 'queue_item']) {
            await db.execute(
                'DROP TRIGGER ${table == 'queue_item' ? 'queue' : table}_identity');
          }
          for (final trigger in [
            _attemptIdentity,
            _purchaseIdentity,
            _queueIdentity
          ]) {
            await db.execute(trigger);
          }
        }
        // The header and foreign keys must be consistent before committing an
        // upgrade, including when this is the application's first launch.
        await _checkHeader(db);
        if (from >= 3) {
          await restoreUnprovenAttempts(db);
          await installReviewedIdentityGuard(db);
          await restoreAppleIdentityDisputes(db);
          return;
        }
        final columns = await db.rawQuery('PRAGMA table_info(purchase)');
        if (!columns.any((c) => c['name'] == 'inputVersion')) {
          await _installV3(db);
        }
        await _quarantineCandidate(db);
        await installReviewedIdentityGuard(db);
        await restoreAppleIdentityDisputes(db);
      },
      onDowngrade: (db, from, to) async {
        throw StateError('Unsupported newer Apple ledger version $from');
      },
      onOpen: (db) async {
        // Claim ownership even when the schema already exists. A failed open
        // releases this connection and preserves the previous owner's data.
        await db.transaction((tx) async {
          await _checkHeader(tx);
        }, exclusive: true);
      },
    );
    return _database = db;
  }

  /// The exclusive owner and local operation queue keep all reads in this
  /// callback on one committed revision, even when it contains awaits.
  Future<T> read<T>(Future<T> Function(DatabaseExecutor db) op) =>
      _enqueue(() async {
        final db = await _open();
        await db.execute('PRAGMA query_only = ON');
        try {
          return await op(db);
        } finally {
          await db.execute('PRAGMA query_only = OFF');
        }
      });

  Future<T> write<T>(Future<T> Function(DatabaseExecutor db) op) =>
      _enqueue(() async {
        final db = await _open();
        return db.transaction((tx) async {
          final result = await op(tx);
          await tx.rawUpdate('UPDATE meta SET revision = revision + 1');
          return result;
        });
      });

  Future<void> close() => _enqueue(() async {
        await _database?.close();
        _database = null;
      });
}

Future<void> _checkHeader(DatabaseExecutor db) async {
  final rows = await db.query('meta');
  final header = rows.length == 1 ? rows.single : null;
  if (header == null ||
      header['singleton'] != 1 ||
      header['revision'] is! int ||
      (header['revision'] as int) < 0 ||
      (header['appId'] == null) != (header['environment'] == null) ||
      header['appId'] != null &&
          (header['appId'] is! String ||
              (header['appId'] as String).trim().isEmpty ||
              !appleEnvironments.contains(header['environment'])) ||
      (await db.rawQuery('PRAGMA quick_check(1)')).single.values.single !=
          'ok' ||
      (await db.rawQuery('PRAGMA recovery.quick_check(1)'))
              .single
              .values
              .single !=
          'ok' ||
      (await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
    throw StateError('Invalid Apple ledger header or integrity');
  }
}

/// Only UUID wire values are case-insensitive in StoreKit.
String appleWireKey(String value) =>
    Uuid.isValidUUID(fromString: value) ? value.toLowerCase() : value;

Future<void> reserveAppleToken(
    DatabaseExecutor db, String wire, String origin, String id) async {
  final token = appleWireKey(wire);
  await db.rawInsert(
      'INSERT OR IGNORE INTO recovery.submission(token,origin,attemptId) VALUES (?,?,?)',
      [token, origin, id]);
  final entries = await db.rawQuery(
      'SELECT origin,attemptId FROM recovery.submission WHERE token=? LIMIT 2',
      [token]);
  if (entries.length != 1 ||
      entries.single['attemptId'] != id ||
      entries.single['origin'] != origin) {
    throw StateError('Apple purchase token already reserved');
  }
}

/// Previously shipped candidates only enforced token uniqueness within each
/// file. Index all existing partitions before any observer can use a receipt.
/// Multiple origins are preserved so known collisions remain unprovable.
Future<void> _indexSubmissions(Database db, String base, String? app) async {
  for (final suffix in [
    '.compat',
    '',
    ...appleEnvironments.map((e) => '.$e')
  ]) {
    final source = suffix.isEmpty ? 'main' : 'prior_partition';
    if (suffix.isNotEmpty) {
      final path = '$base$suffix';
      if (!await File(path).exists()) continue;
      await db.execute('ATTACH DATABASE ? AS prior_partition', [path]);
    }
    try {
      await db.transaction((tx) async {
        final version = (await tx.rawQuery('PRAGMA $source.user_version'))
            .single
            .values
            .single as int;
        final seen = await tx.rawQuery(
            'SELECT version,revision FROM recovery.indexed_partition WHERE name=?',
            [suffix]);
        // First open can leave an empty file before the schema transaction commits.
        if (version == 0 && suffix.isNotEmpty && seen.isEmpty) {
          final objects =
              await tx.rawQuery('SELECT 1 FROM $source.sqlite_master LIMIT 1');
          if (objects.isEmpty) {
            final check = await tx.rawQuery('PRAGMA $source.quick_check(1)');
            if (check.single.values.single == 'ok') return;
          }
        }
        if (version < 1 || version > 5) {
          throw StateError('Unsupported Apple submission ledger version');
        }
        final header = (await tx.rawQuery('SELECT * FROM $source.meta')).single;
        final origin = header['environment'] as String?;
        if (header['appId'] != null && app != null && header['appId'] != app ||
            (origin != null && !appleEnvironments.contains(origin)) ||
            (suffix != '' && suffix != '.compat' && suffix != '.$origin') ||
            suffix == '.compat' && origin != null) {
          throw StateError('Conflicting Apple submission ledger identity');
        }
        // Version 4 writes new reservations in the same transaction as each
        // preparation. Older partitions still need a scan after each revision.
        // Older versions cached .compat without indexing its unhanded receipts.
        final stamp = suffix == '.compat'
            ? 'payments:${header['revision']}'
            : '${header['revision']}';
        if (origin != null) {
          await _locateCompatibilityCopies(tx, source, origin);
        }
        if (seen.isNotEmpty &&
            seen.single['version'] == version &&
            (version >= 4 && suffix != '.compat' ||
                seen.single['revision'] == stamp)) {
          return;
        }
        final attempts =
            await tx.rawQuery("""SELECT id,mode,wireToken FROM $source.attempt
          WHERE wireToken IS NOT NULL AND (mode='legacy' OR wireToken=id COLLATE NOCASE)""");
        for (final a in attempts) {
          await tx.rawInsert(
              'INSERT OR IGNORE INTO recovery.submission VALUES (?,?,?)', [
            appleWireKey(a['wireToken'] as String),
            a['mode'] == 'legacy' ? 'legacy' : origin ?? 'unknown',
            a['id']
          ]);
        }
        if (suffix == '.compat') {
          await _indexCompatibilityPayments(tx, source, version);
        }
        if (suffix == '.compat' && version >= 3) {
          await tx
              .rawInsert("""INSERT OR IGNORE INTO recovery.compatibility_handoff
            (purchaseId,attemptId,wire,sku,orderId,reported,hash)
            SELECT p.id,a.id,a.wireToken,p.productId,a.orderId,p.reportedId,h.hash
              FROM $source.legacy_handoff h JOIN $source.purchase p ON p.id=h.purchaseId
              JOIN $source.attempt a ON a.id=h.attemptId AND p.attemptId=a.id
              WHERE p.disposition='legacyHandedOff' AND p.conflict=0 AND p.reportedId IS NOT NULL
                AND p.productId=a.productId AND p.orderId=a.orderId AND p.token=a.wireToken COLLATE NOCASE
                AND a.mode='legacy' AND a.legacySubmission='accepted'""");
        }
        await tx.rawInsert(
            'INSERT OR REPLACE INTO recovery.indexed_partition VALUES (?,?,?)',
            [suffix, version, stamp]);
      });
    } finally {
      if (suffix.isNotEmpty) {
        await db.execute('DETACH DATABASE prior_partition');
      }
    }
  }
}

// An old receiver may have gone away after submitting and before receiving
// the receipt. Recovery needs the stored evidence even with no SK1 replay.
// No environment, account, native handle or disposition is inferred here.
Future<void> _indexCompatibilityPayments(
    DatabaseExecutor db, String source, int version) async {
  final accepted = version < 2
      ? '0'
      : """EXISTS (
    SELECT 1 FROM $source.attempt a WHERE a.id=p.attemptId AND a.mode='legacy'
      AND a.legacySubmission='accepted' AND a.productId=p.productId
      AND a.orderId=p.orderId AND a.wireToken=p.token COLLATE NOCASE)""";
  await db.execute("""INSERT OR REPLACE INTO recovery.observation
    (id,generation,objectKey,productId,token,reportedId,originalId,status,observedContext,reason)
    SELECT p.id,'compatibility',p.id,p.productId,p.token,p.reportedId,p.originalId,'paid','compat',
      CASE WHEN p.conflict!=0 THEN 'identityConflict'
           WHEN $accepted THEN 'legacySubmissionObserved' ELSE 'sourceUnproven' END
    FROM $source.purchase p WHERE p.disposition IS NULL AND NOT EXISTS (
      SELECT 1 FROM recovery.observation o WHERE o.id=p.id AND
      (o.generation!='compatibility' OR o.boundEnvironment IS NOT NULL OR o.actual IS NOT NULL))""");
  // Keep source records in the compatibility ledger. Only unbound observations
  // need another copy of their receipt bytes on a later index pass.
  final pending = """FROM recovery.observation o
    JOIN $source.purchase_evidence x ON x.purchaseId=o.objectKey
    JOIN $source.evidence e ON e.hash=x.hash
    WHERE o.generation='compatibility' AND o.boundEnvironment IS NULL""";
  await db.execute(
      'INSERT OR IGNORE INTO recovery.body SELECT e.hash,e.body $pending');
  await db.execute("""INSERT OR IGNORE INTO recovery.candidate
    SELECT o.id,e.hash,'store','compat' $pending""");
}

// A live legacy-to-managed handoff copied these exact internal purchase IDs.
// Older ledgers may already contain the copy. Keep one recovery destination;
// a coincidentally matching StoreKit transaction ID is insufficient.
Future<void> _locateCompatibilityCopies(
    DatabaseExecutor db, String source, String environment) async {
  await db.rawUpdate("""UPDATE recovery.observation
    SET boundEnvironment=?,boundPurchase=objectKey
    WHERE generation='compatibility' AND boundEnvironment IS NULL
      AND EXISTS(SELECT 1 FROM $source.purchase p WHERE p.id=observation.objectKey)""",
      [environment]);
}

// Earlier candidates could let an identical StoreKit replay change the UI
// phase after the server had requested more source evidence.
Future<void> restoreUnprovenAttempts(DatabaseExecutor db,
    {String? attemptId}) async {
  await db.rawUpdate("""UPDATE attempt SET phase='uncertain' WHERE phase='paid'
    AND (? IS NULL OR id=?)
    AND EXISTS(SELECT 1 FROM purchase p WHERE p.attemptId=attempt.id AND p.reason='sourceUnproven')
    AND NOT EXISTS(SELECT 1 FROM purchase p WHERE p.attemptId=attempt.id AND
      (p.reason IS NOT 'sourceUnproven' OR p.verifiedId IS NOT NULL OR p.disposition IS NOT NULL OR p.conflict=1))
    AND NOT EXISTS(SELECT 1 FROM attempt x WHERE x.id!=attempt.id AND x.scope IS attempt.scope
      AND x.orderId=attempt.orderId AND x.phase IN ('prepared','submitting','uncertain','accepted','pending'))""",
      [attemptId, attemptId]);
}

const appleEnvironments = {'production', 'sandbox', 'xcode'};

const _recoverySchema = [
  '''CREATE TABLE IF NOT EXISTS recovery.finish_authority(
       generation TEXT NOT NULL, objectKey TEXT NOT NULL, itemId TEXT NOT NULL,
       environment TEXT NOT NULL, basis TEXT NOT NULL,
       PRIMARY KEY(generation,objectKey,itemId,environment,basis))''',
  """CREATE TABLE IF NOT EXISTS recovery.submission(token TEXT NOT NULL, origin TEXT NOT NULL,
      attemptId TEXT NOT NULL, PRIMARY KEY(token,origin,attemptId))""",
  """CREATE TABLE IF NOT EXISTS recovery.indexed_partition(name TEXT PRIMARY KEY,version INTEGER,revision TEXT)""",
  """CREATE TABLE IF NOT EXISTS recovery.compatibility_handoff(purchaseId TEXT PRIMARY KEY,
      attemptId TEXT NOT NULL,wire TEXT NOT NULL,sku TEXT NOT NULL,orderId TEXT NOT NULL,
      reported TEXT NOT NULL,hash TEXT NOT NULL,environment TEXT,scope TEXT,verified TEXT)""",
  """CREATE TABLE IF NOT EXISTS recovery.observation(
    id TEXT PRIMARY KEY, generation TEXT NOT NULL, objectKey TEXT NOT NULL,
    productId TEXT NOT NULL, token TEXT, reportedId TEXT, originalId TEXT,
    queueId TEXT, status TEXT NOT NULL, observedContext TEXT, actual TEXT,
    verifiedId TEXT, proof TEXT, originPurchase TEXT, reason TEXT, boundEnvironment TEXT,
    boundPurchase TEXT, priorIdentity INTEGER DEFAULT 0, originLinked INTEGER DEFAULT 0, finished INTEGER DEFAULT 0, UNIQUE(generation,objectKey))""",
  """CREATE INDEX IF NOT EXISTS recovery.observed_token
    ON observation(token COLLATE NOCASE, productId) WHERE status='paid' AND boundEnvironment IS NULL""",
  """CREATE INDEX IF NOT EXISTS recovery.reported_transaction
    ON observation(reportedId, productId) WHERE status='paid'""",
  """CREATE TABLE IF NOT EXISTS recovery.archive(
    observation TEXT PRIMARY KEY, history TEXT NOT NULL)""",
  """CREATE TABLE IF NOT EXISTS recovery.body(hash TEXT PRIMARY KEY, body TEXT NOT NULL)""",
  """CREATE TABLE IF NOT EXISTS recovery.candidate(observation TEXT NOT NULL, hash TEXT NOT NULL,
    source TEXT NOT NULL, context TEXT NOT NULL, PRIMARY KEY(observation, hash, source, context))""",
  """CREATE INDEX IF NOT EXISTS recovery.candidate_by_hash ON candidate(hash)""",
  """CREATE TRIGGER IF NOT EXISTS recovery.delete_unused_body AFTER DELETE ON candidate BEGIN
    DELETE FROM body WHERE hash=OLD.hash AND NOT EXISTS(SELECT 1 FROM candidate WHERE hash=OLD.hash);
  END""",
];

Future<void> _installV3(DatabaseExecutor db) async {
  for (final sql in [...workerColumns, ...workerTables]) {
    await db.execute(sql);
  }
  await db.execute('ALTER TABLE queue_item ADD COLUMN observation TEXT');
  await installAppleArbitrationSchema(db);
}

Future<void> _quarantineCandidate(DatabaseExecutor db) async {
  final header = (await db.query('meta')).single;
  final others = await db.rawQuery(
      'SELECT id FROM purchase WHERE verifiedId IS NOT NULL AND (appId IS NOT ? OR environment IS NOT ?) LIMIT 1',
      [header['appId'], header['environment']]);
  if (others.isNotEmpty) throw StateError('Apple migration identity conflict');
  final orphaned =
      await db.rawQuery("""SELECT p.* FROM purchase p WHERE p.verifiedId IS NULL
    AND (p.attemptId IS NULL OR NOT EXISTS (SELECT 1 FROM attempt a
      WHERE a.id=p.attemptId AND a.wireToken=p.token AND a.phase!='prepared'))""");
  for (final row in orphaned) {
    final id = row['id'];
    await db.rawInsert("""INSERT OR IGNORE INTO recovery.observation
      (id,generation,objectKey,productId,token,reportedId,originalId,status,observedContext,reason)
      VALUES (?,'candidate',?,?,?,?,?,'paid',?,'migrationSourceUnproven')""", [
      id,
      id,
      row['productId'],
      row['token'],
      row['reportedId'],
      row['originalId'],
      header['environment']
    ]);
    await db.rawInsert(
        """INSERT OR IGNORE INTO recovery.body SELECT e.* FROM evidence e
      JOIN purchase_evidence x ON x.hash=e.hash WHERE x.purchaseId=?""", [id]);
    await db.rawInsert(
        """INSERT OR IGNORE INTO recovery.candidate SELECT purchaseId,hash,'migration',?
      FROM purchase_evidence WHERE purchaseId=?""",
        [header['environment'] ?? 'compat', id]);
    final history = <String, Object?>{'purchase': row};
    for (final table in [
      'queue_item',
      'conflict_fact',
      'purchase_alias',
      'order_primary'
    ]) {
      history[table] =
          await db.query(table, where: 'purchaseId=?', whereArgs: [id]);
    }
    await db.rawInsert('INSERT OR IGNORE INTO recovery.archive VALUES (?,?)',
        [id, jsonEncode(history)]);
    // Preserve existing audit facts, without retaining a routable purchase.
    await db.update('conflict_fact', {'purchaseId': null},
        where: 'purchaseId=?', whereArgs: [id]);
    await db.delete('order_primary', where: 'purchaseId=?', whereArgs: [id]);
    await db.delete('purchase_alias', where: 'purchaseId=?', whereArgs: [id]);
    await db.delete('queue_item', where: 'purchaseId=?', whereArgs: [id]);
    await db
        .delete('purchase_evidence', where: 'purchaseId=?', whereArgs: [id]);
    await db.delete('purchase', where: 'id=?', whereArgs: [id]);
  }
}

const _schema = [
  '''CREATE TABLE meta(
       singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
       revision INTEGER NOT NULL CHECK(revision >= 0),
       appId TEXT, environment TEXT
     )''',
  'INSERT INTO meta(singleton,revision) VALUES (1,0)',
  '''CREATE TABLE attempt(
       id TEXT NOT NULL PRIMARY KEY, scope TEXT, orderId TEXT NOT NULL,
       productId TEXT NOT NULL, wireToken TEXT, mode TEXT NOT NULL,
       phase TEXT NOT NULL, reason TEXT, submittedId TEXT REFERENCES attempt(id),
       legacySubmission TEXT CHECK(legacySubmission IN ('accepted','declined','uncertain')),
       CHECK(length(id)>0 AND length(productId)>0 AND length(orderId)>0),
       CHECK((mode='scoped' AND length(scope)>0 AND scope IS NOT NULL)
             OR (mode='legacy' AND scope IS NULL)),
       CHECK(phase IN ('prepared','submitting','uncertain','accepted','pending',
                       'paid','declined','failed','canceled','conflict'))
     )''',
  'CREATE UNIQUE INDEX attempt_wire ON attempt(wireToken)',
  // SK1 may change UUID case. Arbitrary 1.2.0 order strings are opaque.
  '''CREATE UNIQUE INDEX attempt_uuid_wire ON attempt(wireToken COLLATE NOCASE)
       WHERE length(wireToken)=36 AND substr(wireToken,9,1)='-'
         AND substr(wireToken,14,1)='-' AND substr(wireToken,19,1)='-'
         AND substr(wireToken,24,1)='-' AND length(replace(wireToken,'-',''))=32
         AND lower(replace(wireToken,'-','')) NOT GLOB '*[^0-9a-f]*' ''',
  '''CREATE UNIQUE INDEX attempt_active ON attempt(ifnull(scope,''), orderId)
       WHERE phase IN ('prepared','submitting','uncertain','accepted','pending')''',
  'CREATE INDEX attempt_order ON attempt(scope,orderId)',
  _attemptIdentity,
  '''CREATE TABLE purchase(
       id TEXT NOT NULL PRIMARY KEY, reportedId TEXT, originalId TEXT,
       token TEXT, productId TEXT NOT NULL, attemptId TEXT REFERENCES attempt(id),
       scope TEXT, orderId TEXT, appId TEXT, environment TEXT, verifiedId TEXT,
       ackRef TEXT, claimRef TEXT, disposition TEXT, reason TEXT,
       conflict INTEGER NOT NULL DEFAULT 0 CHECK(conflict IN (0,1)),
       CHECK(length(id)>0 AND length(productId)>0),
       CHECK(verifiedId IS NULL OR (appId IS NOT NULL AND environment IS NOT NULL))
     )''',
  '''CREATE UNIQUE INDEX purchase_verified
       ON purchase(appId,environment,verifiedId) WHERE verifiedId IS NOT NULL''',
  'CREATE INDEX purchase_reported ON purchase(reportedId)',
  'CREATE INDEX purchase_attempt ON purchase(attemptId)',
  'CREATE INDEX purchase_order ON purchase(scope,orderId)',
  '''CREATE TABLE order_primary(
       scope TEXT NOT NULL, orderId TEXT NOT NULL,
       purchaseId TEXT NOT NULL REFERENCES purchase(id), PRIMARY KEY(scope,orderId)
     )''',
  _purchaseIdentity,
  '''CREATE TABLE purchase_alias(
       reportedId TEXT NOT NULL PRIMARY KEY,
       purchaseId TEXT NOT NULL REFERENCES purchase(id), claimRef TEXT NOT NULL
     )''',
  '''CREATE TRIGGER alias_identity BEFORE UPDATE ON purchase_alias
       BEGIN SELECT RAISE(ABORT,'Immutable trusted Apple alias'); END''',
  '''CREATE TABLE queue_item(
       id TEXT NOT NULL PRIMARY KEY, purchaseId TEXT REFERENCES purchase(id),
       attemptId TEXT REFERENCES attempt(id), status TEXT NOT NULL,
       finished INTEGER NOT NULL DEFAULT 0 CHECK(finished IN (0,1)),
       productId TEXT NOT NULL, token TEXT, reportedId TEXT, originalId TEXT,
       storeQueueId TEXT UNIQUE, reason TEXT
     )''',
  'CREATE INDEX queue_purchase ON queue_item(purchaseId)',
  'CREATE INDEX queue_attempt ON queue_item(attemptId)',
  _queueIdentity,
  '''CREATE TABLE evidence(
       hash TEXT NOT NULL PRIMARY KEY, body TEXT NOT NULL
     )''',
  '''CREATE TABLE purchase_evidence(
       seq INTEGER PRIMARY KEY AUTOINCREMENT,
       purchaseId TEXT NOT NULL REFERENCES purchase(id),
       hash TEXT NOT NULL REFERENCES evidence(hash),
       rejected INTEGER NOT NULL DEFAULT 0 CHECK(rejected IN (0,1)),
       tried INTEGER NOT NULL DEFAULT 0 CHECK(tried IN (0,1)),
       UNIQUE(purchaseId,hash)
     )''',
  'CREATE INDEX evidence_references ON purchase_evidence(hash)',
  '''CREATE TRIGGER evidence_gc AFTER DELETE ON purchase_evidence
       BEGIN
         DELETE FROM evidence WHERE hash=OLD.hash AND NOT EXISTS
           (SELECT 1 FROM purchase_evidence WHERE hash=OLD.hash);
       END''',
  '''CREATE TABLE decision(
       issuer TEXT NOT NULL, id TEXT NOT NULL, attemptId TEXT NOT NULL REFERENCES attempt(id),
       payload TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(issuer,id)
     )''',
  '''CREATE TABLE conflict_fact(
       id INTEGER PRIMARY KEY, purchaseId TEXT REFERENCES purchase(id),
       attemptId TEXT REFERENCES attempt(id), reason TEXT NOT NULL,
       evidenceRef TEXT
     )''',
  '''CREATE UNIQUE INDEX conflict_dedupe ON conflict_fact(
       ifnull(purchaseId,''),ifnull(attemptId,''),reason,ifnull(evidenceRef,'')
     )''',
];

const _attemptIdentity =
    '''CREATE TRIGGER attempt_identity BEFORE UPDATE ON attempt
       WHEN OLD.id IS NOT NEW.id OR OLD.scope IS NOT NEW.scope
         OR OLD.orderId IS NOT NEW.orderId OR OLD.productId IS NOT NEW.productId
         OR (OLD.submittedId IS NOT NEW.submittedId AND
             (OLD.submittedId IS NOT NULL OR OLD.mode!='scoped' OR OLD.reason IS NOT 'recovered'
              OR OLD.wireToken IS NOT NULL OR NOT EXISTS(
                SELECT 1 FROM attempt s WHERE s.id=NEW.submittedId AND s.id!=OLD.id
                  AND s.scope=OLD.scope AND s.orderId=OLD.orderId AND s.productId=OLD.productId
                  AND s.wireToken=s.id AND s.submittedId IS NULL)))
         OR OLD.wireToken IS NOT NEW.wireToken OR OLD.mode IS NOT NEW.mode
       BEGIN SELECT RAISE(ABORT,'Immutable Apple attempt identity'); END''';

const _purchaseIdentity =
    '''CREATE TRIGGER purchase_identity BEFORE UPDATE ON purchase
       WHEN OLD.id IS NOT NEW.id OR OLD.productId IS NOT NEW.productId
         OR (OLD.attemptId IS NOT NULL AND OLD.attemptId IS NOT NEW.attemptId AND
             NOT EXISTS(SELECT 1 FROM attempt a WHERE a.id=OLD.attemptId
                         AND a.submittedId=NEW.attemptId))
         OR (OLD.scope IS NOT NULL AND OLD.scope IS NOT NEW.scope)
         OR (OLD.orderId IS NOT NULL AND OLD.orderId IS NOT NEW.orderId)
         OR (OLD.appId IS NOT NULL AND OLD.appId IS NOT NEW.appId)
         OR (OLD.environment IS NOT NULL AND OLD.environment IS NOT NEW.environment)
         OR (OLD.verifiedId IS NOT NULL AND OLD.verifiedId IS NOT NEW.verifiedId)
         OR (OLD.reportedId IS NOT NULL AND OLD.reportedId IS NOT NEW.reportedId)
         OR (OLD.originalId IS NOT NULL AND OLD.originalId IS NOT NEW.originalId)
         OR (OLD.token IS NOT NULL AND OLD.token IS NOT NEW.token)
         OR (OLD.ackRef IS NOT NULL AND OLD.ackRef IS NOT NEW.ackRef)
         OR (OLD.claimRef IS NOT NULL AND OLD.claimRef IS NOT NEW.claimRef)
         OR (OLD.disposition IS NOT NULL AND OLD.disposition IS NOT NEW.disposition)
       BEGIN SELECT RAISE(ABORT,'Conflicting Apple purchase binding'); END''';

const _queueIdentity =
    '''CREATE TRIGGER queue_identity BEFORE UPDATE ON queue_item
       WHEN OLD.id IS NOT NEW.id OR OLD.productId IS NOT NEW.productId
         OR OLD.finished > NEW.finished
         OR (OLD.storeQueueId IS NOT NULL AND OLD.storeQueueId IS NOT NEW.storeQueueId)
         OR (OLD.attemptId IS NOT NULL AND OLD.attemptId IS NOT NEW.attemptId AND
             NOT EXISTS(SELECT 1 FROM attempt a WHERE a.id=OLD.attemptId
                         AND a.submittedId=NEW.attemptId))
         OR (OLD.token IS NOT NULL AND OLD.token IS NOT NEW.token)
         OR (OLD.reportedId IS NOT NULL AND OLD.reportedId IS NOT NEW.reportedId)
         OR (OLD.originalId IS NOT NULL AND OLD.originalId IS NOT NEW.originalId)
       BEGIN SELECT RAISE(ABORT,'Conflicting Apple queue evidence'); END''';
