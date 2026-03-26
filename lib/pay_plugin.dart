import 'dart:async';

import 'package:alipay_payment/alipay_payment.dart';
import 'package:wechat_bridge/wechat_bridge.dart';

import 'pay_plugin_config.dart';
import 'pay_plugin_config_holder.dart';
import 'pay_result_handler.dart';

export 'pay_plugin_config.dart';
export 'pay_plugin_config_holder.dart';

enum PayPlatformType { wechat, alipay }

class PayPlugin {
  StreamSubscription<WechatResp>? _respWeixinSubs;
  StreamSubscription<AlipayResult>? _respAliPaySubs;

  /// 初始化支付插件
  /// 必须在使用前调用，传入业务层实现的配置
  static void initialize(PayPluginConfig config) {
    payPluginConfigHolder.init(config);
  }

  /// 检查微信是否已安装
  Future<bool> isWechatInstalled() {
    return WechatBridgePlatform.instance.isInstalled();
  }

  /// 检查支付宝是否已安装
  Future<bool> isAlipayInstalled() {
    return AlipayPaymentPlatform.instance.isAlipayInstalled();
  }

  /// 支付宝支付
  Future<void> aliPayOrderKitOrder(
    String orderInfo,
    bool showLoading,
    Function(bool, int, String) payFunction,
  ) async {
    _respAliPaySubs?.cancel();

    final bool installed = await isAlipayInstalled();
    if (!installed) {
      payFunction.call(false, 6002, "未安装支付宝");
      return;
    }

    _respAliPaySubs = AlipayPaymentPlatform.instance.payResp().listen((AlipayResult resp) {
      final int resultCode = resp.resultStatusCode ?? -1;
      String msg = PaymentResultHandler.handleAliPayResult(resultCode);
      payFunction.call(resp.isSuccess, resultCode, msg);

      _respAliPaySubs?.cancel();
      _respAliPaySubs = null;
    });

    try {
      return AlipayPaymentPlatform.instance.pay(
        orderInfo: orderInfo,
        showPayLoading: showLoading,
      );
    } catch (e) {
      payFunction.call(false, 4000, "支付宝拉起失败: $e");
      _respAliPaySubs?.cancel();
      _respAliPaySubs = null;
    }
  }

  /// 微信支付
  Future<void> wechatKitPayOrder(
    String appId,
    String partnerId,
    String prepayId,
    String nonceStr,
    String timeStamp,
    String sign,
    Function(bool, int, String) payFunction, {
    String packageValue = "Sign=WXPay",
    String universalLink = "",
  }) {
    _respWeixinSubs?.cancel();

    _respWeixinSubs = WechatBridgePlatform.instance.respStream().listen((WechatResp resp) {
      if (resp is WechatPayResp) {
        String errorMsg = PaymentResultHandler.handleWeChatResult(resp.errorCode);
        payFunction.call(resp.isSuccessful, resp.errorCode, errorMsg);

        _respWeixinSubs?.cancel();
        _respWeixinSubs = null;
      }
    });

    return WechatBridgePlatform.instance.pay(
      appId: appId,
      partnerId: partnerId,
      prepayId: prepayId,
      package: packageValue,
      nonceStr: nonceStr,
      timeStamp: timeStamp,
      sign: sign,
    );
  }

  void clearRespSubs() {
    _respAliPaySubs?.cancel();
    _respAliPaySubs = null;
    _respWeixinSubs?.cancel();
    _respWeixinSubs = null;
  }
}