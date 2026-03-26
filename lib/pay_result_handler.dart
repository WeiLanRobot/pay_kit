import 'pay_plugin_config.dart';
import 'pay_plugin_config_holder.dart';

class PaymentResultHandler {
  /// 微信支付结果处理
  static String handleWeChatResult(int result) {
    final config = payPluginConfigHolder.config;
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

  /// 支付状态，参考支付宝的文档https://docs.open.alipay.com/204/105695/
  /// 返回码，标识支付状态，含义如下：
  /// 9000——订单支付成功
  /// 8000——正在处理中
  /// 4000——订单支付失败
  /// 5000——重复请求
  /// 6001——用户中途取消
  /// 6002——网络连接出错
  static String handleAliPayResult(int? result) {
    final config = payPluginConfigHolder.config;
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