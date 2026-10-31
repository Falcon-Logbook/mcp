import 'dart:convert';
import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart' show auditPathFor;
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

  test('exposes no sync or cloud surface', () async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    // The server is desktop-only and has no Falcon Cloud or sync awareness.
    // A reintroduced tool with these words in it means that scope came back.
    final tools = await server.toolNames();
    expect(
      tools.where(
          (tool) => RegExp(r'sync|cloud|server|provider').hasMatch(tool)),
      isEmpty,
      reason: 'desktop-only server must expose no sync or cloud tools',
    );
    expect(tools, isNot(contains('get_sync_status')));
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

    // The resource lists table names with their column counts, and leaves the
    // columns of a table to the tool: describing every table cost 11 KB on this
    // fixture and 33 KB on a real logbook.
    final resource =
        await server.send('resources/read', {'uri': 'falcon://schema'});
    final contents =
        ((resource['result'] as Map)['contents'] as List).single as Map;
    expect(contents['mimeType'], 'application/json');
    final listed = jsonDecode(contents['text'] as String) as Map;
    final flights = (listed['tables'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((table) => table['name'] == 'flights');
    expect(flights['columns'], columns.length,
        reason: 'the count and the column list come from one source');
    expect(contents['text'], isNot(contains('aircraft_registration')));
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
    // A recorded write reports no audit trouble.
    expect((created.payload as Map).containsKey('warning'), isFalse);
    expect((created.payload as Map).containsKey('audit_failed'), isFalse);
  });

  test('a committed write warns when its audit entry cannot be written',
      () async {
    // The audit path is a directory, so the append fails after the transaction
    // has committed. The write must still land and the response must say the
    // record is missing rather than swallow the failure.
    Directory(auditPathFor(dbPath)).createSync();
    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final created = await server.call('create_flight', {
      'date': '2026-10-27',
      'aircraft_registration': 'xzo',
      'flight_type': 'route',
      'route': 'YSSY - NZQN',
      'total_time': 95,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');
    final payload = created.payload as Map;
    expect(payload['audit_failed'], isTrue);
    expect('${payload['warning']}', contains(auditPathFor(dbPath)));
    expect('${payload['warning']}', isNot(contains('client_ref')),
        reason: 'a create has no imported refs to lose');

    // The row landed even though its record did not.
    final id = payload['id'] as String;
    withFixtureDb(dbPath, (db) {
      expect(
          db.select('SELECT id FROM flights WHERE id = ?', [id]), hasLength(1));
    });

    // A batch whose audit entry is lost also loses the log's only copy of its
    // client_ref values, so the warning says a retry may duplicate the rows.
    final applied = await server.call('apply_flight_batch', {
      'dry_run': false,
      'mode': 'import',
      'flights': [
        {
          'client_ref': 'imp-1',
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'total_time': 90,
        },
      ],
    });
    expect(applied.isError, isFalse, reason: '${applied.payload}');
    final batch = applied.payload as Map;
    expect(batch['applied'], 1);
    expect(batch['created_refs'], ['imp-1']);
    expect(batch['audit_failed'], isTrue);
    expect('${batch['warning']}', contains('client_ref'));
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

  test('tombstones are normalised, deduplicated and never duplicated',
      () async {
    // sync_state holding the app's legacy provider name must not hide the
    // tombstone from a push running under the canonical name, and a
    // tombstone that already exists must not be written twice.
    withFixtureDb(dbPath, (db) {
      db.execute(
        "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
        "VALUES ('flights', 'selfHostPg', 0, 0)",
      );
      // A tombstone the app itself already recorded for this row.
      db.execute(
        "INSERT INTO sync_deletions (sync_table, row_id, provider, created_at) "
        "VALUES ('flights', 'fl-1', 'postgres', 1700000000)",
      );
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final first = await server.call('delete_flight', {'id': 'fl-1'});
    expect(first.isError, isFalse, reason: '${first.payload}');

    // A second delete is a not_found error, not a silent success, and it
    // writes nothing.
    final second = await server.call('delete_flight', {'id': 'fl-1'});
    expect(second.isError, isTrue);
    expect(second.payload, contains('not_found'));
    expect(second.payload, contains('fl-1'));

    withFixtureDb(dbPath, (db) {
      final tombstones = db.select(
        "SELECT sync_table, row_id, provider FROM sync_deletions "
        "WHERE row_id = 'fl-1'",
      );
      // Exactly one tombstone for the row, under the canonical provider name:
      // the legacy sync_state row normalised onto the tombstone the app had
      // already written, so nothing new was inserted.
      expect(tombstones, [
        {'sync_table': 'flights', 'row_id': 'fl-1', 'provider': 'postgres'},
      ]);
    });
  });

  test('a tombstone is written for the canonical name only once per provider',
      () async {
    // A database that has synced under both the legacy and the canonical
    // provider name ends up with one tombstone, not two.
    withFixtureDb(dbPath, (db) {
      for (final provider in ['selfHostPg', 'postgres']) {
        db.execute(
          "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
          "VALUES ('flights', '$provider', 0, 0)",
        );
      }
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final deleted = await server.call('delete_crew', {'id': 'cr-1'});
    expect(deleted.isError, isFalse, reason: '${deleted.payload}');

    withFixtureDb(dbPath, (db) {
      final tombstones = db.select(
        "SELECT provider FROM sync_deletions WHERE row_id = 'cr-1'",
      );
      expect(tombstones.map((row) => row['provider']), ['postgres']);
    });
  });

  test('re-creating a deleted id clears its stale tombstone', () async {
    // Deleting a bad import and replaying it with the same ids is the reason
    // creates accept a caller-supplied id. The tombstone the delete wrote must
    // not outlive the re-create, or the next push deletes the new row again.
    withFixtureDb(dbPath, (db) {
      db.execute(
        "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
        "VALUES ('flights', 'postgres', 0, 0)",
      );
      db.execute(
        "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
        "VALUES ('aircraft', 'postgres', 0, 0)",
      );
      db.execute(
        "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
        "VALUES ('crew_members', 'postgres', 0, 0)",
      );
      db.execute(
        "INSERT INTO sync_state (sync_table, provider, last_push_count, last_pull_count) "
        "VALUES ('custom_airports', 'postgres', 0, 0)",
      );
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    const flightId = '3f1a6c1e-9b2d-4a57-8f0c-2d1e3b4a5c6d';
    final created = await server.call('create_flight', {
      'id': flightId,
      'date': '2026-06-01',
      'route': 'YSSY - YBBN',
      'total_time': 60,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');
    final deleted = await server.call('delete_flight', {'id': flightId});
    expect(deleted.isError, isFalse, reason: '${deleted.payload}');
    final recreated = await server.call('create_flight', {
      'id': flightId,
      'date': '2026-06-02',
      'route': 'YSSY - YBBN',
      'total_time': 60,
    });
    expect(recreated.isError, isFalse, reason: '${recreated.payload}');

    for (final entry in [
      (
        id: '2b7c5e9d-1a3f-4c8b-9d2e-6f0a4b7c8d91',
        create: 'add_aircraft',
        fields: <String, dynamic>{
          'type': 'C172',
          'country_code': 'VH',
          'registration': 'YNQ',
        },
        delete: 'delete_aircraft',
      ),
      (
        id: '8e4d2f6a-7c1b-4a9d-8f3e-5b2c1d0e9f87',
        create: 'add_crew',
        fields: <String, dynamic>{
          'first_name': 'Sam',
          'last_name': 'Replay',
        },
        delete: 'delete_crew',
      ),
      (
        id: 'c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f',
        create: 'add_custom_airport',
        fields: <String, dynamic>{'name': 'Replay Field', 'icao': 'YRPY'},
        delete: 'delete_custom_airport',
      ),
    ]) {
      final made =
          await server.call(entry.create, {'id': entry.id, ...entry.fields});
      expect(made.isError, isFalse, reason: '${made.payload}');
      final gone = await server.call(entry.delete, {'id': entry.id});
      expect(gone.isError, isFalse, reason: '${gone.payload}');
      final again =
          await server.call(entry.create, {'id': entry.id, ...entry.fields});
      expect(again.isError, isFalse, reason: '${again.payload}');
    }

    withFixtureDb(dbPath, (db) {
      // Every tombstone named a row that now exists again, so none survives.
      expect(
          db.select('SELECT sync_table, row_id FROM sync_deletions'), isEmpty);
      expect(
        db.select('SELECT id FROM flights WHERE id = ?', [flightId]).single,
        {'id': flightId},
      );
      for (final id in [
        '2b7c5e9d-1a3f-4c8b-9d2e-6f0a4b7c8d91',
        '8e4d2f6a-7c1b-4a9d-8f3e-5b2c1d0e9f87',
        'c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f',
      ]) {
        expect(
          db.select(
              'SELECT id FROM aircraft WHERE id = ? '
              'UNION ALL SELECT id FROM crew_members WHERE id = ? '
              'UNION ALL SELECT id FROM custom_airports WHERE id = ?',
              [id, id, id]),
          hasLength(1),
          reason: id,
        );
      }
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

  test('a v20 database opens and reports its schema version', () async {
    // Falcon-Logbook/app#237 adds four nullable columns to flights and bumps
    // user_version to 20. The gate used to refuse anything above 19, which
    // locks every app user out of the server the moment they upgrade.
    withFixtureDb(dbPath, (db) {
      for (final statement in [
        'ALTER TABLE flights ADD COLUMN scheduled_departure_utc INTEGER NULL',
        'ALTER TABLE flights ADD COLUMN scheduled_arrival_utc INTEGER NULL',
        'ALTER TABLE flights ADD COLUMN scheduled_block_minutes INTEGER NULL',
        'ALTER TABLE flights ADD COLUMN schedule_source TEXT NULL',
      ]) {
        db.execute(statement);
      }
      db.execute('PRAGMA user_version = 20');
    });

    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final info = await server.call('db_info', {});
    expect(info.isError, isFalse, reason: '${info.payload}');
    expect((info.payload as Map)['schemaVersion'], 20);

    // The v20 columns are additive and unknown to this server, so a flight can
    // still be created without them and an existing row still reads back.
    final created = await server.call('create_flight', {
      'date': '2026-02-04',
      'total_time': 30,
    });
    expect(created.isError, isFalse, reason: '${created.payload}');

    final listed = await server.call('list_flights', {'limit': 5});
    expect(listed.isError, isFalse, reason: '${listed.payload}');
  });

  // The startup gate is the only diagnostic a user sees when the server
  // refuses to run, so each refusal has to name the fault it can act on.
  group('schema gate', () {
    Future<ProcessResult> startWith(String path) => Process.run(
          Platform.resolvedExecutable,
          ['run', 'bin/falcon_mcp.dart', '--db', path],
        );

    test('a file with no schema version is reported as not a logbook',
        () async {
      final path = '${tempDir.path}/not_a_logbook.sqlite';
      File(path).createSync();

      final result = await startWith(path);
      final stderr = '${result.stderr}';

      expect(result.exitCode, isNot(0));
      expect(stderr, contains(path));
      expect(stderr, contains('no schema version'));
      expect(stderr, contains('does not look like a Falcon logbook'));
      expect(stderr, contains('--db'));
      expect(stderr, contains('FALCON_DB_PATH'));
      expect(stderr, contains('db_path.conf'));
      expect(stderr, contains('platform default'));
      expect(stderr, isNot(contains('Update this MCP server')),
          reason: 'a non-Falcon file cannot be fixed by updating the server');
      expect('${result.stdout}', isEmpty,
          reason: 'stdout is the MCP channel and stays clean');
    });

    test('a below-floor database asks for an app update', () async {
      withFixtureDb(dbPath, (db) => db.execute('PRAGMA user_version = 17'));

      final result = await startWith(dbPath);
      final stderr = '${result.stderr}';

      expect(result.exitCode, isNot(0));
      expect(stderr, contains(dbPath));
      expect(stderr, contains('17'));
      expect(stderr, contains('older than the supported 18-20'));
      expect(stderr, contains('Update the Falcon app'));
      expect(stderr, isNot(contains('Update this MCP server')),
          reason: '18 is the floor, so only the app can migrate the file');
    });

    test('an above-ceiling database asks for a server update', () async {
      withFixtureDb(dbPath, (db) => db.execute('PRAGMA user_version = 21'));

      final result = await startWith(dbPath);
      final stderr = '${result.stderr}';

      expect(result.exitCode, isNot(0));
      expect(stderr, contains(dbPath));
      expect(stderr, contains('21'));
      expect(stderr, contains('newer than the supported 18-20'));
      expect(stderr, contains('Update this MCP server'));
      expect(stderr, isNot(contains('Update the Falcon app')),
          reason: 'the app is already ahead; the server is the stale side');
    });
  });
}
