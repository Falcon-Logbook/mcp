import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart'
    show auditPathFor, dateToEpoch, formatCalendarDate, readAudit;
import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #4: a logbook file is mapped to Falcon by hand, reviewed, validated
/// and written in one atomic batch, reusing the roster engine with
/// `mode: "import"`. The tests pin what keeps a legal-ish document honest:
/// the declared duration unit is the only one read, a date that is not
/// YYYY-MM-DD is refused with its probable reading rather than converted, an
/// unknown column is a question with real alternatives rather than a silent
/// drop, and a batch is atomic unless the pilot allows a partial one.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_import_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<McpProcess> start(
      {bool write = true, Map<String, String> environment = const {}}) async {
    final server =
        await McpProcess.start(dbPath, write: write, environment: environment);
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

  int flightCount() => withFixtureDb(
        dbPath,
        (db) =>
            db.select('SELECT COUNT(*) AS n FROM flights').single['n'] as int,
      );

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

  Future<String> resourceText(McpProcess server, String uri) async {
    final response = await server.send('resources/read', {'uri': uri});
    return (((response['result'] as Map)['contents'] as List).single
        as Map)['text'] as String;
  }

  /// The flight columns this build can write, as the test pins them: the
  /// write spec's names, cut to what the live table can store. The resource's
  /// column table must equal this, so a fabricated or missing column fails
  /// here rather than in an import.
  const writableSpec = [
    'date',
    'day_order',
    'aircraft_id',
    'aircraft_registration',
    'flight_type',
    'crew_role',
    'crew_member_id',
    'crew_members_name',
    'route',
    'flight_number',
    'total_time',
    'day_time',
    'night_time',
    'calc_time_mode',
    'time_start',
    'time_stop',
    'hobbs_start',
    'hobbs_stop',
    'actual_instrument',
    'simulated_instrument',
    'ground_instrument',
    'icus_day_time',
    'icus_night_time',
    'approaches2d',
    'approaches3d',
    'approach_details',
    'takeoffs',
    'landings',
    'takeoff_day',
    'takeoff_night',
    'landing_day',
    'landing_night',
    'water_takeoffs',
    'water_landings',
    'is_simulator',
    'is_ifr',
    'custom_columns',
    'scheduled_departure_utc',
    'scheduled_arrival_utc',
    'scheduled_block_minutes',
  ];

  List<String> liveFlightColumns() => withFixtureDb(
        dbPath,
        (db) => [
          for (final row in db.select('PRAGMA table_info(flights)'))
            row['name'] as String,
        ],
      );

  List<String> columnTableNames(String text) => [
        for (final line in text.split('\n'))
          if (RegExp(r'^- (\S+) \(').hasMatch(line))
            RegExp(r'^- (\S+) \(').firstMatch(line)!.group(1)!,
      ];

  group('import units', () {
    test('a cell that is not the declared unit is refused, never guessed',
        () async {
      final server = await start();

      final decimal = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'units': 'decimal_hours',
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN', 'total_time': '1:30'},
        ],
      }));
      final decimalIssue = issuesAt(decimal, 0).single;
      expect(decimalIssue['code'], 'unit_mismatch');
      expect(decimalIssue['severity'], 'error');
      expect(decimalIssue['field'], 'total_time');
      expect('${decimalIssue['message']}', contains('1:30'));
      expect('${decimalIssue['message']}', contains('decimal_hours'));

      final hhmm = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'units': 'hhmm',
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN', 'total_time': 1.5},
        ],
      }));
      expect(issuesAt(hhmm, 0).single['code'], 'unit_mismatch');

      final minutes = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN', 'total_time': '1:30'},
        ],
      }));
      expect(issuesAt(minutes, 0).single['code'], 'unit_mismatch',
          reason: 'minutes is the declared default and 1:30 is not minutes');
    });

    test('a valid decimal_hours cell becomes whole minutes', () async {
      final server = await start();

      final applied = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'units': 'decimal_hours',
        'flights': [
          {
            'date': '2026-11-02',
            'route': 'YSSY - NZQN',
            'total_time': 1.5,
            'day_time': 1.5,
          },
        ],
      }));

      expect(applied['applied'], 1);
      final stored = withFixtureDb(
          dbPath,
          (db) => db.select(
              'SELECT total_time, day_time FROM flights '
              'WHERE id = ?',
              [(applied['created'] as List).single]).single);
      expect(stored['total_time'], 90, reason: '1.5 decimal hours is 90');
      expect(stored['day_time'], 90);

      final hhmm = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'units': 'hhmm',
        'flights': [
          {'date': '2026-11-03', 'route': 'YSSY - NZQN', 'total_time': '1:30'},
        ],
      }));
      expect(hhmm['applied'], 1);
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT total_time FROM flights WHERE id = ?',
                  [(hhmm['created'] as List).single]).single['total_time']),
          90,
          reason: '1:30 hhmm is 90');
    });

    test('a non-whole or out-of-range duration is unit_implausible', () async {
      final server = await start();

      final fractional = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'units': 'decimal_hours',
        'flights': [
          {'date': '2026-11-02', 'total_time': 1.234},
        ],
      }));
      final issue = issuesAt(fractional, 0).single;
      expect(issue['code'], 'unit_implausible');
      expect('${issue['message']}', contains('1.234'));
      expect('${issue['message']}', contains('74.04'),
          reason: 'the message names the minute result');

      final huge = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {'date': '2026-11-02', 'total_time': 600000},
        ],
      }));
      expect(issuesAt(huge, 0).single['code'], 'unit_implausible');
    });

    test('the _hours aliases are refused with unit_conflict in import mode',
        () async {
      final server = await start();

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'units': 'decimal_hours',
        'flights': [
          {'date': '2026-11-02', 'total_time_hours': 1.5},
        ],
      }));

      final issue = issuesAt(report, 0).single;
      expect(issue['code'], 'unit_conflict');
      expect(issue['field'], 'total_time_hours');
      expect(issue['severity'], 'error');
      expect('${issue['message']}', contains('decimal_hours'),
          reason: 'the refusal names the convention the call declared');
    });
  });

  group('import dates', () {
    test('a spreadsheet serial is refused with the date it shows, not written',
        () async {
      final before = flightCount();
      final server = await start();
      // A numeric string of 400 nines parses to Infinity, and a number far
      // past the last date a cell can show. Both are refused by name rather
      // than crashing the conversion.
      final giant = '9' * 400;
      const huge = 1e20;

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {'date': 45290, 'route': 'YSSY - NZQN', 'total_time': 90},
          {'date': 45296, 'route': 'YSSY - NZQN', 'total_time': 90},
          {'date': '45290', 'route': 'YSSY - NZQN', 'total_time': 90},
          {'date': giant, 'route': 'YSSY - NZQN', 'total_time': 90},
          {'date': huge, 'route': 'YSSY - NZQN', 'total_time': 90},
        ],
      }));

      // The reading is the serial epoch plus the serial: DateTime.utc(1899,
      // 12, 30) + days. 45290 shows 2023-12-30 and 45296 shows 2024-01-05.
      // The refusal names what the cell shows and never converts it.
      final first = issuesAt(report, 0).single;
      expect(first['code'], 'serial_date');
      expect(first['severity'], 'error');
      expect(first['field'], 'date');
      expect('${first['message']}', contains('45290'));
      expect('${first['message']}', contains('2023-12-30'));
      expect(issuesAt(report, 1).single['code'], 'serial_date');
      expect(
          '${issuesAt(report, 1).single['message']}', contains('2024-01-05'));
      expect(issuesAt(report, 2).single['code'], 'serial_date',
          reason: 'a numeric string is a serial too');
      for (var index = 0; index < 5; index++) {
        expect(issuesAt(report, index), hasLength(1),
            reason: 'row $index carries the date refusal alone');
      }

      // Out of the range a spreadsheet can show: the refusal names the cell as
      // written and says the value cannot be a date, and the conversion is
      // never attempted.
      final oversized = issuesAt(report, 3).single;
      expect(oversized['code'], 'serial_date');
      expect('${oversized['message']}', contains(giant),
          reason: 'the numeric string is echoed as typed');
      expect('${oversized['message']}',
          contains('outside the range a spreadsheet can show'));
      final beyond = issuesAt(report, 4).single;
      expect(beyond['code'], 'serial_date');
      expect('${beyond['message']}', contains('$huge'));
      expect('${beyond['message']}',
          contains('outside the range a spreadsheet can show'));

      final applied = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'flights': [
          {'date': 45290, 'route': 'YSSY - NZQN', 'total_time': 90},
        ],
      }));
      expect(applied['applied'], 0);
      expect(flightCount(), before,
          reason: 'a refused serial date writes nothing');
    });

    test(
        'a text date is refused with its probable reading, both when '
        'ambiguous', () async {
      final server = await start();

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {'date': '27/10/2026', 'total_time': 90},
          {'date': '10/27/2026', 'total_time': 90},
          {'date': '10/11/2026', 'total_time': 90},
          {'date': '2026-10-27T00:00:00Z', 'total_time': 90},
        ],
      }));

      final dmy = issuesAt(report, 0).single;
      expect(dmy['code'], 'date_format');
      expect('${dmy['message']}', contains('27/10/2026'));
      expect('${dmy['message']}', contains('2026-10-27'),
          reason: 'a field past 12 fixes the reading');
      expect('${issuesAt(report, 1).single['message']}', contains('2026-10-27'),
          reason: '27 in the second field is M/D/Y');
      final ambiguous = issuesAt(report, 2).single;
      expect(ambiguous['code'], 'date_format');
      expect('${ambiguous['message']}', contains('2026-11-10'),
          reason: 'the D/M/Y reading is named');
      expect('${ambiguous['message']}', contains('2026-10-11'),
          reason: 'the M/D/Y reading is named too');
      final timestamp = issuesAt(report, 3).single;
      expect(timestamp['code'], 'date_format');
      expect('${timestamp['message']}', contains('2026-10-27'));
      for (var index = 0; index < 4; index++) {
        expect(issuesAt(report, index), hasLength(1),
            reason: 'row $index carries the date refusal and nothing generic');
      }
    });

    test('a timestamp is read on the logbook-zone day it falls on', () async {
      // UTC+14: an instant late on 27 October UTC is already the 28th in the
      // logbook zone, and that is the day the flight was flown.
      final server =
          await start(environment: {'FALCON_TZ': 'Pacific/Kiritimati'});

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {'date': '2026-10-27T23:30:00Z', 'total_time': 90},
        ],
      }));

      final timestamp = issuesAt(report, 0).single;
      expect(timestamp['code'], 'date_format');
      expect('${timestamp['message']}', contains('2026-10-28'),
          reason: 'the logbook-zone day is the probable reading');
      expect('${timestamp['message']}', contains('2026-10-27'),
          reason: 'the date the text starts with is named as well');
    });
  });

  group('import columns', () {
    test('an unknown column is surfaced with real alternatives, never dropped',
        () async {
      final server = await start();

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {
            'date': '2026-11-02',
            'total_time': 90,
            'INSTR': '12:30',
            'REMARKS': 'a note',
          },
        ],
      }));

      final issues = issuesAt(report, 0);
      expect(issues, hasLength(2),
          reason: 'one issue per unknown column, and the rest of the row is '
              'still evaluated');
      final instr = issues.firstWhere((issue) => issue['field'] == 'INSTR');
      expect(instr['code'], 'unknown_column');
      expect(instr['severity'], 'error');
      expect('${instr['message']}', contains('INSTR'));
      final names = [
        for (final candidate in instr['candidates'] as List)
          candidate['name'] as String,
      ];
      expect(names, contains('icus_day_time'),
          reason: 'the alias hint points at the instructing columns');
      expect(names, everyElement(isIn(liveFlightColumns())),
          reason: 'only live writable columns are ever offered');
      expect('${instr['message']}', contains('icus_day_time'));
      final remarks = issues.firstWhere((issue) => issue['field'] == 'REMARKS');
      expect([
        for (final candidate in remarks['candidates'] as List)
          candidate['name'] as String,
      ], contains('custom_columns'));
    });
  });

  group('apply_flight_batch in import mode', () {
    test('duplicates are reported both ways and skipped on apply', () async {
      insert(
        "INSERT INTO flights (id, date, route, aircraft_registration, "
        "total_time, created_at) VALUES ('fl-existing', ?, 'YSSY - NZQN', "
        "'VH-XZO', 90, 1700000000)",
        [dateToEpoch('2026-12-02')],
      );
      final server = await start();
      final rows = [
        {
          'client_ref': 'imp-1',
          'date': '2026-12-01',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'total_time': 90,
        },
        {
          'client_ref': 'imp-2',
          'date': '2026-12-01',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'total_time': 90,
        },
        {
          'client_ref': 'imp-3',
          'date': '2026-12-02',
          'route': 'YSSY - NZQN',
          'aircraft_registration': 'VH-XZO',
          'total_time': 90,
        },
      ];

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': rows,
      }));
      expect(codesAt(report, 0), isEmpty);
      final batch = issuesAt(report, 1).single;
      expect(batch['code'], 'duplicate_batch');
      expect(batch['severity'], 'warning');
      expect('${batch['message']}', contains('row 0'),
          reason: 'the earlier row is named by index');
      final existing = issuesAt(report, 2).single;
      expect(existing['code'], 'duplicate_existing');
      expect(existing['severity'], 'warning');
      expect('${existing['message']}', contains('fl-existing'),
          reason: 'the existing row is named by id');

      final applied = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'flights': rows,
      }));
      expect(applied['applied'], 1);
      final skipped = (applied['skipped'] as List).cast<Map<String, dynamic>>();
      expect([for (final entry in skipped) entry['code']],
          ['duplicate_batch', 'duplicate_existing']);
      expect(skipped.first['index'], 1);
      expect('${skipped.first['reason']}', contains('row 0'));
      expect(skipped[1]['index'], 2);
      expect('${skipped[1]['reason']}', contains('fl-existing'));
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT total_time FROM flights WHERE id = ?',
                  ['fl-existing']).single)['total_time'],
          90,
          reason: 'the existing row is untouched');
    });

    test('is atomic: one bad row writes nothing and is named', () async {
      final before = flightCount();
      final server = await start();

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN', 'total_time': 90},
          {
            'date': '2026-11-02',
            'route': 'YBBN - YSSY',
            'crew_role': 'captain',
            'total_time': 90,
          },
        ],
      }));

      expect(result['applied'], 0);
      expect(result['created'], isEmpty);
      final failed = (result['failed'] as List).cast<Map<String, dynamic>>();
      expect(failed.single['index'], 1);
      expect('${failed.single['reason']}', contains('crew_role'));
      expect(flightCount(), before,
          reason: 'one bad row rolls the whole batch back');
    });

    test('allow_partial lands the clean rows and reports the rest', () async {
      final before = flightCount();
      final server = await start();

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'allow_partial': true,
        'flights': [
          {
            'client_ref': 'imp-1',
            'date': '2026-11-02',
            'route': 'YSSY - NZQN',
            'total_time': 90,
          },
          {
            'client_ref': 'imp-2',
            'date': '2026-11-02',
            'route': 'YBBN - YSSY',
            'crew_role': 'captain',
            'total_time': 90,
          },
        ],
      }));

      expect(result['applied'], 1);
      expect((result['created'] as List), hasLength(1));
      expect(result['created_refs'], ['imp-1']);
      final failed = (result['failed'] as List).cast<Map<String, dynamic>>();
      expect(failed.single['index'], 1);
      expect('${failed.single['reason']}', contains('crew_role'));
      expect(flightCount(), before + 1);
    });

    test('500 rows land in one transaction with one audit entry', () async {
      final before = flightCount();
      final server = await start();
      final rows = [
        for (var i = 0; i < 500; i++)
          {
            'client_ref': 'imp-${i + 1}',
            // Field arithmetic, not Duration: +24h across a DST change lands
            // on the same calendar date twice, and 500 rows must be 500
            // different days.
            'date': formatCalendarDate(DateTime(2025, 1, 1 + i)),
            'route': 'YSSY - NZQN',
            'aircraft_registration': 'VH-XZO',
            'total_time': 90,
          },
      ];

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'batch_id': 'batch-500',
        'flights': rows,
      }));

      expect(result['applied'], 500);
      expect((result['created'] as List), hasLength(500));
      expect(result['failed'], isEmpty);
      expect(result['skipped'], isEmpty);
      expect(flightCount(), before + 500);

      // The batch audit entry: read back through readAudit from the file
      // auditPathFor names, one entry per call rather than per row, carrying
      // the batch id and the ids it created.
      expect(File(auditPathFor(dbPath)).existsSync(), isTrue);
      final entries = [
        for (final entry in readAudit(dbPath))
          if (entry['tool'] == 'apply_flight_batch') entry,
      ];
      expect(entries, hasLength(1),
          reason: 'one entry per batch, not one per row');
      final entry = entries.single;
      expect(entry['result'], 'ok');
      expect((entry['args'] as Map)['batch_id'], 'batch-500');
      expect(entry['ids'], result['created']);
      expect((entry['created_refs'] as List), hasLength(500));
    });

    test('would_create_draft warns, and writes as a draft when confirmed',
        () async {
      final server = await start();

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'import',
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN', 'total_time': 90},
          {'date': '2026-11-03', 'route': 'YSSY - NZQN'},
          {'date': '2026-11-04', 'route': 'YSSY - NZQN', 'draft': true},
        ],
      }));

      expect(codesAt(report, 0), isEmpty);
      final warning = issuesAt(report, 1).single;
      expect(warning['code'], 'would_create_draft');
      expect(warning['severity'], 'warning');
      expect(rowAt(report, 1)['ok'], isTrue,
          reason: 'a warning does not block the write');
      expect('${warning['message']}',
          contains('confirm the source has no total for it'));
      expect(codesAt(report, 2), isEmpty,
          reason: 'an explicit draft is intended, so there is nothing to '
              'confirm');

      final applied = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'mode': 'import',
        'flights': [
          {'date': '2026-11-03', 'route': 'YSSY - NZQN'},
        ],
      }));
      expect(applied['applied'], 1,
          reason: 'confirmed: the genuine gap lands as a draft');
      expect(
          withFixtureDb(
              dbPath,
              (db) => db.select('SELECT total_time FROM flights WHERE id = ?',
                  [(applied['created'] as List).single]).single['total_time']),
          isNull);
    });
  });

  group('the import contract', () {
    test('the falcon://import column table is the live writable columns',
        () async {
      final server = await start();
      final text = await resourceText(server, 'falcon://import');
      final names = columnTableNames(text);
      final live = liveFlightColumns();
      final expected = [
        for (final name in writableSpec)
          if (live.contains(name)) name,
      ];

      expect(names.toSet(), expected.toSet(),
          reason: 'the table is db.columnsOf("flights") intersected with the '
              'writable spec, so it never names a column this build cannot '
              'write');
      expect(names, hasLength(expected.length));
      expect(text, isNot(contains('scheduled_departure_utc')),
          reason: 'this database cannot store planned times, so they are '
              'never named');
      for (final line in text.split('\n')) {
        if (!line.startsWith('- ')) continue;
        expect(RegExp(r'^- \S+ \([^)]+\): .+').hasMatch(line), isTrue,
            reason: 'one "- name (kind): note" line per column: $line');
      }
    });

    test('the column table follows the live database at read time', () async {
      insert(
          'ALTER TABLE flights ADD COLUMN scheduled_departure_utc INTEGER NULL');
      insert(
          'ALTER TABLE flights ADD COLUMN scheduled_arrival_utc INTEGER NULL');
      insert(
          'ALTER TABLE flights ADD COLUMN scheduled_block_minutes INTEGER NULL');
      final server = await start();

      final names =
          columnTableNames(await resourceText(server, 'falcon://import'));
      final live = liveFlightColumns();
      expect(names.toSet(), {
        for (final name in writableSpec)
          if (live.contains(name)) name,
      });
      expect(names, contains('scheduled_departure_utc'),
          reason: 'a migrated database stores planned times, so the table '
              'offers them');
    });

    test(
        'the prompt points at the resource, and the resource carries the '
        'rules', () async {
      final server = await start();

      final prompt = await promptText(server, 'logbook_import_guide');
      expect(prompt, contains('falcon://import'));
      expect(prompt, contains('ask_user'));
      expect(prompt, contains('mode: "import"'));
      expect(prompt, contains('validate_flight_drafts'));
      expect(prompt, contains('apply_flight_batch'));
      expect(prompt, contains('dry_run: false'));
      expect(prompt, isNot(contains('\u2014')));

      final text = await resourceText(server, 'falcon://import');
      for (final statement in [
        'QUESTIONS: ASK, DO NOT ASSUME',
        'ask_user',
        'source column -> Falcon column',
        'THREE sample rows',
        'explicit yes',
        'never blind-import',
        'unknown_column',
        'get_schema',
        'YYYY-MM-DD',
        'serial',
        'decimal_hours',
        'hhmm',
        'mixed units',
        'list_aircraft',
        'FALCON_TZ',
        'client_ref',
        'batch_id',
        'updated_at',
        'PARTIAL FAILURE IS LOUD',
        'COLUMN TABLE: FLIGHT COLUMNS THIS BUILD CAN WRITE',
      ]) {
        expect(text, contains(statement),
            reason: 'falcon://import must carry "$statement"');
      }
      expect(text, isNot(contains('\u2014')), reason: 'no em dashes');
    });

    test('a mode or units this server does not know is refused by name',
        () async {
      final server = await start();

      // Like every schema enum (period, the limit caps), the SDK refuses
      // before the callback runs, and the refusal names the tool and the
      // argument at fault.
      final mode = await server.call('validate_flight_drafts', {
        'mode': 'improt',
        'flights': <Map<String, dynamic>>[],
      });
      expect(mode.isError, isTrue);
      expect('${mode.payload}', contains('validate_flight_drafts'));
      expect('${mode.payload}', contains('mode'));

      final units = await server.call('apply_flight_batch', {
        'units': 'hours',
        'flights': <Map<String, dynamic>>[],
      });
      expect(units.isError, isTrue);
      expect('${units.payload}', contains('apply_flight_batch'));
      expect('${units.payload}', contains('units'));
    });
  });

  group('roster mode is unchanged', () {
    test('the default mode is roster and pays none of the import rules',
        () async {
      final server = await start();

      // The same serial date and odd cells the import rules name precisely
      // are plain refusals here, and the row keys are unknown_field rather
      // than unknown_column.
      final report = payloadOf(await server.call('validate_flight_drafts', {
        'flights': [
          {'date': 45290, 'route': 'YSSY - NZQN', 'draft': true},
        ],
      }));
      expect(codesAt(report, 0), contains('invalid_row'));
      expect(codesAt(report, 0), isNot(contains('serial_date')));

      final explicit = payloadOf(await server.call('validate_flight_drafts', {
        'mode': 'roster',
        'flights': [
          {'date': 45290, 'route': 'YSSY - NZQN', 'draft': true},
        ],
      }));
      expect(codesAt(explicit, 0), codesAt(report, 0),
          reason: 'mode: roster is what leaving mode out means');

      final unknown = payloadOf(await server.call('validate_flight_drafts', {
        'flights': [
          {'date': '2026-11-02', 'INSTR': '12:30', 'draft': true},
        ],
      }));
      expect(codesAt(unknown, 0), contains('unknown_field'));
      expect(codesAt(unknown, 0), isNot(contains('unknown_column')));

      // The roster draft rule is unchanged: no total and no draft flag is a
      // plain draft, with no would_create_draft warning.
      final draft = payloadOf(await server.call('validate_flight_drafts', {
        'flights': [
          {'date': '2026-11-02', 'route': 'YSSY - NZQN'},
        ],
      }));
      expect(codesAt(draft, 0), isEmpty);
      expect(rowAt(draft, 0).containsKey('warnings'), isFalse);
    });

    test('a clean roster validates exactly as it always has', () async {
      final server = await start();
      final routes = [
        'YSSY - NZQN',
        'YBBN - YSSY',
        'YSSY - YBBN',
        'NZQN - YSSY',
      ];
      final roster = [
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

      final report = payloadOf(await server.call('validate_flight_drafts', {
        'flights': roster,
        'date_from': '2026-11-02',
        'date_to': '2026-11-06',
      }));

      expect(report['valid'], 20);
      expect(report['invalid'], 0);
      expect(report['range'], {'from': '2026-11-02', 'to': '2026-11-06'});
      for (final row in (report['rows'] as List).cast<Map<String, dynamic>>()) {
        expect(row['ok'], isTrue, reason: 'row ${row['index']}');
        expect(row['issues'], isEmpty, reason: 'row ${row['index']}');
        expect(row.containsKey('warnings'), isFalse,
            reason: 'row ${row['index']} has nothing to warn about');
      }
    });
  });
}
