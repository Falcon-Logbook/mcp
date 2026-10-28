import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Per-entity totals: minutes and flight counts per aircraft, crew member, type
/// and registration, aggregated the way the app's own accessors aggregate them.
///
/// The logbook below is built so every rule the tool claims can be pinned to a
/// number: a second aircraft of the same type, a draft on an aircraft with no
/// complete flight, a simulator flight, a row owned by another device, a flight
/// with registration text but no aircraft link, and one with a crew name but no
/// crew link. The expected totals are the app's:
/// `getFlightTimeTotalsForAircraft` plus `getFlightCountForAircraft`, both of
/// which filter `total_time IS NOT NULL` and the local rows.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_totals_test');
    dbPath = createEmptyFixture('${tempDir.path}/falcon_db.sqlite');
    _seedLogbook(dbPath);
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

  List<Map<String, dynamic>> entitiesOf(Map<String, dynamic> payload) =>
      (payload['entities'] as List).cast<Map<String, dynamic>>();

  /// The totals as `label -> (minutes, flights_complete)`, in the order
  /// returned, so a test can assert both the numbers and the ordering.
  List<(String, int, int)> totals(
    Map<String, dynamic> payload,
    String key,
  ) =>
      [
        for (final entity in entitiesOf(payload))
          (
            '${entity[key]}',
            entity['minutes'] as int,
            entity['flights_complete'] as int,
          ),
      ];

  test('aircraft totals are the app\'s aircraft hours and count accessors',
      () async {
    final server = await start();
    final payload =
        payloadOf(await server.call('entity_totals', {'type': 'aircraft'}));

    expect(totals(payload, 'aircraft_id'), [
      // ac-3: 30 minutes of flight plus the 200-minute simulator sector.
      ('ac-3', 230, 2),
      // ac-1: 120 + 90, and the draft on the same aircraft is in neither number.
      ('ac-1', 210, 2),
      // ac-2: 60 + the 15-minute flight with no crew link.
      ('ac-2', 75, 2),
    ]);
    expect(payload['total'], 3,
        reason: 'ac-4 has only a draft, so it has no totals to list');
    expect(payload['count'], 3);
    expect(payload['type'], 'aircraft');
    expect(payload['sort'], 'minutes');
    expect(payload['include_simulator'], isTrue);
    expect((payload['units'] as Map)['time'], 'minutes');

    final first = entitiesOf(payload).first;
    expect(first['registration'], 'VH-DEF',
        reason: 'the display registration, country code and tail joined');
    expect(first['aircraft_type'], 'B738');
    expect(first.containsKey('flights'), isFalse,
        reason: 'flights means every row in logbook_stats, so the complete '
            'count is named flights_complete here too');
  });

  test('crew totals count only flights with a crew link', () async {
    final server = await start();
    final payload =
        payloadOf(await server.call('entity_totals', {'type': 'crew'}));

    expect(totals(payload, 'crew_member_id'), [
      ('cr-1', 240, 3),
      ('cr-2', 105, 2),
    ]);
    expect(payload['total'], 2);
    expect(entitiesOf(payload).first['name'], 'Jane Doe');
  });

  test('type groups on the linked aircraft, so it outranks either aircraft',
      () async {
    final server = await start();
    final payload =
        payloadOf(await server.call('entity_totals', {'type': 'type'}));

    expect(totals(payload, 'aircraft_type'), [
      // ac-1 and ac-3 are both B738: 210 + 230 minutes over four flights.
      ('B738', 440, 4),
      ('C172', 75, 2),
    ]);
  });

  test('registration groups on the flight text, including an unlinked flight',
      () async {
    final server = await start();
    final payload =
        payloadOf(await server.call('entity_totals', {'type': 'registration'}));

    expect(totals(payload, 'aircraft_registration'), [
      ('VH-XZO', 210, 2),
      ('VH-SIM', 200, 1),
      ('VH-ABC', 75, 2),
      ('VH-ZZZ', 45, 1),
      ('VH-DEF', 30, 1),
    ]);
    expect(payload['total'], 5,
        reason: 'VH-GHI is a draft, and the other owner\'s row is not local');
  });

  test('sort orders by the other number or by label', () async {
    final server = await start();

    final byFlights = payloadOf(await server.call(
        'entity_totals', {'type': 'registration', 'sort': 'flights_complete'}));
    expect(totals(byFlights, 'aircraft_registration'), [
      // Two flights each, then the key breaks the tie alphabetically.
      ('VH-ABC', 75, 2),
      ('VH-XZO', 210, 2),
      ('VH-DEF', 30, 1),
      ('VH-SIM', 200, 1),
      ('VH-ZZZ', 45, 1),
    ]);

    final byLabel = payloadOf(await server
        .call('entity_totals', {'type': 'registration', 'sort': 'label'}));
    expect([
      for (final row in totals(byLabel, 'aircraft_registration')) row.$1
    ], [
      'VH-ABC',
      'VH-DEF',
      'VH-SIM',
      'VH-XZO',
      'VH-ZZZ',
    ]);
  });

  test('limit caps the list and total says what was left behind', () async {
    final server = await start();
    final payload = payloadOf(await server
        .call('entity_totals', {'type': 'registration', 'limit': 2}));

    expect(totals(payload, 'aircraft_registration'), [
      ('VH-XZO', 210, 2),
      ('VH-SIM', 200, 1),
    ]);
    expect(payload['count'], 2);
    expect(payload['total'], 5, reason: 'the top two are not the whole fleet');
  });

  test('include_simulator: false drops the simulator sector from both numbers',
      () async {
    final server = await start();

    final aircraft = payloadOf(await server.call(
        'entity_totals', {'type': 'aircraft', 'include_simulator': false}));
    expect(totals(aircraft, 'aircraft_id'), [
      ('ac-1', 210, 2),
      ('ac-2', 75, 2),
      ('ac-3', 30, 1),
    ]);
    expect(aircraft['include_simulator'], isFalse);

    final type = payloadOf(await server
        .call('entity_totals', {'type': 'type', 'include_simulator': false}));
    expect(totals(type, 'aircraft_type'), [
      ('B738', 240, 3),
      ('C172', 75, 2),
    ]);

    final registration = payloadOf(await server.call(
        'entity_totals', {'type': 'registration', 'include_simulator': false}));
    expect(totals(registration, 'aircraft_registration'), [
      ('VH-XZO', 210, 2),
      ('VH-ABC', 75, 2),
      ('VH-ZZZ', 45, 1),
      ('VH-DEF', 30, 1),
    ]);
    expect(registration['total'], 4,
        reason: 'VH-SIM exists only as the simulator flight');
  });

  test('include_shared: true adds the other owner\'s row', () async {
    final server = await start();

    final aircraft = payloadOf(await server
        .call('entity_totals', {'type': 'aircraft', 'include_shared': true}));
    expect(totals(aircraft, 'aircraft_id'), [
      ('ac-2', 1074, 3),
      ('ac-3', 230, 2),
      ('ac-1', 210, 2),
    ]);

    final crew = payloadOf(await server
        .call('entity_totals', {'type': 'crew', 'include_shared': true}));
    expect(totals(crew, 'crew_member_id'), [
      ('cr-2', 1104, 3),
      ('cr-1', 240, 3),
    ]);
  });

  test('flights_complete is the same number logbook_stats reports', () async {
    final server = await start();
    final stats = payloadOf(await server.call('logbook_stats', {}));

    // Nine local rows: two are drafts, and one of those is on ac-4.
    expect(stats['flights'], 9);
    expect(stats['drafts'], 2);
    expect(stats['flights_complete'], 7);

    final aircraft =
        payloadOf(await server.call('entity_totals', {'type': 'aircraft'}));
    final complete = entitiesOf(aircraft)
        .fold<int>(0, (sum, e) => sum + (e['flights_complete'] as int));
    expect(complete, 6,
        reason: 'the two drafts and the unlinked flight are in no aircraft '
            'group, so the sum is lower than the logbook total');
  });

  test('an empty logbook is an empty list, not an error', () async {
    dbPath = createEmptyFixture('${tempDir.path}/second.sqlite');
    final server = await start();

    final payload =
        payloadOf(await server.call('entity_totals', {'type': 'crew'}));
    expect(payload['entities'], isEmpty);
    expect(payload['count'], 0);
    expect(payload['total'], 0);
  });

  test('a bad type or sort is refused with the field at fault', () async {
    final server = await start();

    final badType =
        errorOf(await server.call('entity_totals', {'type': 'route'}));
    expect(badType['error'], 'invalid_value');
    expect(badType['field'], 'type');
    expect(badType['detail'], contains('aircraft, crew, type, registration'));

    final badSort = errorOf(await server
        .call('entity_totals', {'type': 'aircraft', 'sort': 'hours'}));
    expect(badSort['error'], 'invalid_value');
    expect(badSort['field'], 'sort');

    // The declared minimum refuses a zero page before the callback runs, the
    // same way the paged reads refuse a limit above their maximum.
    final badLimit =
        await server.call('entity_totals', {'type': 'aircraft', 'limit': 0});
    expect(badLimit.isError, isTrue);
    expect('${badLimit.payload}', contains('limit'));

    final typo = errorOf(
        await server.call('entity_totals', {'type': 'aircraft', 'sortt': 'x'}));
    expect(typo['error'], 'unknown_field');
    expect(typo['tool'], 'entity_totals');
    expect(typo['field'], 'sortt');
  });
}

