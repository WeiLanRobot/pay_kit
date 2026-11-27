import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/src/iap/apple_payments.dart';

import 'apple_payments_test.dart' show FaultJournal, ProbeStore, delivered;

void main() {
  late Directory dir;
  late ApplePayments payments;
  late FaultJournal journal;
  late ProbeStore store;
  final alarms = <({Timer timer, Duration delay, void Function() fire})>[];
  const deadline = Duration(seconds: 12);
  Completer<void>? nextRetry;
  Future<void> open() async {
    store = ProbeStore();
    journal = FaultJournal(() async => File('${dir.path}/ledger'));
    payments = ApplePayments.forTesting(store, journal,
        verificationTimeout: deadline, timerFactory: (delay, callback) {
      final timer = Timer(const Duration(days: 1), callback);
      alarms.add((timer: timer, delay: delay, fire: callback));
      if (delay == const Duration(seconds: 1)) {
        nextRetry?.complete();
        nextRetry = null;
      }
      return timer;
    });
    await payments.start(environment: 'sandbox');
  }

  void advance(Duration delay) {
    final alarm =
        alarms.singleWhere((a) => a.timer.isActive && a.delay == delay);
    alarm.timer.cancel();
    alarm.fire();
  }

  Future<void> close() async {
    await payments.close();
    await store.stream.close();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('paykit-rotation');
    alarms.clear();
    nextRetry = null;
    await open();
  });
  tearDown(() async {
    await close();
    await dir.delete(recursive: true);
  });

  test('a persisted timeout rotates all tried receipts across restart',
      () async {
    var hang = false;
    final firstTimeout = Completer<void>();
    final firstReply = Completer<AppleVerification>();
    final firstPass = <String>[];
    final a = payments.connect(
        scope: 'A',
        verify: (receipt) async {
          firstPass.add(receipt.receipt);
          if (hang) {
            firstTimeout.complete();
            return firstReply.future;
          }
          return const AppleVerification.retryLater();
        });
    final order = await a.buy(productId: 'sku', orderId: 'order');
    for (final body in ['one', 'two', 'three']) {
      store.event(order.attemptId, 'T', receipt: body);
      await payments.settle();
    }
    expect(firstPass.sublist(firstPass.length - 3), ['three', 'two', 'one']);
    hang = true;
    advance(const Duration(seconds: 1));
    await firstTimeout.future;
    expect(firstPass.last, 'three');
    advance(deadline);
    await payments.settle();
    store.event(order.attemptId, 'T', receipt: 'three');
    await payments.settle();
    expect(store.submitted, hasLength(1));
    await close();
    await open();

    final unexpected = <AppleReceipt>[];
    payments.connect(
        scope: 'B',
        verify: (r) async {
          unexpected.add(r);
          return const AppleVerification.needsReconciliation();
        });
    await payments.settle();
    final nextDispatch = Completer<void>();
    final secondReply = Completer<AppleVerification>();
    final afterRestart = <String>[];
    var grants = 0;
    final current = payments.connect(
        scope: 'A',
        verify: (r) async {
          afterRestart.add(r.receipt);
          if (afterRestart.length == 1) {
            nextDispatch.complete();
            return secondReply.future;
          }
          grants++;
          return delivered(r);
        });
    await nextDispatch.future;
    advance(deadline);
    await payments.settle();
    secondReply.complete(const AppleVerification.invalidEvidence());
    await payments.settle();
    expect(afterRestart, ['two']);
    advance(const Duration(seconds: 1));
    await payments.settle();
    expect(afterRestart, ['two', 'one']);
    expect(grants, 1);
    expect(unexpected, isEmpty);
    expect(store.submitted, isEmpty);
    expect((await current.lookup('order'))!.charges.single.disposition,
        'delivered');
  });

  test('timeout progress retries a failed write before dispatch resumes',
      () async {
    final entered = Completer<void>();
    final reply = Completer<AppleVerification>();
    var calls = 0;
    final a = payments.connect(
        scope: 'A',
        verify: (r) async {
          if (++calls == 1) {
            entered.complete();
            return reply.future;
          }
          return delivered(r);
        });
    final order = await a.buy(productId: 'sku', orderId: 'order');
    store.event(order.attemptId, 'T');
    await entered.future;
    journal.writable = false;
    advance(deadline);
    await payments.settle();
    reply.complete(const AppleVerification.invalidEvidence());
    await payments.retryPending();
    await payments.settle();
    expect(calls, 1);
    journal.writable = true;
    final scheduled = nextRetry = Completer<void>();
    advance(const Duration(seconds: 1)); // Retry the timeout write.
    await scheduled.future;
    await payments.settle();
    expect(calls, 1);
    advance(const Duration(seconds: 1)); // Resume verifier backoff.
    await payments.settle();
    expect(calls, 2);
    expect(store.finished, hasLength(1));
  });

  test('a trusted environment proof remains effective after timeout', () async {
    final entered = Completer<AppleReceipt>();
    final result = Completer<AppleVerification>();
    final a = payments.connect(
        scope: 'A',
        verify: (r) {
          entered.complete(r);
          return result.future;
        });
    final order = await a.buy(productId: 'sku', orderId: 'order');
    store.event(order.attemptId, 'T');
    final receipt = await entered.future;
    advance(deadline);
    await payments.settle();
    result.complete(AppleVerification.environmentMismatch(
        AppleEnvironmentMismatch(
            appId: 'app',
            expectedEnvironment: 'sandbox',
            actualEnvironment: 'production',
            reportedTransactionId: 'T',
            verifiedTransactionId: 'T',
            productId: 'sku',
            issuer: 'server',
            reference: 'env-proof',
            purchaseToken: receipt.purchaseToken)));
    await payments.settle();
    expect((await a.lookup('order'))!.reason, 'environmentMismatch');
    expect(store.finished, isEmpty);
    expect(store.submitted, hasLength(1));
  });
}
