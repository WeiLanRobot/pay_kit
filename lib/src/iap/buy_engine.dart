import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

import '../config/pay_config.dart';
import '../config/pay_config_holder.dart';

typedef ReceiptCallback = Function(String receipt);

/// 苹果内购引擎
class BuyEngine {
  late StreamSubscription<List<PurchaseDetails>> _subscription;
  late InAppPurchase _inAppPurchase;
  List<ProductDetails> _products = [];

  /// 防止重复点击购买
  bool _isPurchasing = false;

  void initialize(ReceiptCallback? receiptCallback) async {
    final config = payConfigHolder.config;

    _inAppPurchase = InAppPurchase.instance;

    // iOS 平台初始化时清理未完成的交易
    if (Platform.isIOS) {
      await _clearPendingTransactions();
    }

    final Stream<List<PurchaseDetails>> purchaseUpdated = _inAppPurchase.purchaseStream;
    _subscription = purchaseUpdated.listen(
      (purchaseDetailsList) {
        _listenToPurchaseUpdated(purchaseDetailsList, receiptCallback);
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
        config.log("BuyEngine", "initialize: 支付失败，可重新支付");
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
      final config = payConfigHolder.config;

      for (var transaction in transactions) {
        config.log("BuyEngine",
            "发现未完成交易: ${transaction.payment.productIdentifier}, 状态: ${transaction.transactionState}");

        if (transaction.transactionState == SKPaymentTransactionStateWrapper.failed) {
          await SKPaymentQueueWrapper().finishTransaction(transaction);
          config.log("BuyEngine", "已清理失败交易: ${transaction.payment.productIdentifier}");
        }
      }
    } catch (e) {
      payConfigHolder.config.log("BuyEngine", "_clearPendingTransactions 异常: $e");
    }
  }

  /// 购买前检查并清理该商品的待处理交易
  Future<bool> _checkAndClearPendingForProduct(String productId) async {
    try {
      final transactions = await SKPaymentQueueWrapper().transactions();
      final config = payConfigHolder.config;

      final pendingForProduct = transactions
          .where((t) => t.payment.productIdentifier == productId)
          .toList();

      if (pendingForProduct.isNotEmpty) {
        config.log("BuyEngine", "发现该商品未完成的交易，正在清理: $productId");
        for (var t in pendingForProduct) {
          if (t.transactionState == SKPaymentTransactionStateWrapper.purchasing) {
            config.log("BuyEngine", "该商品有正在进行的交易，请稍后再试");
            return false;
          }
          await SKPaymentQueueWrapper().finishTransaction(t);
          config.log("BuyEngine", "已清理该商品的待处理交易: $productId");
        }
      }
      return true;
    } catch (e) {
      payConfigHolder.config.log("BuyEngine", "_checkAndClearPendingForProduct 异常: $e");
      return true;
    }
  }

  void buyProduct(String productId, String orderId) async {
    final config = payConfigHolder.config;

    if (_isPurchasing) {
      config.log("BuyEngine", "buyProduct: 正在购买中，请勿重复点击");
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
      config.log("BuyEngine", "buyProduct: 无法连接到商店");
      return;
    }

    if (Platform.isIOS) {
      final canProceed = await _checkAndClearPendingForProduct(productId);
      if (!canProceed) {
        config.dismissLoading();
        _resetPurchaseState();
        config.showToast(config.getMessage(PayMessageKey.processing), isTip: true);
        return;
      }

      final InAppPurchaseStoreKitPlatformAddition iosPlatformAddition =
          _inAppPurchase.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      await iosPlatformAddition.setDelegate(_PaymentQueueDelegate());
    }

    final ProductDetailsResponse response = await _inAppPurchase.queryProductDetails({productId});

    if (response.error != null) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.queryProductFailed), isTip: true);
      config.log("BuyEngine", "buyProduct: 查询商品信息失败");
      return;
    }

    if (response.productDetails.isEmpty) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.noProduct), isTip: true);
      config.log("BuyEngine", "buyProduct: 暂无商品");
      return;
    }

    if (response.notFoundIDs.isNotEmpty) {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.productNotFound), isTip: true);
      config.log("BuyEngine", "buyProduct: 无法找到指定的商品");
      return;
    }

    _products = response.productDetails;
    _startPurchase(productId, orderId);
  }

  void _startPurchase(String productId, String orderId) async {
    final config = payConfigHolder.config;

    if (_products.isNotEmpty) {
      final productDetails = _products.firstWhere((product) => product.id == productId);
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
        config.log("BuyEngine", "_startPurchase: ${e.toString()} 支付失败，可重新支付");
      }
    } else {
      config.dismissLoading();
      _resetPurchaseState();
      config.showToast(config.getMessage(PayMessageKey.noProductToPurchase), isTip: true);
      config.log("BuyEngine", "_startPurchase: 当前没有商品无法购买");
    }
  }

  void _listenToPurchaseUpdated(
    List<PurchaseDetails> purchaseDetailsList,
    ReceiptCallback? receiptCallback,
  ) async {
    final config = payConfigHolder.config;

    for (PurchaseDetails purchase in purchaseDetailsList) {
      config.log("BuyEngine", "购买状态更新: ${purchase.productID}, status: ${purchase.status}");

      if (purchase.status == PurchaseStatus.pending) {
        config.log("BuyEngine", "支付等待中: ${purchase.productID}");
      } else if (purchase.status == PurchaseStatus.canceled) {
        _handleCancel(purchase);
      } else if (purchase.status == PurchaseStatus.error) {
        _handleError(purchase);
      } else if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        config.dismissLoading();
        _resetPurchaseState();
        if (Platform.isIOS) {
          final appstoreDetail = purchase as AppStorePurchaseDetails;
          _verifyReceipt(appstoreDetail, receiptCallback);
        }
      }
    }
  }

  void _handleError(PurchaseDetails purchase) async {
    final config = payConfigHolder.config;

    config.dismissLoading();
    _resetPurchaseState();
    config.showToast(config.getMessage(PayMessageKey.payFailed), isTip: true);
    config.log("BuyEngine", "_handleError: 支付失败，可重新支付");
    await _inAppPurchase.completePurchase(purchase);
  }

  void _handleCancel(PurchaseDetails purchase) async {
    final config = payConfigHolder.config;

    config.dismissLoading();
    _resetPurchaseState();
    config.showToast(config.getMessage(PayMessageKey.payCancel), isTip: true);
    config.log("BuyEngine", "_handleCancel: 支付取消，可重新支付");
    await _inAppPurchase.completePurchase(purchase);
  }

  void _verifyReceipt(
    AppStorePurchaseDetails appstoreDetail,
    ReceiptCallback? receiptCallback,
  ) async {
    receiptCallback?.call(appstoreDetail.verificationData.serverVerificationData);
    _inAppPurchase.completePurchase(appstoreDetail);
  }

  void dispose() {
    _resetPurchaseState();
    if (Platform.isIOS) {
      final InAppPurchaseStoreKitPlatformAddition iosPlatformAddition =
          _inAppPurchase.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      iosPlatformAddition.setDelegate(null);
    }
    _subscription.cancel();
  }
}

class _PaymentQueueDelegate implements SKPaymentQueueDelegateWrapper {
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