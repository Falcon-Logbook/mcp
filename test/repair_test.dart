import 'dart:convert';
import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
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

  /// A year from today, at the day start the `date` column stores. The
  /// future_dates class compares against the wall clock, so the fixture has to
  /// move with it instead of naming an epoch that goes stale.
  final futureEpoch =
      epochForDayStart(DateTime.now().add(const Duration(days: 365)));

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
          "('fl-future', $futureEpoch, 'YSSY - NZQN', 100, 100, NULL, "
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

    test('reports every class exactly on a fixture of messy rows', () async {
      // One row per defect class, plus a second crew member that normalises
      // like the fixture one. Dates ascend with each insert so the report's
      // date-descending order is predictable.
      insert("INSERT INTO crew_members (id, name, first_name, last_name, "
          "created_at) VALUES ('cr-2', 'JANE  DOE', 'Jane', 'Doe', "
          '1700000000)');
      insert("INSERT INTO flights (id, date, route, total_time, day_time, "
          "night_time, aircraft_registration, crew_members_name, "
          "is_simulator, aircraft_id, route_id, created_at) VALUES "
          "('fl-draft2', 1761580800, 'YSSY - YBBN', NULL, NULL, NULL, NULL, "
          "NULL, 0, NULL, NULL, 1700000000), "
          "('fl-missing', 1761667200, NULL, 60, 60, NULL, NULL, NULL, 0, "
          "NULL, NULL, 1700000000), "
          "('fl-mismatch', 1761753600, NULL, 60, 30, 20, NULL, NULL, 0, "
          "NULL, NULL, 1700000000), "
          "('fl-zero', 1761840000, NULL, 0, 0, 0, NULL, NULL, 0, NULL, NULL, "
          "1700000000), "
          "('fl-match', 1761926400, NULL, 90, 90, 0, 'VH-XZO', NULL, 0, "
          "NULL, NULL, 1700000000), "
          "('fl-unmatched', 1762012800, NULL, 90, 90, 0, 'VH-NOPE', NULL, 0, "
          "NULL, NULL, 1700000000), "
          "('fl-crew', 1762099200, NULL, 90, 90, 0, NULL, 'jane doe', 0, "
          "NULL, NULL, 1700000000), "
          "('fl-dup1', 1762185600, 'YSSY - YBBN', 45, 45, 0, NULL, NULL, 0, "
          "NULL, NULL, 1700000000), "
          "('fl-dup2', 1762185600, 'YSSY - YBBN', 45, 45, 0, NULL, NULL, 0, "
          "NULL, NULL, 1700000000), "
          "('fl-route-bad', 1762272000, 'not an airport pair', 60, 60, 0, "
          "NULL, NULL, 0, NULL, NULL, 1700000000), "
          "('fl-future', $futureEpoch, NULL, 60, 60, 0, NULL, NULL, 0, NULL, "
          "NULL, 1700000000), "
          "('fl-dangle', 1762358400, 'YSSY - YBBN', 60, 60, 0, NULL, NULL, "
          "0, NULL, 999, 1700000000), "
          "('fl-sim-nodur', 1762444800, NULL, NULL, NULL, NULL, NULL, NULL, "
          "1, NULL, NULL, 1700000000), "
          "('fl-sim-notsimaircraft', 1762531200, NULL, 60, 60, 0, NULL, "
          "NULL, 1, 'ac-1', NULL, 1700000000)");

      final server = await start();
      final report = payloadOf(await server.call('data_quality_report', {}));

      Map<String, dynamic> at(String id) => {
            'id': id,
            'date': epochToCalendarDate(switch (id) {
              'fl-draft' => 1761494400,
              'fl-draft2' => 1761580800,
              'fl-missing' => 1761667200,
              'fl-mismatch' => 1761753600,
              'fl-zero' => 1761840000,
              'fl-match' => 1761926400,
              'fl-unmatched' => 1762012800,
              'fl-crew' => 1762099200,
              'fl-dup1' || 'fl-dup2' => 1762185600,
              'fl-route-bad' => 1762272000,
              'fl-future' => futureEpoch,
              'fl-dangle' => 1762358400,
              'fl-sim-nodur' => 1762444800,
              'fl-sim-notsimaircraft' => 1762531200,
              _ => throw ArgumentError(id),
            }),
          };

      expect(report['total_flights'], 16,
          reason: 'the two fixture flights plus fourteen arranged');
      expect(report['classes'], [
        {
          'id': 'drafts',
          'label': 'Flights with no total_time (drafts)',
          'count': 3,
          'sample': [
            at('fl-sim-nodur'),
            {...at('fl-draft2'), 'route': 'YSSY - YBBN'},
            {...at('fl-draft'), 'route': 'YSBK - YSSY'},
          ],
        },
        {
          'id': 'missing_split',
          'label': 'Complete flights with a missing day/night split',
          'count': 1,
          'sample': [at('fl-missing')],
        },
        {
          'id': 'split_mismatch',
          'label': 'Flights whose day + night does not equal the total',
          'count': 1,
          'sample': [at('fl-mismatch')],
        },
        {
          'id': 'absurd_totals',
          'label':
              'Totals of zero, or above the app cap of $maxFlightMinutes minutes',
          'count': 1,
          'sample': [at('fl-zero')],
        },
        {
          'id': 'aircraft_matchable',
          'label':
              'Flights whose registration text matches an aircraft row, unlinked',
          'count': 1,
          'sample': [
            {
              ...at('fl-match'),
              'aircraft_registration': 'VH-XZO',
              'candidates': 1,
            },
          ],
        },
        {
          'id': 'aircraft_unmatched',
          'label': 'Flights whose registration text matches no aircraft row',
          'count': 1,
          'sample': [
            {
              ...at('fl-unmatched'),
              'aircraft_registration': 'VH-NOPE',
              'candidates': 0,
            },
          ],
        },
        {
          'id': 'crew_matchable',
          'label': 'Flights whose crew name matches a crew member, unlinked',
          'count': 1,
          'sample': [at('fl-crew')],
        },
        {
          'id': 'duplicate_crew',
          'label': 'Crew members whose names normalise alike',
          'count': 1,
          'sample': [
            {
              'name': 'JANEDOE',
              'members': [
                {'id': 'cr-2', 'name': 'JANE  DOE', 'archived': false},
                {'id': 'cr-1', 'name': 'Jane Doe', 'archived': false},
              ],
            },
          ],
        },
        {
          'id': 'duplicate_flights',
          'label': 'Same date, route, registration and total',
          'count': 1,
          'sample': [
            {
              'date': epochToCalendarDate(1762185600),
              'route': 'YSSY - YBBN',
              'aircraft_registration': null,
              'total_time': 45,
              'flight_ids': ['fl-dup1', 'fl-dup2'],
            },
          ],
        },
        {
          'id': 'route_unparsable',
          'label': 'Routes the app reads as free text, not an airport pair',
          'count': 1,
          'sample': [
            {...at('fl-route-bad'), 'route': 'not an airport pair'},
          ],
        },
        {
          'id': 'future_dates',
          'label': 'Flights dated after today',
          'count': 1,
          'sample': [at('fl-future')],
        },
        {
          'id': 'dangling_route_link',
          'label': 'Route links pointing at no saved route',
          'count': 1,
          'sample': [
            {...at('fl-dangle'), 'route': 'YSSY - YBBN'},
          ],
        },
        {
          'id': 'simulator_oddities',
          'label':
              'Simulator sessions with no duration, or on a non-sim aircraft',
          'count': 2,
          'sample': [
            {...at('fl-sim-notsimaircraft'), 'reason': 'aircraft_not_sim'},
            {...at('fl-sim-nodur'), 'reason': 'no_duration'},
          ],
        },
        {
          'id': 'orphaned_aircraft_text',
          'label':
              'One of the aircraft pair (link, registration text) set, other empty',
          'count': 3,
          'sample': [
            {
              ...at('fl-sim-notsimaircraft'),
              'aircraft_id': 'ac-1',
              'aircraft_registration': null,
            },
            {
              ...at('fl-unmatched'),
              'aircraft_id': null,
              'aircraft_registration': 'VH-NOPE',
            },
            {
              ...at('fl-match'),
              'aircraft_id': null,
              'aircraft_registration': 'VH-XZO',
            },
          ],
        },
      ]);
    });

    test('matching keeps the linkers rules: bare forms, active rows first',
        () async {
      // Two tails whose registrations normalise alike, one of them retired,
      // and a pair with no active row between them. The report counts them the
      // way link_flights_to_aircraft would resolve them.
      insert("INSERT INTO aircraft (id, type, country_code, registration, "
          "archived, created_at) VALUES "
          "('ac-live', 'B738', 'AU', 'VHOLD', 0, 1700000000), "
          "('ac-old', 'B738', 'VH', 'OLD', 1, 1700000000), "
          "('ac-retired1', 'B738', 'VH', 'RET', 1, 1700000000), "
          "('ac-retired2', 'B738', 'NZ', 'VHRET', 1, 1700000000)");
      insert("INSERT INTO flights (id, date, total_time, day_time, night_time, "
          "aircraft_registration, crew_members_name, created_at) VALUES "
          "('fl-bare', 1761580800, 60, 60, 0, 'XZO', NULL, 1700000000), "
          "('fl-live', 1761667200, 60, 60, 0, 'VH-OLD', NULL, 1700000000), "
          "('fl-retired', 1761753600, 60, 60, 0, 'VH-RET', NULL, 1700000000), "
          "('fl-crew-form', 1761840000, 60, 60, 0, NULL, 'DOE Jane', "
          "1700000000)");

      final report =
          payloadOf(await (await start()).call('data_quality_report', {}));

      Map<String, dynamic> at(String id, int epoch,
              [Map<String, dynamic> extra = const {}]) =>
          {
            'id': id,
            'date': epochToCalendarDate(epoch),
            ...extra,
          };

      // Date descending, exactly as the flights query returns them.
      expect(classOf(report, 'aircraft_matchable')['count'], 3);
      expect(
          classOf(report, 'aircraft_matchable')['sample'],
          [
            at('fl-retired', 1761753600,
                {'aircraft_registration': 'VH-RET', 'candidates': 2}),
            at('fl-live', 1761667200,
                {'aircraft_registration': 'VH-OLD', 'candidates': 1}),
            at('fl-bare', 1761580800,
                {'aircraft_registration': 'XZO', 'candidates': 1}),
          ],
          reason: 'an active row hides the retired namesake; a bare form still '
              'matches, because link_flights_to_aircraft matches it');
      expect(classOf(report, 'crew_matchable')['count'], 1,
          reason: 'DOE Jane is Jane Does last-first form');
    });

    test('stays fast when a big logbook meets a big fleet and crew list',
        () async {
      const rows = 5000;
      const fleet = 400;
      const crew = 300;
      withFixtureDb(dbPath, (db) {
        db.execute('BEGIN');
        for (var start = 0; start < fleet; start += 200) {
          final values = [
            for (var i = start; i < start + 200 && i < fleet; i++)
              "('ac-scale$i', 'B738', 'VH', 'S$i', 1700000000)",
          ];
          db.execute('INSERT INTO aircraft (id, type, country_code, '
              'registration, created_at) VALUES ${values.join(', ')}');
        }
        for (var start = 0; start < crew; start += 200) {
          final values = [
            for (var i = start; i < start + 200 && i < crew; i++)
              "('cr-scale$i', 'Crew $i', 'Crew', '$i', 1700000000)",
          ];
          db.execute('INSERT INTO crew_members '
              '(id, name, first_name, last_name, created_at) '
              'VALUES ${values.join(', ')}');
        }
        for (var start = 0; start < rows; start += 500) {
          final values = [
            for (var i = start; i < start + 500 && i < rows; i++)
              "('fl-scale$i', ${1761408000 + i * 60}, 'YSSY - YBBN', 60, 60, "
                  "0, 'VH-S1', 'Crew 1', 1700000000)",
          ];
          db.execute(
              'INSERT INTO flights (id, date, route, total_time, day_time, '
              'night_time, aircraft_registration, crew_members_name, '
              'created_at) VALUES ${values.join(', ')}');
        }
        db.execute('COMMIT');
      });
      final server = await start();
      // Warm the JIT first: the first tool call pays the compile of the
      // handler, which is not what this test is measuring.
      await server.call('data_quality_report', {});

      final watch = Stopwatch()..start();
      final report = payloadOf(await server.call('data_quality_report', {}));
      watch.stop();

      int countOf(String id) => (report['classes'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((c) => c['id'] == id)['count'] as int;
      expect(report['total_flights'], rows + 2);
      expect(countOf('aircraft_matchable'), rows);
      expect(countOf('crew_matchable'), rows);
      // Measured on this fixture: 160 ms with the lookups loaded once, about
      // 7 s before #54, when every flight rescanned the aircraft and crew
      // tables. The bound is a fence, not a benchmark: roughly 19x the
      // measured cost, so a slow CI box is not a failure, while a per-row
      // query coming back lands well above it.
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)),
          reason: 'data_quality_report took ${watch.elapsedMilliseconds} ms '
              'for $rows rows against a $fleet-aircraft fleet and $crew crew');
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

    test(
        'an explicit flight_id with no link and no text is reported, not '
        'thrown', () async {
      // Issue #60: fl-draft has aircraft_id IS NULL and empty registration
      // text, so there is nothing to resolve. The preview must report it.
      final server = await start(write: true);

      final preview = payloadOf(await server.call('link_flights_to_aircraft', {
        'flight_ids': ['fl-draft']
      }));

      expect(preview['dry_run'], isTrue);
      expect(preview['linked'], 0);
      final unmatched = preview['unmatched'] as List;
      expect(unmatched.single['flight_id'], 'fl-draft');
      expect(unmatched.single['detail'],
          'flight has no aircraft and no registration text');

      final applied = payloadOf(await server.call('link_flights_to_aircraft', {
        'flight_ids': ['fl-draft'],
        'dry_run': false
      }));
      expect(applied['linked'], 0);
      expect((applied['unmatched'] as List).single['flight_id'], 'fl-draft');

      final row = withFixtureDb(
          dbPath,
          (db) => db
              .select('SELECT aircraft_id, aircraft_registration FROM flights '
                  "WHERE id = 'fl-draft'")).single;
      expect(row['aircraft_id'], isNull);
      expect(row['aircraft_registration'], isNull);
    });

    test('a batch with one unlinkable flight still links the others', () async {
      insert("INSERT INTO flights (id, date, route, aircraft_registration, "
          "created_at) VALUES ('fl-link', 1761408000, 'YSSY - NZQN', "
          "'VH-XZO', 1700000000)");
      final server = await start(write: true);

      final applied = payloadOf(await server.call('link_flights_to_aircraft', {
        'flight_ids': ['fl-draft', 'fl-link'],
        'dry_run': false
      }));

      expect(applied['linked'], 1);
      expect((applied['unmatched'] as List).single['flight_id'], 'fl-draft');
      final row = withFixtureDb(
              dbPath,
              (db) => db.select(
                  'SELECT aircraft_id FROM flights WHERE id = ?', ['fl-link']))
          .single;
      expect(row['aircraft_id'], 'ac-1');
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

  // Issue #57: deleting a saved route unlinks its flights, and that unlink is
  // a flight write. Without the updated_at stamp a delta push never re-selects
  // the flight, so the cloud keeps a route_id pointing at the deleted route.
  group('delete_saved_route', () {
    test('previews then unlinks every flight and stamps updated_at', () async {
      insert("UPDATE flights SET route_id = 1, updated_at = 1700000000 "
          "WHERE id = 'fl-1'");
      insert("INSERT INTO flights (id, date, route, route_id, updated_at, "
          "created_at) VALUES ('fl-route-b', 1761494400, 'YSSY - EGLL', 1, "
          "1700000000, 1700000000)");
      insert(
          "UPDATE flights SET updated_at = 1700000000 WHERE id = 'fl-draft'");
      final server = await start(write: true);

      Map<String, Map<String, Object?>> rows() => withFixtureDb(
          dbPath,
          (db) => {
                for (final row in db.select(
                    'SELECT id, route_id, updated_at FROM flights ORDER BY id'))
                  row['id'] as String: {
                    'id': row['id'],
                    'route_id': row['route_id'],
                    'updated_at': row['updated_at'],
                  },
              });
      final before = rows();

      final preview = payloadOf(
          await server.call('delete_saved_route', {'id': 1, 'dry_run': true}));
      expect(preview['dry_run'], isTrue);
      expect(preview['status'], 'deleted');
      expect(preview['affected_ids'], unorderedEquals(['fl-1', 'fl-route-b']));
      expect(rows(), before, reason: 'the preview changes nothing');

      final applied = payloadOf(
          await server.call('delete_saved_route', {'id': 1, 'dry_run': false}));
      expect(applied.containsKey('dry_run'), isFalse,
          reason: 'an applied delete is not marked');
      expect(applied['status'], 'deleted');
      expect(applied['table'], 'saved_routes');
      expect(applied['affected_ids'], unorderedEquals(['fl-1', 'fl-route-b']),
          reason: 'the response names the flights it unlinked');

      final after = rows();
      for (final id in ['fl-1', 'fl-route-b']) {
        expect(after[id]!['route_id'], isNull);
        expect(after[id]!['updated_at'],
            greaterThan(before[id]!['updated_at'] as int),
            reason: '$id must carry a stamp so a delta push sees the unlink');
      }
      expect(after['fl-draft'], before['fl-draft'],
          reason: 'a flight that never linked to the route is untouched');
      expect(
          withFixtureDb(
              dbPath, (db) => db.select('SELECT id FROM saved_routes')),
          isEmpty);
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
