import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';
import 'package:sqflite/sqflite.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

/// Place a StoreKit replay between recording a legacy attempt and submitting it.
class _PreparationBarrier extends AppleJournal {
  _PreparationBarrier(super.location);
  final prepared = Completer<void>();
  final release = Completer<void>();

  @override
  Future<T> write<T>(Future<T> Function(DatabaseExecutor) operation) {
    return super.write((db) async {
      final result = await operation(db);
      if (!prepared.isCompleted && result is String) {
        final rows = await db.query('attempt',
            where: "id=? AND phase='prepared'", whereArgs: [result]);
        if (rows.isNotEmpty) {
          prepared.complete();
          await release.future;
        }
      }
      return result;
    });
  }
}

void main() {
  late Directory directory;
  late ProbeStore store;
  late ApplePayments payments;
  late BuyEngine page;
  late Completer<void> dismissed;
  late List<String> messages;

  Future<void> start(AppleJournal journal, ReceiptCallback receive,
      {bool legacyOnly = false}) async {
    payments = ApplePayments.forTesting(store, journal);
    if (!legacyOnly) await payments.start(environment: 'sandbox');
    dismissed = Completer();
    messages = [];
    PayKit.initialize(DefaultPayConfig(
      showLoadingHandler: () {},
      dismissLoadingHandler: () => dismissed.complete(),
      messageResolver: (key) => key.name,
      showToastHandler: (message,
              {bool isTip = false, bool lengthLong = false}) =>
          messages.add(message),
      logHandler: (_, __) {},
    ));
    page = BuyEngine(payments: payments)..initialize(receive);
    addTearDown(() async {
      page.dispose();
      await payments.close();
    });
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('paykit-legacy');
    store = ProbeStore();
  });
  tearDown(() async {
    await store.stream.close();
    await directory.delete(recursive: true);
    PayKit.initialize(DefaultPayConfig());
  });

  test('an active legacy page retries the requested environment before buying',
      () async {
    final journal = AppleJournal(() async => File('${directory.path}/ledger'));
    await start(journal, (_) {}, legacyOnly: true);
    await payments.retryPending();
    Future<Object?> environment() => journal
        .read((db) async => (await db.query('meta')).single['environment']);
    expect(await environment(), isNull);

    store.runningBundle = '';
    await expectLater(
        payments.start(environment: 'production'), throwsStateError);
    page.buyProduct('sku', 'order');
    await dismissed.future;
    expect(store.submitted, isEmpty);
    expect(await journal.read((db) => db.query('attempt')), isEmpty);

    store.runningBundle = 'app';
    final environmentsAtPurchase = <Object?>[];
    store.launch = () async {
      environmentsAtPurchase.add(await environment());
      return true;
    };
    dismissed = Completer();
    page.buyProduct('sku', 'order');
    await dismissed.future;
    expect(environmentsAtPurchase, ['production']);
    expect(store.submitted, ['order']);
    expect((await journal.read((db) => db.query('attempt'))).single['orderId'],
        'order');
  });

  test(
      'a pre-submission replay is recoverable and cannot be handed to a new page',
      () async {
    final journal =
        _PreparationBarrier(() async => File('${directory.path}/ledger'));
    final received = <String>[];
    await start(journal, received.add);
    page.buyProduct('sku', 'legacy-order');
    await journal.prepared.future;
    store.event('legacy-order', 'old-charge');
    await Future<void>.delayed(Duration.zero);
    journal.release.complete();
    await dismissed.future;
    await payments.settle();
    expect(store.submitted, isEmpty);
    expect(received, isEmpty);
    expect(store.finished, isEmpty);
    expect((await payments.unmatched()).single.transactionId, 'old-charge');

    final account = payments.connect(
        scope: 'original-account', verify: (r) async => delivered(r));
    await payments.reconcile(const AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'original-account',
        orderId: 'legacy-order',
        productId: 'sku',
        reportedTransactionId: 'old-charge',
        verifiedTransactionId: 'old-charge',
        reference: 'verified-on-server'));
    await payments.settle();
    expect((await account.lookup('legacy-order'))!.charges.single.disposition,
        'delivered');
    expect(store.finished.single.transactionId, 'old-charge');
    expect(received, isEmpty);
  });

  test('a late payment on a canceled order blocks its receiver again',
      () async {
    await start(AppleJournal(() async => File('${directory.path}/ledger')),
        (receipt) {});
    page.buyProduct('sku', 'first');
    await dismissed.future;
    store.event('first', null, queue: 'cancel', status: StoreStatus.canceled);
    await payments.settle();

    dismissed = Completer();
    page.buyProduct('sku', 'second');
    await dismissed.future;
    store.event('second', 'second-charge');
    await payments.settle();
    expect(store.submitted, ['first', 'second']);

    store.event('first', 'late-charge');
    await payments.settle();
    expect((await payments.unmatched()).single.reason, 'paymentAfterUnpaid');
    dismissed = Completer();
    page.buyProduct('sku', 'third');
    await dismissed.future;
    expect(store.submitted, ['first', 'second']);
  });

  for (final reply in ['accepted', 'declined', 'uncertain']) {
    for (final status in StoreStatus.values) {
      test('early ${status.name} with native reply $reply', () async {
        final read = <String>[],
            entered = Completer<void>(),
            result = Completer<bool>();
        store.launch = () {
          entered.complete();
          return result.future;
        };
        await start(AppleJournal(() async => File('${directory.path}/ledger')),
            read.add);
        page.buyProduct('sku', 'legacy-order');
        await entered.future;
        store.event('legacy-order', 'charge', status: status);
        await payments.settle();
        final terminal =
            status == StoreStatus.canceled || status == StoreStatus.failed;
        expect(messages, isEmpty);
        expect(read, isEmpty);
        expect(
            store.finished.map((e) => e.status), terminal ? [status] : isEmpty);

        switch (reply) {
          case 'accepted':
            result.complete(true);
          case 'declined':
            result.completeError(const StorePurchaseRejected());
          case 'uncertain':
            result.completeError(StateError('native reply lost'));
        }
        await dismissed.future;
        await payments.settle();
        final accepted = reply == 'accepted';
        final paid = status == StoreStatus.paid;
        final message = switch (reply) {
          'uncertain' => 'processing',
          'declined' => 'processing',
          _ => switch (status) {
              StoreStatus.canceled => 'payCancel',
              StoreStatus.failed => 'payFailed',
              _ => null
            },
        };
        expect(messages, message == null ? isEmpty : [message]);
        expect(read, accepted && paid ? ['good'] : isEmpty);
        expect(store.finished.map((e) => e.status),
            terminal || accepted && paid ? [status] : isEmpty);
        if (!accepted && paid) {
          expect((await payments.unmatched()).single.transactionId, 'charge');
        }
        if (!paid && reply == 'uncertain') {
          expect(
              (await payments.unresolvedAttempts()).single.phase, 'uncertain');
        }

        // A definitive refusal releases the submitting page, even while a
        // historical transaction awaits authenticated reconciliation.
        store.launch = null;
        dismissed = Completer();
        page.buyProduct('other-sku', 'fresh-order');
        await dismissed.future;
        final released =
            reply == 'declined' || accepted && status != StoreStatus.pending;
        expect(store.submitted,
            released ? ['legacy-order', 'fresh-order'] : ['legacy-order']);
        if (!accepted && paid) {
          final account =
              payments.connect(scope: 'A', verify: (r) async => delivered(r));
          await payments.reconcile(const AppleClaim(
              appId: 'app',
              environment: 'sandbox',
              scope: 'A',
              orderId: 'legacy-order',
              productId: 'sku',
              reportedTransactionId: 'charge',
              verifiedTransactionId: 'charge',
              reference: 'server-proof'));
          await payments.settle();
          expect(
              (await account.lookup('legacy-order'))!
                  .charges
                  .single
                  .disposition,
              'delivered');
          expect(store.finished.single.transactionId, 'charge');
          expect(read, isEmpty);
        }
      });
    }
  }

  for (final paidFirst in [false, true]) {
    test(
        'a contradictory legacy replay before the native reply (paidFirst=$paidFirst)',
        () async {
      final read = <String>[],
          entered = Completer<void>(),
          result = Completer<bool>();
      store.launch = () {
        entered.complete();
        return result.future;
      };
      await start(
          AppleJournal(() async => File('${directory.path}/ledger')), read.add);
      page.buyProduct('sku', 'legacy-order');
      await entered.future;
      void paid() => store.event('legacy-order', 'tx', queue: 'paid-item');
      void canceled() => store.event('legacy-order', null,
          queue: 'canceled-item', status: StoreStatus.canceled);
      if (paidFirst) {
        paid();
        canceled();
      } else {
        canceled();
        paid();
      }
      await payments.settle();
      result.complete(true);
      await dismissed.future;
      await payments.settle();
      expect(read, paidFirst ? ['good'] : isEmpty);
      expect(store.finished.where((e) => e.status == StoreStatus.paid).length,
          paidFirst ? 1 : 0);
      if (!paidFirst) {
        expect(
            (await payments.unmatched()).single.reason, 'paymentAfterUnpaid');
        final account =
            payments.connect(scope: 'A', verify: (r) async => delivered(r));
        await payments.reconcile(const AppleClaim(
            appId: 'app',
            environment: 'sandbox',
            scope: 'A',
            orderId: 'legacy-order',
            productId: 'sku',
            reportedTransactionId: 'tx',
            verifiedTransactionId: 'tx',
            reference: 'server-proof'));
        await payments.settle();
        expect(
            (await account.lookup('legacy-order'))!.charges.single.disposition,
            'delivered');
        expect(read, isEmpty);
      }
    });
  }

  test(
      'a later unusable receipt cannot indefinitely hide an older usable receipt',
      () async {
    final tried = <String>[];
    var online = false;
    await start(AppleJournal(() async => File('${directory.path}/ledger')),
        (String body) async {
      tried.add(body);
      if (!online || body == 'bad') {
        throw StateError('delivery not acknowledged');
      }
    });
    page.buyProduct('sku', 'legacy-order');
    await dismissed.future;
    store.event('legacy-order', 'charge', receipt: 'good');
    await payments.settle();
    online = true;
    store.event('legacy-order', 'charge', receipt: 'bad');
    await payments.settle();
    expect(tried, ['good', 'bad', 'good']);
    expect(store.finished.single.transactionId, 'charge');
  });
}
