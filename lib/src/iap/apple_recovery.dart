part of 'apple_payments.dart';

// A rejected queue item must not discard a separately authenticated payment.
class _AppleObservationRejected extends StateError {
  _AppleObservationRejected(super.message, {this.opposingProof});
  final _Row? opposingProof;
}

extension _AppleRecovery on ApplePayments {
  Future<_Row?> _verifiedCharge(DatabaseExecutor db, AppleClaim c) async =>
      (await db.query('purchase',
              where: 'appId=? AND environment=? AND verifiedId=?',
              whereArgs: [c.appId, c.environment, c.verifiedTransactionId]))
          .firstOrNull;

  // Older ledgers could store an authenticated original submission without
  // booking its payment if the device did not replay the original wire token.
  Future<void> _restoreOriginalPayments(
      DatabaseExecutor db, String app, String environment) async {
    final missing = await db.rawQuery(
        '''SELECT s.* FROM recovery.original_submission s
      WHERE s.appId=? AND s.environment=? AND NOT EXISTS (
        SELECT 1 FROM purchase p JOIN claim_fact f ON f.purchaseId=p.id
        WHERE p.appId=s.appId AND p.environment=s.environment AND p.verifiedId=s.verifiedId
        AND f.scope=s.scope AND f.orderId=s.orderId AND p.productId=s.productId)''',
        [app, environment]);
    for (final row in missing) {
      // A later review may have corrected the canonical Apple ID. Its original
      // immutable claim remains covered and must not recreate the old charge.
      final reviewed = await db.query('claim_fact',
          columns: ['payload'],
          where: 'covered=1 AND scope=? AND orderId=?',
          whereArgs: [row['scope'], row['orderId']]);
      if (reviewed.any((r) {
        final fields = jsonDecode(r['payload'] as String) as List;
        return fields[0] == app &&
            fields[1] == environment &&
            fields[4] == row['productId'] &&
            fields[6] == row['verifiedId'];
      })) {
        continue;
      }
      final claim = AppleClaim(
          appId: app,
          environment: environment,
          scope: row['scope'] as String,
          orderId: row['orderId'] as String,
          productId: row['productId'] as String,
          reportedTransactionId: row['reportedId'] as String,
          verifiedTransactionId: row['verifiedId'] as String,
          purchaseToken: row['token'] as String,
          reference: row['reference'] as String);
      await _recordFinancialClaim(
          db, claim, await _verifiedCharge(db, claim), <String>{});
    }
  }

