import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/schema.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_db_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('reads the schema version and table list', () {
    final db = openDb(dbPath);
    addTearDown(db.close);
    expect(db.schemaVersion, fixtureSchemaVersion);
    expect(db.tables, containsAll(['flights', 'aircraft', 'crew_members']));
    expect(db.columnsOf('flights'), contains('aircraft_registration'));
  });

  test('renders booleans, epoch dates and blobs for JSON', () {
    withFixtureDb(dbPath, (raw) {
      raw.execute('ALTER TABLE flights ADD COLUMN attachment BLOB');
      raw.execute("UPDATE flights SET attachment = x'0102' WHERE id = 'fl-1'");
    });

    final db = openDb(dbPath);
    addTearDown(db.close);
    final row = db.query("SELECT * FROM flights WHERE id = 'fl-1'").single;
    expect(row['is_simulator'], isFalse);
    expect(row['aircraft_id'], 'ac-1');
    // Drift stores DateTime as unix seconds; epochToIso renders local time.
    expect(row['date'], isA<String>());
    expect(
      DateTime.parse(row['date'] as String).toLocal().day,
      DateTime.fromMillisecondsSinceEpoch(1761408000 * 1000).day,
    );
    expect(row['attachment'], 'AQI=');
  });

  test('read-only connections refuse writes', () {
    final db = openDb(dbPath, readonly: true);
    addTearDown(db.close);
    expect(
      () => db.execute("UPDATE flights SET route = 'x' WHERE id = 'fl-1'"),
      throwsA(anything),
    );
  });

  test('transactions roll back on failure', () {
    final db = openDb(dbPath);
    addTearDown(db.close);
    expect(
      () => db.transaction(() {
        db.execute("UPDATE flights SET total_time = 999 WHERE id = 'fl-1'");
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(
        db
            .query("SELECT total_time FROM flights WHERE id = 'fl-1'")
            .single['total_time'],
        120);
  });

  test('write connections enforce foreign keys', () {
    final db = openDb(dbPath);
    addTearDown(db.close);
    db.execute("DELETE FROM aircraft WHERE id = 'ac-1'");
    expect(
      db
          .query("SELECT aircraft_id FROM flights WHERE id = 'fl-1'")
          .single['aircraft_id'],
      isNull,
    );
  });

  test('missing database files are reported, not created', () {
    final missing = '${tempDir.path}/nope.sqlite';
    expect(() => openDb(missing), throwsA(isA<FalconDbException>()));
    expect(File(missing).existsSync(), isFalse);
  });

  test('tableInfo describes columns', () {
    final db = openDb(dbPath);
    addTearDown(db.close);
    final columns = db.tableInfo('flights');
    final id = columns.firstWhere((column) => column['name'] == 'id');
    expect(id['pk'], 1);
    expect(db.tableInfo('no_such_table'), isEmpty);
  });
}
