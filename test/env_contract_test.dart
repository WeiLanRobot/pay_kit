import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_store.dart';
import 'package:sqflite/sqflite.dart';

import 'apple_payments_test.dart' show FaultJournal, ProbeStore, delivered;

class _Lifecycle extends ProbeStore implements AppleStoreLifecycle {
  bool reject = false;
  int registrations = 0, snapshots = 0, releases = 0;
  final cold = <StoreEvent>[];
  @override
  Future<void> start() async {
    registrations++;
    stream.add(cold);
    if (reject) throw StateError('native registration failed');
  }

  @override
  Future<void> snapshot() async {
    snapshots++;
    stream.add(cold);
  }

  @override
  Future<void> stop() async {
    releases++;
  }
}

void main() {
  late Directory dir;
  late _Lifecycle store;
  late FaultJournal journal;
  late ApplePayments pay;
  Future<void> create() async {
    store = _Lifecycle();
    journal = FaultJournal(() async => File('${dir.path}/ledger'));
    pay = ApplePayments.forTesting(store, journal);
  }

  Future<void> stop() async {
    await pay.close();
    await store.stream.close();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('paykit-env-');
    await create();
  });
  tearDown(() async {
    await stop();
    await dir.delete(recursive: true);
  });
  StoreEvent item(String handle, StoreStatus status,
          {String? token, String? tx, String receipt = 'apple-receipt'}) =>
      StoreEvent(
          productId: 'sku',
          status: status,
          native: handle,
          transactionId: tx,
          queueId: tx,
          receipt: status == StoreStatus.paid ? receipt : '',
          token: token);
  AppleClaim claim(String env, String order, String? token,
          {String? observation}) =>
      AppleClaim(
          appId: 'app',
          environment: env,
          scope: 'A',
          orderId: order,
          productId: 'sku',
          reportedTransactionId: 'T',
          verifiedTransactionId: 'T',
          reference: 'claim-$env-$order',
          purchaseToken: token,
          observationId: observation);

  const uuid = '41aa5857-651a-42fb-ab0f-dd9cf1264569';

  test(
      'one submission UUID across environments, old ambiguous histories stay quarantined',
      () async {
    await pay.start(environment: 'sandbox');
    final a = pay.connect(scope: 'A', verify: (r) async => delivered(r));
    await a.buy(productId: 'sku', orderId: 'first', purchaseToken: uuid);
    store.failFinish = true;
    store.stream.add([item('old', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    expect((await a.lookup('first'))!.charges.single.reference, 'ack-T');
    await stop();
    await create();
    await pay.start(environment: 'production');
    final b = pay.connect(
        scope: 'B', verify: (r) async => const AppleVerification.retryLater());
    await expectLater(
        b.buy(
            productId: 'sku',
            orderId: 'second',
            purchaseToken: uuid.toUpperCase()),
        throwsStateError);
    expect(store.submitted, isEmpty);
    // Reconstruct an older candidate whose partition-local constraint accepted
    // the very same UUID for a second actual submission.
    await journal.write((db) => db.insert('attempt', {
          'id': uuid,
          'scope': 'B',
          'orderId': 'second',
          'productId': 'sku',
          'wireToken': uuid.toUpperCase(),
          'mode': 'scoped',
          'phase': 'accepted'
        }));
    await stop();
    final old = await openDatabase('${dir.path}/ledger.production',
        singleInstance: false);
    await old.setVersion(3);
    await old.close();
    await create();
    await pay.start(environment: 'sandbox');
    store.stream
        .add([item('ambiguous', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    await expectLater(
        pay.reconcile(claim('sandbox', 'first', uuid)), throwsStateError);
    await pay.retryPending();
    await pay.settle();
    expect(store.finished, isEmpty);
  });

  test(
      'cold trusted claim restores the exact compatibility handoff and keeps it in its proven environment',
      () async {
    final owner = Object();
    var calls = 0;
    pay.attachLegacy(owner, (r) async {
      calls++;
    }, (_, __) {}, (_) {});
    await pay.buyLegacy(owner, 'sku', uuid);
    store.failFinish = true;
    store.stream.add([item('old', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    expect(calls, 1);
    await stop();
    await create();
    await pay.start(environment: 'sandbox');
    store.stream.add([item('restore', StoreStatus.paid, tx: 'T')]);
    await pay.settle();
    await pay.reconcile(claim('sandbox', uuid, uuid));
    await pay.settle();
    expect(store.finished, isEmpty);
    store.stream.add([item('restore', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    await pay.reconcile(claim('sandbox', uuid, uuid));
    await pay.settle();
    expect(store.finished, isEmpty);
    final recoveryId = await journal.read((db) async => (await db.query(
            'recovery.observation',
            where: 'objectKey=?',
            whereArgs: ['handle:restore']))
        .single['id'] as String);
    final awaiting = await pay.recoverObservation(
        claim('sandbox', uuid, uuid, observation: recoveryId));
    expect(awaiting.state, AppleObservationState.awaitingDisposition);
    await pay.recordPayment(const AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: uuid,
        productId: 'sku',
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: 'original-payment',
        disposition: AppleDisposition(
            appId: 'app',
            environment: 'sandbox',
            scope: 'A',
            orderId: uuid,
            productId: 'sku',
            reportedTransactionId: 'T',
            verifiedTransactionId: 'T',
            outcome: AppleOutcome.delivered,
            reference: 'server-fulfilled')));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['restore']);
    expect(calls, 1);
    expect(store.submitted, isEmpty);
    await stop();
    await create();
    await pay.start(environment: 'production');
    store.stream.add(
        [item('other-environment', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    await expectLater(
        pay.reconcile(claim('production', uuid, uuid)), throwsStateError);
    expect(store.finished, isEmpty);
  });

  test(
      'current tokenless mismatch awaits independent source proof and then verifies',
      () async {
    await pay.start(environment: 'sandbox');
    var calls = 0;
    final a = pay.connect(
        scope: 'A',
        verify: (r) async {
          if (++calls > 1) return delivered(r);
          return const AppleVerification.environmentMismatch(
              AppleEnvironmentMismatch(
                  appId: 'app',
                  expectedEnvironment: 'sandbox',
                  actualEnvironment: 'production',
                  reportedTransactionId: 'T',
                  verifiedTransactionId: 'T',
                  productId: 'sku',
                  issuer: 'apple-server',
                  reference: 'no-token'));
        });
    await a.buy(productId: 'sku', orderId: 'order', purchaseToken: uuid);
    store.stream.add([item('current', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    await pay.retryPending();
    await pay.settle();
    expect(calls, 1);
    expect((await a.lookup('order'))!.phase, 'uncertain');
    store.stream.add([item('current', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    expect((await a.lookup('order'))!.phase, 'uncertain');
    expect((await pay.unresolvedAttempts()).single.attemptId, uuid);
    expect(store.finished, isEmpty);
    expect(calls, 1);
    await expectLater(
        pay.reconcile(claim('sandbox', 'order', null)), throwsStateError);
    expect(store.finished, isEmpty);
    await pay.reconcile(claim('sandbox', 'order', uuid));
    await pay.settle();
    expect(calls, 2);
    expect(store.finished.map((e) => e.native), ['current']);
  });

  test(
      'v4 replay cannot strand an environment-unproven payment outside recovery',
      () async {
    await pay.start(environment: 'sandbox');
    final account = pay.connect(
        scope: 'A',
        verify: (_) async => const AppleVerification.needsReconciliation());
    await account.buy(productId: 'sku', orderId: 'order', purchaseToken: uuid);
    store.stream.add([item('old', StoreStatus.paid, token: uuid, tx: 'T')]);
    await pay.settle();
    await stop();
    final old = await openDatabase('${dir.path}/ledger', singleInstance: false);
    await old.update('purchase', {'reason': 'sourceUnproven'},
        where: 'attemptId=?', whereArgs: [uuid]);
    expect((await old.query('attempt')).single['phase'], 'paid');
    await old.setVersion(4);
    await old.close();
    await create();
    await pay.start(environment: 'sandbox');
    final resumed = pay.connect(
        scope: 'A', verify: (_) async => fail('source proof required'));
    await pay.settle();
    expect((await resumed.lookup('order'))!.phase, 'uncertain');
    expect((await pay.unresolvedAttempts()).single.attemptId, uuid);
    expect(store.finished, isEmpty);
    expect(store.submitted, isEmpty);
  });

  test('invalid candidate header rolls back its version and original rows',
      () async {
    await pay.start(environment: 'sandbox');
    await pay
        .connect(scope: 'A', verify: (r) async => delivered(r))
        .buy(productId: 'sku', orderId: 'saved');
    await stop();
    final path = '${dir.path}/ledger';
    final old = await openDatabase(path, singleInstance: false);
    await old.update('meta', {'appId': ' '});
    await old.setVersion(2);
    await old.close();
    await create();
    await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
    final check = await openDatabase(path, singleInstance: false);
    expect(await check.getVersion(), 2);
    expect((await check.query('attempt')).single['orderId'], 'saved');
    await check.close();
    expect(store.registrations, 0);
  });

  test('new purchases retry managed startup after a legacy receipt handoff',
      () async {
    final owner = Object(), nextPage = Object();
    pay.attachLegacy(nextPage, (_) async {}, (_, __) {}, (_) {});
    final handoffStarted = Completer<void>(), release = Completer<void>();
    pay.attachLegacy(owner, (receipt) async {
      await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
      handoffStarted.complete();
      await release.future;
    }, (_, __) {}, (error) {});
    await pay.buyLegacy(owner, 'sku', 'legacy-first');
    store.stream.add(
        [item('legacy', StoreStatus.paid, token: 'legacy-first', tx: 'T')]);
    try {
      await handoffStarted.future.timeout(const Duration(seconds: 4));
      await expectLater(
          pay.buyLegacy(nextPage, 'sku', 'new-order'), throwsStateError);
      expect(store.submitted, ['legacy-first']);
    } finally {
      release.complete();
    }
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['legacy']);
    await pay.buyLegacy(nextPage, 'sku', 'new-order');
    expect(store.submitted, ['legacy-first', 'new-order']);
    expect((await journal.read((db) => db.query('meta'))).single['environment'],
        'sandbox');
    expect(store.registrations, 1);
  });

  for (final recover in [false, true]) {
    test('detached legacy-only callback with managed recovery: $recover',
        () async {
      final entered = Completer<void>(), release = Completer<void>();
      final owner = Object();
      pay.attachLegacy(owner, (_) {
        entered.complete();
        return release.future;
      }, (_, __) {}, (_) {});
      try {
        await pay.buyLegacy(owner, 'sku', 'legacy-first');
        store.stream.add(
            [item('legacy', StoreStatus.paid, token: 'legacy-first', tx: 'T')]);
        await entered.future.timeout(const Duration(seconds: 4));
        if (recover) {
          store.stream.add([
            item('legacy', StoreStatus.paid,
                token: 'legacy-first', tx: 'T', receipt: 'updated-receipt')
          ]);
          // Wait for this replay while the original receiver still holds the callback.
          final waiting = Stopwatch()..start();
          while (await journal.read(
                  (db) async => (await db.query('purchase_evidence')).length) <
              2) {
            if (waiting.elapsed >= const Duration(seconds: 4)) {
              fail('The replay never reached the journal');
            }
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
        pay.detachLegacy(owner);
        expect(store.finished, isEmpty);
        if (recover) {
          await pay
              .start(environment: 'sandbox')
              .timeout(const Duration(seconds: 4));
          // A late legacy success cannot bypass verification after a claim.
          await pay.reconcile(claim('sandbox', 'legacy-first', null));
          release.complete();
          await pay.settle().timeout(const Duration(seconds: 4));
          expect(store.finished, isEmpty);
          expect(
              await journal.read((db) => db.query('legacy_handoff')), isEmpty);
          final receipts = <String>[];
          final account = pay.connect(
              scope: 'A',
              verify: (r) async {
                receipts.add(r.receipt);
                return delivered(r);
              });
          await pay.settle().timeout(const Duration(seconds: 4));
          expect(receipts, hasLength(1));
          expect(receipts.single, isIn(['apple-receipt', 'updated-receipt']));
          expect(
              (await account.lookup('legacy-first'))!.charges.single.reference,
              'ack-T');
          expect(store.finished.map((e) => e.native), ['legacy']);
        }
      } finally {
        if (!release.isCompleted) release.complete();
      }
      await pay.settle();
      expect(store.finished.map((e) => e.native), ['legacy']);
      expect(await journal.read((db) => db.query('legacy_handoff')),
          hasLength(recover ? 0 : 1));
      expect(store.submitted, ['legacy-first']);
    });
  }

  test('an invalid environment leaves legacy startup available', () async {
    expect(() => pay.start(environment: 'Sandbox'), throwsArgumentError);
    expect(store.registrations, 0);

    final owner = Object();
    pay.attachLegacy(owner, (_) async {}, (_, __) {}, (_) {});
    await pay.buyLegacy(owner, 'sku', 'legacy-order');
    expect(store.registrations, 1);
    expect(store.submitted, ['legacy-order']);
  });

  test('legacy purchases retry the failed managed environment once', () async {
    store.reject = true;
    await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
    expect(store.releases, 1);

    store.reject = false;
    final owner = Object();
    pay.attachLegacy(owner, (_) async {}, (_, __) {}, (_) {});
    await Future.wait([
      pay.buyLegacy(owner, 'sku', 'legacy-order'),
      pay.buyLegacy(owner, 'sku', 'legacy-order'),
    ]);

    final header = await journal.read((db) => db.query('meta'));
    expect(header.single['environment'], 'sandbox');
    expect(header.single['appId'], 'app');
    expect(store.registrations, 2);
    expect(store.snapshots, 1);
    expect(store.submitted, ['legacy-order']);
  });

  test('explicit startup can replace an environment that never started',
      () async {
    store.reject = true;
    await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
    store.reject = false;
    await pay.start(environment: 'production');

    final header = await journal.read((db) => db.query('meta'));
    expect(header.single['environment'], 'production');
    expect(store.registrations, 2);
    expect(store.snapshots, 1);
  });

  test(
      'startup validates identity, buffers pending registration and releases failed owner',
      () async {
    final cancel = item('c', StoreStatus.canceled);
    final paid = item('p', StoreStatus.paid, tx: 'T');
    store.cold.addAll([cancel, paid]);
    expect(() => pay.start(environment: 'other'), throwsArgumentError);
    store.runningBundle = '';
    await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
    store.runningBundle = 'app';
    expect(store.registrations, 0);
    store.reject = true;
    await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
    store.stream.add([cancel, paid]);
    await expectLater(pay.retryPending(), throwsStateError);
    await pay.settle();
    expect(store.releases, 1);
    expect(store.finished, isEmpty);
    expect(await journal.read((db) => db.query('queue_item')), isEmpty);
    expect(
        await journal
            .read((db) => db.rawQuery('SELECT * FROM recovery.observation')),
        isEmpty);
    store.reject = false;
    final first = pay.start(environment: 'sandbox');
    expect(identical(first, pay.start(environment: 'sandbox')), isTrue);
    await first;
    await pay.settle();
    expect(store.snapshots, 1);
    expect(store.finished.map((e) => e.native), ['c']);
    expect((await pay.unmatched()).single.transactionId, 'T');
    expect(() => pay.start(environment: 'production'), throwsStateError);
    expect((await pay.unmatched()).single.transactionId, 'T');
  });

  test(
      'cold foreign paid report stays unresolved beside exact unowned cancellation',
      () async {
    await pay.start(environment: 'sandbox');
    final a = pay.connect(scope: 'A', verify: (r) async => delivered(r));
    final attempted = await a.buy(productId: 'sku', orderId: '42');
    store.failFinish = true;
    store.stream.add([
      item('sandbox', StoreStatus.paid, token: attempted.attemptId, tx: 'T')
    ]);
    await pay.settle();
    expect((await a.lookup('42'))!.charges.single.reference, 'ack-T');
    await stop();
    await create();
    store.cold.addAll([
      item('production', StoreStatus.paid, tx: 'T'),
      item('cancel', StoreStatus.canceled)
    ]);
    await pay.start(environment: 'production');
    final b = pay.connect(
        scope: 'A', verify: (r) async => throw StateError('unexpected'));
    await pay.settle();
    expect(await b.lookup('42'), isNull);
    expect(store.finished.map((e) => e.native), ['cancel']);
    await b.buy(productId: 'sku', orderId: '42');
    expect(store.submitted, hasLength(1));
    expect((await pay.unmatched()).single.transactionId, 'T');
    await stop();
    await create();
    await pay.start(environment: 'sandbox');
    expect(
        (await pay
                .connect(scope: 'A', verify: (r) async => delivered(r))
                .lookup('42'))!
            .attemptId,
        attempted.attemptId);
    expect(store.finished, isEmpty);
  });

  test(
      'signed mismatch blocks original order and permits independent target recovery',
      () async {
    await pay.start(environment: 'production');
    final a = pay.connect(
        scope: 'A',
        verify: (r) async => AppleVerification.environmentMismatch(
            AppleEnvironmentMismatch(
                appId: 'app',
                expectedEnvironment: 'production',
                actualEnvironment: 'sandbox',
                reportedTransactionId: 'T',
                verifiedTransactionId: 'T',
                productId: 'sku',
                issuer: 'server',
                reference: 'signed-environment',
                purchaseToken: r.purchaseToken)));
    final token = (await a.buy(productId: 'sku', orderId: 'source')).attemptId!;
    store.stream.add([item('first', StoreStatus.paid, tx: 'T', token: token)]);
    await pay.settle();
    expect((await a.lookup('source'))!.reason, 'environmentMismatch');
    expect((await a.buy(productId: 'sku', orderId: 'source')).attemptId, token);
    expect(store.submitted, [token]);
    expect(store.finished, isEmpty);
    // An independent financial row in the source partition cannot acquire
    // the native object whose signed proof selected a different environment.
    final otherCharge = AppleClaim(
      appId: 'app',
      environment: 'production',
      scope: 'A',
      orderId: 'source',
      productId: 'sku',
      reportedTransactionId: 'T',
      verifiedTransactionId: 'T',
      purchaseToken: token,
      reference: 'local-financial-evidence',
      disposition: const AppleDisposition(
        appId: 'app',
        environment: 'production',
        scope: 'A',
        orderId: 'source',
        productId: 'sku',
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: 'separate-local-delivery',
      ),
    );
    await pay.recordPayment(otherCharge);
    await expectLater(pay.reconcile(otherCharge), throwsStateError);
    await pay.retryPending();
    await pay.settle();
    expect(store.finished, isEmpty);
    expect(
        (await a.lookup('source'))!
            .charges
            .where((c) => c.reference == 'separate-local-delivery')
            .single
            .transactionId,
        isNull);
    await stop();
    await create();
    store.cold.add(item('target', StoreStatus.paid, tx: 'T', token: token));
    await pay.start(environment: 'sandbox');
    await pay.settle();
    final evidence = (await pay.unmatched())
        .firstWhere((r) => r.reason == 'environmentMismatch');
    var credits = 0;
    final b = pay.connect(
        scope: 'A',
        verify: (r) async {
          credits++;
          return delivered(r);
        });
    await pay.reconcile(
        claim('sandbox', 'correct', token, observation: evidence.id));
    await pay.settle();
    expect((await b.lookup('correct'))!.attemptId, isNull);
    expect(
        (await b.lookup('correct'))!.charges.single.disposition, 'delivered');
    expect(await b.lookup('source'), isNull);
    expect(credits, 1);
    expect(store.submitted, isEmpty);
    expect(store.finished.map((e) => e.native), ['target']);
  });

  test(
      'an unlinked mismatch still needs original submission evidence before merging',
      () async {
    await pay.start(environment: 'sandbox');
    final a = pay.connect(
        scope: 'A',
        verify: (_) async => const AppleVerification.environmentMismatch(
            AppleEnvironmentMismatch(
                appId: 'app',
                expectedEnvironment: 'sandbox',
                actualEnvironment: 'production',
                reportedTransactionId: 'T',
                verifiedTransactionId: 'T',
                productId: 'sku',
                issuer: 'server',
                reference: 'without-submission')));
    final token = (await a.buy(productId: 'sku', orderId: 'O')).attemptId!;
    store.stream
        .add([item('pending-source', StoreStatus.paid, tx: 'T', token: token)]);
    await pay.settle();
    expect((await a.lookup('O'))!.charges.single.reason, 'sourceUnproven');
    final withoutToken = claim('sandbox', 'O', null);
    await pay.recordPayment(withoutToken);
    await expectLater(pay.reconcile(withoutToken), throwsStateError);
    expect(store.finished, isEmpty);
    await pay.reconcile(claim('sandbox', 'O', token));
    expect((await a.lookup('O'))!.charges.single.attemptId, token);
  });

  test(
      'legacy-only purchase persists across managed handoff; rejected bind preserves receiver',
      () async {
    final received = <String>[], owner = Object();
    pay.attachLegacy(owner, (r) async {
      received.add(r);
    }, (_, __) {}, (_) {});
    await pay.buyLegacy(owner, 'sku', 'legacy-new');
    store.runningBundle = '';
    await expectLater(pay.start(environment: 'sandbox'), throwsStateError);
    store.runningBundle = 'app';
    await pay.start(environment: 'sandbox');
    store.stream
        .add([item('legacy', StoreStatus.paid, token: 'legacy-new', tx: 'T')]);
    await pay.settle();
    expect(received, ['apple-receipt']);
    expect(store.finished.map((e) => e.native), ['legacy']);
    expect(store.registrations, 1);
  });

  test(
      'failed evidence write prevents cold cancellation finish until durable retry',
      () async {
    await pay.start(environment: 'sandbox');
    journal.writable = false;
    store.stream.add([item('unowned', StoreStatus.canceled)]);
    await pay.settle();
    expect(store.finished, isEmpty);
    expect(
        await journal
            .read((db) => db.rawQuery('SELECT id FROM recovery.observation')),
        isEmpty);
    journal.writable = true;
    await pay.retryPending();
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['unowned']);
  });

  test('failed cold ledger validation rejects callbacks before registration',
      () async {
    final file = File('${dir.path}/ledger');
    final bytes = List.filled(128, 42);
    await file.writeAsBytes(bytes);
    final opening = pay.start(environment: 'production');
    store.stream.add([
      item('paid', StoreStatus.paid, tx: 'T'),
      item('failed', StoreStatus.failed)
    ]);
    await expectLater(opening, throwsA(isA<DatabaseException>()));
    store.stream.add([item('failed', StoreStatus.failed)]);
    await pay.settle();
    expect(store.registrations, 0);
    expect(store.finished, isEmpty);
    expect(await file.readAsBytes(), bytes);
  });

  test('candidate migration quarantines a foreign orphan behind sandbox header',
      () async {
    await pay.start(environment: 'sandbox');
    await journal.write((db) async {
      await db.insert(
          'purchase', {'id': 'unbound', 'productId': 'sku', 'reportedId': 'T'});
      await db.insert('evidence', {'hash': 'old', 'body': 'old-apple-receipt'});
      await db.insert(
          'purchase_evidence', {'purchaseId': 'unbound', 'hash': 'old'});
    });
    await stop();
    final old = await openDatabase('${dir.path}/ledger', singleInstance: false);
    await old.setVersion(2);
    await old.close();
    await create();
    await pay.start(environment: 'production');
    final record = (await pay.unmatched()).single;
    expect(record.reason, 'migrationSourceUnproven');
    expect(record.receipts, ['old-apple-receipt']);
    expect(store.finished, isEmpty);
  });
}
