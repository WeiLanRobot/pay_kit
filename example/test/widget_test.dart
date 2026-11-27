import 'dart:async';

import 'package:example/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';

class _Account extends Fake implements AppleAccount {
  final orders = <String>[];
  var disposed = false;

  @override
  void dispose() => disposed = true;
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

class _Payments extends Fake implements ApplePayments {
  final starts = <Completer<void>>[];
  final account = _Account();
  var connections = 0;

  @override
  Future<void> start({required String environment}) {
    expect(environment, 'sandbox');
    final started = Completer<void>();
    starts.add(started);
    return started.future;
  }

  @override
  AppleAccount connect({
    required String scope,
    required Future<AppleVerification> Function(AppleReceipt) verify,
  }) {
    expect(scope, 'demo-account');
    connections++;
    return account;
  }
}

void main() {
  setUp(() {
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
  });

  testWidgets('iOS app shows other payments while Apple startup is pending',
      (tester) async {
    const channel = MethodChannel('pay_kit/storekit1');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.weilanwl.alipay_payment'),
        (call) async => true);
    final bundle = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'bundleIdentifier');
      return bundle.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final launch = Future<void>.sync(app.main);
    await tester.pumpAndSettle();
    expect(find.text('Pay Kit Example'), findsOneWidget);
    void expectOtherPaymentsAvailable() {
      for (final label in ['发起微信支付', '发起支付宝支付']) {
        final button = find.widgetWithText(ElevatedButton, label);
        expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
      }
    }

    expectOtherPaymentsAvailable();
    bundle.complete('');
    await launch;
    await tester.pumpAndSettle();
    expect(find.text('苹果内购启动失败，点击重试'), findsOneWidget);
    expectOtherPaymentsAvailable();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('retry starts Apple once and connects only after success',
      (tester) async {
    final payments = _Payments();
    await tester.pumpWidget(app.MyApp(applePayments: payments));
    expect(payments.starts, hasLength(1));
    expect(payments.connections, 0);
    payments.starts.single.completeError(StateError('账本暂不可用'));
    await tester.pumpAndSettle();
    expect(payments.connections, 0);
    final retry = find.text('苹果内购启动失败，点击重试');
    await tester.tap(retry);
    await tester.tap(retry);
    expect(payments.starts, hasLength(2));
    await tester.pump();
    expect(find.text('正在启动苹果内购…'), findsOneWidget);
    expect(payments.connections, 0);
    payments.starts.last.complete();
    await tester.pumpAndSettle();
    expect(payments.connections, 1);
    await tester.tap(find.text('购买商品 (iOS)'));
    await tester.pumpAndSettle();
    expect(payments.account.orders, ['demo-order-1']);
    await tester.pumpWidget(const SizedBox());
    expect(payments.account.disposed, isTrue);
  });

  testWidgets('late Apple startup cannot connect a disposed app',
      (tester) async {
    final payments = _Payments();
    await tester.pumpWidget(app.MyApp(applePayments: payments));
    await tester.pumpWidget(const SizedBox());
    payments.starts.single.complete();
    await tester.pump();
    expect(payments.connections, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'payment page displays available methods and submits an Apple order',
      (tester) async {
    final account = _Account();
    await tester.pumpWidget(MaterialApp(home: app.PayPage(account: account)));
    await tester.pumpAndSettle();
    expect(find.text('微信: 已安装'), findsOneWidget);
    expect(find.text('支付宝: 未安装'), findsOneWidget);
    await tester.tap(find.text('购买商品 (iOS)'));
    await tester.pumpAndSettle();
    expect(account.orders, ['demo-order-1']);
    expect(find.text('已提交商店，等待付款结果'), findsOneWidget);
  });
}
