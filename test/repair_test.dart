import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #12: an imported logbook is messy, and the server could only find
/// duplicate crew. One report names every defect class; three repairs fix the
/// fixable ones, dry-run first, one transaction, tombstones on deletes, and
/// never destructive beyond the stated operation.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_repair_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
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
      result.isError
          ? throw StateError('call failed: ${result.payload}')
          : result.payload as Map<String, dynamic>;

  Map<String, dynamic> errorPayloadOf(
          ({bool isError, Object? payload}) result) =>
      jsonDecode(result.payload as String) as Map<String, dynamic>;

  Map<String, dynamic> classOf(Map<String, dynamic> report, String id) =>
      (report['classes'] as List)
          .map((c) => c as Map<String, dynamic>)
          .firstWhere((c) => c['id'] == id, orElse: () => {});

  Map<String, int> counts() => withFixtureDb(dbPath, (db) {
        final out = <String, int>{};
        for (final table in ['flights', 'crew_members', 'sync_deletions']) {
          out[table] =
              db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int;
        }
        return out;
      });

  /// Adds a crew member or a flight directly, so the tests arrange exact mess.
  void insert(String sql, [List<Object?> params = const []]) =>
      withFixtureDb(dbPath, (db) => db.execute(sql, params));

  group('data_quality_report', () {
    test('runs in read-only mode and reports every class on a messy fixture',
        () async {
      insert("INSERT INTO flights (id, date, route, total_time, day_time, "
          "night_time, aircraft_registration, crew_members_name, created_at) "
          "VALUES ('fl-absurd', 1761408000, 'YSSY - NZQN', 999999999, NULL, "
          "NULL, 'VH-XZO', NULL, 1700000000)");
      insert("INSERT INTO flights (id, date, route, total_time, day_time, "
          "night_time, aircraft_registration, created_at) VALUES "
          "('fl-future', 1893456000, 'YSSY - NZQN', 100, 100, NULL, "
          "'VH-NOPE', 1700000000)");
      insert("INSERT INTO flights (id, date, route, total_time, day_time, "
          "night_time, aircraft_registration, created_at) VALUES "
          "('fl-dup1', 1761408000, 'YSSY - YBBN', 90, 90, NULL, NULL, "
          "1700000000), ('fl-dup2', 1761408000, 'YSSY - YBBN', 90, 90, NULL, "
          "NULL, 1700000000)");
      insert("INSERT INTO flights (id, date, route, created_at) VALUES "
          "('fl-route', 1761408000, 'not an airport pair', 1700000000)");
      insert(
          "INSERT INTO crew_members (id, name, first_name, last_name, created_at) "
          "VALUES ('cr-2', 'JANE  DOE', 'Jane', 'Doe', 1700000000)");
      insert("INSERT INTO flights (id, date, route, crew_members_name, "
          "created_at) VALUES ('fl-crew', 1761408000, 'YSSY - NZQN', "
          "'jane doe', 1700000000)");

      final server = await start();
      final report = payloadOf(await server.call('data_quality_report', {}));

      expect(report['total_flights'], 8,
          reason: 'the two fixture flights plus six arranged');
      final ids = [
        for (final c in report['classes'] as List) (c as Map)['id'],
      ];
      for (final expected in [
        'drafts',
        'missing_split',
        'absurd_totals',
        'aircraft_matchable',
        'aircraft_unmatched',
        'crew_matchable',
        'duplicate_crew',
        'duplicate_flights',
        'route_unparsable',
        'future_dates',
      ]) {
        expect(ids, contains(expected), reason: 'class $expected missing');
      }

      expect(classOf(report, 'drafts')['count'], 3,
          reason: 'fl-draft, fl-route and fl-crew carry no total');
      expect(classOf(report, 'absurd_totals')['count'], 1);
      expect(classOf(report, 'future_dates')['count'], 1);
      expect(classOf(report, 'duplicate_flights')['count'], 1,
          reason: 'the fl-dup pair');
      expect(classOf(report, 'duplicate_crew')['count'], 1,
          reason: 'Jane Doe and JANE  DOE normalise alike');
      expect(classOf(report, 'crew_matchable')['count'], 1,
          reason: 'jane doe matches the crew table through the normaliser');
      expect(classOf(report, 'aircraft_matchable')['count'], 1,
          reason: 'VH-XZO matches the fixture aircraft');
      expect(classOf(report, 'aircraft_unmatched')['count'], 1,
          reason: 'VH-NOPE matches nothing');
      expect(classOf(report, 'route_unparsable')['count'], 1);

      final dupFlights = classOf(report, 'duplicate_flights')['sample'] as List;
      expect((dupFlights.single['flight_ids'] as List).toSet(),
          {'fl-dup1', 'fl-dup2'});
    });

    test('an empty logbook returns classes with zero counts', () async {
      withFixtureDb(dbPath, (db) {
        db.execute('DELETE FROM flights');
        db.execute('DELETE FROM crew_members');
      });
      final server = await start();
      final report = payloadOf(await server.call('data_quality_report', {}));
      expect(report['total_flights'], 0);
      expect(report['classes'], isEmpty);
    });
  });

  group('merge_crew', () {
    test('defaults to a preview and changes nothing', () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'J. Doe', 'J', 'Doe', 1700000000)");
      final before = counts();
      final server = await start(write: true);

      final preview = payloadOf(await server.call('merge_crew', {
        'into_id': 'cr-1',
        'from_ids': ['cr-2'],
      }));

      expect(preview['dry_run'], isTrue,
          reason: 'a repair defaults to a preview');
      expect(preview['status'], 'merged');
      expect(preview['flights_repointed'], 0,
          reason: 'cr-2 has no flights yet');
      expect(counts(), before, reason: 'the preview touches nothing');
    });

    test('applies when dry_run is false: repoint, rename, tombstone, delete',
        () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'Jane Doe', 'Jane', 'Doe', "
          "1700000000)");
      insert("INSERT INTO flights (id, date, route, crew_member_id, "
          "crew_members_name, created_at) VALUES "
          "('fl-a', 1761408000, 'YSSY - NZQN', 'cr-2', 'Jane Doe', "
          "1700000000), ('fl-b', 1761494400, 'YSSY - NZQN', 'cr-2', "
          "'Jane Doe', 1700000000)");
      insert("INSERT INTO flights (id, date, route, crew_member_id, "
          "crew_members_name, created_at) VALUES "
          "('fl-c', 1761580800, 'YSSY - NZQN', 'cr-3', 'Jane Doe', "
          "1700000000)");
      insert("INSERT INTO sync_state (sync_table, provider) VALUES "
          "('crew_members', 'testProvider')");
      final server = await start(write: true);

      final applied = payloadOf(await server.call('merge_crew', {
        'dry_run': false,
        'into_id': 'cr-1',
        'from_ids': ['cr-2'],
      }));

      expect(applied.containsKey('dry_run'), isFalse,
          reason: 'an applied repair is not marked');
      expect(applied['flights_repointed'], 2);
      expect(applied['removed'], [
        {'id': 'cr-2', 'name': 'Jane Doe'},
      ]);

      final flights = withFixtureDb(
          dbPath,
          (db) => db.select(
              'SELECT id, crew_member_id, crew_members_name FROM flights '
              'WHERE id IN (?, ?, ?) ORDER BY id',
              ['fl-a', 'fl-b', 'fl-c']));
      expect(flights.map((f) => f['crew_member_id']), everyElement('cr-1'));
      expect(
          flights.map((f) => f['crew_members_name']), everyElement('Jane Doe'),
          reason: 'the survivor name lands on every repointed flight, '
              'including the one that named the discard but linked elsewhere '
              '(the app rule)');
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select(
                  'SELECT COUNT(*) AS n FROM crew_members WHERE id = ?',
                  ['cr-2'])).single['n'],
          0);
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select(
                  'SELECT COUNT(*) AS n FROM sync_deletions WHERE sync_table = ? '
                  'AND row_id = ?',
                  ['crew_members', 'cr-2'])).single['n'],
          1,
          reason: 'the deletion carries a tombstone so sync propagates it');
      expect(applied['affected_ids'], containsAll(['cr-1', 'cr-2']));
    });

    test('a failed merge leaves every row as it was', () async {
      final before = counts();
      final server = await start(write: true);

      final result = await server.call('merge_crew', {
        'dry_run': false,
        'into_id': 'cr-1',
        'from_ids': ['cr-nope'],
      });

      expect(result.isError, isTrue);
      expect(errorPayloadOf(result)['error'], 'not_found');
      expect(counts(), before,
          reason: 'one transaction: a refusal halfway changes nothing');
    });

    test('refuses into_id inside from_ids', () async {
      final server = await start(write: true);
      final result = await server.call('merge_crew', {
        'into_id': 'cr-1',
        'from_ids': ['cr-1'],
      });
      expect(result.isError, isTrue);
      expect(errorPayloadOf(result)['error'], 'invalid_value');
    });
  });

  group('update_crew rename', () {
    Map<String, dynamic> crewRow(String id) => withFixtureDb(
        dbPath,
        (db) => db.select(
            'SELECT name, first_name, last_name, updated_at FROM crew_members '
            'WHERE id = ?',
            [id])).single;

    Map<String, dynamic> flightRow(String id) => withFixtureDb(
        dbPath,
        (db) => db.select(
            'SELECT crew_member_id, crew_members_name, updated_at FROM flights '
            'WHERE id = ?',
            [id])).single;

    test('renaming first_name re-derives the name and relabels linked flights',
        () async {
      final server = await start(write: true);

      payloadOf(await server.call('update_crew', {
        'id': 'cr-1',
        'first_name': 'Janet',
      }));

      final crew = crewRow('cr-1');
      expect(crew['name'], 'Janet Doe',
          reason: 'add_crew derives name as "first last"');
      expect(crew['first_name'], 'Janet');
      expect(crew['last_name'], 'Doe');
      expect(crew['updated_at'], isNotNull, reason: 'the rename is stamped');
      final flight = flightRow('fl-1');
      expect(flight['crew_members_name'], 'Janet Doe',
          reason: 'the flight label follows the crew link');
      expect(flight['updated_at'], isNotNull);
    });

    test('renaming last_name re-derives the name too', () async {
      final server = await start(write: true);

      payloadOf(await server.call('update_crew', {
        'id': 'cr-1',
        'last_name': 'Dough',
      }));

      expect(crewRow('cr-1')['name'], 'Jane Dough');
      expect(flightRow('fl-1')['crew_members_name'], 'Jane Dough');
    });

    test('an explicit name wins over the parts, as add_crew does', () async {
      final server = await start(write: true);

      payloadOf(await server.call('update_crew', {
        'id': 'cr-1',
        'first_name': 'Janet',
        'last_name': 'Doe',
        'name': 'Captain Doe',
      }));

      final crew = crewRow('cr-1');
      expect(crew['name'], 'Captain Doe');
      expect(crew['first_name'], 'Janet');
      expect(crew['last_name'], 'Doe');
    });

    test('touches no other crew row or flight', () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at, updated_at) VALUES ('cr-2', 'Sam Pilot', 'Sam', "
          "'Pilot', 1700000000, 1700005000)");
      insert("INSERT INTO flights (id, date, route, crew_member_id, "
          "crew_members_name, created_at) VALUES ('fl-2', 1761494400, "
          "'YSBK - YSSY', 'cr-2', 'Sam Pilot', 1700000000)");
      final server = await start(write: true);

      payloadOf(await server.call('update_crew', {
        'id': 'cr-1',
        'first_name': 'Janet',
      }));

      final other = crewRow('cr-2');
      expect(other['name'], 'Sam Pilot');
      expect(other['updated_at'], 1700005000);
      final otherFlight = flightRow('fl-2');
      expect(otherFlight['crew_members_name'], 'Sam Pilot');
      expect(otherFlight['updated_at'], isNull);
      final unlinked = flightRow('fl-draft');
      expect(unlinked['crew_members_name'], isNull);
      expect(unlinked['updated_at'], isNull,
          reason: 'a flight with no crew link keeps its label');
    });
  });

  group('link_flights_to_aircraft', () {
    test('resolves display-form text against a bare-registration fleet',
        () async {
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-link', 1761408000, 'YSSY - NZQN', "
          "'VH-XZO', 1700000000), ('fl-bare', 1761494400, 'YSSY - NZQN', "
          "'XZO', 1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_aircraft', {'dry_run': false}));

      expect(applied['linked'], 2);
      final rows = withFixtureDb(
          dbPath,
          (db) => db.select(
              'SELECT id, aircraft_id, aircraft_registration FROM flights '
              "WHERE id IN ('fl-link', 'fl-bare') ORDER BY id"));
      expect(rows.map((r) => r['aircraft_id']), everyElement('ac-1'));
      expect(
          rows.map((r) => r['aircraft_registration']), everyElement('VH-XZO'),
          reason: 'the text becomes the display form, as a write does');
    });

    test('the preview reports the same diff and changes nothing', () async {
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-link', 1761408000, 'YSSY - NZQN', "
          "'VH-XZO', 1700000000)");
      final before = counts();
      final server = await start(write: true);

      final preview =
          payloadOf(await server.call('link_flights_to_aircraft', {}));

      expect(preview['dry_run'], isTrue);
      expect(preview['linked'], 1);
      expect(counts(), before);
    });

    test('reports ambiguity instead of guessing', () async {
      insert("INSERT INTO aircraft (id, type, country_code, registration, "
          "created_at) VALUES ('ac-nz', 'C172', 'ZK', 'XZO', 1700000000)");
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-amb', 1761408000, 'YSSY - NZQN', 'XZO', "
          "1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_aircraft', {'dry_run': false}));

      expect(applied['linked'], 0);
      final ambiguous = applied['ambiguous'] as List;
      expect(ambiguous.single['flight_id'], 'fl-amb');
      expect((ambiguous.single['candidates'] as List).length, 2,
          reason: 'VH-XZO and ZK-XZO both match; the tool does not pick');
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT aircraft_id FROM flights WHERE id = ?',
                  ['fl-amb'])).single['aircraft_id'],
          isNull);
    });

    test('the picker flow links named flights to the chosen aircraft',
        () async {
      insert("INSERT INTO aircraft (id, type, country_code, registration, "
          "created_at) VALUES ('ac-nz', 'C172', 'ZK', 'XZO', 1700000000)");
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-amb', 1761408000, 'YSSY - NZQN', 'XZO', "
          "1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(await server.call('link_flights_to_aircraft', {
        'dry_run': false,
        'aircraft_id': 'ac-nz',
        'flight_ids': ['fl-amb']
      }));

      expect(applied['linked'], 1);
      final row = withFixtureDb(
          dbPath,
          (db) => db
              .select('SELECT aircraft_id, aircraft_registration FROM flights '
                  "WHERE id = 'fl-amb'")).single;
      expect(row['aircraft_id'], 'ac-nz');
      expect(row['aircraft_registration'], 'ZK-XZO');
    });

    test('logbook_country settles a two-country tie', () async {
      insert("INSERT INTO aircraft (id, type, country_code, registration, "
          "created_at) VALUES ('ac-nz', 'C172', 'ZK', 'XZO', 1700000000)");
      insert("INSERT INTO flights_settings (id, logbook_country, created_at) "
          "VALUES ('fs-1', 'NZ', 1700000000)");
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-amb', 1761408000, 'YSSY - NZQN', 'XZO', "
          "1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_aircraft', {'dry_run': false}));
      expect(applied['linked'], 1, reason: 'the pilot flies NZ tails');
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT aircraft_id FROM flights WHERE id = ?',
                  ['fl-amb'])).single['aircraft_id'],
          'ac-nz');
    });

    test('fills registration text from the linked aircraft', () async {
      insert("INSERT INTO flights (id, date, route, aircraft_id, created_at) "
          "VALUES ('fl-rev', 1761408000, 'YSSY - NZQN', 'ac-1', "
          "1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_aircraft', {'dry_run': false}));
      expect(applied['reverse_fixed'], 1);
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select(
                  'SELECT aircraft_registration FROM flights WHERE id = ?',
                  ['fl-rev'])).single['aircraft_registration'],
          'VH-XZO');
    });

    test('never creates aircraft and never deletes anything', () async {
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-nope', 1761408000, 'YSSY - NZQN', "
          "'VH-NOPE', 1700000000)");
      final before = counts();
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_aircraft', {'dry_run': false}));
      expect(applied['unmatched'].single['aircraft_registration'], 'VH-NOPE');
      expect(counts(), before,
          reason: 'nothing created, nothing deleted, nothing linked');
    });
  });

  group('link_flights_to_crew', () {
    test('resolves a name and links; ambiguous names are reported', () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'J Smith', 'Jim', 'Smith', "
          "1700000000)");
      insert("INSERT INTO flights (id, date, route, crew_members_name, "
          "created_at) VALUES ('fl-j', 1761408000, 'YSSY - NZQN', 'J Smith', "
          "1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_crew', {'dry_run': false}));
      expect(applied['linked'], 1);
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select(
                  'SELECT crew_member_id FROM flights WHERE id = ?',
                  ['fl-j'])).single['crew_member_id'],
          'cr-2');

      // A second J Smith makes the same flight ambiguous.
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-3', 'J Smith', 'Jane', 'Smith', "
          "1700000001)");
      insert("INSERT INTO flights (id, date, route, crew_members_name, "
          "created_at) VALUES ('fl-k', 1761494400, 'YSSY - YBBN', 'J Smith', "
          "1700000000)");
      final second = payloadOf(
          await server.call('link_flights_to_crew', {'dry_run': false}));
      expect(second['linked'], 0);
      final ambiguous = second['ambiguous'] as List;
      expect(ambiguous.single['flight_id'], 'fl-k');
      expect((ambiguous.single['candidates'] as List).length, 2,
          reason: 'two J Smiths: the tool reports, never takes the first');
    });

    test('defaults to a preview and changes nothing', () async {
      insert("INSERT INTO flights (id, date, route, crew_members_name, "
          "created_at) VALUES ('fl-j', 1761408000, 'YSSY - NZQN', 'Jane Doe', "
          "1700000000)");
      final before = counts();
      final server = await start(write: true);

      final preview = payloadOf(await server.call('link_flights_to_crew', {}));
      expect(preview['dry_run'], isTrue);
      expect(preview['linked'], 1);
      expect(counts(), before);
    });
  });

  group('acceptance: scale and the audit trail', () {
    test('a 500-flight tidy-up completes in one transaction', () async {
      final rows = [
        for (var i = 0; i < 500; i++)
          "('fl-tidy$i', ${1761408000 + i * 60}, 'YSSY - NZQN', 'VH-XZO', "
              '1700000000)',
      ];
      withFixtureDb(dbPath, (db) {
        db.execute(
            'INSERT INTO flights (id, date, route, aircraft_registration, '
            'created_at) VALUES ${rows.join(', ')}');
      });
      final server = await start(write: true);

      final applied = payloadOf(
          await server.call('link_flights_to_aircraft', {'dry_run': false}));

      expect(applied['linked'], 500,
          reason: 'one call, one transaction, every row resolved');
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select(
                  'SELECT COUNT(*) AS n FROM flights WHERE aircraft_id IS NOT NULL '
                  "AND id LIKE 'fl-tidy%'")).single['n'],
          500);
    });

    test('one audit entry per repair carries the affected ids', () async {
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'J. Doe', 'J', 'Doe', 1700000000)");
      insert(
          "INSERT INTO flights (id, date, route, crew_member_id, created_at) "
          "VALUES ('fl-a', 1761408000, 'YSSY - NZQN', 'cr-2', 1700000000)");
      final server = await start(write: true);

      final preview = payloadOf(await server.call('merge_crew', {
        'into_id': 'cr-1',
        'from_ids': ['cr-2'],
      }));
      final applied = payloadOf(await server.call('merge_crew', {
        'dry_run': false,
        'into_id': 'cr-1',
        'from_ids': ['cr-2'],
      }));
      expect(preview['flights_repointed'], applied['flights_repointed'],
          reason: 'the preview answers the same diff the apply does');

      final audit = File('${dbPath.substring(0, dbPath.length - 7)}'
              '.mcp_audit.jsonl')
          .readAsLinesSync();
      final entries = [
        for (final line in audit) jsonDecode(line) as Map<String, dynamic>,
      ].where((entry) => entry['tool'] == 'merge_crew').toList();
      expect(entries, hasLength(2),
          reason: 'one entry per call, not one per row');
      expect(entries.first['result'], 'dry_run');
      expect(entries.last['result'], 'ok');
      expect(entries.last['ids'], containsAll(['cr-1', 'cr-2', 'fl-a']));
    });
  });
}
