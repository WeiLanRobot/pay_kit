import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../config/pay_config.dart';

enum StoreStatus { pending, paid, canceled, failed }

class StoreEvent {
  const StoreEvent({
    required this.productId,
    required this.status,
    this.token,
    this.transactionId,
    this.originalTransactionId,
    this.receipt = '',
    this.queueId,
    this.needsFinish = true,
    this.removed = false,
    this.allowsUnownedFinish = true,
    this.native,
  });

  factory StoreEvent.fromNative(Map<Object?, Object?> item, String receipt,
      {bool removed = false}) {
    final handle = item['handle'];
    if (handle is! String || handle.isEmpty) {
      throw const FormatException('Missing StoreKit object handle');
    }
    final status = StoreStatus.values.byName(item['status'] as String);
    return StoreEvent(
      productId: item['productId'] as String,
      status: status,
      token: item['token'] as String?,
      transactionId: item['transactionId'] as String?,
      originalTransactionId: item['originalTransactionId'] as String?,
      queueId: item['queueId'] as String?,
      receipt: !removed && status == StoreStatus.paid ? receipt : '',
      needsFinish: !removed && status != StoreStatus.pending,
      removed: removed,
      allowsUnownedFinish: item['allowsUnownedFinish'] as bool? ?? true,
      native: handle,
    );
  }

  final String productId;
  final StoreStatus status;
  final String? token;

  /// A restore verifies the original purchase.
  final String? transactionId;
  final String? originalTransactionId;
  final String receipt;

  /// The current queue transaction's own Apple identifier, when available.
  final String? queueId;
  final bool needsFinish;

  /// StoreKit observed the removal of this exact native object.
  final bool removed;

  /// Whether the host catalog delegates unowned canceled/failed items for this SKU.
  final bool allowsUnownedFinish;

  /// An opaque handle bound to an individual object in the current process.
  final Object? native;

  StoreEvent withReceipt(String value) => StoreEvent(
        productId: productId,
        status: status,
        token: token,
        transactionId: transactionId,
        originalTransactionId: originalTransactionId,
        queueId: queueId,
        receipt: value,
        needsFinish: needsFinish,
        removed: removed,
        allowsUnownedFinish: allowsUnownedFinish,
        native: native,
      );
}

class StoreLaunchException implements Exception {
  const StoreLaunchException(this.messageKey, [this.reason]);
  final PayMessageKey messageKey;
  final String? reason;

  @override
  String toString() => 'StoreKit: ${reason ?? messageKey.name}';
}

class StorePurchaseRejected extends StoreLaunchException {
  const StorePurchaseRejected() : super(PayMessageKey.processing);
}

class StoreSubmissionUnresolved extends StoreLaunchException {
  const StoreSubmissionUnresolved() : super(PayMessageKey.processing);
}

abstract class AppleStore {
  Future<String> bundleIdentifier();
  Stream<List<StoreEvent>> get events;
  Future<void> prepare(String productId);
  Future<bool> purchase(String productId, String token);
  Future<void> finish(StoreEvent event, {bool verifiedQueue = false});
  Future<String?> refreshReceipt();
}

abstract interface class AppleStoreLifecycle {
  Future<void> start();
  Future<void> snapshot();
  Future<void> stop();
}

class StoreKitAppleStore implements AppleStore, AppleStoreLifecycle {
  static const _channel = MethodChannel('pay_kit/storekit1');
  static StoreKitAppleStore? _owner;
  String _writer = const Uuid().v4();
  Future<void>? _startup;
  final _events = StreamController<List<StoreEvent>>.broadcast(sync: true);

  @override
  Future<String> bundleIdentifier() async =>
      (await _call<String>('bundleIdentifier')) ??
      (throw StateError('Missing StoreKit application identity'));

  @override
  Stream<List<StoreEvent>> get events => _events.stream;

  /// Subscribe to events first. Startup fails before a second writer can
  /// access the journal or enqueue a payment.
  @override
  Future<void> start() => _startup ??= _acquire().catchError((Object error) {
        _startup = null;
        throw error;
      });

  Future<void> _acquire() async {
    if (!Platform.isIOS) return;
    if (RootIsolateToken.instance == null ||
        (_owner != null && !identical(_owner, this))) {
      throw StateError(
          'StoreKit already has a coordinator or requires the root isolate');
    }
    _writer = const Uuid().v4();
    final generation = _writer;
    _owner = this;
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'updated' && call.method != 'removed') {
          throw MissingPluginException();
        }
        final batch = call.arguments as Map;
        if (batch['writer'] == generation && generation == _writer) {
          _receive(batch, removed: call.method == 'removed');
        }
      });
      _receive(await _call<Object>('start'));
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) =>
      _channel.invokeMethod<T>(method, {'writer': _writer, ...args});

  @override
  Future<void> stop() async {
    if (identical(_owner, this)) {
      try {
        await _call<void>('stop');
      } finally {
        _channel.setMethodCallHandler(null);
        _writer = const Uuid().v4();
        _owner = null;
        _startup = null;
      }
    }
  }

  @override
  Future<void> snapshot() async {
    if (Platform.isIOS) _receive(await _call<Object>('snapshot'));
  }

  void _receive(Object? message, {bool removed = false}) {
    final batch = message as Map;
    final receipt = batch['receipt'] as String;
    final events = [
      for (final item in batch['transactions'] as List)
        StoreEvent.fromNative(item as Map<Object?, Object?>, receipt,
            removed: removed),
    ];
    if (events.isNotEmpty) _events.add(events);
  }

  @override
  Future<void> prepare(String productId) async {
    if (!Platform.isIOS) {
      throw const StoreLaunchException(PayMessageKey.unableConnectStore);
    }
    await start();
    try {
      await _call<void>('prepare', {'productId': productId});
    } on PlatformException catch (error) {
      throw switch (error.code) {
        'unsupported_product_type' => const StoreLaunchException(
            PayMessageKey.noProductToPurchase,
            'This product is not eligible for a consumable purchase'),
        'invalid_consumable_catalog' => const FormatException(
            'PayKitConsumableProductIdentifiers must be an array of nonempty strings'),
        'cannot_pay' =>
          const StoreLaunchException(PayMessageKey.unableConnectStore),
        'unknown_product' =>
          const StoreLaunchException(PayMessageKey.productNotFound),
        _ => const StoreLaunchException(PayMessageKey.queryProductFailed),
      };
    }
  }

  @override
  Future<bool> purchase(String productId, String token) async {
    await start();
    try {
      await _call<void>('purchase', {'productId': productId, 'token': token});
      return true;
    } on PlatformException catch (error) {
      if (error.code == 'duplicate_product') {
        throw const StorePurchaseRejected();
      }
      rethrow;
    }
  }

  @override
  Future<void> finish(StoreEvent event, {bool verifiedQueue = false}) async {
    if (!event.needsFinish) return;
    final handle = event.native;
    if (handle is! String ||
        handle.isEmpty ||
        event.status == StoreStatus.pending) {
      throw StateError('Missing finishable StoreKit object handle');
    }
    final result = await _call<String>('finish', {
      'handle': handle,
      'status': event.status.name,
      if (verifiedQueue)
        'verifiedQueue': {
          'transactionId': event.transactionId,
          'productId': event.productId,
          'token': event.token,
        },
    });
    if (result != 'finished' && result != 'removed') {
      throw StateError('StoreKit could not confirm finish');
    }
  }

  @override
  Future<String?> refreshReceipt() async {
    await start();
    return _call<String>('refreshReceipt');
  }
}
