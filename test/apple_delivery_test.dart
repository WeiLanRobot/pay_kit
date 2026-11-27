import 'dart:async';
import 'dart:io';

import 'verified_queue_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_payments.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

class _Store implements AppleStore {
  @override
  Future<String> bundleIdentifier() async => 'app';

  final updates = StreamController<List<StoreEvent>>.broadcast(sync: true);
  final submissions = <String>[];
  final finished = <StoreEvent>[];
  Future<void> Function(StoreEvent)? beforeFinish;
  bool loseSubmissionReply = false;
  @override
  Stream<List<StoreEvent>> get events => updates.stream;
  @override
  Future<void> prepare(String productId) async {}
  @override
  Future<bool> purchase(String productId, String token) async {
    submissions.add(token);
    if (loseSubmissionReply) throw StateError('lost StoreKit response');
    return true;
  }

  @override
  Future<void> finish(StoreEvent e, {bool verifiedQueue = false}) async {
    await beforeFinish?.call(e);
    finished.add(e);
  }

  @override
  Future<String?> refreshReceipt() async => 'refreshed';
  void paid(String? token, String? transaction,
      {String body = 'receipt', String? queue, String? handle}) {
    updates.add([
      StoreEvent(
          productId: 'coins',
          status: StoreStatus.paid,
          transactionId: transaction,
          token: token,
          queueId: queue,
          receipt: body,
          native: handle)
    ]);
  }
}

AppleVerification ack(AppleReceipt r,
    {String? verified, AppleOutcome outcome = AppleOutcome.delivered}) {
  final id = verified ?? r.transactionId;
  return AppleVerification.delivered(AppleDisposition(
      appId: 'app',
      environment: 'sandbox',
      scope: r.scope,
      orderId: r.orderId,
      productId: r.productId,
      reportedTransactionId: r.transactionId,
      verifiedTransactionId: id,
      reference: 'ack-$id',
      outcome: outcome));
}

AppleClaim claim(String reported,
        {String? verified,
        String order = 'order',
        String? token,
        AppleDisposition? disposition}) =>
    AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: order,
        productId: 'coins',
        reportedTransactionId: reported,
        verifiedTransactionId: verified ?? reported,
        reference: 'claim-$reported',
        purchaseToken: token,
        disposition: disposition);

AppleAttemptDecision recovery(
        String id, String order, AppleAttemptOutcome outcome,
        {String scope = 'A', AppleClaim? claim}) =>
    AppleAttemptDecision(
        issuer: 'server',
        decisionId: '$id-${outcome.name}-$scope',
        appId: 'app',
        attemptId: id,
        environment: 'sandbox',
        attemptProof: 'authenticated-server-attempt-$id',
        scope: scope,
        orderId: order,
        reference: 'recovery-$order',
        outcome: outcome,
        claim: claim);

