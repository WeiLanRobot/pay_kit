part of 'apple_payments.dart';

extension _AppleEnvironment on ApplePayments {
  String _objectKey(StoreEvent e) =>
      _handleKey(e) ??
      (_present(e.queueId) != null
          ? 'queue:${e.queueId}'
          : _observationIds[e] ??= 'object:${const Uuid().v4()}');

  Future<void> _saveCandidate(DatabaseExecutor db, String id, String body,
      String source, String context) async {
    if (body.isEmpty) return;
    final hash = sha256.convert(utf8.encode(body)).toString();
    await db.rawInsert(
        'INSERT OR IGNORE INTO recovery.body VALUES (?,?)', [hash, body]);
    await db.rawInsert(
        'INSERT OR IGNORE INTO recovery.candidate VALUES (?,?,?,?)',
        [id, hash, source, context]);
  }

  // A failed object can identify a previously accepted scoped submission even
  // after process restart. Releasing the order needs stronger evidence than
  // merely removing this object from the StoreKit queue.
  Future<bool> _canRecoverFailure(
      DatabaseExecutor db, StoreEvent e, _Row a) async {
    if (!_configured ||
        a['mode'] != 'scoped' ||
        a['submittedId'] != null ||
        a['id'] != _wire(e.token) ||
        !const {'accepted', 'pending', 'failed', 'canceled'}
            .contains(a['phase'])) {
      return false;
    }
    final reservations = await db.query('recovery.submission',
        where: 'token=?', whereArgs: [a['id']], limit: 2);
    if (reservations.length != 1 ||
        reservations.single['origin'] != _environment ||
        reservations.single['attemptId'] != a['id']) {
      return false;
    }
    final contradictory = await db.rawQuery('''
      SELECT 1 FROM purchase WHERE attemptId=? OR token=?
      UNION ALL SELECT 1 FROM recovery.observation WHERE
        (token=? AND (status='paid' OR reason='identityConflict')) OR
        (generation=? AND objectKey=? AND
          (reason='identityConflict' OR productId!=? OR
           (token IS NOT NULL AND token!=?) OR
           (reportedId IS NOT NULL AND reportedId!=?) OR
           (status!='pending' AND status!=?)))
      LIMIT 1''', [
      a['id'],
      a['id'],
      a['id'],
      _generation,
      _objectKey(e),
      e.productId,
      a['id'],
      _present(e.transactionId),
      e.status.name
    ]);
    return contradictory.isEmpty;
  }

