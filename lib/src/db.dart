import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'sqlite_loader.dart';
import 'util.dart';

/// Columns that hold unix epoch seconds even when their name does not end in
/// `_at`/`_on`, rendered as instants (see [_isInstantColumn]).
const Set<String> _instantColumns = {
  'timestamp',
  'last_backed_up',
  'last_push_at',
  'last_pull_at',
  // Planned-time columns (schema 20, Falcon-Logbook/app#231): unix seconds UTC,
  // and the name ends in `_utc`, which the naming conventions do not catch.
  'scheduled_departure_utc',
  'scheduled_arrival_utc',
};

/// Columns that hold a calendar date, stored as the epoch seconds of the
/// logbook zone's midnight starting that day. `due_date` is spelled out even
/// though the `*_date` rule catches it, because the whole name is the case.
const Set<String> _calendarDateColumns = {
  'date',
  'due_date',
};

/// Integer 0/1 columns whose name is not caught by the prefix rules below.
///
/// `archived` and the aircraft flags are booleans in the app's schema and in
/// every question asked of them, so returning 0/1 next to `is_ifr: false` makes
/// an agent compare two types. The whole column name is the flag, so this is a
/// list rather than a heuristic.
const Set<String> _boolColumns = {
  'minimum_supported',
  'archived',
  'multi_engine',
  'ifr',
  'complex',
  'pressurised',
  'tailwheel',
  'simulator',
  'helicopter',
  'float_plane',
};

/// Thrown for problems the caller can fix (missing file, wrong schema
/// version). The CLI turns it into a clean one-line error.
class FalconDbException implements Exception {
  FalconDbException(this.message);
  final String message;

  @override
  String toString() => message;
}

class FalconDb {
  FalconDb(this.path, {this.readonly = false}) {
    ensureSqliteLibrary();
    if (!File(path).existsSync()) {
      throw FalconDbException(
        'Database not found: $path\n'
        'Pass --db <path>, set FALCON_DB_PATH, or configure the path in the Falcon app.',
      );
    }
    if (readonly) {
      _db = _openReadOnly();
      return;
    }
    _db = sqlite3.open(path, mode: OpenMode.readWrite);
    _db.execute('PRAGMA busy_timeout = 5000');
    // The app turns foreign keys on, and relies on ON DELETE SET NULL to clear
    // flights.aircraft_id / flights.crew_member_id. Without this a delete
    // leaves dangling references.
    _db.execute('PRAGMA foreign_keys = ON');
  }