void main() {
  late Directory dir;
  late ApplePayments payments;
  late _Store store;
  late AppleJournal journal;
  Future<void> start() async {
    store = _Store();
    journal = AppleJournal(() async => File('${dir.path}/ledger'));
    payments = ApplePayments.forTesting(store, journal);
    await payments.start(environment: 'sandbox');
  }

  Future<void> close() async {
    await payments.close();
    await store.updates.close();
  }

  Future<void> restart() async {
    await close();
    await start();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('paykit-delivery-');
    await start();
  });
  tearDown(() async {
    await close();
    await dir.delete(recursive: true);
  });

  test(
      'offline replacement evidence survives restart, remains scoped, rejected bytes stop retrying',
      () async {
    final seen = <String>[];
    final acct = payments.connect(
        scope: 'A',
        verify: (r) async {
          seen.add(r.receipt);
          return const AppleVerification.invalidEvidence();
        });
    await acct.buy(productId: 'coins', orderId: 'order');
    final token = store.submissions.single;
    store.paid(token, 'T', body: 'old', queue: 'Q');
    await payments.settle();
    acct.dispose();
    var leaked = false;
    payments.connect(
        scope: 'B',
        verify: (r) async {
          leaked = true;
          return ack(r);
        });
    store.paid(token, 'T', body: 'new', queue: 'Q');
    await payments.settle();
    await restart();
    final seenOnRestart = <String>[];
    final restored = payments.connect(
        scope: 'A',
        verify: (r) async {
          seenOnRestart.add(r.receipt);
          return ack(r);
        });
    await payments.retryPending();
    await payments.settle();
    expect(seen, ['old']);
    expect(leaked, false);
    expect(seenOnRestart, ['new']);
    expect(
        (await restored.lookup('order'))!.charges.single.finishPending, true);
    store.paid(null, 'T', body: 'old', handle: 'replayed', queue: 'Q');
    await payments.settle();
    expect(store.finished, isEmpty);
    store.paid(token, 'T', body: 'old', handle: 'replayed', queue: 'Q');
    await payments.settle();
    await payments.reconcile(claim('T', token: token));
    await payments.settle();
    expect(store.finished.single.transactionId, 'T');
    expect(
        (await restored.lookup('order'))!.charges.single.finishPending, false);
    expect(store.submissions, isEmpty);
  });

  test('refresh wakes a verifier after a thrown exception', () async {
    final seen = <String>[];
    final acct = payments.connect(
        scope: 'A',
        verify: (r) async {
          seen.add(r.receipt);
          if (r.receipt == 'stale') throw StateError('temporary');
          return ack(r);
        });
    await acct.buy(productId: 'coins', orderId: 'order');
    store.paid(store.submissions.single, 'T', body: 'stale');
    await payments.settle();
    await payments.refreshReceipts();
    await payments.settle();
    expect(seen.last, 'refreshed');
    expect(store.finished.single.transactionId, 'T');
  });

  test(
      'trusted claims independently dispose two charges, preserving absent Apple tokens',
      () async {
    final seen = <AppleReceipt>[];
    final acct = payments.connect(
        scope: 'A',
        verify: (r) async {
          seen.add(r);
          return ack(r,
              verified: r.transactionId,
              outcome: r.additionalCharge
                  ? AppleOutcome.refunded
                  : AppleOutcome.delivered);
        });
    store.paid(null, 'T1', queue: 'T1', handle: 'h1');
    store.paid(null, 'T2', queue: 'T2', handle: 'h2');
    await payments.settle();
    for (final t in ['T1', 'T2']) {
      final c = claim(t);
      await proveQueue(payments, c);
      await payments.settle();
      await payments.reconcile(c);
      await payments.settle();
    }
    expect(seen.map((r) => r.purchaseToken), [null, null]);
    expect(seen.map((r) => r.additionalCharge), [false, true]);
    expect(store.finished.map((r) => r.queueId), ['T1', 'T2']);
    expect((await acct.lookup('order'))!.charges.map((r) => r.disposition),
        ['delivered', 'refunded']);
    expect(store.submissions, isEmpty);
  });

  test(
      'two independently observed aliases share a verified transaction and finish each queue item',
      () async {
    final creator = payments.connect(scope: 'A', verify: (r) async => ack(r));
    final token =
        (await creator.buy(productId: 'coins', orderId: 'order')).attemptId!;
    await restart();
    final verifies = <String>[];
    final acct = payments.connect(
        scope: 'A',
        verify: (r) async {
          verifies.add(r.transactionId);
          return ack(r, verified: 'V');
        });
    store.paid(token, 'T1', queue: 'q1');
    store.paid(token, 'T2', queue: 'q2');
    await payments.settle();
    await payments.reconcile(claim('T1', verified: 'V', token: token));
    await payments.settle();
    await payments.reconcile(claim('T2', verified: 'V', token: token));
    await payments.settle();
    expect(verifies, ['T1']);
    expect(store.finished.map((r) => r.queueId), ['q1', 'q2']);
    expect((await acct.lookup('order'))!.charges, hasLength(1));
    store.paid(null, 'T2', queue: 'q3');
    await payments.settle();
    expect(store.finished.map((e) => e.queueId), ['q1', 'q2']);
    expect((await payments.unmatched()).single.transactionId, 'T2');
    expect(verifies, ['T1']);
  });

  test(
      'trusted alias conflicts preserve token ownership after the canonical disposition',
      () async {
    const first = 'ca2f8b2c-adaf-4d6b-bad4-b665e1c392a3';
    const other = '1efae3c5-f85e-4896-930b-12d8be4dc522';
    final a = payments.connect(
        scope: 'A', verify: (r) async => ack(r, verified: 'V'));
    await a.buy(productId: 'coins', orderId: 'order', purchaseToken: first);
    store.paid(first, 'T1', queue: 'q1');
    await payments.settle();
    store.paid(null, 'T2', queue: 'q2');
    await payments.settle();
    await expectLater(
        payments.reconcile(claim('T2', verified: 'V', token: other)),
        throwsStateError);
    await payments.settle();
    expect(store.finished.map((e) => e.queueId), ['q1']);
    expect((await payments.unmatched()).single.transactionId, 'T2');
    expect((await a.lookup('order'))!.charges.single.disposition, 'delivered');
  });

  test(
      'nil reported id is grouped, separately retaining different original evidence',
      () async {
    for (var i = 0; i < 4; i++) {
      store.paid(null, null, body: 'one', handle: 'h1');
      await payments.retryPending();
    }
    store.paid(null, null, body: 'two', handle: 'h2');
    await payments.settle();
    await restart();
    final item = (await payments.unmatched()).single;
    expect(item.receipts, ['one', 'two']);
    expect(item.transactionId, isNull);
    expect(store.finished, isEmpty);
  });

  test(
      'finishes distinct unbound failed objects while independently ingesting payment and deferred events',
      () async {
    final entered = Completer<void>(),
        release = Completer<void>(),
        paid = Completer<void>();
    final a = payments.connect(
        scope: 'A',
        verify: (r) async {
          if (!paid.isCompleted) paid.complete();
          return ack(r);
        });
    await a.buy(productId: 'coins', orderId: 'order');
    store.beforeFinish = (e) async {
      if (e.native == 'A') {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
    };
    store.updates.add([
      const StoreEvent(
          productId: 'coins', status: StoreStatus.canceled, native: 'A')
    ]);
    await entered.future;
    try {
      store.updates.add([
        const StoreEvent(
            productId: 'coins', status: StoreStatus.failed, native: 'B'),
        const StoreEvent(
            productId: 'coins', status: StoreStatus.pending, native: 'D'),
      ]);
      store.paid(store.submissions.single, 'T', handle: 'paid');
      await paid.future.timeout(const Duration(seconds: 4));
    } finally {
      release.complete();
    }
    await payments.settle();
    expect(store.finished.map((e) => e.native),
        unorderedEquals(['A', 'B', 'paid']));
    expect((await a.lookup('order'))!.phase, 'paid');
  });

  test('mixed catalog leaves foreign failures to their owner after replay',
      () async {
    final a = payments.connect(scope: 'A', verify: (r) async => ack(r));
    final failed = await a.buy(productId: 'old-sku', orderId: 'cancel');
    final paid = await a.buy(productId: 'old-sku', orderId: 'paid');
    // The first event durably identifies an item before a later app version
    // takes this SKU off its consumable list.
    store.updates.add([
      StoreEvent(
          productId: 'old-sku',
          queueId: 'known',
          status: StoreStatus.pending,
          token: failed.attemptId)
    ]);
    await payments.settle();
    await restart();
    final current = payments.connect(scope: 'A', verify: (r) async => ack(r));
    StoreEvent observe(String id, String status, {String? token}) =>
        StoreEvent.fromNative({
          'productId': 'old-sku',
          'status': status,
          'handle': id,
          'queueId': id,
          'transactionId': status == 'paid' ? id : null,
          'token': token,
          'allowsUnownedFinish': false,
        }, 'receipt');
    final events = [
      observe('foreign-failure', 'failed'),
      observe('foreign-cancel', 'canceled'),
      observe('known', 'canceled'),
      observe('paid', 'paid', token: paid.attemptId),
    ];
    store.updates.add(events);
    await payments.settle();
    await payments.retryPending();
    store.updates.add(events);
    await payments.settle();
    expect(store.finished.map((e) => e.native), ['known']);
    await payments.reconcile(AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'paid',
        productId: 'old-sku',
        reportedTransactionId: 'paid',
        verifiedTransactionId: 'paid',
        reference: 'signed-paid',
        purchaseToken: paid.attemptId));
    await payments.settle();
    expect(store.finished.map((e) => e.native),
        unorderedEquals(['known', 'paid']));
    // A cold failure with no token confirms removal without settling the old order.
    expect((await current.lookup('cancel'))!.phase, 'pending');
    expect((await current.lookup('paid'))!.charges.single.finishPending, false);
  });

  test(
      'nil handle promoted to named queue item retains its durable identity across replay',
      () async {
    final a = payments.connect(scope: 'A', verify: (r) async => ack(r));
    await a.buy(productId: 'coins', orderId: 'order');
    final token = store.submissions.single;
    store.paid(token, null, handle: 'H');
    await payments.settle();
    expect(store.finished, isEmpty);
    store.beforeFinish = (e) async {
      throw StateError('device offline');
    };
    store.paid(token, 'T', handle: 'H', queue: 'Q');
    await payments.settle();
    expect((await a.lookup('order'))!.charges.single.finishPending, true);
    await restart();
    final seen = <String>[];
    final b = payments.connect(
        scope: 'A',
        verify: (r) async {
          seen.add(r.receipt);
          return ack(r);
        });
    store.paid(token, 'T', handle: 'new-process-H', queue: 'Q');
    await payments.settle();
    expect(store.finished, isEmpty);
    await payments.reconcile(claim('T', token: token));
    await payments.settle();
    expect((await b.lookup('order'))!.charges.single.finishPending, false);
    expect(store.finished.single.native, 'new-process-H');
    expect(seen, isEmpty);
  });

  test('legacy receipt only reaches its originating active receiver generation',
      () async {
    final a = Object(), b = Object();
    final seenA = <String>[], seenB = <String>[];
    payments.attachLegacy(a, (r) async {
      seenA.add(r);
    }, (_, __) {}, (_) {});
    payments.attachLegacy(b, (r) async {
      seenB.add(r);
    }, (_, __) {}, (_) {});
    await payments.buyLegacy(a, 'coins', 'legacy-A');
    await payments.buyLegacy(b, 'coins', 'legacy-B');
    payments.detachLegacy(a);
    store.paid('legacy-A', 'A');
    store.paid('legacy-B', 'B');
    await payments.settle();
    expect(seenA, isEmpty);
    expect(seenB, ['receipt']);
    expect(store.finished.map((r) => r.transactionId), ['B']);
    expect((await payments.unmatched()).single.transactionId, 'A');
  });

  test(
      'legacy lost response can be recovered by attempt ID and definitive unpaid releases the original receiver',
      () async {
    final owner = Object();
    payments.attachLegacy(owner, (r) async {}, (_, __) {}, (_) {});
    store.loseSubmissionReply = true;
    await expectLater(payments.buyLegacy(owner, 'coins', 'ambiguous'),
        throwsA(isA<StoreSubmissionUnresolved>()));
    store.loseSubmissionReply = false;
    final unresolved = (await payments.unresolvedAttempts()).single;
    expect(unresolved.scope, isNull);
    expect(unresolved.submittedToken, 'ambiguous');
    expect(unresolved.phase, 'uncertain');
    await expectLater(payments.buyLegacy(owner, 'coins', 'next'),
        throwsA(isA<StoreSubmissionUnresolved>()));
    await payments.resolveAttempt(recovery(
        unresolved.attemptId, 'ambiguous', AppleAttemptOutcome.pending));
    await expectLater(
        payments.resolveAttempt(recovery(
            unresolved.attemptId, 'ambiguous', AppleAttemptOutcome.unpaid,
            scope: 'B')),
        throwsStateError);
    await payments.resolveAttempt(recovery(
        unresolved.attemptId, 'ambiguous', AppleAttemptOutcome.unpaid));
    expect(await payments.unresolvedAttempts(), isEmpty);
    await expectLater(
        payments.buyLegacy(owner, 'coins', 'ambiguous'), throwsStateError);
    await payments.buyLegacy(owner, 'coins', 'next');
    expect(store.submissions, ['ambiguous', 'next']);
  });

  test(
      'legacy recovery pins account, preserves receipt until authenticated claim then verifies and finishes once',
      () async {
    final owner = Object(), legacy = <String>[], verified = <AppleReceipt>[];
    payments.attachLegacy(owner, (r) async {
      legacy.add(r);
    }, (_, __) {}, (_) {});
    await payments.buyLegacy(owner, 'coins', 'order');
    final unresolved = (await payments.unresolvedAttempts()).single;
    await payments.resolveAttempt(
        recovery(unresolved.attemptId, 'order', AppleAttemptOutcome.pending));
    store.paid('order', 'T');
    await payments.settle();
    expect(legacy, isEmpty);
    expect(store.finished, isEmpty);
    final account = payments.connect(
        scope: 'A',
        verify: (r) async {
          verified.add(r);
          return ack(r);
        });
    await payments.resolveAttempt(recovery(
        unresolved.attemptId, 'order', AppleAttemptOutcome.paid,
        claim: claim('T')));
    await payments.settle();
    expect(verified.single.scope, 'A');
    expect(verified.single.receipt, 'receipt');
    expect((await account.lookup('order'))!.charges.single.disposition,
        'delivered');
    expect(store.finished.single.transactionId, 'T');
    expect(legacy, isEmpty);
    expect(await payments.unresolvedAttempts(), isEmpty);
  });

  test('signed decision for the wrong account cannot close a scoped attempt',
      () async {
    final a = payments.connect(scope: 'A', verify: (r) async => ack(r));
    final order = await a.buy(productId: 'coins', orderId: 'order');
    await expectLater(
        payments.resolveAttempt(recovery(
            order.attemptId!, 'order', AppleAttemptOutcome.unpaid,
            scope: 'B')),
        throwsStateError);
    expect((await a.lookup('order'))!.phase, 'accepted');
    expect((await payments.unresolvedAttempts()).single.scope, 'A');
    await a.buy(productId: 'coins', orderId: 'order');
    expect(store.submissions, hasLength(1));
  });

  test(
      'legacy handoff authorizes only first charge and extra payment requires its own final disposition',
      () async {
    final owner = Object();
    final received = <String>[];
    payments.attachLegacy(owner, (r) async {
      received.add(r);
    }, (_, __) {}, (_) {});
    await payments.buyLegacy(owner, 'coins', 'order');
    store.paid('order', 'first');
    store.paid('order', 'second');
    await payments.settle();
    expect(received, ['receipt']);
    expect(store.finished.map((e) => e.transactionId), ['first']);
    final seen = <AppleReceipt>[];
    payments.connect(
        scope: 'A',
        verify: (r) async {
          seen.add(r);
          return ack(r, outcome: AppleOutcome.refunded);
        });
    await payments.reconcile(claim('second'));
    await payments.settle();
    expect(seen.single.additionalCharge, true);
    expect(store.finished.map((e) => e.transactionId), ['first', 'second']);
  });

  for (final detach in [true, false]) {
    test(
        'same queue gains its order token during legacy handoff (detached: $detach)',
        () async {
      final owner = Object(),
          entered = Completer<void>(),
          release = Completer<void>();
      final receipts = <String>[];
      payments.attachLegacy(owner, (receipt) {
        receipts.add(receipt);
        if (!entered.isCompleted) entered.complete();
        return release.future;
      }, (_, __) {}, (_) {});
      await payments.buyLegacy(owner, 'coins', 'O');
      store.updates.add([
        const StoreEvent(
            productId: 'coins',
            status: StoreStatus.pending,
            queueId: 'Q',
            native: 'original',
            token: 'O'),
      ]);
      store.paid(null, 'T', queue: 'Q', handle: 'original');
      try {
        await entered.future.timeout(const Duration(seconds: 4));
        if (detach) payments.detachLegacy(owner);
        store.paid('O', 'T', queue: 'Q', handle: 'original');
        // Wait for the StoreKit update to commit while the receiver is still suspended.
        await Stream.periodic(const Duration(milliseconds: 10))
            .asyncMap((_) => journal.read((db) => db.query('purchase',
                columns: ['token'], where: 'reportedId=?', whereArgs: ['T'])))
            .firstWhere((rows) => rows.single['token'] == 'O')
            .timeout(const Duration(seconds: 4));
        expect(store.finished, isEmpty);
      } finally {
        release.complete();
      }
      await payments.settle().timeout(const Duration(seconds: 4));
      expect(receipts, ['receipt']);
      expect(store.finished.map((e) => (e.queueId, e.transactionId, e.native)),
          [('Q', 'T', 'original')]);
    });
  }

  for (final lateFailure in [false, true]) {
    test(
        'detached handoff cannot override trusted settlement (late failure: $lateFailure)',
        () async {
      final entered = Completer<void>(), release = Completer<void>();
      final owner = Object();
      payments.attachLegacy(owner, (_) {
        entered.complete();
        return release.future;
      }, (_, __) {}, (_) {});
      final verified = <String>[], errors = <Object>[];
      final subscription = payments.errors.listen(errors.add);
      addTearDown(subscription.cancel);
      final account = payments.connect(
          scope: 'A',
          verify: (r) async {
            verified.add(r.transactionId);
            return ack(r);
          });
      const disposition = AppleDisposition(
          appId: 'app',
          environment: 'sandbox',
          scope: 'A',
          orderId: 'order',
          productId: 'coins',
          reportedTransactionId: 'T',
          verifiedTransactionId: 'T',
          reference: 'already-refunded',
          outcome: AppleOutcome.refunded);
      final recovery = claim('T', disposition: disposition);
      try {
        await payments.buyLegacy(owner, 'coins', 'order');
        store.paid('order', 'T', handle: 'original');
        await entered.future.timeout(const Duration(seconds: 4));
        // An attached receiver keeps its exclusive handoff while the callback is running.
        await expectLater(payments.reconcile(recovery), throwsStateError);
        payments.detachLegacy(owner);
        await payments.reconcile(recovery).timeout(const Duration(seconds: 4));
        await payments.settle().timeout(const Duration(seconds: 4));
        expect(store.finished.map((e) => e.native), ['original']);
        expect((await account.lookup('order'))!.charges.single.reference,
            'already-refunded');
      } finally {
        if (lateFailure) {
          release.completeError(StateError('expired page'));
        } else {
          release.complete();
        }
      }
      await payments.settle();
      expect((await account.lookup('order'))!.charges.single.disposition,
          'refunded');
      expect(await journal.read((db) => db.query('legacy_handoff')), isEmpty);
      expect(verified, isEmpty);
      expect(errors, isEmpty);
      expect(store.finished.map((e) => e.native), ['original']);
    });
  }

  test(
      'unpaid fact commits before exact native cleanup, including failed finish and restart',
      () async {
    final a = payments.connect(scope: 'A', verify: (r) async => ack(r));
    final bought = await a.buy(productId: 'coins', orderId: 'order');
    final token = store.submissions.single;
    String? observed;
    store.beforeFinish = (e) async {
      observed = (await a.lookup('order'))?.phase;
      throw StateError('lost reply');
    };
    store.updates.add([
      StoreEvent(
          productId: 'coins',
          status: StoreStatus.canceled,
          token: token,
          native: 'old-object')
    ]);
    await payments.settle();
    expect(observed, 'canceled');
    await restart();
    final recovered = payments.connect(scope: 'A', verify: (r) async => ack(r));
    expect((await recovered.lookup('order'))!.phase, 'canceled');
    final replacement =
        await recovered.buy(productId: 'coins', orderId: 'order');
    expect(replacement.attemptId, isNot(bought.attemptId));
    store.updates.add([
      StoreEvent(
          productId: 'coins',
          status: StoreStatus.failed,
          token: token,
          native: 'different-object')
    ]);
    await payments.settle();
    expect(store.finished.single.native, 'different-object');
    expect((await recovered.lookup('order'))!.phase, 'accepted');
  });

  test(
      'paid attempt decisions are durable, idempotent and cannot be reversed by an unpaid decision',
      () async {
    final a = payments.connect(scope: 'A', verify: (r) async => ack(r));
    final bought = await a.buy(productId: 'coins', orderId: 'order');
    AppleAttemptDecision decision(String id, AppleAttemptOutcome outcome) =>
        AppleAttemptDecision(
            issuer: 'server',
            decisionId: id,
            appId: 'app',
            environment: 'sandbox',
            attemptId: bought.attemptId!,
            scope: 'A',
            orderId: 'order',
            reference: 'record-$id',
            outcome: outcome,
            claim: outcome == AppleAttemptOutcome.paid ? claim('T') : null);
    await payments.resolveAttempt(decision('p', AppleAttemptOutcome.pending));
    await payments.resolveAttempt(decision('1', AppleAttemptOutcome.paid));
    await payments.resolveAttempt(decision('1', AppleAttemptOutcome.paid));
    expect((await a.lookup('order'))!.phase, 'paid');
    await expectLater(
        payments.resolveAttempt(decision('2', AppleAttemptOutcome.unpaid)),
        throwsStateError);
    expect((await a.lookup('order'))!.phase, 'conflict');
    expect((await a.lookup('order'))!.charges, hasLength(1));
    await a.buy(productId: 'coins', orderId: 'order');
    expect(store.submissions, hasLength(1));
    expect(store.finished, isEmpty);
  });
}