  /// An observation without a submission from this process has application,
  /// but no store environment, provenance. Keep it out of partition aliases.
  Future<bool> _routeObservation(StoreEvent e) async {
    final object = _objectKey(e);
    if (_observedHere.contains(object)) return true;
    final result = await _journal.write((db) async {
      final a = await _observedAttempt(db, e.token, null);
      if (a != null && _submittedHere.contains(a['id'])) {
        return (owned: true, id: '', finished: false, ownsFailure: false);
      }
      final terminalFailure =
          e.status == StoreStatus.canceled || e.status == StoreStatus.failed;
      final recordedQueue = terminalFailure && _present(e.queueId) != null
          ? (await db.query('queue_item',
                  where:
                      'storeQueueId=? AND productId=? AND attemptId IS NOT NULL',
                  whereArgs: [e.queueId, e.productId]))
              .firstOrNull
          : null;
      final ownsFailure = terminalFailure &&
          (e.allowsUnownedFinish ||
              a != null &&
                  a['productId'] == e.productId &&
                  Uuid.isValidUUID(fromString: _wire(e.token) ?? '') ||
              recordedQueue != null);
      final context = _configured ? _environment! : 'compat';
      final priorCharge =
          await _reportedPurchase(db, _present(e.transactionId));
      final previous = (await db.rawQuery(
              'SELECT * FROM recovery.observation WHERE generation=? AND objectKey=?',
              [_generation, object]))
          .firstOrNull;
      final id = previous?['id'] as String? ?? const Uuid().v4();
      if (previous == null) {
        await db.rawInsert('''INSERT INTO recovery.observation
          (id,generation,objectKey,productId,token,reportedId,originalId,queueId,status,observedContext,reason,priorIdentity)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''', [
          id,
          _generation,
          object,
          e.productId,
          _wire(e.token),
          _present(e.transactionId),
          _present(e.originalTransactionId),
          _present(e.queueId),
          e.status.name,
          context,
          'sourceUnproven',
          priorCharge == null ? 0 : 1
        ]);
      } else {
        if (previous['status'] == 'paid' && e.status != StoreStatus.paid ||
            (previous['status'] == 'failed' ||
                    previous['status'] == 'canceled') &&
                previous['status'] != e.status.name ||
            previous['productId'] != e.productId ||
            _disagrees(previous['token'], _wire(e.token)) ||
            _disagrees(previous['reportedId'], _present(e.transactionId))) {
          await db.rawUpdate(
              "UPDATE recovery.observation SET reason='identityConflict' WHERE id=?",
              [id]);
          return (owned: false, id: id, finished: true, ownsFailure: false);
        }
        if (previous['boundEnvironment'] == _environment &&
            previous['boundPurchase'] != null &&
            previous['reason'] != 'identityConflict' &&
            _currentUnbound.containsKey(id)) {
          return (owned: true, id: id, finished: false, ownsFailure: false);
        }
        await db.rawUpdate(
            '''UPDATE recovery.observation SET token=coalesce(token,?),
          reportedId=coalesce(reportedId,?),originalId=coalesce(originalId,?),
          queueId=coalesce(queueId,?),status=? WHERE id=?''',
            [
              _wire(e.token),
              _present(e.transactionId),
              _present(e.originalTransactionId),
              _present(e.queueId),
              e.status.name,
              id
            ]);
      }
      if (terminalFailure && previous?['reason'] != 'identityConflict') {
        await db.update('recovery.observation',
            {'reason': ownsFailure ? 'ownedFailure' : 'sourceUnproven'},
            where: 'id=?', whereArgs: [id]);
      }
      await _saveCandidate(db, id, e.receipt, 'store', context);
      return (
        owned: false,
        id: id,
        finished: previous?['finished'] == 1 ||
            previous?['reason'] == 'identityConflict',
        ownsFailure: ownsFailure
      );
    });
    if (result.owned) {
      _observedHere.add(object);
      return true;
    }
    if (result.finished) {
      _currentUnbound.remove(result.id);
      return false;
    }
    _currentUnbound[result.id] = e;
    if (result.ownsFailure &&
        (e.status == StoreStatus.failed || e.status == StoreStatus.canceled)) {
      _background(_finishUnbound(result.id));
    }
    _changed();
    return false;
  }

  Future<void> _finishUnbound(String id) async {
    final key = 'unbound/$id';
    if (_closingItems.containsKey(key)) return;
    final work = () async {
      final authorized = await _journal.write((db) async {
        final e = _currentUnbound[id];
        if (!_ready || _closed || e == null) return null;
        final permitted = await db.rawQuery(
            """SELECT 1 FROM recovery.observation WHERE id=? AND generation=?
               AND objectKey=? AND status=? AND status IN ('canceled','failed')
               AND finished=0 AND reason='ownedFailure'""",
            [id, _generation, _objectKey(e), e.status.name]);
        if (permitted.isEmpty) return null;
        await _recordFinishAuthority(db, e, itemId: id);
        return e;
      });
      // A replay can replace the Dart wrapper for the same native object.
      final e = _currentUnbound[id];
      if (!_ready || _closed || e == null || authorized == null) return;
      if (!_sameFinishObject(e, authorized)) {
        throw StateError('StoreKit finish observation changed');
      }
      if (e.needsFinish) await _store.finish(e);
      await _journal.write((db) => db.rawUpdate(
          'UPDATE recovery.observation SET finished=1 WHERE id=? AND status=?',
          [id, e.status.name]));
      _currentUnbound.remove(id);
      _timers.remove(key)?.cancel();
      _delays.remove(key);
      _changed();
    }()
        .catchError((Object error) {
      _report(error);
      _defer(key, () => _finishUnbound(id));
    }).whenComplete(() {
      _closingItems.remove(key);
    });
    _closingItems[key] = work;
    await work;
  }

  AppleEnvironmentMismatch _decodeEnvironmentProof(String payload) {
    final proof = jsonDecode(payload) as List;
    return AppleEnvironmentMismatch(
        issuer: proof[0] as String,
        reference: proof[1] as String,
        appId: proof[2] as String,
        expectedEnvironment: proof[3] as String,
        actualEnvironment: proof[4] as String,
        verifiedTransactionId: proof[5] as String,
        reportedTransactionId: proof[6] as String,
        productId: proof[7] as String,
        purchaseToken: proof[8] as String?);
  }

