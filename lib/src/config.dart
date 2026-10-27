import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the SQLite database path.
///
/// Priority: explicit [override] (from --db) -> FALCON_DB_PATH env ->
/// db_path.conf (best-effort) -> platform default.
String resolveDbPath({String? override}) {
  if (override != null && override.trim().isNotEmpty) {
    return override.trim();
  }
  final env = Platform.environment['FALCON_DB_PATH'];
  if (env != null && env.trim().isNotEmpty) {
    return env.trim();
  }

  // Best-effort db_path.conf lookup.
  final conf = _readConfFile();
  if (conf != null && conf.isNotEmpty) {
    return conf;
  }

  return defaultDbPath();
}

String? _readConfFile() {
  try {
    final dir = _appSupportDir();
    if (dir == null) return null;
    final f = File(p.join(dir, 'db_path.conf'));
    if (!f.existsSync()) return null;
    final v = f.readAsStringSync().trim();
    return v.isEmpty ? null : v;
  } catch (_) {
    return null;
  }
}

String? _appSupportDir() {
  if (Platform.isLinux || Platform.isMacOS) {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'falcon');
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'Application Support', 'falcon');
    }
    return p.join(home, '.local', 'share', 'falcon');
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return p.join(appData, 'falcon');
  }
  return null;
}

String defaultDbPath() {
  if (Platform.isLinux) {
    final home = Platform.environment['HOME'] ?? '/home';
    return p.join(home, 'Documents', 'Falcon', 'falcon_db.sqlite');
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, 'Library', 'Application Support', 'falcon', 'Falcon', 'falcon_db.sqlite');
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? '';
    return p.join(appData, 'falcon', 'Falcon', 'falcon_db.sqlite');
  }
  // Fallback
  final home = Platform.environment['HOME'] ?? '/tmp';
  return p.join(home, 'Falcon', 'falcon_db.sqlite');
}

const int expectedSchemaVersion = 18;
