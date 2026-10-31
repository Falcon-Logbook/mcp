import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #10 section 4: an agent that has assembled a write can only find out
/// what is wrong by writing it. dry_run: true answers exactly what the write
/// would answer - the resolved row, computed ids, warnings - and commits
/// nothing, so the guided flows can preview, ask, then apply.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_dry_run_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<McpProcess> start() async {
    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });
    return server;
  }

  /// Errors arrive as raw text; successes arrive decoded.
  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) =>
      result.isError
          ? throw StateError('call failed: ${result.payload}')
          : result.payload as Map<String, dynamic>;

  Map<String, dynamic> errorPayloadOf(
          ({bool isError, Object? payload}) result) =>
      jsonDecode(result.payload as String) as Map<String, dynamic>;

  /// Every row count that a write tool can touch, so a dry run can prove it
  /// moved none of them.
  Map<String, int> tableCounts() => withFixtureDb(dbPath, (db) {
        final counts = <String, int>{};
        for (final table in [
          'flights',
          'aircraft',
          'crew_members',
          'custom_airports',
          'saved_routes',
          'flights_settings',
          'sync_deletions',
        ]) {
          final row = db.select('SELECT COUNT(*) AS n FROM $table').first;
          counts[table] = row['n'] as int;
        }
        return counts;
      });

  test('every write tool advertises dry_run and no read tool does', () async {
    final server = await start();
    final tools =
        (await server.send('tools/list', {}))['result']['tools'] as List;
    final offenders = <String>[];
    for (final tool in tools) {
      final has = (tool['inputSchema']['properties'] ?? {})
          .containsKey('dry_run') as bool;
      final writes = tool['annotations']['readOnlyHint'] == false;
      if (writes && !has) offenders.add('missing on ${tool['name']}');
      if (!writes && has) offenders.add('present on ${tool['name']}');
    }
    expect(offenders, isEmpty, reason: offenders.join('; '));
  });

  test('create_flight dry_run resolves the row and writes nothing', () async {
    final before = tableCounts();
    final server = await start();

    final result = await server.call('create_flight', {
      'dry_run': true,
      'date': '2026-03-01',
      'aircraft_registration': 'VH-XZO',
      'crew_members_name': 'Jane Doe',
      'route': 'YSSY - NZQN',
      'total_time_hours': 1.5,
      'day_time_hours': 1.5,
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    final payload = payloadOf(result);
    expect(payload['dry_run'], isTrue,
        reason: 'the response says it is a preview');
    expect(payload['status'], 'created');
    final flight = payload['flight'] as Map<String, dynamic>;
    expect(flight['id'], isNotEmpty, reason: 'the resolved id is in the row');
    expect(flight['aircraft_id'], 'ac-1',
        reason: 'the registration linked to the fixture aircraft');
    expect(flight['crew_member_id'], 'cr-1');
    expect(flight['total_time'], 90, reason: 'hours arrive as minutes');
    expect(flight['day_order'], isNotNull);
    expect(tableCounts(), before,
        reason: 'a preview commits nothing, not even the row it resolved');
  });

  test('a dry run that the write would refuse returns that error', () async {
    final before = tableCounts();
    final server = await start();

    final result = await server.call('create_flight', {
      'dry_run': true,
      'date': '2026-03-01',
      'route': 'YSSY - NZQN',
      'total_time': 100,
      'day_time': 100,
      'night_time': 30,
    });

    expect(result.isError, isTrue);
    final payload = errorPayloadOf(result);
    expect(payload['error'], 'invalid_value',
        reason: 'a preview error is the write error');
    expect(tableCounts(), before);
  });

  test('update_flight dry_run shows the row as written and changes nothing',
      () async {
    final before = tableCounts();
    final server = await start();

    // Every value differs from the seeded row, so a preview that leaked the
    // write would show up in the stored row rather than matching by accident.
    final result = await server.call('update_flight', {
      'dry_run': true,
      'id': 'fl-1',
      'route': 'YSSY - YBBN',
      'total_time': 45,
      'day_time': 45,
      'night_time': 0,
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    final payload = payloadOf(result);
    expect(payload['dry_run'], isTrue);
    expect((payload['flight'] as Map)['route'], 'YSSY - YBBN',
        reason: 'the preview answers the row as the write would leave it');
    expect(payload['flight']['total_time'], 45,
        reason: 'the preview reports the total it was given');
    final stored = withFixtureDb(
        dbPath,
        (db) =>
            db.select('SELECT * FROM flights WHERE id = ?', ['fl-1']).single);
    expect(stored['route'], 'YSSY - NZQN',
        reason: 'the stored row is untouched');
    expect(stored['total_time'], 120,
        reason: 'the stored total is the seeded 120, not the previewed 45');
    expect(tableCounts(), before);
  });

  test('a dry run with a stale expected_updated_at still conflicts', () async {
    final server = await start();
    withFixtureDb(dbPath, (db) {
      db.execute(
          'UPDATE flights SET updated_at = 1700000100 WHERE id = ?', ['fl-1']);
    });

    final result = await server.call('update_flight', {
      'dry_run': true,
      'id': 'fl-1',
      'expected_updated_at': 1700000000,
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isTrue);
    final payload = errorPayloadOf(result);
    expect(payload['error'], 'conflict');
    expect(payload['current'], isNotNull,
        reason: 'the conflict carries the current row, as the write would');
  });

  test('delete_flight dry_run deletes nothing and writes no tombstone',
      () async {
    final before = tableCounts();
    final server = await start();

    final result = await server.call('delete_flight', {
      'dry_run': true,
      'id': 'fl-1',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    final payload = payloadOf(result);
    expect(payload['dry_run'], isTrue);
    expect(payload['status'], 'deleted');
    expect(tableCounts(), before,
        reason: 'no row went, and sync_deletions gained no tombstone');
  });

  test('add_aircraft dry_run refuses a clash and otherwise writes nothing',
      () async {
    final before = tableCounts();
    final server = await start();

    final clash = await server.call('add_aircraft', {
      'dry_run': true,
      'type': 'A320',
      'country_code': 'VH',
      'registration': 'XZO',
    });
    expect(clash.isError, isTrue, reason: 'the clash the write would hit');
    expect(errorPayloadOf(clash)['error'], 'invalid_value');

    final clean = await server.call('add_aircraft', {
      'dry_run': true,
      'type': 'A320',
      'country_code': 'VH',
      'registration': 'QLK',
    });
    expect(clean.isError, isFalse, reason: '${clean.payload}');
    expect(payloadOf(clean)['dry_run'], isTrue);
    expect(tableCounts(), before);
  });

  test('update_flight_settings dry_run previews a row it never creates',
      () async {
    final server = await start();
    withFixtureDb(dbPath, (db) => db.execute('DELETE FROM flights_settings'));

    final before = tableCounts();
    final result = await server.call('update_flight_settings', {
      'dry_run': true,
      'pilot_name': 'Self',
      'flight_time_format': 'decimal1',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    final payload = payloadOf(result);
    expect(payload['dry_run'], isTrue);
    expect((payload['settings'] as Map)['flight_time_format'], 'decimal1',
        reason: 'the preview answers the settings as the insert would leave '
            'them, though the row does not exist yet');
    expect(tableCounts(), before,
        reason: 'the insert-if-missing must not insert on a preview');
  });

  test('dry_run: false writes for real', () async {
    final server = await start();

    final result = await server.call('create_flight', {
      'dry_run': false,
      'date': '2026-03-01',
      'route': 'YSSY - NZQN',
      'total_time': 90,
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    final payload = payloadOf(result);
    expect(payload.containsKey('dry_run'), isFalse,
        reason: 'a real write is not marked');
    expect(tableCounts()['flights'], 3);
  });
}