  Future<Map<String, AppleEnvironmentMismatch>> _disputedEnvironmentProofs(
      DatabaseExecutor db, String purchaseId) async {
    final rows = await db.rawQuery(
        """SELECT id,proof FROM recovery.observation WHERE
      originPurchase=? AND observedContext=? AND originLinked=1 AND reason='environmentConflict'""",
        [purchaseId, _environment]);
    return Map.unmodifiable({
      for (final row in rows)
        row['id'] as String: _decodeEnvironmentProof(row['proof'] as String)
    });
  }

  Future<List<AppleTransaction>> _unboundTransactions(
      DatabaseExecutor db) async {
    final rows = await db.rawQuery('''SELECT * FROM recovery.observation
      WHERE status='paid' AND boundEnvironment IS NULL AND (actual IS NULL OR actual=?)
      AND reason!='environmentRejected' ORDER BY rowid''', [_environment]);
    final groups = <(String?, String, String?), List<_Row>>{};
    for (final row in rows) {
      final key = (
        row['reportedId'] == null ? null : row['id'] as String,
        row['productId'] as String,
        row['token'] as String?
      );
      if ((await _row(db, 'purchase', row['id']))?['conflict'] == 1) continue;
      (groups[key] ??= []).add(row);
    }
    final result = <AppleTransaction>[];
    for (final group in groups.values) {
      final observations = <String, List<String>>{};
      for (final row in group) {
        final candidates = await db.rawQuery(
            '''SELECT DISTINCT b.body FROM recovery.candidate c
          JOIN recovery.body b ON b.hash=c.hash WHERE c.observation=? ORDER BY c.rowid''',
            [row['id']]);
        observations[row['id'] as String] =
            List.unmodifiable(candidates.map((r) => r['body'] as String));
      }
      final r = group.first;
      final proof = r['proof'] as String?;
      result.add(AppleTransaction(
          environmentProof:
              proof == null ? null : _decodeEnvironmentProof(proof),
          id: r['id'] as String,
          productId: r['productId'] as String,
          transactionId: r['reportedId'] as String?,
          purchaseToken: r['token'] as String?,
          receipts: List.unmodifiable(
              observations.values.expand((values) => values).toSet()),
          observations: Map.unmodifiable(observations),
          reason: r['reason'] as String?));
    }
    return result;
  }

  Future<Set<String>> _captureUnboundRefresh(DatabaseExecutor db) async =>
      (await db.rawQuery(
              """SELECT id FROM recovery.observation WHERE status='paid'
        AND boundEnvironment IS NULL AND (actual IS NULL OR actual=?)""",
              [_environment]))
          .map((r) => r['id'] as String)
          .toSet();

  Future<Set<String>> _refreshUnbound(
      DatabaseExecutor db, String receipt, Set<String> initial) async {
    final targets = await db.rawQuery(
        """SELECT * FROM recovery.observation WHERE status='paid'
      AND (actual IS NULL OR actual=?) AND (boundEnvironment IS NULL OR boundEnvironment=?)""",
        [_environment, _environment]);
    final imported = <String>{};
    for (final r in targets) {
      final id = r['id'] as String;
      if (!initial.contains(id)) {
        if (r['generation'] != _generation ||
            r['boundEnvironment'] != null ||
            (await db.rawQuery(
                    'SELECT 1 FROM recovery.candidate WHERE observation=? LIMIT 1',
                    [id]))
                .isNotEmpty) {
          continue;
        }
      }
      if (r['boundPurchase'] case final String bound) {
        imported.add(await _canonicalPurchaseId(db, bound));
      } else {
        await _saveCandidate(db, id, receipt, 'refresh', _environment!);
      }
    }
    return imported;
  }

