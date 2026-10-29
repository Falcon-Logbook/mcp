import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
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
    // Drift stores a DateTime as unix seconds; the row mapper renders a
    // calendar date as strict YYYY-MM-DD in the logbook zone (the system zone
    // here), and that date must round-trip to the day holding the stored
    // instant. A declaration or a value claiming any other shape fails here.
    expect(dateTypeOf(row['date']), 'calendar_date');
    final start = dateToEpoch(row['date'] as String)!;
    final end = dateToEpoch(row['date'] as String, endOfDay: true)!;
    expect(1761408000, inInclusiveRange(start, end),
        reason: 'the rendered date covers the stored midnight');
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

  test('a nested transaction nests as a savepoint', () {
    final db = openDb(dbPath);
    addTearDown(db.close);

    db.transaction(() {
      db.execute("UPDATE flights SET route = 'outer' WHERE id = 'fl-1'");
      db.transaction(() {
        db.execute("UPDATE flights SET total_time = 60 WHERE id = 'fl-1'");
      });
    });
    expect(
      db
          .query("SELECT route, total_time FROM flights WHERE id = 'fl-1'")
          .single,
      {'route': 'outer', 'total_time': 60},
    );

    // A failure inside the nested call rolls the whole outer body back.
    expect(
      () => db.transaction(() {
        db.execute("UPDATE flights SET route = 'lost' WHERE id = 'fl-1'");
        db.transaction(() => throw StateError('boom'));
      }),
      throwsStateError,
    );
    expect(
      db.query("SELECT route FROM flights WHERE id = 'fl-1'").single['route'],
      'outer',
    );

    // The connection is usable again after both unwound.
    db.transaction(() => db.execute("UPDATE flights SET route = 'again' "
        "WHERE id = 'fl-1'"));
    expect(
      db.query("SELECT route FROM flights WHERE id = 'fl-1'").single['route'],
      'again',
    );
  });

  test('execute reports how many rows it changed', () {
    final db = openDb(dbPath);
    addTearDown(db.close);
    expect(db.execute("UPDATE flights SET route = 'x' WHERE id = 'fl-1'"), 1);
    expect(db.execute("UPDATE flights SET route = 'x' WHERE id = 'nope'"), 0);
  });

  test('write connections enforce foreign keys', () {
    final db = openDb(dbPath);
    addTearDown(db.close);
    // The pragma itself, so a refactor that drops it fails here first: the
    // behavioural asserts below would also catch it, but only through the
    // ON DELETE clause.
    expect(db.query('PRAGMA foreign_keys').single['foreign_keys'], 1);
    // A dangling link is refused, not stored.
    expect(
      () => db.execute(
        "INSERT INTO flights (id, date, aircraft_id, created_at) "
        "VALUES ('fl-bogus', 1761408000, 'aircraft-that-does-not-exist', 0)",
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(db.query("SELECT id FROM flights WHERE id = 'fl-bogus'"), isEmpty);
    // Deleting a linked aircraft unlinks the flight (ON DELETE SET NULL).
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