  /// Accepts a host-authenticated statement about the original submission.
  /// Retain competing statements so a retry cannot silently erase a collision.
  Future<void> _saveOriginal(
      DatabaseExecutor db, AppleClaim c, AppleOriginalSubmission s) async {
    if (s.issuer.trim().isEmpty ||
        s.reference.trim().isEmpty ||
        s.appId != c.appId ||
        s.environment != c.environment ||
        s.scope != c.scope ||
        s.orderId != c.orderId ||
        s.productId != c.productId ||
        s.quantity != 1 ||
        s.reportedTransactionId != c.reportedTransactionId ||
        s.verifiedTransactionId != c.verifiedTransactionId ||
        !Uuid.isValidUUID(fromString: s.purchaseToken) ||
        _wire(s.purchaseToken) != _wire(c.purchaseToken)) {
      throw _AppleObservationRejected(
          'Original Apple submission does not match the authenticated claim');
    }
    await db.insert(
        'recovery.original_submission',
        {
          'appId': s.appId,
          'token': _wire(s.purchaseToken),
          'issuer': s.issuer,
          'reference': s.reference,
          'environment': s.environment,
          'scope': s.scope,
          'orderId': s.orderId,
          'productId': s.productId,
          'verifiedId': s.verifiedTransactionId,
          'reportedId': s.reportedTransactionId,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    // The evidence registry is shared by every environment of this app.
    // If a signer reuses a reference, quarantine both affected submissions.
    final collision = await db.rawQuery(
        """SELECT DISTINCT a.token FROM recovery.original_submission a
      JOIN recovery.original_submission b ON a.appId=b.appId AND
        (a.token=b.token OR (a.issuer=b.issuer AND a.reference=b.reference))
      WHERE a.appId=? AND (a.token=? OR (a.issuer=? AND a.reference=?)) AND
        (a.token!=b.token OR a.environment!=b.environment OR a.scope!=b.scope OR
         a.orderId!=b.orderId OR a.productId!=b.productId OR a.reportedId!=b.reportedId OR
         a.verifiedId!=b.verifiedId)""",
        [c.appId, _wire(s.purchaseToken), s.issuer, s.reference]);
    for (final entry in collision) {
      await db.rawUpdate(
          """UPDATE recovery.observation SET reason='originalSubmissionConflict'
        WHERE token=? AND (reason='originalSubmission' OR id=?)""",
          [entry['token'], c.observationId]);
    }
  }

  Future<bool> _sourceForObservation(
      DatabaseExecutor db, AppleClaim c, _Row r) async {
    if (r['reason'] == 'originalSubmissionConflict' ||
        r['generation'] == 'verified' && r['originLinked'] != 1) {
      return false;
    }
    final bound = r['boundPurchase'];
    if (bound is String && r['boundEnvironment'] == c.environment) {
      final p =
          await _row(db, 'purchase', await _canonicalPurchaseId(db, bound));
      return p != null &&
          p['verifiedId'] == c.verifiedTransactionId &&
          p['appId'] == c.appId;
    }
    final token = _wire(c.purchaseToken);
    if (token == null || token != r['token']) return false;
    final claims = await db.rawQuery('''SELECT s.*, EXISTS(
      SELECT 1 FROM recovery.original_submission b WHERE b.appId=s.appId AND b.issuer=s.issuer
      AND b.reference=s.reference AND b.token!=s.token) AS reusedReference
      FROM recovery.original_submission s WHERE s.appId=? AND s.token=?''',
        [c.appId, token]);
    final original = claims.isNotEmpty &&
        claims.every((p) =>
            p['reusedReference'] == 0 &&
            p['environment'] == c.environment &&
            p['scope'] == c.scope &&
            p['orderId'] == c.orderId &&
            p['productId'] == c.productId &&
            p['verifiedId'] == c.verifiedTransactionId &&
            p['reportedId'] == c.reportedTransactionId);
    if (claims.isNotEmpty && !original) return false;
    final reservations = await db
        .query('recovery.submission', where: 'token=?', whereArgs: [token]);
    if (reservations.isEmpty) return original;
    if (reservations.length != 1) return false;
    final a = await _attemptForToken(db, token);
    final reservation = reservations.single;
    if (a != null &&
        a['phase'] != 'prepared' &&
        !_unpaidPhase(a['phase']) &&
        reservation['attemptId'] == a['id'] &&
        a['productId'] == c.productId &&
        a['orderId'] == c.orderId &&
        !_disagrees(a['scope'], c.scope) &&
        (reservation['origin'] == c.environment ||
            reservation['origin'] == 'legacy' && a['mode'] == 'legacy')) {
      return true;
    }
    if (reservation['origin'] == 'legacy' &&
        _wire(c.orderId) == token &&
        (await db.rawQuery('''SELECT 1 FROM recovery.compatibility_handoff
         WHERE attemptId=? AND wire=? COLLATE NOCASE AND orderId=? AND sku=?
           AND reported=? LIMIT 1''', [
          reservation['attemptId'],
          token,
          c.orderId,
          c.productId,
          c.reportedTransactionId
        ]))
            .isNotEmpty) {
      // The archived accepted submission and its completed callback provide
      // independent provenance. Restore checks its signed environment and owner.
      return true;
    }
    // Only a previously linked compatibility handoff or trusted environment
    // correction can move an original submission into another partition.
    return (await db.rawQuery(
            '''SELECT 1 FROM recovery.observation WHERE
      actual=? AND verifiedId=? AND productId=? AND token=? AND originLinked=1 AND
      (reason IN ('environmentMismatch','environmentSelected') OR
       (generation='compatibility' AND reason='legacySubmissionObserved' AND reportedId=?)) LIMIT 1''',
            [
          c.environment,
          c.verifiedTransactionId,
          c.productId,
          token,
          c.reportedTransactionId
        ]))
        .isNotEmpty;
  }

  bool _onlyLiveQueueObject(StoreEvent event) {
    if (_removingHandles.contains(_handleKey(event))) return false;
    return !_live.values.followedBy(_currentUnbound.values).any((other) =>
        (other.transactionId == event.transactionId ||
            other.queueId == event.queueId) &&
        _objectKey(other) != _objectKey(event));
  }

  Future<_Row?> _acceptVerifiedQueueTransaction(
      DatabaseExecutor db,
      AppleClaim c,
      _Row r,
      _Row? purchase,
      AppleVerifiedQueueTransaction proof,
      List<String> sources) async {
    final id = proof.observationId;
    if (id != r['id'] ||
        proof.transactionId != c.reportedTransactionId ||
        proof.transactionId != c.verifiedTransactionId ||
        proof.appId != c.appId ||
        proof.environment != c.environment ||
        proof.productId != c.productId ||
        proof.scope != c.scope ||
        proof.orderId != c.orderId ||
        proof.quantity != 1 ||
        proof.reference.trim().isEmpty ||
        c.purchaseToken != null ||
        c.review != null ||
        _disagrees(r['token'], c.orderId) ||
        Uuid.isValidUUID(fromString: r['token'] as String? ?? '')) {
      throw _AppleObservationRejected(
          'Verified Apple transaction does not match the order');
    }
    final record = {
      'observation': id,
      'appId': c.appId,
      'reference': proof.reference,
      'receiptHash': proof.receiptHash,
      'environment': c.environment,
      'transactionId': proof.transactionId,
      'productId': c.productId,
      'scope': c.scope,
      'orderId': c.orderId,
    };
    final prior = await db.query('recovery.verified_queue_transaction',
        where: 'observation=? OR (appId=? AND reference=?)',
        whereArgs: [id, c.appId, proof.reference]);
    if (r['reason'] != 'sourceUnproven') {
      throw _AppleObservationRejected(
          'Apple observation requires existing dispute resolution');
    }
    final repeated = prior.length == 1 &&
        record.entries.every((e) => prior.single[e.key] == e.value);
    if (repeated && r['finished'] == 1 && c.environment == _environment) {
      return null;
    }
    final event = _currentUnbound[id];
    if (event == null ||
        r['generation'] != _generation ||
        event.native == null ||
        _objectKey(event) != r['objectKey'] ||
        event.status != StoreStatus.paid ||
        !event.allowsUnownedFinish ||
        event.productId != c.productId ||
        event.originalTransactionId != null ||
        event.queueId != proof.transactionId ||
        event.transactionId != proof.transactionId ||
        _removingHandles.contains(_handleKey(event))) {
      throw _AppleObservationRejected(
          'Verified Apple transaction requires its current queue object');
    }
    final candidate = await db.rawQuery(
        'SELECT 1 FROM recovery.candidate WHERE observation=? AND hash=? LIMIT 1',
        [id, proof.receiptHash]);
    if (candidate.isEmpty) {
      throw _AppleObservationRejected(
          'Verified receipt does not belong to this observation');
    }
    if (prior.isNotEmpty && !repeated) {
      if (prior.any((p) => p['observation'] != id)) {
        throw _AppleObservationRejected('Apple observation proof already used');
      }
      final contradictory = prior.any((p) =>
          p['observation'] == id &&
          (p['environment'] != c.environment ||
              p['scope'] != c.scope ||
              p['orderId'] != c.orderId));
      throw _AppleObservationRejected('Apple observation proof already used',
          opposingProof: contradictory ? record : null);
    }
    if (c.environment != _environment) {
      // Preserve the signed source for this object only. The receiving ledger
      // cannot book a foreign charge or authorize its finish.
      if (prior.isEmpty) {
        await db.insert('recovery.verified_queue_transaction', record);
      }
      return null;
    }
    if (_chargeOnHold(purchase) ||
        _disagrees(purchase?['scope'], c.scope) ||
        _disagrees(purchase?['orderId'], c.orderId) ||
        _disagrees(purchase?['productId'], c.productId)) {
      throw _AppleObservationRejected('Conflicting Apple transaction source');
    }
    final submission =
        await _inspectQueueSubmission(db, record, purchase, sources);
    if (submission.conflict) {
      throw _AppleObservationRejected('Conflicting Apple transaction source');
    }
    final attempt = submission.attempt;
    if (attempt != null && await _row(db, 'attempt', attempt['id']) == null) {
      // The compatibility partition can be the only copy after a cold start.
      await db.insert('attempt', attempt);
    }
    if (prior.isEmpty) {
      await db.insert('recovery.verified_queue_transaction', record);
    }
    return attempt;
  }

  // Both initial authorization and finish retry must see the same provenance,
  // including an explicit server decision made before this handle appeared.
  Future<({bool conflict, _Row? attempt})> _inspectQueueSubmission(
      DatabaseExecutor db,
      _Row proof,
      _Row? purchase,
      List<String> sources) async {
    const conflict = (conflict: true, attempt: null);
    final legacy = await _inspectLegacySubmission(db, proof, sources);
    if (legacy.conflict) return conflict;
    var attempt = legacy.attempt;
    if (purchase?['attemptId'] case final String bound) {
      final a = await _row(db, 'attempt', bound);
      final decisions =
          await db.rawQuery('''SELECT 1 FROM decision WHERE attemptId=? AND
        (result=? OR result IN (SELECT id FROM purchase_redirect WHERE purchaseId=?))
        LIMIT 1''', [bound, purchase!['id'], purchase['id']]);
      // A verifier may learn the signed original UUID after it first verified
      // this tokenless replay. Only a recorded claim and that UUID's one
      // original reservation can link it to a scoped submission.
      bool verifiedToken = false;
      if (decisions.isEmpty &&
          a?['mode'] == 'scoped' &&
          _wire(a?['wireToken'] as String?) == bound &&
          _wire(purchase['token'] as String?) == bound) {
        final entries = await db
            .query('recovery.submission', where: 'token=?', whereArgs: [bound]);
        if (entries.length == 1 &&
            entries.single['attemptId'] == bound &&
            entries.single['origin'] == proof['environment']) {
          final claims = await db.query('claim_fact',
              columns: ['payload'],
              where: 'purchaseId=? AND scope=? AND orderId=? AND covered=0',
              whereArgs: [purchase['id'], proof['scope'], proof['orderId']]);
          verifiedToken = claims.any((fact) {
            final fields = jsonDecode(fact['payload'] as String) as List;
            return fields[0] == proof['appId'] &&
                fields[1] == proof['environment'] &&
                fields[4] == proof['productId'] &&
                fields[6] == proof['transactionId'] &&
                fields[8] == bound;
          });
        }
      }
      if (a != null && (decisions.isNotEmpty || verifiedToken)) {
        if (_disagrees(a['id'], attempt?['id']) ||
            a['phase'] != 'paid' ||
            a['orderId'] != proof['orderId'] ||
            a['productId'] != proof['productId'] ||
            _disagrees(a['scope'], proof['scope'])) {
          return conflict;
        }
        attempt = a;
      }
    }
    final expectedWire = attempt?['wireToken'] ?? proof['orderId'];
    final reported =
        await _reportedPurchase(db, proof['transactionId'] as String);
    for (final charge in [purchase, reported].nonNulls) {
      if (_disagrees(_wire(charge['token'] as String?), expectedWire) ||
          charge['attemptId'] != null &&
              charge['attemptId'] != attempt?['id']) {
        return conflict;
      }
    }
    if (await _legacyQueueHistoryConflicts(db, proof, expectedWire)) {
      return conflict;
    }
    return (conflict: false, attempt: attempt);
  }

  // A reservation establishes that a submission existed. Its order, product
  // and acceptance cannot identify which submission produced this charge.
  // Require a payment observed against the original attempt or its handoff.
  Future<({bool conflict, _Row? attempt})> _inspectLegacySubmission(
      DatabaseExecutor db, _Row proof, List<String> sources) async {
    const conflict = (conflict: true, attempt: null);
    final order = proof['orderId'] as String;
    final reservations = await db.query('recovery.submission',
        where: 'token=?', whereArgs: [appleWireKey(order)]);
    if (reservations.isEmpty) return (conflict: false, attempt: null);
    if (reservations.length != 1 ||
        reservations.single['origin'] != 'legacy' ||
        Uuid.isValidUUID(fromString: order)) {
      return conflict;
    }
    final id = reservations.single['attemptId'];
    _Row? original;
    var linked = false;
    for (final source in sources) {
      final rows = await db.rawQuery(
          'SELECT * FROM $source.attempt WHERE id=? OR wireToken=?',
          [id, order]);
      final charges = await db.rawQuery(
          'SELECT * FROM $source.purchase WHERE attemptId=? OR token=?',
          [id, order]);
      if (rows.isEmpty && charges.isEmpty) continue;
      final header = (await db.rawQuery('SELECT * FROM $source.meta')).single;
      if (rows.length > 1 ||
          _disagrees(header['appId'], proof['appId']) ||
          _disagrees(header['environment'], proof['environment'])) {
        return conflict;
      }
      final version = (await db.rawQuery('PRAGMA $source.user_version'))
          .single
          .values
          .single as int;
      for (final p in charges) {
        if (_chargeOnHold(p) ||
            p['originalId'] != null ||
            source != 'main' &&
                p['disposition'] != null &&
                p['disposition'] != 'legacyHandedOff' ||
            _disagrees(p['appId'], proof['appId']) ||
            _disagrees(p['token'], order) ||
            _disagrees(p['attemptId'], id) ||
            _disagrees(p['reportedId'], proof['transactionId']) ||
            _disagrees(p['verifiedId'], proof['transactionId']) ||
            _disagrees(p['environment'], proof['environment']) ||
            _disagrees(p['scope'], proof['scope']) ||
            _disagrees(p['orderId'], order) ||
            p['productId'] != proof['productId']) {
          return conflict;
        }
        // This historical callback receipt remains positive submission
        // evidence after an authenticated delivery or refund is recorded.
        final recordedHandoff = version >= 3 &&
            (await db.rawQuery(
                    'SELECT 1 FROM $source.legacy_handoff WHERE purchaseId=? '
                    'AND attemptId=? AND length(hash)>0 LIMIT 1',
                    [p['id'], id]))
                .isNotEmpty;
        if (recordedHandoff || p['disposition'] == 'legacyHandedOff') {
          if (!recordedHandoff ||
              p['attemptId'] != id ||
              p['orderId'] != order ||
              p['reportedId'] != proof['transactionId'] ||
              p['token'] != order) {
            return conflict;
          }
          linked = true;
        } else if (version >= 3 && p['attemptId'] == id && !linked) {
          // A replay linked by an earlier recovery is not independent evidence
          // of a local launch. Only use a queue item recorded at purchase time.
          final native = await db.rawQuery(
              "SELECT 1 FROM recovery.legacy_payment_origin WHERE attemptId=? AND reportedId=? "
              "UNION ALL SELECT 1 FROM $source.queue_item WHERE purchaseId=? AND attemptId=? "
              "AND productId=? AND reportedId=? AND token=? AND status='paid' "
              "AND observation IS NULL LIMIT 1",
              [
                id,
                proof['transactionId'],
                p['id'],
                id,
                proof['productId'],
                proof['transactionId'],
                order
              ]);
          linked = native.isNotEmpty;
        }
      }
      if (rows.isEmpty) continue;
      final a = rows.single;
      if (a['id'] != id ||
          a['mode'] != 'legacy' ||
          a['legacySubmission'] != 'accepted' ||
          a['wireToken'] != order ||
          a['orderId'] != order ||
          a['productId'] != proof['productId'] ||
          a['submittedId'] != null ||
          !const {'accepted', 'pending', 'paid'}.contains(a['phase']) ||
          a['reason'] != null &&
              a['reason'] != 'serverPending' &&
              !(a['phase'] == 'pending' && a['reason'] == 'store_pending')) {
        return conflict;
      }
      final decisions = await db.rawQuery(
          'SELECT result,payload FROM $source.decision WHERE attemptId=?',
          [id]);
      if (decisions.any((d) =>
          d['result'] == 'conflict' ||
          (jsonDecode(d['payload'] as String) as List)[2] != proof['scope'])) {
        return conflict;
      }
      original ??= a;
    }
    return (conflict: original == null, attempt: linked ? original : null);
  }

  Future<bool> _legacyQueueHistoryConflicts(
      DatabaseExecutor db, _Row proof, Object? expectedWire) async {
    final transaction = proof['transactionId'];
    // A trusted original may carry a UUID even when the replay carries no
    // token. An incompatible identity for the same Apple charge still matters.
    final originals =
        await db.rawQuery('''SELECT 1 FROM recovery.original_submission s
      JOIN recovery.observation o ON o.id=?
      WHERE s.appId=? AND s.environment=? AND s.verifiedId=? AND
        (s.scope!=? OR s.orderId!=? OR s.productId!=? OR s.reportedId!=? OR
         (o.token IS NOT NULL AND s.token!=o.token)) LIMIT 1''', [
      proof['observation'],
      proof['appId'],
      proof['environment'],
      transaction,
      proof['scope'],
      proof['orderId'],
      proof['productId'],
      transaction
    ]);
    if (originals.isNotEmpty) return true;
    // Verified sources belong to their exact object and environment. A
    // different object's disputed source cannot veto a fresh verified line.
    final conflict = await db.rawQuery('''SELECT 1 FROM recovery.observation o
      WHERE (reportedId=? OR queueId=?)
      AND (o.id=? OR NOT EXISTS(SELECT 1 FROM recovery.verified_queue_transaction v
        WHERE v.observation=o.id AND (v.environment!=? OR o.reason='queueProofConflict')))
      AND (status NOT IN ('pending','paid') OR originalId IS NOT NULL
        OR reportedId!=? OR queueId!=? OR productId!=? OR token!=?
        OR actual!=? OR boundEnvironment!=? OR verifiedId!=?
        OR reason IN ('identityConflict','environmentConflict','environmentRejected',
          'originalSubmissionConflict','compatibilityTransferred'))
      LIMIT 1''', [
      transaction,
      transaction,
      proof['observation'],
      proof['environment'],
      transaction,
      transaction,
      proof['productId'],
      expectedWire,
      proof['environment'],
      proof['environment'],
      transaction
    ]);
    return conflict.isNotEmpty;
  }

  Future<AppleRecoveryResult> _recoverObservation(
      AppleClaim c,
      AppleOriginalSubmission? original,
      AppleVerifiedQueueTransaction? queueProof) async {
    final id = c.observationId;
    final foreignSource = queueProof != null && c.environment != _environment;
    if (!_validClaim(c, allowOtherEnvironment: foreignSource) ||
        original != null && queueProof != null ||
        id == null ||
        id.trim().isEmpty ||
        c.disposition != null && !_matchesClaim(c, c.disposition!)) {
      throw StateError('Invalid Apple observation claim');
    }
    final affected = <String>{};
    final (result, rejection) = await _journal.recover((db, sources) async {
      // Native-object evidence and a financial claim have different rejection
      // criteria. Roll back partial object writes, retaining the authenticated
      // financial fact in this same serialization window.
      await db.execute('SAVEPOINT apple_observation');
      try {
        final result = await _recoverSelected(
            db, sources, id, c, original, queueProof, affected);
        return (result, null);
      } on _AppleObservationRejected catch (error) {
        if (c.review != null) rethrow;
        await db.execute('ROLLBACK TO apple_observation');
        affected.clear();
        if (error.opposingProof case final proof?) {
          final observation = proof['observation'];
          await db.rawUpdate(
              'UPDATE recovery.verified_queue_transaction SET opposingProof=coalesce(opposingProof,?) WHERE observation=?',
              [jsonEncode(proof), observation]);
          await db.update(
              'recovery.observation', {'reason': 'queueProofConflict'},
              where: 'id=?', whereArgs: [observation]);
        }
        if (!foreignSource) {
          await _recordFinancialClaim(
              db, c, await _verifiedCharge(db, c), affected);
        }
        return (null, error);
      } finally {
        await db.execute('RELEASE apple_observation');
      }
    }, legacyOrderId: queueProof == null || foreignSource ? null : c.orderId);
    _changed();
    for (final purchaseId in affected) {
      _schedule(purchaseId);
    }
    if (rejection != null) {
      throw AppleObservationRejected(id, rejection.message);
    }
    return result!;
  }

  Future<AppleRecoveryResult> _recoverSelected(
      DatabaseExecutor db,
      List<String> sources,
      String id,
      AppleClaim c,
      AppleOriginalSubmission? original,
      AppleVerifiedQueueTransaction? queueProof,
      Set<String> affected) async {
    var r = await _row(db, 'recovery.observation', id);
    if (r == null) throw _AppleObservationRejected('Unknown Apple observation');
    if (queueProof != null && c.environment != _environment) {
      if (r['status'] != 'paid' ||
          r['productId'] != c.productId ||
          r['reportedId'] != c.reportedTransactionId) {
        throw _AppleObservationRejected(
            'Foreign Apple proof does not match its observation');
      }
      await _acceptVerifiedQueueTransaction(
          db, c, r, null, queueProof, sources);
      await db.insert('recovery.observation_review', {'observation': id},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return AppleRecoveryResult(
          observationId: id,
          state: AppleObservationState.awaitingReplay,
          reason: 'verifiedOutsideActiveEnvironment');
    }
    if (queueProof == null &&
        (await db.rawQuery(
                'SELECT 1 FROM recovery.verified_queue_transaction WHERE observation=? AND environment!=?',
                [id, c.environment]))
            .isNotEmpty) {
      throw _AppleObservationRejected(
          'Apple observation has a different verified environment');
    }
    if (r['status'] != 'paid' ||
        r['productId'] != c.productId ||
        r['reportedId'] != c.reportedTransactionId ||
        _disagrees(r['actual'], c.environment) ||
        _disagrees(r['boundEnvironment'], c.environment) ||
        _disagrees(r['verifiedId'], c.verifiedTransactionId) ||
        _disagrees(r['token'], _wire(c.purchaseToken)) ||
        const {
          'identityConflict',
          'queueProofConflict',
          'environmentRejected',
          'environmentConflict',
          'compatibilityTransferred'
        }.contains(r['reason'])) {
      throw _AppleObservationRejected(
          'Apple recovery observation does not match the authenticated claim');
    }
    if (r['boundPurchase'] case final String bound) {
      final assigned =
          await _row(db, 'purchase', await _canonicalPurchaseId(db, bound));
      if (assigned == null ||
          _disagrees(assigned['verifiedId'], c.verifiedTransactionId)) {
        throw _AppleObservationRejected(
            'Apple observation already bound to a different charge');
      }
    }
    if (original != null) {
      await _saveOriginal(db, c, original);
      r = (await _row(db, 'recovery.observation', id))!;
    }
    await db.insert('recovery.observation_review', {'observation': id},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    var purchase = await _verifiedCharge(db, c);
    final ruling = c.review;
    if (ruling != null) {
      final reviewed = await _row(db, 'purchase', ruling.disputeId);
      if (reviewed == null ||
          _disagrees(purchase?['id'], reviewed['id']) ||
          _disagrees(reviewed['appId'], c.appId) ||
          _disagrees(reviewed['environment'], c.environment)) {
        throw StateError('Unknown Apple review target');
      }
      purchase = reviewed;
    }
    final recoveredAttempt = queueProof == null
        ? null
        : await _acceptVerifiedQueueTransaction(
            db, c, r, purchase, queueProof, sources);
    final proven = queueProof != null || await _sourceForObservation(db, c, r);
    if (proven) {
      final byReport = await _reportedPurchase(db, c.reportedTransactionId);
      if (byReport != null &&
          _disagrees(byReport['verifiedId'], c.verifiedTransactionId)) {
        throw _AppleObservationRejected(
            'Reported Apple identity already bound to a different verified charge');
      }
      final applied = await _applyClaim(db, c,
          exactObservation: r,
          affected: affected,
          decidedAttempt: recoveredAttempt);
      if (applied != null &&
          recoveredAttempt != null &&
          (await _row(db, 'purchase', applied))?['attemptId'] !=
              recoveredAttempt['id']) {
        throw StateError('Apple claim has no confirmed submission binding');
      }
    } else {
      await _recordFinancialClaim(db, c, purchase, affected);
    }
    purchase = await _verifiedCharge(db, c);
    final current = (await _row(db, 'recovery.observation', id))!;
    final linked = purchase != null &&
        current['boundEnvironment'] == c.environment &&
        current['boundPurchase'] != null &&
        await _canonicalPurchaseId(db, current['boundPurchase'] as String) ==
            purchase['id'];
    final outcome = purchase?['disposition'] as String?;
    final financialDisposition =
        outcome == 'delivered' || outcome == 'refunded' ? outcome : null;
    final AppleObservationState status;
    if (purchase?['conflict'] == 1 ||
        current['reason'] == 'originalSubmissionConflict') {
      status = AppleObservationState.disputed;
    } else if (!linked) {
      status = AppleObservationState.sourceUnproven;
    } else if (current['finished'] == 1) {
      status = AppleObservationState.removed;
    } else if (current['generation'] != _generation ||
        !_currentUnbound.containsKey(id)) {
      status = AppleObservationState.awaitingReplay;
    } else if (financialDisposition == null) {
      status = AppleObservationState.awaitingDisposition;
    } else {
      status = AppleObservationState.awaitingRemoval;
    }
    if (proven && purchase != null) affected.add(purchase['id'] as String);
    return AppleRecoveryResult(
        observationId: id,
        state: status,
        scope: purchase?['scope'] as String?,
        orderId: purchase?['orderId'] as String?,
        verifiedTransactionId: purchase?['verifiedId'] as String?,
        disposition: financialDisposition,
        reference: financialDisposition == null
            ? null
            : purchase?['ackRef'] as String?,
        reason: current['reason'] == 'originalSubmissionConflict'
            ? 'originalSubmissionConflict'
            : purchase?['reason'] as String? ?? status.name);
  }

  // The Apple identity selects the financial record. No device alias, attempt
  // or queue item can be discovered or created by this branch.
  Future<void> _recordFinancialClaim(DatabaseExecutor db, AppleClaim c,
      _Row? existing, Set<String> affected) async {
    var p = existing;
    if (c.review != null) {
      if (p == null || c.disposition != null) {
        throw StateError('Invalid Apple review');
      }
      final resolved =
          await _reviewDispute(db, p, p, c, affected, authorizeItems: false);
      if (resolved != null) affected.add(resolved);
      return;
    }
    if (p == null) {
      final id = const Uuid().v4();
      await db.insert('purchase', {
        'id': id,
        'scope': c.scope,
        'orderId': c.orderId,
        'productId': c.productId,
        'appId': c.appId,
        'environment': c.environment,
        'verifiedId': c.verifiedTransactionId,
        'claimRef': c.reference
      });
      p = (await _row(db, 'purchase', id))!;
    }
    final prior = (await db.query('claim_fact',
            where: 'purchaseId=? AND payload=?',
            whereArgs: [p['id'], _claimPayload(c)]))
        .firstOrNull;
    final ack = c.disposition;
    if (prior?['covered'] != 1) {
      await _saveClaim(db, p, c);
      final otherSku = await db.rawQuery(
          '''SELECT 1 FROM purchase WHERE scope=? AND orderId=? AND productId!=?
        UNION ALL SELECT 1 FROM attempt WHERE scope=? AND orderId=? AND productId!=? LIMIT 1''',
          [c.scope, c.orderId, c.productId, c.scope, c.orderId, c.productId]);
      if (p['productId'] != c.productId ||
          p['scope'] != c.scope ||
          p['orderId'] != c.orderId ||
          otherSku.isNotEmpty) {
        await _openDispute(db, p, 'ownershipConflict', _claimPayload(c));
        if (ack != null && await _saveDisposition(db, p, ack)) {
          await _openDispute(db, p, 'dispositionConflict', _ackPayload(ack));
        }
        return;
      }
      if (p['claimRef'] == null) {
        await db.update('purchase', {'claimRef': c.reference},
            where: 'id=?', whereArgs: [p['id']]);
      }
      await _reservePrimary(db, c.scope, c.orderId, p['id'] as String);
    }
    if (ack != null) {
      final changed = await _recordDisposition(db, p, ack);
      if (changed != null) affected.add(changed);
    }
  }
}
