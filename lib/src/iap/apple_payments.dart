import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'apple_journal.dart';
import 'apple_models.dart';
import 'apple_store.dart';

export 'apple_models.dart';
part 'apple_delivery.dart';
part 'apple_environment.dart';

typedef _Legacy = ({
  Future<void> Function(String)? receive,
  void Function(String?, StoreStatus) status,
  void Function(Object) error
});
typedef _Row = Map<String, Object?>;
typedef _Launch = ({
  String product,
  String? token,
  Object owner,
  Future<AppleOrderSnapshot> operation,
  Future<AppleOrderSnapshot> future
});

// Object identity distinguishes successive calls even for identical inputs.
class _VerificationCall {
  _VerificationCall(this.account, this.version, this.hash);
  final AppleAccount account;
  final int version;
  final String hash;
  final retired = Completer<void>();
  void retire() {
    if (!retired.isCompleted) retired.complete();
  }
}

enum _CandidateResult { stop, rejected, retry }

class AppleAccount {
  AppleAccount._(this._payments, this.scope, this._verify);
  final ApplePayments _payments;
  final String scope;
  final String _generation = const Uuid().v4();
  final Future<AppleVerification> Function(AppleReceipt) _verify;

  Future<AppleOrderSnapshot> buy(
          {required String productId,
          required String orderId,
          String? purchaseToken}) =>
      _payments._buy(this, null, productId, orderId, purchaseToken);

  Future<AppleOrderSnapshot?> lookup(String orderId) async {
    _requireActive();
    final result = await _payments._snapshot(scope, orderId);
    _requireActive();
    return result;
  }

  Stream<AppleOrderSnapshot?> watch(String orderId) =>
      _payments._watch(this, orderId);

  void _requireActive() {
    if (!identical(_payments._account, this)) {
      throw StateError('Apple account has signed out');
    }
  }

  void dispose() {
    if (identical(_payments._account, this)) {
      _payments._account = null;
      for (final call in _payments._calls.values) {
        if (identical(call.account, this)) call.retire();
      }
      _payments._changed();
    }
  }
}

/// One owner for this application's StoreKit 1 consumable queue.
class ApplePayments {
  ApplePayments._(
    this._store,
    this._journal, {
    Duration verificationTimeout = const Duration(seconds: 30),
    Timer Function(Duration, void Function())? timerFactory,
  })  : _verificationTimeout = verificationTimeout,
        _timer = timerFactory ?? Timer.new;
  final Duration _verificationTimeout;
  final Timer Function(Duration, void Function()) _timer;
  static final instance =
      ApplePayments._(StoreKitAppleStore(), AppleJournal.production());

  @visibleForTesting
  factory ApplePayments.forTesting(AppleStore store, AppleJournal journal,
          {Duration verificationTimeout,
          Timer Function(Duration, void Function())? timerFactory}) =
      ApplePayments._;

  final AppleStore _store;
  final AppleJournal _journal;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast();
  final _legacy = <Object, _Legacy>{};
  final _origin = <String, Object>{};
  final _legacyDelivering = <String>{};
  final _legacyBusy = <Object, String>{};
  final _launches = <(String?, String), _Launch>{};
  final _live = <String, StoreEvent>{};
  final _handleAliases = <String, String>{};
  final _observationIds = Expando<String>();
  final _closingItems = <String, Future<void>>{};
  final _calls = <String, _VerificationCall>{};
  final _cooldowns = <String, (String, int)>{};
  final _responding = <Future<_CandidateResult>>{};
  Future<void>? _checkingCalls;
  bool _checkAgain = false;
  final _workers = <String, Future<void>>{};
  final _dirty = <String>{};
  final _timers = <String, Timer>{};
  final _delays = <String, int>{};
  final _unwritten = <StoreEvent>{};
  // A native result may outlive a failed disk write. Retain its exact transition.
  final _launchResults = <String, String>{};
  Future<void> _events = Future.value();
  Future<void> _activation = Future.value();
  Future<void>? _boot, _configuration;
  StreamSubscription<List<StoreEvent>>? _subscription;
  AppleAccount? _account;
  String? _appId, _environment;
  bool _closed = false;
  bool _configured = false;
  Stream<Object> get errors => _errors.stream;

  final _generation = const Uuid().v4();
  final _submittedHere = <String>{};
  final _currentUnbound = <String, StoreEvent>{};
  final _observedHere = <String>{};
  List<StoreEvent>? _buffer;
  final _heldWork = <String>{};
  bool _ready = false, _managedRequested = false;

