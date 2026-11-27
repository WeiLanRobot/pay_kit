import 'dart:convert';

import 'package:sqflite/sqflite.dart';

typedef AppleDispositionFact = Map<String, Object?>;
typedef AppleDispositionResolution = ({
  AppleDispositionFact? effective,
  String? issue
});

// covered=0 is new evidence. covered=1 was superseded by a formal decision.
// The selected receipt remains the authoritative starting point for new facts.
const appleReviewedDisposition = 2;
// A v6 ruling transferred a fulfilled order without recording compensation.
const appleUncompensatedTransfer = 3;

bool pendingAppleCoverage(Object? reason) =>
    reason == 'missingPredecessor' || reason == 'incompleteRefundCoverage';

/// Device report IDs can be authenticated aliases of the same verified charge.
/// Only the commercial contents determine whether two copies of a receipt
/// agree. The optional operation ID is absent from older payloads.
typedef _Receipt = ({
  Object? app,
  Object? environment,
  Object? scope,
  Object? order,
  Object? product,
  Object? quantity,
  Object? verified,
  Object? outcome,
  Object? predecessor,
  String? operation,
});

_Receipt _contents(AppleDispositionFact fact) {
  final f = jsonDecode(fact['payload'] as String) as List;
  return (
    app: f[0],
    environment: f[1],
    scope: f[2],
    order: f[3],
    product: f[4],
    quantity: f[5],
    verified: f[7],
    outcome: f[9],
    predecessor: f[10],
    operation: f.length > 11 ? f[11] as String : null
  );
}

AppleDispositionResolution resolveAppleDispositions(
    AppleDispositionFact purchase, List<AppleDispositionFact> facts) {
  const conflict = (effective: null, issue: 'dispositionConflict');
  if (facts.any((f) => f['covered'] == appleUncompensatedTransfer)) {
    return (effective: null, issue: 'uncompensatedOwnershipChange');
  }
  final covered = <Object?, Set<_Receipt>>{};
  final receipts = <String, _Receipt>{};
  final rows = <String, AppleDispositionFact>{};
  for (final fact in facts.where((f) => f['covered'] == 1)) {
    (covered[fact['reference']] ??= {}).add(_contents(fact));
  }
  // Process the formal decision first, even if the newly supplied reference
  // denotes a different outcome. A replay of overruled contents stays covered.
  for (final fact in [
    ...facts.where((f) => f['covered'] == appleReviewedDisposition),
    ...facts.where((f) => f['covered'] == 0)
  ]) {
    final ref = fact['reference'] as String;
    final body = _contents(fact);
    final previous = covered[ref];
    if (fact['covered'] == 0 && previous != null) {
      if (previous.contains(body)) continue;
      if (receipts[ref] != body) return conflict;
    }
    if (body.app != purchase['appId'] ||
        body.environment != purchase['environment'] ||
        body.scope != purchase['scope'] ||
        body.order != purchase['orderId'] ||
        body.product != purchase['productId'] ||
        body.quantity != 1 ||
        body.verified != purchase['verifiedId'] ||
        receipts.containsKey(ref) && receipts[ref] != body) {
      return conflict;
    }
    receipts[ref] = body;
    rows.putIfAbsent(ref, () => fact);
  }
  final deliveries = <String, (bool, String)>{};
  final refunds = <String>[];
  for (final entry in receipts.entries) {
    final body = entry.value;
    switch (body.outcome) {
      case 'delivered':
        if (body.predecessor != null) return conflict;
        final operation = body.operation;
        deliveries[entry.key] = (operation != null, operation ?? entry.key);
      case 'refunded':
        if (body.operation != null || body.predecessor == entry.key) {
          return conflict;
        }
        refunds.add(entry.key);
      default:
        return conflict;
    }
  }
  final compensated = <(bool, String)>{};
  var missing = false;
  for (final ref in refunds) {
    final predecessor = receipts[ref]!.predecessor;
    if (predecessor == null) continue;
    final delivery = deliveries[predecessor];
    if (delivery != null) {
      compensated.add(delivery);
    } else if (receipts.containsKey(predecessor)) {
      return conflict;
    } else if (rows[ref]!['covered'] != appleReviewedDisposition) {
      missing = true;
    }
  }
  if (missing) return (effective: null, issue: 'missingPredecessor');
  if (refunds.isNotEmpty && !compensated.containsAll(deliveries.values)) {
    return (effective: null, issue: 'incompleteRefundCoverage');
  }
  final candidates = refunds.isEmpty ? deliveries.keys : refunds;
  if (candidates.isEmpty) return conflict;
  final current = purchase['ackRef'];
  final effective = candidates.contains(current)
      ? current
      : (candidates.toList()..sort()).first;
  return (effective: rows[effective]!, issue: null);
}

