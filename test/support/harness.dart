import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'schema.dart';

/// Creates a Falcon-shaped database at [path] and seeds it with one aircraft,
/// one crew member, one flight, one saved route and settings rows.
String createFixture(String path) {
  ensureSqliteLibrary();
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final db = sqlite.sqlite3.open(path);
  try {
    for (final statement in fixtureStatements) {
      db.execute(statement);
    }
    db.execute('PRAGMA user_version = $fixtureSchemaVersion');
    db.execute(
      "INSERT INTO aircraft (id, type, country_code, registration, multi_engine, ifr, created_at) "
      "VALUES ('ac-1', 'B738', 'VH', 'XZO', 1, 1, 1700000000)",
    );
    db.execute(
      "INSERT INTO crew_members (id, name, first_name, last_name, created_at) "
      "VALUES ('cr-1', 'Jane Doe', 'Jane', 'Doe', 1700000000)",
    );
    db.execute(
      "INSERT INTO flights (id, date, aircraft_id, aircraft_registration, flight_type, crew_role, "
      "crew_member_id, crew_members_name, route, total_time, day_time, night_time, takeoffs, landings, "
      "is_simulator, created_at) VALUES ('fl-1', 1761408000, 'ac-1', 'VH-XZO', 'route', 'pilotInCommand', "
      "'cr-1', 'Jane Doe', 'YSSY - NZQN', 120, 90, 30, 1, 1, 0, 1700000000)",
    );
    db.execute(
      "INSERT INTO flights (id, date, route, created_at) "
      "VALUES ('fl-draft', 1761494400, 'YSBK - YSSY', 1700000000)",
    );
    db.execute(
      "INSERT INTO saved_routes (flight_number, departure_icao, arrival_icao, distance_nm, created_at) "
      "VALUES ('QF1', 'YSSY', 'EGLL', 9000.0, 1700000000)",
    );
    db.execute(
      "INSERT INTO flights_settings (id, pilot_name, created_at) "
      "VALUES ('settings-1', 'Self', 1700000000)",
    );
  } finally {
    db.dispose();
  }
  return path;
}

/// Creates a Falcon-shaped database at [path] with the schema and no seed rows,
/// for tests that need exact counts.
String createEmptyFixture(String path) {
  ensureSqliteLibrary();
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final db = sqlite.sqlite3.open(path);
  try {
    for (final statement in fixtureStatements) {
      db.execute(statement);
    }
    db.execute('PRAGMA user_version = $fixtureSchemaVersion');
  } finally {
    db.dispose();
  }
  return path;
}

/// Inserts extra flight rows. Each entry is a column map; a `DateTime` date is
/// stored as local midnight epoch seconds, the way the app writes it.
void insertFlights(String path, List<Map<String, Object?>> rows) {
  withFixtureDb(path, (db) {
    for (final row in rows) {
      final values = <String, Object?>{};
      for (final entry in row.entries) {
        final value = entry.value;
        values[entry.key] = value is DateTime ? epochForDayStart(value) : value;
      }
      db.execute(
        'INSERT INTO flights (${values.keys.join(', ')}) '
        'VALUES (${List.filled(values.length, '?').join(', ')})',
        values.values.toList(),
      );
    }
  });
}

/// Raw SQL access for assertions.
T withFixtureDb<T>(String path, T Function(sqlite.Database db) body) {
  ensureSqliteLibrary();
  final db = sqlite.sqlite3.open(path);
  try {
    return body(db);
  } finally {
    db.dispose();
  }
}

/// A JSON-RPC line protocol client for the compiled-in server script.
class McpProcess {
  McpProcess._(this._process) {
    _stderrDone = _process.stderr.transform(utf8.decoder).join();
  }

  static Future<McpProcess> start(String dbPath, {bool write = false}) async {
    final libraryPath = Platform.environment['LD_LIBRARY_PATH'] ?? '';
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/falcon_mcp.dart',
        '--db',
        dbPath,
        if (write) '--no-readonly',
      ],
      environment: {
        // The server resolves libsqlite3 itself; keep the parent's library path
        // in case the platform needs it.
        'LD_LIBRARY_PATH': libraryPath,
      },
    );
    final client = McpProcess._(process);
    final init = await client.send('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'falcon_mcp_test', 'version': '1'},
    });
    if (init['error'] != null) {
      throw StateError('initialize failed: ${init['error']}');
    }
    client._notify('notifications/initialized', {});
    return client;
  }

  final Process _process;
  late final Future<String> _stderrDone;
  late final StreamIterator<String> _lines = StreamIterator(
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
  int _nextId = 1;

  Future<String> _readLine() async {
    while (await _lines.moveNext()) {
      final line = _lines.current.trim();
      if (line.isNotEmpty) return line;
    }
    throw StateError('server closed stdout: ${await _stderrDone}');
  }

  Future<Map<String, dynamic>> send(
      String method, Map<String, dynamic> params) async {
    final id = _nextId++;
    _process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    await _process.stdin.flush();
    return jsonDecode(await _readLine()) as Map<String, dynamic>;
  }

  void _notify(String method, Map<String, dynamic> params) {
    _process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    }));
  }

  /// Calls [tool] and returns the decoded JSON payload, or the error text when
  /// the tool reported a failure.
  Future<({bool isError, Object? payload})> call(
      String tool, Map<String, dynamic> args) async {
    final response =
        await send('tools/call', {'name': tool, 'arguments': args});
    final error = response['error'];
    if (error is Map) {
      return (isError: true, payload: '${error['message']}');
    }
    final result = response['result'] as Map<String, dynamic>;
    final content = (result['content'] as List).cast<Map<String, dynamic>>();
    final text = content.isEmpty ? '' : content.first['text'] as String;
    final isError = result['isError'] == true;
    return (
      isError: isError,
      payload: isError ? text : jsonDecode(text),
    );
  }

  Future<List<String>> toolNames() async {
    final response = await send('tools/list', {});
    final tools = (response['result'] as Map<String, dynamic>)['tools'] as List;
    return [
      for (final tool in tools) (tool as Map<String, dynamic>)['name'] as String
    ];
  }

  Future<String> stop() async {
    await _process.stdin.close();
    final exitCode = await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
    final stderr = await _stderrDone;
    if (exitCode != 0 && exitCode != -1) {
      throw StateError('server exited with $exitCode: $stderr');
    }
    return stderr;
  }
}
