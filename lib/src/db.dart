import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'sqlite_loader.dart';
import 'util.dart';

/// Columns that hold unix epoch seconds even when their name does not end in
/// `_at`/`_on`/`_date`.
const Set<String> _dateColumns = {
  'date',
  'timestamp',
  'due_date',
  'last_backed_up',
  'last_push_at',
  'last_pull_at',
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
    _db = sqlite3.open(
      path,
      mode: readonly ? OpenMode.readOnly : OpenMode.readWrite,
    );
    _db.execute('PRAGMA busy_timeout = 5000');
    // The app turns foreign keys on, and relies on ON DELETE SET NULL to clear
    // flights.aircraft_id / flights.crew_member_id. Without this a delete
    // leaves dangling references.
    if (!readonly) _db.execute('PRAGMA foreign_keys = ON');
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
        if (_isDateColumn(column)) {
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

/// Epoch-second columns: known names plus the drift naming conventions for
/// timestamps and dates (`*_at`, `*_on`, `*_date`), so additive schema changes
/// keep being rendered readably.
bool _isDateColumn(String column) =>
    _dateColumns.contains(column) ||
    column.endsWith('_at') ||
    column.endsWith('_on') ||
    column.endsWith('_date');

bool _isBoolColumn(String column) =>
    _boolColumns.contains(column) ||
    column.startsWith('is_') ||
    column.startsWith('show_') ||
    column.startsWith('has_') ||
    column.endsWith('_enabled');

FalconDb openDb(String path, {bool readonly = false}) =>
    FalconDb(path, readonly: readonly);
