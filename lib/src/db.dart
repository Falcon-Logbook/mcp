import 'package:sqlite3/sqlite3.dart';

const Set<String> _dateColumns = {
  'date',
  'timestamp',
  'createdAt',
  'updatedAt',
  'lastBackedUp',
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
  'oledDarkMode',
  'hasSeenStorageExplanation',
  'backgroundLaunchPending',
  'hangarDoorsSplash',
  'showDashboard',
  'showExpiries',
  'showReports',
  'showAirports',
  'showCurrency',
  'showTools',
  'showRoutes',
  'expandedOnLaunch',
};

class FalconDb {
  FalconDb(this.path) {
    _db = sqlite3.open(path, mode: OpenMode.readOnly);
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  final String path;
  late final Database _db;

  int get schemaVersion {
    final rows = _db.select('PRAGMA user_version');
    if (rows.isEmpty) return 0;
    final v = rows.first['user_version'];
    return v is int ? v : 0;
  }

  List<String> get tables {
    final rows = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return rows.map((r) => r['name'] as String).toList();
  }

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
          out[col] = DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true).toIso8601String();
        } else if (_boolColumns.contains(col)) {
          out[col] = v != 0;
        } else {
          out[col] = v;
        }
      } else {
        out[col] = v;
      }
    }
    return out;
  }

  void close() => _db.dispose();
}

FalconDb openDb(String path) => FalconDb(path);
