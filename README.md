# pay_kit

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
  pay_kit:
    git:
      url: https://github.com/WeiLanRobot/pay_kit.git
```

## 使用方法

### 1. 初始化

在使用前需要注入配置：

```dart
import 'package:pay_kit/pay_kit.dart';

PayKit.initialize(
  DefaultPayConfig(
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
final payKit = PayKit();

// 检查微信是否安装
final installed = await payKit.isWechatInstalled();

// 发起支付
await payKit.payWithWechat(
  appId: 'your_app_id',
  partnerId: 'your_partner_id',
  prepayId: 'your_prepay_id',
  nonceStr: 'your_nonce_str',
  timeStamp: 'your_timestamp',
  sign: 'your_sign',
  onResult: (bool success, int code, String message) {
    // 处理支付结果
  },
);
```

### 3. 支付宝支付

```dart
final payKit = PayKit();

// 检查支付宝是否安装
final installed = await payKit.isAlipayInstalled();

// 发起支付
await payKit.payWithAlipay(
  'your_order_info',
  onResult: (bool success, int code, String message) {
    // 处理支付结果
  },
);
```

### 4. 苹果内购

适用于 iOS StoreKit 1 消耗型内购。应用启动时在主 Flutter engine 建立唯一队列观察者。登录层为当前账号绑定独立的验单客户端，支付页通过同一个账号句柄下单或订阅订单。

```dart
final payments = ApplePayments.instance;
await payments.start(environment: storeEnvironment);
final account = payments.connect(
  scope: user.id,
  verify: api.verifyAndDeliver, // Future<AppleVerification> Function(AppleReceipt)
);

final order = await api.createOrder();
final subscription = account.watch(order.id).listen(renderOrder);
final snapshot = await account.buy(
  orderId: order.id,
  productId: order.productId,
  purchaseToken: order.attemptUuid,
);
```

**订单和尝试。** 服务端创建业务订单。每个账号内订单号唯一，每次实际拉起有独立的 UUID。同一应用的生产、沙盒、本地测试和旧接口共同保留已登记的购买标识；跨环境重用 UUID 会在提交 Apple 付款前返回错误。同单并发调用共享商店结果。服务端预先登记尝试 UUID 可以支持重装后查回原单。跨设备限制重复付款时，服务端还需原子授权一个设备提交。页面退出时取消 subscription，账号退出时调用 `account.dispose()`。重新打开可使用 `account.lookup(orderId)` 或 `account.watch(orderId)` 查看持久状态。

对于仅由服务端凭证恢复的订单，`AppleOrderSnapshot.attemptId` 和 `AppleReceipt.attemptId` 可以为空。重复购买该订单会返回已有扣款的状态。

账号退出后，尚未返回的购买请求会向旧调用方报告会话已结束。商店结果仍记录在原订单，重新登录后可查询。

**商店环境。** `start` 自动读取当前应用的 Bundle ID，调用方传入 `production`、`sandbox` 或 `xcode`。服务端应先核实 Apple 应用和实际环境，再履约。环境不符时返回 `AppleVerification.environmentMismatch` 和核实依据。原提交保留在发起环境，受信服务在实际环境重新启动后，使用 `unmatched()` 提供的观察引用和服务端归属凭据继续对账。

**商品类型。** 这个入口只购买消耗品。若应用同时销售非消耗品或订阅，请在宿主 iOS 的 `Info.plist` 列出允许购买的消耗品 SKU。空清单会禁止全部商品，格式错误会在准备购买时报告。纯消耗品目录可以省略此项。清单外且账本无归属的取消或失败项，由对应的商品处理方收尾。调整清单后，先前已经登记的消耗品订单仍可验单和收尾。

```xml
<key>PayKitConsumableProductIdentifiers</key>
<array>
  <string>com.example.coins.100</string>
</array>
```

**付款结果。** `snapshot.phase` 中的 `accepted` 表示商店已受理。`uncertain` 表示提交结果待确认，快照提供 `attemptId`。明确拒单、取消和失败分别为 `declined`、`canceled`、`failed`。已付款订单的 `charges` 分别报告每笔扣款的处置回执和队列收尾进度。队列暂时为空或服务端暂时查无记录时继续等待。

**验单与发货。** 应用服务端核实应用、环境、SKU、数量、订单归属和每笔 Apple 交易，以经 Apple 核实的交易号幂等发货或退款。验单回调通过受信客户端获取结果，分别返回 `AppleVerification.delivered(AppleDisposition(...))`、`retryLater()`、`invalidEvidence()` 或 `needsReconciliation()`。最终回执同时绑定设备报告的交易号和服务端确认的交易号。多笔扣款分别处置。库先保存回执，再结束对应的原生队列项。网络恢复可调用 `await payments.retryPending()` 安排重试，取消或关闭支付页不会丢弃待验凭证。用户主动调用 `refreshReceipts()` 时系统可能要求 Apple ID 认证。

**对账。** 只有受信的应用级恢复服务应读取 `await payments.unmatched()` 中的完整凭证，用 `payments.reconcile(AppleClaim(...))` 提交服务端确认的归属。无法查证的原商店 UUID 保持空值。尚无交易号的尝试可由受信恢复服务通过 `unresolvedAttempts()` 找到，再用 `resolveAttempt(AppleAttemptDecision(...))` 记录持久裁决。只有能证明本次未提交或最终未扣款的权威结论才允许重新购买。SDK 依赖宿主认证这些裁决和回执。服务端已发货但应答丢失时要返回原回执。

若交易有相互冲突的认领或处置，`unmatched()` 会给出争议引用、当前修订号和回执引用。应用级服务将已认证的 `AppleDisputeReview` 传给 `AppleClaim` 的 `review` 参数。复核须指向当前争议；涉及已发货订单的补偿时，还须核对原履约回执。托管验单超时或切换账号后可能重试同一笔付款，服务端必须按应用、真实商店环境和核实的交易号原子去重。`AppleAttemptDecision` 须绑定环境；旧业务订单串缺失时，已付款裁决还须有能独立关联原提交的依据。

正式复核可以选择已在争议中留证的正确 Apple 交易号。跨环境复核时，`AppleTransaction.environmentProofs` 提供可选证明，`AppleDisputeReview.environmentProofId` 选择实际环境。已有发货时，宿主须先完成补偿并提交覆盖原回执的已退款处置。在目标环境重新提供归属和处置依据后，SDK 才能结束该环境的队列项。更正涉及已有独立扣款或无法区分的多个报告号时，SDK 保留争议。

**从 1.2.0 升级。** `BuyEngine.initialize(receiptCallback)`、`buyProduct(productId, orderId)` 和 `dispose()` 的调用形状保持兼容。传入空接收器可以观察队列；旧入口实际发起购买需要有效的收据回调。原始业务订单串仍传给 Apple。一个旧接收器一次只持有一笔未决购买，成功只交给原下单代次。旧异步回调正常结束表示收据已交接。原页退出、缺少归属或升级前遗留的收据交由受信恢复服务认领。每笔实际拉起都要使用全新的业务订单串。升级后也要避免复用 1.2.0 已经使用的订单号。商店明确受理后，原页才可接收对应收据。旧回调可能重投，业务侧应按已核实的交易号幂等处理。

## 配置项

### PayConfig 接口

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

- 苹果购买和队列收尾由本包的 iOS 原生 StoreKit 1 观察者负责。
- [sqflite](https://pub.dev/packages/sqflite) - 苹果内购本地账本
- [alipay_payment](https://pub.dev/packages/alipay_payment) - 支付宝支付
- [wechat_bridge](https://pub.dev/packages/wechat_bridge) - 微信支付

## License

MIT License