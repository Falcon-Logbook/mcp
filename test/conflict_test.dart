import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #10 section 2: a concurrent write from the app or a second agent
/// must not be silently overwritten. An update that sends expected_updated_at
/// applies only to the row as its caller read it; a stale expectation is a
/// conflict that returns the current row, and a vanished row is not_found
/// instead of a success that never wrote.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_conflict_test');
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

  /// Error payloads reach the harness as the raw JSON text of the envelope.
  Map<String, dynamic> errorPayloadOf(
          ({bool isError, Object? payload}) result) =>
      jsonDecode(result.payload as String) as Map<String, dynamic>;

  Map<String, dynamic>? rowOf(String table, String id) => withFixtureDb(
        dbPath,
        (db) => db.select('SELECT * FROM $table WHERE id = ?', [id]).isEmpty
            ? null
            : db.select('SELECT * FROM $table WHERE id = ?', [id]).single,
      );

  /// Stamps [table]'s row directly, the way a concurrent app write would, so
  /// a server-side read taken before this moment is stale afterwards.
  void stamp(String table, String id, int updatedAt) =>
      withFixtureDb(dbPath, (db) {
        db.execute(
            'UPDATE $table SET updated_at = ? WHERE id = ?', [updatedAt, id]);
      });

  test('a matching expected_updated_at updates the row', () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': 1700000100,
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - YBBN');
    expect(rowOf('flights', 'fl-1')!['updated_at'], greaterThan(1700000100),
        reason: 'a successful write stamps the row again');
  });

  test('the ISO stamp a read returns updates the row', () async {
    // Issue #56: reads render updated_at as ISO-8601 text, so that text is
    // what a caller following falcon://conventions has to pass back.
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);

    final read = (await server.call('get_flight', {'id': 'fl-1'})).payload
        as Map<String, dynamic>;
    final iso = read['updated_at'] as String;
    expect(iso, contains('T'));

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': iso,
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - YBBN');
    expect(rowOf('flights', 'fl-1')!['updated_at'], greaterThan(1700000100));
  });

  test('the same instant in another offset form also matches', () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': '2023-11-14T22:15:00.000Z',
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    expect(rowOf('flights', 'fl-1')!['updated_at'], greaterThan(1700000100));
  });

  test('a stale ISO stamp conflicts and the current stamp retries', () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);
    final stale = ((await server.call('get_flight', {'id': 'fl-1'})).payload
        as Map<String, dynamic>)['updated_at'] as String;

    // A concurrent app write moves the row on after the caller's read.
    stamp('flights', 'fl-1', 1700000200);

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': stale,
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isTrue);
    final payload = errorPayloadOf(result);
    expect(payload['error'], 'conflict');
    expect(payload['field'], 'expected_updated_at');
    final current = payload['current'] as Map<String, dynamic>;
    expect(current['id'], 'fl-1');
    final currentStamp = current['updated_at'] as String;
    expect(currentStamp, isNot(stale));
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - NZQN');

    // The value the conflict handed back is directly retryable.
    final retried = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': currentStamp,
      'route': 'YSSY - YBBN',
    });
    expect(retried.isError, isFalse, reason: '${retried.payload}');
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - YBBN');
  });

  test('a value in neither accepted form is refused, not ignored', () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);

    for (final value in <Object>[
      '',
      'yesterday',
      '1700000100 seconds',
      '2023-11-14',
      '2023-11-14T22:15:00',
      '2023-02-30T22:15:00.000+1100',
      '2023-11-14T22:15:00.500+1100',
      '2023-11-14T22:15:00.000+2500',
      '2023-11-14T25:15:00.000+1100',
    ]) {
      final result = await server.call('update_flight', {
        'id': 'fl-1',
        'expected_updated_at': value,
        'route': 'YSSY - YBBN',
      });
      expect(result.isError, isTrue, reason: 'accepted $value');
      final payload = errorPayloadOf(result);
      expect(payload['error'], 'invalid_value', reason: 'accepted $value');
      expect(payload['field'], 'expected_updated_at',
          reason: 'accepted $value');
    }

    // A negative epoch is outside the schema and refused before the handler.
    final negative = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': -1,
      'route': 'YSSY - YBBN',
    });
    expect(negative.isError, isTrue);

    // None of the refused calls wrote anything.
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - NZQN');
    expect(rowOf('flights', 'fl-1')!['updated_at'], 1700000100);
  });

  test('a stale expected_updated_at is a conflict with the current row',
      () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': 1700000000,
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isTrue);
    final payload = errorPayloadOf(result);
    expect(payload['error'], 'conflict');
    expect(payload['field'], 'expected_updated_at');
    expect(payload['tool'], 'update_flight');
    expect(payload['detail'], contains('1700000100'));
    final current = payload['current'] as Map<String, dynamic>;
    expect(current['id'], 'fl-1');
    // The envelope's current row is the rendered shape reads return, so the
    // stamp is ISO text; the stored value is named in the detail.
    expect(current['updated_at'], isA<String>());

    // The row is untouched: the concurrent change survives.
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - NZQN');
    expect(rowOf('flights', 'fl-1')!['updated_at'], 1700000100);
  });

  test('a row without a stamp conflicts once, then expects', () async {
    // Fixture rows were written before the server stamped updated_at, so the
    // first expectation cannot match. The conflict says what to do, the
    // unconditional retry stamps the row, and from then on expectations
    // work.
    final server = await start();
    expect(rowOf('flights', 'fl-1')!['updated_at'], isNull);

    final guarded = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': 0,
      'route': 'YSSY - YBBN',
    });
    expect(guarded.isError, isTrue);
    final payload = errorPayloadOf(guarded);
    expect(payload['error'], 'conflict');
    expect(payload['detail'], contains('no updated_at stamp'));
    expect((payload['current'] as Map<String, dynamic>)['updated_at'], isNull);
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - NZQN');

    final unguarded = await server.call('update_flight', {
      'id': 'fl-1',
      'route': 'YSSY - YBBN',
    });
    expect(unguarded.isError, isFalse, reason: '${unguarded.payload}');
    final stamped = rowOf('flights', 'fl-1')!['updated_at'] as int;

    final guardedAgain = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': stamped,
      'route': 'YSSY - YBBN - YBOK',
    });
    expect(guardedAgain.isError, isFalse, reason: '${guardedAgain.payload}');
  });

  test('an expected_updated_at on a deleted row is not_found, not a conflict',
      () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);
    await server.call('delete_flight', {'id': 'fl-1'});

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'expected_updated_at': 1700000100,
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isTrue);
    expect(errorPayloadOf(result)['error'], 'not_found');
  });

  test('an aircraft conflict preserves the concurrent rename', () async {
    // The issue's scenario: update_aircraft normalises registration and
    // country_code from its read, so a rename between read and write used to
    // be clobbered by the caller's stale copy.
    final server = await start();
    stamp('aircraft', 'ac-1', 1700000100);

    final result = await server.call('update_aircraft', {
      'id': 'ac-1',
      'expected_updated_at': 1700000000,
      'type': 'A320',
    });

    expect(result.isError, isTrue);
    final payload = errorPayloadOf(result);
    expect(payload['error'], 'conflict');
    expect(payload['tool'], 'update_aircraft');
    final current = payload['current'] as Map<String, dynamic>;
    expect(current['type'], 'B738');
    // The current row is the rendered shape reads return: the stamp comes
    // back as ISO text, not the stored epoch.
    expect(current['updated_at'], isA<String>());
    expect(rowOf('aircraft', 'ac-1')!['type'], 'B738');
  });

  test('aircraft, crew, custom airport, saved route and settings guard too',
      () async {
    final server = await start();
    final created =
        await server.call('add_custom_airport', {'name': 'My Strip'});
    final customId = (created.payload as Map<String, dynamic>)['id'] as String;
    final customStamp = withFixtureDb(
        dbPath,
        (db) => db.select('SELECT updated_at FROM custom_airports WHERE id = ?',
            [customId]).single['updated_at']) as int;

    stamp('crew_members', 'cr-1', 1700000100);
    stamp('saved_routes', '1', 1700000100);
    stamp('flights_settings', 'settings-1', 1700000100);

    final cases = <String,
        ({
      Future<({bool isError, Object? payload})> Function() call,
      String detail
    })>{
      'crew': (
        call: () => server.call('update_crew', {
              'id': 'cr-1',
              'expected_updated_at': 1,
              'name': 'Jane Dough',
            }),
        detail: '1700000100',
      ),
      'custom_airport': (
        call: () => server.call('update_custom_airport', {
              'id': customId,
              'expected_updated_at': customStamp + 1,
              'name': 'Renamed Strip',
            }),
        detail: '$customStamp',
      ),
      'saved_route': (
        call: () => server.call('update_saved_route', {
              'id': 1,
              'expected_updated_at': 1700000000,
              'flight_number': 'QF2',
            }),
        detail: '1700000100',
      ),
      'flight_settings': (
        call: () => server.call('update_flight_settings', {
              'expected_updated_at': 1700000000,
              'pilot_name': 'Someone Else',
            }),
        detail: '1700000100',
      ),
    };

    for (final entry in cases.entries) {
      final result = await entry.value.call();
      expect(result.isError, isTrue, reason: '${entry.key}: ${result.payload}');
      final payload = errorPayloadOf(result);
      expect(payload['error'], 'conflict', reason: entry.key);
      expect(payload['tool'], 'update_${entry.key}', reason: entry.key);
      expect(payload['detail'], contains(entry.value.detail),
          reason: entry.key);
      expect(payload['current'], isA<Map<String, dynamic>>(),
          reason: entry.key);
    }

    // Nothing was written by the refused calls.
    expect(rowOf('crew_members', 'cr-1')!['name'], 'Jane Doe');
    expect(rowOf('saved_routes', '1')!['flight_number'], 'QF1');
    expect(rowOf('flights_settings', 'settings-1')!['pilot_name'], 'Self');
  });

  test('settings creation ignores the guard it cannot match', () async {
    // A row this call inserts carries a stamp from now, so an expectation
    // taken from nothing must not block the create path.
    withFixtureDb(dbPath, (db) {
      db.execute("DELETE FROM flights_settings WHERE id = 'settings-1'");
    });

    final server = await start();
    final result = await server.call('update_flight_settings', {
      'expected_updated_at': 1700000000,
      'pilot_name': 'Self',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    final rows = withFixtureDb(
        dbPath, (db) => db.select('SELECT * FROM flights_settings'));
    expect(rows, hasLength(1));
    expect(rows.single['pilot_name'], 'Self');
    expect(rows.single['updated_at'], isNotNull);
  });

  test('omitting expected_updated_at still writes unconditionally', () async {
    final server = await start();
    stamp('flights', 'fl-1', 1700000100);

    final result = await server.call('update_flight', {
      'id': 'fl-1',
      'route': 'YSSY - YBBN',
    });

    expect(result.isError, isFalse, reason: '${result.payload}');
    expect(rowOf('flights', 'fl-1')!['route'], 'YSSY - YBBN');
    expect(rowOf('flights', 'fl-1')!['updated_at'], greaterThan(1700000100));
  });

  test('an unknown field is still rejected before the guard runs', () async {
    final server = await start();
    final result = await server.call('update_crew', {
      'id': 'cr-1',
      'expected_updated_at': 1700000100,
      'not_a_crew_field': true,
    });

    expect(result.isError, isTrue);
    expect(errorPayloadOf(result)['error'], 'unknown_field');
  });

  test('the conventions resource documents the conflict envelope', () async {
    final server = await start();
    final response =
        await server.send('resources/read', {'uri': 'falcon://conventions'});
    final text = (((response['result'] as Map)['contents'] as List).single
        as Map)['text'] as String;
    expect(text, contains('expected_updated_at'));
    expect(text, contains('conflict'));
  });
}
