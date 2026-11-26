import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';

class _Account extends Fake implements AppleAccount {
  final orders = <String>[];
  @override
  Future<AppleOrderSnapshot> buy(
      {required String productId,
      required String orderId,
      String? purchaseToken}) async {
    orders.add(orderId);
    return AppleOrderSnapshot(
        scope: 'demo-account',
        orderId: orderId,
        productId: productId,
        attemptId: 'example',
        phase: 'accepted',
        revision: 1,
        charges: const []);
  }
}

void main() {
  testWidgets(
      'payment page displays available methods and submits an Apple order',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const wechat = MethodChannel('wechat_bridge');
    const alipay = MethodChannel('io.github.weilanwl.alipay_payment');
    messenger.setMockMethodCallHandler(wechat, (call) async => true);
    messenger.setMockMethodCallHandler(alipay, (call) async => false);
    addTearDown(() {
      messenger.setMockMethodCallHandler(wechat, null);
      messenger.setMockMethodCallHandler(alipay, null);
    });
    final account = _Account();
    await tester.pumpWidget(MaterialApp(home: PayPage(account: account)));
    await tester.pumpAndSettle();
    expect(find.text('微信: 已安装'), findsOneWidget);
    expect(find.text('支付宝: 未安装'), findsOneWidget);
    await tester.tap(find.text('购买商品 (iOS)'));
    await tester.pumpAndSettle();
    expect(account.orders, ['demo-order-1']);
    expect(find.text('已提交商店，等待付款结果'), findsOneWidget);
  });
}
