import 'dart:convert';
import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Read behaviour that issue #9 turns into a promise: a filter that cannot be
/// applied is an error, a page says how many rows it left behind, ordering
/// matches the app, and a response states its units.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_read_test');
    dbPath = createEmptyFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<McpProcess> start({bool write = false}) async {
    final server = await McpProcess.start(dbPath, write: write);
    addTearDown(() async {
      await server.stop();
    });
    return server;
  }

  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) =>
      result.payload as Map<String, dynamic>;

  List<String> idsOf(Map<String, dynamic> payload) => [
        for (final flight in payload['flights'] as List)
          (flight as Map)['id'] as String
      ];

  test('rejects a date it cannot apply instead of dropping the filter',
      () async {
    insertFlights(dbPath, [
      {'id': 'fl-1', 'date': DateTime(2025, 3, 4), 'total_time': 60},
    ]);
    final server = await start();

    // Every one of these used to remove the filter and return career totals.
    for (final bad in [
      'garbage',
      '',
      '2025',
      '20250101',
      '2025-13-01',
      '2026-10-26T20:00:00Z',
    ]) {
      for (final tool in ['list_flights', 'logbook_stats']) {
        final result = await server.call(tool, {'date_from': bad});
        expect(result.isError, isTrue,
            reason: '$tool must reject date_from "$bad"');
        expect('${result.payload}', contains('YYYY-MM-DD'),
            reason: 'the error must name the accepted format');
        expect('${result.payload}', contains('date_from'));
      }
      final searched = await server
          .call('search_flights', {'query': 'YSSY', 'date_to': bad});
      expect(searched.isError, isTrue,
          reason: 'search_flights must reject date_to "$bad"');
      expect('${searched.payload}', contains('YYYY-MM-DD'));
    }

    // A sound date still filters normally.
    final good = await server.call('list_flights', {'date_from': '2025-03-04'});
    expect(good.isError, isFalse, reason: '${good.payload}');
    expect(payloadOf(good)['total'], 1);
  });

  test('a period preset resolves to the window it echoes back', () async {
    final today = DateTime.now();
    insertFlights(dbPath, [
      // Inside every last-N-days window tested here.
      {'id': 'fl-recent', 'date': today, 'total_time': 60},
      // Outside last_90_days.
      {
        'id': 'fl-old',
        'date': DateTime(today.year, today.month, today.day - 200),
        'total_time': 90,
      },
      {
        'id': 'fl-quarter',
        'date': DateTime(today.year, today.month, today.day - 30),
        'total_time': 30,
      },
    ]);
    final server = await start();

    final preset = payloadOf(
        await server.call('list_flights', {'period': 'last_90_days'}));
    final range = preset['range'] as Map;
    expect(range['to'], formatCalendarDate(today));
    expect(
      range['from'],
      formatCalendarDate(DateTime(today.year, today.month, today.day - 89)),
      reason: 'last_90_days includes today and the 89 preceding dates',
    );
    expect(idsOf(preset), ['fl-recent', 'fl-quarter']);
    expect(preset['total'], 2);

    // The same window written out by hand selects the same rows.
    final explicit = payloadOf(await server.call(
        'list_flights', {'date_from': range['from'], 'date_to': range['to']}));
    expect(explicit['range'], range);
    expect(explicit['total'], preset['total']);
    expect(idsOf(explicit), idsOf(preset));

    // this_year is a calendar year, not a rolling window.
    final year =
        payloadOf(await server.call('logbook_stats', {'period': 'this_year'}));
    expect((year['range'] as Map)['from'], '${today.year}-01-01');
    expect((year['range'] as Map)['to'], '${today.year}-12-31');
  });

  test('rejects contradictory or unknown window arguments', () async {
    final server = await start();

    final both = await server.call(
        'list_flights', {'period': 'last_7_days', 'date_from': '2025-01-01'});
    expect(both.isError, isTrue);
    expect('${both.payload}', contains('period'));

    final unknown =
        await server.call('list_flights', {'period': 'last_6_months'});
    expect(unknown.isError, isTrue,
        reason: 'the schema lists the allowed presets, so an unknown one is '
            'refused before the callback runs');
    expect('${unknown.payload}', contains('period'));

    final reversed = await server.call(
        'logbook_stats', {'date_from': '2025-12-31', 'date_to': '2025-01-01'});
    expect(reversed.isError, isTrue);
    expect('${reversed.payload}', contains('date_from'));
  });

  test('a page reports the total and what it left behind', () async {
    insertFlights(dbPath, [
      for (var day = 1; day <= 5; day++)
        {
          'id': 'fl-$day',
          'date': DateTime(2025, 6, day),
          'total_time': 60,
        },
    ]);
    final server = await start();

    final first = payloadOf(await server.call('list_flights', {'limit': 2}));
    expect(first['count'], 2, reason: 'count stays the page size');
    expect(first['total'], 5);
    expect(first['has_more'], isTrue);
    expect(first['offset'], 0);
    expect(idsOf(first), ['fl-5', 'fl-4']);

    final last =
        payloadOf(await server.call('list_flights', {'limit': 2, 'offset': 4}));
    expect(last['count'], 1);
    expect(last['total'], 5);
    expect(last['has_more'], isFalse);
    expect(last['offset'], 4);
    expect(idsOf(last), ['fl-1']);

    final past = payloadOf(
        await server.call('list_flights', {'limit': 2, 'offset': 10}));
    expect(past['count'], 0);
    expect(past['total'], 5);
    expect(past['has_more'], isFalse);

    // Filters narrow the total, so the envelope never counts filtered-out rows.
    final filtered = payloadOf(await server
        .call('list_flights', {'limit': 2, 'date_from': '2025-06-04'}));
    expect(filtered['total'], 2);
    expect(filtered['has_more'], isFalse);
  });

  test('search_flights pages, offsets and filters by date', () async {
    insertFlights(dbPath, [
      for (var day = 1; day <= 4; day++)
        {
          'id': 'fl-s$day',
          'date': DateTime(2025, 7, day),
          'route': 'YSSY - NZQN',
          'total_time': 120,
        },
      {
        'id': 'fl-other',
        'date': DateTime(2025, 7, 5),
        'route': 'YSBK - YSSY',
        'total_time': 30,
      },
    ]);
    final server = await start();

    final first = payloadOf(
        await server.call('search_flights', {'query': 'NZQN', 'limit': 2}));
    expect(first['count'], 2);
    expect(first['total'], 4);
    expect(first['has_more'], isTrue);
    expect(idsOf(first), ['fl-s4', 'fl-s3']);

    final last = payloadOf(await server
        .call('search_flights', {'query': 'NZQN', 'limit': 2, 'offset': 2}));
    expect(last['count'], 2);
    expect(last['has_more'], isFalse);
    expect(idsOf(last), ['fl-s2', 'fl-s1']);

    // The missing date bounds: only the two July flights from the 3rd on.
    final bounded = payloadOf(await server.call('search_flights', {
      'query': 'YSSY',
      'date_from': '2025-07-03',
      'date_to': '2025-07-04',
    }));
    expect(bounded['total'], 2);
    expect(bounded['range'], {'from': '2025-07-03', 'to': '2025-07-04'});
    expect(idsOf(bounded), ['fl-s4', 'fl-s3']);
  });

  test('orders flights the way the app does', () async {
    insertFlights(dbPath, [
      {'id': 'fl-a', 'date': DateTime(2025, 5, 1), 'day_order': 0},
      {'id': 'fl-b', 'date': DateTime(2025, 5, 1), 'day_order': 1},
      {'id': 'fl-e', 'date': DateTime(2025, 5, 1), 'day_order': 1},
      {'id': 'fl-c', 'date': DateTime(2025, 5, 2), 'day_order': 0},
    ]);
    final server = await start();

    // Newest date first, then the later flight of a day, then id ascending.
    const expected = ['fl-c', 'fl-b', 'fl-e', 'fl-a'];
    expect(idsOf(payloadOf(await server.call('list_flights', {}))), expected);

    final resource =
        await server.send('resources/read', {'uri': 'falcon://flights'});
    final contents =
        ((resource['result'] as Map)['contents'] as List).single as Map;
    final rows =
        (jsonDecode(contents['text'] as String) as Map)['rows'] as List;
    expect(
      [for (final row in rows) (row as Map)['id'] as String],
      expected,
      reason: 'the resource lists flights in the same order',
    );
  });

  test('splits complete, draft and simulator rows in logbook_stats', () async {
    insertFlights(dbPath, [
      {
        'id': 'fl-1',
        'date': DateTime(2025, 2, 1),
        'total_time': 120,
        'day_time': 90,
        'night_time': 30,
      },
      {'id': 'fl-draft', 'date': DateTime(2025, 2, 2)},
      {
        'id': 'fl-sim',
        'date': DateTime(2025, 2, 3),
        'total_time': 60,
        'is_simulator': 1,
      },
    ]);
    final server = await start();

    final stats = payloadOf(await server.call('logbook_stats', {}));
    expect(stats['flights'], 3, reason: 'drafts stay in flights');
    expect(stats['flights_complete'], 2);
    expect(stats['drafts'], 1);
    expect(stats['total_minutes'], 180);
    expect(stats['sim_flights'], 1);
    expect(stats['sim_minutes'], 60);

    // The date filter has to move the counts and the sums together.
    final window = payloadOf(await server.call(
        'logbook_stats', {'date_from': '2025-02-03', 'date_to': '2025-02-03'}));
    expect(window['flights'], 1);
    expect(window['total_minutes'], 60);
    expect(window['night_minutes'], 0);
    expect(window['range'], {'from': '2025-02-03', 'to': '2025-02-03'});

    final empty = payloadOf(
        await server.call('logbook_stats', {'date_from': '2030-01-01'}));
    expect(empty['flights'], 0);
    expect(empty['has_more'], isNull, reason: 'stats are not paged');
  });

  test('excludes other owners unless include_shared is set', () async {
    insertFlights(dbPath, [
      {
        'id': 'fl-local',
        'date': DateTime(2025, 1, 1),
        'total_time': 60,
        'owner_id': 'local',
      },
      {'id': 'fl-null', 'date': DateTime(2025, 1, 2), 'total_time': 60},
      {
        'id': 'fl-foreign',
        'date': DateTime(2025, 1, 3),
        'total_time': 90,
        'owner_id': 'other-device',
      },
    ]);
    withFixtureDb(dbPath, (db) {
      db.execute(
        "INSERT INTO aircraft (id, type, country_code, registration, owner_id) "
        "VALUES ('ac-foreign', 'C172', 'VH', 'ZZZ', 'other-device')",
      );
      db.execute(
        "INSERT INTO crew_members (id, name, first_name, last_name, owner_id) "
        "VALUES ('cr-foreign', 'Other Pilot', 'Other', 'Pilot', 'other-device')",
      );
    });
    final server = await start();

    expect(payloadOf(await server.call('list_flights', {}))['total'], 2);
    final shared =
        payloadOf(await server.call('list_flights', {'include_shared': true}));
    expect(shared['total'], 3);
    expect(idsOf(shared), ['fl-foreign', 'fl-null', 'fl-local']);

    // The resource takes no arguments, so it defaults to local rows only.
    final resource =
        await server.send('resources/read', {'uri': 'falcon://flights'});
    final contents =
        ((resource['result'] as Map)['contents'] as List).single as Map;
    final rows =
        (jsonDecode(contents['text'] as String) as Map)['rows'] as List;
    expect(
      [for (final row in rows) (row as Map)['id'] as String],
      ['fl-null', 'fl-local'],
    );

    final stats = payloadOf(await server.call('logbook_stats', {}));
    expect(stats['flights'], 2);
    expect(stats['total_minutes'], 120);

    expect((await server.call('get_flight', {'id': 'fl-foreign'})).isError,
        isTrue);
    expect(
      payloadOf(await server.call('get_flight',
          {'id': 'fl-foreign', 'include_shared': true}))['total_time'],
      90,
    );

    expect(payloadOf(await server.call('list_aircraft', {}))['count'], 0);
    expect(
        payloadOf(await server.call('list_aircraft', {'include_shared': true}))[
            'count'],
        1);
    expect(payloadOf(await server.call('list_crew', {}))['count'], 0);
    expect(
      payloadOf(
          await server.call('list_crew', {'include_shared': true}))['count'],
      1,
    );
  });

  test('rejects an unknown read argument instead of ignoring it', () async {
    final server = await start();

    final typo = await server.call('logbook_stats', {'date_fom': '2025-01-01'});
    expect(typo.isError, isTrue);
    expect('${typo.payload}', contains('date_fom'));

    final limitTypo = await server.call('list_flights', {'limt': 5});
    expect(limitTypo.isError, isTrue);
    expect('${limitTypo.payload}', contains('limt'));

    for (final (tool, args) in [
      ('get_flight', <String, dynamic>{'id': 'x', 'ide': 'y'}),
      ('list_airports', <String, dynamic>{'qurey': 'YSSY'}),
      ('db_info', <String, dynamic>{'db': 'other.sqlite'}),
      ('find_missing_times', <String, dynamic>{'limt': 1}),
    ]) {
      final result = await server.call(tool, args);
      expect(result.isError, isTrue, reason: '$tool must reject unknown args');
      // The envelope says which tool refused as well as which field was wrong,
      // because this loop is exactly the "three tools in a row" case.
      final envelope = jsonDecode('${result.payload}') as Map;
      expect(envelope['error'], 'unknown_field', reason: tool);
      expect(envelope['tool'], tool);
      expect(envelope['field'], args.keys.last);
    }
  });

  test('states units on every response that carries time', () async {
    insertFlights(dbPath, [
      {
        'id': 'fl-1',
        'date': DateTime(2025, 3, 4),
        'route': 'YSSY - NZQN',
        'total_time': 60,
      },
    ]);
    final server = await start();

    final declarations = <String, String>{};
    Object? serialisedDate;
    for (final (tool, args) in [
      ('list_flights', <String, dynamic>{}),
      ('search_flights', <String, dynamic>{'query': 'YSSY'}),
      ('get_flight', <String, dynamic>{'id': 'fl-1'}),
      ('logbook_stats', <String, dynamic>{}),
      ('find_missing_times', <String, dynamic>{}),
    ]) {
      final payload = payloadOf(await server.call(tool, args));
      final units = payload['units'] as Map;
      expect(units['time'], 'minutes',
          reason: '$tool must state its time unit');
      declarations[tool] = '${units['date']}';
      serialisedDate ??= _serialisedDate(payload);
    }

    // Asserted against the shape of a value the server actually returns, not
    // against a literal: the date columns are rendered as YYYY-MM-DD calendar
    // dates in the logbook zone, so a declaration that says epoch seconds or
    // an ISO timestamp fails here.
    expect(serialisedDate, isNotNull,
        reason: 'a row date to check the declaration against');
    expect(declarations.values.toSet(), hasLength(1),
        reason: 'every response declares the same date type: $declarations');
    expect(declarations.values.toSet().single, dateTypeOf(serialisedDate));
  });

  test('accepts hours aliases on write and rejects supplying both forms',
      () async {
    final server = await start(write: true);

    final created = await server.call('create_flight', {
      'date': '2025-04-01',
      'total_time_hours': 1.5,
      'night_time_hours': 0.5,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');
    final id = payloadOf(created)['id'] as String;
    final read = payloadOf(await server.call('get_flight', {'id': id}));
    expect(read['total_time'], 90);
    expect(read['night_time'], 30);

    // The complete split (60 day + 30 night = 90 total) is the app's own rule,
    // so this stays a test of the hours conversion rather than of the split
    // check added for issue #10.
    final updated = await server.call('update_flight', {
      'id': id,
      'day_time_hours': 1,
    });
    expect(updated.isError, isFalse, reason: '${updated.payload}');
    expect(
        payloadOf(await server.call('get_flight', {'id': id}))['day_time'], 60);

    final both = await server.call('create_flight', {
      'date': '2025-04-02',
      'total_time': 60,
      'total_time_hours': 1,
    });
    expect(both.isError, isTrue);
    expect('${both.payload}', contains('total_time_hours'));
  });
}

/// A date value [payload] serialises, or null when it carries no row date
/// (logbook_stats answers with a calendar range, not a row).
Object? _serialisedDate(Map<String, dynamic> payload) {
  final flights = payload['flights'];
  if (flights is List && flights.isNotEmpty) {
    return (flights.first as Map)['date'];
  }
  return payload['date'];
}