  /// Use the running application's bundle identifier in the selected store environment.
  Future<void> start({required String environment}) {
    if (_closed) throw StateError('Apple payments closed');
    _managedRequested = true;
    if (!appleEnvironments.contains(environment)) {
      throw ArgumentError('Expected production, sandbox or xcode');
    }
    if (_environment != null && _environment != environment) {
      throw StateError('Apple service identity already configured');
    }
    _environment = environment;
    return _configuration ??=
        _configure(environment).catchError((Object error) {
      _configuration = null;
      _appId = _environment = null;
      throw error;
    });
  }

  Future<void> _configure(String environment) async {
    final app = await _store.bundleIdentifier();
    if (app.trim().isEmpty) {
      throw StateError('Missing StoreKit application identity');
    }
    _appId = app;
    final legacyBoot = _boot;
    if (legacyBoot != null) await legacyBoot;
    if (_closed) throw StateError('Apple payments closed');
    if (_ready) {
      // A legal legacy session remains the owner if managed binding fails.
      // Never await a host callback or native call that may itself request start.
      _buffer = [];
      try {
        await _events;
        if (_launches.isNotEmpty ||
            _workers.isNotEmpty ||
            _closingItems.isNotEmpty ||
            _launchResults.isNotEmpty) {
          throw StateError(
              'Legacy payment work in progress; retry managed startup');
        }
        await _journal.select(app, environment, handoff: _submittedHere);
        _configured = true;
      } finally {
        _drainBuffer();
      }
    } else {
      await _open(app, environment);
    }
  }

  Future<void> _ensureStarted() {
    if (_closed) throw StateError('Apple payments closed');
    if (_ready && _buffer != null && _configuration != null) {
      return _configuration!;
    }
    if (_ready) return Future.value();
    if (_configuration != null) return _configuration!;
    if (_managedRequested || _legacy.isEmpty) {
      throw StateError('Apple payments not started');
    }
    return _boot ??= _open(null, null).catchError((Object error) {
      _boot = null;
      throw error;
    });
  }

  void _drainBuffer() {
    final buffered = _buffer;
    _buffer = null;
    for (final event in buffered ?? const <StoreEvent>[]) {
      _queueEvent(event);
    }
    final work = _heldWork.toList();
    _heldWork.clear();
    for (final id in work) {
      _schedule(id);
    }
  }

  Future<void> _open(String? app, String? environment) async {
    final store = _store;
    final lifecycle =
        store is AppleStoreLifecycle ? store as AppleStoreLifecycle : null;
    bool registrationAttempted = false;
    try {
      await _journal.select(app, environment);
      if (_closed) throw StateError('Apple payments closed');
      _buffer = [];
      _subscription = store.events.listen((batch) {
        if (_closed) return;
        final buffered = _buffer;
        if (buffered != null) {
          buffered.addAll(batch);
        } else if (_ready) {
          for (final event in batch) {
            _queueEvent(event);
          }
        }
      }, onError: (Object error) => _report(error));
      if (lifecycle != null) {
        registrationAttempted = true;
        await lifecycle.start();
        await lifecycle.snapshot();
      }
      if (_closed) throw StateError('Apple payments closed');
      _configured = environment != null;
      _ready = true;
      _drainBuffer();
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      _ready = _configured = false;
      _buffer = null;
      try {
        if (registrationAttempted) await lifecycle!.stop();
      } finally {
        await _journal.close();
      }
      rethrow;
    }
  }

  AppleAccount connect(
      {required String scope,
      required Future<AppleVerification> Function(AppleReceipt) verify}) {
    if (!_configured || _closed) {
      throw StateError(
          'Await ApplePayments.start with the application identity before login');
    }
    if (scope.trim().isEmpty) throw ArgumentError('scope must be non-empty');
    _account?.dispose();
    final account = _account = AppleAccount._(this, scope, verify);
    _activation = _activate(account).catchError((Object error) {
      _report(error);
    });
    return account;
  }

  Future<void> _activate(AppleAccount account) async {
    final rows = await _journal.read((db) => db.query('purchase',
        columns: ['id'],
        where: 'scope=? AND disposition IS NULL',
        whereArgs: [account.scope]));
    if (!identical(_account, account)) return;
    for (final row in rows) {
      // The binding is a new verifier generation, also for the same scope.
      _schedule(row['id'] as String);
    }
  }

  void _report(Object error) {
    if (!_closed) {
      _errors.add(
          StateError('Apple payment operation failed (${error.runtimeType})'));
    }
  }

  void _changed() {
    if (!_closed) {
      _changes.add(null);
      _checkCalls();
    }
  }

