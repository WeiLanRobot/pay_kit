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

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pay Kit Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const PayPage(),
    );
  }
}

class PayPage extends StatefulWidget {
  const PayPage({super.key});

  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  final PayKit _payKit = PayKit();
  final BuyEngine _buyEngine = BuyEngine();
  bool _wechatInstalled = false;
  bool _alipayInstalled = false;

  @override
  void initState() {
    super.initState();
    _checkInstallStatus();
    _initIAP();
  }

  Future<void> _checkInstallStatus() async {
    final wechatInstalled = await _payKit.isWechatInstalled();
    final alipayInstalled = await _payKit.isAlipayInstalled();
    setState(() {
      _wechatInstalled = wechatInstalled;
      _alipayInstalled = alipayInstalled;
    });
  }

  void _initIAP() {
    _buyEngine.initialize((String receipt) {
      // 将 receipt 发送到服务器验证
      debugPrint('Receipt: $receipt');
      // TODO: 发送到服务器验证
    });
  }

  @override
  void dispose() {
    _payKit.dispose();
    _buyEngine.dispose();
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
                    const Text('安装状态', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('微信: ${_wechatInstalled ? "已安装" : "未安装"}'),
                    Text('支付宝: ${_alipayInstalled ? "已安装" : "未安装"}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('微信支付', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _wechatInstalled ? _payWithWechat : null,
              child: const Text('发起微信支付'),
            ),
            const SizedBox(height: 16),
            const Text('支付宝支付', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _alipayInstalled ? _payWithAlipay : null,
              child: const Text('发起支付宝支付'),
            ),
            const SizedBox(height: 16),
            const Text('苹果内购', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _buyIAP,
              child: const Text('购买商品 (iOS)'),
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

  void _buyIAP() {
    // 替换为实际的商品ID和订单ID
    _buyEngine.buyProduct('your_product_id', 'your_order_id');
  }
}