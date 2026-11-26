import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

class _DelayedProductStore extends ProbeStore {
  final preparing = Completer<void>(), prepared = Completer<void>();

  @override
  Future<void> prepare(String productId) {
    preparing.complete();
    return prepared.future;
  }
}

class _AfterPrepare extends AppleJournal {
  _AfterPrepare(super.file);
  final waiting = Completer<void>(), release = Completer<void>();
  bool ready = false;
  @override
  Future<T> write<T>(Future<T> Function(DatabaseExecutor db) op) async {
    final result = await super.write(op);
    if (ready && !waiting.isCompleted && result is String) {
      waiting.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  late Directory directory;
  late _DelayedProductStore store;
  late ApplePayments payments;
  late AppleAccount account;
  late List<AppleReceipt> receipts;
  Future<void> start() async {
    store = _DelayedProductStore();
    payments = ApplePayments.forTesting(store,
        AppleJournal(() async => File('${directory.path}/ledger.sqlite')));
    await payments.start(environment: 'sandbox');
    account = payments.connect(
        scope: 'A',
        verify: (r) async {
          receipts.add(r);
          return delivered(r);
        });
  }

  Future<void> stop() async {
    await payments.close();
    await store.stream.close();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pay-order-contract');
    receipts = [];
    await start();
  });
  tearDown(() async {
    await stop();
    await directory.delete(recursive: true);
  });

  test(
      'recovering an order while its product is loading never submits a new attempt',
      () async {
    final pending = account.buy(productId: 'sku', orderId: 'O');
    await store.preparing.future;
    store.event(null, 'historical');
    await payments.settle();
    await payments.reconcile(const AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        productId: 'sku',
        reportedTransactionId: 'historical',
        verifiedTransactionId: 'historical',
        reference: 'authenticated-order'));
    store.prepared.complete();
    final order = await pending;
    await payments.settle();
    expect(order.attemptId, isNull);
    expect(order.phase, 'paid');
    expect(store.submitted, isEmpty);
    expect(receipts.single.attemptId, isNull);
    expect(await payments.unresolvedAttempts(), isEmpty);

    await stop();
    await start();
    final recovered = await account.buy(productId: 'sku', orderId: 'O');
    expect(recovered.charges.single.disposition, 'delivered');
    expect(recovered.attemptId, isNull);
    expect(store.preparing.isCompleted, isFalse);
    expect(store.submitted, isEmpty);
    await expectLater(
        account.buy(productId: 'other', orderId: 'O'), throwsStateError);
    final other =
        payments.connect(scope: 'B', verify: (r) async => delivered(r));
    expect(await other.lookup('O'), isNull);
  });

  for (final token in <String?>[null, 'c2487f2f-6051-4084-a42b-77f8cc024505']) {
    test('a recovered charge supersedes prepared checkout with token $token',
        () async {
      await stop();
      store = _DelayedProductStore();
      final journal =
          _AfterPrepare(() async => File('${directory.path}/ledger.sqlite'));
      payments = ApplePayments.forTesting(store, journal);
      await payments.start(environment: 'sandbox');
      account = payments.connect(scope: 'A', verify: (r) async => delivered(r));
      journal.ready = true;
      store.prepared.complete();
      final checkout =
          account.buy(productId: 'sku', orderId: 'O', purchaseToken: token);
      await journal.waiting.future;
      try {
        store.event(token, 'T');
        await payments.settle();
        final observed = (await payments.unmatched()).single;
        await payments.reconcile(AppleClaim(
            appId: 'app',
            environment: 'sandbox',
            scope: 'A',
            orderId: 'O',
            productId: 'sku',
            reportedTransactionId: 'T',
            verifiedTransactionId: 'T',
            reference: 'proof',
            observationId: observed.id,
            purchaseToken: token));
      } finally {
        journal.release.complete();
      }
      final order = await checkout;
      expect(store.submitted, isEmpty);
      expect(await payments.unresolvedAttempts(), isEmpty);
      expect(order.attemptId, isNull);
      expect(order.phase, 'paid');
    });
  }

