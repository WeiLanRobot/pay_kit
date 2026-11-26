import 'dart:async';

import 'package:pay_kit/pay_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store extends Fake implements InAppPurchase {
  final events = StreamController<List<PurchaseDetails>>.broadcast();
  bool failNextCompletion = false;
  final finished = <PurchaseDetails>[];
  final product = ProductDetails(
      id: '17',
      title: '',
      description: '',
      price: '',
      rawPrice: 1,
      currencyCode: 'CNY');
  final requested = <PurchaseParam>[];
  Completer<ProductDetailsResponse>? lookup;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async =>
      lookup?.future ??
      Future.value(
          ProductDetailsResponse(productDetails: [product], notFoundIDs: []));
  @override
  Future<bool> buyConsumable(
      {required PurchaseParam purchaseParam, bool autoConsume = true}) async {
    requested.add(purchaseParam);
    return true;
  }

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => events.stream;
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    if (failNextCompletion) {
      failNextCompletion = false;
      throw StateError('StoreKit completion failed');
    }
    finished.add(purchase);
  }
}

AppStorePurchaseDetails _purchase(String? order) =>
    AppStorePurchaseDetails.fromSKTransaction(
        SKPaymentTransactionWrapper(
          payment: SKPaymentWrapper(
              productIdentifier: '17', applicationUsername: order),
          transactionIdentifier: 'transaction-$order',
          transactionState: SKPaymentTransactionStateWrapper.purchased,
        ),
        'receipt-for-$order');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scope = 'test-user-dog';
  late _Store store;
  late ApplePurchaseSession apple;
  late List<String> checked;
  var accept = true;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      scope: 'legacy',
      '$scope/order/old': '17',
      '$scope/order/new': '17',
    });
    store = _Store();
    checked = [];
    accept = true;
    apple = ApplePurchaseSession(scope, () => true, (id, receipt) async {
      checked.add('$id:$receipt');
      return accept;
    }, () {}, (_) {}, () {}, store: store)
      ..listen();
  });
  Future<void> finishDelivery() async {
    await store.events.close();
    // 事件流关闭后，模拟支付队列仍有异步写入和验单回调。
    await pumpEventQueue();
  }

  tearDown(() async {
    apple.dispose();
    await store.events.close();
  });
  test('发起支付使用原订单，等待回调期间忽略第二次购买', () async {
    await apple.buy('created', '17');
    await apple.buy('second', '17');
    expect(store.requested.single.applicationUserName, 'created');
    expect(
        (await SharedPreferences.getInstance())
            .getString('$scope/order/created'),
        '17');
    store.events.add([_purchase('created')]);
    await finishDelivery();
    expect(checked, ['created:receipt-for-created']);
    expect(apple.busy, isFalse);
  });
  test('查询商品期间退出，不再发起购买', () async {
    store.lookup = Completer<ProductDetailsResponse>();
    final buying = apple.buy('closed', '17');
    await Future<void>.delayed(Duration.zero);
    apple.dispose();
    store.lookup!.complete(ProductDetailsResponse(
        productDetails: [store.product], notFoundIDs: []));
    await buying;
    expect(store.requested, isEmpty);
    expect(store.events.hasListener, isFalse);
  });
  test('延迟交易绑定原订单，未知交易不会占用新订单', () async {
    store.events.add([
      _purchase(null),
      _purchase('other'),
      _purchase('old'),
      _purchase('legacy')
    ]);
    await finishDelivery();
    expect(checked, ['old:receipt-for-old', 'legacy:receipt-for-legacy']);
    expect(store.finished, hasLength(2));
    expect(
        (await SharedPreferences.getInstance()).getString('$scope/order/new'),
        '17');
  });
  test('验单失败保留交易，重试成功后才通知 StoreKit 完成', () async {
    accept = false;
    store.events.add([_purchase('new')]);
    await finishDelivery();
    expect(store.finished, isEmpty);
    expect(apple.hasPending, isTrue);
    accept = true;
    await apple.retry();
    expect(store.finished, hasLength(1));
    expect(apple.hasPending, isFalse);
  });
  test('验单失败退出后，重新进入按原订单补验，无需 StoreKit 重发', () async {
    accept = false;
    store.events.add([_purchase('new')]);
    await finishDelivery();
    apple.dispose();
    final recovered = Completer<void>();
    store = _Store();
    apple = ApplePurchaseSession(scope, () => true, (id, receipt) async {
      checked.add('$id:$receipt');
      return true;
    }, recovered.complete, (_) => fail('补验失败'), () {}, store: store)
      ..listen();
    await recovered.future;
    expect(checked, ['new:receipt-for-new', 'new:receipt-for-new']);
    expect(store.finished.single.purchaseID, 'transaction-new');
    expect(
        (await SharedPreferences.getInstance()).containsKey('$scope/order/new'),
        isFalse);
    store.events.add([_purchase('new')]);
    await finishDelivery();
    expect(checked, hasLength(2));
    expect(store.finished, hasLength(1));
  });
  for (final separate in [false, true]) {
    test('${separate ? '分批' : '同批'}第一笔验单时退出，重进后仍能补验第二笔', () async {
      apple.dispose();
      final started = Completer<void>();
      final firstResult = Completer<bool>();
      apple = ApplePurchaseSession(scope, () => true, (id, receipt) {
        checked.add('$id:$receipt');
        started.complete();
        return firstResult.future;
      }, () {}, (_) {}, () {}, store: store)
        ..listen();

      store.events.add([_purchase('old'), if (!separate) _purchase('new')]);
      await started.future;
      if (separate) {
        store.events.add([_purchase('new')]);
        await Future<void>.delayed(Duration.zero);
      }
      apple.dispose();
      firstResult.complete(true);

      apple = ApplePurchaseSession(scope, () => true, (id, receipt) async {
        checked.add('$id:$receipt');
        return true;
      }, () {}, (_) {}, () {}, store: store)
        ..listen();
      // 等待新页面初始化时已排入队列的补验，无需商店重发事件。
      await apple.retry();
      expect(checked, ['old:receipt-for-old', 'new:receipt-for-new']);
      expect(store.finished.map((p) => p.purchaseID),
          ['transaction-old', 'transaction-new']);
    });
  }
  test('验单成功但 StoreKit 完成失败，重进只补完成，不重复验单', () async {
    store.failNextCompletion = true;
    store.events.add([_purchase('new')]);
    await finishDelivery();
    expect(checked, ['new:receipt-for-new']);
    expect(store.finished, isEmpty);
    apple.dispose();
    store = _Store();
    apple = ApplePurchaseSession(scope, () => true, (id, receipt) async {
      checked.add('$id:$receipt');
      return true;
    }, () {}, (_) => fail('补完成失败'), () {}, store: store)
      ..listen();
    await apple.retry();
    expect(checked, ['new:receipt-for-new']);
    expect(store.finished.single.purchaseID, 'transaction-new');
    expect(
        (await SharedPreferences.getInstance()).containsKey('$scope/order/new'),
        isFalse);
  });
  for (final status in [PurchaseStatus.canceled, PurchaseStatus.error]) {
    test('收到 ${status.name} 后释放购买按钮且不验单', () async {
      await apple.buy('created', '17');
      final event = _purchase('created')..status = status;
      store.events.add([event]);
      await finishDelivery();
      expect(checked, isEmpty);
      expect(apple.busy, isFalse);
      expect(apple.hasPending, isFalse);
      expect(
          (await SharedPreferences.getInstance())
              .containsKey('$scope/order/created'),
          isFalse);
      await apple.buy('next', '17');
      expect(store.requested.last.applicationUserName, 'next');
    });
  }
  test('旧入口支付同一商品时保留其他会话的延迟交易', () async {
    apple.dispose();
    PayKit.initialize(DefaultPayConfig());
    final legacy = BuyEngine(store: store);
    final legacyReceipts = <String>[];
    legacy.initialize(legacyReceipts.add);
    legacy.buyProduct('17', 'legacy-current');
    await pumpEventQueue();
    store.events.add([_purchase('new'), _purchase('legacy-current')]);
    await pumpEventQueue();
    expect(legacyReceipts, ['receipt-for-legacy-current']);
    expect(store.finished.map((p) => p.purchaseID),
        ['transaction-legacy-current']);
    legacy.dispose();
    apple = ApplePurchaseSession(scope, () => true, (order, receipt) async {
      checked.add('$order:$receipt');
      return true;
    }, () {}, (_) => fail('补验失败'), () {}, store: store)
      ..listen();
    await apple.retry();
    expect(checked, ['new:receipt-for-new']);
    expect(store.finished.last.purchaseID, 'transaction-new');
  });
  test('进入后立即退出可安全取消订阅', () async {
    apple.dispose();
    expect(store.events.hasListener, isFalse);
    store.events.add([_purchase('old')]);
    await finishDelivery();
    expect(checked, isEmpty);
  });
}
