import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #11: a flight read answers with a twelve-field summary by default, an
/// agent can ask for every column, a page is 20 rows by default, and the cost of
/// the common answers is asserted in bytes rather than estimated. Tokens are
/// roughly bytes/4, so every budget here is a byte count of the text a client
/// actually puts in context.
void main() {
  late Directory tempDir;
  late String dbPath;

  /// The summary row: what a pilot question needs, in a fixed key order.
  const slimKeys = {
    'id',
    'date',
    'route',
    'flight_number',
    'aircraft_registration',
    'crew_members_name',
    'total_time',
    'day_time',
    'night_time',
    'takeoffs',
    'landings',
    'is_simulator',
  };

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_shaping_test');
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

  /// The `limit` default and maximum each tool declares in the catalog an agent
  /// reads, parsed out of the description rather than from a constant here, so a
  /// description that disagrees with the callback fails a test.
  Future<Map<String, ({int byDefault, int atMost})>> declaredLimits(
      McpProcess server, List<String> tools) async {
    final response = await server.send('tools/list', {});
    final catalog =
        ((response['result'] as Map<String, dynamic>)['tools'] as List)
            .cast<Map<String, dynamic>>();
    return {
      for (final name in tools)
        name: () {
          final properties =
              (catalog.firstWhere((tool) => tool['name'] == name)['inputSchema']
                  as Map)['properties'] as Map;
          final description = (properties['limit'] as Map)['description'];
          final match = RegExp(r'Default (\d+), maximum (\d+)\.')
              .firstMatch('$description');
          if (match == null) {
            throw StateError('$name does not declare its limit: $description');
          }
          return (
            byDefault: int.parse(match.group(1)!),
            atMost: int.parse(match.group(2)!),
          );
        }(),
    };
  }

  /// Fifty complete flights plus two drafts: enough that the default page
  /// leaves rows behind, and enough to measure a page at the 200-row cap.
  void seedLogbook() {
    insertFlights(dbPath, [
      for (var day = 1; day <= 50; day++)
        {
          'id': 'fl-$day',
          'date': DateTime(2025, 1, 1).add(Duration(days: day)),
          'day_order': day % 3,
          'aircraft_registration': 'VH-XZO',
          'crew_members_name': day % 5 == 0 ? null : 'Jane Doe',
          'route': 'YSSY - NZQN',
          'flight_number': day % 4 == 0 ? null : 'QF$day',
          'total_time': 90 + day,
          'day_time': 60,
          'night_time': 30 + day,
          'takeoffs': 1,
          'landings': 1,
          'created_at': 1700000000,
        },
      {'id': 'fl-draft', 'date': DateTime(2025, 3, 1), 'route': 'YSBK - YSSY'},
    ]);
  }

  /// The exact text a read returns, and its size. Measured on the wire rather
  /// than on a re-encoded payload, so an encoding change cannot hide here.
  Future<int> bytesOf(McpProcess server, String tool, Map<String, dynamic> args,
      {String? uri}) async {
    final Object? text;
    if (uri != null) {
      final response = await server.send('resources/read', {'uri': uri});
      final contents =
          ((response['result'] as Map)['contents'] as List).single as Map;
      text = contents['text'];
    } else {
      final response =
          await server.send('tools/call', {'name': tool, 'arguments': args});
      final content = ((response['result'] as Map)['content'] as List)
          .cast<Map<String, dynamic>>();
      text = content.first['text'];
    }
    return utf8.encode(text as String).length;
  }

  test('a default flight read is a twelve-field summary page', () async {
    seedLogbook();
    final server = await start();

    final payload = payloadOf(await server.call('list_flights', {}));
    expect(payload['count'], 20, reason: 'the default page is 20 rows');
    expect(payload['total'], 51);
    expect(payload['has_more'], isTrue);
    expect(payload['offset'], 0);

    final rows = payload['flights'] as List;
    for (final row in rows) {
      expect((row as Map).keys.toSet(), slimKeys,
          reason: 'every summary row carries exactly the twelve keys');
    }

    // The summary still answers "what did I fly, and how long was it".
    final first = rows.first as Map;
    expect(first['id'], 'fl-draft');
    expect(first['route'], 'YSBK - YSSY');
    expect(first['date'], isA<String>());
    expect(first['total_time'], isNull, reason: 'the draft is still a draft');

    final flown = rows[2] as Map;
    expect(flown['id'], 'fl-49');
    expect(flown['total_time'], 139);
    expect(flown['day_time'], 60);
    expect(flown['night_time'], 79);
    expect(flown['takeoffs'], 1);
    expect(flown['landings'], 1);
    expect(flown['crew_members_name'], 'Jane Doe');
    expect(flown['flight_number'], 'QF49');
    expect(flown['is_simulator'], isFalse);
  });

  test('a flight with nothing recorded keeps every summary key', () async {
    insertFlights(dbPath, [
      {'id': 'fl-empty', 'date': DateTime(2025, 4, 1)},
    ]);
    final server = await start();

    final rows =
        payloadOf(await server.call('list_flights', {}))['flights'] as List;
    final flight = rows.single as Map;
    // A key that vanishes reads as "not recorded" only to a caller who knows it
    // exists, so the durations and counts are present and null.
    expect(flight.keys.toSet(), slimKeys);
    for (final key in [
      'route',
      'flight_number',
      'aircraft_registration',
      'crew_members_name',
      'total_time',
      'day_time',
      'night_time',
      'takeoffs',
      'landings',
    ]) {
      expect(flight.containsKey(key), isTrue, reason: '$key must be present');
      expect(flight[key], isNull, reason: '$key has nothing recorded');
    }
    expect(flight['is_simulator'], isFalse);
  });

  test('full: true returns every column of the live schema', () async {
    seedLogbook();
    final server = await start();
    final columnCount = withFixtureDb(
      dbPath,
      (db) => db.select('PRAGMA table_info(flights)').length,
    );

    final full = payloadOf(
        await server.call('list_flights', {'limit': 1, 'full': true}));
    final rows =
        payloadOf(await server.call('list_flights', {'limit': 1}))['flights']
            as List;
    final row = (full['flights'] as List).single as Map;

    // #9 derives departure_icao and arrival_icao from route on full rows and
    // get_flight, so they are two keys past the stored columns. The summary
    // stays the twelve stored fields.
    expect(row, hasLength(columnCount + 2),
        reason: 'full is the whole row plus the two derived route codes');
    expect(row.keys, containsAll(['departure_icao', 'arrival_icao']));
    expect(row['departure_icao'], 'YSBK',
        reason: 'the route parses as a pair, so the codes are filled');
    expect(row['id'], (rows.single as Map)['id']);
    for (final key in ['created_at', 'custom_columns', 'hobbs_start']) {
      expect(row.keys, contains(key));
    }

    // The same row through the detail call, minus its own units block.
    final detail = payloadOf(await server.call('get_flight', {'id': row['id']}))
      ..remove('units');
    expect(row, detail, reason: 'full and get_flight agree on the row');
  });

  test('search_flights is slim unless full, find_missing_times always lean',
      () async {
    seedLogbook();
    final server = await start();
    final columnCount = withFixtureDb(
      dbPath,
      (db) => db.select('PRAGMA table_info(flights)').length,
    );

    final searched = payloadOf(
        await server.call('search_flights', {'query': 'NZQN', 'limit': 2}));
    expect(searched['count'], 2);
    for (final row in searched['flights'] as List) {
      expect((row as Map).keys.toSet(), slimKeys);
    }
    final searchedFull = payloadOf(await server
        .call('search_flights', {'query': 'NZQN', 'limit': 2, 'full': true}));
    for (final row in searchedFull['flights'] as List) {
      // Two keys past the stored columns: the derived route codes (#9).
      expect(row as Map, hasLength(columnCount + 2));
    }

    // #9 turns find_missing_times into a fixed lean projection with a reason
    // per row, so there is no full form to ask for: the row is only the fields
    // the reason needs.
    final missing = payloadOf(await server.call('find_missing_times', {}));
    expect(missing['count'], 1);
    final missingRow = (missing['flights'] as List).single as Map;
    expect(missingRow.keys.toSet(), {
      'id',
      'date',
      'route',
      'total_time',
      'day_time',
      'night_time',
      'is_simulator',
      'reason',
    });
    expect(missingRow, containsPair('id', 'fl-draft'));
    expect(missingRow, containsPair('reason', 'draft'),
        reason: 'a null total is a draft, said in words');
  });

  test('pages default to 20 rows and refuse more than 200', () async {
    seedLogbook();
    final server = await start();

    final tooMany = await server.call('list_flights', {'limit': 201});
    expect(tooMany.isError, isTrue,
        reason: 'the cap is enforced before the callback runs');
    expect('${tooMany.payload}', contains('200'),
        reason: 'the refusal names the limit');

    final tooManySearch =
        await server.call('search_flights', {'query': 'NZQN', 'limit': 201});
    expect(tooManySearch.isError, isTrue);

    final cap = payloadOf(await server.call('list_flights', {'limit': 200}));
    expect(cap['count'], 51,
        reason: 'the cap is a page size, not a truncation');
    expect(cap['has_more'], isFalse);

    // A misspelled opt-out is refused by name, like every other argument.
    final typo = await server.call('list_flights', {'fulll': true});
    expect(typo.isError, isTrue);
    expect('${typo.payload}', contains('fulll'));
  });

  test('every flight read returns the rows its limit schema promises',
      () async {
    // 250 drafts: more rows than either default, so a tool that declares one
    // default and delivers another shows up here instead of only in a token
    // report. The old declaration promised 20 rows from find_missing_times and
    // got 200.
    insertFlights(dbPath, [
      for (var day = 1; day <= 250; day++)
        {
          'id': 'fl-draft-$day',
          'date': DateTime(2025, 2, 1).add(Duration(days: day)),
          'day_order': day % 3,
          'route': 'YSBK - YSSY',
          'created_at': 1700000000,
        },
    ]);
    final server = await start();
    final limits = await declaredLimits(
        server, ['list_flights', 'search_flights', 'find_missing_times']);

    // The two paged reads keep the documented page. find_missing_times is not
    // paged: it exists to find every draft, so it declares the 200 rows its
    // callback actually returns.
    for (final tool in ['list_flights', 'search_flights']) {
      expect(limits[tool], (byDefault: 20, atMost: 200),
          reason: '$tool is a page of 20 by default');
    }
    expect(limits['find_missing_times'], (byDefault: 200, atMost: 200),
        reason: 'find_missing_times returns every match up to the cap');

    final listed = payloadOf(await server.call('list_flights', {}));
    expect(
        (listed['flights'] as List).length, limits['list_flights']!.byDefault);
    expect(listed['has_more'], isTrue, reason: 'the rest are on later pages');

    final searched =
        payloadOf(await server.call('search_flights', {'query': 'YSBK'}));
    expect((searched['flights'] as List).length,
        limits['search_flights']!.byDefault);

    // More rows than the default: the response is exactly the count the
    // catalog promises, not one row more.
    final missing = payloadOf(await server.call('find_missing_times', {}));
    expect(missing['count'], limits['find_missing_times']!.byDefault,
        reason: 'find_missing_times returns the 200 rows it declares');
    expect((missing['flights'] as List).length, missing['count']);

    // The cap is in the schema, so an inflated limit is refused by the schema
    // and the refusal names it, as on the two paged reads.
    final tooMany = await server.call('find_missing_times', {'limit': 201});
    expect(tooMany.isError, isTrue);
    expect('${tooMany.payload}', contains('200'));
  });

  test('the flights resource is capped, slim and states its units', () async {
    seedLogbook();
    final server = await start();

    final response =
        await server.send('resources/read', {'uri': 'falcon://flights'});
    final contents =
        ((response['result'] as Map)['contents'] as List).single as Map;
    final payload = jsonDecode(contents['text'] as String) as Map;

    final rows = payload['rows'] as List;
    expect(rows, hasLength(20), reason: 'the resource stops at 20 rows');
    for (final row in rows) {
      expect((row as Map).keys.toSet(), slimKeys);
    }
    expect((rows.first as Map)['id'], 'fl-draft',
        reason: 'newest first, the same order as list_flights');

    // The resource is the one payload a client may read without asking, so it
    // carries the units a tool response carries.
    final units = payload['units'] as Map;
    expect(units['time'], 'minutes');
    expect(units['date'], dateTypeOf((rows.first as Map)['date']));
    final listPayload = payloadOf(await server.call('list_flights', {}));
    expect(units, listPayload['units']);
  });

  test('the common answers stay inside their byte budgets', () async {
    seedLogbook();
    final server = await start();

    // The default list on a fifty-row logbook. A page of fifty rows cannot fit
    // 8 KB at the 300 B row budget, so the promise is the default page.
    final defaultList = await bytesOf(server, 'list_flights', {});
    expect(defaultList, lessThan(8000),
        reason: 'a default flight answer costs $defaultList B');

    // One summary row, measured from a real response.
    final single =
        payloadOf(await server.call('list_flights', {'limit': 1}))['flights']
            as List;
    final rowBytes = utf8.encode(jsonEncode(single.single)).length;
    expect(rowBytes, lessThan(300),
        reason: 'one summary row costs $rowBytes B');

    final resource = await bytesOf(server, '', {}, uri: 'falcon://flights');
    expect(resource, lessThan(6000),
        reason: 'the flights resource costs $resource B');

    final readOnlyCatalog = utf8
        .encode(jsonEncode((await server.send('tools/list', {}))['result']))
        .length;
    // #8's expiry and currency reads add 2,702 B (`list_expiries` 1,295 and
    // `currency_status` 1,405, schemas included), taking the catalog from
    // 11,096 B to 13,798 B. Slice 2's `entity_totals` and `get_settings` add
    // 2,344 B, the flights_complete rename 55 B, #6's `ask_user` 888 B and
    // the type/sort enums with the offset argument 138 B. #12's
    // `data_quality_report` adds 1,421 B and #7's `logbook_overview` 640 B.
    // #3's `validate_flight_drafts` adds 1,460 B. Slice 3's timezone reword
    // of the three flight read descriptions adds 9 B, measured at 21,442 B.
    // #4's guided logbook import adds `mode` and `units` to
    // `validate_flight_drafts` and rewords its description, 1,224 B at 22,666
    // B measured (the same measurement and bound as catalog_cost_test, where
    // the write-mode catalog is measured too).
    // The bound is the measurement plus 1,024 B of headroom, which leaves
    // room to reword a description but trips on a new tool or a description
    // that grows materially: 22,666 B measured, so 23,690 B.
    expect(readOnlyCatalog, lessThanOrEqualTo(23690),
        reason: 'the read-only catalog costs $readOnlyCatalog B, against '
            '22,666 B measured plus 1,024 B of wording headroom');

    final typo = await bytesOf(server, 'list_flights', {'limt': 5});
    expect(typo, lessThan(400), reason: 'a typo error costs $typo B');

    final help = await server.send('prompts/get', {'name': 'falcon_help'});
    final messages = (help['result'] as Map)['messages'] as List;
    final helpText = ((messages.single as Map)['content'] as Map)['text'];
    final helpBytes = utf8.encode(helpText as String).length;
    expect(helpBytes, lessThan(1500), reason: 'falcon_help costs $helpBytes B');

    // The write-mode catalog, the schema payouts and the error envelope are
    // measured and asserted in catalog_cost_test.dart, where the flight write
    // schemas are also compared field by field.
  });
}