  // A merge can invalidate either the source or the surviving purchase. Check
  // the actual rows after commit, including when the old verifier never returns.
  void _checkCalls() {
    if (_calls.isEmpty || _closed) return;
    if (_checkingCalls != null) {
      _checkAgain = true;
      return;
    }
    _checkingCalls = Future<void>(() async {
      do {
        _checkAgain = false;
        for (final entry in _calls.entries.toList()) {
          final call = entry.value;
          final row =
              await _journal.read((db) => _row(db, 'purchase', entry.key));
          if (identical(_calls[entry.key], call) &&
              (row == null ||
                  row['inputVersion'] != call.version ||
                  row['disposition'] != null ||
                  _chargeOnHold(row))) {
            call.retire();
            _dirty.add(entry.key);
          }
        }
      } while (_checkAgain && !_closed);
    }).catchError((Object error) {
      _report(error);
    }).whenComplete(() => _checkingCalls = null);
  }

  void _background(Future<void> work) {
    unawaited(work.catchError((Object error) {
      _report(error);
    }));
  }

  @internal
  void attachLegacy(
      Object owner,
      Future<void> Function(String)? receiver,
      void Function(String?, StoreStatus) onStatus,
      void Function(Object) onError) {
    _legacy[owner] = (receive: receiver, status: onStatus, error: onError);
    _background(retryPending().catchError((Object error) {
      _legacy[owner]?.error(error);
      throw error;
    }));
  }

  @internal
  void detachLegacy(Object owner) {
    _legacy.remove(owner);
    _legacyBusy.remove(owner);
    _origin.removeWhere((_, value) => identical(value, owner));
  }

  @internal
  Future<void> buyLegacy(Object owner, String productId, String orderId) async {
    if (_legacy[owner]?.receive == null) {
      throw StateError('A legacy receipt receiver is required to purchase');
    }
    final snapshot = await _buy(null, owner, productId, orderId, null);
    if (snapshot.phase == 'declined') throw const StorePurchaseRejected();
    if (snapshot.phase == 'uncertain' || snapshot.phase == 'conflict') {
      throw const StoreSubmissionUnresolved();
    }
  }

  bool _attached(AppleAccount? account, Object? owner) => account != null
      ? identical(_account, account)
      : _legacy.containsKey(owner);

