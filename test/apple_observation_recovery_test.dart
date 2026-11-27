import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';

import 'apple_payments_test.dart' show ProbeStore, delivered;

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
      {String? wire,
      String reported = 'R',
      String receipt = 'shared',
      bool allowsUnownedFinish = true}) async {
    store.stream.add([
      StoreEvent(
          productId: 'sku',
          token: wire,
          native: handle,
          transactionId: reported,
          queueId: reported,
          receipt: receipt,
          allowsUnownedFinish: allowsUnownedFinish,
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

  void removed(String handle) {
    store.stream.add([
      StoreEvent(
          productId: 'sku',
          native: handle,
          transactionId: 'R',
          queueId: 'R',
          status: StoreStatus.paid,
          removed: true,
          needsFinish: false)
    ]);
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

  AppleVerifiedQueueTransaction verifiedItem(String observation,
          {String transaction = 'R',
          String owner = 'A',
          String environment = 'sandbox',
          String receipt = 'shared',
          int quantity = 1,
          String? reference}) =>
      AppleVerifiedQueueTransaction(
          observationId: observation,
          receiptHash: sha256.convert(utf8.encode(receipt)).toString(),
          transactionId: transaction,
          appId: 'app',
          environment: environment,
          productId: 'sku',
          scope: owner,
          orderId: 'order',
          quantity: quantity,
          reference: reference ?? 'verified-$observation');
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
        await journal.read(
            (db) => db.query('purchase', where: 'blockedLogin IS NOT NULL')),
        isEmpty);
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
    expect(waiting.state, AppleObservationState.sourceUnproven);
    final payment = (await account.lookup('order'))!;
    expect(payment.phase, 'paid');
    expect(payment.charges.single.disposition, isNull);
    expect(payment.charges.single.attemptId, isNull);
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
        throwsA(isA<AppleObservationRejected>()));
    expect((await account.lookup('order'))!.charges.single.disposition,
        'delivered');
    expect(store.finished, isEmpty);
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
      'a local verifier merges a device transaction into a server-only payment',
      () async {
    account = pay.connect(
        scope: 'A', verify: (r) async => delivered(r, verified: 'V'));
    final launch = await account.buy(
        productId: 'sku', orderId: 'order', purchaseToken: token);
    await pay.recordPayment(claim(null, terminal: false));
    store.event(token, 'R');
    await pay.settle();
    final paid = (await account.lookup('order'))!.charges.single;
    expect(paid.verifiedTransactionId, 'V');
    expect(paid.transactionId, 'R');
    expect(paid.attemptId, launch.attemptId);
    expect(paid.disposition, 'delivered');
    expect(paid.finishPending, isFalse);
    expect(store.finished, hasLength(1));
  });

  test('old original-only claims are imported before replay can finish',
      () async {
    await journal.write((db) async {
      await db.update('meta', {'originalPaymentsRestored': 0});
      await db.insert('recovery.original_submission', {
        'appId': 'app',
        'token': token,
        'issuer': 'server',
        'reference': 'old-original',
        'environment': 'sandbox',
        'scope': 'B',
        'orderId': 'order',
        'productId': 'sku',
        'verifiedId': 'R',
        'reportedId': 'R',
      });
    });
    await close();
    await start();
    final current = await observe('fresh');
    await expectLater(
        pay.recoverObservation(claim(current, verified: 'R'),
            verifiedQueueTransaction: verifiedItem(current)),
        throwsStateError);
    await pay.settle();
    expect((await account.lookup('order'))!.phase, 'conflict');
    expect(store.finished, isEmpty);
    await close();
    await start();
    expect((await account.lookup('order'))!.phase, 'conflict');
  });

  test('authenticated payment survives restart without a device observation',
      () async {
    await pay.recordPayment(claim(null, terminal: false));
    await pay.recordPayment(claim(null, terminal: false));
    await pay.refreshReceipts();
    await close();
    await start();
    final status = await account.buy(productId: 'sku', orderId: 'order');
    expect(status.phase, 'paid');
    expect(status.attemptId, isNull);
    expect(status.charges.single.verifiedTransactionId, 'V');
    expect(status.charges.single.transactionId, isNull);
    expect(store.submitted, isEmpty);
    final pending = (await pay.unmatched()).single;
    expect(pending.verifiedTransactionId, 'V');
    expect(pending.observations, isEmpty);
    expect(pending.receipts, isEmpty);
    await pay.recordPayment(claim(null));
    await pay.recordPayment(claim(null));
    expect((await account.lookup('order'))!.charges.single.reference, 'ack');
    final other = pay.connect(
        scope: 'B', verify: (_) async => const AppleVerification.retryLater());
    expect(await other.lookup('order'), isNull);
    await other.buy(productId: 'sku', orderId: 'order');
    expect(store.submitted, hasLength(1));
    expect(store.finished, isEmpty);
  });

  test('authenticated submission decision can precede exact replay proof',
      () async {
    final launch = await account.buy(
        productId: 'sku', orderId: 'order', purchaseToken: token);
    await close();
    await start();
    await observe('old');
    await close();
    await start();
    final current = await observe('current');
    await pay.recordPayment(claim(null, verified: 'R'));
    final before = (await account.lookup('order'))!;
    expect(before.phase, 'paid');
    expect(before.attemptPhase, 'accepted');
    expect(before.charges.single.attemptId, isNull);
    final decision = AppleAttemptDecision(
        issuer: 'backend',
        decisionId: 'link',
        appId: 'app',
        environment: 'sandbox',
        attemptId: launch.attemptId!,
        scope: 'A',
        orderId: 'order',
        reference: 'verified-link',
        outcome: AppleAttemptOutcome.paid,
        attemptProof: 'original-submission',
        claim: claim(null, verified: 'R'));
    await pay.resolveAttempt(decision);
    await pay.resolveAttempt(decision);
    await pay.settle();
    final after = (await account.lookup('order'))!;
    expect(after.attemptPhase, 'paid');
    expect(after.charges.single.attemptId, launch.attemptId);
    expect(after.charges.single.transactionId, isNull);
    expect(store.finished, isEmpty);
    expect(
        (await pay.unmatched())
            .any((t) => t.currentObservationIds.contains(current)),
        isTrue);
    await pay.recoverObservation(claim(current, verified: 'R'),
        verifiedQueueTransaction: verifiedItem(current));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['current']);
    expect((await account.lookup('order'))!.charges.single.attemptId,
        launch.attemptId);
  });

  test(
      'legacy reconcile can book the one matching report without authorizing its object',
      () async {
    final id = await observe('single-unowned');
    await pay.reconcile(claim(null, verified: 'R'));
    await pay.retryPending();
    await pay.settle();
    final payment = (await account.lookup('order'))!.charges.single;
    expect(payment.verifiedTransactionId, 'R');
    expect(payment.transactionId, isNull);
    expect(payment.reference, 'ack');
    expect(payment.attemptId, isNull);
    expect((await pay.unmatched()).single.currentObservationIds, {id});
    expect(store.finished, isEmpty);
    expect(verifications, 0);
    await pay.recoverObservation(claim(id, verified: 'R', terminal: false),
        verifiedQueueTransaction: verifiedItem(id));
    await pay.settle();
    expect(store.finished.map((event) => event.native), ['single-unowned']);
    expect((await account.lookup('order'))!.charges.single.reference, 'ack');
    expect(verifications, 0);
  });

  test('a stale selector preserves money and cannot authorize a live handle',
      () async {
    await observe('unrelated', reported: 'different');
    await expectLater(pay.recoverObservation(claim('missing')),
        throwsA(isA<AppleObservationRejected>()));
    final charge = (await account.lookup('order'))!.charges.single;
    expect(charge.verifiedTransactionId, 'V');
    expect(charge.disposition, 'delivered');
    expect(charge.transactionId, isNull);
    await pay.retryPending();
    await pay.settle();
    expect(store.finished, isEmpty);
  });

  test('conflicting authenticated ownership survives rejected object proof',
      () async {
    final live = await observe('current', wire: 'order');
    await pay.recordPayment(claim(null, verified: 'R', terminal: false));
    await expectLater(
        pay.recoverObservation(claim(live, owner: 'B', verified: 'R'),
            verifiedQueueTransaction: verifiedItem(live, owner: 'B')),
        throwsStateError);
    await expectLater(
        pay.recoverObservation(claim(live, verified: 'R'),
            verifiedQueueTransaction: verifiedItem(live)),
        throwsStateError);
    await pay.retryPending();
    await pay.settle();
    expect((await account.lookup('order'))!.phase, 'conflict');
    expect((await pay.unmatched()).any((t) => t.disputeId != null), isTrue);
    expect(store.finished, isEmpty);
  });

  Future<String> submitLegacyOrder() async {
    final owner = Object();
    pay.attachLegacy(owner, (_) async {}, (_, __) {}, (_) {});
    await pay.buyLegacy(owner, 'sku', 'order');
    pay.detachLegacy(owner);
    return journal.read((db) async =>
        (await db.query('attempt', columns: ['id'])).single['id'] as String);
  }

  for (final change in ['new reservation', 'attempt conflict']) {
    test('pending exact finish is revoked after $change', () async {
      final attempt = await submitLegacyOrder();
      await close();
      await start();
      final id = await observe('pending-finish', wire: 'order');
      store.failFinish = true;
      await pay.recoverObservation(claim(id, verified: 'R'),
          verifiedQueueTransaction: verifiedItem(id));
      await pay.settle();
      expect(store.finished, isEmpty);
      await journal.write((db) async {
        if (change == 'attempt conflict') {
          expect(
              await db.update('attempt', {'phase': 'conflict'},
                  where: "id=? AND phase='accepted'", whereArgs: [attempt]),
              1);
        } else {
          await db.insert('recovery.submission', {
            'token': 'order',
            'origin': 'production',
            'attemptId': 'competing',
          });
        }
      });
      store.failFinish = false;
      await pay.retryPending();
      await pay.settle();
      expect(store.finished, isEmpty);
    });
  }

  for (final owner in ['A', 'B']) {
    test('accepted order with pending server decision for $owner', () async {
      final attempt = await submitLegacyOrder();
      await pay.resolveAttempt(AppleAttemptDecision(
          issuer: 'backend',
          decisionId: 'pending',
          attemptId: attempt,
          appId: 'app',
          environment: 'sandbox',
          scope: owner,
          orderId: 'order',
          reference: 'pending-from-server',
          outcome: AppleAttemptOutcome.pending));
      await close();
      await start();
      final id = await observe('replayed');
      final other = await observe('other-payment', reported: 'R2');
      final proof = verifiedItem(id);
      await expectLater(
          pay.recoverObservation(claim(other, report: 'R2', verified: 'R2'),
              verifiedQueueTransaction: proof),
          throwsStateError);
      final recovery = pay.recoverObservation(claim(id, verified: 'R'),
          verifiedQueueTransaction: proof);
      if (owner == 'A') {
        await recovery;
      } else {
        await expectLater(recovery, throwsStateError);
      }
      await pay.settle();
      expect(store.finished.map((e) => e.native),
          owner == 'A' ? ['replayed'] : isEmpty);
      expect((await pay.unmatched()).expand((t) => t.observations.keys),
          contains(other));
    });
  }

  test(
      'legacy proof preserves the scoped purchase already bound to this transaction',
      () async {
    final legacy = await submitLegacyOrder();
    final active = await account.buy(
        productId: 'sku', orderId: 'order', purchaseToken: token);
    store.event(token, 'R');
    await pay.settle();
    store.failFinish = true;
    await pay.reconcile(claim(null, wire: token, verified: 'R'));
    await pay.settle();
    await journal.read((db) async {
      final charge = (await db.query('purchase')).single;
      expect(charge['attemptId'], active.attemptId);
      expect(charge['disposition'], 'delivered');
    });
    await close();
    await start();
    final id = await observe('replay-without-token');
    await pay.recoverObservation(claim(id, verified: 'R'),
        verifiedQueueTransaction: verifiedItem(id));
    await pay.settle();
    await journal.read((db) async {
      final charge = (await db.query('purchase')).single;
      expect(charge['attemptId'], active.attemptId);
      expect(charge['conflict'], 0);
      expect(charge['disposition'], 'delivered');
      expect(await db.query('conflict_fact'), isEmpty);
      expect(
          (await db.query('recovery.verified_queue_transaction'))
              .single['observation'],
          id);
    });
    expect(
        store.finished.map((event) => event.native), ['replay-without-token']);
    expect((await pay.unresolvedAttempts()).single.attemptId, legacy);
  });

  for (final competing in [false, true]) {
    test(
        'a charge in a partition without the original attempt (competing=$competing)',
        () async {
      await close();
      store = ProbeStore();
      journal = AppleJournal(() async => File('${dir.path}/ledger'));
      pay = ApplePayments.forTesting(store, journal);
      await submitLegacyOrder();
      await close();
      await start('production');
      final candidate = competing ? 'order' : 'unrelated';
      final prodId =
          await observe('prod-event', wire: candidate, reported: 'P');
      await pay.reconcile(claim(prodId,
          env: 'production',
          owner: 'B',
          report: 'P',
          verified: 'P',
          reference: 'ack-prod'));
      await pay.settle();
      // A v6 reconciliation could have retained the reported business string
      // even without an attempt in this partition. Preserve its conflict guard.
      await journal.write((db) async {
        expect(await db.query('attempt'), isEmpty);
        expect((await db.query('purchase')).single['token'], isNull);
        await db.update('purchase', {'token': candidate},
            where: 'verifiedId=?', whereArgs: ['P']);
      });
      await close();
      await start('sandbox');
      final s = await observe('sandbox-event', wire: 'order', reported: 'R');
      final result = pay.recoverObservation(claim(s, verified: 'R'),
          verifiedQueueTransaction: verifiedItem(s));
      if (competing) {
        await expectLater(result, throwsStateError);
      } else {
        await result;
      }
      await pay.settle();
      expect(store.finished.map((e) => e.native),
          competing ? isEmpty : ['sandbox-event']);
    });
  }

  for (final conflict in [
    'environment',
    'product',
    'uncertain',
    'declined',
    'missing attempt',
    'multiple'
  ]) {
    test('registered legacy recovery rejects $conflict conflict atomically',
        () async {
      if (conflict == 'environment') {
        await close();
        await start('production');
      }
      if (conflict == 'uncertain') {
        store.launch = () async => throw StateError('unknown launch result');
      } else if (conflict == 'declined') {
        store.launch = () async => false;
      }
      final owner = Object();
      pay.attachLegacy(owner, (_) async {}, (_, __) {}, (_) {});
      final launch = pay.buyLegacy(
          owner, conflict == 'product' ? 'other-sku' : 'sku', 'order');
      if (conflict == 'uncertain') {
        await expectLater(launch, throwsA(isA<StoreSubmissionUnresolved>()));
      } else if (conflict == 'declined') {
        await expectLater(launch, throwsA(isA<StorePurchaseRejected>()));
      } else {
        await launch;
      }
      pay.detachLegacy(owner);
      if (conflict == 'missing attempt') {
        await journal.write((db) => db.delete('attempt'));
      }
      if (conflict == 'multiple') {
        await journal.write((db) => db.insert('recovery.submission', {
              'token': 'order',
              'origin': 'legacy',
              'attemptId': 'other-attempt',
            }));
      }
      await close();
      await start();
      final id = await observe('conflicting-replay', wire: 'order');
      await expectLater(
          pay.recoverObservation(claim(id, verified: 'R'),
              verifiedQueueTransaction: verifiedItem(id)),
          throwsStateError);
      await pay.settle();
      expect(store.finished, isEmpty);
      await journal.read((db) async {
        expect(await db.query('recovery.verified_queue_transaction'), isEmpty);
        expect(await db.query('disposition_fact'), hasLength(1));
        final observation = (await db
                .query('recovery.observation', where: 'id=?', whereArgs: [id]))
            .single;
        expect(observation['boundPurchase'], isNull);
      });
    });
  }

  for (final mode in ['managed', 'compatibility', 'handoff']) {
    for (final pending in [false, true]) {
      test(
          'BuyEngine accepted order survives two replays '
          '(mode=$mode, pending=$pending)', () async {
        if (mode != 'managed') {
          await close();
          store = ProbeStore();
          journal = AppleJournal(() async => File('${dir.path}/ledger'));
          pay = ApplePayments.forTesting(store, journal);
        }
        var checkoutFinished = Completer<void>();
        PayKit.initialize(DefaultPayConfig(
          showLoadingHandler: () {},
          dismissLoadingHandler: () => checkoutFinished.complete(),
          showToastHandler: (_,
              {bool isTip = false, bool lengthLong = false}) {},
          logHandler: (_, __) {},
        ));
        addTearDown(() => PayKit.initialize(DefaultPayConfig()));
        final engine = BuyEngine(payments: pay);
        engine.initialize((_) => fail('abandoned receiver called'));
        engine.buyProduct('sku', 'order');
        // The void compatibility API completes through its UI callback.
        await checkoutFinished.future;
        await pay.settle();
        expect(store.submitted, ['order']);
        if (pending) {
          store.event('order', null, status: StoreStatus.pending);
          await pay.settle();
        }
        final attemptId = await journal
            .read((db) async => (await db.query('attempt')).single['id']);
        if (mode == 'handoff') {
          await pay.start(environment: 'sandbox');
          expect(
              await journal
                  .read((db) async => (await db.query('attempt')).single['id']),
              attemptId);
        }
        // Apple does not guarantee a non-UUID business order will be echoed.
        final wire = pending ? 'order' : null;
        engine.dispose();
        await close();
        await start();
        await observe('first-restart', wire: wire);
        await close();
        await start();
        final id = await observe('second-restart', wire: wire);
        store.failFinish = true;
        await pay.recoverObservation(claim(id, verified: 'R'),
            verifiedQueueTransaction: verifiedItem(id));
        await pay.settle();
        expect(store.finished, isEmpty);
        await close();
        await start();
        final replay = await observe('finish-retry', wire: wire);
        // Match the SK1 bridge: a product in the queue rejects a new purchase
        // until StoreKit confirms removal of the outstanding item.
        final accepted = <String>[];
        store.launch = () async {
          if (store.finished.every((item) => item.native != 'finish-retry')) {
            throw const StorePurchaseRejected();
          }
          accepted.add(store.submitted.last);
          return true;
        };
        final next = BuyEngine(payments: pay)..initialize((_) {});
        addTearDown(next.dispose);
        checkoutFinished = Completer<void>();
        next.buyProduct('sku', 'blocked-order');
        await checkoutFinished.future;
        expect(store.submitted, ['blocked-order']);
        expect(accepted, isEmpty);
        await expectLater(
            pay.recoverObservation(claim(replay, verified: 'R'),
                verifiedQueueTransaction: verifiedItem(id)),
            throwsStateError);
        await pay.recoverObservation(
            claim(replay, verified: 'R', terminal: false),
            verifiedQueueTransaction: verifiedItem(replay));
        await pay.settle();
        expect(store.finished.map((e) => e.native), ['finish-retry']);
        await journal.read((db) async {
          final purchase = (await db.query('purchase')).single;
          expect(purchase['attemptId'], isNull);
          expect(purchase['disposition'], 'delivered');
          final attempts =
              await db.query('attempt', where: 'id=?', whereArgs: [attemptId]);
          if (mode == 'compatibility') {
            expect(attempts, isEmpty);
          } else {
            expect(attempts.single['phase'], pending ? 'pending' : 'accepted');
          }
        });
        checkoutFinished = Completer<void>();
        next.buyProduct('sku', 'next-order');
        await checkoutFinished.future;
        await pay.settle();
        expect(accepted, ['next-order']);
      });
    }
  }

  test(
      'a repeated report on a replacement object cannot inherit the original callback',
      () async {
    final page = Object();
    var received = 0;
    pay.attachLegacy(page, (_) async {
      received++;
    }, (_, __) {}, (_) {});
    await pay.buyLegacy(page, 'sku', 'order');
    store.failFinish = true;
    store.event('order', 'R', handle: 'original');
    await pay.settle();
    expect(received, 1);
    store.event('order', 'R', handle: 'replacement');
    await pay.settle();
    store.failFinish = false;
    await pay.retryPending();
    await pay.settle();
    expect(store.finished, isEmpty);
    expect(received, 1);
  });

  test(
      'a directly observed legacy payment retains its original submission after a cold replay',
      () async {
    final legacy =
        await submitLegacyOrder(); // The receiver has already detached.
    store.event('order', 'R', handle: 'original-object');
    await pay.settle();
    expect(store.finished, isEmpty);
    await close();
    await start();
    final id = await observe('cold-object');
    await pay.recoverObservation(claim(id, verified: 'R', terminal: false),
        verifiedQueueTransaction: verifiedItem(id));
    await pay.settle();
    expect(store.finished, isEmpty);
    expect((await account.lookup('order'))!.charges.single.attemptId, legacy);
    await pay.recordPayment(claim(null, verified: 'R'));
    await pay.settle();
    expect(store.finished.map((event) => event.native), ['cold-object']);
    final settled = (await account.lookup('order'))!.charges.single;
    expect(settled.attemptId, legacy);
    expect(settled.finishPending, isFalse);
  });

  for (final (recorded, managed) in [
    (true, false),
    (false, false),
    (true, true)
  ]) {
    test(
        'exact recovery checks the original handoff (recorded=$recorded, managed=$managed)',
        () async {
      await close();
      store = ProbeStore();
      journal = AppleJournal(() async => File('${dir.path}/ledger'));
      pay = ApplePayments.forTesting(store, journal);
      if (managed) await pay.start(environment: 'sandbox');
      final page = Object();
      var handoffs = 0;
      pay.attachLegacy(page, (_) async {
        handoffs++;
      }, (_, __) {}, (_) {});
      await pay.buyLegacy(page, 'sku', 'order');
      store.failFinish = true;
      store.event('order', 'R');
      await pay.settle();
      expect(handoffs, 1);
      final attempt = await journal.read((db) async {
        final p = (await db.query('purchase')).single;
        expect(p['disposition'], 'legacyHandedOff');
        return p['attemptId'];
      });
      expect(store.finished, isEmpty);
      if (!recorded) {
        await journal.write((db) => db.delete('legacy_handoff'));
      }
      await close();
      await start();
      await observe('first-replay');
      await close();
      await start();
      final current = await observe('current');
      final proof = verifiedItem(current);
      if (!recorded) {
        await expectLater(
            pay.recoverObservation(claim(current, verified: 'R'),
                verifiedQueueTransaction: proof),
            throwsStateError);
        await pay.settle();
        expect(store.finished, isEmpty);
        expect(
            (await account.lookup('order'))!.charges.single.attemptId, isNull);
        return;
      }
      final waiting = await pay.recoverObservation(
          claim(current, verified: 'R', terminal: false),
          verifiedQueueTransaction: proof);
      expect(waiting.state, AppleObservationState.awaitingDisposition);
      expect(waiting.disposition, isNull);
      await pay.settle();
      expect(store.finished, isEmpty);
      await pay.recoverObservation(claim(current, verified: 'R'),
          verifiedQueueTransaction: proof);
      await pay.settle();
      expect(store.finished.map((e) => e.native), ['current']);
      await journal.read((db) async {
        final p = (await db.query('purchase')).single;
        expect(p['attemptId'], attempt);
        expect(p['disposition'], 'delivered');
      });
    });
  }

  test(
      'two accepted submissions for one order cannot identify a tokenless payment',
      () async {
    final legacy = await submitLegacyOrder();
    final scoped = await account.buy(
        productId: 'sku', orderId: 'order', purchaseToken: token);
    await close();
    await start();
    await observe('first-replay');
    await close();
    await start();
    final current = await observe('current');
    await pay.recoverObservation(claim(current, verified: 'R'),
        verifiedQueueTransaction: verifiedItem(current));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['current']);
    await journal.read((db) async {
      final p = (await db.query('purchase')).single;
      expect(p['attemptId'], isNull);
      expect(p['disposition'], 'delivered');
      final attempts = await db.query('attempt');
      expect(attempts.map((a) => a['id']),
          unorderedEquals([legacy, scoped.attemptId]));
      expect(attempts.map((a) => a['phase']), everyElement('accepted'));
    });
  });

  test('legacy replay finishes only the verified item on a shared app receipt',
      () async {
    final prior = await observe('previous-run', wire: 'order');
    await close();
    // An unrelated, interrupted first installation may leave an empty partition.
    await File('${dir.path}/ledger.compat').create();
    await start();
    final current = await observe('current', wire: 'order');
    final other = await observe('other', wire: 'another-order', reported: 'R2');
    final proof = verifiedItem(current);
    final currentClaim = claim(current, verified: 'R');
    await expectLater(
        pay.reconcile(currentClaim), throwsA(isA<AppleAmbiguousObservation>()));
    expect((await pay.recoverObservation(currentClaim)).state,
        AppleObservationState.sourceUnproven);

    await expectLater(
        pay.recoverObservation(claim(other, report: 'R2', verified: 'R2'),
            verifiedQueueTransaction: proof),
        throwsStateError);
    await expectLater(
        pay.recoverObservation(claim(other, report: 'R2', verified: 'R2'),
            verifiedQueueTransaction: verifiedItem(other, transaction: 'R2')),
        throwsStateError);
    await expectLater(
        pay.recoverObservation(currentClaim,
            verifiedQueueTransaction: verifiedItem(prior)),
        throwsStateError);
    await pay.recoverObservation(currentClaim, verifiedQueueTransaction: proof);
    await pay.settle();
    expect(
        (await pay.recoverObservation(currentClaim,
                verifiedQueueTransaction: proof))
            .state,
        AppleObservationState.removed);
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['current']);
    final charges = (await account.lookup('order'))!.charges;
    expect(charges.map((c) => c.verifiedTransactionId),
        unorderedEquals(['R', 'R2']));
    expect(
        charges
            .singleWhere((c) => c.verifiedTransactionId == 'R')
            .finishPending,
        isFalse);
    expect(
        charges
            .singleWhere((c) => c.verifiedTransactionId == 'R2')
            .transactionId,
        isNull);
    expect(verifications, 0);
  });

  test('restart reuses delivery but requires fresh proof for the replay',
      () async {
    final old = await observe('old', wire: 'order');
    final oldProof = verifiedItem(old);
    store.failFinish = true;
    await pay.recoverObservation(claim(old, verified: 'R'),
        verifiedQueueTransaction: oldProof);
    await pay.settle();
    expect(store.finished, isEmpty);
    await close();
    await start();
    final replay = await observe('replay', wire: 'order');
    final existing = claim(replay, verified: 'R', terminal: false);
    expect((await pay.recoverObservation(existing)).state,
        AppleObservationState.sourceUnproven);
    await expectLater(
        pay.recoverObservation(existing, verifiedQueueTransaction: oldProof),
        throwsStateError);
    await expectLater(
        pay.recoverObservation(existing,
            verifiedQueueTransaction:
                verifiedItem(replay, reference: oldProof.reference)),
        throwsStateError);
    await pay.retryPending();
    await pay.settle();
    expect(store.finished, isEmpty);
    await pay.recoverObservation(existing,
        verifiedQueueTransaction: verifiedItem(replay));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['replay']);
    expect((await account.lookup('order'))!.charges.single.reference, 'ack');
    expect(
        await journal.read((db) => db.query('disposition_fact')), hasLength(1));
    expect(verifications, 0);
  });

  test(
      'invalid queue proof cannot attach an authenticated payment to an observation',
      () async {
    final excluded = await observe('outside-catalog',
        reported: 'off-catalog', allowsUnownedFinish: false);
    await expectLater(
        pay.recoverObservation(
            claim(excluded, report: 'off-catalog', verified: 'off-catalog'),
            verifiedQueueTransaction:
                verifiedItem(excluded, transaction: 'off-catalog')),
        throwsStateError);
    final id = await observe('candidate');
    final matching = claim(id, verified: 'R');
    for (final proof in [
      verifiedItem(id, environment: 'production'),
      verifiedItem(id, owner: 'B'),
      verifiedItem(id, receipt: 'unrelated receipt'),
      verifiedItem(id, transaction: 'other transaction'),
      verifiedItem(id, quantity: 2),
    ]) {
      await expectLater(
          pay.recoverObservation(matching, verifiedQueueTransaction: proof),
          throwsStateError);
    }
    await expectLater(
        pay.recoverObservation(claim(id),
            verifiedQueueTransaction: verifiedItem(id)),
        throwsStateError);
    final duplicate = await observe('different-current-handle');
    expect(duplicate, isNot(id));
    await expectLater(
        pay.recoverObservation(matching,
            verifiedQueueTransaction: verifiedItem(duplicate)),
        throwsStateError);
    await pay.settle();
    expect(store.finished, isEmpty);
    final charges = (await account.lookup('order'))!.charges;
    expect(charges.map((c) => c.verifiedTransactionId),
        unorderedEquals(['off-catalog', 'R', 'V']));
    expect(charges.every((c) => c.attemptId == null && c.transactionId == null),
        isTrue);
    expect(await journal.read((db) => db.query('queue_item')), isEmpty);
    expect(await journal.read((db) => db.query('recovery.observation_review')),
        isEmpty);
  });

  test('opposing authenticated proofs revoke only the selected handle',
      () async {
    final current = await observe('challenged');
    final proof = verifiedItem(current);
    await pay.recoverObservation(claim(current, verified: 'R', terminal: false),
        verifiedQueueTransaction: proof);
    await expectLater(
        pay.recoverObservation(claim(current, owner: 'B', verified: 'R'),
            verifiedQueueTransaction: verifiedItem(current, owner: 'B')),
        throwsStateError);
    await journal.read((db) async {
      final h = (await db.query('recovery.observation',
              where: 'id=?', whereArgs: [current]))
          .single;
      expect(h['reason'], 'queueProofConflict');
      expect(
          (await db.query('recovery.verified_queue_transaction'))
              .single['scope'],
          'A');
      expect((await db.query('purchase')).single['conflict'], 1);
    });
    await pay.retryPending();
    await pay.settle();
    expect(store.finished, isEmpty);
  });

  for (final foreignFirst in [false, true]) {
    test(
        'opposing environments hold one current object (foreign first: $foreignFirst)',
        () async {
      final id = await observe('challenged');
      final local = claim(id, verified: 'R', terminal: false);
      final foreign = claim(id, verified: 'R', env: 'production');
      final foreignProof = verifiedItem(id,
          environment: 'production', reference: 'production-proof');
      if (foreignFirst) {
        final held = await pay.recoverObservation(foreign,
            verifiedQueueTransaction: foreignProof);
        expect(held.reason, 'verifiedOutsideActiveEnvironment');
        expect(await account.lookup('order'), isNull);
        await observe('alias');
        await expectLater(
            pay.recoverObservation(local,
                verifiedQueueTransaction: verifiedItem(id)),
            throwsA(isA<AppleObservationRejected>()));
      } else {
        await pay.recoverObservation(local,
            verifiedQueueTransaction: verifiedItem(id));
        await observe('alias');
        await expectLater(
            pay.recoverObservation(foreign,
                verifiedQueueTransaction: foreignProof),
            throwsA(isA<AppleObservationRejected>()));
      }
      removed('alias');
      await pay.settle();
      await pay.recordPayment(claim(null, verified: 'R'));
      await pay.retryPending();
      await pay.settle();
      expect(store.finished, isEmpty);
      final charge = (await account.lookup('order'))!.charges.single;
      expect(charge.disposition, 'delivered');
      final held = await journal.read((db) async =>
          (await db.query('recovery.verified_queue_transaction')).single);
      final opposing = jsonDecode(held['opposingProof'] as String) as Map;
      expect({held['environment'], opposing['environment']},
          {'sandbox', 'production'});
      expect(
          await journal.read((db) async => (await db.query(
                  'recovery.observation',
                  where: 'id=?',
                  whereArgs: [id]))
              .single['reason']),
          'queueProofConflict');
      removed('challenged');
      await pay.settle();
      final fresh = await observe('separate');
      await pay.recoverObservation(claim(fresh, verified: 'R'),
          verifiedQueueTransaction: verifiedItem(fresh));
      await pay.settle();
      expect(store.finished.map((e) => e.native), ['separate']);
      await close();
      await start('production');
      expect(await account.lookup('order'), isNull);
      await pay.recordPayment(foreign);
      expect((await account.lookup('order'))!.charges.single.disposition,
          'delivered');
      final prod = await observe('production-object');
      await pay.recoverObservation(
          claim(prod, verified: 'R', env: 'production'),
          verifiedQueueTransaction:
              verifiedItem(prod, environment: 'production'));
      await pay.settle();
      expect(store.finished.map((e) => e.native), ['production-object']);
    });
  }

  test('unmatched foreign proof leaves the current source usable', () async {
    final id = await observe('eligible');
    final local = claim(id, verified: 'R', terminal: false);
    await pay.recoverObservation(local,
        verifiedQueueTransaction: verifiedItem(id));
    final foreign = claim(id, verified: 'R', env: 'production');
    for (final wrong in [
      verifiedItem(id, environment: 'sandbox'),
      verifiedItem(id, environment: 'production', receipt: 'other bytes'),
      verifiedItem(id, environment: 'production', transaction: 'different'),
      verifiedItem('stale', environment: 'production'),
      verifiedItem(id, environment: 'production', quantity: 2),
    ]) {
      await expectLater(
          pay.recoverObservation(foreign, verifiedQueueTransaction: wrong),
          throwsA(isA<AppleObservationRejected>()));
    }
    await expectLater(pay.recordPayment(foreign), throwsStateError);
    await pay.recordPayment(claim(null, verified: 'R'));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['eligible']);
  });

  for (final duplicateFirst in [false, true]) {
    test(
        'removal resumes the verified object (duplicate first: $duplicateFirst)',
        () async {
      final first = await observe('first');
      if (duplicateFirst) await observe('duplicate');
      await pay.recoverObservation(claim(first, verified: 'R', terminal: false),
          verifiedQueueTransaction: verifiedItem(first));
      await pay.settle();
      if (!duplicateFirst) await observe('duplicate');
      await pay.recordPayment(claim(null, verified: 'R'));
      await pay.settle();
      expect(store.finished, isEmpty);

      removed('duplicate');
      await pay.settle();
      expect(store.finished.map((e) => e.native), ['first']);
    });
  }

  test('conflicting queue evidence blocks retry of an authorized finish',
      () async {
    final id = await observe('authorized', wire: 'order');
    final c = claim(id, verified: 'R');
    final proof = verifiedItem(id);
    store.failFinish = true;
    await pay.recoverObservation(c, verifiedQueueTransaction: proof);
    await pay.settle();
    expect(store.finished, isEmpty);

    store.failFinish = false;
    store.stream.add([
      const StoreEvent(
          productId: 'sku',
          native: 'failed-object',
          transactionId: 'R',
          queueId: 'R',
          token: 'order',
          status: StoreStatus.failed),
    ]);
    await pay.settle();
    await expectLater(
        pay.recoverObservation(c, verifiedQueueTransaction: proof),
        throwsStateError);
    await pay.retryPending();
    await pay.settle();
    expect(store.finished.map((e) => e.native), isNot(contains('authorized')));
    expect(
        (await account.lookup('order'))!.charges.single.finishPending, isTrue);
  });

  test('original submission finishes its own handle when a queue ID is shared',
      () async {
    final pending = await observe('pending-handle');
    store.failFinish = true;
    await pay.recoverObservation(claim(pending, verified: 'R'),
        verifiedQueueTransaction: verifiedItem(pending));
    await pay.settle();
    expect(store.finished, isEmpty);
    await observe('pending-handle');
    final other = await observe('original-handle', wire: token);
    store.failFinish = false;
    await pay.recoverObservation(claim(other, wire: token, verified: 'R'),
        originalSubmission: original(verified: 'R'));
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['original-handle']);
    final observations = await journal.read(
        (db) => db.query('recovery.observation', columns: ['id', 'finished']));
    expect({for (final row in observations) row['id']: row['finished']},
        {pending: 0, other: 1});
    expect(
        (await account.lookup('order'))!.charges.single.finishPending, isTrue);
  });

  test('refresh makes an empty receipt available for the current replay',
      () async {
    final old = await observe('old', receipt: '');
    await close();
    await start();
    final live = await observe('live', receipt: '');
    final rows = await pay.unmatched();
    expect(rows.expand((r) => r.currentObservationIds), [live]);
    final proof = verifiedItem(live, receipt: 'fresh');
    final current = claim(live, verified: 'R');
    await expectLater(
        pay.recoverObservation(current, verifiedQueueTransaction: proof),
        throwsStateError);
    await pay.refreshReceipts();
    await pay.settle();
    final refreshed = (await pay.unmatched())
        .singleWhere((r) => r.currentObservationIds.contains(live));
    expect(refreshed.observations[live], contains('fresh'));
    await expectLater(
        pay.recoverObservation(claim(old, verified: 'R'),
            verifiedQueueTransaction: verifiedItem(old, receipt: 'fresh')),
        throwsStateError);
    await pay.recoverObservation(current, verifiedQueueTransaction: proof);
    await pay.settle();
    expect(store.finished.map((e) => e.native), ['live']);
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
      'an unsuccessful review and a legacy claim cannot authorize a lone device report',
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
    await pay.retryPending();
    await pay.settle();
    final charge = (await account.lookup('order'))!.charges.single;
    expect(charge.verifiedTransactionId, 'V');
    expect(charge.disposition, 'delivered');
    expect(charge.transactionId, isNull);
    expect(store.finished, isEmpty);
    expect((await pay.unmatched()).single.currentObservationIds, {id});
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
