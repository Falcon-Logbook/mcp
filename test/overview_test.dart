import 'dart:convert';
import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #7, the first-run slice: one small payload of the pilot's own numbers,
/// and a help prompt generated from the tools this connection actually carries.
///
/// Every number here is compared with the tool that already computes it, because
/// an overview that disagrees with `logbook_stats` is worse than no overview: the
/// pilot sees two answers to one question. Sizes are measured on the wire in
/// bytes, with a token read as roughly four bytes, so 1,600 B is under 400
/// tokens and 2,400 B is under 600: the budgets the issue sets for the two
/// artifacts.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_overview_test');
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

  /// A logbook with no rows at all, on its own file.
  Future<McpProcess> startEmpty() async {
    final path = createEmptyFixture('${tempDir.path}/fresh.sqlite');
    final server = await McpProcess.start(path);
    addTearDown(() async {
      await server.stop();
    });
    return server;
  }

  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) =>
      result.payload as Map<String, dynamic>;

  /// Local midnight [days] ago: the flight date form the fixture writes.
  DateTime dayOffset(int days) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day - days);
  }

  /// Local midnight [days] from today, for the future-facing fixtures.
  DateTime dayAhead(int days) => dayOffset(-days);

  int epochOf(DateTime day) => epochForDayStart(day);

  Future<Map<String, dynamic>> overview(McpProcess server,
          [Map<String, dynamic> args = const {}]) async =>
      payloadOf(await server.call('logbook_overview', args));

  /// The text of a registered prompt, and the tool names a catalog lists.
  Future<String> promptText(McpProcess server, String name) async {
    final response = await server.send('prompts/get', {'name': name});
    final messages = (response['result'] as Map)['messages'] as List;
    return ((messages.single as Map)['content'] as Map)['text'] as String;
  }

  Future<List<Map<String, dynamic>>> catalog(McpProcess server) async {
    final response = await server.send('tools/list', {});
    return ((response['result'] as Map)['tools'] as List)
        .cast<Map<String, dynamic>>();
  }

  int bytesOf(Object? value) =>
      utf8.encode(value is String ? value : jsonEncode(value)).length;

  /// The capability groups a help prompt lists: their headlines and the example
  /// questions under each. The rules section below them is not a group.
  ({List<String> headlines, Map<String, List<String>> questions}) groupsOf(
      String help) {
    final body =
        help.split('What the pilot can ask for:').last.split('Rules:').first;
    final headlines = <String>[];
    final questions = <String, List<String>>{};
    for (final line in body.split('\n')) {
      if (line.startsWith('- ')) {
        final headline = line.substring(2).trim();
        headlines.add(headline);
        questions[headline] = <String>[];
      } else if (line.startsWith('  "') && headlines.isNotEmpty) {
        questions[headlines.last]!.add(line.trim());
      }
    }
    return (headlines: headlines, questions: questions);
  }

  /// A logbook with recent flights, an aircraft, a draft, expiries due soon, a
  /// currency rule that needs attention, and a row owned by another device.
  void seedLogbook() {
    insertFlights(dbPath, [
      // Today, 60 minutes, all day.
      {
        'id': 'fl-today',
        'date': dayOffset(0),
        'aircraft_id': 'ac-1',
        'aircraft_registration': 'VH-XZO',
        'route': 'YSSY - YSBK',
        'total_time': 60,
        'day_time': 60,
        'night_time': 0,
        'takeoffs': 1,
        'landings': 1,
      },
      // Ten days ago, 90 minutes with 20 of it at night.
      {
        'id': 'fl-ten',
        'date': dayOffset(10),
        'aircraft_id': 'ac-1',
        'aircraft_registration': 'VH-XZO',
        'route': 'YSBK - YSSY',
        'total_time': 90,
        'day_time': 70,
        'night_time': 20,
        'takeoffs': 1,
        'landings': 1,
      },
      // Inside the year, outside the default window.
      {
        'id': 'fl-old',
        'date': dayOffset(100),
        'aircraft_id': 'ac-1',
        'aircraft_registration': 'VH-XZO',
        'total_time': 30,
        'day_time': 30,
        'night_time': 0,
      },
      // Another device's row: never in any of these numbers.
      {
        'id': 'fl-other',
        'date': dayOffset(0),
        'aircraft_id': 'ac-other',
        'aircraft_registration': 'VH-OTH',
        'total_time': 999,
        'day_time': 999,
        'night_time': 0,
        'owner_id': 'other',
      },
    ]);
    withFixtureDb(dbPath, (db) {
      db.execute(
        "INSERT INTO aircraft (id, type, country_code, registration, created_at, owner_id) "
        "VALUES ('ac-other', 'B789', 'VH', 'OTH', 1700000000, 'other')",
      );
      // One document due in three weeks, one overdue, one too far away to
      // matter.
      for (final (id, name, days) in [
        ('ex-1', 'Class 1 Medical', 21),
        ('ex-2', 'Instrument Rating', -3),
        ('ex-3', 'ASIC', 400),
      ]) {
        db.execute(
          'INSERT INTO expiries (id, name, due_date, created_at) '
          'VALUES (?, ?, ?, 1700000000)',
          [id, name, epochOf(dayAhead(days))],
        );
      }
      db.execute(
        'INSERT INTO user_currency (id, title, metric, period, threshold, '
        "sort_order, type, created_at) VALUES ('cur-1', 'Night pax', "
        "'nightTime', 'rolling365', 90.0, 0, 'requirement', 1700000000)",
      );
    });
  }

  test('the payload agrees with the tools it is composed from', () async {
    seedLogbook();
    final server = await start();

    final payload = await overview(server);
    final stats = payloadOf(await server.call('logbook_stats', {}));
    final totals =
        payloadOf(await server.call('entity_totals', {'type': 'type'}));
    final fleet = payloadOf(await server.call('list_aircraft', {}));
    final recent = payloadOf(
        await server.call('list_flights', {'period': 'last_90_days'}));

    // The shape of the issue, in order, with no flight rows anywhere.
    expect(payload.keys.toList(), [
      'flights',
      'hours',
      'drafts',
      'recent',
      'fleet',
      'recent_activity',
      'attention',
      'logbook',
    ]);
    expect((payload['recent'] as Map).keys.toList(),
        ['days', 'flights', 'hours', 'night_hours']);
    expect((payload['attention'] as Map).keys.toList(), [
      'drafts',
      'expiries_due_soon',
      'currency_failing',
      'unlinked_flights',
    ]);

    // Every total is the number the tool that owns it reports. Five local rows:
    // the fixture's two and three seeded ones, never the other device's.
    expect(payload['flights'], stats['flights']);
    expect(payload['flights'], 5);
    expect(payload['drafts'], stats['drafts']);
    expect(payload['drafts'], 1);
    expect((payload['hours'] as double) * 60,
        closeTo(stats['total_minutes'] as int, 6),
        reason: 'hours is the same sum, to one decimal');
    expect((payload['recent'] as Map)['flights'], recent['total']);
    expect((payload['recent'] as Map)['flights'], 2);
    expect((payload['recent'] as Map)['days'], 90);

    final top = (totals['entities'] as List).single as Map;
    expect((payload['fleet'] as Map)['top_type'], top['aircraft_type']);
    expect((payload['fleet'] as Map)['top_type_hours'] as double, isPositive);
    expect(((payload['fleet'] as Map)['top_type_hours'] as double) * 60,
        closeTo(top['minutes'] as int, 6));
    expect((payload['fleet'] as Map)['aircraft'], fleet['total'],
        reason: 'the fleet is what list_aircraft counts');
    expect((payload['fleet'] as Map)['aircraft'], 1);

    // The last flight is the pilot's own, and the other device's row is not it.
    expect((payload['recent_activity'] as Map)['last_flight_date'],
        formatCalendarDate(dayOffset(0)));
    expect((payload['recent_activity'] as Map)['days_since_last_flight'], 0);
    expect((payload['attention'] as Map)['unlinked_flights'], 1,
        reason: 'the fixture draft carries no aircraft link');

    // The pilot, and never the database path: an answer gets screenshotted.
    final logbook = payload['logbook'] as Map;
    expect(logbook['pilot_name'], 'Self');
    expect(logbook['schema_version'], 19);
    expect(logbook['readonly'], isTrue);
    expect(logbook.containsKey('country'), isFalse,
        reason:
            'no country is set, so the key is left out rather than blanked');
    expect(jsonEncode(payload), isNot(contains(dbPath)));
    expect(jsonEncode(payload), isNot(contains('.sqlite')));
  });

  test('attention carries only what needs work, in the shape of the issue',
      () async {
    seedLogbook();
    final server = await start();

    final attention = (await overview(server))['attention'] as Map;
    final soon =
        (attention['expiries_due_soon'] as List).cast<Map<String, dynamic>>();

    // Soonest first, overdue included, the far-away document left out.
    expect(soon.map((row) => row['name']),
        ['Instrument Rating', 'Class 1 Medical']);
    expect(soon.map((row) => row['days_remaining']), [-3, 21]);
    expect(soon.first['due_date'], formatCalendarDate(dayAhead(-3)));
    for (final row in soon) {
      expect(row.keys.toList(), ['name', 'due_date', 'days_remaining'],
          reason: 'the list is the evidence, not a second list_expiries');
    }

    // The same day counts and dates list_expiries reports.
    final expiries =
        payloadOf(await server.call('list_expiries', {'include_past': true}));
    for (final row in soon) {
      final match = (expiries['expiries'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((other) => other['name'] == row['name']);
      expect(match['days_remaining'], row['days_remaining'],
          reason: '${row['name']} is the same day count as list_expiries');
      expect(match['due_date'], row['due_date']);
    }

    // A failing rule is reported the way the issue shapes it, with the numbers
    // currency_status computed.
    final failing =
        (attention['currency_failing'] as List).cast<Map<String, dynamic>>();
    final rules = payloadOf(await server.call('currency_status', {}));
    final rule = (rules['rules'] as List).single as Map;
    expect(rule['is_exceeded'], isTrue);
    expect(failing.single.keys.toList(),
        ['title', 'period', 'current', 'threshold']);
    expect(failing.single['title'], 'Night pax');
    expect(failing.single['period'], 'rolling365');
    expect(failing.single['current'], rule['current']);
    expect(failing.single['threshold'], rule['threshold']);
  });

  test('attention is capped, so a messy logbook stays a small payload',
      () async {
    seedLogbook();
    withFixtureDb(dbPath, (db) {
      for (var i = 0; i < 6; i++) {
        db.execute(
          'INSERT INTO expiries (id, name, due_date, created_at) '
          'VALUES (?, ?, ?, 1700000000)',
          ['ex-more-$i', 'Document $i', epochOf(dayAhead(30 + i))],
        );
        db.execute(
          'INSERT INTO user_currency (id, title, metric, period, threshold, '
          "sort_order, type, created_at) VALUES (?, ?, 'totalTime', "
          "'rolling30', 500.0, 1, 'requirement', 1700000000)",
          ['cur-more-$i', 'Rule $i'],
        );
      }
    });
    final server = await start();

    final attention = (await overview(server))['attention'] as Map;
    expect(attention['expiries_due_soon'] as List, hasLength(3));
    expect(attention['currency_failing'] as List, hasLength(3));
  });

  test('the recent window is the days asked for, and only the window moves',
      () async {
    seedLogbook();
    final server = await start();

    final week = await overview(server, {'days': 7});
    expect((week['recent'] as Map)['days'], 7);
    expect((week['recent'] as Map)['flights'], 1,
        reason: 'today only: the ten-day-old flight is outside the window');
    expect((week['recent'] as Map)['hours'], 1.0);

    final month = await overview(server, {'days': 30});
    expect((month['recent'] as Map)['days'], 30);
    expect((month['recent'] as Map)['flights'], 2);
    expect((month['recent'] as Map)['hours'], 2.5);
    expect((month['recent'] as Map)['night_hours'] as double,
        closeTo(20 / 60, 0.05),
        reason: 'night minutes as one decimal of an hour');

    // The whole-logbook numbers do not move with the window.
    expect(month['flights'], week['flights']);
    expect(month['hours'], week['hours']);
    expect(month['recent_activity'], week['recent_activity']);
  });

  test('a table that is not there leaves its key out rather than zeroing it',
      () async {
    seedLogbook();
    withFixtureDb(dbPath, (db) {
      db.execute('DROP TABLE expiries');
      db.execute('DROP TABLE user_currency');
    });
    final server = await start();

    final attention = (await overview(server))['attention'] as Map;
    expect(attention.containsKey('expiries_due_soon'), isFalse);
    expect(attention.containsKey('currency_failing'), isFalse);
    expect(attention['drafts'], 1);
    expect(attention['unlinked_flights'], 1);

    // Nothing due and no rules configured is the same honest silence: an empty
    // table is where a fresh logbook starts.
    final empty = (await overview(await startEmpty()))['attention'] as Map;
    expect(empty.containsKey('expiries_due_soon'), isFalse);
    expect(empty.containsKey('currency_failing'), isFalse);
  });

  test('another device\'s rows never reach the numbers', () async {
    insertFlights(dbPath, [
      {
        'id': 'fl-local',
        'date': dayOffset(0),
        'total_time': 60,
        'day_time': 60,
        'owner_id': 'local',
      },
      {
        'id': 'fl-other',
        'date': dayOffset(0),
        'total_time': 600,
        'day_time': 600,
        'owner_id': 'other',
      },
    ]);
    final server = await start();

    final payload = await overview(server);
    final stats = payloadOf(await server.call('logbook_stats', {}));

    expect(payload['flights'], stats['flights']);
    // The fixture's two rows plus the local one: the other device's row and its
    // 600 minutes are not here.
    expect(payload['flights'], 3);
    expect(payload['hours'], 3.0);
    expect((payload['recent'] as Map)['flights'], 1,
        reason: 'the fixture rows are a year old, so today holds the local '
            'flight alone, not the 600 minute row');
  });

  test('an empty logbook answers sanely instead of failing', () async {
    final server = await startEmpty();

    final payload = await overview(server);
    expect(payload['flights'], 0);
    expect(payload['hours'], 0.0);
    expect(payload['drafts'], 0);
    expect(payload['recent'],
        {'days': 90, 'flights': 0, 'hours': 0.0, 'night_hours': 0.0});
    expect(payload.containsKey('fleet'), isFalse);
    expect(payload.containsKey('recent_activity'), isFalse);
    expect(payload['attention'], {'drafts': 0, 'unlinked_flights': 0});
    final logbook = payload['logbook'] as Map;
    expect(logbook['schema_version'], 19);
    expect(logbook['readonly'], isTrue);
    expect(logbook.containsKey('pilot_name'), isFalse,
        reason: 'a fresh database has no settings row, and a name is not '
            'invented for it');
    expect(bytesOf(payload), lessThan(400));
  });

  test('a misspelled argument is refused by name', () async {
    final server = await start();
    final result = await server.call('logbook_overview', {'day': 30});
    expect(result.isError, isTrue);
    expect('${result.payload}', contains('day'));
    expect('${result.payload}', contains('logbook_overview'));
  });

  test('the overview stays under 400 tokens on a 1000 flight logbook',
      () async {
    withFixtureDb(dbPath, (db) {
      db.execute('BEGIN');
      for (var i = 0; i < 1000; i++) {
        db.execute(
          'INSERT INTO flights (id, date, aircraft_id, aircraft_registration, '
          'route, total_time, day_time, night_time, takeoffs, landings, '
          'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1, 1700000000)',
          [
            'fl-bulk-$i',
            epochOf(dayOffset(i % 700)),
            'ac-1',
            'VH-XZO',
            'YSSY - YBBN',
            120 + i,
            90,
            30 + i,
          ],
        );
      }
      db.execute('COMMIT');
    });
    final server = await start();

    final payload = await overview(server);
    expect(payload['flights'], 1002);
    // Bytes are the proxy for tokens: about four bytes to one, so 1,600 B is
    // under 400 tokens even with that rule being generous.
    expect(
      bytesOf(payload),
      lessThan(1600),
      reason: 'the overview costs ${bytesOf(payload)} B on a 1000 flight '
          'logbook: it does not grow with the rows',
    );
  });

  test('falcon_help lists at most seven groups of two questions', () async {
    seedLogbook();
    for (final write in [false, true]) {
      final server = await start(write: write);
      final groups = groupsOf(await promptText(server, 'falcon_help'));

      expect(groups.headlines, isNotEmpty, reason: 'write: $write');
      expect(groups.headlines.length, lessThanOrEqualTo(7),
          reason: 'write: $write');
      for (final headline in groups.headlines) {
        final questions = groups.questions[headline]!;
        expect(questions, hasLength(2),
            reason: '$headline carries two example questions');
        for (final question in questions) {
          expect(question, startsWith('"'));
          expect(question, anyOf(endsWith('?"'), endsWith('."')),
              reason: '$question reads as a question');
        }
      }
      expect(groups.headlines.toSet(), hasLength(groups.headlines.length),
          reason: 'a group is printed once');
    }
  });

  test('falcon_help advertises only what this mode registered', () async {
    final reader = await start();
    final writer = await start(write: true);

    final readTools = await reader.toolNames();
    final allTools = await writer.toolNames();
    final writeOnly = [
      for (final tool in allTools)
        if (!readTools.contains(tool)) tool,
    ];
    expect(writeOnly, isNotEmpty,
        reason: 'the write tools are registered only with writes on');

    // Read-only: no write tool named, no write claimed, and every tool named is
    // registered.
    final readHelp = await promptText(reader, 'falcon_help');
    for (final tool in writeOnly) {
      expect(readHelp, isNot(contains(tool)),
          reason: 'read-only mode advertises $tool');
    }
    expect(readHelp, isNot(contains('Writes are on')));
    for (final tool in allTools) {
      if (readHelp.contains(tool)) {
        expect(readTools, contains(tool),
            reason: '$tool is named in read-only mode but not registered');
      }
    }

    // The mode's own catalog says the same: nothing in read-only mode writes.
    for (final tool in await catalog(reader)) {
      final annotations = tool['annotations'] as Map?;
      expect(annotations?['readOnlyHint'], isTrue,
          reason: '${tool['name']} writes but is advertised in read-only mode');
    }

    // Write mode: the write groups appear, and nothing named is unregistered.
    final writeHelp = await promptText(writer, 'falcon_help');
    expect(writeHelp, contains('Writes are on'));
    expect(groupsOf(writeHelp).headlines.length,
        greaterThan(groupsOf(readHelp).headlines.length));
    for (final tool in allTools) {
      if (writeHelp.contains(tool)) {
        expect(allTools, contains(tool));
      }
    }
  });

  test('falcon_help stays under 600 tokens, and the prompts are registered',
      () async {
    final reader = await start();
    final writer = await start(write: true);

    for (final server in [reader, writer]) {
      final help = await promptText(server, 'falcon_help');
      expect(bytesOf(help), lessThan(2400),
          reason: 'falcon_help costs ${bytesOf(help)} B, about '
              '${(bytesOf(help) / 4).ceil()} tokens');
    }
    // Read-only is the mode a fresh install runs in, and the mode the shaping
    // test already measures.
    expect(bytesOf(await promptText(reader, 'falcon_help')), lessThan(1500));

    final listed = await reader.send('prompts/list', {});
    final names = [
      for (final prompt in ((listed['result'] as Map)['prompts'] as List))
        (prompt as Map)['name'] as String,
    ];
    expect(
        names,
        containsAll([
          'falcon_help',
          'what_can_you_do',
          'logbook_review',
          'currency_check'
        ]));

    // The three new prompts reference the tools they need, and stay short
    // enough that a client can show them as a command.
    for (final (name, tool) in [
      ('what_can_you_do', 'logbook_overview'),
      ('logbook_review', 'currency_status'),
      ('currency_check', 'currency_status'),
    ]) {
      final text = await promptText(reader, name);
      expect(text, contains(tool), reason: name);
      expect(bytesOf(text), lessThan(1400), reason: '$name is short');
      expect(text, isNot(contains('—')), reason: '$name uses no em dash');
    }
  });
}
