import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

void main() {
  late Directory dir;
  late ApplePayments payments;
  late ProbeStore store;
  late List<AppleReceipt> verified;

  Future<void> boot() async {
    store = ProbeStore();
    payments = ApplePayments.forTesting(
        store, AppleJournal(() async => File('${dir.path}/ledger')));
    await payments.start(environment: 'sandbox');
  }

  Future<void> stop() async {
    await payments.close();
    await store.stream.close();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('iap-review');
    verified = [];
    await boot();
  });
  tearDown(() async {
    await stop();
    await dir.delete(recursive: true);
  });

  AppleAccount login(String scope) => payments.connect(
      scope: scope,
      verify: (r) async {
        verified.add(r);
        return delivered(r);
      });

  AppleClaim claim(String scope,
          {String reference = 'claim',
          AppleDisputeReview? review,
          AppleDisposition? disposition,
          String? observationId,
          String? token,
          String order = 'O',
          String transactionId = 'T'}) =>
      AppleClaim(
        appId: 'app',
        environment: 'sandbox',
        scope: scope,
        orderId: order,
        productId: 'sku',
        reportedTransactionId: transactionId,
        verifiedTransactionId: transactionId,
        reference: reference,
        review: review,
        observationId: observationId,
        purchaseToken: token,
        disposition: disposition,
      );

  AppleDisposition receipt(String scope, String ref,
          {AppleOutcome outcome = AppleOutcome.delivered,
          String? supersedes}) =>
      AppleDisposition(
        appId: 'app',
        environment: 'sandbox',
        scope: scope,
        orderId: 'O',
        productId: 'sku',
        reportedTransactionId: 'T',
        verifiedTransactionId: 'T',
        reference: ref,
        supersedes: supersedes,
        outcome: outcome,
      );

  Future<AppleClaim> observe() async {
    store.event(null, 'T');
    await payments.settle();
    final orphan = (await payments.unmatched()).single;
    final c = claim('A', observationId: orphan.id);
    await payments.reconcile(c);
    await payments.settle();
    return c;
  }

  Future<AppleTransaction> dispute() async =>
      (await payments.unmatched()).singleWhere((o) => o.disputeId != null);

  AppleDisputeReview review(AppleTransaction d,
          {String decision = 'review',
          List<String> covers = const [],
          AppleDisposition? finalAck}) =>
      AppleDisputeReview(
          issuer: 'review-service',
          decisionId: decision,
          disputeId: d.disputeId!,
          revision: d.disputeRevision!,
          reference: 'account-and-charge-evidence',
          coveredReceipts: covers,
          finalDisposition: finalAck);

  for (final conflictFirst in [true, false]) {
    test(
        'retains the finish history when conflict arrives ${conflictFirst ? 'before' : 'after'} authorization',
        () async {
      await observe();
      final verified = Completer<AppleReceipt>();
      final deliver = Completer<void>();
      final finishRequested = Completer<void>();
      final nativeResponse = Completer<void>();
      store.afterFinish = () async {
        finishRequested.complete();
        await nativeResponse.future;
      };
      final account = payments.connect(
          scope: 'A',
          verify: (receipt) async {
            verified.complete(receipt);
            await deliver.future;
            return delivered(receipt);
          });
      final receipt = await verified.future;
      expect(receipt.transactionId, 'T');
      if (!conflictFirst) {
        deliver.complete();
        await finishRequested.future;
      }
      try {
        await expectLater(payments.reconcile(claim('B')), throwsStateError);
      } finally {
        if (!deliver.isCompleted) deliver.complete();
        nativeResponse.complete();
      }
      await payments.settle();
      await payments.retryPending();
      await payments.settle();
      final charge = (await account.lookup('O'))!.charges.single;
      expect(charge.conflict, true);
      expect(charge.finishPending, conflictFirst);
      expect(store.finished.map((e) => e.transactionId),
          conflictFirst ? isEmpty : ['T']);
    });
  }

  test(
      'moving the primary charge revalidates the remaining charge in the same login',
      () async {
    for (final tx in ['T', 'T2']) {
      store.event(null, tx);
      await payments.settle();
      await payments.reconcile(claim('A', transactionId: tx));
    }
    final flags = <bool>[];
    final a = payments.connect(
        scope: 'A',
        verify: (r) async {
          if (r.transactionId == 'T2') {
            flags.add(r.additionalCharge);
            if (!r.additionalCharge) return delivered(r);
          }
          return const AppleVerification.needsReconciliation();
        });
    await payments.settle();
    expect(flags, [true]);
    await expectLater(payments.reconcile(claim('B')), throwsStateError);
    final ruling = claim('B', review: review(await dispute()));
    await payments.reconcile(ruling);
    await payments.settle();
    await payments.reconcile(ruling);
    await payments.settle();
    expect(flags, [true, false]);
    expect((await a.lookup('O'))!.charges.single.reference, 'ack-T2');
    expect(store.finished.map((e) => e.transactionId), ['T2']);
  });

  test('ownership correction survives restart, stale rulings and replay',
      () async {
    final first = await observe();
    await expectLater(payments.reconcile(claim('B')), throwsStateError);
    final d1 = await dispute();
    await payments.reconcile(first);
    expect((await dispute()).disputeRevision, d1.disputeRevision);
    await expectLater(payments.reconcile(claim('C')), throwsStateError);
    final d2 = await dispute();
    expect(d2.disputeRevision, greaterThan(d1.disputeRevision!));
    await expectLater(
        payments.reconcile(claim('B', review: review(d1))), throwsStateError);
    final ruling = claim('B', review: review(d2));
    await payments.reconcile(ruling);
    final b = login('B');
    await payments.settle();
    expect(verified.single.scope, 'B');
    expect((await b.lookup('O'))!.attemptId, isNull);
    expect(store.finished.map((e) => e.transactionId), ['T']);
    await stop();
    await boot();
    await payments.reconcile(first);
    await payments.reconcile(claim('C'));
    await payments.reconcile(ruling);
    final restored = await login('B').buy(productId: 'sku', orderId: 'O');
    expect(restored.charges.single.reference, 'ack-T');
    expect(await login('A').lookup('O'), isNull);
    expect(store.submitted, isEmpty);
    expect(store.finished, isEmpty);
    await expectLater(payments.reconcile(claim('D')), throwsStateError);
    expect((await dispute()).disputeRevision, greaterThan(d2.disputeRevision!));
  });

  test('correcting an already fulfilled owner requires covered compensation',
      () async {
    await observe();
    login('A');
    await payments.settle();
    expect(verified, hasLength(1));
    await expectLater(payments.reconcile(claim('B')), throwsStateError);
    final d = await dispute();
    expect(d.receiptReferences, ['ack-T']);
    await expectLater(
        payments.reconcile(claim('B', review: review(d))), throwsStateError);
    final refund = receipt('B', 'compensation', outcome: AppleOutcome.refunded);
    await expectLater(
        payments.reconcile(claim('B', review: review(d, finalAck: refund))),
        throwsStateError);
    final ruling =
        claim('B', review: review(d, covers: ['ack-T'], finalAck: refund));
    await payments.reconcile(ruling);
    final b = login('B');
    await payments.settle();
    expect((await b.lookup('O'))!.charges.single.disposition, 'refunded');
    expect(verified, hasLength(1));
    await payments.reconcile(claim('A', disposition: receipt('A', 'ack-T')));
    expect(await payments.unmatched(), isEmpty);
    expect((await b.lookup('O'))!.charges.single.disposition, 'refunded');
    await expectLater(
        payments.reconcile(claim('A', review: review(d))), throwsStateError);
    expect((await dispute()).reason, 'reviewDecisionConflict');
    expect(store.finished, hasLength(1));
  });

  for (final refundFirst in [true, false]) {
    test(
        'explicit refund chain converges when refund arrives first = $refundFirst',
        () async {
      await observe();
      final sale = claim('A', disposition: receipt('A', 'sale'));
      final refund = claim('A',
          disposition: receipt('A', 'refund',
              outcome: AppleOutcome.refunded, supersedes: 'sale'));
      if (refundFirst) {
        await expectLater(payments.reconcile(refund), throwsStateError);
        expect((await dispute()).reason, 'missingPredecessor');
        expect(store.finished, isEmpty);
        await payments.reconcile(sale);
      } else {
        await payments.reconcile(sale);
        await payments.reconcile(refund);
      }
      await payments.reconcile(refund);
      await payments.reconcile(sale);
      final a = login('A');
      await payments.settle();
      final charge = (await a.lookup('O'))!.charges.single;
      expect(charge.disposition, 'refunded');
      expect(charge.reference, 'refund');
      expect(charge.conflict, isFalse);
      expect(store.finished, hasLength(1));
      expect(verified, isEmpty);
    });
  }

  test('unrelated refunds freeze the known delivery until explicit review',
      () async {
    await observe();
    final sale = receipt('A', 'sale');
    final refund = receipt('A', 'refund', outcome: AppleOutcome.refunded);
    await payments.reconcile(claim('A', disposition: sale));
    await expectLater(
        payments.reconcile(claim('A', disposition: refund)), throwsStateError);
    final d = await dispute();
    expect(d.receiptReferences.toSet(), {'sale', 'refund'});
    final a = login('A');
    expect((await a.lookup('O'))!.charges.single.reference, 'sale');
    await payments.reconcile(claim('A',
        review: review(d, covers: d.receiptReferences, finalAck: refund)));
    expect((await a.lookup('O'))!.charges.single.reference, 'refund');
    await payments.reconcile(claim('A', disposition: sale));
    expect((await a.lookup('O'))!.charges.single.reference, 'refund');
    expect(verified, isEmpty);
  });

  test('corrected ownership detaches the real attempt across native replay',
      () async {
    final a = login('A');
    final submitted = (await a.buy(productId: 'sku', orderId: 'O')).attemptId!;
    a.dispose();
    store.event(submitted, 'T');
    await payments.settle();
    await payments.reconcile(claim('A', token: submitted));
    await expectLater(payments.reconcile(claim('B')), throwsStateError);
    final d = await dispute();
    await payments.reconcile(claim('B', review: review(d)));
    store.event(submitted, 'T');
    final b = login('B');
    await payments.settle();
    final corrected = (await b.lookup('O'))!;
    expect(corrected.attemptId, isNull);
    expect(corrected.charges.single.reference, 'ack-T');
    expect(verified.map((r) => r.scope), ['B']);
    expect((await payments.unresolvedAttempts()).single.attemptId, submitted);
    await payments.resolveAttempt(AppleAttemptDecision(
        issuer: 'orders',
        decisionId: 'original',
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        attemptId: submitted,
        reference: 'server-closed-original-order',
        outcome: AppleAttemptOutcome.unpaid));
    expect(await payments.unresolvedAttempts(), isEmpty);
    expect((await login('A').lookup('O'))!.phase, 'declined');
    expect(store.finished, hasLength(1));
  });

  test(
      'signed preregistered legacy UUID identifies a true submission without echoing the local id',
      () async {
    const wire = '8c5019c2-2c04-45d9-8e49-9e4c18849727';
    final owner = Object();
    payments.attachLegacy(owner, (r) async {
      fail('Unexpected legacy handoff');
    }, (_, __) {}, (_) {});
    await payments.buyLegacy(owner, 'sku', wire);
    final a = (await payments.unresolvedAttempts()).single;
    expect(a.attemptId, isNot(wire));
    store.event(null, 'T');
    await payments.settle();
    final observation = (await payments.unmatched()).single;
    final c =
        claim('A', order: wire, observationId: observation.id, token: wire);
    await payments.resolveAttempt(AppleAttemptDecision(
        issuer: 'orders',
        decisionId: 'wire-proof',
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: wire,
        attemptId: a.attemptId,
        reference: 'signed-apple-order-link',
        claim: c,
        outcome: AppleAttemptOutcome.paid));
    login('A');
    await payments.settle();
    expect(verified.single.attemptId, a.attemptId);
    expect(verified.single.purchaseToken, wire);
    expect(store.finished, hasLength(1));
    await payments.buyLegacy(owner, 'other', 'next');
    expect(store.submitted, [wire, 'next']);
  });

  for (final decisionFirst in [true, false]) {
    test(
        'lost legacy business string links only against independent proof, decisionFirst=$decisionFirst',
        () async {
      final owner = Object();
      final handedOff = <String>[];
      payments.attachLegacy(owner, (r) async {
        handedOff.add(r);
      }, (_, __) {}, (_) {});
      await payments.buyLegacy(owner, 'sku', 'O');
      final attempt = (await payments.unresolvedAttempts()).single;
      store.event(null, 'T');
      await payments.settle();
      final orphan = (await payments.unmatched()).single;
      final c = claim('A', observationId: orphan.id);
      AppleAttemptDecision decision(String? proof, {String env = 'sandbox'}) =>
          AppleAttemptDecision(
              issuer: 'orders',
              decisionId: 'paid',
              appId: 'app',
              environment: env,
              attemptId: attempt.attemptId,
              attemptProof: proof,
              scope: 'A',
              orderId: 'O',
              reference: 'order-record',
              outcome: AppleAttemptOutcome.paid,
              claim: c);
      await expectLater(
          payments.resolveAttempt(decision(null)), throwsStateError);
      await expectLater(
          payments.resolveAttempt(decision('server-proof', env: 'production')),
          throwsStateError);
      final a = login('A');
      if (!decisionFirst) {
        await payments.reconcile(c);
        await payments.settle();
        expect((await a.lookup('O'))!.attemptId, isNull);
        await expectLater(
            payments.buyLegacy(owner, 'other', 'next'), throwsA(anything));
      }
      await payments.resolveAttempt(decision('server-proof'));
      await payments.reconcile(c);
      await payments.resolveAttempt(decision('server-proof'));
      await payments.settle();
      final paid = (await a.lookup('O'))!;
      expect(paid.attemptId, attempt.attemptId);
      expect(paid.charges.single.disposition, 'delivered');
      expect(verified, hasLength(1));
      expect(handedOff, isEmpty);
      expect(store.finished, hasLength(1));
      await payments.buyLegacy(owner, 'other', 'next');
      expect(store.submitted, ['O', 'next']);
    });
  }
  test(
      'attempt decision during dispute must not silently lose independent linkage',
      () async {
    final owner = Object();
    payments.attachLegacy(owner, (r) async {
      fail('unexpected old handoff');
    }, (_, __) {}, (_) {});
    await payments.buyLegacy(owner, 'sku', 'O');
    final old = (await payments.unresolvedAttempts()).single;
    final a = await observe();
    await expectLater(payments.reconcile(claim('B')), throwsStateError);
    final d = await dispute();
    final paid = AppleAttemptDecision(
        issuer: 'orders',
        decisionId: 'real-attempt',
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        attemptId: old.attemptId,
        attemptProof: 'signed-order-link',
        reference: 'real-submission',
        outcome: AppleAttemptOutcome.paid,
        claim: a);
    await expectLater(payments.resolveAttempt(paid), throwsStateError);
    await payments.reconcile(claim('A', review: review(d)));
    await payments.resolveAttempt(paid);
    final account = login('A');
    await payments.settle();
    expect((await account.lookup('O'))!.attemptId, old.attemptId);
    await payments.buyLegacy(owner, 'other', 'next');
    expect(store.submitted, ['O', 'next']);
  });

  test('two reported aliases reviewed as one payment settle both queue objects',
      () async {
    AppleClaim alias(String scope, String reported,
            {AppleDisputeReview? ruling}) =>
        AppleClaim(
            appId: 'app',
            environment: 'sandbox',
            scope: scope,
            orderId: 'O',
            productId: 'sku',
            reportedTransactionId: reported,
            verifiedTransactionId: 'V',
            reference: 'claim-$scope-$reported',
            review: ruling);
    store.event(null, 'T1');
    await payments.settle();
    await payments.reconcile(alias('A', 'T1'));
    store.event(null, 'T2');
    await payments.settle();
    await expectLater(payments.reconcile(alias('B', 'T2')), throwsStateError);
    final d = await dispute();
    await payments.reconcile(alias('B', 'T2', ruling: review(d)));
    final b = payments.connect(
        scope: 'B',
        verify: (r) async {
          verified.add(r);
          return delivered(r, verified: 'V');
        });
    await payments.settle();
    expect(verified, hasLength(1));
    expect(store.finished.map((e) => e.transactionId).toSet(), {'T1', 'T2'});
    expect((await b.lookup('O'))!.charges.single.finishPending, isFalse);
    expect(await payments.unmatched(), isEmpty);
  });
  test('a review cannot combine aliases bearing incompatible purchase UUIDs',
      () async {
    const original = 'f6af789c-7abd-4ae2-ac21-e612080a24c1';
    const different = '54794acf-9e4e-420a-9e9b-6460ef8be341';
    AppleClaim alias(String scope, String reported,
            {AppleDisputeReview? ruling}) =>
        AppleClaim(
            appId: 'app',
            environment: 'sandbox',
            scope: scope,
            orderId: 'O',
            productId: 'sku',
            reportedTransactionId: reported,
            verifiedTransactionId: 'V',
            reference: 'server-$reported',
            review: ruling);
    store.event(original, 'T1');
    await payments.settle();
    await payments.reconcile(alias('A', 'T1'));
    store.event(different, 'T2');
    await payments.settle();
    await expectLater(payments.reconcile(alias('B', 'T2')), throwsStateError);
    final d = await dispute();
    await expectLater(payments.reconcile(alias('B', 'T2', ruling: review(d))),
        throwsStateError);
    login('B');
    await payments.settle();
    expect((await dispute()).disputeRevision, d.disputeRevision);
    expect(store.finished, isEmpty);
    expect(verified, isEmpty);
  });

  test(
      'contradictory verified identities in a late receipt require adjudication',
      () async {
    store.failFinish = true;
    final waiting = Completer<AppleReceipt>(),
        old = Completer<AppleVerification>();
    final a = payments.connect(
        scope: 'A',
        verify: (r) {
          waiting.complete(r);
          return old.future;
        });
    final attempt = (await a.buy(productId: 'sku', orderId: 'O')).attemptId!;
    store.event(attempt, 'T');
    final r = await waiting.future;
    final current = payments.connect(
        scope: 'A', verify: (r) async => delivered(r, verified: 'T'));
    await payments.settle();
    old.complete(AppleVerification.delivered(AppleDisposition(
        appId: 'app',
        environment: 'sandbox',
        scope: 'A',
        orderId: 'O',
        productId: 'sku',
        reportedTransactionId: r.transactionId,
        verifiedTransactionId: 'other',
        reference: 'other-sale')));
    await payments.settle();
    final d = await dispute();
    expect(d.receiptReferences.toSet(), {'ack-T', 'other-sale'});
    store.failFinish = false;
    await payments.reconcile(claim('A', token: attempt));
    await payments.settle();
    expect((await current.lookup('O'))!.charges.single.conflict, isTrue);
    expect(store.finished, isEmpty);
    await expectLater(
        payments.reconcile(claim('A', review: review(d))), throwsStateError);
    await payments.reconcile(claim('A',
        review: review(d,
            covers: d.receiptReferences, finalAck: receipt('A', 'corrected'))));
    await payments.settle();
    expect((await current.lookup('O'))!.charges.single.reference, 'corrected');
    expect(store.finished.map((e) => e.transactionId), ['T']);
  });
}
