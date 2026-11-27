import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:sqflite/sqflite.dart';
import 'apple_payments_test.dart' show ProbeStore, delivered;

void main() {
  late Directory temp;
  late ApplePayments pay;
  late ProbeStore store;
  late AppleAccount a;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp();
    store = ProbeStore()..failFinish = true;
    pay = ApplePayments.forTesting(
        store, AppleJournal(() async => File('${temp.path}/ledger')));
    await pay.start(environment: 'sandbox');
  });
  tearDown(() async {
    await pay.close();
    await store.stream.close();
    await temp.delete(recursive: true);
  });
  AppleDisposition ack(String identity, String ref) => AppleDisposition(
      appId: 'app',
      environment: 'sandbox',
      scope: 'A',
      orderId: 'O',
      productId: 'sku',
      reportedTransactionId: 'T',
      verifiedTransactionId: identity,
      reference: ref);
  AppleClaim claim(String identity, String ref,
          {AppleDisputeReview? review,
          AppleDisposition? disposition,
          String? token}) =>
      AppleClaim(
          appId: 'app',
          environment: 'sandbox',
          scope: 'A',
          orderId: 'O',
          productId: 'sku',
          reportedTransactionId: 'T',
          verifiedTransactionId: identity,
          reference: ref,
          purchaseToken: token,
          review: review,
          disposition: disposition);
  Future<void> reopen(String env) async {
    await pay.close();
    await store.stream.close();
    store = ProbeStore()..failFinish = true;
    pay = ApplePayments.forTesting(
        store, AppleJournal(() async => File('${temp.path}/ledger')));
    await pay.start(environment: env);
  }

  Future<String> buy() async {
    final id = (await a.buy(orderId: 'O', productId: 'sku')).attemptId!;
    store.event(id, 'T');
    return id;
  }

  test(
      'contradictory trusted final disposition supplied by reconcile must continue to freeze finish after plain replay',
      () async {
    a = pay.connect(
        scope: 'A', verify: (r) async => delivered(r, verified: 'v1'));
    final token = await buy();
    await pay.settle();
    final correct = claim('v1', 'first-claim', token: token);
    await pay.reconcile(correct);
    await pay.settle();
    await expectLater(
        pay.reconcile(claim('v2', 'second-claim',
            token: token, disposition: ack('v2', 'ack-V2'))),
        throwsStateError);
    final disputed = (await pay.unmatched()).single;
    expect(disputed.disputeId, isNotNull);
    expect(disputed.receiptReferences.toSet(), {'ack-T', 'ack-V2'});
    store.failFinish = false;
    await pay.reconcile(correct);
    await pay.settle();
    expect(store.finished, isEmpty);
    expect((await a.lookup('O'))!.charges.single.conflict, true);
  });
  test(
      'formal review can select authenticated alternate verified identity after late contradictory ACK',
      () async {
    final wait = Completer<void>(), waiting = Completer<AppleVerification>();
    a = pay.connect(
        scope: 'A',
        verify: (r) {
          wait.complete();
          return waiting.future;
        });
    final token = await buy();
    await wait.future;
    a = pay.connect(
        scope: 'A', verify: (r) async => delivered(r, verified: 'v1'));
    await pay.settle();
    waiting.complete(AppleVerification.delivered(ack('v2', 'ack-V2')));
    await pay.settle();
    final d = (await pay.unmatched()).singleWhere((e) => e.disputeId != null);
    final ruling = AppleDisputeReview(
        issuer: 'trusted-adjudicator',
        decisionId: 'correct-second-source',
        disputeId: d.disputeId!,
        revision: d.disputeRevision!,
        reference: 'audited-apple-environment-and-charge',
        coveredReceipts: d.receiptReferences,
        finalDisposition: ack('v2', 'corrected-final'));
    await pay.reconcile(
        claim('v2', 'confirmed-by-review', token: token, review: ruling));
    store.failFinish = false;
    await pay.retryPending();
    await pay.settle();
    expect(store.finished.single.transactionId, 'T');
  });

  for (final collision in ['other charge', 'other queue alias']) {
    test('identity correction preserves an independently recorded $collision',
        () async {
      a = pay.connect(
          scope: 'A',
          verify: (r) async => delivered(r,
              verified:
                  r.transactionId == 'T' || collision == 'other queue alias'
                      ? 'v1'
                      : 'v2'));
      final token = await buy();
      await pay.settle();
      store.event(token, 'other-report', queue: 'other-object');
      await pay.settle();
      await expectLater(
          pay.reconcile(claim('v2', 'alternate',
              token: token, disposition: ack('v2', 'other-receipt'))),
          throwsStateError);
      final disputed =
          (await pay.unmatched()).singleWhere((r) => r.disputeId != null);
      final ruling = AppleDisputeReview(
          issuer: 'orders',
          decisionId: 'ruling',
          disputeId: disputed.disputeId!,
          revision: disputed.disputeRevision!,
          reference: 'correct identity',
          coveredReceipts: disputed.receiptReferences,
          finalDisposition: ack('v2', 'resolution'));
      await expectLater(
          pay.reconcile(claim('v2', 'review', token: token, review: ruling)),
          throwsStateError);
      expect(
          (await pay.unmatched()).any((r) => r.disputeId == disputed.id), true);
      expect(store.finished, isEmpty);
    });
  }

  for (final keepSource in [true, false]) {
    test('environment review and cold recovery, keep source=$keepSource',
        () async {
      await reopen('production');
      final started = Completer<void>(),
          lateReply = Completer<AppleVerification>();
      a = pay.connect(
          scope: 'A',
          verify: (r) {
            started.complete();
            return lateReply.future;
          });
      final token = await buy();
      await started.future;
      final lateFinancial = Completer<AppleVerification>();
      if (!keepSource) {
        final verifying = Completer<void>();
        a = pay.connect(
            scope: 'A',
            verify: (_) {
              verifying.complete();
              return lateFinancial.future;
            });
        await verifying.future;
      }
      AppleDisposition sourceAck(String ref,
              {AppleOutcome outcome = AppleOutcome.delivered,
              String? supersedes}) =>
          AppleDisposition(
              appId: 'app',
              environment: 'production',
              scope: 'A',
              orderId: 'O',
              productId: 'sku',
              reportedTransactionId: 'T',
              verifiedTransactionId: 'T',
              reference: ref,
              outcome: outcome,
              supersedes: supersedes);
      AppleClaim source(
              {AppleDisputeReview? review,
              AppleDisposition? disposition,
              String scope = 'A'}) =>
          AppleClaim(
              appId: 'app',
              environment: 'production',
              scope: scope,
              orderId: 'O',
              productId: 'sku',
              reportedTransactionId: 'T',
              verifiedTransactionId: 'T',
              purchaseToken: token,
              reference: 'production server',
              review: review,
              disposition: disposition);
      await pay.reconcile(source(disposition: sourceAck('credited')));
      lateReply.complete(AppleVerification.environmentMismatch(
          AppleEnvironmentMismatch(
              appId: 'app',
              expectedEnvironment: 'production',
              actualEnvironment: 'sandbox',
              reportedTransactionId: 'T',
              verifiedTransactionId: 'T',
              productId: 'sku',
              issuer: 'verification',
              reference: 'verified sandbox',
              purchaseToken: token)));
      await pay.settle();
      final disputed =
          (await pay.unmatched()).singleWhere((r) => r.disputeId != null);
      final proof = disputed.environmentProofs.entries.single;
      expect(proof.value.actualEnvironment, 'sandbox');
      AppleClaim ruling(AppleDisposition finalAck) => source(
          review: AppleDisputeReview(
              issuer: 'orders',
              decisionId: 'adjudication',
              disputeId: disputed.id,
              revision: disputed.disputeRevision!,
              reference: 'reviewed both Apple identities',
              coveredReceipts: disputed.receiptReferences,
              environmentProofId: keepSource ? null : proof.key,
              finalDisposition: finalAck));
      if (!keepSource) {
        await expectLater(
            pay.reconcile(ruling(sourceAck('credited'))), throwsStateError);
      }
      final decision = ruling(keepSource
          ? sourceAck('credited')
          : sourceAck('compensated', outcome: AppleOutcome.refunded));
      store.failFinish = false;
      await pay.reconcile(decision);
      await pay.reconcile(decision);
      await pay.settle();
      expect((await a.lookup('O'))!.charges.single.conflict, false);
      expect(store.finished.length, keepSource ? 1 : 0);
      if (!keepSource) {
        lateFinancial
            .complete(AppleVerification.delivered(sourceAck('late-grant')));
        await pay.settle();
        final financial =
            (await pay.unmatched()).singleWhere((r) => r.disputeId != null);
        expect(financial.environmentProofs, isEmpty);
        await pay.recordPayment(source(
            review: AppleDisputeReview(
          issuer: 'orders',
          decisionId: 'late-grant-compensation',
          disputeId: financial.id,
          revision: financial.disputeRevision!,
          reference: 'corrected fulfillment',
          coveredReceipts: financial.receiptReferences,
          finalDisposition:
              sourceAck('late-grant-refund', outcome: AppleOutcome.refunded),
        )));
        await pay.settle();
        expect(store.finished, isEmpty);
        expect((await a.lookup('O'))!.charges.single.reason,
            'environmentMismatch');
        final later = source(
            disposition:
                sourceAck('another-refund', outcome: AppleOutcome.refunded));
        await pay.recordPayment(later);
        await pay.recordPayment(later);
        await pay.settle();
        expect((await a.lookup('O'))!.charges.single.reason,
            'environmentMismatch');
        expect(store.finished, isEmpty);

        // A pending financial predecessor temporarily takes over the public reason.
        await pay.recordPayment(source(
            disposition: sourceAck('additional-refund',
                outcome: AppleOutcome.refunded,
                supersedes: 'additional-grant')));
        expect(
            (await a.lookup('O'))!.charges.single.reason, 'missingPredecessor');
        await reopen('production');
        store.failFinish = false;
        store.event(token, 'T', queue: 'source replay');
        await pay
            .recordPayment(source(disposition: sourceAck('additional-grant')));
        a = pay.connect(scope: 'A', verify: (r) async => delivered(r));
        expect((await a.lookup('O'))!.charges.single.reason,
            'environmentMismatch');

        // A later ownership ruling only resolves that new financial dispute.
        await pay.recordPayment(source(scope: 'B'));
        final ownership =
            (await pay.unmatched()).singleWhere((t) => t.disputeId != null);
        await pay.recordPayment(source(
            review: AppleDisputeReview(
                issuer: 'orders',
                decisionId: 'later-owner',
                disputeId: ownership.id,
                revision: ownership.disputeRevision!,
                reference: 'confirmed account A',
                coveredReceipts: ownership.receiptReferences,
                finalDisposition: sourceAck('final-refund',
                    outcome: AppleOutcome.refunded))));
        await expectLater(pay.reconcile(later), throwsStateError);
        await pay.retryPending();
        await pay.settle();
        expect((await a.lookup('O'))!.charges.single.reason,
            'environmentMismatch');
        expect(store.finished, isEmpty);
      }
      await reopen('sandbox');
      store.failFinish = false;
      const destination = 'verified destination';
      store.event(token, 'T', queue: 'destination queue');
      await pay.settle();
      final target = AppleClaim(
          appId: 'app',
          environment: 'sandbox',
          scope: 'B',
          orderId: 'S',
          productId: 'sku',
          reportedTransactionId: 'T',
          verifiedTransactionId: 'T',
          purchaseToken: token,
          reference: destination);
      if (keepSource) {
        await expectLater(pay.reconcile(target), throwsStateError);
        expect(store.finished, isEmpty);
      } else {
        await pay.reconcile(target);
        await pay.settle();
        expect(store.finished, isEmpty);
        final b = pay.connect(scope: 'B', verify: (r) async => delivered(r));
        await pay.settle();
        expect((await b.lookup('S'))!.charges.single.reference, 'ack-T');
        expect(store.finished.single.queueId, 'destination queue');
      }
    });
  }
  test(
      'a later environment fact never revives a proof rejected by an earlier review',
      () async {
    final responses = <Completer<AppleVerification>>[];
    final starts = <Completer<void>>[];
    for (var i = 0; i < 3; i++) {
      final response = Completer<AppleVerification>(),
          started = Completer<void>();
      responses.add(response);
      starts.add(started);
      a = pay.connect(
          scope: 'A',
          verify: (r) {
            started.complete();
            return response.future;
          });
      if (i == 0) await buy();
      await starts[i].future;
    }
    final current = pay.connect(
        scope: 'A', verify: (r) async => delivered(r, verified: 'v1'));
    await pay.settle();
    final token = (await current.lookup('O'))!.attemptId!;
    AppleVerification proof(String ref) =>
        AppleVerification.environmentMismatch(AppleEnvironmentMismatch(
            appId: 'app',
            expectedEnvironment: 'sandbox',
            actualEnvironment: ref == 'new' ? 'xcode' : 'production',
            productId: 'sku',
            verifiedTransactionId: 'v1',
            reportedTransactionId: 'T',
            issuer: 'apple-server',
            reference: ref,
            purchaseToken: token));
    responses[0].complete(proof('old'));
    await pay.settle();
    final first = (await pay.unmatched()).single;
    expect(first.environmentProofs.values.single.reference, 'old');
    await pay.reconcile(claim('v1', 'confirmed source',
        token: token,
        review: AppleDisputeReview(
            issuer: 'finance',
            decisionId: 'set-1',
            disputeId: first.id,
            revision: first.disputeRevision!,
            reference: 'source confirmed',
            coveredReceipts: first.receiptReferences,
            finalDisposition: ack('v1', 'ack-T'))));
    responses[1].complete(proof('new'));
    await pay.settle();
    final next = (await pay.unmatched()).single;
    expect(next.disputeRevision, greaterThan(first.disputeRevision!));
    expect(next.environmentProofs.values.single.reference, 'new');
    responses[2].complete(proof('old'));
    await pay.settle();
    final replay = (await pay.unmatched()).single;
    expect(replay.disputeRevision, next.disputeRevision);
    expect(replay.environmentProofs.keys, next.environmentProofs.keys);
    expect(store.finished, isEmpty);
  });

  test(
      'populated version four identity guard migrates without ordinary writes gaining authority',
      () async {
    a = pay.connect(
        scope: 'A', verify: (r) async => delivered(r, verified: 'v1'));
    final token = await buy();
    await pay.settle();
    await pay.close();
    await store.stream.close();
    final db = await openDatabase('${temp.path}/ledger', singleInstance: false);
    final ddl = (await db.rawQuery(
            "SELECT sql FROM sqlite_master WHERE name='purchase_identity'"))
        .single['sql'] as String;
    // Restore the v4 invariant: even a recorded amendment could not change verifiedId.
    await db.execute('DROP TRIGGER purchase_identity');
    await db.execute(ddl.replaceFirst('WHEN OLD.id',
        'WHEN (OLD.verifiedId IS NOT NULL AND OLD.verifiedId IS NOT NEW.verifiedId) OR OLD.id'));
    final existing = (await db.query('purchase', columns: ['id'])).single['id'];
    await db.insert('conflict_fact', {
      'purchaseId': existing,
      'reason': 'claimMismatch',
      'evidenceRef': jsonEncode(
          ['app', 'sandbox', 'A', 'O', 'sku', 'T', 'v2', 'new identity', token])
    });
    // A v4 replay may already have cleared the public conflict bit.
    await db.rawUpdate('UPDATE purchase SET conflict=0,reason=NULL');
    await db.setVersion(4);
    await db.close();
    store = ProbeStore();
    final journal = AppleJournal(() async => File('${temp.path}/ledger'));
    pay = ApplePayments.forTesting(store, journal);
    await pay.start(environment: 'sandbox');
    await expectLater(
        journal.write((db) => db.rawUpdate(
            "UPDATE purchase SET verifiedId='v2' WHERE verifiedId='v1'")),
        throwsA(isA<DatabaseException>()));
    final oldClaim = claim('v1', 'original claim', token: token);
    await pay.reconcile(oldClaim);
    final historical = (await pay.unmatched()).single;
    expect(historical.disputeId, isNotNull);
    expect(historical.receiptReferences, ['ack-T']);
    expect(store.finished, isEmpty);
    final alternate = claim('v2', 'new identity',
        token: token, disposition: ack('v2', 'second'));
    await expectLater(pay.reconcile(alternate), throwsStateError);
    final dispute = (await pay.unmatched()).single;
    final decision = claim('v2', 'formal finding',
        token: token,
        review: AppleDisputeReview(
            issuer: 'orders',
            decisionId: 'checked',
            disputeId: dispute.id,
            revision: dispute.disputeRevision!,
            reference: 'confirmed T belongs to v2',
            coveredReceipts: dispute.receiptReferences,
            finalDisposition: ack('v2', 'decision receipt')));
    await pay.reconcile(decision);
    await reopen('sandbox');
    await pay.reconcile(decision);
    await pay.reconcile(oldClaim);
    expect(await pay.unmatched(), isEmpty);
    await expectLater(
        pay.reconcile(claim('v3', 'new third identity',
            token: token, disposition: ack('v3', 'third'))),
        throwsStateError);
    expect((await pay.unmatched()).single.disputeRevision,
        greaterThan(dispute.disputeRevision!));
  });
}
