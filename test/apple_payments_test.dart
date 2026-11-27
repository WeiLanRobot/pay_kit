import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'verified_queue_fixture.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/pay_kit.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:pay_kit/src/iap/apple_store.dart';
import 'package:sqflite/sqflite.dart';

class FaultJournal extends AppleJournal {
  FaultJournal(super.location);
  bool writable = true;
  @override
  Future<T> write<T>(Future<T> Function(DatabaseExecutor) op) {
    if (!writable) {
      return Future.error(
          const FileSystemException('test storage unavailable'));
    }
    return super.write(op);
  }
}

class ProbeStore implements AppleStore {
  String runningBundle = 'app';
  @override
  Future<String> bundleIdentifier() async => runningBundle;

  final stream = StreamController<List<StoreEvent>>.broadcast(sync: true);
  final submitted = <String>[], finished = <StoreEvent>[];
  Future<bool> Function()? launch;
  Future<void> Function()? afterFinish;
  bool failFinish = false;
  @override
  Stream<List<StoreEvent>> get events => stream.stream;
  @override
  Future<void> prepare(String productId) async {}
  @override
  Future<bool> purchase(String productId, String token) async {
    submitted.add(token);
    return await launch?.call() ?? true;
  }

  @override
  Future<void> finish(StoreEvent e, {bool verifiedQueue = false}) async {
    if (failFinish) throw StateError('finish interrupted');
    finished.add(e);
    await afterFinish?.call();
  }

  @override
  Future<String?> refreshReceipt() async => 'fresh';
  void event(String? token, String? id,
          {String receipt = 'good',
          String? queue,
          String? handle,
          StoreStatus status = StoreStatus.paid}) =>
      stream.add([
        StoreEvent(
            productId: 'sku',
            token: token,
            transactionId: id,
            native: handle,
            receipt: receipt,
            queueId: queue ?? id,
            status: status)
      ]);
}

AppleVerification delivered(AppleReceipt r,
        {String? verified, AppleOutcome outcome = AppleOutcome.delivered}) =>
    AppleVerification.delivered(AppleDisposition(
        appId: 'app',
        environment: 'sandbox',
        scope: r.scope,
        orderId: r.orderId,
        productId: r.productId,
        reportedTransactionId: r.transactionId,
        verifiedTransactionId: verified ?? r.transactionId,
        reference: 'ack-${r.transactionId}',
        outcome: outcome));

