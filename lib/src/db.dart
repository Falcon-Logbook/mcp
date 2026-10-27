import 'package:sqlite3/sqlite3.dart';


const Set<String> _dateColumns = {
  'date',
  'createdAt',
  'updatedAt',
};

const Set<String> _boolColumns = {
  'multiEngine',
  'ifr',
  'complex',
  'pressurised',
  'tailwheel',
  'simulator',
  'helicopter',
  'floatPlane',
  'archived',
  'isSimulator',
  'isIfr',
  'showSummaryCard',
  'showDayNight',
  'showRoutesInWizard',
  'showLogbookView',
  'showFlightNumber',
  'showProperties',
  'showMultiEngine',
  'showIfr',
  'showComplex',
  'showPressurised',
  'showTailwheel',
  'showSimulator',
  'showHelicopter',
  'showFloatPlane',
  'archiveEnabled',
  'showTableView',
  'showBadge',
  'firstNameInitialOnly',
  'nicknameOnly',
};

class FalconDb {
  FalconDb(this.path) {
    _db = sqlite3.open(path);
  }

  final String path;
  late final Database _db;

  int get schemaVersion {
    final rows = _db.select('PRAGMA user_version');
    if (rows.isEmpty) return 0;
    return rows.first.values.first as int? ?? 0;
  }

  List<String> get tables {
    final rows = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return rows.map((r) => r['name'] as String).toList();
  }

  /// Run a SELECT and return rows as JSON-friendly maps.
  List<Map<String, dynamic>> query(String sql, [List<Object?> params = const []]) {
    final rows = _db.select(sql, params);
    return rows.map(_rowToMap).toList();
  }

  Map<String, dynamic> _rowToMap(Row row) {
    final out = <String, dynamic>{};
    for (final col in row.keys) {
      final v = row[col];
      if (v is int) {
        if (_dateColumns.contains(col)) {
          // Drift stores DateTime as unix seconds.
          out[col] = DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true).toIso8601String();
        } else if (_boolColumns.contains(col)) {
          out[col] = v != 0;
        } else {
          out[col] = v;
        }
      } else if (v is double) {
        out[col] = v;
      } else {
        out[col] = v;
      }
    }
    return out;
  }

  void close() => _db.dispose();
}

/// Open read-only? We open normally but callers should only SELECT.
FalconDb openDb(String path) => FalconDb(path);
