import 'dart:io';

import 'package:path/path.dart' as p;

/// Version advertised over MCP and by `--version`.
const String serverVersion = '0.3.0';

/// Schema versions this server can read and write. Every query selects whole
/// rows and writes only columns it knows about, so additive columns added by
/// later migrations are tolerated.
const int minSchemaVersion = 18;
const int maxSchemaVersion = 19;

/// Candidate application-support directories where the Falcon app may have
/// written `db_path.conf`, most likely first.
List<String> appSupportCandidates() {
  final env = Platform.environment;
  final home = env['HOME'] ?? '';
  final out = <String>[];

  if (Platform.isMacOS) {
    if (home.isNotEmpty) {
      out.add(p.join(
          home, 'Library', 'Application Support', 'com.teamsuperpanda.falcon'));
      out.add(p.join(home, 'Library', 'Application Support', 'Falcon'));
    }
  } else if (Platform.isWindows) {
    final appData = env['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      out.add(p.join(appData, 'com.teamsuperpanda.falcon'));
      out.add(p.join(appData, 'Falcon'));
      out.add(p.join(appData, 'Team Super Panda', 'Falcon'));
    }
  } else if (Platform.isLinux) {
    final xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      out.add(p.join(xdg, 'com.teamsuperpanda.falcon'));
      out.add(p.join(xdg, 'falcon'));
    }
    if (home.isNotEmpty) {
      out.add(p.join(home, '.local', 'share', 'com.teamsuperpanda.falcon'));
      out.add(p.join(home, '.local', 'share', 'falcon'));
    }
  }
  return out;
}

/// The database path the app uses when no custom path is configured.
String defaultDbPath() {
  final home = Platform.environment['HOME'] ?? '';
  if (Platform.isLinux) {
    return p.join(home.isEmpty ? '/home' : home, 'Documents', 'Falcon',
        'falcon_db.sqlite');
  }
  final candidates = appSupportCandidates();
  final support = candidates.isNotEmpty
      ? candidates.first
      : p.join(home, 'Library', 'Application Support');
  if (Platform.isMacOS) return p.join(support, 'Falcon', 'falcon_db.sqlite');
  if (Platform.isWindows) return p.join(support, 'Falcon', 'falcon_db.sqlite');
  return p.join(home.isEmpty ? '/tmp' : home, 'Falcon', 'falcon_db.sqlite');
}

/// Reads the custom database path the app persists in `db_path.conf`, if any.
String? readConfiguredDbPath() {
  for (final dir in appSupportCandidates()) {
    try {
      final file = File(p.join(dir, 'db_path.conf'));
      if (!file.existsSync()) continue;
      final value = file.readAsStringSync().trim();
      if (value.isNotEmpty) return value;
    } catch (_) {
      // Unreadable candidate: keep looking.
    }
  }
  return null;
}

/// Resolves the database path in priority order: explicit argument, then
/// `FALCON_DB_PATH`, then the app's `db_path.conf`, then the platform default.
///
/// A configured path that no longer exists is ignored so a stale
/// `db_path.conf` cannot hide a perfectly good default database.
String resolveDbPath({String? override, bool requireExisting = true}) {
  bool usable(String path) => !requireExisting || File(path).existsSync();

  final explicit = override?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;

  final env = Platform.environment['FALCON_DB_PATH']?.trim();
  if (env != null && env.isNotEmpty) return env;

  final configured = readConfiguredDbPath();
  if (configured != null && usable(configured)) return configured;

  return defaultDbPath();
}