void main() {
  late Directory dir;
  late ProbeStore store;
  late ApplePayments pay;
  late AppleJournal journal;
  Future<void> boot() async {
    store = ProbeStore();
    journal = FaultJournal(() async => File('${dir.path}/ledger'));
    pay = ApplePayments.forTesting(store, journal);
    await pay.start(environment: 'sandbox');
  }

  Future<void> stop() async {
    await pay.close();
    await store.stream.close();
  }

  Future<void> restart() async {
    await stop();
    await boot();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pay-131-');
    await boot();
  });
  tearDown(() async {
    await stop();
    await dir.delete(recursive: true);
  });
  AppleAccount login(
          [String scope = 'A',
          Future<AppleVerification> Function(AppleReceipt)? verify]) =>
      pay.connect(scope: scope, verify: verify ?? (r) async => delivered(r));
  Future<AppleOrderSnapshot> buy(AppleAccount a, [String id = '42']) =>
      a.buy(productId: 'sku', orderId: id);
  Future<void> drain() async {
    await pay.retryPending();
    await pay.settle();
  }

  AppleClaim claim(String tx,
          {String order = '42', String? token, String? verified}) =>
      AppleClaim(
          appId: 'app',
          environment: 'sandbox',
          reportedTransactionId: tx,
          verifiedTransactionId: verified ?? tx,
          scope: 'A',
          orderId: order,
          productId: 'sku',
          reference: 'claim-$tx',
          purchaseToken: token);

  test(
      'G1 same order number in two accounts routes late evidence only to the owner',
      () async {
    final seen = <String>[];
    final a = login('A', (r) async {
      seen.add('A');
      return delivered(r);
    });
    final u = (await buy(a)).attemptId;
    final b = login('B', (r) async {
      seen.add('B');
      return delivered(r);
    });
    expect((await buy(b)).attemptId, isNot(u));
    store.event(u, 'T');
    await drain();
    expect(seen, isEmpty);
    expect(store.finished, isEmpty);
    login('A', (r) async {
      seen.add(r.scope);
      return delivered(r);
    });
    await drain();
    expect(seen, ['A']);
    expect(store.finished.single.transactionId, 'T');
  });
  test(
      'G2 persisted acknowledgement survives failed finish and process restart',
      () async {
    var calls = 0;
    final a = login('A', (r) async {
      calls++;
      return delivered(r);
    });
    final u = (await buy(a)).attemptId;
    store.failFinish = true;
    store.event(u, 'T');
    await drain();
    expect((await a.lookup('42'))!.charges.single.reference, 'ack-T');
    final grants =
        await journal.read((db) => db.query('recovery.finish_authority'));
    final basis = jsonDecode(grants.single['basis'] as String) as Map;
    expect(basis['reportedId'], 'T');
    expect(basis['reference'], 'ack-T');
    expect(basis['scope'], 'A');
    expect((await a.lookup('42'))!.charges.single.finishPending, true);
    await restart();
    login('A', (r) async {
      calls++;
      return delivered(r);
    });
    store.event(u, 'T');
    await drain();
    expect(store.finished, isEmpty);
    await pay.reconcile(claim('T', token: u));
    await drain();
    expect(calls, 1);
    expect(store.finished.single.transactionId, 'T');
  });
  test('a lost removal confirmation preserves delivery and permits a new order',
      () async {
    final verified = <String>[];
    Future<AppleVerification> verify(AppleReceipt receipt) async {
      verified.add(receipt.transactionId);
      return delivered(receipt);
    }

    final first = login('A', verify);
    final token = (await buy(first)).attemptId;
    // StoreKit finishes the item, but the final journal write cannot commit.
    store.afterFinish = () async {
      (journal as FaultJournal).writable = false;
    };
    store.event(token, 'T');
    await pay.settle();
    expect(store.finished.map((item) => item.transactionId), ['T']);

    await restart();
    final current = login('A', verify);
    // The removed transaction does not replay in the new store instance.
    await drain();
    await drain();
    final charge = (await current.lookup('42'))!.charges.single;
    expect(charge.disposition, 'delivered');
    expect(charge.reference, 'ack-T');
    expect(charge.finishPending, isTrue);
    expect(verified, ['T']);
    expect(store.finished, isEmpty);
    expect(store.submitted, isEmpty);

    final next = await buy(current, 'next-order');
    expect(store.submitted, [next.attemptId]);
    store.event(next.attemptId, 'T2');
    await drain();
    expect(verified, ['T', 'T2']);
    expect(store.finished.map((item) => item.transactionId), ['T2']);
    expect((await current.lookup('next-order'))!.charges.single.finishPending,
        isFalse);
    expect((await current.lookup('42'))!.charges.single.finishPending, isTrue);
  });

  test('G3 disposal cannot transfer legacy receipt to surviving receiver',
      () async {
    final received = <String>[];
    final a = Object(), b = Object();
    pay.attachLegacy(a, (r) async {
      received.add(r);
    }, (_, __) {}, (_) {});
    pay.attachLegacy(b, (r) async {
      received.add(r);
    }, (_, __) {}, (_) {});
    await pay.buyLegacy(a, 'sku', 'old-a');
    await pay.buyLegacy(b, 'sku', 'old-b');
    pay.detachLegacy(a);
    store.event('old-a', 'T');
    await drain();
    expect(received, isEmpty);
    expect(store.finished, isEmpty);
    await expectLater(pay.buyLegacy(b, 'sku', 'old-a'), throwsStateError);
  });
  test('G4 concurrent submissions share the exact future and native refusal',
      () async {
    final a = login();
    final entered = Completer<void>(), release = Completer<bool>();
    store.launch = () {
      entered.complete();
      return release.future;
    };
    final first = buy(a);
    await entered.future;
    final second = buy(a);
    expect(identical(first, second), isTrue);
    release.complete(false);
    expect((await first).phase, 'declined');
    expect((await second).phase, 'declined');
    expect(store.submitted, hasLength(1));
  });
  test('G5 distinct receipts persist while logged out and across restart',
      () async {
    final a = login();
    final u = (await buy(a)).attemptId;
    a.dispose();
    store.event(u, 'T', receipt: 'stale');
    store.event(u, 'T', receipt: 'fresh');
    await drain();
    await restart();
    final seen = <String>[];
    login('A', (r) async {
      seen.add(r.receipt);
      return r.receipt == 'fresh'
          ? delivered(r)
          : const AppleVerification.invalidEvidence();
    });
    await drain();
    expect(seen, contains('fresh'));
  });
  test('G6 repeated nil-ID queue observation stays one unresolved item',
      () async {
    for (var i = 0; i < 6; i++) {
      store.event(null, null, queue: 'Q');
      await drain();
    }
    expect(await pay.unmatched(), hasLength(1));
    expect(store.finished, isEmpty);
  });
  test('G7 reconciliation cannot invent a missing StoreKit purchase token',
      () async {
    final seen = <AppleReceipt>[];
    login('A', (r) async {
      seen.add(r);
      return delivered(r);
    });
    store.event(null, 'reported', handle: 'current');
    await drain();
    await proveQueue(pay, claim('reported'));
    await drain();
    expect(seen.single.purchaseToken, isNull);
    expect(seen.single.attemptId, isNull);
    expect(store.finished.single.transactionId, 'reported');
  });
  test('G8 refresh after an exception supplies independent usable evidence',
      () async {
    final seen = <String>[];
    final a = login('A', (r) async {
      seen.add(r.receipt);
      if (r.receipt == 'stale') throw const FormatException();
      return delivered(r);
    });
    final u = (await buy(a)).attemptId;
    store.event(u, 'T', receipt: 'stale');
    await drain();
    await pay.refreshReceipts();
    await drain();
    expect(seen, contains('fresh'));
    expect(store.finished, hasLength(1));
  });
  test('G9 each actual charge needs its own terminal disposition', () async {
    bool refund = false;
    final a = login(
        'A',
        (r) async => r.transactionId == 'T1'
            ? delivered(r)
            : refund
                ? delivered(r, outcome: AppleOutcome.refunded)
                : const AppleVerification.retryLater());
    final u = (await buy(a)).attemptId;
    store.event(u, 'T1');
    await drain();
    store.event(u, 'T2');
    await drain();
    expect(store.finished.map((e) => e.transactionId), ['T1']);
    await pay.reconcile(claim('T2', token: u));
    refund = true;
    await drain();
    final s = await a.lookup('42');
    expect(s!.charges.map((c) => c.disposition),
        unorderedEquals(['delivered', 'refunded']));
    expect(store.finished.map((e) => e.transactionId), ['T1', 'T2']);
  });
  test(
      'G10 cancellation is committed in the on-disk image before native finish',
      () async {
    final a = login();
    final u = (await buy(a)).attemptId;
    final diskPhase = Completer<String>();
    store.afterFinish = () async {
      final file =
          await File('${dir.path}/ledger').copy('${dir.path}/crash-copy');
      final reopened = AppleJournal(() async => file);
      try {
        diskPhase.complete(await reopened.read((db) async =>
            (await db.query('attempt')).single['phase'] as String));
      } finally {
        await reopened.close();
      }
    };
    store.event(u, null, queue: 'native-object', status: StoreStatus.canceled);
    expect(await diskPhase.future, 'canceled');
    await drain();
    expect((await buy(a)).attemptId, isNot(u));
  });
  test(
      'uncertain result remains locked across restart until a durable authoritative decision',
      () async {
    final a = login();
    store.launch = () async => throw StateError('reply lost');
    final s = await buy(a);
    expect(s.phase, 'uncertain');
    await restart();
    final b = login();
    expect((await buy(b)).attemptId, s.attemptId);
    expect(store.submitted, isEmpty);
    AppleAttemptDecision decision(String id, AppleAttemptOutcome outcome) =>
        AppleAttemptDecision(
            issuer: 'server',
            decisionId: id,
            appId: 'app',
            environment: 'sandbox',
            attemptId: s.attemptId!,
            scope: 'A',
            orderId: '42',
            reference: 'proof-$id',
            outcome: outcome);
    await pay.resolveAttempt(decision('open', AppleAttemptOutcome.pending));
    expect((await buy(b)).attemptId, s.attemptId);
    final end = decision('final', AppleAttemptOutcome.unpaid);
    await pay.resolveAttempt(end);
    await pay.resolveAttempt(end);
    expect((await buy(b)).attemptId, isNot(s.attemptId));
    expect(store.submitted, hasLength(1));
  });
  test('stale cancellation cannot retire a later attempt', () async {
    final a = login();
    final x = (await buy(a)).attemptId;
    store.event(x, null, queue: 'cancel1', status: StoreStatus.canceled);
    await drain();
    final y = (await buy(a)).attemptId;
    store.event(x, null, queue: 'cancel1', status: StoreStatus.canceled);
    await drain();
    expect((await a.lookup('42'))!.attemptId, y);
    expect((await buy(a)).attemptId, y);
    expect(store.submitted, hasLength(2));
  });
  test('bad input and conflicting product or token cannot submit', () async {
    final a = login();
    await expectLater(
        a.buy(productId: 'sku', orderId: '  '), throwsArgumentError);
    await expectLater(
        a.buy(productId: 'sku', orderId: '42', purchaseToken: 'bad'),
        throwsArgumentError);
    expect(store.submitted, isEmpty);
    await buy(a);
    await expectLater(
        a.buy(productId: 'other', orderId: '42'), throwsStateError);
    expect(store.submitted, hasLength(1));
  });
  test(
      'watch includes initial and terminal snapshots, survives page reentry and ends on logout',
      () async {
    final a = login();
    final values = <AppleOrderSnapshot?>[];
    final closed = Completer<void>(), initial = Completer<void>();
    final sub = a.watch('42').listen((s) {
      values.add(s);
      if (!initial.isCompleted) initial.complete();
    }, onDone: closed.complete);
    await initial.future;
    final u = (await buy(a)).attemptId;
    store.event(u, 'T');
    await drain();
    final current = await a.watch('42').first;
    expect(current!.charges.single.reference, 'ack-T');
    a.dispose();
    await closed.future;
    await sub.cancel();
    expect(values.first, isNull);
    final revisions = values.nonNulls.map((s) => s.revision).toList();
    expect(revisions, orderedEquals(revisions.toSet().toList()..sort()));
    await expectLater(a.lookup('42'), throwsStateError);
  });
  test(
      'verifier can enqueue retry and another charge advances during a slow verifier',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    final a = login('A', (r) async {
      await pay.retryPending();
      if (r.transactionId == 'slow') {
        entered.complete();
        await release.future;
      }
      return delivered(r);
    });
    final x = (await buy(a, 'one')).attemptId,
        y = (await buy(a, 'two')).attemptId;
    store.event(x, 'slow');
    await entered.future;
    store.event(y, 'fast');
    try {
      await a.watch('two').firstWhere(
          (s) => s?.charges.any((c) => c.reference == 'ack-fast') ?? false);
    } finally {
      release.complete();
    }
    await drain();
    expect(store.finished, hasLength(2));
  });
  test('rejected service identity cannot read the previous installation ledger',
      () async {
    await buy(login());
    await stop();
    store = ProbeStore();
    journal = FaultJournal(() async => File('${dir.path}/ledger'));
    pay = ApplePayments.forTesting(store, journal);
    store.runningBundle = 'different.app';
    final opening = pay.start(environment: 'sandbox');
    expect(() => login(), throwsStateError);
    await expectLater(opening, throwsStateError);
    expect(() => login(), throwsStateError);
    await expectLater(pay.unmatched(), throwsStateError);
    store.runningBundle = 'app';
    await pay.start(environment: 'sandbox');
    expect(await login().lookup('42'), isNotNull);
  });

  test('a persisted preparation cannot submit over a positive earlier attempt',
      () async {
    final a = login();
    final original = (await buy(a)).attemptId;
    store.event(original, null,
        status: StoreStatus.canceled, queue: 'cancelled');
    await drain();
    // Crash image after preparing an explicitly requested retry, before native submission.
    const next = 'ae222222-c3d2-4b54-aaaa-123456789012';
    await journal.write((db) => db.insert('attempt', {
          'id': next,
          'wireToken': next,
          'orderId': '42',
          'scope': 'A',
          'mode': 'scoped',
          'phase': 'prepared',
          'productId': 'sku'
        }));
    await restart();
    final b = login();
    store.event(original, 'late-paid');
    await drain();
    expect((await buy(b)).phase, 'conflict');
    expect(store.submitted, isEmpty);
    expect(store.finished, isEmpty);
  });
  test(
      'new login continues remaining receipt evidence after previous verifier retires',
      () async {
    final a = login();
    final u = (await buy(a)).attemptId;
    a.dispose();
    store.event(u, 'T', receipt: 'first');
    store.event(u, 'T', receipt: 'second');
    await drain();
    final started = Completer<void>(), old = Completer<AppleVerification>();
    login('A', (r) async {
      started.complete();
      return old.future;
    });
    await started.future;
    final fresh = Completer<String>();
    login('A', (r) async {
      fresh.complete(r.receipt);
      return delivered(r);
    });
    old.complete(const AppleVerification.invalidEvidence());
    expect(await fresh.future, isNotEmpty);
    await pay.settle();
    expect(store.finished, hasLength(1));
  });

  test(
      'disk failure keeps native refusal and inhibits new submissions until saved',
      () async {
    final a = login();
    final disk = journal as FaultJournal;
    store.launch = () async {
      disk.writable = false;
      return false;
    };
    await expectLater(buy(a), throwsA(isA<FileSystemException>()));
    expect((await buy(a)).phase, 'uncertain');
    expect(store.submitted, hasLength(1));
    disk.writable = true;
    await drain();
    expect((await a.lookup('42'))!.phase, 'declined');
    await restart();
    expect((await login().lookup('42'))!.phase, 'declined');
  });

  test('storage outage before evidence capture cannot deliver or finish',
      () async {
    final disk = journal as FaultJournal;
    var calls = 0;
    final a = login('A', (r) async {
      calls++;
      return delivered(r);
    });
    final u = (await buy(a)).attemptId;
    disk.writable = false;
    store.event(u, 'T');
    await pay.settle();
    expect(calls, 0);
    expect(store.finished, isEmpty);
    disk.writable = true;
    await drain();
    expect(calls, 1);
    expect(store.finished, hasLength(1));
  });

  test(
      'lost acknowledgement replays idempotent server transaction before finish',
      () async {
    final disk = journal as FaultJournal;
    final credits = <String>{};
    var calls = 0;
    Future<AppleVerification> verify(AppleReceipt r) async {
      credits.add(r.transactionId);
      calls++;
      if (calls == 1) disk.writable = false;
      return delivered(r);
    }

    final a = login('A', verify);
    final u = (await buy(a)).attemptId;
    store.event(u, 'T');
    await pay.settle();
    expect(store.finished, isEmpty);
    await restart();
    login('A', verify);
    store.event(u, 'T');
    await drain();
    await pay.reconcile(claim('T', token: u));
    await drain();
    expect(credits, {'T'});
    expect(calls, 2);
    expect(store.finished, hasLength(1));
  });
  test(
      'in-flight server acknowledgement after logout is written only to the original order',
      () async {
    final entered = Completer<AppleReceipt>(),
        reply = Completer<AppleVerification>();
    final a = login('A', (r) {
      entered.complete(r);
      return reply.future;
    });
    final u = (await buy(a)).attemptId;
    store.event(u, 'T');
    final receipt = await entered.future;
    var bCalls = 0;
    final b = login('B', (r) async {
      bCalls++;
      return delivered(r);
    });
    await buy(b);
    reply.complete(delivered(receipt));
    await pay.settle();
    expect(bCalls, 0);
    expect((await b.lookup('42'))!.charges, isEmpty);
    expect(store.finished.single.transactionId, 'T');
    expect((await login().lookup('42'))!.charges.single.reference, 'ack-T');
  });
  test(
      'an earlier unknown charge claimed while primary fulfillment is in flight is additional',
      () async {
    final checking = Completer<void>(),
        release = Completer<void>(),
        claimed = Completer<void>();
    final flags = <String, bool>{};
    final a = login('A', (r) async {
      flags[r.transactionId] = r.additionalCharge;
      if (r.transactionId == 'primary') {
        checking.complete();
        await release.future;
      } else {
        claimed.complete();
      }
      return delivered(r);
    });
    store.event(null, 'orphan', handle: 'orphan-handle');
    await pay.settle();
    final token = (await buy(a)).attemptId;
    store.event(token, 'primary');
    await checking.future;
    try {
      await proveQueue(pay, claim('orphan'));
      await claimed.future;
    } finally {
      release.complete();
    }
    await pay.settle();
    expect(flags, {'primary': false, 'orphan': true});
    expect(store.finished, hasLength(2));
  });
}