  Future<List<_Row>> _claimObservations(
      DatabaseExecutor db, AppleClaim c) async {
    final rows = await db
        .rawQuery("""SELECT * FROM recovery.observation WHERE reportedId=?
      AND productId=? AND status='paid' AND reason NOT IN ('identityConflict','environmentRejected','environmentConflict','compatibilityTransferred')
      AND (actual IS NULL OR actual=?) AND (verifiedId IS NULL OR verifiedId=?)
      AND (boundEnvironment IS NULL OR boundEnvironment=?)
      AND NOT EXISTS(SELECT 1 FROM recovery.submission s WHERE s.token=observation.token
        GROUP BY s.token HAVING count(*)>1)
      AND NOT EXISTS(SELECT 1 FROM recovery.observation legacy
        WHERE legacy.generation='compatibility' AND legacy.reason!='compatibilityTransferred'
          AND legacy.token=observation.token AND legacy.reportedId=observation.reportedId
          AND legacy.productId=observation.productId AND legacy.actual!=?)
      ORDER BY (generation='compatibility') DESC, rowid""", [
      c.reportedTransactionId,
      c.productId,
      c.environment,
      c.verifiedTransactionId,
      c.environment,
      c.environment
    ]);
    final token = _wire(c.purchaseToken);
    if (token != null &&
        (await db.rawQuery(
                'SELECT 1 FROM recovery.submission WHERE token=? LIMIT 1 OFFSET 1',
                [token]))
            .isNotEmpty) {
      throw StateError('Ambiguous Apple submission token');
    }
    if (token != null &&
        (await db.rawQuery(
                """SELECT 1 FROM recovery.observation WHERE generation='compatibility'
          AND reason!='compatibilityTransferred'
          AND token=? AND reportedId=? AND productId=? AND actual IS NOT NULL AND actual!=?
          LIMIT 1""",
                [token, c.reportedTransactionId, c.productId, c.environment]))
            .isNotEmpty) {
      throw StateError('Conflicting legacy payment environment');
    }
    final candidates =
        rows.where((r) => !_disagrees(r['token'], token)).toList();
    if (c.observationId != null &&
        !candidates.any((r) => r['id'] == c.observationId)) {
      throw StateError(
          'Apple recovery observation does not match the authenticated claim');
    }
    if (candidates.length <= 1) return candidates;
    // Identical device IDs across observations are insufficient. A verified UUID
    // can independently identify a replay bearing that same token.
    return candidates
        .where((r) =>
            r['id'] == c.observationId && r['actual'] == c.environment ||
            token != null && r['token'] == token)
        .toList();
  }

  Future<void> _bindExactObservation(
      DatabaseExecutor db, StoreEvent e, String target) async {
    final old = (await db.rawQuery(
            """SELECT id FROM recovery.observation WHERE generation=?
        AND objectKey=? AND reason!='identityConflict' AND boundPurchase IS NULL""",
            [_generation, _objectKey(e)]))
        .firstOrNull;
    if (old == null) return;
    final candidates = await db.rawQuery(
        """SELECT b.body,c.source,c.context FROM recovery.candidate c
        JOIN recovery.body b ON b.hash=c.hash WHERE observation=? ORDER BY c.rowid""",
        [old['id']]);
    for (final r in candidates) {
      await _addEvidence(db, target, r['body'] as String,
          source: r['source'] as String, context: r['context'] as String);
    }
    await db.rawUpdate(
        'UPDATE recovery.observation SET boundEnvironment=?,boundPurchase=? WHERE id=?',
        [_configured ? _environment : 'compat', target, old['id']]);
  }

  Future<bool> _provesSource(
      DatabaseExecutor db, _Row purchase, AppleClaim c) async {
    final token = _wire(c.purchaseToken);
    if (token == null || _wire(purchase['token'] as String?) != token) {
      return false;
    }
    final attempt = await _attemptForToken(db, token);
    return attempt != null &&
        attempt['id'] == purchase['attemptId'] &&
        attempt['orderId'] == c.orderId &&
        attempt['productId'] == c.productId &&
        !_disagrees(attempt['scope'], c.scope);
  }

