import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// Issue #10: a value the app could not have written is refused, and a value it
/// writes is stored the way the app stores it. The first two tests replay the
/// two payloads from the issue that were reproduced against a real logbook.
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_write_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<McpProcess> start({bool write = true}) async {
    final server = await McpProcess.start(dbPath, write: write);
    addTearDown(() async {
      await server.stop();
    });
    return server;
  }

  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) =>
      result.payload as Map<String, dynamic>;

  int flightCount() => withFixtureDb(
        dbPath,
        (db) =>
            db.select('SELECT COUNT(*) AS n FROM flights').single['n'] as int,
      );

  Map<String, dynamic> flightRow(String id) => withFixtureDb(
        dbPath,
        (db) => db.select('SELECT * FROM flights WHERE id = ?', [id]).single,
      );

  final uuidV4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  test('rejects the probe payload 999999999 minutes and writes no row',
      () async {
    final server = await start();
    final before = flightCount();

    final result = await server.call('create_flight', {
      'date': '2026-10-27',
      'total_time': 999999999,
    });

    expect(result.isError, isTrue);
    expect('${result.payload}', contains('525600'),
        reason: 'the error must name the app limit');
    expect(flightCount(), before, reason: 'a refused write must not insert');
  });

  test('rejects the probe payload time_start 9am and writes no row', () async {
    final server = await start();
    final before = flightCount();

    final result = await server.call('create_flight', {
      'date': '2026-10-27',
      'time_start': '9am',
    });

    expect(result.isError, isTrue);
    final message = '${result.payload}';
    expect(message, contains('time_start'));
    for (final form in ['9', '930', '9:30', '09:30', '0930']) {
      expect(message, contains(form),
          reason: 'the error must name the accepted forms');
    }
    expect(flightCount(), before, reason: 'a refused write must not insert');
  });

  test('accepts the app limits exactly and refuses one past them', () async {
    final server = await start();

    final maxTime = await server.call('create_flight', {
      'date': '2026-10-01',
      'total_time': 525600,
      'takeoffs': 10000,
      'landings': 10000,
    });
    expect(maxTime.isError, isFalse, reason: '${maxTime.payload}');

    final tooLong = await server
        .call('create_flight', {'date': '2026-10-01', 'total_time': 525601});
    expect(tooLong.isError, isTrue);
    expect('${tooLong.payload}', contains('525600'));

    final tooMany = await server
        .call('create_flight', {'date': '2026-10-01', 'takeoffs': 10001});
    expect(tooMany.isError, isTrue);
    expect('${tooMany.payload}', contains('10000'));

    // The cap applies after the hours conversion, not instead of it.
    final tooManyHours = await server.call(
        'create_flight', {'date': '2026-10-01', 'total_time_hours': 8761});
    expect(tooManyHours.isError, isTrue);
    expect('${tooManyHours.payload}', contains('525600'));
  });

  test('refuses a day and night split that does not add up to the total',
      () async {
    final server = await start();
    final before = flightCount();

    final result = await server.call('create_flight', {
      'date': '2026-10-27',
      'total_time': 120,
      'day_time': 90,
      'night_time': 60,
    });
    expect(result.isError, isTrue);
    final message = '${result.payload}';
    expect(message, contains('150'), reason: 'the error names the sum');
    expect(message, contains('120'), reason: 'the error names the total');
    expect(flightCount(), before);
  });

  test('accepts the splits the app saves and warns on a one-sided one',
      () async {
    final server = await start();

    // The app's wizard accepts day == total, night == total, or an exact sum.
    for (final (day, night) in [(120, null), (null, 120), (90, 30)]) {
      final created = await server.call('create_flight', {
        'date': '2026-10-27',
        'total_time': 120,
        if (day != null) 'day_time': day,
        if (night != null) 'night_time': night,
      });
      expect(created.isError, isFalse,
          reason: 'day $day night $night: ${created.payload}');
      expect(payloadOf(created)['warnings'], isNull);
    }

    final oneSided = await server.call('create_flight', {
      'date': '2026-10-27',
      'total_time': 120,
      'day_time': 60,
    });
    expect(oneSided.isError, isFalse, reason: '${oneSided.payload}');
    final warnings = payloadOf(oneSided)['warnings'] as List;
    expect(warnings.join(' '), contains('day_time'),
        reason: 'a one-sided split is stored with a warning, not refused');
  });

  test('refuses total_time 0 at the schema, without a round trip', () async {
    final server = await start();
    final before = flightCount();

    // The column advertises minimum 1, so the SDK refuses 0 before the tool
    // runs. #65: the schema and the write path must agree on the floor.
    for (final args in [
      {'date': '2026-10-27', 'total_time': 0},
      {'date': '2026-10-27', 'total_time_hours': 0},
    ]) {
      final zero = await server.call('create_flight', args);
      expect(zero.isError, isTrue, reason: '$args');
      final message = '${zero.payload}';
      expect(message, contains('below minimum 1'), reason: message);
    }
    expect(flightCount(), before);

    final normal = await server
        .call('create_flight', {'date': '2026-10-27', 'total_time': 30});
    expect(normal.isError, isFalse, reason: '${normal.payload}');
  });

  test('the write path still refuses total_time 0 on a batch row', () async {
    final server = await start();
    final before = flightCount();

    // A batch row arrives with an untyped item schema, so the schema cannot
    // refuse it: the column's floor is applied when the row is coerced.
    final result = payloadOf(await server.call('apply_flight_batch', {
      'dry_run': false,
      'flights': [
        {'date': '2026-10-27', 'total_time': 0},
      ],
    }));
    expect(result['applied'], 0);
    final failed = (result['failed'] as List).cast<Map<String, dynamic>>();
    expect('${failed.single['reason']}', contains('total_time'));
    expect('${failed.single['reason']}', contains('>= 1'));
    expect(flightCount(), before, reason: 'a refused batch writes nothing');
  });

  test('canonicalises block times to HH:MM and refuses anything else',
      () async {
    final server = await start();

    for (final (given, stored) in [
      ('930', '09:30'),
      ('9', '09:00'),
      ('9:30', '09:30'),
      ('0930', '09:30'),
      ('23:59', '23:59'),
    ]) {
      final created = await server.call('create_flight', {
        'date': '2026-10-27',
        'time_start': given,
      });
      expect(created.isError, isFalse, reason: '$given: ${created.payload}');
      final id = payloadOf(created)['id'] as String;
      expect(flightRow(id)['time_start'], stored, reason: '$given -> $stored');
    }

    for (final bad in ['24:00', '09:60', '2400', '0960', '9am', '0930am', '']) {
      final result = await server
          .call('create_flight', {'date': '2026-10-27', 'time_start': bad});
      expect(result.isError, isTrue, reason: '"$bad" must be refused');
    }
  });

  test('creates every synced row with a UUID v4 id', () async {
    final empty = createEmptyFixture('${tempDir.path}/empty.sqlite');
    final server = await McpProcess.start(empty, write: true);
    addTearDown(() async {
      await server.stop();
    });

    final flight = await server
        .call('create_flight', {'date': '2026-03-04', 'total_time': 60});
    final aircraft = await server
        .call('add_aircraft', {'type': 'C172', 'registration': 'ABC'});
    final crew = await server
        .call('add_crew', {'first_name': 'Sam', 'last_name': 'Pilot'});
    final airport =
        await server.call('add_custom_airport', {'name': 'Back Paddock'});
    final settings =
        await server.call('update_flight_settings', {'pilot_name': 'Ada'});

    for (final (tool, result) in [
      ('create_flight', flight),
      ('add_aircraft', aircraft),
      ('add_crew', crew),
      ('add_custom_airport', airport),
      ('update_flight_settings', settings),
    ]) {
      expect(result.isError, isFalse, reason: '$tool: ${result.payload}');
      final id = payloadOf(result)['id'] as String;
      expect(uuidV4.hasMatch(id), isTrue, reason: '$tool produced id $id');
    }

    // The settings row is the one that used to be written as 'default'.
    final stored = withFixtureDb(
        empty,
        (db) => db
            .select('SELECT id FROM flights_settings')
            .map((row) => row['id'] as String)
            .toList());
    expect(stored, hasLength(1));
    expect(uuidV4.hasMatch(stored.single), isTrue, reason: stored.single);
  });

  test('accepts a caller-supplied UUID id only when it is unused', () async {
    final server = await start();
    const id = '3f1a6c1e-9b2d-4a57-8f0c-2d1e3b4a5c6d';

    final created = await server.call(
        'create_flight', {'id': id, 'date': '2026-06-01', 'total_time': 60});
    expect(created.isError, isFalse, reason: '${created.payload}');
    expect(payloadOf(created)['id'], id);

    final reused = await server.call(
        'create_flight', {'id': id, 'date': '2026-06-01', 'total_time': 60});
    expect(reused.isError, isTrue);
    expect('${reused.payload}', contains('already exists'));

    final notAUuid = await server
        .call('create_flight', {'id': 'mcp_fl_1a2b', 'date': '2026-06-01'});
    expect(notAUuid.isError, isTrue);
    expect('${notAUuid.payload}', contains('UUID v4'));
    expect(flightCount(), 3, reason: 'only the first create may land');
  });

  test('stamps updated_at and orders flights within their day', () async {
    final server = await start();

    final first = await server
        .call('create_flight', {'date': '2026-05-01', 'total_time': 60});
    final second = await server
        .call('create_flight', {'date': '2026-05-01', 'total_time': 60});
    final other = await server
        .call('create_flight', {'date': '2026-05-02', 'total_time': 60});

    expect(payloadOf(first)['day_order'], 0);
    expect(payloadOf(second)['day_order'], 1);
    expect(payloadOf(other)['day_order'], 0);

    // A push must not re-select a created row forever, so updated_at is set.
    final created = payloadOf(first)['flight'] as Map;
    expect(created['updated_at'], isNotNull);
    expect(created['total_time'], 60);
    expect(
        flightRow(payloadOf(first)['id'] as String)['updated_at'], isNotNull);

    // Moving the second flight to the other day appends it to that day.
    final moved = await server.call('update_flight', {
      'id': payloadOf(other)['id'],
      'date': '2026-05-01',
    });
    expect(moved.isError, isFalse, reason: '${moved.payload}');
    expect(payloadOf(moved)['day_order'], 2);

    // An update that keeps the date leaves the order alone.
    final kept = await server.call('update_flight', {
      'id': payloadOf(first)['id'],
      'route': 'YSSY - YSCB',
    });
    expect(kept.isError, isFalse, reason: '${kept.payload}');
    expect(payloadOf(kept)['day_order'], 0);
  });

  test('draft: true clears the time, and total_time refuses to share it',
      () async {
    final server = await start();
    final created = await server
        .call('create_flight', {'date': '2026-04-01', 'total_time': 90});
    final id = payloadOf(created)['id'] as String;

    final cleared =
        await server.call('update_flight', {'id': id, 'draft': true});
    expect(cleared.isError, isFalse, reason: '${cleared.payload}');
    expect(payloadOf(cleared)['draft'], isTrue);
    expect(flightRow(id)['total_time'], isNull);

    final conflict = await server
        .call('update_flight', {'id': id, 'draft': true, 'total_time': 60});
    expect(conflict.isError, isTrue);
    expect('${conflict.payload}', contains('draft: true'));

    // A client cannot send a null total_time: the SDK rejects it before the
    // tool runs. Asserted so a future schema change is noticed.
    final nullTime =
        await server.call('update_flight', {'id': id, 'total_time': null});
    expect(nullTime.isError, isTrue);
    expect(flightRow(id)['total_time'], isNull);
  });

  test('create_flight without a total is still a draft', () async {
    final server = await start();

    final bare = await server.call('create_flight', {'date': '2026-04-02'});
    expect(bare.isError, isFalse, reason: '${bare.payload}');
    expect(payloadOf(bare)['draft'], isTrue);
    expect((payloadOf(bare)['flight'] as Map)['total_time'], isNull);

    final explicit = await server.call('create_flight', {
      'date': '2026-04-02',
      'draft': true,
      'aircraft_registration': 'xzo',
    });
    expect(explicit.isError, isFalse, reason: '${explicit.payload}');
    expect(payloadOf(explicit)['draft'], isTrue);
    final row = flightRow(payloadOf(explicit)['id'] as String);
    expect(row['total_time'], isNull);
    expect(row['aircraft_id'], 'ac-1');
  });

  test('an update returns the written row and leaves a valid split alone',
      () async {
    final server = await start();

    // fl-1 is the seeded complete flight: 90 day, 30 night, 120 total.
    final updated = await server
        .call('update_flight', {'id': 'fl-1', 'route': 'YSSY - YSCB'});
    expect(updated.isError, isFalse, reason: '${updated.payload}');
    final payload = payloadOf(updated);
    expect(payload['status'], 'updated');
    expect(payload['draft'], isFalse);
    final flight = payload['flight'] as Map;
    expect(flight['route'], 'YSSY - YSCB');
    expect(flight['total_time'], 120);
    expect(flight['day_time'], 90);
    expect(flight['night_time'], 30);
  });

  test('a row that was already inconsistent stays editable', () async {
    // The app can hold rows this server would now refuse to create: an imported
    // logbook, or a split saved from a draft. Fixing an unrelated field must
    // not force a repair of times nobody touched, but touching the split
    // re-checks it.
    insertFlights(dbPath, [
      {
        'id': 'fl-legacy',
        'date': DateTime(2026, 2, 2),
        'total_time': 120,
        'day_time': 100,
        'night_time': 30,
      },
    ]);
    final server = await start();

    final routed = await server
        .call('update_flight', {'id': 'fl-legacy', 'route': 'YSSY - YSCB'});
    expect(routed.isError, isFalse, reason: '${routed.payload}');
    expect(payloadOf(routed)['warnings'], isNull);

    final untouched =
        await server.call('update_flight', {'id': 'fl-legacy', 'takeoffs': 1});
    expect(untouched.isError, isFalse, reason: '${untouched.payload}');

    final repaired =
        await server.call('update_flight', {'id': 'fl-legacy', 'day_time': 90});
    expect(repaired.isError, isFalse, reason: '${repaired.payload}');
    expect(flightRow('fl-legacy')['day_time'], 90);

    final worsened = await server
        .call('update_flight', {'id': 'fl-legacy', 'night_time': 40});
    expect(worsened.isError, isTrue);
    expect(flightRow('fl-legacy')['night_time'], 30,
        reason: 'the refused update must not land');
  });

  test('update_flight_settings no longer takes an id', () async {
    final server = await start();

    final withId = await server
        .call('update_flight_settings', {'id': 'x', 'pilot_name': 'Ada'});
    expect(withId.isError, isTrue);
    final envelope = jsonDecode('${withId.payload}') as Map;
    expect(envelope['error'], 'unknown_field');
    expect(envelope['field'], 'id');
    expect(envelope['tool'], 'update_flight_settings');

    final updated =
        await server.call('update_flight_settings', {'pilot_name': 'Ada'});
    expect(updated.isError, isFalse, reason: '${updated.payload}');
    final settings = payloadOf(updated)['settings'] as Map;
    expect(settings['pilot_name'], 'Ada');
    expect(settings['id'], 'settings-1',
        reason: 'an existing settings row keeps its id');
  });

  group('the _hours aliases never round', () {
    void addPlannedColumns() {
      withFixtureDb(dbPath, (db) {
        db.execute(
            'ALTER TABLE flights ADD COLUMN scheduled_departure_utc INTEGER NULL');
        db.execute(
            'ALTER TABLE flights ADD COLUMN scheduled_arrival_utc INTEGER NULL');
        db.execute(
            'ALTER TABLE flights ADD COLUMN scheduled_block_minutes INTEGER NULL');
      });
    }

    test('accept exact whole-minute values across every alias', () async {
      addPlannedColumns();
      final server = await start();

      final complete = await server.call('create_flight', {
        'date': '2026-07-01',
        'total_time_hours': 1.5,
        'day_time_hours': 1,
        'night_time_hours': 0.5,
      });
      expect(complete.isError, isFalse, reason: '${complete.payload}');
      final stored = flightRow(payloadOf(complete)['id'] as String);
      expect(stored['total_time'], 90, reason: '1.5 hours is 90 minutes');
      expect(stored['day_time'], 60, reason: '1 hour is 60 minutes');
      expect(stored['night_time'], 30, reason: '0.5 hours is 30 minutes');

      final planned = await server.call('create_flight', {
        'date': '2026-07-02',
        'scheduled_block_minutes_hours': 1.25,
      });
      expect(planned.isError, isFalse, reason: '${planned.payload}');
      expect(
          flightRow(
              payloadOf(planned)['id'] as String)['scheduled_block_minutes'],
          75,
          reason: '1.25 hours is 75 minutes');
    });

    test('refuse a sub-minute value by field, naming the nearest whole minute',
        () async {
      final server = await start();
      final before = flightCount();

      // 1.005 hours is 60.3 minutes. It used to be stored as 60: a duration
      // the pilot never entered.
      final refused = await server.call('create_flight', {
        'date': '2026-07-03',
        'total_time_hours': 1.005,
      });
      expect(refused.isError, isTrue);
      final message = '${refused.payload}';
      expect(message, contains('total_time_hours'),
          reason: 'the error names the field');
      expect(message, contains('never rounded'), reason: message);
      expect(message, contains('60.3'), reason: 'the exact minutes are named');
      expect(message, contains('60 minutes'),
          reason: 'the nearest valid value is named');
      expect(flightCount(), before, reason: 'a refused write must not insert');

      // The same conversion is used on update, so an existing value is not
      // silently moved to the nearest minute either.
      final created = await server
          .call('create_flight', {'date': '2026-07-04', 'total_time': 90});
      expect(created.isError, isFalse, reason: '${created.payload}');
      final id = payloadOf(created)['id'] as String;
      final update = await server
          .call('update_flight', {'id': id, 'total_time_hours': 1.005});
      expect(update.isError, isTrue);
      expect('${update.payload}', contains('total_time_hours'));
      expect(flightRow(id)['total_time'], 90,
          reason: 'the refused update leaves the stored minutes alone');
    });

    test('refuse a sub-minute value on a batch row', () async {
      final server = await start();
      final before = flightCount();

      final result = payloadOf(await server.call('apply_flight_batch', {
        'dry_run': false,
        'flights': [
          {'date': '2026-07-05', 'total_time_hours': 2.02},
        ],
      }));
      expect(result['applied'], 0);
      final failed = (result['failed'] as List).cast<Map<String, dynamic>>();
      final reason = '${failed.single['reason']}';
      expect(reason, contains('total_time_hours'),
          reason: 'the row failure names the field');
      expect(reason, contains('never rounded'), reason: reason);
      expect(reason, contains('121 minutes'),
          reason: '2.02 hours is 121.2 minutes, nearest 121');
      expect(flightCount(), before, reason: 'a refused batch writes nothing');
    });
  });
}
