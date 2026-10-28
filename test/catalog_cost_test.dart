import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #11, second slice: the catalog and the responses a mistake produces.
///
/// Four artifacts, each measured on the wire rather than estimated: a
/// names-only schema by default, one copy of the flight field notes, a
/// projected log read, and an error envelope small enough to act on. Every
/// declared default and maximum is read back out of the catalog an agent
/// receives and compared with what the server actually does, because this
/// repository once shipped a schema that promised 20 rows and returned 200.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_catalog_test');
    dbPath = createEmptyFixture('${tempDir.path}/falcon_db.sqlite');
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
      result.payload as Map<String, dynamic>;

  /// The catalog an agent receives, as a name to tool map.
  Future<Map<String, Map<String, dynamic>>> catalog(McpProcess server) async {
    final response = await server.send('tools/list', {});
    final tools = ((response['result'] as Map)['tools'] as List)
        .cast<Map<String, dynamic>>();
    return {for (final tool in tools) tool['name'] as String: tool};
  }

  /// The `limit` schema of [tool], as declared, plus the default and maximum its
  /// description states.
  ({int byDefault, int atMost, Map<String, dynamic> schema}) declaredLimit(
      Map<String, Map<String, dynamic>> tools, String tool) {
    final properties =
        (tools[tool]!['inputSchema'] as Map)['properties'] as Map;
    final schema = (properties['limit'] as Map).cast<String, dynamic>();
    final match = RegExp(r'Default (\d+), maximum (\d+)\.')
        .firstMatch('${schema['description']}');
    if (match == null) {
      throw StateError(
          '$tool does not declare its limit: ${schema['description']}');
    }
    return (
      byDefault: int.parse(match.group(1)!),
      atMost: int.parse(match.group(2)!),
      schema: schema,
    );
  }

  /// The error envelope a failed call returns, decoded. A tool error carries the
  /// same compact JSON a success does, so a caller parses one shape.
  Map<String, dynamic> errorOf(({bool isError, Object? payload}) result) {
    expect(result.isError, isTrue,
        reason: 'expected a refusal: ${result.payload}');
    return jsonDecode(result.payload as String) as Map<String, dynamic>;
  }

  Future<String> textOf(
      McpProcess server, String tool, Map<String, dynamic> args) async {
    final response =
        await server.send('tools/call', {'name': tool, 'arguments': args});
    final content = ((response['result'] as Map)['content'] as List)
        .cast<Map<String, dynamic>>();
    return content.first['text'] as String;
  }

  Future<String> resourceText(McpProcess server, String uri) async {
    final response = await server.send('resources/read', {'uri': uri});
    return (((response['result'] as Map)['contents'] as List).single
        as Map)['text'] as String;
  }

  int bytesOf(String text) => utf8.encode(text).length;

  /// Runs [body] while a second connection holds `BEGIN EXCLUSIVE` on the
  /// fixture, the way the desktop app holds the file while it writes: until
  /// [body] ends, every statement the server attempts waits out its busy
  /// timeout and then fails with SQLITE_BUSY. Start the server first, because
  /// it reads the schema version when it opens the file.
  Future<void> whileLocked(Future<void> Function() body) async {
    final lock = sqlite.sqlite3.open(dbPath);
    lock.execute('BEGIN EXCLUSIVE');
    try {
      await body();
    } finally {
      lock.execute('ROLLBACK');
      lock.dispose();
    }
  }

  group('get_schema', () {
    test('names and column counts by default, one table on request', () async {
      final server = await start();
      final tools = await catalog(server);
      final schema = tools['get_schema']!;
      final properties = (schema['inputSchema'] as Map)['properties'] as Map;

      // The catalog says what the default is. Nothing here may promise columns
      // without a table, because the response will not carry them.
      expect('${schema['description']}', contains('column count'));
      expect(properties.keys, containsAll(['table', 'detail']));
      expect((schema['inputSchema'] as Map)['required'], isNull,
          reason: 'table is optional: falcon_help and falcon://conventions '
              'both instruct a zero-argument call');

      final defaultText = await textOf(server, 'get_schema', {});
      final defaultPayload = jsonDecode(defaultText) as Map;
      final tables =
          (defaultPayload['tables'] as List).cast<Map<String, dynamic>>();

      expect(defaultPayload.keys, ['tables']);
      expect(
          tables,
          hasLength(withFixtureDb(
              dbPath,
              (db) => db
                  .select("SELECT name FROM sqlite_master "
                      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                  .length)));
      for (final entry in tables) {
        expect(entry.keys.toSet(), {'name', 'columns'},
            reason: 'the default carries a name and a count, no columns');
      }
      expect(
        bytesOf(defaultText),
        lessThan(1024),
        reason: 'the names-only answer costs ${bytesOf(defaultText)} B',
      );

      // The count is the number of columns the same table lists on request: the
      // declaration and the behaviour come from one source and must agree.
      final flightsCount =
          (tables.firstWhere((table) => table['name'] == 'flights'))['columns'];
      final flights = payloadOf(await server.call('get_schema', {
        'table': 'flights',
      }));
      final columns = (flights['flights'] as List).cast<Map<String, dynamic>>();
      expect(columns, hasLength(flightsCount));
      for (final column in columns) {
        expect(column.keys.toSet(), {'name', 'type', 'notnull'});
      }
      expect(
        columns.map((column) => column['name']),
        containsAll(['date', 'aircraft_id', 'total_time', 'time_start']),
      );

      final full = payloadOf(await server.call('get_schema', {
        'table': 'flights',
        'detail': 'full',
      }));
      final fullColumns =
          (full['flights'] as List).cast<Map<String, dynamic>>();
      expect(fullColumns, hasLength(flightsCount),
          reason: 'detail adds fields, never rows');
      for (final column in fullColumns) {
        expect(
            column.keys.toSet(), {'name', 'type', 'notnull', 'default', 'pk'});
      }
      expect(
        fullColumns.firstWhere((column) => column['name'] == 'id')['pk'],
        1,
        reason: 'the primary-key flag is what detail: full adds',
      );
    });

    test('refuses detail without a table instead of dumping every column',
        () async {
      final server = await start();

      // The 33 KB answer used to be the default. It is not reachable at all now,
      // which is the point: an agent cannot ask for it by accident.
      final noTable =
          errorOf(await server.call('get_schema', {'detail': 'full'}));
      expect(noTable['error'], 'invalid_value');
      expect(noTable['field'], 'table');

      final bogusDetail = errorOf(await server
          .call('get_schema', {'table': 'flights', 'detail': 'all'}));
      expect(bogusDetail['error'], 'invalid_value');
      expect(bogusDetail['field'], 'detail');

      final missing =
          errorOf(await server.call('get_schema', {'table': 'nope'}));
      expect(missing['error'], 'not_found');
      expect(missing['field'], 'table');
    });

    test('the schema resource is the same names-only payload', () async {
      final server = await start();

      final resource = await resourceText(server, 'falcon://schema');
      expect(resource, await textOf(server, 'get_schema', {}),
          reason: 'a client may read the resource without asking; it must not '
              'cost more than the tool call it mirrors');
      expect(
        bytesOf(resource),
        lessThan(1024),
        reason: 'falcon://schema costs ${bytesOf(resource)} B',
      );
    });
  });

  group('flight write catalog', () {
    test('the field notes exist once, on create_flight only', () async {
      final server = await start(write: true);
      final tools = await catalog(server);
      final create =
          ((tools['create_flight']!['inputSchema'] as Map)['properties'] as Map)
              .cast<String, Map<String, dynamic>>();
      final update =
          ((tools['update_flight']!['inputSchema'] as Map)['properties'] as Map)
              .cast<String, Map<String, dynamic>>();

      expect(update.keys.toSet(), create.keys.toSet(),
          reason: 'both tools take the same fields; only one explains them');

      for (final name in create.keys) {
        final noted = create[name]!;
        final bare = update[name]!;
        expect(noted['type'], bare['type'], reason: '$name keeps its type');
        expect(bare['maximum'], noted['maximum'],
            reason: '$name keeps its limit where it has one');
        expect(bare['format'], noted['format'],
            reason: '$name keeps its format where it has one');
      }

      // Every column note is on create_flight and absent from update_flight.
      final noted = [
        for (final entry in create.entries)
          if (entry.value['description'] != null) entry.key,
      ];
      expect(noted, containsAll(['date', 'total_time', 'time_start', 'route']));
      expect(noted.length, greaterThan(15),
          reason: 'the notes are the canonical copy, not a handful');
      for (final name in noted) {
        expect('${update[name]}',
            isNot(contains(create[name]!['description'] as String)),
            reason: '$name repeats its note in update_flight');
      }
      for (final name in update.keys) {
        if (name == 'draft' || name == 'id') continue;
        expect(update[name]!['description'], isNull,
            reason: '$name carries no note on update_flight');
      }

      // The cap #15 relies on is in both schemas, so it survives the dedupe:
      // its refusal text is what the write tests name.
      for (final properties in [create, update]) {
        expect(properties['total_time']!['maximum'], 525600);
        expect(properties['takeoffs']!['maximum'], 10000);
      }
    });

    test('the catalogs stay inside their byte budgets', () async {
      final reader = await start();
      final writer = await start(write: true);

      // #8's expiry and currency reads add 2,702 B (`list_expiries` 1,295 and
      // `currency_status` 1,405, schemas included), taking this from 11,713 B
      // to 14,415 B. The bound was 15 KiB (15,360 B), 945 B of room, the same
      // figure response_shaping_test uses. #6 adds `ask_user` at 973 B for
      // 15,389 B, so the bound moves with it to 16 KiB (16,384 B): 995 B of
      // room, which is that same ~1 KB.
      final readOnly =
          bytesOf(jsonEncode((await reader.send('tools/list', {}))['result']));
      expect(readOnly, lessThan(16384),
          reason: 'the read-only catalog costs $readOnly B, '
              'and 16 KiB is 16,384 B');

      // Issue #11 sets 22 KiB here, measured when the two flight write schemas
      // were 5.9 KB together. Validation in #15 grew them to 7.3 KB by adding
      // the bounds, formats and draft rule that the write tests pin, so the
      // figure is out of reach without deleting typed properties or that text.
      // This is the reachable number: 27,254 B before the bound, about 800 B
      // under the pre-slice 28,063 B. #8's two read tools add the same 2,702 B
      // for 29,956 B, so the bound was 30 KiB (30,720 B): 764 B of room. #6's
      // `ask_user` adds its 973 B again, to 30,930 B, so the bound is 31 KiB
      // (31,744 B): 814 B of room, the same guard at 800 B instead of 764.
      final writeMode =
          bytesOf(jsonEncode((await writer.send('tools/list', {}))['result']));
      expect(writeMode, lessThan(31744),
          reason: 'the write-mode catalog costs $writeMode B, '
              'and 31 KiB is 31,744 B');
    });
  });

  group('get_recent_logs', () {
    /// Sixty entries, some with a message far longer than the projection and a
    /// stack trace large enough to dominate a response on its own.
    void seedLogs() {
      withFixtureDb(dbPath, (db) {
        for (var i = 0; i < 60; i++) {
          db.execute(
            'INSERT INTO log_entries (timestamp, category, level, message, '
            'details, stack_trace) VALUES (?, ?, ?, ?, ?, ?)',
            [
              1761408000 + i,
              i.isEven ? 'flight' : 'sync',
              i % 9 == 0 ? 'error' : 'info',
              i.isEven ? 'short entry $i' : 'long entry $i ${'x' * 3000}',
              'details $i',
              '#0      FalconDb.write (package:falcon/db.dart:1234:5)\n' * 400,
            ],
          );
        }
      });
    }

    test('returns the fields and page its catalog declares', () async {
      seedLogs();
      final server = await start();
      final declared = declaredLimit(await catalog(server), 'get_recent_logs');

      expect(declared.byDefault, 20);
      expect(declared.atMost, 200);
      expect(declared.schema['maximum'], declared.atMost,
          reason: 'the declared maximum is the one the schema enforces');

      final payload = payloadOf(await server.call('get_recent_logs', {}));
      final logs = (payload['logs'] as List).cast<Map<String, dynamic>>();
      expect(payload['count'], declared.byDefault,
          reason: 'the default page is the declared default');
      expect(logs, hasLength(declared.byDefault));
      expect(logs.first['timestamp'], isA<String>(),
          reason: 'timestamps are rendered as local ISO-8601 strings');
      for (final entry in logs) {
        expect(
            entry.keys.toSet(), {'timestamp', 'level', 'category', 'message'},
            reason: 'the projection is fixed, not the whole row; a stack trace '
                'is opt-in');
      }

      // At the declared maximum the page is the declared size, not more.
      final capped =
          payloadOf(await server.call('get_recent_logs', {'limit': 200}));
      expect(capped['count'], 60);

      // One past the maximum is refused before the callback runs.
      final tooMany = await server.call('get_recent_logs', {'limit': 201});
      expect(tooMany.isError, isTrue);
      expect('${tooMany.payload}', contains('200'));
    });

    test('a message is cut at 500 characters and says that it was cut',
        () async {
      seedLogs();
      final server = await start();

      final logs =
          (payloadOf(await server.call('get_recent_logs', {}))['logs'] as List)
              .cast<Map<String, dynamic>>();
      final long =
          logs.firstWhere((entry) => '${entry['message']}'.startsWith('long'));
      final message = long['message'] as String;
      expect(message.length, lessThanOrEqualTo(500));
      expect(message, endsWith('...'),
          reason: 'a truncated message must not read as the whole message');
      expect(long['details'], isNull,
          reason: 'details are not in the projection');
    });

    test('a stack trace is opt-in and cannot dominate the response', () async {
      seedLogs();
      final server = await start();

      final projected = await textOf(server, 'get_recent_logs', {});
      final declared = declaredLimit(await catalog(server), 'get_recent_logs');
      expect(projected.length, greaterThan(0));
      expect(
        bytesOf(projected),
        lessThan(8000),
        reason:
            '60 entries of 400-line traces default to ${bytesOf(projected)} B',
      );
      expect(projected, isNot(contains('FalconDb.write')));

      final withStack = payloadOf(
          await server.call('get_recent_logs', {'include_stack': true}));
      final entries = (withStack['logs'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(declared.byDefault));
      expect('${entries.first['stack_trace']}', contains('FalconDb.write'),
          reason: 'include_stack: true returns the trace it was asked for');
      expect(bytesOf(jsonEncode(withStack)), greaterThan(bytesOf(projected)),
          reason: 'the opt-in adds bytes rather than replacing the projection');
    });
  });

  group('error envelopes', () {
    test('a typo names the code, the field, the tool and what is accepted',
        () async {
      withFixtureDb(dbPath, (db) {
        db.execute(
          "INSERT INTO flights (id, date, created_at) VALUES ('fl-1', 1761408000, 1700000000)",
        );
      });
      final server = await start(write: true);

      final result = await server.call('update_flight', {
        'id': 'fl-1',
        'block_off': 10,
      });
      final envelope = errorOf(result);

      expect(envelope['error'], 'unknown_field');
      expect(envelope['field'], 'block_off');
      expect(envelope['tool'], 'update_flight',
          reason: 'an agent that called three tools needs to know which '
              'refused');
      expect(envelope['detail'], isA<String>());

      // The accepted list is capped: eight names then a count, so the envelope
      // stays inside the budget the issue sets.
      final detail = envelope['detail'] as String;
      expect(detail, contains('and 34 more'),
          reason: 'update_flight accepts 43 arguments; eight are named');
      final named = detail.replaceFirst('accepts ', '').split(' and ').first;
      expect(named.split(', '), hasLength(8));
      expect(
        bytesOf(jsonEncode(envelope)),
        lessThan(400),
        reason: 'a typo costs ${bytesOf(jsonEncode(envelope))} B',
      );
    });

    test('the tool that refused is named on every read and write', () async {
      final server = await start(write: true);

      for (final (tool, args) in [
        ('list_flights', {'limt': 5}),
        ('get_recent_logs', {'include_stacks': true}),
        ('add_aircraft', {'type': 'C172', 'registration': 'ABC', 'ifrr': true}),
      ]) {
        final envelope = errorOf(await server.call(tool, args));
        expect(envelope['error'], 'unknown_field', reason: tool);
        expect(envelope['tool'], tool);
        expect(envelope['field'], args.keys.last);
      }
    });

    test('a missing row and a bad value are told apart by code', () async {
      final server = await start();

      final missing =
          errorOf(await server.call('get_flight', {'id': 'not-a-flight'}));
      expect(missing['error'], 'not_found');
      expect(missing['field'], 'id');

      final badDate = errorOf(
          await server.call('list_flights', {'date_from': 'yesterday'}));
      expect(badDate['error'], 'invalid_value');
      expect(badDate['field'], 'date_from');
      expect(badDate['detail'], contains('YYYY-MM-DD'));
    });

    test('a database failure is a code, not SQL text or a file path', () async {
      // A trigger standing in for any constraint the server does not pre-check.
      // Its message deliberately carries SQL and a path, because a raw SQLite
      // message does, and none of it may reach the caller.
      withFixtureDb(dbPath, (db) {
        db.execute(
          'CREATE TRIGGER refuse_flight BEFORE INSERT ON flights BEGIN '
          "SELECT RAISE(ABORT, 'INSERT INTO flights failed at /secret/db.sqlite'); "
          'END',
        );
      });
      final server = await start(write: true);

      final result = await server.call('create_flight', {
        'date': '2026-10-27',
        'total_time': 60,
      });
      final envelope = errorOf(result);

      expect(envelope['error'], 'constraint');
      expect('${result.payload}', isNot(contains('INSERT INTO')));
      expect('${result.payload}', isNot(contains('db.sqlite')));
      expect('${result.payload}', isNot(contains('SqliteException')));
      expect(bytesOf(jsonEncode(envelope)), lessThan(400));
      expect(
        withFixtureDb(dbPath,
            (db) => db.select("SELECT COUNT(*) AS n FROM flights").single['n']),
        0,
        reason: 'the refused write rolled back',
      );
    });

    test('the error shape is the same in read-only mode', () async {
      final server = await start();
      final envelope = errorOf(await server.call('db_info', {'db': 'x'}));
      expect(envelope.keys.toSet(), {'error', 'field', 'tool', 'detail'});
    });

    test('a missing table is not_found and names the field', () async {
      // A logbook written by an older schema, or one the user has never opened
      // the expiry or currency page on, has no such table. That is a missing
      // thing, not a bad value.
      withFixtureDb(dbPath, (db) {
        db.execute('DROP TABLE expiries');
        db.execute('DROP TABLE user_currency');
      });
      final server = await start();

      for (final (tool, field) in [
        ('list_expiries', 'expiries'),
        ('currency_status', 'user_currency'),
      ]) {
        final envelope = errorOf(await server.call(tool, {}));
        expect(envelope['error'], 'not_found', reason: tool);
        expect(envelope['field'], field, reason: tool);
        expect(envelope['detail'], contains('has no $field table'));
      }
    });

    test('a locked database is a busy envelope, not SQLite text', () async {
      final server = await start();

      await whileLocked(() async {
        for (final tool in ['list_expiries', 'currency_status']) {
          final result = await server.call(tool, {});
          final envelope = errorOf(result);

          expect(envelope['error'], 'busy', reason: tool);
          expect(envelope['detail'],
              'the database is locked by another process; retry in a moment',
              reason: tool);
          expect(envelope.keys.toSet(), {'error', 'detail'},
              reason: 'a busy database names no field and no tool');

          // The exact text SQLite produces carries the statement it was
          // preparing, and a caller can act on none of it.
          final text = '${result.payload}';
          expect(text, isNot(contains('SqliteException')), reason: tool);
          expect(text, isNot(contains('Causing statement')), reason: tool);
          expect(text, isNot(contains('SELECT')), reason: tool);
          expect(bytesOf(text), lessThan(200),
              reason: '$tool costs ${bytesOf(text)} B while locked');
        }
      });
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('no read tool leaks SQLite text or SQL when the database is locked',
        () async {
      // The guard for the whole class rather than the two tools that leaked: a
      // tool added later that pipes a caught exception into `_fail` fails here.
      final server = await start();

      await whileLocked(() async {
        for (final (tool, args) in [
          ('list_flights', <String, dynamic>{}),
          ('get_flight', {'id': 'fl-1'}),
          ('search_flights', {'query': 'YSSY'}),
          ('find_missing_times', <String, dynamic>{}),
          ('logbook_stats', <String, dynamic>{}),
          ('list_aircraft', <String, dynamic>{}),
          ('list_expiries', <String, dynamic>{}),
          ('currency_status', <String, dynamic>{}),
          ('get_schema', <String, dynamic>{}),
          ('db_info', <String, dynamic>{}),
        ]) {
          final result = await server.call(tool, args);
          final text = '${result.payload}';

          expect(text, isNot(contains('SqliteException')), reason: tool);
          expect(text, isNot(contains('Causing statement')), reason: tool);
          expect(text, isNot(contains('SELECT')), reason: tool);
          expect(text, isNot(contains('sqlite_master')), reason: tool);
          expect(errorOf(result)['error'], 'busy', reason: tool);
        }
      });
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
