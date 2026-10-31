import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #41: eight destructive tools never called `_rejectUnknown`, so a
/// caller that read the row and passed `expected_updated_at` got an
/// unconditional delete instead of a refusal. Each one now rejects argument
/// names it does not implement, the same way the create and update tools do,
/// and a plain valid call still works.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_unknown_args');
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

  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) =>
      result.isError
          ? throw StateError('call failed: ${result.payload}')
          : result.payload as Map<String, dynamic>;

  Map<String, dynamic> errorPayloadOf(
          ({bool isError, Object? payload}) result) =>
      jsonDecode(result.payload as String) as Map<String, dynamic>;

  int countOf(String table) => withFixtureDb(
        dbPath,
        (db) => db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int,
      );

  Map<String, dynamic>? rowOf(String table, Object? id) => withFixtureDb(
        dbPath,
        (db) {
          final rows = db.select('SELECT * FROM $table WHERE id = ?', [id]);
          return rows.isEmpty ? null : rows.first;
        },
      );

  void insert(String sql, [List<Object?> params = const []]) =>
      withFixtureDb(dbPath, (db) => db.execute(sql, params));

  /// An unknown name is refused with the field and tool named, and the detail
  /// lists what the tool does accept.
  void expectUnknown(({bool isError, Object? payload}) result,
      {required String field, required String tool, String? accepts}) {
    expect(result.isError, isTrue, reason: '${result.payload}');
    final envelope = errorPayloadOf(result);
    expect(envelope['error'], 'unknown_field');
    expect(envelope['field'], field);
    expect(envelope['tool'], tool);
    if (accepts != null) {
      expect(envelope['detail'], contains('accepts $accepts'));
    }
  }

  group('delete tools', () {
    test('delete_flight rejects expected_updated_at and the row survives',
        () async {
      final server = await start();

      final guarded = await server.call('delete_flight', {
        'id': 'fl-1',
        'expected_updated_at': 1700000001,
        'dry_run': false,
      });

      expectUnknown(guarded,
          field: 'expected_updated_at',
          tool: 'delete_flight',
          accepts: 'dry_run, id');
      expect(rowOf('flights', 'fl-1'), isNotNull,
          reason: 'a refused delete must not remove the row');
    });

    test('delete_flight still deletes with only id and dry_run', () async {
      final server = await start();

      final deleted =
          await server.call('delete_flight', {'id': 'fl-1', 'dry_run': false});

      expect(deleted.isError, isFalse, reason: '${deleted.payload}');
      expect(payloadOf(deleted)['status'], 'deleted');
      expect(rowOf('flights', 'fl-1'), isNull);
    });

    test('the other delete tools reject unknown arguments too', () async {
      insert("INSERT INTO custom_airports (id, icao, name, created_at) "
          "VALUES ('ca-1', 'ZZZZ', 'Test Field', 1700000000)");
      final server = await start();
      final cases = <String, Map<String, dynamic>>{
        'delete_aircraft': {'id': 'ac-1'},
        'delete_crew': {'id': 'cr-1'},
        'delete_custom_airport': {'id': 'ca-1'},
        'delete_saved_route': {'id': 1},
      };

      for (final entry in cases.entries) {
        final result = await server.call(entry.key, {
          ...entry.value,
          'expected_updated_at': 1700000001,
        });
        expectUnknown(result, field: 'expected_updated_at', tool: entry.key);
      }

      expect(countOf('aircraft'), 1, reason: 'the aircraft row survives');
      expect(countOf('crew_members'), 1, reason: 'the crew row survives');
      expect(countOf('custom_airports'), 1);
      expect(countOf('saved_routes'), 1);
    });
  });

  group('repair tools that write', () {
    test('merge_crew rejects expected_updated_at and keeps both crew rows',
        () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'Jane Doe', 'Jane', 'Doe', 1700000000)");
      final server = await start();

      final guarded = await server.call('merge_crew', {
        'into_id': 'cr-1',
        'from_ids': ['cr-2'],
        'expected_updated_at': 1700000001,
        'dry_run': false,
      });

      expectUnknown(guarded,
          field: 'expected_updated_at',
          tool: 'merge_crew',
          accepts: 'dry_run, from_ids, into_id');
      expect(countOf('crew_members'), 2, reason: 'nothing was merged away');
    });

    test('merge_crew still applies a valid merge', () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'Jane Doe', 'Jane', 'Doe', 1700000000)");
      final server = await start();

      final merged = await server.call('merge_crew', {
        'into_id': 'cr-1',
        'from_ids': ['cr-2'],
        'dry_run': false,
      });

      expect(merged.isError, isFalse, reason: '${merged.payload}');
      expect(payloadOf(merged)['status'], 'merged');
      expect(rowOf('crew_members', 'cr-2'), isNull);
    });

    test('link_flights_to_aircraft rejects an unknown argument and links',
        () async {
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES "
          "('fl-unlinked', 1761408000, 'YSSY - NZQN', 'XZO', 1700000000)");
      final server = await start();

      final guarded = await server.call('link_flights_to_aircraft', {
        'flight_ids': ['fl-unlinked'],
        'expected_updated_at': 1700000001,
        'dry_run': false,
      });
      expectUnknown(guarded,
          field: 'expected_updated_at',
          tool: 'link_flights_to_aircraft',
          accepts: 'aircraft_id, dry_run, flight_ids');
      expect(rowOf('flights', 'fl-unlinked')!['aircraft_id'], isNull,
          reason: 'the refused repair must not link anything');

      final linked = await server.call('link_flights_to_aircraft', {
        'flight_ids': ['fl-unlinked'],
        'dry_run': false,
      });
      expect(linked.isError, isFalse, reason: '${linked.payload}');
      expect(payloadOf(linked)['linked'], 1);
      expect(rowOf('flights', 'fl-unlinked')!['aircraft_id'], 'ac-1');
    });

    test('link_flights_to_crew rejects an unknown argument and links',
        () async {
      insert("INSERT INTO flights (id, date, route, crew_members_name, "
          "created_at) VALUES "
          "('fl-unlinked', 1761408000, 'YSSY - NZQN', 'Jane Doe', 1700000000)");
      final server = await start();

      final guarded = await server.call('link_flights_to_crew', {
        'flight_ids': ['fl-unlinked'],
        'expected_updated_at': 1700000001,
        'dry_run': false,
      });
      expectUnknown(guarded,
          field: 'expected_updated_at',
          tool: 'link_flights_to_crew',
          accepts: 'dry_run, flight_ids');
      expect(rowOf('flights', 'fl-unlinked')!['crew_member_id'], isNull,
          reason: 'the refused repair must not link anything');

      final linked = await server.call('link_flights_to_crew', {
        'flight_ids': ['fl-unlinked'],
        'dry_run': false,
      });
      expect(linked.isError, isFalse, reason: '${linked.payload}');
      expect(payloadOf(linked)['linked'], 1);
      expect(rowOf('flights', 'fl-unlinked')!['crew_member_id'], 'cr-1');
    });
  });
}
