import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

import 'apple_payments_test.dart' show ProbeStore;

class _RetryStore extends ProbeStore {
  final firstCall = Completer<void>();
  final failFirst = Completer<void>();
  int calls = 0;

  @override
  Future<void> finish(StoreEvent event, {bool verifiedQueue = false}) async {
    if (++calls == 1) {
      firstCall.complete();
      await failFirst.future;
      throw StateError('temporary');
    }
    return super.finish(event, verifiedQueue: verifiedQueue);
  }
}

void main() {
  late Directory directory;
  late AppleJournal journal;
  late ApplePayments payments;
  late ProbeStore store;
  Future<void> open(
      {ProbeStore? testStore,
      bool legacyOnly = false,
      Timer Function(Duration, void Function())? timerFactory}) async {
    store = testStore ?? ProbeStore();
    journal = AppleJournal(() async => File('${directory.path}/ledger'));
    payments =
        ApplePayments.forTesting(store, journal, timerFactory: timerFactory);
    if (legacyOnly) {
      payments.attachLegacy(Object(), null, (_, __) {}, (_) {});
      await payments.retryPending();
    } else {
      await payments.start(environment: 'sandbox');
    }
  }

  Future<void> stop() async {
    await payments.close();
    await store.stream.close();
  }

  AppleAccount login() => payments.connect(
      scope: 'A', verify: (_) async => const AppleVerification.retryLater());
  StoreEvent event(StoreStatus status, String handle,
          {String? token, String sku = 'sku'}) =>
      StoreEvent(native: handle, productId: sku, status: status, token: token);

  StoreEvent offCatalog(StoreStatus status, String handle, String? order,
          {String sku = 'sku'}) =>
      StoreEvent(
          native: handle,
          productId: sku,
          token: order,
          status: status,
          allowsUnownedFinish: false);

  Future<void> submitLegacy(String order) {
    final owner = Object();
    payments.attachLegacy(owner, (_) async {}, (_, __) {}, (_) {});
    return payments.buyLegacy(owner, 'sku', order);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('paykit-terminal');
  });
  tearDown(() async {
    await stop();
    await directory.delete(recursive: true);
  });

  for (final status in [StoreStatus.canceled, StoreStatus.failed]) {
    test(
        'replayed ${status.name} with a unique submission releases only its order',
        () async {
      await open();
      final first = login();
      final id = (await first.buy(orderId: 'O', productId: 'sku')).attemptId!;
      final other =
          (await first.buy(orderId: 'other', productId: 'sku')).attemptId!;
      store.stream.add([event(StoreStatus.pending, 'pending', token: id)]);
      await payments.settle();
      await stop();
      await open();
      final account = login();
      store.stream.add([event(status, 'terminal', token: id.toUpperCase())]);
      await payments.settle();
      expect((await account.lookup('O'))!.phase, status.name);
      expect((await account.lookup('other'))!.phase, 'accepted');
      expect((await payments.unresolvedAttempts()).map((e) => e.attemptId),
          [other]);
      expect(store.finished.map((e) => e.native), ['terminal']);
      await stop();
      await open();
      final reopened = login();
      expect((await reopened.lookup('O'))!.phase, status.name);
      final next = await reopened.buy(orderId: 'O', productId: 'sku');
      expect(next.attemptId, isNot(id));
      expect(store.submitted, [next.attemptId]);
    });
  }

  for (final status in [StoreStatus.canceled, StoreStatus.failed]) {
    for (final legacyOnly in [false, true]) {
      test(
          'catalog removal still permits legacy ${status.name} cleanup (legacy-only: $legacyOnly)',
          () async {
        await open(legacyOnly: legacyOnly);
        await submitLegacy('order-123');
        await stop();
        await open(legacyOnly: legacyOnly);

        // The old business token is the only queue identifier available at replay.
        final target = offCatalog(status, 'owned', 'order-123');
        store.stream.add([
          offCatalog(status, 'foreign', 'other-order'),
          offCatalog(status, 'different-product', 'order-123', sku: 'other'),
          offCatalog(status, 'missing-token', null),
          target,
        ]);
        await payments.settle();
        store.stream.add([target]);
        await payments.retryPending();
        await payments.settle();
        expect(store.finished, [same(target)]);
        final attempt = await journal.read((db) async => (await db
                .query('attempt', where: 'orderId=?', whereArgs: ['order-123']))
            .single);
        expect(attempt['phase'], 'accepted');
      });
    }
  }

  test('off-catalog cleanup preserves an existing server unpaid decision',
      () async {
    await open();
    await submitLegacy('order-123');
    final attempt = (await payments.unresolvedAttempts()).single;
    await payments.resolveAttempt(AppleAttemptDecision(
        issuer: 'server',
        decisionId: 'unpaid',
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'order-123',
        attemptId: attempt.attemptId,
        reference: 'closed-by-server',
        outcome: AppleAttemptOutcome.unpaid));
    await stop();
    await open();

    final target = offCatalog(StoreStatus.canceled, 'old-item', 'order-123');
    store.stream.add([target]);
    await payments.settle();
    expect(store.finished, [same(target)]);
    final original = await journal.read((db) async => (await db
            .query('attempt', where: 'id=?', whereArgs: [attempt.attemptId]))
        .single);
    expect(original['phase'], 'declined');
    expect(original['reason'], 'serverUnpaid');
  });

  test('off-catalog legacy failures require confirmed, unambiguous ownership',
      () async {
    await open();
    store.launch = () async => false;
    await expectLater(
        submitLegacy('declined'), throwsA(isA<StorePurchaseRejected>()));
    store.launch = () async => throw StateError('lost reply');
    await expectLater(
        submitLegacy('uncertain'), throwsA(isA<StoreSubmissionUnresolved>()));
    store.launch = null;
    await submitLegacy('ambiguous');
    await submitLegacy('payment-observed');
    await submitLegacy('other-accepted-order');
    await stop();
    await open();

    // Older ledgers may have reserved the same token in different partitions.
    await journal.write((db) => db.insert('recovery.submission', {
          'token': 'ambiguous',
          'origin': 'production',
          'attemptId': 'another-attempt'
        }));
    store.event('payment-observed', 'payment');
    await payments.settle();
    // This token has its own accepted order, but the queue ID identifies the
    // payment already observed for a different order.
    store.stream.add([
      const StoreEvent(
          native: 'conflicting-item',
          productId: 'sku',
          token: 'other-accepted-order',
          queueId: 'payment',
          status: StoreStatus.failed,
          allowsUnownedFinish: false),
    ]);
    for (final order in [
      'declined',
      'uncertain',
      'ambiguous',
      'payment-observed'
    ]) {
      store.stream
          .add([offCatalog(StoreStatus.failed, 'failure-$order', order)]);
    }
    await payments.settle();
    await payments.retryPending();
    await payments.settle();
    expect(store.finished, isEmpty);
  });

  test('new payment evidence stops a pending off-catalog finish retry',
      () async {
    await open();
    await submitLegacy('order-123');
    await stop();
    final native = _RetryStore();
    await open(
        testStore: native,
        timerFactory: (_, callback) =>
            Timer(const Duration(days: 1), callback));

    store.stream.add([offCatalog(StoreStatus.failed, 'old-item', 'order-123')]);
    try {
      await native.firstCall.future.timeout(const Duration(seconds: 4));
    } finally {
      native.failFirst.complete();
    }
    await payments.settle();

    store.event('order-123', 'late-payment');
    await payments.settle();
    await payments.retryPending();
    await payments.settle();
    expect(native.calls, 1);
    expect(native.finished, isEmpty);
  });

  for (final blocked in [
    'no token',
    'wrong product',
    'ambiguous UUID',
    'unresolved payment'
  ]) {
    test('cold failure with $blocked cannot release a previous order',
        () async {
      await open();
      final id = (await login().buy(orderId: 'O', productId: 'sku')).attemptId!;
      await stop();
      await open();
      if (blocked == 'ambiguous UUID') {
        // Historical candidates could accept the same UUID in two environments.
        await journal.write((db) => db.rawInsert(
            'INSERT INTO recovery.submission(token,origin,attemptId) VALUES (?,?,?)',
            [id, 'production', id]));
      }
      final account = login();
      if (blocked == 'unresolved payment') {
        store.stream.add([
          StoreEvent(
              native: 'unsettled',
              productId: 'sku',
              token: id,
              transactionId: 'payment',
              status: StoreStatus.paid,
              receipt: 'receipt')
        ]);
        await payments.settle();
      }
      store.stream.add([
        event(StoreStatus.failed, 'failure',
            token: blocked == 'no token' ? null : id,
            sku: blocked == 'wrong product' ? 'elsewhere' : 'sku')
      ]);
      await payments.settle();
      expect((await account.lookup('O'))!.phase, isNot('failed'));
      await account.buy(orderId: 'O', productId: 'sku');
      expect(store.submitted, isEmpty);
      expect(store.finished.map((e) => e.native), ['failure']);
    });
  }

  test('unowned terminal item waits for a durable finish authorization',
      () async {
    await open();
    await journal.write((db) => db.execute(
        """CREATE TRIGGER recovery.reject_finish BEFORE INSERT ON finish_authority
           BEGIN SELECT RAISE(ABORT,'test write failure'); END"""));
    store.stream.add([event(StoreStatus.canceled, 'original')]);
    await payments.settle();
    expect(store.finished, isEmpty);
    await journal
        .write((db) => db.execute('DROP TRIGGER recovery.reject_finish'));
    await payments.retryPending();
    await payments.settle();
    expect(store.finished.map((e) => e.native), ['original']);
    expect(
        await journal.read((db) =>
            db.rawQuery('SELECT itemId FROM recovery.finish_authority')),
        hasLength(1));
  });

  test(
      'failed finish retries the same native object after its Dart wrapper changes',
      () async {
    final native = _RetryStore();
    final deferred = Completer<void Function()>();
    await open(
        testStore: native,
        timerFactory: (delay, callback) {
          final timer = Timer(const Duration(days: 1), callback);
          deferred.complete(() {
            timer.cancel();
            callback();
          });
          return timer;
        });
    final first = event(StoreStatus.canceled, 'object');
    final replay = event(StoreStatus.canceled, 'object');
    native.stream.add([first]);
    await native.firstCall.future;
    native.stream.add([replay]);
    // Refresh drains the store event stream, while the first finish stays pending.
    await payments.refreshReceipts();
    native.failFirst.complete();
    await payments.settle();
    expect(native.finished, isEmpty);
    (await deferred.future)();
    await payments.settle();
    expect(native.calls, 2);
    expect(native.finished.single, same(replay));
  });
}
