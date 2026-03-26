import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

import 'pay_plugin_config.dart';
import 'pay_plugin_config_holder.dart';

typedef FuncCallback = Function(String receipt);

class BuyEngin {
  late StreamSubscription<List<PurchaseDetails>> _subscription;
  late InAppPurchase _inAppPurchase;
  List<ProductDetails> _products = [];

  /// 防止重复点击购买
  bool _isPurchasing = false;

  void initializeInAppPurchase(FuncCallback? receiptCallBack) async {
    final config = payPluginConfigHolder.config;

    _inAppPurchase = InAppPurchase.instance;

    // iOS 平台初始化时清理未完成的交易
    if (Platform.isIOS) {
      await _clearPendingTransactions();
    }

    final Stream<List<PurchaseDetails>> purchaseUpdated = _inAppPurchase.purchaseStream;
    _subscription = purchaseUpdated.listen(
      (purchaseDetailsList) {
        _listenToPurchaseUpdated(purchaseDetailsList, receiptCallBack);
      },
      onDone: () {
        config.dismissLoading();
        _resetPurchaseState();
        _subscription.cancel();
      },
      onError: (error) {
        error.printError();
        config.dismissLoading();
        _resetPurchaseState();
        config.showToast(config.getMessage(PayMessageKey.payFailed), isTip: true);
        config.log("BuyEngin", "initializeInAppPurchase:: 支付失败，可重新支付");
      },
    );
  }

  /// 重置购买状态
  void _resetPurchaseState() {
    _isPurchasing = false;
  }

  /// 清理 iOS 支付队列中未完成的交易
  Future<void> _clearPendingTransactions() async {
    try {
      final transactions = await SKPaymentQueueWrapper().transactions();
      final config = payPluginConfigHolder.config;

      for (var transaction in transactions) {
        config.log("BuyEngin",
            "发现未完成交易: ${transaction.payment.productIdentifier}, 状态: ${transaction.transactionState}");

        // 清理失败或卡住的交易
        if (transaction.transactionState == SKPaymentTransactionStateWrapper.failed) {
          await SKPaymentQueueWrapper().finishTransaction(transaction);
          config.log("BuyEngin", "已清理失败交易: ${transaction.payment.productIdentifier}");
        }
      }
    } catch (e) {
      payPluginConfigHolder.config.log("BuyEngin", "_clearPendingTransactions 异常: $e");
    }
  }

  /// 购买前检查并清理该商品的待处理交易
  Future<bool> _checkAndClearPendingForProduct(String productId) async {
    try {
      final transactions = await SKPaymentQueueWrapper().transactions();
      final config = payPluginConfigHolder.config;

      final pendingForProduct = transactions
          .where((t) => t.payment.productIdentifier == productId)
          .toList();

      if (pendingForProduct.isNotEmpty) {
        config.log("BuyEngin", "发现该商品未完成的交易，正在清理: $productId");
        for (var t in pendingForProduct) {
          // 如果是 purchasing 状态，说明有正在进行的交易，不应该清理
          if (t.transactionState == SKPaymentTransactionStateWrapper.purchasing) {
            config.log("BuyEngin", "该商品有正在进行的交易，请稍后再试");
            return false;
          }
          await SKPaymentQueueWrapper().finishTransaction(t);
          config.log("BuyEngin", "已清理该商品的待处理交易: $productId");
        }
      }
      return true;
    } catch (e) {
      payPluginConfigHolder.config.log("BuyEngin", "_checkAndClearPendingForProduct 异常: $e");
      return true; // 异常时允许继续购买
    }
  }

