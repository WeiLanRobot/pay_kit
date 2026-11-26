import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pay_kit/storekit1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final store = StoreKitAppleStore();

  StoreEvent event(String handle, String status,
          {String? queueId, String? original}) =>
      StoreEvent.fromNative({
        'productId': 'coins',
        'status': status,
        'handle': handle,
        'token': 'original-token',
        'transactionId': original ?? queueId,
        'originalTransactionId': original,
        'queueId': queueId,
      }, 'app receipt');

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
      'restores verify the original purchase and retain the current queue object',
      () {
    final replay =
        event('object-A', 'paid', queueId: 'restore', original: 'purchase');
    final copy = replay.withReceipt('fresh');
    expect(copy.native, 'object-A');
    expect(copy.queueId, 'restore');
    expect(copy.originalTransactionId, 'purchase');
    expect(copy.transactionId, 'purchase');
    expect(copy.token, 'original-token');
    expect(replay.receipt, 'app receipt');
    expect(copy.receipt, 'fresh');
  });

  test('only the observed object and terminal state authorize native finish',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'finished';
    });
    await store.finish(event('object-A', 'failed'));
    await store.finish(event('object-B', 'canceled'));
    await store.finish(event('object-C', 'paid', queueId: 'purchase'));
    final deferred = event('object-D', 'pending');
    expect(deferred.needsFinish, isFalse);
    expect(deferred.receipt, isEmpty);
    await store.finish(deferred);
    expect(calls.map((c) => c.method), ['finish', 'finish', 'finish']);
    expect(calls.map((c) => c.arguments['handle']),
        ['object-A', 'object-B', 'object-C']);
    expect(calls.map((c) => c.arguments['status']),
        ['failed', 'canceled', 'paid']);
    for (final call in calls) {
      expect(call.arguments['writer'], isNotEmpty);
      expect((call.arguments as Map).keys,
          unorderedEquals(['writer', 'status', 'handle']));
    }
  });

  test('a missing or unknown outcome never acknowledges a finish', () async {
    final paid = event('object-A', 'paid', queueId: 'purchase');
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await expectLater(store.finish(paid), throwsStateError);
    messenger.setMockMethodCallHandler(channel, (_) async => 'not_found');
    await expectLater(store.finish(paid), throwsStateError);
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'not_found'));
    await expectLater(store.finish(paid), throwsA(isA<PlatformException>()));
    messenger.setMockMethodCallHandler(channel, (_) async => 'removed');
    await store.finish(paid);
  });
}