  Future<void> _bindObservation(DatabaseExecutor db, AppleClaim c) async {
    final frozen = await db.rawQuery(
        '''SELECT 1 FROM recovery.observation WHERE actual=? AND verifiedId=?
        AND (reason='environmentConflict' OR (reason='environmentRejected'
            AND (token=? OR ? IS NULL) AND NOT EXISTS (SELECT 1 FROM recovery.observation s
              WHERE s.reason='environmentSelected' AND s.actual=observation.actual
              AND s.verifiedId=observation.verifiedId AND s.token=observation.token))) LIMIT 1''',
        [
          c.environment,
          c.verifiedTransactionId,
          _wire(c.purchaseToken),
          _wire(c.purchaseToken)
        ]);
    if (frozen.isNotEmpty) {
      throw StateError('Conflicting Apple environment proof');
    }
    final candidates = await _claimObservations(db, c);
    if (candidates.any((row) => row['reason'] == 'environmentSelected')) {
      final existing = (await db.query('purchase',
              where: 'appId=? AND environment=? AND verifiedId=?',
              whereArgs: [c.appId, c.environment, c.verifiedTransactionId]))
          .firstOrNull;
      if (existing != null &&
          (existing['reportedId'] != c.reportedTransactionId ||
              existing['token'] != _wire(c.purchaseToken) ||
              existing['productId'] != c.productId ||
              _disagrees(existing['scope'], c.scope) ||
              _disagrees(existing['orderId'], c.orderId))) {
        throw StateError(
            'The destination already has an independent Apple charge');
      }
    }
    if (candidates.isEmpty ||
        await _reportedPurchase(db, c.reportedTransactionId) != null) {
      return;
    }
    final r = candidates.first;
    await db.insert('purchase', {
      'id': r['id'],
      'productId': c.productId,
      'reportedId': c.reportedTransactionId,
      'originalId': r['originalId'],
      'token': r['token']
    });
    final evidence = await db.rawQuery(
        '''SELECT b.body,c.source,c.context FROM recovery.body b
      JOIN recovery.candidate c ON b.hash=c.hash WHERE observation=? ORDER BY c.rowid''',
        [r['id']]);
    for (final item in evidence) {
      await _addEvidence(db, r['id'] as String, item['body'] as String,
          source: item['source'] as String, context: item['context'] as String);
    }
  }