  void buyProduct(String productId, String orderId) async {
    final config = payPluginConfigHolder.config;

    // 防止重复点击
    if (_isPurchasing) {
      config.log("BuyEngin", "buyProduct:: 正在购买中，请勿重复点击");
      config.showToast(config.getMessage(PayMessageKey.processing), isTip: true);
      return;
    }

    _isPurchasing = true;
    config.showLoading();

    final bool available = await _inAppPurchase.isAvailable();
    if (!available) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.unableConnectStore), isTip: true);
      config.log("BuyEngin", "buyProduct:: 无法连接到商店");
      return;
    }

    if (Platform.isIOS) {
      // iOS: 检查并清理该商品的待处理交易
      final canProceed = await _checkAndClearPendingForProduct(productId);
      if (!canProceed) {
        config.dismissLoading();
        _resetPurchaseState();
        config.showToast(config.getMessage(PayMessageKey.processing), isTip: true);
        return;
      }

      final InAppPurchaseStoreKitPlatformAddition iosPlatformAddition =
          _inAppPurchase.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      await iosPlatformAddition.setDelegate(ExamplePaymentQueueDelegate());
    }

    List<String> kIds = [productId];
    final ProductDetailsResponse response = await _inAppPurchase.queryProductDetails(kIds.toSet());

    if (response.error != null) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.queryProductFailed), isTip: true);
      config.log("BuyEngin", "buyProduct:: 查询商品信息失败");
      return;
    }

    if (response.productDetails.isEmpty) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.noProduct), isTip: true);
      config.log("BuyEngin", "buyProduct:: 暂无商品");
      return;
    }

    if (response.notFoundIDs.isNotEmpty) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.productNotFound), isTip: true);
      config.log("BuyEngin", "buyProduct:: 无法找到指定的商品");
      return;
    }

    List<ProductDetails> products = response.productDetails;
    _products = [];
    if (products.isNotEmpty) {
      _products = products;
    }
    startPurchase(productId, orderId);
  }

  void startPurchase(String productId, String orderId) async {
    final config = payPluginConfigHolder.config;

    if (_products.isNotEmpty) {
      ProductDetails productDetails = _getProduct(productId);
      try {
        await _inAppPurchase.buyConsumable(
          purchaseParam: PurchaseParam(
            productDetails: productDetails,
            applicationUserName: orderId,
          ),
        );
      } catch (e) {
        config.dismissLoading();
        _resetPurchaseState();
        config.showToast(config.getMessage(PayMessageKey.payFailed), isTip: true);
        config.log("BuyEngin", "startPurchase::${e.toString()} 支付失败，可重新支付");
      }
    } else {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.noProductToPurchase), isTip: true);
      config.log("BuyEngin", "startPurchase:: 当前没有商品无法购买");
    }
  }

  ProductDetails _getProduct(String productId) {
    return _products.firstWhere((product) => product.id == productId);
  }

  void _listenToPurchaseUpdated(
    List<PurchaseDetails> purchaseDetailsList,
    FuncCallback? receiptCallBack,
  ) async {
    final config = payPluginConfigHolder.config;

    for (PurchaseDetails purchase in purchaseDetailsList) {
      config.log("BuyEngin", "购买状态更新: ${purchase.productID}, status: ${purchase.status}");

      if (purchase.status == PurchaseStatus.pending) {
        // 等待支付完成，保持 loading 状态
        config.log("BuyEngin", "支付等待中: ${purchase.productID}");
      } else if (purchase.status == PurchaseStatus.canceled) {
        _handleCancel(purchase);
      } else if (purchase.status == PurchaseStatus.error) {
        _handleError(purchase);
      } else if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        config.dismissLoading();
        _resetPurchaseState();
        if (Platform.isIOS) {
          var appstoreDetail = purchase as AppStorePurchaseDetails;
          checkApplePayInfo(appstoreDetail, receiptCallBack);
        }
      }
    }
  }

  void _handleError(PurchaseDetails purchase) async {
    final config = payPluginConfigHolder.config;

    config.dismissLoading();
    _resetPurchaseState();
    config.showToast(config.getMessage(PayMessageKey.payFailed), isTip: true);
    config.log("BuyEngin", "_handleError:: 支付失败，可重新支付");
    await _inAppPurchase.completePurchase(purchase);
  }

  void _handleCancel(PurchaseDetails purchase) async {
    final config = payPluginConfigHolder.config;

    config.dismissLoading();
    _resetPurchaseState();
    config.showToast(config.getMessage(PayMessageKey.payCancel), isTip: true);
    config.log("BuyEngin", "_handleCancel:: 支付取消，可重新支付");
    await _inAppPurchase.completePurchase(purchase);
  }

  void checkApplePayInfo(
    AppStorePurchaseDetails appstoreDetail,
    FuncCallback? receiptCallBack,
  ) async {
    receiptCallBack?.call(appstoreDetail.verificationData.serverVerificationData);
    _inAppPurchase.completePurchase(appstoreDetail);
  }

  void onClose() {
    _resetPurchaseState();
    if (Platform.isIOS) {
      final InAppPurchaseStoreKitPlatformAddition iosPlatformAddition =
          _inAppPurchase.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      iosPlatformAddition.setDelegate(null);
    }
    _subscription.cancel();
  }
}

class ExamplePaymentQueueDelegate implements SKPaymentQueueDelegateWrapper {
  @override
  bool shouldContinueTransaction(
    SKPaymentTransactionWrapper transaction,
    SKStorefrontWrapper storefront,
  ) {
    return false;
  }

  @override
  bool shouldShowPriceConsent() {
    return false;
  }
}