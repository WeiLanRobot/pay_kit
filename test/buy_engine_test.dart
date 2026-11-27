import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

class _Payments extends Fake implements ApplePayments {
  final launches = <Completer<void>>[];
  Future<void> Function(String)? receive;
  void Function(String?, StoreStatus)? status;
  Object? owner;

  @override
  void attachLegacy(
      Object owner,
      Future<void> Function(String)? receiver,
      void Function(String?, StoreStatus) onStatus,
      void Function(Object) onError) {
    this.owner = owner;
    receive = receiver;
    status = onStatus;
  }

  @override
  void detachLegacy(Object owner) {
    if (identical(this.owner, owner)) this.owner = null;
  }

  @override
  Future<void> buyLegacy(Object owner, String productId, String orderId) {
    final launch = Completer<void>();
    launches.add(launch);
    return launch.future;
  }
}

void main() {
  _routingTests();
  late _Payments payments;
  late List<String> ui;
  late BuyEngine engine;

  setUp(() {
    payments = _Payments();
    ui = [];
    PayKit.initialize(DefaultPayConfig(
      showLoadingHandler: () => ui.add('open'),
      dismissLoadingHandler: () => ui.add('close'),
      messageResolver: (key) => key.name,
      showToastHandler: (message,
              {bool isTip = false, bool lengthLong = false}) =>
          ui.add(message),
      logHandler: (_, __) {},
    ));
    engine = BuyEngine(payments: payments);
  });
  tearDown(() {
    engine.dispose();
    PayKit.initialize(DefaultPayConfig());
  });

  test('an abandoned launch cannot close the next page or show a stale error',
      () async {
    engine.initialize((_) {});
    final oldStatus = payments.status!;
    engine.buyProduct('sku', 'a');
    engine.buyProduct('sku', 'a');
    expect(ui, ['open', 'processing']);
    engine.initialize((_) {});
    engine.buyProduct('sku', 'b');
    payments.launches.first.completeError(StateError('old launch'));
    oldStatus(null, StoreStatus.failed);
    await Future<void>.delayed(Duration.zero);
    expect(ui, ['open', 'processing', 'close', 'open']);
    payments.launches.last.complete();
    await Future<void>.delayed(Duration.zero);
    expect(ui.last, 'close');
    expect(payments.launches.length, 2);
  });

  test('legacy delivery awaits an asynchronous receipt callback', () async {
    final verified = Completer<void>();
    final received = <String>[];
    engine.initialize((String receipt) async {
      received.add(receipt);
      await verified.future;
    });
    var finished = false;
    final delivery = payments.receive!('receipt').then((_) {
      finished = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, ['receipt']);
    expect(finished, isFalse);
    verified.complete();
    await delivery;
    expect(finished, isTrue);
  });
}

class _LegacyStore extends Fake implements AppleStore {
  @override
  Future<String> bundleIdentifier() async => 'app';

  final updates = StreamController<List<StoreEvent>>.broadcast(sync: true);
  final launched = <String>[];
  final finished = <String?>[];

  @override
  Stream<List<StoreEvent>> get events => updates.stream;
  @override
  Future<void> prepare(String productId) async {}
  @override
  Future<bool> purchase(String productId, String token) async {
    launched.add(token);
    return true;
  }

  @override
  Future<void> finish(StoreEvent event) async {
    finished.add(event.transactionId);
  }

  void paid(String? token, String id) => updates.add([
        StoreEvent(
            status: StoreStatus.paid,
            productId: 'sku',
            token: token,
            transactionId: id,
            receipt: 'receipt-$id')
      ]);
}

void _routingTests() {
  group('1.2.0 receiver routing', () {
    late _LegacyStore store;
    late ApplePayments payments;
    setUp(() async {
      store = _LegacyStore();
      addTearDown(store.updates.close);
      final dir = await Directory.systemTemp.createTemp('pay-kit-legacy-');
      addTearDown(() => dir.delete(recursive: true));
      payments = ApplePayments.forTesting(
          store, AppleJournal(() async => File('${dir.path}/orders')));
      await payments.start(environment: 'sandbox');
      addTearDown(payments.close);
    });

    Object attach(List<String> receipts) {
      final owner = Object();
      payments.attachLegacy(owner, (receipt) async {
        receipts.add(receipt);
      }, (_, __) {}, (_) {});
      return owner;
    }

    test(
        'after reinstall a legacy listener cannot claim a managed UUID or missing token',
        () async {
      final receipts = <String>[];
      attach(receipts);
      store.paid('8C73EF3A-2AD7-45AB-9566-3DF6C748569F', 'managed');
      store.paid(null, 'missing');
      store.paid('pre-upgrade-order', 'legacy');
      await payments.retryPending();
      await payments.settle();
      expect(receipts, isEmpty);
      expect(store.finished, isEmpty);
      expect((await payments.unmatched()).map((e) => e.transactionId),
          unorderedEquals(['managed', 'missing', 'legacy']));
    });

    test('only the launching legacy page receives the delayed result',
        () async {
      final first = <String>[];
      final second = <String>[];
      final a = attach(first);
      final b = attach(second);
      await payments.buyLegacy(a, 'sku', 'old-order');
      await payments.buyLegacy(b, 'sku', 'new-order');
      store.paid(store.launched.last, '2');
      store.paid(store.launched.first, '1');
      await payments.retryPending();
      await payments.settle();
      expect(first, ['receipt-1']);
      expect(second, ['receipt-2']);
      expect(store.finished, unorderedEquals(['1', '2']));
    });

    test(
        'unattributed historical receipts stay pending with competing receivers',
        () async {
      final first = <String>[];
      final second = <String>[];
      final a = attach(first);
      attach(second);
      store.paid(null, 'historic');
      await payments.retryPending();
      await payments.settle();
      expect((await payments.unmatched()).single.transactionId, 'historic');
      final current = payments.connect(
          scope: 'alice',
          verify: (_) async => const AppleVerification.retryLater());
      await current.buy(orderId: 'new-order', productId: 'sku');
      payments.detachLegacy(a);
      await payments.retryPending();
      await payments.settle();
      expect(first, isEmpty);
      expect(second, isEmpty);
      expect(store.finished, isEmpty);
      expect((await payments.unmatched()).single.transactionId, 'historic');
    });

    test(
        'a surviving legacy page cannot claim a known order even by its old string',
        () async {
      final closed = <String>[];
      final original = attach(closed);
      await payments.buyLegacy(original, 'sku', 'legacy-order');
      payments.detachLegacy(original);
      final verified = <String>[];
      final account = payments.connect(
          scope: 'new-account',
          verify: (receipt) async {
            verified.add(receipt.orderId);
            return const AppleVerification.retryLater();
          });
      await account.buy(productId: 'sku', orderId: 'managed-order');
      final survivor = <String>[];
      final other = attach(survivor);
      store.paid('legacy-order', 'legacy-tx');
      await payments.retryPending();
      await payments.settle();
      expect(survivor, isEmpty);
      expect(closed, isEmpty);
      expect(verified, isEmpty);
      expect(store.finished, isEmpty);
      await expectLater(
          payments.buyLegacy(other, 'sku', 'legacy-order'), throwsStateError);
      await payments.retryPending();
      await payments.settle();
      expect(store.launched, hasLength(2));
      expect(survivor, isEmpty);
      expect(store.finished, isEmpty);
    });

    test('a UUID already used by legacy cannot be claimed in a different case',
        () async {
      const uuid = 'abcdef01-2345-4678-9012-abcdefabcdef';
      final legacy = <String>[];
      final original = attach(legacy);
      await payments.buyLegacy(original, 'sku', uuid.toUpperCase());
      final managed = <String>[];
      final account = payments.connect(
          scope: 'other',
          verify: (r) async {
            managed.add(r.orderId);
            return const AppleVerification.retryLater();
          });
      await expectLater(
          account.buy(
              orderId: 'different', productId: 'sku', purchaseToken: uuid),
          throwsStateError);
      expect(store.launched, hasLength(1));
      store.paid(store.launched.single, 'old');
      await payments.retryPending();
      await payments.settle();
      expect(legacy, ['receipt-old']);
      expect(managed, isEmpty);
    });
  });
}