  /// Opens the logbook for reading, preferring an ordinary read-only
  /// connection so the `-wal` is honoured and a live writer is coordinated
  /// with.
  ///
  /// An ordinary read-only connection still writes to the logbook's directory:
  /// a WAL database creates and maps `-shm`, and may create `-wal`, so a
  /// successful read-only start can leave `falcon_db.sqlite-wal` and
  /// `falcon_db.sqlite-shm` beside the logbook. In a directory that cannot be
  /// written to that same connection fails, which is the case the immutable
  /// retry exists for.
  Database _openReadOnly() {
    Database? db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = 5000');
      // Opening is lazy: the first read is what touches `-shm`, so prove the
      // connection can read before accepting it.
      db.select('PRAGMA user_version');
      return db;
    } on SqliteException catch (error) {
      try {
        db?.dispose();
      } catch (_) {
        // The connection never worked; the open error is what matters.
      }
      if (!_isLockedOutByDirectory(error)) rethrow;
      return _openImmutable(error);
    }
  }

  /// Last resort for a logbook whose directory cannot be written to:
  /// `immutable=1` promises SQLite the file cannot change, so it takes no
  /// locks and creates no `-shm`/`-wal`, and the read works on a read-only
  /// mount.
  ///
  /// The promise has a cost: an immutable connection never checks for a
  /// writer, ignores a `-wal` left behind by one, and can therefore miss
  /// recent commits or read a half-written file. It is worth it only when the
  /// alternative is refusing to read an otherwise readable logbook.
  Database _openImmutable(SqliteException firstError) {
    final uri = _immutableUri(path);
    try {
      final db = sqlite3.open(uri, mode: OpenMode.readOnly, uri: true);
      db.execute('PRAGMA busy_timeout = 5000');
      return db;
    } on SqliteException catch (error) {
      throw FalconDbException(
        'Cannot read the logbook at $path: ${firstError.message}\n'
        'A logbook in WAL mode needs a writable directory even for reads, '
        'because SQLite creates and maps the -shm file there (and may create '
        '-wal), so a read-only mount fails.\n'
        'Copy the logbook somewhere writable and point --db at the copy.\n'
        'The immutable fallback ($uri) also failed: ${error.message}. '
        'immutable=1 reads the file without locks, so it cannot coordinate '
        'with a live writer or see commits still in -wal.',
      );
    }
  }

  final String path;
  final bool readonly;
  late final Database _db;

  int get schemaVersion {
    final rows = _db.select('PRAGMA user_version');
    if (rows.isEmpty) return 0;
    final value = rows.first['user_version'];
    return value is int ? value : 0;
  }

  List<String> get tables {
    final rows = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return rows.map((row) => row['name'] as String).toList();
  }

  bool hasTable(String table) => tables.contains(table);

  /// Column names of [table], or an empty list when it does not exist.
  List<String> columnsOf(String table) {
    if (!hasTable(table)) return const [];
    return _db
        .select('PRAGMA table_info("${table.replaceAll('"', '""')}")')
        .map((row) => row['name'] as String)
        .toList();
  }

  List<Map<String, dynamic>> query(String sql,
      [List<Object?> params = const []]) {
    final rows = _db.select(sql, params);
    return rows.map(_rowToMap).toList();
  }

  /// Rows exactly as SQLite stored them, without the JSON rendering [query]
  /// applies, so a caller can compare stored values (a `*_at` epoch) rather
  /// than the displayed ISO text.
  List<Map<String, dynamic>> selectRaw(String sql,
      [List<Object?> params = const []]) {
    final rows = _db.select(sql, params);
    return rows.map(Map<String, dynamic>.from).toList();
  }

  /// Reads a table's schema for `get_schema` and the `falcon://schema` resource.
  List<Map<String, dynamic>> tableInfo(String table) {
    if (!hasTable(table)) return const [];
    return query('PRAGMA table_info("${table.replaceAll('"', '""')}")')
        .map((column) => {
              'name': column['name'],
              'type': column['type'],
              'notnull': column['notnull'],
              'default': column['dflt_value'],
              'pk': column['pk'],
            })
        .toList();
  }

  /// Runs a write statement and returns how many rows it changed, so a caller
  /// can tell "updated one row" from "the row was gone".
  int execute(String sql, [List<Object?> params = const []]) {
    _db.execute(sql, params);
    return _db.updatedRows;
  }

  int lastInsertRowId() => _db.lastInsertRowId;

  /// Depth of nested [transaction] calls, so a write body that opens its own
  /// transaction nests instead of failing: SQLite has no nested `BEGIN`.
  int _transactionDepth = 0;

  /// Runs [body] in a write transaction and returns its result. A call made
  /// while a transaction is already open uses a savepoint, so the outer call
  /// still decides whether the whole change commits or rolls back.
  T transaction<T>(T Function() body) {
    if (_transactionDepth > 0) {
      final savepoint = 'sp_$_transactionDepth';
      _db.execute('SAVEPOINT $savepoint');
      _transactionDepth++;
      try {
        final result = body();
        _db.execute('RELEASE $savepoint');
        return result;
      } catch (_) {
        try {
          _db.execute('ROLLBACK TO $savepoint');
          _db.execute('RELEASE $savepoint');
        } catch (_) {
          // The outer transaction unwinds the statement that failed; its error
          // matters more than this one.
        }
        rethrow;
      } finally {
        _transactionDepth--;
      }
    }

    _db.execute('BEGIN IMMEDIATE');
    _transactionDepth++;
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        _db.execute('ROLLBACK');
      } catch (_) {
        // Connection may already be unwound; the original error matters more.
      }
      rethrow;
    } finally {
      _transactionDepth--;
    }
  }

  Map<String, dynamic> _rowToMap(Row row) {
    final out = <String, dynamic>{};
    for (final column in row.keys) {
      final value = row[column];
      if (value is int) {
        if (_isCalendarDateColumn(column)) {
          out[column] = epochToCalendarDate(value);
        } else if (_isInstantColumn(column)) {
          out[column] = epochToIso(value);
        } else if (_isBoolColumn(column)) {
          out[column] = value != 0;
        } else {
          out[column] = value;
        }
      } else if (value is Uint8List) {
        // JSON has no binary type; expose blobs as base64 rather than failing
        // the whole response.
        out[column] = base64Encode(value);
      } else {
        out[column] = value;
      }
    }
    return out;
  }

  void close() => _db.dispose();
}

/// Calendar-date columns: known names plus the drift naming convention
/// (`*_date`). A calendar date has no time and no offset, so it renders as
/// `YYYY-MM-DD` computed in the logbook zone ([epochToCalendarDate]): the
/// stored value is the zone's midnight, and rendering it any other way would
/// move the date on a host in a different zone.
bool _isCalendarDateColumn(String column) =>
    _calendarDateColumns.contains(column) || column.endsWith('_date');

/// Instant columns: known names plus the drift naming conventions for
/// timestamps (`*_at`, `*_on`), so additive schema changes keep being rendered
/// readably. An instant is a moment, so it renders as ISO-8601 with an
/// explicit offset ([epochToIso]) rather than as someone's local clock.
bool _isInstantColumn(String column) =>
    _instantColumns.contains(column) ||
    column.endsWith('_at') ||
    column.endsWith('_on');

bool _isBoolColumn(String column) =>
    _boolColumns.contains(column) ||
    column.startsWith('is_') ||
    column.startsWith('show_') ||
    column.startsWith('has_') ||
    column.endsWith('_enabled');

FalconDb openDb(String path, {bool readonly = false}) =>
    FalconDb(path, readonly: readonly);

/// The `immutable=1` URI SQLite needs to open [path] without touching its
/// directory.
///
/// The path is made absolute first (a relative `file:` URI resolves against the
/// working directory, which is not what a caller passed), then percent-encoded
/// by [Uri.file] so a logbook in a directory with a space or a `?` in its name
/// still opens. `file:///...` is the absolute path SQLite's URI parser expects.
String _immutableUri(String path) =>
    '${Uri.file(File(path).absolute.path)}?immutable=1';

/// Whether [error] is SQLite refusing to write the directory (or unable to
/// open a file there), which is the only failure the immutable retry can fix.
///
/// [SqliteException.resultCode] strips the extended code, so
/// `SQLITE_READONLY_DIRECTORY` and `SQLITE_READONLY_CANTINIT` count as
/// `SQLITE_READONLY` here.
bool _isLockedOutByDirectory(SqliteException error) {
  const sqliteReadonly = 8;
  const sqliteCantOpen = 14;
  return error.resultCode == sqliteReadonly ||
      error.resultCode == sqliteCantOpen;
}
