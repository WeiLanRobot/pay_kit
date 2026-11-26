import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ApplePurchaseFailure { cancelled, payment, verification }

extension on AppStorePurchaseDetails {
  String? get orderId =>
      skPaymentTransaction.payment.applicationUsername ??
      skPaymentTransaction.originalTransaction?.payment.applicationUsername;

  bool get paid =>
      status == PurchaseStatus.purchased || status == PurchaseStatus.restored;

  List<String> receiptRecord(String state) => [
        productID,
        purchaseID ?? '',
        verificationData.serverVerificationData,
        state
      ];
}

/// 按业务传入的存储范围恢复订单，并在验单成功后完成交易。
class ApplePurchaseSession {
  ApplePurchaseSession(this.scope, this.isCurrent, this.verify, this.onSuccess,
      this.onFailure, this.changed,
      {InAppPurchase? store})
      : store = store ?? InAppPurchase.instance;

  final InAppPurchase store;
  final String scope;
  final bool Function() isCurrent;
  final Future<bool> Function(String orderId, String receipt) verify;
  final void Function() onSuccess;
  final void Function(ApplePurchaseFailure) onFailure;
  final void Function() changed;
  final _pending = <String, PurchaseDetails>{};
  // 旧页面的验单可能尚未结束，新页面的补验和苹果回调要排在它之后。
  static Future<void> _transactions = Future.value();
  Future<void> _enqueue(Future<void> Function() action) {
    return _transactions =
        _transactions.then((_) => action()).catchError((Object error) {
      if (_current) onFailure(ApplePurchaseFailure.verification);
    });
  }

