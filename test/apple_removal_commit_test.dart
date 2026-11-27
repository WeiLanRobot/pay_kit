import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_payments.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

class _Store extends ProbeStore {
  final calls = <Object?>[];
  final started = Completer<void>();
  final release = Completer<void>();
  bool pause = false;

  // A no-data refresh drains prior store messages without waiting for a pending finish.
  @override
  Future<String?> refreshReceipt() async => null;

  @override
  Future<void> finish(StoreEvent event) async {
    calls.add(event.native);
    if (!started.isCompleted) started.complete();
    if (pause) await release.future;
    await super.finish(event);
  }

  void paid(String handle, String report, {String? token, String? queue}) {
    stream.add([
      StoreEvent(
          productId: 'sku',
          native: handle,
          queueId: queue,
          status: StoreStatus.paid,
          transactionId: report,
          token: token,
          receipt: 'same-app-receipt')
    ]);
  }
}

void main() {
  late Directory dir;
  late AppleJournal db;
  late ApplePayments pay;
  late _Store store;

  Future<void> open() async {
    db = AppleJournal(() async => File('${dir.path}/ledger'));
    store = _Store();
    pay = ApplePayments.forTesting(store, db);
    await pay.start(environment: 'sandbox');
  }

  Future<void> close() async {
    if (!store.release.isCompleted) store.release.complete();
    await pay.close();
    await store.stream.close();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('paykit-removal-commit-');
    await open();
  });

  tearDown(() async {
    await close();
    await dir.delete(recursive: true);
  });

  AppleAccount login() =>
      pay.connect(scope: 'A', verify: (r) async => delivered(r));

  test('removal releases only this cold handle and its observation bytes',
      () async {
    store.paid('one', 'T', queue: 'Q');
    store.paid('other', 'U');
    await pay.settle();
    expect(pay.cachedReceiptCounts, (queue: 0, recovery: 2));
    final observation =
        (await pay.unmatched()).singleWhere((r) => r.transactionId == 'T').id;
    final acct = login();
    store.pause = true;
    await pay.reconcile(AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        productId: 'sku',
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: 'server-T',
        observationId: observation));
    await store.started.future;
    // A different object can carry the same reported transaction and queue ID.
    store.paid('foreign', 'T', queue: 'Q');
    await pay.refreshReceipts();
    expect(
        await db.read((tx) => tx.rawQuery(
            "SELECT id FROM recovery.observation WHERE objectKey='handle:foreign'")),
        hasLength(1));
    expect(store.calls, ['one']);
    expect(store.finished, isEmpty);
    store.release.complete();
    await pay.settle();
    expect(store.calls, ['one']);
    expect(pay.cachedReceiptCounts, (queue: 0, recovery: 2));
    expect((await acct.lookup('O'))!.charges.single.finishPending, false);
    Future<void> checkBody() async {
      final observations = await db.read((tx) => tx.rawQuery(
          'SELECT objectKey, finished FROM recovery.observation ORDER BY objectKey'));
      expect(
          observations
              .firstWhere((r) => r['objectKey'] == 'handle:one')['finished'],
          1);
      expect(
          observations.firstWhere(
              (r) => r['objectKey'] == 'handle:foreign')['finished'],
          0);
      final candidates = await db.read(
          (tx) => tx.rawQuery('SELECT observation FROM recovery.candidate'));
      expect(candidates.map((r) => r['observation']),
          isNot(contains(observation)));
      expect(
          await db.read((tx) => tx.rawQuery('SELECT body FROM recovery.body')),
          [
            {'body': 'same-app-receipt'}
          ]);
    }

    await checkBody();
    store.paid('one', 'T', queue: 'Q');
    store.paid('new-handle', 'T', queue: 'Q');
    await pay.settle();
    expect(store.calls, ['one']);
    expect(pay.cachedReceiptCounts, (queue: 0, recovery: 3));
    expect((await pay.unmatched()).map((r) => r.transactionId), contains('T'));
    await checkBody();
    await close();
    await open();
    expect((await login().lookup('O'))!.charges.single.finishPending, false);
    expect(store.calls, isEmpty);
  });

  test(
      'a removal whose conditional update touched zero rows retries SQLite only',
      () async {
    final account = login();
    final token = (await account.buy(productId: 'sku', orderId: 'O')).attemptId;
    await db.write((tx) => tx.execute('''
      CREATE TEMP TRIGGER ignore_finish BEFORE UPDATE OF finished ON queue_item
      BEGIN SELECT RAISE(IGNORE); END'''));
    store.paid('H', 'T', token: token);
    await pay.settle();
    expect(store.calls, ['H']);
    expect(store.finished.single.native, 'H');
    expect(pay.cachedReceiptCounts.queue, 1);
    expect((await account.lookup('O'))!.charges.single.finishPending, true);
    await db.write((tx) => tx.execute('DROP TRIGGER ignore_finish'));
    await pay.retryPending();
    await pay.settle();
    expect(store.calls, ['H']);
    expect(pay.cachedReceiptCounts.queue, 0);
    expect((await account.lookup('O'))!.charges.single.finishPending, false);
  });

  test(
      'enrichment merges the provisional row while its native request is pending',
      () async {
    final account = login();
    final token = (await account.buy(productId: 'sku', orderId: 'O')).attemptId;
    store.pause = true;
    store.paid('provisional', 'T', token: token);
    await store.started.future;
    store.paid('stable-wrapper', 'T', token: token, queue: 'Q');
    store.paid('provisional', 'T', token: token, queue: 'Q');
    // Wait for the queue merge itself, without awaiting the held native call.
    await pay.refreshReceipts();
    final items = await db.read((tx) => tx.query('queue_item'));
    expect(items.map((r) => r['id']), ['queue:Q']);
    expect(items.single['finished'], 0);
    await pay.retryPending();
    expect(store.calls, ['provisional']);
    expect(store.finished, isEmpty);
    store.release.complete();
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['provisional']);
    expect(store.calls, ['provisional']);
    expect((await account.lookup('O'))!.charges.single.finishPending, false);
    store.paid('provisional', 'T', token: token);
    await pay.settle();
    expect(store.calls, ['provisional']);
    expect(pay.cachedReceiptCounts, (queue: 0, recovery: 0));
  });
}
