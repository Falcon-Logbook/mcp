import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support/harness.dart';

/// The declared logbook zone, `FALCON_TZ`, and what it guarantees: the same
/// database answers with the same calendar dates, windows and counts whatever
/// zone the server process itself runs in. Each cross-process case spawns real
/// servers under two opposite host zones (`Pacific/Kiritimati` is UTC+14,
/// `Etc/GMT+12` is UTC-12) and compares their answers.
void main() {
  tzdata.initializeTimeZones();
  final sydney = tz.getLocation('Australia/Sydney');

  /// Two host zones at the extremes of the date line (UTC+14 and UTC-12), so
  /// a server that falls back to its own zone instead of the declared one
  /// cannot pass by accident.
  const hostZones = ['Pacific/Kiritimati', 'Etc/GMT+12'];

  Map<String, dynamic> payloadOf(({bool isError, Object? payload}) result) {
    expect(result.isError, isFalse, reason: '${result.payload}');
    return result.payload as Map<String, dynamic>;
  }

  group('logbook zone helpers', () {
    tearDown(() => configureLogbookZone());

    test('the configured zone decides every calendar date', () {
      final zone = configureLogbookZone(name: 'Australia/Sydney');
      expect(zone.name, 'Australia/Sydney');

      final day = logbookDateAt(2026, 10, 27);
      expect([day.year, day.month, day.day, day.hour], [2026, 10, 27, 0]);
      expect(day.timeZoneOffset, const Duration(hours: 11),
          reason: 'Sydney is on daylight time in late October');

      // 2026-10-26T13:00Z is already 2026-10-27 in Sydney (+11:00).
      final instant =
          DateTime.utc(2026, 10, 26, 13).millisecondsSinceEpoch ~/ 1000;
      expect(epochToCalendarDate(instant), '2026-10-27');
      expect(formatCalendarDate(logbookDateFromEpoch(instant)), '2026-10-27');

      // A DateTime means its own Y-M-D in the logbook zone, not its instant.
      expect(formatCalendarDate(logbookDateOf(DateTime.utc(2026, 10, 26, 13))),
          '2026-10-26');
    });

    test('with no name the system zone applies, exactly as before', () {
      configureLogbookZone();
      final host = DateTime(2026, 10, 26, 13);
      expect(epochToCalendarDate(host.millisecondsSinceEpoch ~/ 1000),
          formatCalendarDate(host));
      expect(logbookDateAt(2026, 10, 27).millisecondsSinceEpoch,
          DateTime(2026, 10, 27).millisecondsSinceEpoch);
    });

    test('an invalid IANA name fails loudly, naming FALCON_TZ and the value',
        () {
      expect(
        () => configureLogbookZone(name: 'Not/AZone'),
        throwsA(isA<LogbookZoneException>().having(
          (error) => error.message,
          'message',
          allOf(contains('FALCON_TZ'), contains('Not/AZone')),
        )),
      );
    });
  });

  // Each case spawns two or three real servers, one per host zone, so the
  // default 30 s is not enough on a loaded machine where a fresh VM start can
  // take a while. The assertions are unchanged; only the clock is patient.
  group(
    'across processes',
    () {
      late Directory tempDir;
      late String dbPath;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('falcon_mcp_tz_test');
        dbPath = createEmptyFixture('${tempDir.path}/falcon_db.sqlite');
      });

      tearDown(() => tempDir.deleteSync(recursive: true));

      /// The instant 2026-10-26T13:00:00Z, exactly Sydney midnight starting
      /// 2026-10-27 and mid-afternoon of 2026-10-26 in UTC.
      int instantOf(DateTime utc) => utc.millisecondsSinceEpoch ~/ 1000;

      test('the same FALCON_TZ gives identical answers in opposite host zones',
          () async {
        const logbook = {'FALCON_TZ': 'Australia/Sydney'};

        // The fixture is built through the server, so every stored date is the
        // declared zone's midnight of the date the caller named.
        final writer = await McpProcess.start(dbPath,
            write: true, environment: {...logbook, 'TZ': hostZones.first});
        addTearDown(() => writer.stop());
        for (final (date, minutes) in [
          ('2026-10-27', 120),
          ('2026-10-27', 60),
          ('2026-10-26', 90),
        ]) {
          final created = await writer.call('create_flight', {
            'date': date,
            'route': 'YSSY - NZQN',
            'total_time': minutes,
            'day_time': minutes,
            'night_time': 0,
          });
          expect(created.isError, isFalse, reason: '${created.payload}');
        }

        final answers = <String, Map<String, dynamic>>{};
        for (final host in hostZones) {
          final server = await McpProcess.start(dbPath,
              environment: {...logbook, 'TZ': host});
          addTearDown(() => server.stop());
          final list = payloadOf(await server.call('list_flights', {}));
          final id = ((list['flights'] as List).first as Map)['id'] as String;
          answers[host] = {
            'list': list,
            'stats': payloadOf(await server.call('logbook_stats', {})),
            'flight': payloadOf(await server.call('get_flight', {'id': id})),
          };
        }

        // Counts, totals, YYYY-MM-DD dates and rendered timestamps all read
        // identically: the logbook zone, not the host, decides every one.
        expect(answers[hostZones[1]], answers[hostZones[0]]);

        final first = answers[hostZones[0]]!;
        final flights =
            (first['list']!['flights'] as List).cast<Map<String, dynamic>>();
        expect([
          for (final row in flights) row['date']
        ], [
          '2026-10-27',
          '2026-10-27',
          '2026-10-26'
        ], reason: 'newest first, and the dates read back as written');
        expect(first['stats']!['flights'], 3);
        expect(first['stats']!['total_minutes'], 270);
      });

      test('the declared zone decides the calendar date of a stored instant',
          () async {
        final instant = instantOf(DateTime.utc(2026, 10, 26, 13));
        insertFlights(dbPath, [
          {'id': 'fl-known', 'date': instant, 'total_time': 60},
        ]);

        for (final (index, zone, expected) in [
          (0, 'UTC', '2026-10-26'),
          (1, 'Australia/Sydney', '2026-10-27'),
        ]) {
          final server = await McpProcess.start(dbPath, environment: {
            'FALCON_TZ': zone,
            'TZ': hostZones[index],
          });
          addTearDown(() => server.stop());
          final rows =
              payloadOf(await server.call('list_flights', {}))['flights']
                  as List;
          expect((rows.single as Map)['date'], expected,
              reason: 'the same instant is $expected in $zone');
          final full =
              payloadOf(await server.call('get_flight', {'id': 'fl-known'}));
          expect(full['date'], expected);
        }
      });

      test('a date filter is the declared zone\'s day, edge to edge', () async {
        final instant = instantOf(DateTime.utc(2026, 10, 26, 13));
        insertFlights(dbPath, [
          {'id': 'fl-edge', 'date': instant, 'total_time': 60},
        ]);

        for (final (index, zone) in [
          (0, 'UTC'),
          (1, 'Australia/Sydney'),
        ]) {
          final server = await McpProcess.start(dbPath, environment: {
            'FALCON_TZ': zone,
            'TZ': hostZones[index],
          });
          addTearDown(() => server.stop());

          Future<Map<String, dynamic>> filtered(String date) async =>
              payloadOf(await server
                  .call('list_flights', {'date_from': date, 'date_to': date}));

          // The row is 2026-10-26 in UTC and 2026-10-27 in Sydney, so each
          // zone's window for that day includes it and the other day excludes
          // it. The same instant, two honest dates, no missing row.
          final own = zone == 'UTC' ? '2026-10-26' : '2026-10-27';
          final other = zone == 'UTC' ? '2026-10-27' : '2026-10-26';
          expect((await filtered(own))['total'], 1,
              reason: '$zone includes $own');
          expect((await filtered(other))['total'], 0,
              reason: '$zone excludes $other');
        }
      });

      test('days_since_last_flight counts the pilot\'s days in any host zone',
          () async {
        final sydneyNow = tz.TZDateTime.now(sydney);
        final last = tz.TZDateTime(
            sydney, sydneyNow.year, sydneyNow.month, sydneyNow.day - 3);
        insertFlights(dbPath, [
          {
            'id': 'fl-last',
            'date': last.millisecondsSinceEpoch ~/ 1000,
            'total_time': 60,
          },
        ]);

        for (final host in hostZones) {
          final server = await McpProcess.start(dbPath, environment: {
            'FALCON_TZ': 'Australia/Sydney',
            'TZ': host,
          });
          addTearDown(() => server.stop());
          final overview = payloadOf(await server.call('logbook_overview', {}));
          final activity = overview['recent_activity'] as Map<String, dynamic>;
          expect(activity['days_since_last_flight'], 3, reason: 'host $host');
          expect(activity['last_flight_date'], formatCalendarDate(last));
        }
      });

      test('an expiry due in 30 pilot days reads the same in any host zone',
          () async {
        final sydneyNow = tz.TZDateTime.now(sydney);
        final due = tz.TZDateTime(
            sydney, sydneyNow.year, sydneyNow.month, sydneyNow.day + 30);
        withFixtureDb(dbPath, (db) {
          db.execute(
            'INSERT INTO expiries (id, name, due_date, created_at) '
            'VALUES (?, ?, ?, ?)',
            ['ex-1', 'Medical', due.millisecondsSinceEpoch ~/ 1000, 1700000000],
          );
        });

        for (final host in hostZones) {
          final server = await McpProcess.start(dbPath, environment: {
            'FALCON_TZ': 'Australia/Sydney',
            'TZ': host,
          });
          addTearDown(() => server.stop());
          final payload = payloadOf(await server.call('list_expiries', {}));
          final row =
              (payload['expiries'] as List).single as Map<String, dynamic>;
          expect(row['days_remaining'], 30, reason: 'host $host');
          expect(row['status'], 'orange', reason: 'host $host');
          expect(row['due_date'], formatCalendarDate(due));
          expect(payload['checked_on'], formatCalendarDate(sydneyNow));
        }
      });

      test('a preset window is the pilot\'s days in any host zone', () async {
        final sydneyNow = tz.TZDateTime.now(sydney);
        final inside = tz.TZDateTime(
            sydney, sydneyNow.year, sydneyNow.month, sydneyNow.day - 6);
        final outside = tz.TZDateTime(
            sydney, sydneyNow.year, sydneyNow.month, sydneyNow.day - 7);
        insertFlights(dbPath, [
          {
            'id': 'fl-in',
            'date': inside.millisecondsSinceEpoch ~/ 1000,
            'total_time': 60,
          },
          {
            'id': 'fl-out',
            'date': outside.millisecondsSinceEpoch ~/ 1000,
            'total_time': 60,
          },
        ]);

        final answers = <String, Map<String, dynamic>>{};
        for (final host in hostZones) {
          final server = await McpProcess.start(dbPath, environment: {
            'FALCON_TZ': 'Australia/Sydney',
            'TZ': host,
          });
          addTearDown(() => server.stop());
          final week = payloadOf(
              await server.call('logbook_stats', {'period': 'last_7_days'}));
          expect(week['flights'], 1, reason: 'host $host');
          expect(week['flights_complete'], 1, reason: 'host $host');
          expect((week['range'] as Map)['from'], formatCalendarDate(inside));
          expect((week['range'] as Map)['to'], formatCalendarDate(sydneyNow));
          answers[host] = week;
        }
        expect(answers[hostZones[1]], answers[hostZones[0]]);

        // The row just outside the window is still a career flight, so the
        // window is what moved, not the data.
        final server = await McpProcess.start(dbPath, environment: {
          'FALCON_TZ': 'Australia/Sydney',
          'TZ': hostZones.first,
        });
        addTearDown(() => server.stop());
        final all = payloadOf(await server.call('logbook_stats', {}));
        expect(all['flights'], 2);
      });

      test(
          'an invalid FALCON_TZ stops the server, naming the variable and value',
          () async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'bin/falcon_mcp.dart', '--db', dbPath],
          environment: {'FALCON_TZ': 'Not/AZone'},
        );
        expect(result.exitCode, isNot(0));
        expect('${result.stderr}', contains('FALCON_TZ'));
        expect('${result.stderr}', contains('Not/AZone'));
        expect('${result.stdout}', isEmpty,
            reason: 'stdout is the MCP channel and stays clean');
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
