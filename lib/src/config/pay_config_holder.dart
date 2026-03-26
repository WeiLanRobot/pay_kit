import 'pay_config.dart';
import 'default_pay_config.dart';

/// 支付配置持有者
class PayConfigHolder {
  PayConfig? _config;

  /// 默认配置（兜底）
  static final PayConfig _defaultConfig = DefaultPayConfig();

  /// 获取配置（如果未初始化则返回默认配置）
  PayConfig get config => _config ?? _defaultConfig;

  /// 初始化配置
  void init(PayConfig config) {
    _config = config;
  }

  /// 是否已初始化
  bool get isInitialized => _config != null;
}

/// 全局配置持有者
final payConfigHolder = PayConfigHolder();