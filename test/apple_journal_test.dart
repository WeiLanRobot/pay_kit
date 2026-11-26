import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pay_kit/src/iap/apple_journal.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  late Directory temp;
  late File file;
  late AppleJournal journal;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('paykit-sqlite-');
    file = File('${temp.path}/app/ledger.sqlite');
    journal = AppleJournal(() async => file);
  });
  tearDown(() async {
    await journal.close();
    await temp.delete(recursive: true);
  });

  Future<int> revision() => journal.read((db) async =>
      (await db.query('meta', columns: ['revision'])).single['revision']
          as int);

  Future<void> purchase(DatabaseExecutor db, String id) async {
    await db.insert('purchase', {'id': id, 'productId': 'coffee'});
  }

  Map<String, Object?> attempt(String id,
          {String scope = 'A', String order = '42'}) =>
      {
        'id': id,
        'scope': scope,
        'orderId': order,
        'productId': 'coffee',
        'wireToken': id,
        'mode': 'scoped',
        'phase': 'prepared',
      };

  test('the connection owns the ledger between transactions until close',
      () async {
    await journal.write((db) => db.insert('attempt', attempt('u1')));
    final contender = AppleJournal(() async => file);
    addTearDown(contender.close);
    await expectLater(
        contender.write((db) => db.insert('attempt', attempt('u2'))),
        throwsA(isA<DatabaseException>()));
    await journal.close();
    final rows = await contender.read((db) => db.query('attempt'));
    expect(rows.single['id'], 'u1');
    await contender.close();
    expect(await revision(), 1);
  });

  test(
      'concurrent writes serialize and only committed facts increment revision',
      () async {
    await Future.wait(
        List.generate(16, (i) => journal.write((db) => purchase(db, 'p$i'))));
    await expectLater(journal.write((db) async {
      await purchase(db, 'more');
      throw StateError('simulate failure before commit');
    }), throwsStateError);
    expect(await revision(), 16);
    await expectLater(journal.read((db) => purchase(db, 'unversioned')),
        throwsA(isA<DatabaseException>()));
    await journal.close();
    final rows = await journal.read((db) => db.query('purchase'));
    expect(rows.length, 16);
    expect(await revision(), 16);
  });

  test('order locks, wire tokens and attempt identities survive terminal facts',
      () async {
    const uuid = '075e826b-239a-44f4-9bf0-fdf12f7b67c3';
    await journal.write(
        (db) => db.insert('attempt', {...attempt('u1'), 'wireToken': uuid}));
    await expectLater(
        journal.write((db) => db.insert('attempt', attempt('u2'))),
        throwsA(isA<DatabaseException>()));
    await journal
        .write((db) => db.insert('attempt', attempt('u3', scope: 'B')));
    await journal.write((db) => db.update('attempt', {'phase': 'canceled'},
        where: 'id=?', whereArgs: ['u1']));
    await journal.close();
    await journal.write((db) => db.insert('attempt', attempt('u2')));
    await expectLater(
        journal.write((db) => db.update('attempt', {'scope': 'C'},
            where: 'id=?', whereArgs: ['u1'])),
        throwsA(isA<DatabaseException>()));
    final legacy = {
      ...attempt('legacy'),
      'scope': null,
      'mode': 'legacy',
      'wireToken': uuid.toUpperCase()
    };
    await expectLater(journal.write((db) => db.insert('attempt', legacy)),
        throwsA(isA<DatabaseException>()));
    for (final key in ['Case', 'case']) {
      await journal.write((db) => db.insert(
          'attempt', {...legacy, 'id': key, 'wireToken': key, 'orderId': key}));
    }
  });

  test('the verified Apple identity is unique across local purchases',
      () async {
    await journal.write((db) async {
      await purchase(db, 'p1');
      await purchase(db, 'p2');
    });
    final proof = {
      'appId': 'store.app',
      'environment': 'sandbox',
      'verifiedId': 'T1',
      'ackRef': 'ack1',
      'disposition': 'delivered',
    };
    await journal.write(
        (db) => db.update('purchase', proof, where: 'id=?', whereArgs: ['p1']));
    await expectLater(
        journal.write((db) =>
            db.update('purchase', proof, where: 'id=?', whereArgs: ['p2'])),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        journal.write((db) => db.update('purchase', {'verifiedId': 'T2'},
            where: 'id=?', whereArgs: ['p1'])),
        throwsA(isA<DatabaseException>()));
    final rows =
        await journal.read((db) => db.query('purchase', orderBy: 'id'));
    expect(rows.map((p) => p['ackRef']), ['ack1', null]);
  });

  test('receipt bodies survive restart and are collected at last reference',
      () async {
    await journal.write((db) async {
      for (final id in ['p1', 'p2']) {
        await purchase(db, id);
      }
      for (final hash in ['shared', 'first-only']) {
        await db.insert('evidence', {'hash': hash, 'body': 'signed-$hash'});
      }
      for (final ids in [
        ['p1', 'shared'],
        ['p1', 'first-only'],
        ['p2', 'shared']
      ]) {
        await db.insert(
            'purchase_evidence', {'purchaseId': ids.first, 'hash': ids.last});
      }
    });
    await journal.close();
    expect(
        (await journal.read((db) => db.query('purchase_evidence'))).length, 3);
    await journal.write((db) => db
        .delete('purchase_evidence', where: 'purchaseId=?', whereArgs: ['p1']));
    final retained = await journal.read((db) => db.query('evidence'));
    expect(retained.single['body'], 'signed-shared');
    await journal.write((db) => db.delete('purchase_evidence'));
    expect(await journal.read((db) => db.query('evidence')), isEmpty);
    expect((await journal.read((db) => db.query('purchase'))).length, 2);
  });

  test('corruption and newer versions fail closed without replacing data',
      () async {
    await file.parent.create(recursive: true);
    final corrupt = List.filled(120, 0x61);
    await file.writeAsBytes(corrupt);
    await expectLater(revision(), throwsA(isA<DatabaseException>()));
    expect(await file.readAsBytes(), corrupt);
    await file.delete();
    await journal.write((db) => purchase(db, 'v1'));
    await journal.close();
    final futureDb = await openDatabase(file.path);
    await futureDb.setVersion(42);
    await futureDb.close();
    await expectLater(revision(), throwsStateError);
    final check = await openDatabase(file.path);
    expect(await check.getVersion(), 42);
    expect((await check.query('purchase')).single['id'], 'v1');
    await check.close();
  });

  test('a full SQLite file rolls back evidence and can resume after restart',
      () async {
    await journal.write((db) async {
      await purchase(db, 'waiting');
      final capacity =
          (await db.rawQuery('PRAGMA page_count')).single.values.single;
      await db.rawQuery('PRAGMA max_page_count = $capacity');
    });
    await expectLater(journal.write((db) async {
      await db.update('purchase', {'reason': 'before overflow'});
      await db.execute(
          "INSERT INTO evidence(hash,body) VALUES ('large', zeroblob(1048576))");
    }), throwsA(isA<DatabaseException>()));
    await journal.close();
    expect(await revision(), 1);
    expect(await journal.read((db) => db.query('evidence')), isEmpty);
    expect((await journal.read((db) => db.query('purchase'))).single['reason'],
        isNull);
    await journal.write(
        (db) => db.insert('evidence', {'hash': 'small', 'body': 'replayed'}));
    expect(await revision(), 2);
  });
}
