import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:sqlite3/sqlite3.dart' as sqlite show OpenMode, sqlite3;
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/schema.dart';

/// Whether permission bits are enforced, which a root process does not do.
/// The read-only-directory tests set those bits, so a root run would pass
/// without exercising the fallback and has to be skipped instead.
final bool _permissionsIgnored = () {
  try {
    return Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
  } on ProcessException {
    return false;
  }
}();

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
    // The exact refusal, not just any failure: a syntax error or a missing
    // table would otherwise satisfy this and leave the read-only mode
    // untested. SQLITE_READONLY is result code 8, and SQLite words it
    // "attempt to write a readonly database".
    expect(
      () => db.execute("UPDATE flights SET route = 'x' WHERE id = 'fl-1'"),
      throwsA(
        isA<SqliteException>()
            .having((error) => error.resultCode, 'resultCode', 8)
            .having((error) => error.message, 'message', contains('readonly')),
      ),
    );
    // The refused write left the row alone.
    expect(
      db.query("SELECT route FROM flights WHERE id = 'fl-1'").single['route'],
      'YSSY - NZQN',
    );
  });

  test('a writable logbook starts in write mode without changing the file', () {
    final before = File(dbPath).readAsBytesSync();

    final db = openDb(dbPath);
    addTearDown(db.close);
    expect(db.readonly, isFalse);
    // The probe takes the write lock and rolls it back, so the logbook is
    // byte-identical and no journal is left beside it: a probe that did write
    // would show up here.
    expect(File(dbPath).readAsBytesSync(), before);
    expect(
      tempDir.listSync().map((entry) => entry.path.split('/').last),
      ['falcon_db.sqlite'],
    );
  });

  test(
      'a write-protected logbook fails at startup in write mode with a '
      'permission message', () {
    final copy =
        File(dbPath).copySync('${tempDir.path}/readonly file.sqlite').path;
    Process.runSync('chmod', ['444', copy]);
    addTearDown(() => Process.runSync('chmod', ['644', copy]));

    // SQLite would open this file read-write and quietly fall back to
    // read-only, so the write is what has to fail, before the banner claims
    // readwrite.
    expect(
      () => openDb(copy),
      throwsA(
        isA<FalconDbException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('Cannot write to the logbook'),
            contains('not writable'),
            contains('read-only'),
            contains('--db'),
            contains('FALCON_DB_PATH'),
            contains('--readonly'),
          ),
        ),
      ),
    );
  },
      skip: _permissionsIgnored
          ? 'running as root ignores the file mode, so the write would succeed '
              'and nothing would be proven'
          : null);

  test('a write-protected directory fails at startup in write mode', () {
    final dir = Directory('${tempDir.path}/readonly mount')..createSync();
    final copy = File(dbPath).copySync('${dir.path}/falcon_db.sqlite').path;
    // The file itself is writable; only the directory cannot take the journal
    // or -wal SQLite needs to begin a write.
    Process.runSync('chmod', ['555', dir.path]);
    addTearDown(() => Process.runSync('chmod', ['755', dir.path]));

    expect(
      () => openDb(copy),
      throwsA(
        isA<FalconDbException>().having(
          (error) => error.message,
          'message',
          contains('not writable'),
        ),
      ),
    );
  },
      skip: _permissionsIgnored
          ? 'running as root ignores the directory mode, so the write would '
              'succeed and nothing would be proven'
          : null);

  test('a write-protected logbook still opens in read-only mode', () {
    final copy =
        File(dbPath).copySync('${tempDir.path}/readonly read.sqlite').path;
    Process.runSync('chmod', ['444', copy]);
    addTearDown(() => Process.runSync('chmod', ['644', copy]));

    final db = openDb(copy, readonly: true);
    addTearDown(db.close);
    expect(db.schemaVersion, fixtureSchemaVersion);
    expect(
      db.query("SELECT route FROM flights WHERE id = 'fl-1'").single['route'],
      'YSSY - NZQN',
    );
  },
      skip: _permissionsIgnored
          ? 'running as root ignores the file mode, so the read would succeed '
              'with or without read-only mode'
          : null);

  test('a WAL logbook is read over a normal read-only connection', () {
    _setWal(dbPath);
    // A commit still in the -wal is visible only to a connection that honours
    // the WAL, which the ordinary read-only open does and the immutable
    // fallback does not. Keeping the writer open stops the checkpoint.
    final writer = sqlite.sqlite3.open(dbPath);
    addTearDown(writer.dispose);
    writer.execute(
      "INSERT INTO flights (id, date, route, created_at) "
      "VALUES ('fl-wal', 1761408000, 'WAL - not checkpointed', 0)",
    );

    final db = openDb(dbPath, readonly: true);
    addTearDown(db.close);
    expect(
      db.query("SELECT route FROM flights WHERE id = 'fl-wal'").single['route'],
      'WAL - not checkpointed',
    );
  });

  test(
      'a WAL logbook in a read-only directory is read via the immutable '
      'fallback', () {
    final dir = Directory('${tempDir.path}/readonly mount')..createSync();
    // A space in the name proves the fallback URI is encoded rather than just
    // prefixed with `file:`, which SQLite would reject or misread.
    _setWal(dbPath);
    final copy = File(dbPath).copySync('${dir.path}/falcon db.sqlite').path;
    Process.runSync('chmod', ['555', dir.path]);
    addTearDown(() => Process.runSync('chmod', ['755', dir.path]));

    // The ordinary read-only connection is what fails here. Without this the
    // test would pass on a writable directory and prove nothing.
    ensureSqliteLibrary();
    expect(
      () {
        final raw = sqlite.sqlite3.open(copy, mode: sqlite.OpenMode.readOnly);
        try {
          raw.select('PRAGMA user_version');
        } finally {
          raw.dispose();
        }
      },
      throwsA(isA<SqliteException>()),
    );

    final db = openDb(copy, readonly: true);
    addTearDown(db.close);
    expect(db.schemaVersion, fixtureSchemaVersion);
    expect(
      db.query("SELECT route FROM flights WHERE id = 'fl-1'").single['route'],
      'YSSY - NZQN',
    );
    // immutable=1 promises the file cannot change, so it writes nothing: the
    // directory still holds only the logbook, with no -wal or -shm beside it.
    expect(dir.listSync().map((entry) => entry.path.split('/').last), [
      'falcon db.sqlite',
    ]);
  },
      skip: _permissionsIgnored
          ? 'running as root ignores the directory mode, so the fallback would not '
              'be exercised'
          : null);

  test(
      'failing both reads explains the writable directory and the immutable '
      'caveat', () {
    _setWal(dbPath);
    final copy =
        File(dbPath).copySync('${tempDir.path}/unreadable.sqlite').path;
    // The file exists but SQLite cannot read it, so the immutable retry fails
    // too and the error has to carry the explanation.
    Process.runSync('chmod', ['000', copy]);
    addTearDown(() => Process.runSync('chmod', ['644', copy]));

    expect(
      () => openDb(copy, readonly: true),
      throwsA(
        isA<FalconDbException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('writable directory'),
            contains('-shm'),
            contains('immutable=1'),
            contains('live writer'),
            contains('--db'),
          ),
        ),
      ),
    );
  },
      skip: _permissionsIgnored
          ? 'running as root ignores the file mode, so the read would succeed '
              'instead of failing'
          : null);

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

/// Switches the fixture at [path] to WAL, the mode the Falcon app runs in, so
/// the read path is exercised against the shape a real logbook has.
void _setWal(String path) {
  withFixtureDb(path, (raw) => raw.execute('PRAGMA journal_mode = wal'));
}