  /// A signed claim can reuse one old receiver's completed handoff. A report
  /// or shared app receipt alone cannot select its submission or environment.
  Future<void> _restoreCompatibilityHandoff(
      DatabaseExecutor db, AppleClaim c, String target) async {
    final token = _wire(c.purchaseToken);
    if (token == null || !Uuid.isValidUUID(fromString: token)) return;
    final rows = await db.rawQuery(
        """SELECT h.* FROM recovery.compatibility_handoff h
      JOIN recovery.submission s ON s.attemptId=h.attemptId AND s.origin='legacy' AND s.token=?
      WHERE h.wire=? COLLATE NOCASE AND h.sku=? AND h.orderId=? AND h.reported=?""",
        [token, token, c.productId, c.orderId, c.reportedTransactionId]);
    if (rows.isEmpty) return;
    if (rows.length != 1) throw StateError('Ambiguous legacy receipt handoff');
    final h = rows.single;
    if (_disagrees(h['environment'], c.environment) ||
        _disagrees(h['scope'], c.scope) ||
        _disagrees(h['verified'], c.verifiedTransactionId)) {
      throw StateError('Conflicting legacy receipt handoff identity');
    }
    final p = (await _row(db, 'purchase', target))!;
    if (p['conflict'] == 1 ||
        _disagrees(p['attemptId'], h['attemptId']) ||
        _disagrees(p['token'], token) ||
        p['scope'] != c.scope ||
        p['orderId'] != c.orderId) {
      throw StateError('Legacy handoff does not match claimed purchase');
    }
    if (await _row(db, 'attempt', h['attemptId']) == null) {
      await db.insert('attempt', {
        'id': h['attemptId'],
        'wireToken': h['wire'],
        'orderId': h['orderId'],
        'productId': h['sku'],
        'mode': 'legacy',
        'phase': 'paid',
        'legacySubmission': 'accepted'
      });
    }
    await db.update(
        'purchase',
        {
          'attemptId': h['attemptId'],
          if (p['disposition'] == null) 'disposition': 'legacyHandedOff'
        },
        where: 'id=?',
        whereArgs: [target]);
    await db.insert('legacy_handoff',
        {'purchaseId': target, 'attemptId': h['attemptId'], 'hash': h['hash']},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.rawUpdate(
        'UPDATE recovery.compatibility_handoff SET environment=?,scope=?,verified=? WHERE purchaseId=?',
        [c.environment, c.scope, c.verifiedTransactionId, h['purchaseId']]);
  }

  Future<void> _authorizeObservation(
      DatabaseExecutor db, AppleClaim c, String target) async {
    final candidates = await _claimObservations(db, c);
    await _restoreCompatibilityHandoff(db, c, target);
    final p = (await _row(db, 'purchase', target))!;
    final token = _wire(c.purchaseToken);
    for (final r in candidates) {
      if (_disagrees(r['boundPurchase'], target) &&
          await _canonicalPurchaseId(db, r['boundPurchase'] as String) !=
              target) {
        continue;
      }
      // A signed UUID naming the archived accepted submission can later
      // authorize an exact object, once the service has proved its source.
      if (r['generation'] == 'compatibility') {
        final linked = r['reason'] == 'legacySubmissionObserved' &&
            token != null &&
            r['token'] == token &&
            _wire(c.orderId) == token &&
            Uuid.isValidUUID(fromString: token);
        await db.rawUpdate(
            '''UPDATE recovery.observation SET actual=?, verifiedId=?, originLinked=max(originLinked,?)
               WHERE id=?''',
            [c.environment, c.verifiedTransactionId, linked ? 1 : 0, r['id']]);
      }
      final a = await _attemptForToken(db, token);
      final signedReplay = token != null &&
          token == r['token'] &&
          a != null &&
          a['productId'] == c.productId &&
          a['id'] == p['attemptId'] &&
          a['orderId'] == c.orderId &&
          (a['scope'] == null || a['scope'] == c.scope);
      // An old receipt only authorizes a new object after fresh source proof.
      final originProof = token != null &&
          token == r['token'] &&
          (await db
                  .rawQuery('''SELECT 1 FROM recovery.observation WHERE actual=?
            AND verifiedId=? AND productId=? AND token=? AND originLinked=1
            AND (reason IN ('environmentMismatch','environmentSelected')
              OR (generation='compatibility' AND reason='legacySubmissionObserved' AND reportedId=?))
            LIMIT 1''', [
            c.environment,
            c.verifiedTransactionId,
            c.productId,
            token,
            c.reportedTransactionId
          ]))
              .isNotEmpty;
      final newAlias = r['priorIdentity'] == 0 &&
          r['generation'] == _generation &&
          c.reportedTransactionId != p['reportedId'] &&
          c.verifiedTransactionId == p['verifiedId'];
      if ((p['disposition'] != null || r['priorIdentity'] == 1) &&
          !signedReplay &&
          !originProof &&
          !newAlias &&
          r['boundEnvironment'] == null) {
        continue;
      }
      final id = r['id'] as String;
      final evidence = await db.rawQuery(
          '''SELECT b.body,c.source,c.context FROM recovery.body b
        JOIN recovery.candidate c ON b.hash=c.hash WHERE observation=? ORDER BY c.rowid''',
          [id]);
      for (final item in evidence) {
        await _addEvidence(db, target, item['body'] as String,
            source: item['source'] as String,
            context: item['context'] as String);
      }
      await db.rawUpdate(
          'UPDATE recovery.observation SET boundEnvironment=?, boundPurchase=? WHERE id=?',
          [c.environment, target, id]);
      final e = _currentUnbound[id];
      if (r['generation'] != _generation || e == null) continue;
      final key = await _queueKey(db, e);
      final prior = await _row(db, 'queue_item', key);
      if (prior == null) {
        await db.insert('queue_item', {
          'id': key,
          'purchaseId': target,
          'productId': c.productId,
          'reportedId': c.reportedTransactionId,
          'token': r['token'],
          'status': 'paid',
          'storeQueueId': r['queueId'],
          'attemptId': p['attemptId'],
          'observation': id
        });
      } else if (prior['purchaseId'] == target && prior['status'] == 'paid') {
        await db.update('queue_item', {'observation': id},
            where: 'id=?', whereArgs: [key]);
      }
    }
  }

  Future<void> _acceptMismatch(String id, AppleReceipt input,
      AppleEnvironmentMismatch proof, _VerificationCall call) async {
    if (_closed || !_configured) return;
    if (proof.appId != _appId ||
        proof.expectedEnvironment != _environment ||
        proof.actualEnvironment == _environment ||
        !appleEnvironments.contains(proof.actualEnvironment) ||
        proof.reportedTransactionId != input.transactionId ||
        proof.productId != input.productId ||
        [proof.issuer, proof.reference, proof.verifiedTransactionId]
            .any((v) => v.trim().isEmpty)) {
      throw StateError('Invalid Apple environment proof');
    }
    await _journal.write((db) async {
      final canonical = await _canonicalPurchaseId(db, id);
      final p = await _row(db, 'purchase', canonical);
      if (p == null || p['productId'] != input.productId) return;
      final a = await _row(db, 'attempt', input.attemptId);
      final token = _wire(proof.purchaseToken);
      final linked = a != null &&
          a['id'] == p['attemptId'] &&
          token != null &&
          Uuid.isValidUUID(fromString: token) &&
          _wire(a['wireToken'] as String?) == token &&
          _wire(input.purchaseToken) == token &&
          a['orderId'] == input.orderId;
      final payload = jsonEncode([
        proof.issuer,
        proof.reference,
        proof.appId,
        proof.expectedEnvironment,
        proof.actualEnvironment,
        proof.verifiedTransactionId,
        proof.reportedTransactionId,
        proof.productId,
        token
      ]);
      final ref = 'mismatch:${sha256.convert(utf8.encode(payload))}';
      await db.rawInsert(
          """INSERT OR IGNORE INTO recovery.observation
        (id,generation,objectKey,productId,token,reportedId,originalId,status,observedContext,actual,verifiedId,proof,originLinked,reason)
        VALUES (?,'verified',?,?,?,?,?,'paid',?,?,?,?,?,'environmentMismatch')""",
          [
            ref,
            ref,
            proof.productId,
            token,
            proof.reportedTransactionId,
            input.originalTransactionId,
            proof.expectedEnvironment,
            proof.actualEnvironment,
            proof.verifiedTransactionId,
            payload,
            linked ? 1 : 0
          ]);
      if ((await db.rawQuery("""SELECT 1 FROM recovery.observation WHERE id=?
          AND reason IN ('environmentRejected','environmentSelected')""",
              [ref]))
          .isNotEmpty) {
        return;
      }
      await _saveCandidate(
          db, ref, input.receipt, 'store', proof.expectedEnvironment);
      // A result for another UUID (or with no independent submission proof)
      // describes application-level evidence only. A late result cannot
      // revoke an unrelated verified charge even when device reports match.
      if (!linked) {
        final currentUnproven = token == null &&
            identical(_calls[id], call) &&
            !call.retired.isCompleted &&
            identical(_account, call.account) &&
            canonical == id &&
            p['inputVersion'] == call.version &&
            p['verifiedId'] == null &&
            p['disposition'] == null &&
            p['conflict'] == 0;
        if (currentUnproven) {
          await db.update('purchase', {'reason': 'sourceUnproven'},
              where: 'id=?', whereArgs: [id]);
          if (a != null && a['id'] == p['attemptId']) {
            await restoreUnprovenAttempts(db, attemptId: a['id'] as String);
          }
        }
        return;
      }
      await db.rawInsert(
          '''INSERT OR IGNORE INTO recovery.body SELECT b.* FROM evidence b
        JOIN purchase_evidence x ON x.hash=b.hash WHERE x.purchaseId=?''',
          [canonical]);
      await db.rawInsert(
          '''INSERT OR IGNORE INTO recovery.candidate SELECT ?,hash,'original',?
        FROM purchase_evidence WHERE purchaseId=?''',
          [ref, proof.expectedEnvironment, canonical]);
      await db.rawUpdate(
          'UPDATE recovery.observation SET originPurchase=? WHERE id=?',
          [canonical, ref]);
      final different = await db.rawQuery(
          '''SELECT 1 FROM recovery.observation WHERE originPurchase=? AND
          (actual!=? OR verifiedId!=?) LIMIT 1''',
          [canonical, proof.actualEnvironment, proof.verifiedTransactionId]);
      if (p['disposition'] != null ||
          p['verifiedId'] != null ||
          different.isNotEmpty) {
        await _openDispute(db, p, 'environmentConflict', payload);
      } else {
        await db.update('purchase', {'reason': 'environmentMismatch'},
            where: 'id=?', whereArgs: [canonical]);
        await db.update('attempt', {'reason': 'environmentMismatch'},
            where: 'id=?', whereArgs: [a['id']]);
      }
    });
    _changed();
  }
}