/// Recheck already settled v6 charges before native finish can be retried.
/// Keep removal history, fulfillment facts and revision-bound reviews intact.
Future<void> upgradeAppleDispositionCoverage(DatabaseExecutor db) async {
  final purchases = await db.rawQuery('''SELECT p.* FROM purchase p WHERE
      id IN (SELECT purchaseId FROM disposition_fact
        WHERE outcome='refunded' OR covered=1)''');
  for (final p in purchases) {
    final id = p['id'];
    var receipts = await db
        .query('disposition_fact', where: 'purchaseId=?', whereArgs: [id]);
    if (receipts.any((r) => r['covered'] == 1)) {
      // v6 marked all dispositions covered even for an ownership-only review.
      // Only reviews with an explicit final receipt decided fulfillment.
      final reviews = await db.query('dispute_review',
          where: 'purchaseId=?', whereArgs: [id], orderBy: 'rowid');
      final superseded = <String>{};
      String? selected;
      AppleDispositionFact? previousFinal;
      var compensationDue = false;
      for (final review in reviews) {
        final data = jsonDecode(review['payload'] as String) as List;
        if (data.length < 6) continue;
        final finalPayload = data[5];
        // With no final receipt, slot 5 may instead contain an environment
        // proof ID. Match the serialized receipt against actual saved facts.
        final next =
            receipts.where((f) => f['payload'] == finalPayload).firstOrNull;
        if (next == null) continue;
        final covers = (data[4] as List).cast<String>().toSet();
        // A v6 review could select another beneficiary's delivery even when a
        // covered grant to the former beneficiary had never been compensated.
        // Each formal refund settles the receipts covered by that ruling.
        if (next['outcome'] == 'refunded') {
          compensationDue = false;
        } else {
          final newReceipts = receipts.where((f) =>
              covers.contains(f['reference']) &&
              !superseded.contains(f['reference']));
          final priorGrants = [
            if (previousFinal != null) previousFinal,
            ...newReceipts
          ];
          compensationDue |= priorGrants.any((f) =>
              f['outcome'] == 'delivered' &&
              (f['scope'] != next['scope'] ||
                  f['orderId'] != next['orderId']) &&
              !newReceipts.any((r) =>
                  r['outcome'] == 'refunded' &&
                  r['supersedes'] == f['reference'] &&
                  r['scope'] == f['scope'] &&
                  r['orderId'] == f['orderId'] &&
                  _contents(r).verified == _contents(f).verified));
        }
        previousFinal = next;
        selected = finalPayload as String;
        superseded.addAll(covers);
        superseded.add((jsonDecode(selected) as List)[8] as String);
      }
      for (final fact in receipts.where((f) => f['covered'] == 1)) {
        final state = fact['payload'] == selected
            ? (compensationDue
                ? appleUncompensatedTransfer
                : appleReviewedDisposition)
            : superseded.contains(fact['reference'])
                ? 1
                : 0;
        if (state != 1) {
          await db.update('disposition_fact', {'covered': state},
              where: 'purchaseId=? AND payload=?',
              whereArgs: [id, fact['payload']]);
        }
      }
      receipts = await db
          .query('disposition_fact', where: 'purchaseId=?', whereArgs: [id]);
    }
    if (p['conflict'] == 1 ||
        p['reason'] == 'environmentMismatch' ||
        p['disposition'] == 'legacyHandedOff') {
      continue;
    }
    final result = resolveAppleDispositions(p, receipts);
    if (result.issue case final reason?) {
      await db.rawUpdate('''UPDATE purchase SET conflict=1,reason=?,
          disputeRevision=disputeRevision+1 WHERE id=?''', [reason, id]);
      await db.insert(
          'conflict_fact',
          {
            'purchaseId': id,
            'reason': reason,
            'evidenceRef': 'v7-fulfillment-coverage'
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}
