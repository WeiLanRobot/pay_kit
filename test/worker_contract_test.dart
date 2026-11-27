import 'dart:async';
import 'dart:io';

import 'verified_queue_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_payments.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

class _Store extends ProbeStore {
  final refreshing = Completer<void>();
  final refreshed = Completer<String>();
  int refreshCount = 0;

  @override
  Future<String?> refreshReceipt() {
    refreshCount++;
    refreshing.complete();
    return refreshed.future;
  }
}

class _Alarm implements Timer {
  _Alarm(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    expect(isActive, isTrue);
    isActive = false;
    tick++;
    callback();
  }
}

void main() {
  late Directory dir;
  late _Store store;
  late ApplePayments pay;
  final alarms = <_Alarm>[];
  Future<void> open() async {
    store = _Store();
    pay = ApplePayments.forTesting(
        store, AppleJournal(() async => File('${dir.path}/ledger')),
        verificationTimeout: const Duration(seconds: 12),
        timerFactory: (delay, callback) {
      final alarm = _Alarm(delay, callback);
      alarms.add(alarm);
      return alarm;
    });
    await pay.start(environment: 'sandbox');
  }

  Future<void> close() async {
    await pay.close();
    await store.stream.close();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('paykit-worker');
    alarms.clear();
    await open();
  });
  tearDown(() async {
    await close();
    await dir.delete(recursive: true);
  });

  for (final lateResult in ['needsReconciliation', 'sameAck', 'oppositeAck']) {
    test('new login takes a hung call, late $lateResult respects disposition',
        () async {
      final first = Completer<AppleReceipt>();
      final old = Completer<AppleVerification>();
      final a = pay.connect(
          scope: 'A',
          verify: (r) {
            first.complete(r);
            return old.future;
          });
      final order = await a.buy(productId: 'sku', orderId: 'order');
      store.event(order.attemptId, 'T');
      final receipt = await first.future;
      var calls = 0;
      final active = pay.connect(
          scope: 'A',
          verify: (r) async {
            calls++;
            return delivered(r);
          });
      await pay.settle();
      expect(store.finished.single.transactionId, 'T');
      old.complete(lateResult == 'needsReconciliation'
          ? const AppleVerification.needsReconciliation()
          : delivered(receipt,
              outcome: lateResult == 'sameAck'
                  ? AppleOutcome.delivered
                  : AppleOutcome.refunded));
      await pay.settle();
      final charge = (await active.lookup('order'))!.charges.single;
      expect(charge.conflict, lateResult == 'oppositeAck');
      expect(charge.disposition, 'delivered');
      expect(calls, 1);
      expect(store.submitted, hasLength(1));
      expect(store.finished, hasLength(1));
    });
  }

  test(
      'timeout revokes a single call, coalesces retries and accepts its late ACK',
      () async {
    final replies = [
      Completer<AppleVerification>(),
      Completer<AppleVerification>()
    ];
    final entered = [Completer<AppleReceipt>(), Completer<AppleReceipt>()];
    var calls = 0;
    final a = pay.connect(
        scope: 'A',
        verify: (r) async {
          final index = calls++;
          entered[index].complete(r);
          await pay.retryPending();
          return replies[index].future;
        });
    final order = await a.buy(productId: 'sku', orderId: 'order');
    store.event(order.attemptId, 'T');
    final first = await entered.first.future;
    alarms.singleWhere((a) => a.isActive && a.delay.inSeconds == 12).fire();
    await pay.settle();
    await pay.retryPending();
    store.event(order.attemptId, 'T');
    await pay.settle();
    expect(calls, 1);
    alarms.singleWhere((a) => a.isActive && a.delay.inSeconds == 1).fire();
    await entered.last.future;
    replies.first.complete(delivered(first));
    await pay.settle();
    expect(store.finished, hasLength(1));
    replies.last.complete(const AppleVerification.needsReconciliation());
    await pay.retryPending();
    await pay.settle();
    final charge = (await a.lookup('order'))!.charges.single;
    expect(charge.disposition, 'delivered');
    expect(charge.reason, isNull);
    expect(calls, 2);
    expect(store.submitted, hasLength(1));
    expect(store.finished, hasLength(1));
  });

  for (final replyFirst in [false, true]) {
    test('new evidence supersedes blocking reply, replyFirst=$replyFirst',
        () async {
      final old = Completer<AppleVerification>(), entered = Completer<void>();
      final seen = <AppleReceipt>[];
      final a = pay.connect(
          scope: 'A',
          verify: (r) async {
            seen.add(r);
            if (seen.length == 1) {
              entered.complete();
              return old.future;
            }
            return delivered(r);
          });
      final order = await a.buy(productId: 'sku', orderId: 'order');
      store.event(order.attemptId, 'T', receipt: 'old');
      await entered.future;
      if (replyFirst) {
        old.complete(const AppleVerification.needsReconciliation());
        await pay.settle();
      }
      store.event(order.attemptId, 'T', receipt: 'replacement');
      await pay.settle();
      if (!replyFirst) {
        old.complete(const AppleVerification.needsReconciliation());
        await pay.settle();
      }
      expect(seen.map((r) => r.receipt), ['old', 'replacement']);
      expect(store.finished, hasLength(1));
      expect(
          (await a.lookup('order'))!.charges.single.disposition, 'delivered');
    });
  }

  for (final replyFirst in [false, true]) {
    test(
        'a trusted attempt binding rechecks the same bytes, replyFirst=$replyFirst',
        () async {
      final blocked = Completer<AppleVerification>(),
          entered = Completer<void>();
      final seen = <AppleReceipt>[];
      final a = pay.connect(
          scope: 'A',
          verify: (r) async {
            seen.add(r);
            if (seen.length == 1) {
              entered.complete();
              return blocked.future;
            }
            return delivered(r);
          });
      final token =
          (await a.buy(productId: 'sku', orderId: 'order')).attemptId!;
      AppleClaim claim(String? uuid) => AppleClaim(
          appId: 'app',
          environment: 'sandbox',
          scope: 'A',
          orderId: 'order',
          productId: 'sku',
          reportedTransactionId: 'T',
          verifiedTransactionId: 'T',
          reference: uuid == null ? 'ownership' : 'submission',
          purchaseToken: uuid);
      store.event(null, 'T', handle: 'worker');
      await pay.settle();
      await proveQueue(pay, claim(null));
      await entered.future;
      expect(seen.single.attemptId, isNull);
      if (replyFirst) {
        blocked.complete(const AppleVerification.needsReconciliation());
        await pay.settle();
        await pay.reconcile(claim(null));
        await pay.retryPending();
        await pay.settle();
        expect(seen, hasLength(1));
      }
      await pay.reconcile(claim(token));
      await pay.settle();
      if (!replyFirst) {
        blocked.complete(const AppleVerification.invalidEvidence());
        await pay.settle();
      }
      expect(seen.map((r) => r.receipt), ['good', 'good']);
      expect(seen.last.attemptId, token);
      expect(seen.last.purchaseToken, token);
      expect(store.finished, hasLength(1));
      expect(store.submitted, hasLength(1));
    });
  }

  test(
      'merging two observed charges revokes both old calls and routes late responses',
      () async {
    final a = pay.connect(scope: 'A', verify: (r) async => delivered(r));
    final token = (await a.buy(productId: 'sku', orderId: 'order')).attemptId;
    a.dispose();
    AppleClaim alias(String reported) => AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'order',
        productId: 'sku',
        reportedTransactionId: reported,
        verifiedTransactionId: 'verified',
        reference: 'claim-$reported',
        purchaseToken: token);
    store.event(token, 'one', receipt: 'first');
    store.event(token, 'two', receipt: 'second');
    await pay.settle();
    await pay.reconcile(alias('one'));
    final beforeMerge = Completer<void>();
    final old = <String, Completer<AppleVerification>>{};
    final seen = <AppleReceipt>[];
    final active = pay.connect(
        scope: 'A',
        verify: (r) async {
          seen.add(r);
          if (seen.length <= 2) {
            final reply = old[r.transactionId] = Completer<AppleVerification>();
            if (old.length == 2) beforeMerge.complete();
            return reply.future;
          }
          return delivered(r, verified: 'verified');
        });
    await beforeMerge.future;
    await pay.reconcile(alias('two'));
    await pay.settle();
    expect(seen, hasLength(3));
    expect(store.finished.map((e) => e.transactionId),
        unorderedEquals(['one', 'two']));
    old['one']!.complete(const AppleVerification.needsReconciliation());
    final sourceReceipt = seen.firstWhere((r) => r.transactionId == 'two');
    old['two']!.complete(delivered(sourceReceipt, verified: 'verified'));
    await pay.settle();
    final charge = (await active.lookup('order'))!.charges.single;
    expect(charge.disposition, 'delivered');
    expect(charge.conflict, isFalse);
    expect(store.finished, hasLength(2));
  });

  test(
      'refresh after close cannot persist its result in another startup context',
      () async {
    store.event(null, 'waiting', receipt: '');
    await pay.settle();
    final oldStore = store;
    final refresh = pay.refreshReceipts();
    await oldStore.refreshing.future;
    await close();
    await open();
    oldStore.refreshed.complete('stale context');
    await refresh;
    final pending = await pay.unmatched();
    expect(pending.single.receipts, isEmpty);
    expect(store.finished, isEmpty);
  });

  test(
      'one refresh follows claimed and newly observed orphans across account change',
      () async {
    final seenA = <AppleReceipt>[], seenB = <AppleReceipt>[];
    pay.connect(
        scope: 'A',
        verify: (r) async {
          seenA.add(r);
          return const AppleVerification.invalidEvidence();
        });
    store.event(null, 'orphan', receipt: '');
    store.event(null, 'claimed', receipt: 'previous', handle: 'claimed-handle');
    await pay.settle();
    final refresh = pay.refreshReceipts();
    await store.refreshing.future;
    final b = pay.connect(
        scope: 'B',
        verify: (r) async {
          seenB.add(r);
          return r.receipt == 'fresh'
              ? delivered(r)
              : const AppleVerification.invalidEvidence();
        });
    await proveQueue(
        pay,
        const AppleClaim(
            appId: 'app',
            environment: 'sandbox',
            scope: 'B',
            orderId: 'B-order',
            productId: 'sku',
            reportedTransactionId: 'claimed',
            verifiedTransactionId: 'claimed',
            reference: 'claim-B'));
    await pay.settle();
    store.event(null, 'new', receipt: '');
    store.refreshed.complete('fresh');
    await refresh;
    await pay.settle();
    expect(seenA, isEmpty);
    expect(seenB.map((r) => r.receipt), ['previous', 'fresh']);
    expect(seenB.last.attemptId, isNull);
    expect(store.finished.map((e) => e.transactionId), ['claimed']);
    expect(store.refreshCount, 1);
    expect((await b.lookup('B-order'))!.attemptId, isNull);
    await close();
    await open();
    final retained = await pay.unmatched();
    expect(
        retained
            .where((r) => r.receipts.contains('fresh'))
            .map((r) => r.transactionId),
        unorderedEquals(['orphan', 'new']));
    expect(store.submitted, isEmpty);
  });
}
