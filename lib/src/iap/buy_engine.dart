import '../config/pay_config.dart';
import '../config/pay_config_holder.dart';
import 'apple_payments.dart';
import 'apple_store.dart';

typedef ReceiptCallback = Function(String receipt);

/// 1.2.0 的收据回调入口。需要确认业务验单结果时使用 [ApplePayments.connect]。
class BuyEngine {
  BuyEngine({ApplePayments? payments})
      : _payments = payments ?? ApplePayments.instance;

  final ApplePayments _payments;
  Object? _owner;
  PayConfig? _loadingConfig;

  // PayConfig 的加载框全局共用。每次拉起商店只允许发起方关闭自己的加载框。
  static Object? _launchOwner;

  void initialize(ReceiptCallback? receiptCallback) {
    dispose();
    final owner = Object();
    _owner = owner;
    try {
      _payments.attachLegacy(
        owner,
        receiptCallback == null
            ? null
            : (receipt) async {
                await receiptCallback(receipt);
              },
        (_, status) {
          if (_owner != owner) return;
          if (status == StoreStatus.canceled) _toast(PayMessageKey.payCancel);
          if (status == StoreStatus.failed) _toast(PayMessageKey.payFailed);
        },
        (error) {
          if (_owner == owner) _report(error);
        },
      );
    } catch (error) {
      dispose();
      _report(error);
    }
  }

  void buyProduct(String productId, String orderId) async {
    final owner = _owner;
    if (owner == null) {
      _report(
          StateError('BuyEngine.initialize must be called before buyProduct'));
      return;
    }
    if (_launchOwner != null) {
      _toast(PayMessageKey.processing);
      return;
    }

    _launchOwner = owner;
    final config = payConfigHolder.config;
    _loadingConfig = config;
    try {
      config.showLoading();
      await _payments.buyLegacy(owner, productId, orderId);
    } catch (error) {
      if (_owner == owner) _report(error);
    } finally {
      _dismissLoading(owner);
    }
  }

  void _report(Object error) {
    // Host verifier exceptions can contain the complete receipt.
    final reason = error is StoreLaunchException
        ? error.messageKey.name
        : error.runtimeType;
    payConfigHolder.config.log('BuyEngine', 'Apple purchase error: $reason');
    _toast(error is StoreLaunchException
        ? error.messageKey
        : PayMessageKey.payFailed);
  }

  void _toast(PayMessageKey key) {
    final config = payConfigHolder.config;
    config.showToast(config.getMessage(key), isTip: true);
  }

  void _dismissLoading(Object owner) {
    if (_launchOwner != owner) return;
    _launchOwner = null;
    final config = _loadingConfig;
    _loadingConfig = null;
    config?.dismissLoading();
  }

  void dispose() {
    final owner = _owner;
    if (owner == null) return;
    _owner = null;
    _payments.detachLegacy(owner);
    _dismissLoading(owner);
  }
}
