import 'pay_plugin_config.dart';
import 'default_pay_plugin_config.dart';

/// 支付插件配置持有者
class PayPluginConfigHolder {
  PayPluginConfig? _config;

  /// 默认配置（兜底）
  static final PayPluginConfig _defaultConfig = DefaultPayPluginConfig();

  /// 获取配置（如果未初始化则返回默认配置）
  PayPluginConfig get config => _config ?? _defaultConfig;

  /// 初始化配置
  void init(PayPluginConfig config) {
    _config = config;
  }

  /// 是否已初始化
  bool get isInitialized => _config != null;
}

/// 全局配置持有者
final payPluginConfigHolder = PayPluginConfigHolder();