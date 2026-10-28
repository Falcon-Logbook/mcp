import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// The generic settings getter: one allowlisted single-row table at a time, `{}`
/// when the app has never written that row, and a refusal for anything else.
///
/// A read must never create the row (`ensureSingletonRow` in the app does, and in
/// read-only mode that insert would fail), so the empty cases assert that the
/// table is still empty afterwards.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_settings_test');
    dbPath = createEmptyFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<McpProcess> start() async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });
    return server;
  }

  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) =>
      result.payload as Map<String, dynamic>;

  /// The error envelope a failed call returns, decoded: the same compact JSON a
  /// success carries, so a caller parses one shape either way.
  Map<String, dynamic> errorOf(({bool isError, Object? payload}) result) {
    expect(result.isError, isTrue,
        reason: 'expected a refusal: ${result.payload}');
    return jsonDecode(result.payload as String) as Map<String, dynamic>;
  }

  int rowsIn(String table) => withFixtureDb(dbPath,
      (db) => db.select('SELECT COUNT(*) AS n FROM $table').single['n'] as int);

  test('returns the settings row, every column of it', () async {
    dbPath = createFixture('${tempDir.path}/seeded.sqlite');
    final server = await start();

    final payload = payloadOf(
        await server.call('get_settings', {'table': 'flights_settings'}));

    expect(payload['pilot_name'], 'Self');
    // The answer to "why does my logbook print in decimal hours?".
    expect(payload['flight_time_format'], 'decimal1');
    expect(payload['show_day_night'], isFalse,
        reason: '0/1 columns are rendered as booleans, the same as elsewhere');

    final columns = withFixtureDb(
        dbPath,
        (db) => db
            .select('PRAGMA table_info("flights_settings")')
            .map((row) => row['name'] as String)
            .toList());
    expect(payload.keys.toSet(), columns.toSet(),
        reason: 'the row is returned whole, not a chosen subset');
  });

  test('a settings table with no row is an empty object, not an error',
      () async {
    final server = await start();

    for (final table in [
      'app_settings',
      'general_settings',
      'expiry_settings'
    ]) {
      final payload =
          payloadOf(await server.call('get_settings', {'table': table}));

      expect(payload, isEmpty, reason: '$table has no row in a fresh database');
      expect(rowsIn(table), 0,
          reason: '$table must not gain the singleton row from a read');
    }
  });

  test('refuses a table outside the allowlist by name', () async {
    final server = await start();

    for (final table in ['flights', 'aircraft_type_settings', 'nope']) {
      final envelope =
          errorOf(await server.call('get_settings', {'table': table}));

      expect(envelope['error'], 'invalid_value', reason: table);
      expect(envelope['field'], 'table', reason: table);
      expect(envelope['detail'], contains('app_settings'), reason: table);
      expect(envelope['detail'], contains('sidebar_settings'),
          reason: '$table: the accepted list names every table it does read');
      expect(envelope['detail'], contains('(got "$table")'), reason: table);
    }
  });

  test('an allowlisted table this database lacks is not_found', () async {
    // An older or partial file may not carry a table the current schema has:
    // that is a missing table, which is not the same answer as a table with
    // no row.
    withFixtureDb(dbPath, (db) => db.execute('DROP TABLE sidebar_settings'));
    final server = await start();

    final envelope = errorOf(
        await server.call('get_settings', {'table': 'sidebar_settings'}));
    expect(envelope['error'], 'not_found');
    expect(envelope['field'], 'table');
    expect(envelope['detail'], contains('has no sidebar_settings table'));
  });

  test('reads each singleton whole, uuid id and integer id alike', () async {
    withFixtureDb(dbPath, (db) {
      db.execute(
        'INSERT INTO crew_settings (id, name_display_format, created_at) '
        "VALUES ('cs-1', 'lastFirst', 1700000000)",
      );
      db.execute(
        'INSERT INTO sidebar_settings (position, item_order) '
        "VALUES ('right', '{\"flights\": 1}')",
      );
    });
    final server = await start();

    final crew =
        payloadOf(await server.call('get_settings', {'table': 'crew_settings'}));
    expect(crew['id'], 'cs-1');
    expect(crew['name_display_format'], 'lastFirst');
    expect(crew['show_badge'], isTrue,
        reason: 'the default the app would have written shows as a boolean');

    final sidebar =
        payloadOf(await server.call('get_settings', {'table': 'sidebar_settings'}));
    expect(sidebar['id'], 1, reason: 'app-managed settings use an integer id');
    expect(sidebar['position'], 'right');
  });

  test('a typo argument names the tool that refused', () async {
    final server = await start();

    final envelope = errorOf(await server
        .call('get_settings', {'table': 'app_settings', 'tabel': 'crew'}));
    expect(envelope['error'], 'unknown_field');
    expect(envelope['tool'], 'get_settings');
    expect(envelope['field'], 'tabel');
  });
}