  Future<AppleOrderSnapshot> _buy(AppleAccount? account, Object? legacyOwner,
      String productId, String orderId, String? suppliedToken) {
    try {
      if (orderId.trim().isEmpty || productId.trim().isEmpty) {
        throw ArgumentError('orderId and productId are required');
      }
      if (!_attached(account, legacyOwner)) {
        throw StateError('Payment session ended');
      }
      final token = suppliedToken?.toLowerCase();
      if (token != null && !Uuid.isValidUUID(fromString: token)) {
        throw ArgumentError('purchaseToken must be a UUID');
      }
      final key = (account?.scope, orderId);
      final active = _launches[key];
      final owner = account ?? legacyOwner!;
      if (active != null) {
        if (active.product != productId ||
            active.token != token ||
            (legacyOwner != null && !identical(active.owner, owner))) {
          throw StateError('Conflicting purchase request');
        }
        if (identical(active.owner, owner)) return active.future;
        final visible = active.operation.whenComplete(account!._requireActive);
        _launches[key] = (
          product: productId,
          token: token,
          owner: owner,
          operation: active.operation,
          future: visible
        );
        return visible;
      }
      if (legacyOwner != null && _legacyBusy[legacyOwner] != null) {
        throw StateError('Previous purchase is being submitted');
      }
      if (legacyOwner != null) _legacyBusy[legacyOwner] = orderId;

      final operation = _launch(account, legacyOwner, productId, orderId, token)
          .whenComplete(() {
        _launches.remove(key);
        if (legacyOwner != null) _legacyBusy.remove(legacyOwner);
      });
      final job = account == null
          ? operation
          : operation.whenComplete(account._requireActive);
      _launches[key] = (
        product: productId,
        token: token,
        owner: owner,
        operation: operation,
        future: job
      );
      return job;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<AppleOrderSnapshot> _launch(AppleAccount? account, Object? owner,
      String product, String order, String? requested) async {
    await (account == null ? _ensureStarted() : _configuration!);
    final scope = account?.scope;
    Future<({String? preparedId})?> existing(DatabaseExecutor db) async {
      if (!_attached(account, owner)) throw StateError('Payment session ended');
      final rows = await db.rawQuery(
          """SELECT * FROM attempt WHERE scope IS ? AND orderId=? AND submittedId IS NULL
              AND (mode='legacy' OR wireToken=id COLLATE NOCASE)
              ORDER BY rowid DESC LIMIT 1""", [scope, order]);
      final prior = rows.firstOrNull;
      if (scope != null) {
        final charges = await db.query('purchase',
            columns: ['productId'],
            where: 'scope=? AND orderId=?',
            whereArgs: [scope, order]);
        if (charges.any((charge) => charge['productId'] != product)) {
          throw StateError('Order product changed');
        }
        // A server-confirmed order can predate this installation.
        if (charges.isNotEmpty) return (preparedId: null);
        final dispute = await _disputedProduct(db, scope, order);
        if (dispute != null) {
          if (dispute != product) throw StateError('Order product changed');
          return (preparedId: null);
        }
      }
      if (prior != null) {
        if (prior['productId'] != product) {
          throw StateError('Order product changed');
        }
        if (owner != null && !identical(_origin[prior['id']], owner)) {
          throw StateError('Original legacy receiver unavailable');
        }
        if (owner != null && prior['legacySubmission'] == 'declined') {
          throw const StorePurchaseRejected();
        }
        if (const {'canceled', 'failed', 'declined'}.contains(prior['phase'])) {
          if (owner != null) {
            throw StateError('A new legacy order ID is required');
          }
          return null;
        }
        if (owner != null && prior['legacySubmission'] == 'uncertain') {
          throw const StoreSubmissionUnresolved();
        }
        if (requested != null && prior['wireToken'] != requested) {
          throw StateError('Attempt token changed');
        }
        return (
          preparedId:
              prior['phase'] == 'prepared' ? prior['id'] as String : null
        );
      }
      if (owner != null) {
        for (final entry in _origin.entries
            .where((e) => identical(e.value, owner))
            .toList()) {
          final unresolved = await db.rawQuery('''
            SELECT id FROM attempt a WHERE id=? AND legacySubmission IS NOT 'declined'
            AND phase NOT IN ('canceled','failed','declined') AND NOT EXISTS (
                SELECT 1 FROM purchase p WHERE p.attemptId=a.id AND p.conflict=0 AND
                  (p.disposition='legacyHandedOff' OR
                   (p.claimRef IS NOT NULL AND p.verifiedId IS NOT NULL AND p.disposition IS NOT NULL)))
          ''', [entry.key]);
          if (unresolved.isNotEmpty) {
            throw const StoreSubmissionUnresolved();
          }
        }
      }
      return null;
    }

    final prior = await _journal.read(existing);
    if (prior != null && prior.preparedId == null) {
      return (await _snapshot(scope, order))!;
    }
    await _store.prepare(product);
    final id = await _journal.write((db) async {
      final row = await existing(db);
      if (row != null) return row.preparedId;
      final id = requested ?? const Uuid().v4();
      final wire = owner == null ? id : order;
      final isUuid = Uuid.isValidUUID(fromString: wire);
      final compare = isUuid ? 'COLLATE NOCASE' : '';
      final occupied = await db.rawQuery('''
        SELECT 1 FROM attempt WHERE wireToken=? $compare UNION ALL
        SELECT 1 FROM purchase WHERE token=? $compare UNION ALL
        SELECT 1 FROM queue_item WHERE token=? $compare UNION ALL
        SELECT 1 FROM recovery.observation WHERE token=? $compare LIMIT 1''',
          [wire, wire, wire, wire]);
      if (occupied.isNotEmpty) {
        throw StateError('Purchase token was already observed');
      }
      await reserveAppleToken(
          db, wire, owner == null ? _environment! : 'legacy', id);
      await db.insert('attempt', {
        'id': id,
        'scope': scope,
        'orderId': order,
        'productId': product,
        'wireToken': wire,
        'mode': owner == null ? 'scoped' : 'legacy',
        'phase': 'prepared'
      });
      return id;
    });
    if (id == null) return (await _snapshot(scope, order))!;
    if (owner != null && _legacy.containsKey(owner)) _origin[id] = owner;
    _changed();
    final submit = await _journal.write((db) async {
      if (!_attached(account, owner)) {
        await db.update('attempt', {'phase': 'declined'},
            where: "id=? AND phase='prepared'", whereArgs: [id]);
        return false;
      }
      // Between preparation and submission an earlier attempt may have received
      // positive evidence. A local retry must not create another charge then.
      final otherFacts = await db.rawQuery("""
        SELECT id FROM attempt WHERE scope IS ? AND orderId=? AND id<>? AND phase IN ('conflict','paid')
        UNION ALL SELECT id FROM purchase WHERE scope IS ? AND orderId=? LIMIT 1
        """, [scope, order, id, scope, order]);
      if (otherFacts.isNotEmpty ||
          (scope != null && await _disputedProduct(db, scope, order) != null)) {
        // No native call was made. The charge or open dispute now supplies the
        // order snapshot; a superseded preparation is not a real submission.
        await db.delete('attempt',
            where: "id=? AND phase='prepared'", whereArgs: [id]);
        return false;
      }
      await reserveAppleToken(db, owner == null ? id : order,
          owner == null ? _environment! : 'legacy', id);
      return await db.update('attempt', {'phase': 'submitting'},
              where: "id=? AND phase='prepared'", whereArgs: [id]) ==
          1;
    });
    if (submit && _ready && !_closed && _attached(account, owner)) {
      _submittedHere.add(id);
      String phase;
      try {
        phase = await _store.purchase(product, owner == null ? id : order)
            ? 'accepted'
            : 'declined';
      } on StorePurchaseRejected {
        phase = 'declined';
      } catch (_) {
        phase = 'uncertain';
      }
      _launchResults[id] = phase;
      await _saveLaunchResult(id, phase);
      // The queue may have changed the order while the channel reply was pending.
      if (owner != null && phase == 'declined') {
        throw const StorePurchaseRejected();
      }
      if (owner != null && phase == 'uncertain') {
        throw const StoreSubmissionUnresolved();
      }
    } else if (submit) {
      // No native call was made after the session ended.
      _launchResults[id] = 'declined';
      await _saveLaunchResult(id, 'declined');
    }
    _changed();
    return (await _snapshot(scope, order))!;
  }

  Future<void> _saveLaunchResult(String id, String phase) async {
    try {
      final result = await _journal.write((db) async {
        await db.update('attempt', {'phase': phase},
            where: "id=? AND phase='submitting'", whereArgs: [id]);
        final attempt = await _row(db, 'attempt', id);
        final paid = <String>[];
        StoreStatus? terminal;
        if (attempt != null &&
            attempt['mode'] == 'legacy' &&
            attempt['legacySubmission'] == null) {
          // The native reply belongs to this invocation. A queue observation
          // with the same business string can predate it or disagree with it.
          await db.update('attempt', {'legacySubmission': phase},
              where: 'id=?', whereArgs: [id]);
          final observed = await db.query('purchase',
              where: 'attemptId=? AND disposition IS NULL', whereArgs: [id]);
          if (phase == 'accepted') {
            paid.addAll(observed.map((p) => p['id'] as String));
            if (attempt['phase'] == 'accepted') {
              final queue = await db.query('queue_item',
                  columns: ['status'],
                  where:
                      "attemptId=? AND status IN ('pending','canceled','failed')",
                  whereArgs: [id],
                  orderBy:
                      "CASE WHEN status='pending' THEN 1 ELSE 0 END, rowid",
                  limit: 1);
              if (queue.isNotEmpty) {
                final status =
                    StoreStatus.values.byName(queue.single['status'] as String);
                await db.update('attempt',
                    {'phase': status.name, 'reason': 'store_${status.name}'},
                    where: 'id=?', whereArgs: [id]);
                if (status != StoreStatus.pending) terminal = status;
              }
            }
          } else if (phase == 'declined') {
            for (final purchase in observed) {
              await _conflict(db, purchase, attempt, 'paymentAfterUnpaid', id);
            }
          }
        }
        return (
          paid: paid,
          terminal: terminal,
          token: attempt?['wireToken'] as String?
        );
      });
      _launchResults.remove(id);
      for (final purchaseId in result.paid) {
        _schedule(purchaseId);
      }
      if (result.terminal != null) {
        try {
          _legacy[_origin[id]]?.status(result.token, result.terminal!);
        } catch (error) {
          _report(error);
        }
      }
      _changed();
    } catch (_) {
      _defer('storage', retryPending);
      rethrow;
    }
  }

  void _queueEvent(StoreEvent event) {
    if (_buffer case final pending?) {
      pending.add(event);
      return;
    }
    _unwritten.add(event);
    _events = _events.then((_) async {
      if (_closed || !_unwritten.contains(event)) return;
      try {
        if (!_ready) return;
        await _ingest(event);
        _unwritten.remove(event);
      } catch (error) {
        _report(error);
        _defer('storage', retryPending);
      }
    });
  }

  void _defer(String key, Future<void> Function() work) {
    if (_closed || _timers.containsKey(key)) return;
    final delay = _delays[key] ?? 1;
    _delays[key] = (delay * 2).clamp(1, 300);
    _timers[key] = _timer(Duration(seconds: delay), () {
      _timers.remove(key);
      if (!_closed) _background(work());
    });
  }

  void _retryLater(String id) => _defer('purchase/$id', () async {
        _cooldowns.remove(id);
        _schedule(id);
      });

  void _schedule(String id) {
    if (_closed) return;
    if (_buffer != null) {
      _heldWork.add(id);
      return;
    }
    if (_workers.containsKey(id)) {
      _dirty.add(id);
      _checkCalls();
      return;
    }
    _workers[id] = Future<void>(() async {
      try {
        do {
          _dirty.remove(id);
          try {
            await _processPurchase(id);
          } catch (error) {
            _report(error);
            _retryLater(id);
          }
        } while (!_closed && _dirty.remove(id));
      } finally {
        _workers.remove(id);
      }
    });
  }

  /// Enqueue existing work. This may safely be called from the verifier itself.
  Future<void> retryPending() async {
    await _ensureStarted();
    for (final entry in _launchResults.entries.toList()) {
      await _saveLaunchResult(entry.key, entry.value);
    }
    for (final event in _unwritten.toList()) {
      _queueEvent(event);
    }
    final rows = await _journal.read((db) => db.rawQuery('''
      SELECT id FROM purchase p WHERE disposition IS NULL OR EXISTS (
        SELECT 1 FROM queue_item q WHERE q.purchaseId=p.id AND q.finished=0)
    '''));
    // An explicit retry inside the current verifier must not perpetually requeue itself.
    for (final row in rows) {
      final id = row['id'] as String;
      if (!_workers.containsKey(id)) _schedule(id);
    }
    for (final entry in _currentUnbound.entries.toList()) {
      if (entry.value.status == StoreStatus.failed ||
          entry.value.status == StoreStatus.canceled) {
        _background(_finishUnbound(entry.key));
      }
    }
    for (final event in _live.values.toList()) {
      if (event.status == StoreStatus.failed ||
          event.status == StoreStatus.canceled) {
        _queueEvent(event);
      }
    }
  }

  Future<void> refreshReceipts() async {
    final context = _configuration;
    if (!_configured || _closed || context == null) {
      throw StateError('Application identity required');
    }
    await _events;
    final targets = await _journal.read((db) async {
      final rows = await db.query('purchase',
          columns: ['id'], where: 'disposition IS NULL');
      return (
        purchases: rows.map((r) => r['id'] as String).toSet(),
        unbound: await _captureUnboundRefresh(db)
      );
    });
    if (_closed || !identical(_configuration, context)) return;
    final body = await _store.refreshReceipt();
    if (body == null ||
        body.isEmpty ||
        _closed ||
        !identical(_configuration, context)) {
      return;
    }
    // Include store events already delivered to our stream during the request.
    await _events;
    if (_closed || !identical(_configuration, context)) return;
    await _refreshEvidence(context, targets.purchases, targets.unbound, body);
  }

  Future<void> reconcile(AppleClaim claim) async {
    if (_configuration == null) {
      throw StateError('Application identity required');
    }
    await _configuration;
    if (!_ready || _closed) throw StateError('Application identity required');
    await _reconcile(claim);
  }

  Future<void> resolveAttempt(AppleAttemptDecision decision) async {
    if (_configuration == null) {
      throw StateError('Application identity required');
    }
    await _configuration;
    if (!_ready || _closed) throw StateError('Application identity required');
    await _resolve(decision);
  }

  /// Enumerate unresolved submissions even when Apple has supplied no transaction.
  /// Only the authenticated application recovery service should consume this list.
  Future<List<AppleRecoveryAttempt>> unresolvedAttempts() async {
    if (!_configured || _closed) {
      throw StateError('Application identity required');
    }
    return _journal.read((db) async {
      final rows = await db.rawQuery('''
        SELECT * FROM attempt WHERE submittedId IS NULL AND (mode='legacy' OR wireToken=id COLLATE NOCASE) AND phase IN ('submitting','accepted','pending','uncertain','conflict')
        ORDER BY rowid
      ''');
      return [
        for (final row in rows)
          (
            attemptId: row['id'] as String,
            scope: row['scope'] as String?,
            orderId: row['orderId'] as String,
            productId: row['productId'] as String,
            submittedToken: row['wireToken'] as String?,
            phase: row['phase'] == 'submitting'
                ? 'uncertain'
                : row['phase'] as String,
            reason: row['reason'] as String?
          )
      ];
    });
  }

  /// Only expose to the trusted application-level recovery service.
  Future<List<AppleTransaction>> unmatched() async {
    if (!_configured || _closed) {
      throw StateError('Application identity required');
    }
    return _journal.read((db) async {
      final rows = await db.rawQuery('''
        SELECT * FROM purchase WHERE conflict=1 OR disposition IS NULL AND
        (scope IS NULL OR reportedId IS NULL OR conflict=1 OR reason='needsReconciliation')
        ORDER BY rowid''');
      final groups = <(String?, String, String?), List<_Row>>{};
      for (final row in rows) {
        // An unresolved group conveys uncertainty. Its members retain separate
        // identities and are never consumed together by the delivery worker.
        final key = (
          row['reportedId'] == null && row['conflict'] == 0
              ? null
              : row['id'] as String,
          row['productId'] as String,
          row['token'] as String?
        );
        (groups[key] ??= []).add(row);
      }
      final result = <AppleTransaction>[];
      for (final group in groups.values) {
        final row = group.first;
        final observations = <String, List<String>>{};
        for (final member in group) {
          final receipts = await db.rawQuery('''
            SELECT body FROM evidence JOIN purchase_evidence ON evidence.hash=purchase_evidence.hash
            WHERE purchaseId=? ORDER BY seq''', [member['id']]);
          observations[member['id'] as String] =
              List.unmodifiable(receipts.map((r) => r['body'] as String));
        }
        final revision = row['disputeRevision'] as int? ?? 0;
        final disputed = row['conflict'] == 1 && revision > 0;
        final receiptRefs = disputed
            ? await db.query('disposition_fact',
                columns: ['reference'],
                where: 'purchaseId=?',
                whereArgs: [row['id']])
            : const <_Row>[];
        result.add(AppleTransaction(
            environmentProofs: disputed
                ? await _disputedEnvironmentProofs(db, row['id'] as String)
                : const {},
            disputeId: disputed ? row['id'] as String : null,
            disputeRevision: disputed ? revision : null,
            receiptReferences: List.unmodifiable(
                receiptRefs.map((r) => r['reference'] as String)),
            id: row['id'] as String,
            productId: row['productId'] as String,
            transactionId: row['reportedId'] as String?,
            purchaseToken: row['token'] as String?,
            observations: Map.unmodifiable(observations),
            receipts:
                List.unmodifiable(observations.values.expand((r) => r).toSet()),
            reason: row['reason'] as String?));
      }
      result.addAll(await _unboundTransactions(db));
      return result;
    });
  }

  // A competing authenticated claim blocks another checkout without exposing
  // the other account's receipt, charge, or local attempt.
  Future<String?> _disputedProduct(
      DatabaseExecutor db, String scope, String orderId) async {
    final rows = await db.rawQuery('''
      SELECT a.productId FROM attempt a JOIN recovery.observation r
        ON r.token=a.wireToken COLLATE NOCASE AND r.productId=a.productId
      WHERE a.mode='scoped' AND a.wireToken=a.id COLLATE NOCASE
        AND a.scope=? AND a.orderId=? AND r.status='paid'
        AND r.boundEnvironment IS NULL AND (r.actual IS NULL OR r.actual=?)
      UNION ALL
      SELECT productId FROM purchase WHERE conflict=1 AND id IN (
        SELECT purchaseId FROM claim_fact WHERE scope=? AND orderId=? AND covered=0
        UNION SELECT purchaseId FROM disposition_fact WHERE scope=? AND orderId=? AND covered=0
      ) LIMIT 1
    ''', [scope, orderId, _environment, scope, orderId, scope, orderId]);
    return rows.firstOrNull?['productId'] as String?;
  }

  Future<AppleOrderSnapshot?> _snapshot(String? scope, String orderId) =>
      _journal.read((db) async {
        final attempts = await db.rawQuery(
            """SELECT * FROM attempt WHERE scope IS ? AND orderId=? AND submittedId IS NULL
              AND (mode='legacy' OR wireToken=id COLLATE NOCASE)
              ORDER BY rowid DESC LIMIT 1""", [scope, orderId]);
        var a = attempts.firstOrNull;
        final purchases = await db.rawQuery('''
            SELECT p.*, (NOT EXISTS(SELECT 1 FROM queue_item q WHERE q.purchaseId=p.id)
               OR EXISTS(SELECT 1 FROM queue_item q WHERE q.purchaseId=p.id AND q.finished=0)) AS finishPending
            FROM purchase p WHERE (p.scope IS ? AND p.orderId=?) OR
              (p.scope IS NULL AND p.attemptId=?) ORDER BY p.rowid
        ''', [scope, orderId, a?['id']]);
        final dispute =
            scope == null ? null : await _disputedProduct(db, scope, orderId);
        if (a == null && purchases.isEmpty && dispute == null) return null;
        if (a == null) {
          final linked =
              purchases.map((p) => p['attemptId']).whereType<String>().toSet();
          if (linked.length == 1) a = await _row(db, 'attempt', linked.single);
        }
        final unpaid = await db.rawQuery('''
          SELECT 1 FROM queue_item q JOIN attempt a ON q.attemptId=a.id
          WHERE a.scope IS ? AND a.orderId=? AND q.status IN ('failed','canceled')
            AND q.finished=0 LIMIT 1''', [scope, orderId]);
        final revision = (await db.query('meta', columns: ['revision']))
            .single['revision'] as int;
        final disputed =
            dispute != null || purchases.any((p) => p['conflict'] == 1);
        final attemptPhase = a?['phase'] as String?;
        final verifiedPayment = purchases.any((p) =>
            p['verifiedId'] != null &&
            p['scope'] == scope &&
            !_requiresEnvironmentProof(p['reason']));
        final phase = disputed || attemptPhase == 'conflict'
            ? 'conflict'
            : verifiedPayment
                ? 'paid'
                : attemptPhase ?? 'paid';
        return AppleOrderSnapshot(
            scope: scope ?? '',
            orderId: orderId,
            productId: (a?['productId'] ??
                purchases.firstOrNull?['productId'] ??
                dispute) as String,
            attemptId: a?['id'] as String?,
            revision: revision,
            unpaidFinishPending: unpaid.isNotEmpty,
            phase: phase == 'submitting' ? 'uncertain' : phase,
            reason: verifiedPayment && phase == 'paid'
                ? null
                : a?['reason'] as String?,
            charges: List.unmodifiable(purchases.map((p) => AppleCharge(
                transactionId: p['reportedId'] as String?,
                disposition: p['disposition'] as String?,
                reference: p['ackRef'] as String?,
                finishPending: p['finishPending'] == 1,
                conflict: p['conflict'] == 1,
                reason: p['reason'] as String?))));
      });

  Stream<AppleOrderSnapshot?> _watch(AppleAccount account, String orderId) {
    late StreamController<AppleOrderSnapshot?> out;
    StreamSubscription<void>? sub;
    Future<void> reads = Future.value();
    bool active = true, initial = true;
    String? previous;
    void stop() {
      if (!active) return;
      active = false;
      unawaited(sub?.cancel());
      unawaited(out.close());
    }

    void refresh() {
      if (!identical(_account, account)) {
        stop();
        return;
      }
      reads = reads.then((_) async {
        if (!active) return;
        final s = await _snapshot(account.scope, orderId);
        if (!active || !identical(_account, account)) return;
        final value = s == null
            ? null
            : jsonEncode([
                s.attemptId,
                s.phase,
                s.reason,
                s.unpaidFinishPending,
                for (final c in s.charges)
                  [
                    c.transactionId,
                    c.disposition,
                    c.reference,
                    c.finishPending,
                    c.conflict,
                    c.reason
                  ]
              ]);
        if (initial || value != previous) out.add(s);
        previous = value;
        initial = false;
      }).catchError((Object error) {
        if (active) out.addError(error);
      });
    }

    out = StreamController<AppleOrderSnapshot?>(onListen: () {
      sub = _changes.stream.listen((_) => refresh(), onDone: stop);
      refresh();
    }, onCancel: () async {
      active = false;
      await sub?.cancel();
    });
    // A paused listener may still have snapshots queued when its login ends.
    // Check the generation again as those events are delivered on resume.
    return out.stream.transform(StreamTransformer.fromHandlers(
      handleData: (snapshot, sink) {
        if (identical(_account, account)) sink.add(snapshot);
      },
      handleError: (error, stack, sink) {
        if (identical(_account, account)) sink.addError(error, stack);
      },
    ));
  }

  /// Drain already scheduled work without firing delayed retries.
  @visibleForTesting
  Future<void> settle() async {
    while (true) {
      final pending = _events;
      await pending;
      await _activation;
      await Future.wait([
        ..._workers.values,
        ..._closingItems.values,
        if (_checkingCalls != null) _checkingCalls!,
        ..._responding.map((work) => work.then<void>((_) {})),
      ]);
      await Future<void>.delayed(Duration.zero);
      if (identical(pending, _events) &&
          _workers.isEmpty &&
          _responding.isEmpty &&
          _checkingCalls == null &&
          _closingItems.isEmpty) {
        return;
      }
    }
  }

  @visibleForTesting
  Future<void> close() async {
    _closed = true;
    _ready = false;
    _account?.dispose();
    await _subscription?.cancel();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    await settle();
    await _changes.close();
    await _errors.close();
    final store = _store;
    if (store is AppleStoreLifecycle) {
      await (store as AppleStoreLifecycle).stop();
    }
    await _journal.close();
  }
}
