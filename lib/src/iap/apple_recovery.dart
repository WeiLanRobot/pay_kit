part of 'apple_payments.dart';

extension _AppleRecovery on ApplePayments {
  Future<_Row?> _verifiedCharge(DatabaseExecutor db, AppleClaim c) async =>
      (await db.query('purchase',
              where: 'appId=? AND environment=? AND verifiedId=?',
              whereArgs: [c.appId, c.environment, c.verifiedTransactionId]))
          .firstOrNull;

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
      throw StateError(
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
        Uuid.isValidUUID(fromString: r['token'] as String? ?? '') ||
        _chargeOnHold(purchase) ||
        _disagrees(purchase?['scope'], c.scope) ||
        _disagrees(purchase?['orderId'], c.orderId) ||
        _disagrees(purchase?['productId'], c.productId) ||
        c.disposition == null &&
            !const {'delivered', 'refunded'}
                .contains(purchase?['disposition'])) {
      throw StateError('Verified Apple transaction does not match the order');
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
    if (prior.isNotEmpty &&
        (prior.length != 1 ||
            !record.entries.every((e) => prior.single[e.key] == e.value))) {
      throw StateError('Apple observation proof already used');
    }
    if (r['reason'] != 'sourceUnproven') {
      throw StateError(
          'Apple observation requires existing dispute resolution');
    }
    if (prior.isNotEmpty && r['finished'] == 1) return null;
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
        !_onlyLiveQueueObject(event)) {
      throw StateError(
          'Verified Apple transaction requires its current queue object');
    }
    final candidate = await db.rawQuery(
        'SELECT 1 FROM recovery.candidate WHERE observation=? AND hash=? LIMIT 1',
        [id, proof.receiptHash]);
    if (candidate.isEmpty) {
      throw StateError('Verified receipt does not belong to this observation');
    }
    final submission = await _inspectLegacySubmission(db, record, sources);
    if (submission.conflict || await _legacyQueueHistoryConflicts(db, record)) {
      throw StateError('Conflicting Apple transaction source');
    }
    final attempt = submission.attempt;
    // The verified charge and the device alias may already name a different
    // submission even when neither carries the legacy wire string.
    final reported = await _reportedPurchase(db, c.reportedTransactionId);
    for (final charge in [purchase, reported].nonNulls) {
      if (_disagrees(charge['token'], c.orderId) ||
          charge['attemptId'] != null &&
              charge['attemptId'] != attempt?['id']) {
        throw StateError('Conflicting Apple transaction source');
      }
    }
    if (attempt != null && await _row(db, 'attempt', attempt['id']) == null) {
      // The compatibility partition can be the only copy after a cold start.
      await db.insert('attempt', attempt);
    }
    if (prior.isEmpty) {
      await db.insert('recovery.verified_queue_transaction', record);
    }
    return attempt;
  }

  // A reservation records intent. Only its original, accepted BuyEngine
  // submission may be bound by an independently verified queue transaction.
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
      for (final p in charges) {
        if (_chargeOnHold(p) ||
            p['originalId'] != null ||
            source != 'main' && p['disposition'] != null ||
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
    return (conflict: original == null, attempt: original);
  }

  Future<bool> _legacyQueueHistoryConflicts(
      DatabaseExecutor db, _Row proof) async {
    final transaction = proof['transactionId'];
    final conflict = await db.rawQuery('''SELECT 1 FROM recovery.observation
      WHERE (reportedId=? OR queueId=?)
      AND (status NOT IN ('pending','paid') OR originalId IS NOT NULL
        OR reportedId!=? OR queueId!=? OR productId!=? OR token!=?
        OR actual!=? OR boundEnvironment!=? OR verifiedId!=?
        OR reason IN ('identityConflict','environmentConflict','environmentRejected',
          'originalSubmissionConflict','compatibilityTransferred'))
      LIMIT 1''', [
      transaction,
      transaction,
      transaction,
      transaction,
      proof['productId'],
      proof['orderId'],
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
    if (!_validClaim(c) ||
        original != null && queueProof != null ||
        id == null ||
        id.trim().isEmpty ||
        c.disposition != null && !_matchesClaim(c, c.disposition!)) {
      throw StateError('Invalid Apple observation claim');
    }
    final affected = <String>{};
    final state = await _journal.recover((db, sources) async {
      var r = await _row(db, 'recovery.observation', id);
      if (r == null) throw StateError('Unknown Apple observation');
      if (r['status'] != 'paid' ||
          r['productId'] != c.productId ||
          r['reportedId'] != c.reportedTransactionId ||
          _disagrees(r['actual'], c.environment) ||
          _disagrees(r['boundEnvironment'], c.environment) ||
          _disagrees(r['verifiedId'], c.verifiedTransactionId) ||
          _disagrees(r['token'], _wire(c.purchaseToken)) ||
          const {
            'identityConflict',
            'environmentRejected',
            'environmentConflict',
            'compatibilityTransferred'
          }.contains(r['reason'])) {
        throw StateError(
            'Apple recovery observation does not match the authenticated claim');
      }
      if (r['boundPurchase'] case final String bound) {
        final assigned =
            await _row(db, 'purchase', await _canonicalPurchaseId(db, bound));
        if (assigned == null ||
            _disagrees(assigned['verifiedId'], c.verifiedTransactionId)) {
          throw StateError(
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
      final proven =
          queueProof != null || await _sourceForObservation(db, c, r);
      if (proven) {
        final byReport = await _reportedPurchase(db, c.reportedTransactionId);
        if (byReport != null &&
            _disagrees(byReport['verifiedId'], c.verifiedTransactionId)) {
          throw StateError(
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
      } else if (c.disposition != null ||
          purchase?['disposition'] != null ||
          c.review != null && purchase != null) {
        await _recordFinancialClaim(db, c, purchase, affected);
      }
      purchase = await _verifiedCharge(db, c);
      final current = (await _row(db, 'recovery.observation', id))!;
      final linked = purchase != null &&
          current['boundEnvironment'] == c.environment &&
          current['boundPurchase'] != null &&
          await _canonicalPurchaseId(db, current['boundPurchase'] as String) ==
              purchase['id'];
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
      } else if (purchase['disposition'] == null) {
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
          disposition: purchase?['disposition'] as String?,
          reference: purchase?['ackRef'] as String?,
          reason: status == AppleObservationState.sourceUnproven &&
                  purchase?['disposition'] == null
              ? 'dispositionOrSourceRequired'
              : current['reason'] == 'originalSubmissionConflict'
                  ? 'originalSubmissionConflict'
                  : purchase?['reason'] as String? ?? status.name);
    }, legacyOrderId: queueProof == null ? null : c.orderId);
    _changed();
    for (final id in affected) {
      _schedule(id);
    }
    return state;
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
      await _reviewDispute(db, p, p, c, affected, authorizeItems: false);
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
    if (ack != null) await _recordDisposition(db, p, ack);
  }
}
