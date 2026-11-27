import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';
import 'package:sqflite/sqflite.dart';
import 'apple_payments_test.dart' show ProbeStore, delivered;

void main() {
  late ProbeStore store;
  late ApplePayments p;
  late Directory dir;
  late AppleAccount a;
  final seen = <AppleReceipt>[];
  AppleAccount connect() => p.connect(
      scope: 'A',
      verify: (r) async {
        seen.add(r);
        return delivered(r);
      });
  void observe(String? token, String handle, String? queue, String? report,
          {String? original}) =>
      store.stream.add([
        StoreEvent(
            productId: 'sku',
            status: StoreStatus.paid,
            token: token,
            native: handle,
            queueId: queue,
            transactionId: report,
            originalTransactionId: original,
            receipt: 'receipt')
      ]);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('independent-pay');
    store = ProbeStore();
    p = ApplePayments.forTesting(
        store, AppleJournal(() async => File('${dir.path}/ledger')));
    await p.start(environment: 'sandbox');
    seen.clear();
    a = connect();
  });
  tearDown(() async {
    await p.close();
    await store.stream.close();
    await dir.delete(recursive: true);
  });
  AppleClaim claim(String id, [String? token, String? canonical]) => AppleClaim(
      appId: 'app',
      environment: 'sandbox',
      scope: 'A',
      orderId: 'O',
      productId: 'sku',
      reportedTransactionId: id,
      verifiedTransactionId: canonical ?? id,
      reference: 'ref-$id',
      purchaseToken: token);
  Future<void> settle() async {
    await p.settle();
    await p.retryPending();
    await p.settle();
  }

  Future<String> buy() async =>
      (await a.buy(productId: 'sku', orderId: 'O')).attemptId!;
  test(
      'late positive resolved and finished must cease being an unresolved attempt',
      () async {
    final u = await buy();
    store.event(u, null, queue: 'cancel', status: StoreStatus.canceled);
    await settle();
    store.event(u, 'paid', queue: 'paid');
    await settle();
    await p.reconcile(claim('paid', u));
    await settle();
    final s = (await a.lookup('O'))!;
    expect(s.charges.single.disposition, 'delivered');
    expect(s.charges.single.finishPending, false);
    expect(
        (await p.unresolvedAttempts()).where((r) => r.attemptId == u), isEmpty);
  });
  test(
      'server decision precedes same native object acquiring a transaction identifier',
      () async {
    final u = await buy();
    void observe(String? id) => store.stream.add([
          StoreEvent(
              productId: 'sku',
              status: StoreStatus.paid,
              token: u,
              native: 'same-native-object',
              transactionId: id,
              queueId: id,
              receipt: id == null ? 'first' : 'new')
        ]);
    observe(null);
    await settle();
    await p.resolveAttempt(AppleAttemptDecision(
        issuer: 'server',
        environment: 'sandbox',
        decisionId: 'd',
        appId: 'app',
        attemptId: u,
        scope: 'A',
        orderId: 'O',
        reference: 'proof',
        outcome: AppleAttemptOutcome.paid,
        claim: claim('T', u)));
    await settle();
    observe('T');
    await settle();
    expect((await a.lookup('O'))!.charges, hasLength(1));
    await p.reconcile(claim('T', u));
    await settle();
    expect(
        (await a.buy(productId: 'sku', orderId: 'O', purchaseToken: u))
            .attemptId,
        u);
    expect(store.submitted, hasLength(1));
    expect(seen.map((r) => r.transactionId), contains('T'));
    expect(store.finished, hasLength(1));
  });
  test(
      'authenticated transaction claim without token can later receive its originally submitted token',
      () async {
    final u = await buy();
    a.dispose();
    store.event(null, 'T');
    await settle();
    await p.reconcile(claim('T'));
    await settle();
    store.event(u, 'T');
    await settle();
    a = connect();
    await settle();
    await p.reconcile(claim('T', u));
    await settle();
    expect(
        (await a.buy(productId: 'sku', orderId: 'O', purchaseToken: u))
            .attemptId,
        u);
    expect(store.submitted, hasLength(1));
    expect(seen.map((r) => r.transactionId), contains('T'));
    expect(store.finished, hasLength(1));
  });

  test(
      'different queue objects can identify one purchase before server adjudication',
      () async {
    final token = await buy();
    a.dispose();
    observe(token, 'original', null, null);
    observe(token, 'restoration', 'restore', 'T', original: 'T');
    observe(token, 'original', 'T', 'T');
    await settle();
    a = connect();
    await settle();
    expect((await a.lookup('O'))!.charges, hasLength(1));
    expect(seen, hasLength(1));
    expect(store.finished, hasLength(2));
  });
  test(
      'adjudicated cancellation retains its history as its physical object gains an id',
      () async {
    final token = await buy();
    a.dispose();
    store.event(token, null, queue: 'cancel', status: StoreStatus.canceled);
    observe(token, 'original', null, null);
    await settle();
    await p.resolveAttempt(AppleAttemptDecision(
        issuer: 'svc',
        environment: 'sandbox',
        decisionId: 'charge',
        appId: 'app',
        attemptId: token,
        scope: 'A',
        orderId: 'O',
        reference: 'proof',
        outcome: AppleAttemptOutcome.paid,
        claim: claim('T', token)));
    observe(token, 'original', 'T', 'T');
    await settle();
    expect(store.finished.where((e) => e.status == StoreStatus.paid), isEmpty);
    await p.reconcile(claim('T', token));
    a = connect();
    await settle();
    expect((await a.lookup('O'))!.phase, 'paid');
    expect(seen, hasLength(1));
    expect(store.finished.where((e) => e.status == StoreStatus.paid),
        hasLength(1));
    await p.close();
    final journal = AppleJournal(() async => File('${dir.path}/ledger'));
    final facts = await journal.read((db) => db.query('conflict_fact'));
    await journal.close();
    expect(facts.where((r) => r['reason'] == 'paymentAfterUnpaid'), isNotEmpty);
    expect(
        facts
            .singleWhere(
                (r) => r['reason'] == 'mergedObservation')['evidenceRef']
            .toString(),
        contains('paymentAfterUnpaid'));
  });
  test('trusted report alias binds recovery to the original submission',
      () async {
    final token = await buy();
    a.dispose();
    observe(null, 'canonical', 'T', 'T');
    await settle();
    await p.reconcile(claim('T'));
    observe(token, 'alias', 'S', 'S');
    await settle();
    await p.reconcile(claim('S', token, 'T'));
    a = p.connect(scope: 'A', verify: (r) async => delivered(r, verified: 'T'));
    await settle();
    expect((await a.lookup('O'))!.charges, hasLength(1));
    expect(
        (await a.buy(productId: 'sku', orderId: 'O', purchaseToken: token))
            .attemptId,
        token);
    expect(store.submitted, hasLength(1));
    expect(store.finished.map((item) => item.native), ['alias']);
  });
  test(
      'the original queue object retains its token when its later callback omits it',
      () async {
    final token = await buy();
    a.dispose();
    observe(token, 'original', null, null);
    observe(null, 'restore', 'restored', 'T', original: 'T');
    await settle();
    await p.reconcile(claim('T'));
    observe(null, 'original', 'T', 'T');
    await settle();
    a = connect();
    await settle();
    expect((await a.lookup('O'))!.attemptId, token);
    expect(seen, hasLength(1));
    expect(store.finished.map((item) => item.native), ['original']);
  });
  test(
      'a provisional object and another wrapper for one stable queue item finish once',
      () async {
    final token = await buy();
    a.dispose();
    observe(token, 'H', null, null);
    observe(token, 'other-wrapper', 'T', 'T');
    observe(token, 'H', 'T', 'T');
    await settle();
    a = connect();
    await settle();
    // A sparse callback from the original object still addresses this item.
    observe(token, 'H', null, null);
    await settle();
    expect((await a.lookup('O'))!.charges, hasLength(1));
    expect((await p.unmatched()), isEmpty);
    expect(seen, hasLength(1));
    expect(store.finished, hasLength(1));
  });
  test('one claim cannot settle another disputed charge on the same attempt',
      () async {
    final u = await buy();
    store.event(u, null, queue: 'cancel', status: StoreStatus.canceled);
    await settle();
    store.event(u, 'first');
    await settle();
    // Independent verified disposition mismatch for a second charge.
    a = p.connect(
        scope: 'A',
        verify: (r) async => r.transactionId == 'second'
            ? AppleVerification.delivered(AppleDisposition(
                appId: 'wrong-app',
                environment: 'sandbox',
                scope: 'A',
                orderId: 'O',
                productId: 'sku',
                reportedTransactionId: r.transactionId,
                verifiedTransactionId: r.transactionId,
                reference: 'bad-ack'))
            : delivered(r));
    store.event(u, 'second');
    await settle();
    await p.reconcile(claim('first', u));
    await settle();
    expect((await a.lookup('O'))!.phase, 'conflict');
    expect(
        store.finished
            .where((e) => e.status == StoreStatus.paid)
            .map((e) => e.transactionId),
        ['first']);
    a = p.connect(scope: 'A', verify: (r) async => delivered(r));
    await p.reconcile(claim('second', u));
    await settle();
    expect((await a.lookup('O'))!.phase, 'paid');
    expect(
        store.finished
            .where((e) => e.status == StoreStatus.paid)
            .map((e) => e.transactionId),
        ['first', 'second']);
  });
  test(
      'same physical handle with a contradictory account token cannot merge charges',
      () async {
    final u = await buy();
    final b = p.connect(
        scope: 'B',
        verify: (r) async {
          seen.add(r);
          return delivered(r);
        });
    final other = (await b.buy(productId: 'sku', orderId: 'O')).attemptId;
    void observe(String token, String? id) => store.stream.add([
          StoreEvent(
              productId: 'sku',
              status: StoreStatus.paid,
              token: token,
              native: 'shared-handle',
              transactionId: id,
              queueId: id,
              receipt: 'evidence')
        ]);
    observe(u, null);
    await settle();
    await p.resolveAttempt(AppleAttemptDecision(
        issuer: 'server',
        environment: 'sandbox',
        decisionId: 'p',
        appId: 'app',
        attemptId: u,
        scope: 'A',
        orderId: 'O',
        reference: 'proof',
        outcome: AppleAttemptOutcome.paid,
        claim: claim('T', u)));
    observe(other!, 'T');
    await settle();
    expect(seen, isEmpty);
    expect(store.finished, isEmpty);
    expect((await p.unmatched()).where((r) => r.reason == 'identityConflict'),
        isNotEmpty);
  });
  test('version-one pending evidence survives atomic identity-guard upgrade',
      () async {
    final u = await buy();
    a.dispose();
    store.event(u, 'migrated');
    await settle();
    await p.close();
    final path = '${dir.path}/ledger';
    final file = await openDatabase(path, singleInstance: false);
    // Build the pre-migration column layout with its three named identity guards.
    for (final name in ['attempt', 'queue', 'purchase']) {
      await file.execute('DROP TRIGGER ${name}_identity');
    }
    await file.execute('ALTER TABLE attempt DROP COLUMN submittedId');
    await file.execute('ALTER TABLE attempt DROP COLUMN legacySubmission');
    for (final name in ['attempt', 'queue', 'purchase']) {
      final table = name == 'queue' ? 'queue_item' : name;
      await file.execute(
          "CREATE TRIGGER ${name}_identity BEFORE UPDATE ON $table WHEN OLD.id IS NOT NEW.id BEGIN SELECT RAISE(ABORT,'identity'); END");
    }
    await file.setVersion(1);
    await file.close();
    p = ApplePayments.forTesting(store, AppleJournal(() async => File(path)));
    await p.start(environment: 'sandbox');
    a = connect();
    await settle();
    store.event(u, 'migrated');
    await settle();
    expect(store.finished, isEmpty);
    await p.reconcile(claim('migrated', u));
    await settle();
    expect(seen.single.receipt, 'good');
    expect(store.finished.single.transactionId, 'migrated');
    expect((await a.lookup('O'))!.attemptId, u);
  });
}
