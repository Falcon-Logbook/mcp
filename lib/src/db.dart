import 'package:sqlite3/sqlite3.dart';

const Set<String> _dateColumns = {
  'date',
  'timestamp',
  'created_at',
  'updated_at',
  'last_backed_up',
  'last_push_at',
  'last_pull_at',
};

const Set<String> _boolColumns = {
  'multi_engine',
  'ifr',
  'complex',
  'pressurised',
  'tailwheel',
  'simulator',
  'helicopter',
  'float_plane',
  'archived',
  'is_simulator',
  'is_ifr',
  'show_summary_card',
  'show_day_night',
  'show_routes_in_wizard',
  'show_logbook_view',
  'show_flight_number',
  'show_properties',
  'show_multi_engine',
  'show_ifr',
  'show_complex',
  'show_pressurised',
  'show_tailwheel',
  'show_simulator',
  'show_helicopter',
  'show_float_plane',
  'archive_enabled',
  'show_table_view',
  'show_badge',
  'first_name_initial_only',
  'nickname_only',
  'oled_dark_mode',
  'has_seen_storage_explanation',
  'background_launch_pending',
  'hangar_doors_splash',
  'show_dashboard',
  'show_expiries',
  'show_reports',
  'show_airports',
  'show_currency',
  'show_tools',
  'show_routes',
  'expanded_on_launch',
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
