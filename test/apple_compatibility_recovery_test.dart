import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';
import 'package:sqflite/sqflite.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

void main() {
  const wire = 'e6e2110c-9af8-4892-8b5c-63b09620aaa8';
  const transaction = 'apple-reported';
  late Directory dir;
  late ProbeStore store;
  late ApplePayments payments;

  void open() {
    store = ProbeStore();
    payments = ApplePayments.forTesting(
        store, AppleJournal(() async => File('${dir.path}/ledger')));
  }

  Future<void> close() async {
    await payments.close();
    await store.stream.close();
  }

  Future<void> restart(String environment) async {
    await close();
    open();
    await payments.start(environment: environment);
  }

  AppleClaim claim(String environment,
          {String? observationId, String? token = wire}) =>
      AppleClaim(
          appId: 'app',
          environment: environment,
          scope: 'A',
          orderId: wire,
          productId: 'sku',
          reportedTransactionId: transaction,
          verifiedTransactionId: transaction,
          purchaseToken: token,
          reference: 'verified-$environment',
          observationId: observationId);

  void observe(String handle, String? token, String receipt) =>
      store.stream.add([
        StoreEvent(
            productId: 'sku',
            token: token,
            status: StoreStatus.paid,
            native: handle,
            queueId: transaction,
            transactionId: transaction,
            receipt: receipt)
      ]);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('compat-receipt-');
    open();
  });
  tearDown(() async {
    await close();
    await dir.delete(recursive: true);
  });

  Future<void> unhanded() async {
    final owner = Object();
    payments.attachLegacy(owner, (_) async => fail('detached receiver called'),
        (_, __) {}, (_) {});
    await payments.buyLegacy(owner, 'sku', wire);
    payments.detachLegacy(owner);
    observe('legacy', wire, 'first receipt');
    observe('legacy', wire, 'updated receipt');
    await payments.settle();
    expect(store.finished, isEmpty);
  }

  test(
      'cached v4 compatibility ledger exposes all unhanded evidence without store replay',
      () async {
    await unhanded();
    await close();
    // The old version considered this revision fully indexed.
    final old =
        await openDatabase('${dir.path}/ledger.compat', singleInstance: false);
    final revision = (await old.query('meta')).single['revision'].toString();
    await old.setVersion(4);
    await old.close();
    final recovery = await openDatabase('${dir.path}/ledger.observations',
        singleInstance: false);
    await recovery.rawInsert(
        'INSERT OR REPLACE INTO indexed_partition VALUES (?,?,?)',
        ['.compat', 4, revision]);
    await recovery.close();
    open();
    await payments.start(environment: 'sandbox');
    final verified = <AppleReceipt>[];
    final a = payments.connect(
        scope: 'A',
        verify: (r) async {
          verified.add(r);
          return delivered(r);
        });
    await payments.settle();
    final saved = (await payments.unmatched()).single;
    expect(saved.transactionId, transaction);
    expect(
        saved.receipts, unorderedEquals(['first receipt', 'updated receipt']));
    expect(verified, isEmpty);
    expect(await a.lookup(wire), isNull);
    expect(store.finished, isEmpty);
    await payments.reconcile(claim('sandbox', observationId: saved.id));
    await payments.settle();
    await payments.reconcile(claim('sandbox', observationId: saved.id));
    await payments.settle();
    expect(verified, hasLength(1));
    expect((await a.lookup(wire))!.charges.single.finishPending, isTrue);
    expect(await payments.unmatched(), isEmpty);
    expect(store.finished, isEmpty);
    await restart('sandbox');
    observe('current', null, 'shared receipt');
    await payments.settle();
    await payments.reconcile(claim('sandbox'));
    await payments.settle();
    expect(store.finished, isEmpty);
    observe('current', wire, 'shared receipt');
    await payments.settle();
    await payments.reconcile(claim('sandbox'));
    await payments.settle();
    expect(store.finished.map((e) => e.native), ['current']);
    expect(store.submitted, isEmpty);
    await restart('production');
    observe('other', wire, 'shared receipt');
    await payments.settle();
    await expectLater(
        payments.reconcile(claim('production')), throwsStateError);
    await expectLater(
        payments.reconcile(claim('production', token: null)), throwsStateError);
    expect(store.finished, isEmpty);
  });

  test(
      'live transition with unhanded receipt and later restarts keep one recovery destination',
      () async {
    await unhanded();
    await payments.start(environment: 'sandbox');
    final archived = (await payments.unmatched()).single;
    expect(archived.receipts,
        unorderedEquals(['first receipt', 'updated receipt']));
    expect(store.finished, isEmpty);
    await restart('production');
    expect(await payments.unmatched(), isEmpty);
    await restart('sandbox');
    expect((await payments.unmatched()).single.id, archived.id);
    expect(store.finished, isEmpty);
  });
}
