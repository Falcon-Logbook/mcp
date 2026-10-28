import 'dart:convert';
import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart'
    show auditPathFor, dateToEpoch, formatCalendarDate;
import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #3: a pilot pastes a roster, the model reads it, and this server
/// validates the rows and writes them as drafts in one transaction. The tests
/// pin the three properties that keep a schedule out of the hours: validation
/// writes nothing, the batch is atomic unless it is told otherwise, and a
/// scheduled leg never acquires a total.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_roster_test');
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

  void insert(String sql, [List<Object?> params = const []]) =>
      withFixtureDb(dbPath, (db) => db.execute(sql, params));

  /// The airport reference the app's built-in list provides. An empty list is
  /// "not imported yet" and the validator stays quiet about it, so the tests
  /// that want airport resolution seed one.
  void seedAirports() => insert(
        "INSERT INTO airports (icao, iata, name, lat, lon) VALUES "
        "('YSSY', 'SYD', 'Sydney', -33.94, 151.18), "
        "('YBBN', 'BNE', 'Brisbane', -27.38, 153.12), "
        "('NZQN', NULL, 'Queenstown', -45.02, 168.74)",
      );

  /// Falcon-Logbook/app#231's columns, added at user_version 19: the migration
  /// has not shipped, so this is how a migrated database is exercised without
  /// pretending a schema version exists.
  void addPlannedColumns() {
    insert(
        'ALTER TABLE flights ADD COLUMN scheduled_departure_utc INTEGER NULL');
    insert('ALTER TABLE flights ADD COLUMN scheduled_arrival_utc INTEGER NULL');
    insert(
        'ALTER TABLE flights ADD COLUMN scheduled_block_minutes INTEGER NULL');
  }

  int flightCount() => withFixtureDb(
        dbPath,
        (db) =>
            db.select('SELECT COUNT(*) AS n FROM flights').single['n'] as int,
      );

  List<Map<String, dynamic>> auditEntries() {
    final file = File(auditPathFor(dbPath));
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  Map<String, dynamic> rowAt(Map<String, dynamic> report, int index) =>
      (report['rows'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((row) => row['index'] == index);

  List<Map<String, dynamic>> issuesAt(Map<String, dynamic> report, int index) =>
      (rowAt(report, index)['issues'] as List).cast<Map<String, dynamic>>();

  Set<String> codesAt(Map<String, dynamic> report, int index) =>
      {for (final issue in issuesAt(report, index)) issue['code'] as String};

  Future<String> promptText(McpProcess server, String name) async {
    final response = await server.send('prompts/get', {'name': name});
    final messages = ((response['result'] as Map)['messages'] as List);
    return ((messages.single as Map)['content'] as Map)['text'] as String;
  }

  /// A month of flying: 20 legs, four a day, no totals, every field the roster
  /// needs and nothing that needs asking about.
  List<Map<String, dynamic>> cleanRoster() {
    const routes = [
      'YSSY - NZQN',
      'YBBN - YSSY',
      'YSSY - YBBN',
      'NZQN - YSSY',
    ];
    return [
      for (var day = 0; day < 5; day++)
        for (var leg = 0; leg < 4; leg++)
          {
            'client_ref': 'leg-${day * 4 + leg + 1}',
            'date': formatCalendarDate(DateTime(2026, 11, 2 + day)),
            'route': routes[leg],
            'aircraft_registration': 'VH-XZO',
            'crew_role': 'pilotInCommand',
            'crew_members_name': 'Jane Doe',
            'draft': true,
          },
    ];
  }

  group('validate_flight_drafts', () {
    test('writes nothing: no row and no audit entry', () async {
      seedAirports();
      final before = flightCount();
      final server = await start(write: true);

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'flights': cleanRoster(),
        'date_from': '2026-11-02',
        'date_to': '2026-11-06',
      }));

      expect(report['valid'], 20);
      expect(report['invalid'], 0);
      expect(report['range'], {'from': '2026-11-02', 'to': '2026-11-06'});
      expect(flightCount(), before, reason: 'validation opens no write');
      expect(File(auditPathFor(dbPath)).existsSync(), isFalse,
          reason: 'validation records no audit entry');
    });

    test('a clean 20-leg roster has no issue on any row', () async {
      seedAirports();
      final server = await start();

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'flights': cleanRoster(),
      }));

      expect(report['valid'], 20);
      for (final row in (report['rows'] as List).cast<Map<String, dynamic>>()) {
        expect(row['ok'], isTrue, reason: 'row ${row['index']}');
        expect(row['issues'], isEmpty, reason: 'row ${row['index']}');
        expect(row.containsKey('warnings'), isFalse,
            reason: 'row ${row['index']} has nothing to warn about');
      }
      expect((report['rows'] as List).first['client_ref'], 'leg-1');
    });

    test('every issue class fires on the right row, with a stable code',
        () async {
      // The one class that needs the planned-time columns. Everything else is
      // exercised on a migrated database too, since a real v20 file has both.
      addPlannedColumns();
      seedAirports();
      insert(
        "INSERT INTO aircraft (id, type, country_code, registration, created_at) "
        "VALUES ('ac-nz', 'C172', 'ZK', 'XZO', 1700000000)",
      );
      // The row a duplicate is checked against: same date, route, registration
      // and total as the roster row below.
      insert(
        "INSERT INTO flights (id, date, route, aircraft_registration, total_time, "
        "created_at) VALUES ('fl-dup-source', ?, 'YSSY - NZQN', 'VH-XZO', 120, "
        '1700000000)',
        [dateToEpoch('2026-11-03')],
      );
      final server = await start();

      final roster = <Map<String, dynamic>>[
        {
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'crew_role': 'pilotInCommand',
          'crew_members_name': 'Jane Doe',
          'draft': true,
        },
        // 1: a registration nothing matches.
        {
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-NOPE',
          'draft': true,
        },
        // 2: one tail under two countries.
        {
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'XZO',
          'draft': true,
        },
        // 3: a segment no airport answers to.
        {
          'date': '2026-11-02',
          'route': 'YSSY - ZZZZ',
          'aircraft_registration': 'VH-XZO',
          'draft': true,
        },
        // 4: a name the crew table does not hold. Informational: the app stores
        // the text.
        {
          'date': '2026-11-02',
          'route': 'YBBN - YSSY',
          'aircraft_registration': 'VH-XZO',
          'crew_members_name': 'Nobody Here',
          'draft': true,
        },
        // 5, 6, 7: the three enums.
        {'date': '2026-11-02', 'crew_role': 'captain', 'draft': true},
        {'date': '2026-11-02', 'flight_type': 'logbook', 'draft': true},
        {'date': '2026-11-02', 'calc_time_mode': 'zulu', 'draft': true},
        // 8: the same identity as row 0, inside the batch.
        {
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'crew_role': 'pilotInCommand',
          'crew_members_name': 'Jane Doe',
          'draft': true,
        },
        // 9: a scheduled leg that also carries a total.
        {
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'scheduled_departure_utc': dateToEpoch('2026-11-02'),
          'scheduled_block_minutes': 90,
          'total_time': 90,
        },
        // 10: a type with a tail in the fleet, no registration.
        {
          'date': '2026-11-02',
          'route': 'YSSY - NZQN',
          'aircraft_type': 'B738',
          'draft': true,
        },
        // 11: a type with no tail at all.
        {
          'date': '2026-11-02',
          'route': 'YBBN - YSSY',
          'aircraft_type': 'A320',
          'draft': true,
        },
        // 12: a value the write itself refuses.
        {'date': '2026-11-02', 'total_time': 0},
        // 13: a flight the logbook already holds.
        {
          'date': '2026-11-03',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'total_time': 120,
        },
        // 14: after the stated window.
        {'date': '2026-11-20', 'draft': true},
        // 15: before the previous leg, and before the window.
        {'date': '2026-10-15', 'draft': true},
        // 16: a name create_flight would refuse.
        {'date': '2026-11-04', 'block_off': 10, 'draft': true},
        // 17: a route the app reads as a description.
        {'date': '2026-11-04', 'route': 'not an airport pair', 'draft': true},
        // 18: day and night that do not add up.
        {
          'date': '2026-11-05',
          'total_time': 120,
          'day_time': 60,
          'night_time': 30
        },
        // 19: no date at all.
        {'route': 'YSSY - NZQN', 'draft': true},
      ];

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'flights': roster,
        'date_from': '2026-11-01',
        'date_to': '2026-11-10',
      }));

      final expected = <int, String>{
        1: 'aircraft_unmatched',
        2: 'aircraft_ambiguous',
        3: 'airport_unresolved',
        4: 'crew_unmatched',
        5: 'invalid_crew_role',
        6: 'invalid_flight_type',
        7: 'invalid_calc_time_mode',
        8: 'duplicate_batch',
        9: 'scheduled_total_time',
        10: 'aircraft_missing',
        11: 'aircraft_missing',
        12: 'invalid_row',
        13: 'duplicate_existing',
        14: 'date_out_of_range',
        15: 'date_order',
        16: 'unknown_field',
        17: 'route_unparsable',
        18: 'split_mismatch',
        19: 'date_missing',
      };
      for (final entry in expected.entries) {
        expect(codesAt(report, entry.key), contains(entry.value),
            reason: 'row ${entry.key} should report ${entry.value}');
      }
      expect(codesAt(report, 0), isEmpty, reason: 'row 0 is clean');
      expect(report['invalid'], 8,
          reason: 'rows 5, 6, 7, 9, 12, 16, 18 and 19 are errors');
      expect(report['valid'], 12);

      // The classes carry the evidence the issue asks for, not just a label.
      final airport = issuesAt(report, 3).single;
      expect('${airport['message']}', contains('ZZZZ'));
      expect('${airport['message']}', contains('YSSY'));
      expect((issuesAt(report, 2).single['candidates'] as List), hasLength(2));
      expect((issuesAt(report, 10).single['candidates'] as List).single['id'],
          'ac-1');
      expect(issuesAt(report, 11).single.containsKey('candidates'), isFalse);
      expect((issuesAt(report, 4).single['severity']), 'info');
      expect((issuesAt(report, 9).single['severity']), 'error',
          reason: 'a total on a scheduled leg is hard: it adds unflown hours');
      expect(
          '${issuesAt(report, 9).single['message']}', contains('never flown'));
      expect((issuesAt(report, 1).single['severity']), 'warning');

      // The prose warning _flightValues raises for the same registration is not
      // repeated next to the coded issue.
      expect(rowAt(report, 1).containsKey('warnings'), isFalse);
    });

    test('refuses more rows than one roster call takes', () async {
      final server = await start();

      final result = await server
          .call('validate_flight_drafts', {'flights': List.filled(501, {})});

      expect(result.isError, isTrue);
      expect('${result.payload}', contains('500'));
    });
  });

  group('apply_flight_batch', () {
    test('is atomic: one hard row writes nothing and is named', () async {
      final before = flightCount();
      final server = await start(write: true);

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN', 'draft': true},
          {
            'date': '2026-11-02',
            'route': 'YBBN - YSSY',
            'crew_role': 'captain',
            'draft': true,
          },
        ],
      }));

      expect(result['applied'], 0);
      expect(result['created'], isEmpty);
      expect(result['valid'], 1);
      expect(result['invalid'], 1);
      final failed = (result['failed'] as List).cast<Map<String, dynamic>>();
      expect(failed.single['index'], 1);
      expect('${failed.single['reason']}', contains('crew_role'));
      expect((failed.single['issues'] as List).single['code'],
          'invalid_crew_role');
      expect(flightCount(), before, reason: 'one bad row rolls the batch back');
    });

    test('allow_partial lands the clean rows and lists the rest', () async {
      final before = flightCount();
      final server = await start(write: true);

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'allow_partial': true,
        'flights': [
          {
            'client_ref': 'leg-1',
            'date': '2026-11-02',
            'route': 'YSSY - NZQN',
            'draft': true,
          },
          {
            'client_ref': 'leg-2',
            'date': '2026-11-02',
            'route': 'YBBN - YSSY',
            'crew_role': 'captain',
            'draft': true,
          },
          {
            'date': '2026-11-02',
            'route': 'YSSY - YBBN',
            'planned_times_are_not_a_field': true,
            'draft': true,
          },
        ],
      }));

      expect(result['applied'], 1);
      expect((result['created'] as List), hasLength(1));
      expect(result['created_refs'], ['leg-1']);
      final failed = (result['failed'] as List).cast<Map<String, dynamic>>();
      expect([for (final row in failed) row['index']], [1, 2],
          reason: 'both refusals are reported, with their index');
      expect(flightCount(), before + 1);
      final stored = withFixtureDb(
          dbPath,
          (db) => db.select(
              'SELECT route, total_time FROM flights WHERE id = ?',
              [(result['created'] as List).single]).single);
      expect(stored['route'], 'YSSY - NZQN');
      expect(stored['total_time'], isNull, reason: 'a roster leg is a draft');

      // The failed row did not land, so its client_ref is not spent: fixing it
      // and retrying imports it rather than skipping it as already imported.
      final retry = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [
          {
            'client_ref': 'leg-2',
            'date': '2026-11-02',
            'route': 'YBBN - YSSY',
            'crew_role': 'pilotInCommand',
            'draft': true,
          },
        ],
      }));
      expect(retry['applied'], 1, reason: 'the fixed row lands');
      expect(flightCount(), before + 2);
    });

    test('a duplicate in the logbook is skipped, never overwritten', () async {
      insert(
        "INSERT INTO flights (id, date, route, aircraft_registration, "
        "created_at) VALUES ('fl-existing', ?, 'YSSY - NZQN', 'VH-XZO', "
        '1700000000)',
        [dateToEpoch('2026-12-01')],
      );
      final server = await start(write: true);

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [
          {
            'date': '2026-12-01',
            'route': 'YSSY - NZQN',
            'aircraft_registration': 'VH-XZO',
            'draft': true,
          },
          {'date': '2026-12-02', 'route': 'YSSY - NZQN', 'draft': true},
        ],
      }));

      expect(result['applied'], 1);
      final skipped = (result['skipped'] as List).cast<Map<String, dynamic>>();
      expect(skipped.single['index'], 0);
      expect(skipped.single['code'], 'duplicate_existing');
      expect('${skipped.single['reason']}', contains('fl-existing'));
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT total_time FROM flights WHERE id = ?',
                  ['fl-existing']).single)['total_time'],
          isNull,
          reason: 'the existing row is untouched');
    });

    test('a client_ref retry creates nothing the second time', () async {
      final server = await start(write: true);
      final roster = [
        {
          'client_ref': 'leg-1',
          'date': '2026-12-07',
          'route': 'YSSY - NZQN',
          'draft': true,
        },
        {
          'client_ref': 'leg-2',
          'date': '2026-12-07',
          'route': 'YBBN - YSSY',
          'draft': true,
        },
      ];

      final first = payloadOf(await server
          .call('apply_flight_batch', {'dry_run': false, 'flights': roster}));
      expect(first['applied'], 2);
      final afterFirst = flightCount();

      final second = payloadOf(await server
          .call('apply_flight_batch', {'dry_run': false, 'flights': roster}));

      expect(second['applied'], 0);
      expect(second['created'], isEmpty);
      expect(flightCount(), afterFirst, reason: 'the retry is idempotent');
      final skipped = (second['skipped'] as List).cast<Map<String, dynamic>>();
      expect([for (final row in skipped) row['code']],
          ['client_ref_seen', 'client_ref_seen']);
      expect('${skipped.first['reason']}', contains('leg-1'));
    });

    test('without the v20 columns, planned times are refused with the message',
        () async {
      final server = await start(write: true);
      final planned = {
        'date': '2026-11-02',
        'route': 'YSSY - NZQN',
        'scheduled_departure_utc': dateToEpoch('2026-11-02'),
        'scheduled_block_minutes': 90,
      };

      final validation = payloadOf(await server.call('validate_flight_drafts', {
        'flights': [planned],
      }));
      expect(codesAt(validation, 0), contains('planned_times_unsupported'));
      expect((issuesAt(validation, 0).single['severity']), 'error');

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [planned]
      }));
      expect(result['applied'], 0);
      expect('${(result['failed'] as List).single['reason']}',
          contains('does not store planned times'));
      expect(flightCount(), 2, reason: 'the two seeded flights, nothing else');

      // The same leg with the times dropped lands as a draft with no total.
      final plain = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN'},
        ],
      }));
      expect(plain['applied'], 1);
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT total_time FROM flights WHERE id = ?',
                  [(plain['created'] as List).single])).single['total_time'],
          isNull);
    });

    test(
        'with the v20 columns, planned times round-trip and total_time stays '
        'null', () async {
      addPlannedColumns();
      final server = await start(write: true);
      final departure = dateToEpoch('2026-11-02')! + 8 * 3600;
      final arrival = departure + 90 * 60;

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [
          {
            'date': '2026-11-02',
            'route': 'YSSY - NZQN',
            'aircraft_registration': 'VH-XZO',
            'scheduled_departure_utc': departure,
            'scheduled_arrival_utc': arrival,
            'scheduled_block_minutes': 90,
          },
        ],
      }));

      expect(result['applied'], 1);
      final stored = withFixtureDb(
          dbPath,
          (db) => db.select(
              'SELECT scheduled_departure_utc, scheduled_arrival_utc, '
              'scheduled_block_minutes, total_time, day_order FROM flights '
              'WHERE id = ?',
              [(result['created'] as List).single])).single;
      expect(stored['scheduled_departure_utc'], departure);
      expect(stored['scheduled_arrival_utc'], arrival);
      expect(stored['scheduled_block_minutes'], 90);
      expect(stored['total_time'], isNull,
          reason: 'the block is the plan, never the time flown');
      expect(stored['day_order'], 0);
    });

    test('one audit entry per batch carries batch_id and the created ids',
        () async {
      final server = await start(write: true);
      final roster = [
        {'date': '2026-12-09', 'route': 'YSSY - NZQN', 'draft': true},
        {'date': '2026-12-09', 'route': 'YBBN - YSSY', 'draft': true},
      ];
      final before = flightCount();

      // dry_run defaults to a preview: the same plan, the same ids resolved and
      // nothing written.
      final preview = payloadOf(
          await server.call('apply_flight_batch', {'flights': roster}));
      expect(preview['dry_run'], isTrue);
      expect((preview['created'] as List), hasLength(2));
      expect(preview['applied'], 2);
      expect(flightCount(), before, reason: 'the preview commits nothing');

      final applied = payloadOf(await server
          .call('apply_flight_batch', {'dry_run': false, 'flights': roster}));
      expect(applied['dry_run'], isFalse);
      expect(applied['batch_id'], isNotEmpty);
      expect(applied['created'], hasLength(2));

      final entries = [
        for (final entry in auditEntries())
          if (entry['tool'] == 'apply_flight_batch') entry,
      ];
      expect(entries, hasLength(2),
          reason: 'one entry per call, not one per row');
      expect(entries.first['result'], 'dry_run');
      final last = entries.last;
      expect(last['result'], 'ok');
      expect((last['args'] as Map)['batch_id'], applied['batch_id']);
      expect(last['ids'], applied['created']);
    });
  });

  group('read-only mode and the roster protocol', () {
    test('registers the validator, not the batch, and the help names no write',
        () async {
      final reader = await start();
      final tools = await reader.toolNames();
      expect(tools, contains('validate_flight_drafts'));
      expect(tools, isNot(contains('apply_flight_batch')));

      final help = await promptText(reader, 'falcon_help');
      expect(help, isNot(contains('apply_flight_batch')));
      expect(help, isNot(contains('create_flight')));
      expect(help, isNot(contains('Draft what is ahead')),
          reason: 'the roster write flow only appears with writes on');
      expect(help, contains('Find what is missing'),
          reason: 'the read half is advertised in both modes');

      final writer = await start(write: true);
      final writeHelp = await promptText(writer, 'falcon_help');
      expect(writeHelp, contains('Draft what is ahead'));
      expect(await writer.toolNames(), contains('apply_flight_batch'));
    });

    test(
        'the prompt points at the resource, and the resource carries the rules',
        () async {
      final server = await start();

      final prompt = await promptText(server, 'roster_import');
      expect(prompt, contains('falcon://roster_import'));
      expect(prompt, contains('validate_flight_drafts'));
      expect(prompt, isNot(contains('\u2014')));

      final response = await server
          .send('resources/read', {'uri': 'falcon://roster_import'});
      final text = (((response['result'] as Map)['contents'] as List).single
          as Map)['text'] as String;
      for (final statement in [
        'A roster is a schedule, not a logbook',
        'ask_user',
        'PLAN BEFORE WRITE',
        'Never write a scheduled time into total_time',
        'NEVER FABRICATE',
        'REPORT EVERY ROW',
        'scheduled_block_minutes',
        'Falcon-Logbook/app#231',
        'apply_flight_batch',
      ]) {
        expect(text, contains(statement));
      }
      expect(text, isNot(contains('\u2014')), reason: 'no em dashes');
    });
  });
}
