import 'package:flutter/material.dart';

import 'pay_config.dart';

/// 默认支付配置实现 - 提供兜底方案
/// 业务层可以继承此类并覆盖需要自定义的方法
class DefaultPayConfig implements PayConfig {
  final String Function(PayMessageKey key)? messageResolver;
  final void Function(String message, {bool isTip, bool lengthLong})? showToastHandler;
  final void Function()? showLoadingHandler;
  final void Function()? dismissLoadingHandler;
  final void Function(String tag, String message)? logHandler;

  DefaultPayConfig({
    this.messageResolver,
    this.showToastHandler,
    this.showLoadingHandler,
    this.dismissLoadingHandler,
    this.logHandler,
  });

  /// 默认中文文案
  static const Map<PayMessageKey, String> _defaultMessages = {
    PayMessageKey.success: '支付成功',
    PayMessageKey.payFailed: '支付失败，请重试',
    PayMessageKey.payCancel: '已取消支付',
    PayMessageKey.networkError: '网络连接失败，请检查网络',
    PayMessageKey.processing: '正在处理中...',
    PayMessageKey.unsupportedWechat: '当前微信版本不支持',
    PayMessageKey.authFailed: '授权失败',
    PayMessageKey.noProduct: '暂无商品',
    PayMessageKey.queryProductFailed: '查询商品信息失败',
    PayMessageKey.unableConnectStore: '无法连接到商店',
    PayMessageKey.productNotFound: '未找到该商品',
    PayMessageKey.noProductToPurchase: '当前没有可购买的商品',
    PayMessageKey.repeatRequest: '请求过于频繁，请稍后重试',
  };

  @override
  String getMessage(PayMessageKey key) {
    if (messageResolver != null) {
      final result = messageResolver!(key);
      if (result.isNotEmpty) return result;
    }
    return _defaultMessages[key] ?? '未知错误';
  }

  @override
  void showToast(String message, {bool isTip = false, bool lengthLong = false}) {
    if (showToastHandler != null) {
      showToastHandler!(message, isTip: isTip, lengthLong: lengthLong);
      return;
    }
    debugPrint('[PayKit] Toast: $message');
  }

  @override
  void showLoading() {
    if (showLoadingHandler != null) {
      showLoadingHandler!();
      return;
    }
    debugPrint('[PayKit] showLoading: please inject showLoadingHandler');
  }

  @override
  void dismissLoading() {
    if (dismissLoadingHandler != null) {
      dismissLoadingHandler!();
      return;
    }
    debugPrint('[PayKit] dismissLoading: please inject dismissLoadingHandler');
  }

  @override
  void log(String tag, String message) {
    if (logHandler != null) {
      logHandler!(tag, message);
    } else {
      debugPrint('[$tag] $message');
    }
  }
}