  // 旧入口收到其他会话的回调时，将收据交还给创建该订单的会话。
  static Future<void> retainReceipts(List<PurchaseDetails> batch) {
    final task = _transactions.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      for (final purchase in batch.whereType<AppStorePurchaseDetails>()) {
        final order = purchase.orderId;
        if (!purchase.paid ||
            order == null ||
            order.isEmpty ||
            purchase.verificationData.serverVerificationData.isEmpty) {
          continue;
        }
        for (final key
            in prefs.getKeys().where((key) => key.endsWith('/order/$order'))) {
          if (prefs.get(key) == purchase.productID &&
              !await prefs.setStringList(
                  key, purchase.receiptRecord('pending'))) {
            throw StateError('Could not persist App Store receipt');
          }
        }
      }
    });
    _transactions = task.catchError((Object _) {});
    return task;
  }

  String get _orderPrefix => '$scope/order/';
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  bool _closed = false;
  String? _activeOrder;
  bool get busy => _activeOrder != null;
  bool get hasPending => _pending.isNotEmpty;
  bool get _current => !_closed && isCurrent();

  void listen() {
    if (_closed || _subscription != null) return;
    _subscription = store.purchaseStream.listen((batch) {
      unawaited(_enqueue(() => _handleBatch(batch)));
    }, onError: (Object error) {
      _activeOrder = null;
      if (_current) changed();
      if (_current) onFailure(ApplePurchaseFailure.payment);
    });
    unawaited(_enqueue(_recoverReceipts));
  }

  Future<void> _recoverReceipts() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(_orderPrefix))) {
      if (!_current) return;
      final record = prefs.get(key) is List ? prefs.getStringList(key) : null;
      // 原有字符串只记录商品 ID。收到收据后才有足够的信息补验。
      if (record == null || record.length != 4) continue;
      final transaction = SKPaymentTransactionWrapper(
        payment: SKPaymentWrapper(
            productIdentifier: record[0],
            applicationUsername: key.substring(_orderPrefix.length)),
        transactionIdentifier: record[1].isEmpty ? null : record[1],
        transactionState: SKPaymentTransactionStateWrapper.purchased,
      );
      await _handle(
          AppStorePurchaseDetails.fromSKTransaction(transaction, record[2]));
    }
  }

  Future<void> buy(String orderId, String productId) async {
    if (!_current || busy) return;
    _activeOrder = orderId;
    changed();
    try {
      if (!await store.isAvailable()) throw StateError('StoreKit unavailable');
      final result = await store.queryProductDetails({productId});
      if (!_current) return;
      final product =
          result.productDetails.singleWhere((p) => p.id == productId);
      final prefs = await SharedPreferences.getInstance();
      if (!_current) return;
      // 先持久化，再拉起支付。不同订单互不覆盖。
      if (!await prefs.setString('$scope/order/$orderId', productId)) {
        throw StateError('Could not persist App Store order');
      }
      if (!_current) return;
      if (!await store.buyConsumable(
          purchaseParam: PurchaseParam(
              productDetails: product, applicationUserName: orderId))) {
        throw StateError('StoreKit rejected purchase');
      }
    } catch (_) {
      if (_activeOrder == orderId) _activeOrder = null;
      if (_current) {
        changed();
        onFailure(ApplePurchaseFailure.payment);
      }
    }
  }

  Future<void> retry() =>
      _enqueue(() => _handleBatch(_pending.values.toList()));

  Future<void> _handleBatch(List<PurchaseDetails> batch) async {
    final prefs = await SharedPreferences.getInstance();
    final ready = <AppStorePurchaseDetails>[];
    // 先保存本批收据。即使页面已关闭，也只写入原账号、原设备已建单的记录。
    for (final purchase in batch.whereType<AppStorePurchaseDetails>()) {
      final order = purchase.orderId;
      if (order == null ||
          order.isEmpty ||
          purchase.status == PurchaseStatus.pending) {
        continue;
      }
      final key = '$_orderPrefix$order';
      final record = prefs.get(key);
      final legacy = prefs.getString(scope) == order;
      if (purchase.paid &&
          record is! List &&
          record != 'verified' &&
          (record == purchase.productID || legacy)) {
        try {
          if (purchase.verificationData.serverVerificationData.isEmpty ||
              !await prefs.setStringList(
                  key, purchase.receiptRecord('pending'))) {
            throw StateError('Could not persist App Store receipt');
          }
        } catch (_) {
          _pending[order] = purchase;
          if (_activeOrder == order) _activeOrder = null;
          if (_current) {
            changed();
            onFailure(ApplePurchaseFailure.verification);
          }
          continue;
        }
      }
      ready.add(purchase);
    }
    for (final purchase in ready) {
      await _handle(purchase);
    }
  }

  Future<void> _handle(AppStorePurchaseDetails purchase) async {
    if (!_current) return;
    final order = purchase.orderId;
    if (order == null || order.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_current) return;
      final key = '$scope/order/$order';
      final record = prefs.get(key);
      final saved = record is List ? prefs.getStringList(key) : null;
      final marker = saved == null ? record : saved.first;
      final legacy = prefs.getString(scope) == order;
      if (marker != purchase.productID && marker != 'verified' && !legacy) {
        return;
      }
      final paid = purchase.paid;
      if (paid) {
        _pending[order] = purchase;
        if (marker != 'verified' && saved?.last != 'verified') {
          final receipt = purchase.verificationData.serverVerificationData;
          if (receipt.isEmpty || !await verify(order, receipt)) {
            throw StateError('Receipt verification failed');
          }
          if (!await prefs.setStringList(
              key, purchase.receiptRecord('verified'))) {
            throw StateError('Could not persist verified order');
          }
        }
      }
      if (purchase.pendingCompletePurchase) {
        await store.completePurchase(purchase);
      }
      _pending.remove(order);
      await prefs.remove(key);
      if (legacy && prefs.getString(scope) == order) await prefs.remove(scope);
      if (_current) {
        if (paid) {
          onSuccess();
        } else {
          onFailure(purchase.status == PurchaseStatus.canceled
              ? ApplePurchaseFailure.cancelled
              : ApplePurchaseFailure.payment);
        }
      }
    } catch (_) {
      if (_current) {
        onFailure(_pending.containsKey(order)
            ? ApplePurchaseFailure.verification
            : ApplePurchaseFailure.payment);
      }
    } finally {
      if (_activeOrder == order) _activeOrder = null;
      if (_current) changed();
    }
  }

  void dispose() {
    _closed = true;
    unawaited(_subscription?.cancel());
  }
}
