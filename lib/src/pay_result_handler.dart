import 'config/pay_config.dart';
import 'config/pay_config_holder.dart';

/// 支付结果处理
class PayResultHandler {
  /// 微信支付结果处理
  static String handleWechatResult(int result) {
    final config = payConfigHolder.config;
    switch (result) {
      case 0:
        return config.getMessage(PayMessageKey.success);
      case -2:
        return config.getMessage(PayMessageKey.payCancel);
      case -4:
        return config.getMessage(PayMessageKey.authFailed);
      case -5:
        return config.getMessage(PayMessageKey.unsupportedWechat);
      default:
        return config.getMessage(PayMessageKey.payFailed);
    }
  }

  /// 支付宝支付结果处理
  /// 参考支付宝文档 https://docs.open.alipay.com/204/105695/
  /// 返回码含义：
  /// 9000——订单支付成功
  /// 8000——正在处理中
  /// 4000——订单支付失败
  /// 5000——重复请求
  /// 6001——用户中途取消
  /// 6002——网络连接出错
  static String handleAlipayResult(int? result) {
    final config = payConfigHolder.config;
    switch (result) {
      case 9000:
        return config.getMessage(PayMessageKey.success);
      case 8000:
        return config.getMessage(PayMessageKey.processing);
      case 6001:
        return config.getMessage(PayMessageKey.payCancel);
      case 6002:
        return config.getMessage(PayMessageKey.networkError);
      case 5000:
        return config.getMessage(PayMessageKey.repeatRequest);
      default:
        return config.getMessage(PayMessageKey.payFailed);
    }
  }
}