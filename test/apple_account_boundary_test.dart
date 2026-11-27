import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

void main() {
  late ProbeStore store;
  late ApplePayments payments;
  late Directory temp;

  AppleAccount login(String scope) =>
      payments.connect(scope: scope, verify: (r) async => delivered(r));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('paykit-session-');
    store = ProbeStore();
    payments = ApplePayments.forTesting(
      store,
      AppleJournal(() async => File('${temp.path}/ledger')),
    );
    await payments.start(environment: 'sandbox');
  });

  tearDown(() async {
    await payments.close();
    await store.stream.close();
    await temp.delete(recursive: true);
  });

  test(
      'logout revokes the shared purchase result and preserves the original order',
      () async {
    final a = login('A');
    final entered = Completer<void>();
    final accepted = Completer<bool>();
    store.launch = () {
      entered.complete();
      return accepted.future;
    };
    final first = a.buy(productId: 'sku', orderId: 'O');
    final second = a.buy(productId: 'sku', orderId: 'O');
    expect(identical(first, second), isTrue);
    await entered.future;
    store.event(store.submitted.single, 'T');
    await payments.settle();
    final b = login('B');
    expect(await b.lookup('O'), isNull);

    final revoked = expectLater(first, throwsStateError);
    accepted.complete(true);
    await revoked;
    expect((await login('A').lookup('O'))!.charges.single.reference, 'ack-T');
    expect(store.submitted, hasLength(1));
    expect(store.finished, hasLength(1));
  });

  test('relogin during native submission shares the result with the new handle',
      () async {
    final a = login('A');
    final entered = Completer<void>(), result = Completer<bool>();
    store.launch = () {
      entered.complete();
      return result.future;
    };
    final first = a.buy(productId: 'sku', orderId: 'O');
    await entered.future;
    final revoked = expectLater(first, throwsStateError);
    final next = login('A');
    final accepted = next.buy(productId: 'sku', orderId: 'O');
    expect(
        identical(accepted, next.buy(productId: 'sku', orderId: 'O')), isTrue);
    result.complete(true);
    expect((await accepted).phase, 'accepted');
    await revoked;
    expect(store.submitted, hasLength(1));
  });

  test('resuming a paused subscription after relogin drops all old snapshots',
      () async {
    final a = login('A');
    final snapshots = <AppleOrderSnapshot?>[];
    final initial = Completer<void>();
    final closed = Completer<void>();
    final sub = a.watch('O').listen((s) {
      snapshots.add(s);
      if (!initial.isCompleted) initial.complete();
    }, onDone: closed.complete);
    await initial.future;
    sub.pause();
    final checkout = await a.buy(productId: 'sku', orderId: 'O');
    store.event(checkout.attemptId, 'T');
    await payments.settle();
    // Another active listener confirms the terminal snapshot is available.
    await a
        .watch('O')
        .firstWhere((s) => s?.charges.lastOrNull?.reference == 'ack-T');
    final next = login('A');
    sub.resume();
    await closed.future;
    expect(snapshots, [null]);
    expect((await next.watch('O').first)!.charges.single.reference, 'ack-T');
  });

  test(
      'validating a supplied UUID before purchase uses the same rules as receipt matching',
      () async {
    final a = login('A');
    // Correct layout, invalid version / variant.
    for (final token in [
      'abcabcab-cdef-4abc-cabc-abcdefabcdef',
      'abcabcab-cdef-fabc-8abc-abcdefabcdef'
    ]) {
      await expectLater(
          a.buy(productId: 'sku', orderId: 'O', purchaseToken: token),
          throwsArgumentError);
    }
    expect(store.submitted, isEmpty);
    expect(await a.lookup('O'), isNull);
    const accepted = 'ABCABCAB-CDEF-4ABC-8ABC-ABCDEFABCDEF';
    await a.buy(productId: 'sku', orderId: 'O', purchaseToken: accepted);
    expect(store.submitted.single, accepted.toLowerCase());
    store.event(accepted, 'T');
    await payments.settle();
    expect((await a.lookup('O'))!.charges.single.reference, 'ack-T');
  });
}
