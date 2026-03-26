/// 支付配置接口 - 由业务层实现注入
abstract class PayConfig {
  /// 显示 Toast
  void showToast(String message, {bool isTip = false, bool lengthLong = false});

  /// 显示 Loading
  void showLoading();

  /// 隐藏 Loading
  void dismissLoading();

  /// 获取国际化文案
  String getMessage(PayMessageKey key);

  /// 日志输出（可选）
  void log(String tag, String message);
}

/// 国际化文案 Key
enum PayMessageKey {
  /// 支付成功
  success,
  /// 支付失败，可重新支付
  payFailed,
  /// 支付取消，可重新支付
  payCancel,
  /// 网络连接错误
  networkError,
  /// 正在处理中
  processing,
  /// 微信不支持
  unsupportedWechat,
  /// 授权失败
  authFailed,
  /// 暂无商品
  noProduct,
  /// 查询商品信息失败
  queryProductFailed,
  /// 无法连接到商店
  unableConnectStore,
  /// 无法找到指定商品
  productNotFound,
  /// 当前没有商品可购买
  noProductToPurchase,
  /// 重复请求
  repeatRequest,
}