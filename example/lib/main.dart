import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pay_kit/pay_kit.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化支付插件
  PayKit.initialize(
    DefaultPayConfig(
      showToastHandler: (message, {isTip = false, lengthLong = false}) {
        debugPrint('Toast: $message');
      },
      showLoadingHandler: () {
        debugPrint('Show Loading');
      },
      dismissLoadingHandler: () {
        debugPrint('Dismiss Loading');
      },
      logHandler: (tag, message) {
        debugPrint('[$tag] $message');
      },
    ),
  );

  runApp(MyApp(
    applePayments: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? ApplePayments.instance
        : null,
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.applePayments});

  final ApplePayments? applePayments;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  AppleAccount? _account;
  bool _startingApple = false;

  @override
  void initState() {
    super.initState();
    _startApple();
  }

  Future<void> _startApple() async {
    final payments = widget.applePayments;
    if (payments == null || _startingApple || _account != null) return;
    setState(() => _startingApple = true);
    try {
      await payments.start(environment: 'sandbox');
      if (!mounted) return;
      // 示例模拟已登录账号。实际应用在登录时传入稳定的账号 ID，在退出时 dispose。
      _account = payments.connect(
        scope: 'demo-account',
        verify: (AppleReceipt receipt) async {
          // 将 scope、orderId、productId、transactionId 和 receipt 交给业务服务端。
          // 接入后返回服务端的幂等验单结果。示例没有后端，保留待验交易。
          return const AppleVerification.retryLater();
        },
      );
    } catch (error) {
      debugPrint('苹果内购启动失败（${error.runtimeType}）');
    }
    if (mounted) setState(() => _startingApple = false);
  }

  @override
  void dispose() {
    _account?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pay Kit Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: PayPage(
        account: _account,
        startingApple: _startingApple,
        retryApple:
            widget.applePayments != null && !_startingApple && _account == null
                ? _startApple
                : null,
      ),
    );
  }
}

class PayPage extends StatefulWidget {
  const PayPage({
    super.key,
    required this.account,
    this.startingApple = false,
    this.retryApple,
  });

  final AppleAccount? account;
  final bool startingApple;
  final VoidCallback? retryApple;

  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  final PayKit _payKit = PayKit();
  bool _wechatInstalled = false;
  bool _alipayInstalled = false;

  @override
  void initState() {
    super.initState();
    _checkInstallStatus();
  }

  Future<void> _checkInstallStatus() async {
    final wechatInstalled = await _payKit.isWechatInstalled();
    final alipayInstalled = await _payKit.isAlipayInstalled();
    if (!mounted) return;
    setState(() {
      _wechatInstalled = wechatInstalled;
      _alipayInstalled = alipayInstalled;
    });
  }

  @override
  void dispose() {
    _payKit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pay Kit Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('安装状态',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('微信: ${_wechatInstalled ? "已安装" : "未安装"}'),
                    Text('支付宝: ${_alipayInstalled ? "已安装" : "未安装"}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('微信支付',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _wechatInstalled ? _payWithWechat : null,
              child: const Text('发起微信支付'),
            ),
            const SizedBox(height: 16),
            const Text('支付宝支付',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _alipayInstalled ? _payWithAlipay : null,
              child: const Text('发起支付宝支付'),
            ),
            const SizedBox(height: 16),
            const Text('苹果内购',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (widget.retryApple != null)
              ElevatedButton(
                onPressed: widget.retryApple,
                child: const Text('苹果内购启动失败，点击重试'),
              )
            else
              ElevatedButton(
                onPressed: widget.account == null ? null : _buyIAP,
                child: Text(widget.startingApple ? '正在启动苹果内购…' : '购买商品 (iOS)'),
              ),
          ],
        ),
      ),
    );
  }

  void _payWithWechat() {
    _payKit.payWithWechat(
      appId: 'your_app_id',
      partnerId: 'your_partner_id',
      prepayId: 'your_prepay_id',
      nonceStr: 'your_nonce_str',
      timeStamp: 'your_timestamp',
      sign: 'your_sign',
      onResult: (bool success, int code, String message) {
        debugPrint('微信支付结果: success=$success, code=$code, message=$message');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('微信支付: $message')),
          );
        }
      },
    );
  }

  void _payWithAlipay() {
    _payKit.payWithAlipay(
      'your_order_info',
      onResult: (bool success, int code, String message) {
        debugPrint('支付宝支付结果: success=$success, code=$code, message=$message');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('支付宝支付: $message')),
          );
        }
      },
    );
  }

  Future<void> _buyIAP() async {
    final account = widget.account;
    if (account == null) return;
    String message;
    try {
      // 替换为 StoreKit 商品和业务服务端为本次购买创建的唯一订单号。
      final result = await account.buy(
          productId: 'your_product_id', orderId: 'demo-order-1');
      message = switch (result.phase) {
        'accepted' => '已提交商店，等待付款结果',
        'declined' => '商店拒绝了这次购买',
        'uncertain' => '提交结果待确认，可用原订单查询',
        _ => '订单进度 ${result.phase}',
      };
    } catch (_) {
      message = '购买请求未获确认，请查看订单状态';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
