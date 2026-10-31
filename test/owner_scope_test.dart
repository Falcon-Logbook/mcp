import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #59: reads return local rows only unless `include_shared` widens them,
/// so a write that resolved its target by id alone could update or delete a row
/// another pilot owns, and a delete even tombstoned it for sync. Every synced
/// write now carries the same owner rule as the reads: a foreign row is simply
/// not found, while `owner_id` NULL and `'local'` rows stay writable.
void main() {
  late Directory tempDir;
  late String dbPath;

  tearDown(() => tempDir.deleteSync(recursive: true));

  /// A row of every synced table owned by another pilot, next to one row per
  /// owner form the app writes locally (NULL and 'local'). sync_state has a
  /// provider so the delete tools take their tombstone path.
  void seedForeignRows() {
    withFixtureDb(dbPath, (db) {
      void insert(String sql, List<Object?> params) => db.execute(sql, params);

      for (final table in [
        'flights',
        'aircraft',
        'crew_members',
        'custom_airports',
      ]) {
        insert(
          'INSERT INTO sync_state (sync_table, provider) VALUES (?, ?)',
          [table, 'postgres'],
        );
      }

      insert(
        'INSERT INTO flights (id, date, route, total_time, owner_id, '
        'updated_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'fl-other',
          1761408000,
          'YSSY - YMML',
          60,
          'someone-else',
          1700000000,
          1700000000
        ],
      );
      insert(
        'INSERT INTO flights (id, date, route, owner_id, updated_at, created_at) '
        'VALUES (?, ?, ?, NULL, ?, ?)',
        ['fl-null', 1761408000, 'YSBK - YSSY', 1700000000, 1700000000],
      );
      insert(
        'INSERT INTO flights (id, date, route, owner_id, updated_at, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'fl-local',
          1761408000,
          'YSSY - YSCB',
          'local',
          1700000000,
          1700000000
        ],
      );

      insert(
        'INSERT INTO aircraft (id, type, country_code, registration, owner_id, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        ['ac-other', 'A320', 'VH', 'OTH', 'someone-else', 1700000000],
      );
      insert(
        'INSERT INTO aircraft (id, type, country_code, registration, owner_id, '
        'updated_at) VALUES (?, ?, ?, ?, NULL, ?)',
        ['ac-null', 'C172', 'VH', 'NUL', 1700000000],
      );
      insert(
        'INSERT INTO aircraft (id, type, country_code, registration, owner_id, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        ['ac-local', 'PA28', 'VH', 'LOC', 'local', 1700000000],
      );

      insert(
        'INSERT INTO crew_members (id, name, first_name, last_name, owner_id, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          'cr-other',
          'Other Pilot',
          'Other',
          'Pilot',
          'someone-else',
          1700000000
        ],
      );
      insert(
        'INSERT INTO crew_members (id, name, first_name, last_name, owner_id, '
        'updated_at) VALUES (?, ?, ?, ?, NULL, ?)',
        ['cr-null', 'Null Owner', 'Null', 'Owner', 1700000000],
      );
      insert(
        'INSERT INTO crew_members (id, name, first_name, last_name, owner_id, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        ['cr-local', 'Local Owner', 'Local', 'Owner', 'local', 1700000000],
      );

      insert(
        'INSERT INTO custom_airports (id, icao, name, owner_id) '
        'VALUES (?, ?, ?, ?)',
        ['ca-other', 'YOTH', 'Other Field', 'someone-else'],
      );
      insert(
        'INSERT INTO custom_airports (id, icao, name, owner_id) '
        'VALUES (?, ?, ?, NULL)',
        ['ca-null', 'YNUL', 'Null Field'],
      );
      insert(
        'INSERT INTO custom_airports (id, icao, name, owner_id) '
        'VALUES (?, ?, ?, ?)',
        ['ca-local', 'YLOC', 'Local Field', 'local'],
      );

      for (final route in [
        (101, 'QF9', 'someone-else'),
        (102, 'QF10', null),
        (103, 'QF11', 'local'),
      ]) {
        insert(
          'INSERT INTO saved_routes (id, flight_number, departure_icao, '
          'arrival_icao, owner_id, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
          [route.$1, route.$2, 'YSSY', 'EGLL', route.$3, 1700000000],
        );
      }
      // A local flight the foreign route is linked to: deleting the route must
      // neither succeed nor unlink this flight.
      insert('UPDATE flights SET route_id = 101 WHERE id = ?', ['fl-null']);
    });
  }

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('falcon_mcp_owner_scope_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
    seedForeignRows();
  });

  Future<McpProcess> start() async {
    final server = await McpProcess.start(dbPath, write: true);
    addTearDown(() async {
      await server.stop();
    });
    return server;
  }

  /// A failed call's envelope, as the harness hands it back: raw JSON text.
  Map<String, dynamic> errorPayloadOf(
          ({bool isError, Object? payload}) result) =>
      jsonDecode(result.payload as String) as Map<String, dynamic>;

  Map<String, dynamic> rowOf(String table, Object id) => withFixtureDb(
        dbPath,
        (db) => db.select('SELECT * FROM $table WHERE id = ?', [id]).single,
      );

  int? tombstoneCount(String table, Object id) => withFixtureDb(
        dbPath,
        (db) => db.select(
            'SELECT COUNT(*) AS n FROM sync_deletions '
            'WHERE sync_table = ? AND row_id = ?',
            [table, '$id']).single['n'] as int,
      );

  /// Asserts the call failed with the not_found envelope naming [id].
  void expectNotFound(({bool isError, Object? payload}) result, String detail) {
    expect(result.isError, isTrue, reason: '${result.payload}');
    final error = errorPayloadOf(result);
    expect(error['error'], 'not_found');
    expect(error['field'], 'id');
    expect('${error['detail']}', contains(detail));
  }

  test('a flight read with include_shared cannot be updated', () async {
    final server = await start();

    // The id is reachable by a read: that is exactly how a caller gets one.
    final read = await server
        .call('get_flight', {'id': 'fl-other', 'include_shared': true});
    expect(read.isError, isFalse, reason: '${read.payload}');
    expect((read.payload as Map<String, dynamic>)['id'], 'fl-other');

    final before = rowOf('flights', 'fl-other');
    final update = await server
        .call('update_flight', {'id': 'fl-other', 'route': 'YSSY - YBBN'});
    expectNotFound(update, 'fl-other');
    expect(rowOf('flights', 'fl-other'), before,
        reason: 'a refused write must leave the row as it was');
  });

  test('a flight owned by another pilot is not deleted or tombstoned',
      () async {
    final server = await start();

    final result = await server.call('delete_flight', {'id': 'fl-other'});
    expectNotFound(result, 'fl-other');
    expect(rowOf('flights', 'fl-other')['id'], 'fl-other');
    expect(tombstoneCount('flights', 'fl-other'), 0,
        reason: 'no tombstone may be written for another owners row');
  });

  test('NULL and local flights update and delete, and delete tombstones',
      () async {
    final server = await start();

    for (final id in ['fl-null', 'fl-local']) {
      final update = await server
          .call('update_flight', {'id': id, 'route': 'YSSY - YBBN'});
      expect(update.isError, isFalse, reason: '${update.payload}');
      expect(rowOf('flights', id)['route'], 'YSSY - YBBN');
    }

    final deleted = await server.call('delete_flight', {'id': 'fl-local'});
    expect(deleted.isError, isFalse, reason: '${deleted.payload}');
    expect(tombstoneCount('flights', 'fl-local'), 1);
  });

  test('an aircraft owned by another pilot is not found, updated or deleted',
      () async {
    final server = await start();
    final before = rowOf('aircraft', 'ac-other');

    final update = await server
        .call('update_aircraft', {'id': 'ac-other', 'registration': 'XXX'});
    expectNotFound(update, 'ac-other');
    expect(rowOf('aircraft', 'ac-other'), before);

    final delete = await server.call('delete_aircraft', {'id': 'ac-other'});
    expectNotFound(delete, 'ac-other');
    expect(rowOf('aircraft', 'ac-other')['id'], 'ac-other');
    expect(tombstoneCount('aircraft', 'ac-other'), 0);

    for (final id in ['ac-null', 'ac-local']) {
      final registration = id == 'ac-null' ? 'NU2' : 'LO2';
      final local = await server
          .call('update_aircraft', {'id': id, 'registration': registration});
      expect(local.isError, isFalse, reason: '${local.payload}');
      expect(rowOf('aircraft', id)['registration'], registration);
    }
    final localDelete = await server.call('delete_aircraft', {'id': 'ac-null'});
    expect(localDelete.isError, isFalse, reason: '${localDelete.payload}');
    expect(tombstoneCount('aircraft', 'ac-null'), 1);
  });

  test('a crew member owned by another pilot is not found, updated or deleted',
      () async {
    final server = await start();
    final before = rowOf('crew_members', 'cr-other');

    final update =
        await server.call('update_crew', {'id': 'cr-other', 'last_name': 'X'});
    expectNotFound(update, 'cr-other');
    expect(rowOf('crew_members', 'cr-other'), before);

    final delete = await server.call('delete_crew', {'id': 'cr-other'});
    expectNotFound(delete, 'cr-other');
    expect(rowOf('crew_members', 'cr-other')['id'], 'cr-other');
    expect(tombstoneCount('crew_members', 'cr-other'), 0);

    for (final id in ['cr-null', 'cr-local']) {
      final local =
          await server.call('update_crew', {'id': id, 'last_name': 'UPD'});
      expect(local.isError, isFalse, reason: '${local.payload}');
      expect(rowOf('crew_members', id)['last_name'], 'UPD');
    }
    final localDelete = await server.call('delete_crew', {'id': 'cr-local'});
    expect(localDelete.isError, isFalse, reason: '${localDelete.payload}');
    expect(tombstoneCount('crew_members', 'cr-local'), 1);
  });

  test('a custom airport owned by another pilot is not found or deleted',
      () async {
    final server = await start();
    final before = rowOf('custom_airports', 'ca-other');

    final update = await server
        .call('update_custom_airport', {'id': 'ca-other', 'name': 'Renamed'});
    expectNotFound(update, 'ca-other');
    expect(rowOf('custom_airports', 'ca-other'), before);

    final delete =
        await server.call('delete_custom_airport', {'id': 'ca-other'});
    expectNotFound(delete, 'ca-other');
    expect(rowOf('custom_airports', 'ca-other')['id'], 'ca-other');
    expect(tombstoneCount('custom_airports', 'ca-other'), 0);

    for (final id in ['ca-null', 'ca-local']) {
      final local = await server
          .call('update_custom_airport', {'id': id, 'name': 'Updated'});
      expect(local.isError, isFalse, reason: '${local.payload}');
      expect(rowOf('custom_airports', id)['name'], 'Updated');
    }
    final localDelete =
        await server.call('delete_custom_airport', {'id': 'ca-local'});
    expect(localDelete.isError, isFalse, reason: '${localDelete.payload}');
    expect(tombstoneCount('custom_airports', 'ca-local'), 1);
  });

  test('a saved route owned by another pilot is not found or deleted',
      () async {
    final server = await start();
    final before = rowOf('saved_routes', 101);

    final update = await server
        .call('update_saved_route', {'id': 101, 'flight_number': 'QF99'});
    expectNotFound(update, '101');
    expect(rowOf('saved_routes', 101), before);

    final delete = await server.call('delete_saved_route', {'id': 101});
    expect(delete.isError, isTrue, reason: '${delete.payload}');
    final error = errorPayloadOf(delete);
    expect(error['error'], 'not_found');
    expect(error['field'], 'id');
    expect(rowOf('saved_routes', 101)['id'], 101);
    expect(rowOf('flights', 'fl-null')['route_id'], 101,
        reason: 'a refused delete must not unlink the flights pointing at it');

    for (final id in [102, 103]) {
      final local = await server
          .call('update_saved_route', {'id': id, 'flight_number': 'QF99'});
      expect(local.isError, isFalse, reason: '${local.payload}');
      expect(rowOf('saved_routes', id)['flight_number'], 'QF99');
    }
    final localDelete = await server.call('delete_saved_route', {'id': 102});
    expect(localDelete.isError, isFalse, reason: '${localDelete.payload}');
    expect(
        withFixtureDb(
            dbPath,
            (db) => db.select(
                'SELECT id FROM saved_routes WHERE id = ?', [102]).isEmpty),
        isTrue);
  });
}
