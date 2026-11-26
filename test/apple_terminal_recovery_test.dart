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
  Future<void> finish(StoreEvent event) async {
    if (++calls == 1) {
      firstCall.complete();
      await failFirst.future;
      throw StateError('temporary');
    }
    return super.finish(event);
  }
}

void main() {
  late Directory directory;
  late AppleJournal journal;
  late ApplePayments payments;
  late ProbeStore store;
  Future<void> open(
      {ProbeStore? testStore,
      Timer Function(Duration, void Function())? timerFactory}) async {
    store = testStore ?? ProbeStore();
    journal = AppleJournal(() async => File('${directory.path}/ledger'));
    payments =
        ApplePayments.forTesting(store, journal, timerFactory: timerFactory);
    await payments.start(environment: 'sandbox');
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
