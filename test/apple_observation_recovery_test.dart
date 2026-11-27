import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

import 'apple_payments_test.dart' show ProbeStore;

void main() {
  const token = '254adff7-e1d1-452d-89fa-4a3872371a68';
  late Directory dir;
  late ProbeStore store;
  late ApplePayments pay;
  late AppleJournal journal;
  late AppleAccount account;
  var verifications = 0;
  Future<void> start([String env = 'sandbox']) async {
    store = ProbeStore();
    journal = AppleJournal(() async => File('${dir.path}/ledger'));
    pay = ApplePayments.forTesting(store, journal);
    await pay.start(environment: env);
    account = pay.connect(
        scope: 'A',
        verify: (_) async {
          verifications++;
          return const AppleVerification.retryLater();
        });
  }

  Future<void> close() async {
    await pay.close();
    await store.stream.close();
  }

  Future<String> observe(String handle,
      {String? wire, String reported = 'R'}) async {
    store.stream.add([
      StoreEvent(
          productId: 'sku',
          token: wire,
          native: handle,
          transactionId: reported,
          queueId: reported,
          receipt: 'shared',
          status: StoreStatus.paid)
    ]);
    await pay.settle();
    return journal.read((db) async => (await db.query('recovery.observation',
            columns: ['id'],
            where: 'objectKey=?',
            whereArgs: ['handle:$handle'],
            orderBy: 'rowid DESC'))
        .first['id'] as String);
  }

  AppleClaim claim(String? id,
          {String? wire,
          bool terminal = true,
          AppleDisputeReview? review,
          String owner = 'A',
          String report = 'R',
          String verified = 'V',
          String env = 'sandbox',
          String reference = 'ack'}) =>
      AppleClaim(
          appId: 'app',
          environment: env,
          scope: owner,
          orderId: 'order',
          productId: 'sku',
          reportedTransactionId: report,
          verifiedTransactionId: verified,
          reference: 'claim-$owner-$verified',
          purchaseToken: wire,
          observationId: id,
          review: review,
          disposition: terminal
              ? AppleDisposition(
                  appId: 'app',
                  environment: env,
                  scope: owner,
                  orderId: 'order',
                  productId: 'sku',
                  reportedTransactionId: report,
                  verifiedTransactionId: verified,
                  reference: reference,
                  outcome: AppleOutcome.delivered)
              : null);
  AppleOriginalSubmission original(
          {String wire = token,
          String report = 'R',
          String verified = 'V',
          String env = 'sandbox',
          int quantity = 1}) =>
      AppleOriginalSubmission(
          issuer: 'backend',
          reference: 'original',
          appId: 'app',
          environment: env,
          scope: 'A',
          orderId: 'order',
          productId: 'sku',
          quantity: quantity,
          purchaseToken: wire,
          reportedTransactionId: report,
          verifiedTransactionId: verified);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('apple-observation');
    verifications = 0;
    await start();
  });
  tearDown(() async {
    await close();
    await dir.delete(recursive: true);
  });

  test(
      'a disputed source retires the verifier and stays quarantined after restart',
      () async {
    const otherToken = '254adff7-e1d1-452d-89fa-4a3872371a69';
    final first = await observe('first', wire: token);
    final other = await observe('second', wire: otherToken, reported: 'R2');
    final entered = Completer<void>();
    final reply = Completer<AppleVerification>();
    pay.connect(
        scope: 'A',
        verify: (_) {
          verifications++;
          entered.complete();
          return reply.future;
        });
    await pay.recoverObservation(claim(first, wire: token, terminal: false),
        originalSubmission: original());
    await entered.future;
    await pay.recoverObservation(
        claim(other,
            wire: otherToken, report: 'R2', verified: 'V2', terminal: false),
        originalSubmission:
            original(wire: otherToken, report: 'R2', verified: 'V2'));
    reply.complete(const AppleVerification.needsReconciliation());
    await pay.settle();
    expect(
        (await journal.read((db) => db.query('purchase')))
            .single['blockedLogin'],
        isNull);
    await close();
    await start();
    await pay.refreshReceipts();
    await pay.retryPending();
    await pay.settle();
    expect(verifications, 1);
    expect(store.finished, isEmpty);
    final result = await pay.recoverObservation(claim(first, wire: token));
    expect(result.disposition, 'delivered');
    expect(result.state, AppleObservationState.disputed);
    expect(store.finished, isEmpty);
  });

  test(
      'an interrupted recovery rolls back both proof and disposition before a new process retries',
      () async {
    final first = await observe('old-handle', wire: token);
    await journal.write((db) => db.execute('''
      CREATE TEMP TRIGGER interrupt_disposition BEFORE INSERT ON disposition_fact
      BEGIN SELECT RAISE(ABORT, 'interrupt financial commit'); END'''));
    await expectLater(
        pay.recoverObservation(claim(first, wire: token),
            originalSubmission: original()),
        throwsA(isA<DatabaseException>()));
    await pay.settle();
    expect(await account.lookup('order'), isNull);
    expect(store.finished, isEmpty);
    await close();
    await start();
    await journal.read((db) async {
      expect(await db.query('recovery.original_submission'), isEmpty);
      expect(await db.query('recovery.observation_review'), isEmpty);
      expect(await db.query('claim_fact'), isEmpty);
      expect(await db.query('disposition_fact'), isEmpty);
      expect((await db.query('recovery.observation')).single['boundPurchase'],
          isNull);
    });
    final replay = await observe('fresh-handle', wire: token);
    await pay.recoverObservation(claim(replay, wire: token),
        originalSubmission: original());
    await pay.settle();
    expect((await account.lookup('order'))!.charges.single.disposition,
        'delivered');
    expect(store.finished.map((e) => e.native), ['fresh-handle']);
    expect(verifications, 0);
  });

  test(
      'two tokenless observations can record one financial outcome without assigning either queue item',
      () async {
    final first = await observe('first');
    await close();
    await start();
    final second = await observe('second');
    expect(first, isNot(second));
    await expectLater(pay.reconcile(claim(second)),
        throwsA(isA<AppleAmbiguousObservation>()));
    final waiting =
        await pay.recoverObservation(claim(second, terminal: false));
    expect(waiting.reason, 'dispositionOrSourceRequired');
    expect(await account.lookup('order'), isNull);
    for (final id in [first, second, second]) {
      final result = await pay.recoverObservation(claim(id));
      expect(result.state, AppleObservationState.sourceUnproven);
      expect(result.disposition, 'delivered');
      expect(result.observationId, id);
    }
    final charge = (await account.lookup('order'))!.charges.single;
    expect(charge.reference, 'ack');
    expect(charge.finishPending, isTrue);
    await expectLater(
        pay.reconcile(claim(first)), throwsA(isA<AppleAmbiguousObservation>()));
    await pay.refreshReceipts();
    await pay.retryPending();
    await observe('second');
    expect(store.finished, isEmpty);
    expect(store.submitted, isEmpty);
    expect(verifications, 0);
    expect((await pay.unmatched()).expand((t) => t.observations.keys),
        unorderedEquals([first, second]));
    await journal.read((db) async {
      final p = (await db.query('purchase')).single;
      for (final key in ['token', 'attemptId', 'reportedId']) {
        expect(p[key], isNull);
      }
      for (final table in [
        'attempt',
        'purchase_alias',
        'queue_item',
        'purchase_evidence'
      ]) {
        expect(await db.query(table), isEmpty);
      }
    });
  });

  test(
      'the original authenticated purchase authorizes the exact replay and previous observation keeps its own status',
      () async {
    final first = await observe('first', wire: token);
    await expectLater(
        pay.recoverObservation(claim(first, wire: token),
            originalSubmission: original(quantity: 2)),
        throwsStateError);
    final booked = await pay.recoverObservation(claim(first, wire: token));
    expect(booked.state, AppleObservationState.sourceUnproven);
    store.failFinish = true;
    final failed = await pay.recoverObservation(claim(first, wire: token),
        originalSubmission: original());
    expect(failed.state, AppleObservationState.awaitingRemoval);
    await pay.settle();
    expect(store.finished, isEmpty);
    await close();
    await start();
    final replay = await observe('replay', wire: token);
    expect((await pay.recoverObservation(claim(first, wire: token))).state,
        AppleObservationState.awaitingReplay);
    await pay.settle();
    expect(store.finished, isEmpty);
    await pay.recoverObservation(claim(replay, wire: token));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['replay']);
    expect((await pay.recoverObservation(claim(replay, wire: token))).state,
        AppleObservationState.removed);
    expect((await pay.recoverObservation(claim(first, wire: token))).state,
        AppleObservationState.awaitingReplay);
    await pay.settle();
    expect(store.finished, hasLength(1));
    expect(verifications, 0);
  });

  test(
      'a finance-only conflict freezes the verified charge without assigning an item',
      () async {
    final id = await observe('first');
    await pay.recoverObservation(claim(id));
    final disputed =
        await pay.recoverObservation(claim(id, owner: 'B', reference: 'other'));
    expect(disputed.state, AppleObservationState.disputed);
    expect(disputed.scope, 'A');
    expect(store.finished, isEmpty);
  });

  test(
      'a selected synthetic environment fact and same report cannot authorize another live object',
      () async {
    await journal.write((db) => db.insert('recovery.observation', {
          'id': 'proof',
          'generation': 'verified',
          'objectKey': 'proof',
          'productId': 'sku',
          'reportedId': 'R',
          'status': 'paid',
          'actual': 'sandbox',
          'verifiedId': 'V',
          'reason': 'environmentMismatch'
        }));
    for (final selector in ['proof', null]) {
      await expectLater(pay.reconcile(claim(selector)),
          throwsA(isA<AppleAmbiguousObservation>()));
    }
    final live = await observe('same-report');
    for (final id in ['proof', live]) {
      expect((await pay.recoverObservation(claim(id))).state,
          AppleObservationState.sourceUnproven);
    }
    for (final selector in [live, 'proof', null]) {
      await expectLater(pay.reconcile(claim(selector)),
          throwsA(isA<AppleAmbiguousObservation>()));
    }
    await journal.read((db) async {
      expect(await db.query('purchase_alias'), isEmpty);
      expect((await db.query('purchase')).single['reportedId'], isNull);
      expect(await db.query('purchase_evidence'), isEmpty);
    });
    await pay.refreshReceipts();
    await pay.settle();
    expect(store.finished, isEmpty);
    expect(verifications, 0);
  });

  test(
      'an unknown dispute rolls back the observation marker for a legacy single candidate',
      () async {
    final id = await observe('orphan');
    await expectLater(
        pay.recoverObservation(claim(id,
            terminal: false,
            review: const AppleDisputeReview(
                issuer: 'backend',
                reference: 'review',
                decisionId: 'decision',
                disputeId: 'missing',
                revision: 1))),
        throwsStateError);
    await journal.read((db) async {
      expect(await db.query('recovery.observation_review'), isEmpty);
      expect(await db.query('purchase'), isEmpty);
    });
    await pay.reconcile(claim(id));
    await pay.settle();
    expect(store.finished, hasLength(1));
  });

  test(
      'a new independently proven handle sharing an already finished report receives its own confirmation',
      () async {
    final first = await observe('old-handle', wire: token);
    await pay.recoverObservation(claim(first, wire: token),
        originalSubmission: original());
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['old-handle']);
    await close();
    await start();
    final replay = await observe('new-handle', wire: token);
    expect((await pay.recoverObservation(claim(first, wire: token))).state,
        AppleObservationState.removed);
    expect(store.finished, isEmpty);
    expect((await pay.recoverObservation(claim(replay, wire: token))).state,
        AppleObservationState.awaitingRemoval);
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['new-handle']);
    expect((await pay.recoverObservation(claim(replay, wire: token))).state,
        AppleObservationState.removed);
    expect(verifications, 0);
  });

  test(
      'source before disposition imports only the selected evidence for its authenticated account',
      () async {
    final id = await observe('unbound', wire: token);
    final result = await pay.recoverObservation(
        claim(id, wire: token, terminal: false),
        originalSubmission: original());
    expect(result.state, AppleObservationState.awaitingDisposition);
    await pay.settle();
    expect(verifications, 1);
    expect(store.finished, isEmpty);
    await pay.recoverObservation(claim(id, wire: token));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['unbound']);
    expect((await account.lookup('order'))!.charges.single.reference, 'ack');
  });

  for (final differentToken in [false, true]) {
    test(
        'conflicting authenticated original evidence survives restart (different token=$differentToken)',
        () async {
      final first = await observe('first', wire: token);
      store.failFinish = true;
      await pay.recoverObservation(claim(first, wire: token),
          originalSubmission: original());
      await pay.settle();
      expect(store.finished, isEmpty);
      await close();
      await start('production');
      final secondToken =
          differentToken ? 'b48152f2-c98b-491b-86a9-1705222a79fd' : token;
      final second =
          await observe('second', wire: secondToken, reported: 'other');
      final conflict = await pay.recoverObservation(
          claim(second,
              wire: secondToken,
              report: 'other',
              verified: 'other-v',
              env: 'production'),
          originalSubmission: original(
              wire: secondToken,
              report: 'other',
              verified: 'other-v',
              env: 'production'));
      expect(conflict.state, AppleObservationState.disputed);
      expect(conflict.reason, 'originalSubmissionConflict');
      await pay.settle();
      expect(store.finished, isEmpty);
      await close();
      await start();
      final replay = await observe('replay', wire: token);
      final result = await pay.recoverObservation(claim(replay, wire: token),
          originalSubmission: original());
      expect(result.state, AppleObservationState.disputed);
      expect(result.disposition, 'delivered');
      await pay.recoverObservation(claim(first, wire: token));
      await pay.retryPending();
      await pay.settle();
      expect(store.finished, isEmpty);
      expect(verifications, 0);
    });
  }
}