  test('a definitive refusal and a later recovered charge show the paid order',
      () async {
    store.prepared.complete();
    store.launch = () async => false;
    expect(
        (await account.buy(productId: 'sku', orderId: 'O')).phase, 'declined');
    store.event(null, 'T');
    await payments.settle();
    final observed = (await payments.unmatched()).single;
    await payments.reconcile(AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        productId: 'sku',
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: 'server-proof',
        observationId: observed.id));
    await payments.settle();
    final order = await account.buy(productId: 'sku', orderId: 'O');
    expect(order.phase, 'paid');
    expect(order.charges.single.disposition, 'delivered');
    expect(store.submitted, hasLength(1));
  });

  test('a server reference is opaque and cannot hide a real pending attempt',
      () async {
    store.prepared.complete();
    final order = await account.buy(productId: 'sku', orderId: 'O');
    await payments.resolveAttempt(AppleAttemptDecision(
        appId: 'app',
        environment: 'sandbox',
        issuer: 'orders',
        decisionId: 'pending',
        reference: 'recovered-server-ticket',
        attemptId: order.attemptId!,
        orderId: 'O',
        scope: 'A',
        outcome: AppleAttemptOutcome.pending));
    expect((await payments.unresolvedAttempts()).single.attemptId,
        order.attemptId);
    expect((await account.buy(productId: 'sku', orderId: 'O')).attemptId,
        order.attemptId);
    store.event(order.attemptId, 'T');
    await payments.settle();
    expect(receipts.single.attemptId, order.attemptId);
    expect(store.submitted, hasLength(1));
  });

  test(
      'recovering an old raw order string cannot authenticate its original attempt',
      () async {
    final owner = Object();
    payments.attachLegacy(owner, (r) async {
      fail('unexpected handoff');
    }, (_, __) {}, (_) {});
    store.prepared.complete();
    await payments.buyLegacy(owner, 'sku', 'O');
    final original = (await payments.unresolvedAttempts()).single.attemptId;
    await stop();
    await start();
    store.event('O', 'T');
    await payments.settle();
    final item = (await payments.unmatched()).single;
    await payments.reconcile(AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        productId: 'sku',
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: 'order-only',
        observationId: item.id));
    await payments.settle();
    expect((await account.lookup('O'))!.attemptId, isNull);
    expect(receipts.single.attemptId, isNull);
    expect((await payments.unresolvedAttempts()).single.attemptId, original);
  });

  test(
      'finishing one recovered charge retains the shared receipt for the other',
      () async {
    store.event(null, 'T1', receipt: 'shared');
    store.event(null, 'T2', receipt: 'shared');
    await payments.settle();
    for (final transaction in ['T1', 'T2']) {
      final item = (await payments.unmatched())
          .singleWhere((i) => i.transactionId == transaction);
      expect(item.receipts, ['shared']);
      await payments.reconcile(AppleClaim(
          appId: 'app',
          environment: 'sandbox',
          scope: 'A',
          orderId: transaction,
          productId: 'sku',
          reportedTransactionId: transaction,
          verifiedTransactionId: transaction,
          reference: 'proof-$transaction',
          observationId: item.id));
      await payments.settle();
    }
    expect(store.finished.map((e) => e.transactionId), ['T1', 'T2']);
    expect(await payments.unmatched(), isEmpty);
    await stop();
    final reopened =
        AppleJournal(() async => File('${directory.path}/ledger.sqlite'));
    try {
      expect(
          await reopened
              .read((db) => db.rawQuery('SELECT hash FROM recovery.body')),
          isEmpty);
    } finally {
      await reopened.close();
      await start();
    }
  });

  test('empty legacy receiver may observe but cannot launch a payment',
      () async {
    final owner = Object();
    payments.attachLegacy(owner, null, (_, __) {}, (_) {});
    await expectLater(
        payments.buyLegacy(owner, 'sku', 'unused'), throwsStateError);
    expect(store.preparing.isCompleted, isFalse);
    expect(store.submitted, isEmpty);
    expect(store.finished, isEmpty);
  });
}
