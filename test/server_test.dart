import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_server_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('read-only mode hides write tools and still answers reads', () async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    final tools = await server.toolNames();
    expect(
        tools,
        containsAll(
            ['db_info', 'list_flights', 'get_schema', 'logbook_stats']));
    for (final writeTool in [
      'create_flight',
      'update_flight',
      'delete_flight',
      'add_aircraft',
      'delete_crew',
      'add_saved_route',
      'update_flight_settings',
    ]) {
      expect(tools, isNot(contains(writeTool)),
          reason: '$writeTool must be hidden');
    }

    final info = await server.call('db_info', {});
    expect(info.isError, isFalse);
    expect((info.payload as Map)['readonly'], isTrue);

    final flights = await server.call('list_flights', {'limit': 5});
    expect((flights.payload as Map)['count'], 2);

    final stats = await server.call('logbook_stats', {});
    expect((stats.payload as Map)['flights'], 2);
    expect((stats.payload as Map)['drafts'], 1);
    expect((stats.payload as Map)['total_minutes'], 120);
  });

  test('schema resource and get_schema describe the database', () async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    final schema = await server.call('get_schema', {'table': 'flights'});
    final columns = (schema.payload as Map)['flights'] as List;
    expect(
      columns.map((column) => (column as Map)['name']),
      containsAll(['date', 'aircraft_id', 'total_time', 'time_start']),
    );

    final missing = await server.call('get_schema', {'table': 'nope'});
    expect(missing.isError, isTrue);

    final resource =
        await server.send('resources/read', {'uri': 'falcon://schema'});
    final contents =
        ((resource['result'] as Map)['contents'] as List).single as Map;
    expect(contents['mimeType'], 'application/json');
    expect(contents['text'], contains('aircraft_registration'));
  });

  test('flight writes link aircraft and crew and record an audit line',
      () async {
    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    expect(await server.toolNames(), contains('create_flight'));

    final created = await server.call('create_flight', {
      'date': '2026-10-27',
      'aircraft_registration': 'xzo',
      'flight_type': 'route',
      'route': 'YSSY - NZQN',
      'crew_members_name': 'Jane Doe',
      'total_time': 95,
      'time_start': '08:00',
      'time_stop': '09:35',
      'is_ifr': true,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');
    final id = (created.payload as Map)['id'] as String;

    withFixtureDb(dbPath, (db) {
      final row = db.select('SELECT * FROM flights WHERE id = ?', [id]).single;
      // Registration is normalised to the display form and linked to the row.
      expect(row['aircraft_registration'], 'VH-XZO');
      expect(row['aircraft_id'], 'ac-1');
      expect(row['crew_member_id'], 'cr-1');
      expect(row['total_time'], 95);
      expect(row['time_start'], '08:00');
      expect(row['is_ifr'], 1);
      expect(row['is_simulator'], 0);
      expect(row['created_at'], isNotNull);
      // Local midnight of the requested date.
      expect(
        DateTime.fromMillisecondsSinceEpoch((row['date'] as int) * 1000).day,
        27,
      );
    });

    final updated = await server.call('update_flight', {
      'id': id,
      'total_time': 100,
      'crew_members_name': 'Jane Doe',
    });
    expect(updated.isError, isFalse, reason: '${updated.payload}');
    withFixtureDb(dbPath, (db) {
      final row = db.select(
          'SELECT total_time, updated_at FROM flights WHERE id = ?',
          [id]).single;
      expect(row['total_time'], 100);
      expect(row['updated_at'], isNotNull);
    });

    final unknown =
        await server.call('update_flight', {'id': id, 'block_off': 10});
    expect(unknown.isError, isTrue);
    expect(unknown.payload, contains('block_off'));

    final audit = File('${tempDir.path}/falcon_db.mcp_audit.jsonl');
    expect(audit.existsSync(), isTrue);
    final lines = audit.readAsLinesSync();
    expect(lines, hasLength(3));
    expect(lines.first, contains('"tool":"create_flight"'));
    expect(lines.first, contains('"result":"ok"'));
  });

  test('deletes record tombstones and unlink dependent rows', () async {
    withFixtureDb(dbPath, (db) {
      db.execute(
        "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
        "VALUES ('flights', 'postgres', 0, 0)",
      );
      db.execute(
        "INSERT INTO sync_deletions (sync_table, row_id, provider, created_at) "
        "VALUES ('flights', 'old-row', 'postgres', 1700000000)",
      );
      db.execute("UPDATE flights SET route_id = 1 WHERE id = 'fl-1'");
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final routeDelete = await server.call('delete_saved_route', {'id': 1});
    expect(routeDelete.isError, isFalse, reason: '${routeDelete.payload}');
    withFixtureDb(dbPath, (db) {
      expect(db.select('SELECT id FROM saved_routes').isEmpty, isTrue);
      expect(
          db
              .select("SELECT route_id FROM flights WHERE id = 'fl-1'")
              .single['route_id'],
          isNull);
    });

    final aircraftDelete = await server.call('delete_aircraft', {'id': 'ac-1'});
    expect(aircraftDelete.isError, isFalse,
        reason: '${aircraftDelete.payload}');
    withFixtureDb(dbPath, (db) {
      expect(
        db
            .select(
                "SELECT aircraft_id, aircraft_registration FROM flights WHERE id = 'fl-1'")
            .single,
        {'aircraft_id': null, 'aircraft_registration': 'VH-XZO'},
      );
      final tombstones = db
          .select(
              'SELECT sync_table, row_id FROM sync_deletions WHERE row_id != ?',
              ['old-row'])
          .map((row) => '${row['sync_table']}:${row['row_id']}')
          .toList();
      // saved_routes has no sync table in the app, so deleting a route only
      // unlinks flights; aircraft deletions do record a tombstone.
      expect(tombstones, ['aircraft:ac-1']);
    });

    final flightDelete = await server.call('delete_flight', {'id': 'fl-1'});
    expect(flightDelete.isError, isFalse, reason: '${flightDelete.payload}');
    expect((await server.call('get_flight', {'id': 'fl-1'})).isError, isTrue);
    withFixtureDb(dbPath, (db) {
      final tombstones = db
          .select('SELECT sync_table, row_id FROM sync_deletions')
          .map((row) => '${row['sync_table']}:${row['row_id']}')
          .toList();
      expect(tombstones,
          containsAll(['aircraft:ac-1', 'flights:fl-1', 'flights:old-row']));
    });
  });

  test('entity writes validate input and keep the app schema intact', () async {
    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final aircraft = await server.call('add_aircraft', {
      'type': 'C172',
      'country_code': 'vh',
      'registration': 'VH-ABC',
      'ifr': false,
    });
    expect(aircraft.isError, isFalse, reason: '${aircraft.payload}');
    withFixtureDb(dbPath, (db) {
      final row =
          db.select("SELECT * FROM aircraft WHERE registration = 'ABC'").single;
      expect(row['country_code'], 'VH');
      expect(row['ifr'], 0);
    });

    final duplicate = await server.call('add_aircraft', {
      'type': 'C172',
      'country_code': 'VH',
      'registration': 'ABC',
    });
    expect(duplicate.isError, isTrue);
    expect(duplicate.payload, contains('already exists'));

    final crew = await server
        .call('add_crew', {'first_name': 'Sam', 'last_name': 'Pilot'});
    expect(crew.isError, isFalse, reason: '${crew.payload}');
    expect((crew.payload as Map)['name'], 'Sam Pilot');

    final invalidAirport = await server.call('add_custom_airport', {
      'name': 'Back Paddock',
      'lat': 120,
    });
    expect(invalidAirport.isError, isTrue);
    expect(invalidAirport.payload, contains('lat'));

    final airport = await server.call('add_custom_airport', {
      'name': 'Back Paddock',
      'icao': 'YXPD',
      'lat': -33.9,
      'lon': 151.0,
    });
    expect(airport.isError, isFalse, reason: '${airport.payload}');

    final route = await server.call('add_saved_route', {
      'flight_number': 'QF2',
      'departure_icao': 'yssy',
      'arrival_icao': 'nzqn',
    });
    expect(route.isError, isFalse, reason: '${route.payload}');

    final settings = await server.call('update_flight_settings', {
      'pilot_name': 'Ada',
      'default_flight_type': 'details',
      'show_day_night': true,
    });
    expect(settings.isError, isFalse, reason: '${settings.payload}');
    withFixtureDb(dbPath, (db) {
      final row = db.select('SELECT * FROM flights_settings').single;
      expect(row['pilot_name'], 'Ada');
      expect(row['default_flight_type'], 'details');
      expect(row['show_day_night'], 1);
      expect(row['updated_at'], isNotNull);
    });

    final badEnum = await server
        .call('update_flight_settings', {'default_flight_type': 'warp'});
    expect(badEnum.isError, isTrue);
  });

  test('additive schema columns do not break reads or writes', () async {
    withFixtureDb(dbPath, (db) {
      db.execute('ALTER TABLE flights ADD COLUMN extra_note TEXT');
      db.execute('ALTER TABLE flights ADD COLUMN weather TEXT');
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final created = await server.call('create_flight', {
      'date': '2026-01-02',
      'total_time': 30,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');
    final schema = await server.call('get_schema', {'table': 'flights'});
    expect('${schema.payload}', contains('extra_note'));

    final read =
        await server.call('get_flight', {'id': (created.payload as Map)['id']});
    expect(read.isError, isFalse);
    expect((read.payload as Map)['total_time'], 30);
  });

  test('a v18 database hides the v19-only flight fields', () async {
    withFixtureDb(dbPath, (db) {
      for (final column in [
        'calc_time_mode',
        'time_start',
        'time_stop',
        'hobbs_start',
        'hobbs_stop'
      ]) {
        db.execute('ALTER TABLE flights DROP COLUMN $column');
      }
      db.execute('PRAGMA user_version = 18');
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final info = await server.call('db_info', {});
    expect((info.payload as Map)['schemaVersion'], 18);

    final listed = await server.send('tools/list', {});
    final tools = (listed['result'] as Map)['tools'] as List;
    final createFlight = tools
        .firstWhere((tool) => (tool as Map)['name'] == 'create_flight') as Map;
    final properties =
        (createFlight['inputSchema'] as Map)['properties'] as Map;
    expect(properties.keys, contains('total_time'));
    expect(properties.keys, isNot(contains('time_start')));

    final created = await server.call('create_flight', {
      'date': '2026-02-03',
      'total_time': 45,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');

    final rejected = await server.call('create_flight', {
      'date': '2026-02-03',
      'time_start': '09:00',
    });
    expect(rejected.isError, isTrue);
    expect(rejected.payload, contains('time_start'));
  });
}
