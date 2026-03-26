import 'dart:async';

import 'package:alipay_payment/alipay_payment.dart';
import 'package:wechat_bridge/wechat_bridge.dart';

import 'src/config/pay_config.dart';
import 'src/config/pay_config_holder.dart';
import 'src/pay_result_handler.dart';

export 'src/config/pay_config.dart';
export 'src/config/default_pay_config.dart';
export 'src/config/pay_config_holder.dart';
export 'src/iap/buy_engine.dart';

typedef PayCallback = void Function(bool success, int code, String message);

/// 支付插件
class PayKit {
  StreamSubscription<WechatResp>? _wechatSubs;
  StreamSubscription<AlipayResult>? _alipaySubs;

  /// 初始化支付插件
  /// 必须在使用前调用，传入业务层实现的配置
  static void initialize(PayConfig config) {
    payConfigHolder.init(config);
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
  Future<void> payWithAlipay(
    String orderInfo, {
    bool showLoading = true,
    required PayCallback onResult,
  }) async {
    _alipaySubs?.cancel();

    final bool installed = await isAlipayInstalled();
    if (!installed) {
      onResult(false, 6002, "未安装支付宝");
      return;
    }

    _alipaySubs = AlipayPaymentPlatform.instance.payResp().listen((AlipayResult resp) {
      final int resultCode = resp.resultStatusCode ?? -1;
      final msg = PayResultHandler.handleAlipayResult(resultCode);
      onResult(resp.isSuccess, resultCode, msg);

      _alipaySubs?.cancel();
      _alipaySubs = null;
    });

    try {
      await AlipayPaymentPlatform.instance.pay(
        orderInfo: orderInfo,
        showPayLoading: showLoading,
      );
    } catch (e) {
      onResult(false, 4000, "支付宝拉起失败: $e");
      _alipaySubs?.cancel();
      _alipaySubs = null;
    }
  }

  /// 微信支付
  Future<void> payWithWechat({
    required String appId,
    required String partnerId,
    required String prepayId,
    required String nonceStr,
    required String timeStamp,
    required String sign,
    String packageValue = "Sign=WXPay",
    required PayCallback onResult,
  }) async {
    _wechatSubs?.cancel();

    _wechatSubs = WechatBridgePlatform.instance.respStream().listen((WechatResp resp) {
      if (resp is WechatPayResp) {
        final msg = PayResultHandler.handleWechatResult(resp.errorCode);
        onResult(resp.isSuccessful, resp.errorCode, msg);

        _wechatSubs?.cancel();
        _wechatSubs = null;
      }
    });

    await WechatBridgePlatform.instance.pay(
      appId: appId,
      partnerId: partnerId,
      prepayId: prepayId,
      package: packageValue,
      nonceStr: nonceStr,
      timeStamp: timeStamp,
      sign: sign,
    );
  }

  /// 清理订阅
  void dispose() {
    _alipaySubs?.cancel();
    _alipaySubs = null;
    _wechatSubs?.cancel();
    _wechatSubs = null;
  }
}