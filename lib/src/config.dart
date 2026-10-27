import 'dart:io';

import 'package:path/path.dart' as p;

/// Candidate application-support directories where the Falcon app may have
/// written `db_path.conf`. We try all of them and use the first that exists.
List<String> _appSupportCandidates() {
  final out = <String>[];
  if (Platform.isLinux || Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '';
    if (Platform.isMacOS) {
      out.add(p.join(home, 'Library', 'Application Support'));
      out.add(p.join(home, 'Library', 'Application Support', 'Falcon'));
      out.add(p.join(home, 'Library', 'Application Support', 'com.teamsuperpanda.falcon'));
    } else {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      if (xdg != null && xdg.isNotEmpty) {
        out.add(xdg);
        out.add(p.join(xdg, 'falcon'));
        out.add(p.join(xdg, 'com.teamsuperpanda.falcon'));
      }
      out.add(p.join(home, '.local', 'share'));
      out.add(p.join(home, '.local', 'share', 'falcon'));
      out.add(p.join(home, '.local', 'share', 'com.teamsuperpanda.falcon'));
    }
  } else if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? '';
    out.add(appData);
    out.add(p.join(appData, 'Falcon'));
    out.add(p.join(appData, 'Team Super Panda', 'Falcon'));
    out.add(p.join(appData, 'com.teamsuperpanda.falcon'));
  }
  return out.where((d) => d.isNotEmpty).toList();
}

String? _readConfFile() {
  for (final dir in _appSupportCandidates()) {
    try {
      final f = File(p.join(dir, 'db_path.conf'));
      if (f.existsSync()) {
        final v = f.readAsStringSync().trim();
        if (v.isNotEmpty) return v;
      }
    } catch (_) {}
  }
  return null;
}

String resolveDbPath({String? override}) {
  if (override != null && override.trim().isNotEmpty) {
    return override.trim();
  }
  final env = Platform.environment['FALCON_DB_PATH'];
  if (env != null && env.trim().isNotEmpty) {
    return env.trim();
  }
  final conf = _readConfFile();
  if (conf != null && conf.isNotEmpty) {
    return conf;
  }
  return defaultDbPath();
}

String defaultDbPath() {
  if (Platform.isLinux) {
    final home = Platform.environment['HOME'] ?? '/home';
    return p.join(home, 'Documents', 'Falcon', 'falcon_db.sqlite');
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, 'Library', 'Application Support', 'Falcon', 'falcon_db.sqlite');
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? '';
    return p.join(appData, 'Falcon', 'falcon_db.sqlite');
  }
  final home = Platform.environment['HOME'] ?? '/tmp';
  return p.join(home, 'Falcon', 'falcon_db.sqlite');
}

const int expectedSchemaVersion = 18;
