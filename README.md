# pay_plugin

Flutter 支付插件，支持微信支付、支付宝支付、苹果内购（In-App Purchase）。

## 功能特性

- ✅ 微信支付
- ✅ 支付宝支付
- ✅ 苹果内购 (iOS In-App Purchase)
- ✅ 支付结果统一处理
- ✅ 可配置的国际化文案
- ✅ 自定义 Toast/Loading 注入

## 安装

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  pay_plugin:
    git:
      url: https://github.com/WeiLanRobot/pay_kit.git
```

## 使用方法

### 1. 初始化

在使用前需要注入配置：

```dart
import 'package:pay_plugin/pay_plugin.dart';

// 初始化配置
PayPlugin.initialize(
  DefaultPayPluginConfig(
    showToastHandler: (message, {isTip, lengthLong}) {
      // 你的 Toast 实现
    },
    showLoadingHandler: () {
      // 显示 Loading
    },
    dismissLoadingHandler: () {
      // 隐藏 Loading
    },
    logHandler: (tag, message) {
      // 日志输出
    },
  ),
);
```

### 2. 微信支付

```dart
final payPlugin = PayPlugin();

// 检查微信是否安装
final installed = await payPlugin.isWechatInstalled();

// 发起支付
await payPlugin.wechatKitPayOrder(
  appId: 'your_app_id',
  partnerId: 'your_partner_id',
  prepayId: 'your_prepay_id',
  nonceStr: 'your_nonce_str',
  timeStamp: 'your_timestamp',
  sign: 'your_sign',
  (bool success, int code, String message) {
    // 处理支付结果
  },
);
```

### 3. 支付宝支付

```dart
final payPlugin = PayPlugin();

// 检查支付宝是否安装
final installed = await payPlugin.isAlipayInstalled();

// 发起支付
await payPlugin.aliPayOrderKitOrder(
  'your_order_info',
  true, // 显示 Loading
  (bool success, int code, String message) {
    // 处理支付结果
  },
);
```

### 4. 苹果内购

```dart
import 'package:pay_plugin/pay_plugin.dart';

final buyEngine = BuyEngin();

// 初始化内购
buyEngine.initializeInAppPurchase((String receipt) {
  // 处理支付凭证，发送到服务器验证
});

// 发起购买
buyEngine.buyProduct('product_id', 'order_id');

// 页面销毁时清理
@override
void dispose() {
  buyEngine.onClose();
  super.dispose();
}
```

## 配置项

### PayPluginConfig 接口

| 方法 | 说明 |
|------|------|
| `showToast(message, {isTip, lengthLong})` | 显示 Toast 提示 |
| `showLoading()` | 显示加载中 |
| `dismissLoading()` | 隐藏加载中 |
| `getMessage(PayMessageKey key)` | 获取国际化文案 |
| `log(tag, message)` | 日志输出 |

### PayMessageKey 枚举

| Key | 默认文案 |
|-----|---------|
| `success` | 支付成功 |
| `payFailed` | 支付失败，请重试 |
| `payCancel` | 已取消支付 |
| `networkError` | 网络连接失败，请检查网络 |
| `processing` | 正在处理中... |
| `unsupportedWechat` | 当前微信版本不支持 |
| `authFailed` | 授权失败 |
| `noProduct` | 暂无商品 |
| `queryProductFailed` | 查询商品信息失败 |
| `unableConnectStore` | 无法连接到商店 |
| `productNotFound` | 未找到该商品 |
| `noProductToPurchase` | 当前没有可购买的商品 |
| `repeatRequest` | 请求过于频繁，请稍后重试 |

## 依赖

- [in_app_purchase](https://pub.dev/packages/in_app_purchase) - 苹果内购
- [in_app_purchase_storekit](https://pub.dev/packages/in_app_purchase_storekit) - StoreKit 支持
- [alipay_payment](https://pub.dev/packages/alipay_payment) - 支付宝支付
- [wechat_bridge](https://pub.dev/packages/wechat_bridge) - 微信支付

## License

MIT License