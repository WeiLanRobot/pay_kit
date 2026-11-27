import 'dart:async';
import 'dart:io';

import 'verified_queue_fixture.dart';

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
  Future<void> finish(StoreEvent event, {bool verifiedQueue = false}) async {
    calls.add(event.native);
    if (!started.isCompleted) started.complete();
    if (pause) await release.future;
    await super.finish(event, verifiedQueue: verifiedQueue);
  }

  void paid(String handle, String report,
      {String? token, String? queue, bool removed = false}) {
    stream.add([
      StoreEvent(
          productId: 'sku',
          native: handle,
          queueId: queue,
          status: StoreStatus.paid,
          transactionId: report,
          token: token,
          removed: removed,
          receipt: removed ? '' : 'same-app-receipt')
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

  test(
      'external removal withdraws only its handle and preserves unclaimed evidence',
      () async {
    store.paid('gone', 'T', queue: 'T');
    store.paid('still-queued', 'T', queue: 'T');
    await pay.settle();
    final rows = await db.read((tx) => tx.query('recovery.observation'));
    String id(String handle) =>
        rows.singleWhere((r) => r['objectKey'] == 'handle:$handle')['id']
            as String;
    store.paid('gone', 'T', queue: 'T', removed: true);
    store.paid('gone', 'T', queue: 'T'); // Older duplicate snapshot.
    await pay.settle();
    final observations = await pay.unmatched();
    expect(observations.expand((r) => r.currentObservationIds),
        [id('still-queued')]);
    expect(
        observations
            .singleWhere((r) => r.observations.containsKey(id('gone')))
            .receipts,
        ['same-app-receipt']);
    expect(pay.cachedReceiptCounts.recovery, 1);
    expect(store.calls, isEmpty);
    await close();
    await open();
    expect(
        await db.read((tx) =>
            tx.query('recovery.removed_object', columns: ['objectKey'])),
        [
          {'objectKey': 'handle:gone'}
        ]);
    expect(await db.read((tx) => tx.query('purchase')), isEmpty);
    expect(
        await db.read((tx) => tx.query('recovery.finish_authority')), isEmpty);
  });

  test('a later independently sourced claim keeps verified external removal',
      () async {
    final token =
        (await login().buy(productId: 'sku', orderId: 'O')).attemptId!;
    await close();
    await open();
    store.paid('gone', 'T', queue: 'T', token: token);
    await pay.settle();
    final id = (await pay.unmatched()).single.id;
    store.paid('gone', 'T', queue: 'T', token: token, removed: true);
    await pay.settle();
    final result = await pay.recoverObservation(AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        productId: 'sku',
        purchaseToken: token,
        observationId: id,
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: 'claim'));
    expect(result.state, AppleObservationState.removed);
    expect(result.disposition, isNull);
    expect((await login().lookup('O'))!.charges.single.finishPending, isFalse);
    expect(store.calls, isEmpty);
  });

  test('a failed removal write cannot revive the retired handle', () async {
    store.paid('gone', 'T', queue: 'T');
    await pay.settle();
    await db.write((tx) => tx.execute("""
      CREATE TEMP TRIGGER reject_removal BEFORE INSERT ON recovery.removed_object
      BEGIN SELECT RAISE(ABORT, 'storage unavailable'); END"""));
    store.paid('gone', 'T', queue: 'T', removed: true);
    await pay.settle();
    expect((await pay.unmatched()).single.currentObservationIds, isEmpty);
    expect(store.calls, isEmpty);
    await db.write((tx) => tx.execute('DROP TRIGGER reject_removal'));
    await pay.retryPending();
    await pay.settle();
    expect(pay.cachedReceiptCounts.recovery, 0);
    expect(await db.read((tx) => tx.query('recovery.removed_object')),
        hasLength(1));
    expect((await pay.unmatched()).single.receipts, ['same-app-receipt']);
  });

  test('late native removal commits an authorized item even after a dispute',
      () async {
    final acct = login();
    final token = (await acct.buy(productId: 'sku', orderId: 'O')).attemptId;
    store.failFinish = true;
    store.paid('late', 'T', queue: 'T', token: token);
    await pay.settle();
    expect((await acct.lookup('O'))!.charges.single.finishPending, isTrue);
    await db.write((tx) => tx.rawUpdate(
        "UPDATE purchase SET conflict=1,reason='identityConflict',disputeRevision=1 WHERE reportedId='T'"));
    final attempts = List.of(store.calls);
    store.paid('late', 'T', queue: 'T', token: token, removed: true);
    await pay.settle();
    final charge = (await acct.lookup('O'))!.charges.single;
    expect(charge.finishPending, isFalse);
    expect(
        await db.read(
            (tx) => tx.query('purchase', columns: ['conflict', 'disposition'])),
        [
          {'conflict': 1, 'disposition': 'delivered'}
        ]);
    expect(store.calls, attempts);
    expect(pay.cachedReceiptCounts.queue, 0);
  });

  test('removal releases only this cold handle and its observation bytes',
      () async {
    store.paid('one', 'T', queue: 'T');
    store.paid('other', 'U');
    await pay.settle();
    expect(pay.cachedReceiptCounts, (queue: 0, recovery: 2));
    final observation =
        (await pay.unmatched()).singleWhere((r) => r.transactionId == 'T').id;
    final acct = login();
    store.pause = true;
    await proveQueue(
        pay,
        AppleClaim(
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
    store.paid('foreign', 'T', queue: 'T');
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
    store.paid('one', 'T', queue: 'T');
    store.paid('new-handle', 'T', queue: 'T');
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