DateTime _day(int dayOfMonth) => DateTime(2026, 1, dayOfMonth);

void _seedLogbook(String dbPath) {
  withFixtureDb(dbPath, (db) {
    for (final (id, type, country, registration) in [
      ('ac-1', 'B738', 'VH', 'XZO'),
      ('ac-2', 'C172', 'VH', 'ABC'),
      ('ac-3', 'B738', 'VH', 'DEF'),
      ('ac-4', 'C152', 'VH', 'GHI'),
    ]) {
      db.execute(
        'INSERT INTO aircraft (id, type, country_code, registration, created_at) '
        'VALUES (?, ?, ?, ?, 1700000000)',
        [id, type, country, registration],
      );
    }
    for (final (id, name) in [('cr-1', 'Jane Doe'), ('cr-2', 'John Smith')]) {
      db.execute(
        'INSERT INTO crew_members (id, name, first_name, last_name, created_at) '
        "VALUES (?, ?, ?, ?, 1700000000)",
        [id, name, name.split(' ').first, name.split(' ').last],
      );
    }
  });
  insertFlights(dbPath, [
    // ac-1: two complete flights.
    {
      'id': 'fl-1',
      'date': _day(10),
      'aircraft_id': 'ac-1',
      'aircraft_registration': 'VH-XZO',
      'crew_member_id': 'cr-1',
      'total_time': 120,
    },
    {
      'id': 'fl-2',
      'date': _day(11),
      'aircraft_id': 'ac-1',
      'aircraft_registration': 'VH-XZO',
      'crew_member_id': 'cr-1',
      'total_time': 90,
    },
    // ac-2.
    {
      'id': 'fl-3',
      'date': _day(12),
      'aircraft_id': 'ac-2',
      'aircraft_registration': 'VH-ABC',
      'crew_member_id': 'cr-2',
      'total_time': 60,
    },
    // ac-3, and the simulator flight on the same aircraft.
    {
      'id': 'fl-4',
      'date': _day(13),
      'aircraft_id': 'ac-3',
      'aircraft_registration': 'VH-DEF',
      'crew_member_id': 'cr-1',
      'total_time': 30,
    },
    {
      'id': 'fl-sim',
      'date': _day(14),
      'aircraft_id': 'ac-3',
      'aircraft_registration': 'VH-SIM',
      'total_time': 200,
      'is_simulator': 1,
    },
    // A draft belongs to no total: it has no time to sum and the app's count
    // accessors skip it.
    {
      'id': 'fl-draft',
      'date': _day(15),
      'aircraft_id': 'ac-1',
      'aircraft_registration': 'VH-XZO',
      'crew_member_id': 'cr-1',
    },
    // ac-4 has one flight and it is a draft, so ac-4 has no totals at all.
    {
      'id': 'fl-draft-ac4',
      'date': _day(16),
      'aircraft_id': 'ac-4',
      'aircraft_registration': 'VH-GHI',
    },
    // Owned by another device: only when include_shared is true.
    {
      'id': 'fl-other',
      'date': _day(17),
      'aircraft_id': 'ac-2',
      'aircraft_registration': 'VH-ABC',
      'crew_member_id': 'cr-2',
      'total_time': 999,
      'owner_id': 'other',
    },
    // Registration text but no aircraft row: registration only.
    {
      'id': 'fl-nolink',
      'date': _day(18),
      'aircraft_registration': 'VH-ZZZ',
      'crew_member_id': 'cr-2',
      'total_time': 45,
    },
    // Crew name but no crew link: not a crew total.
    {
      'id': 'fl-nocrew',
      'date': _day(19),
      'aircraft_id': 'ac-2',
      'aircraft_registration': 'VH-ABC',
      'crew_members_name': 'Ghost Writer',
      'total_time': 15,
    },
  ]);
}
