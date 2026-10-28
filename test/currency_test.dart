import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Currency reads: the app's five windows, eight metrics, hours for time
/// metrics, and the deliberately inverted `is_exceeded` for a requirement.
///
/// Every number here is hand-checkable against the fixture below, which is the
/// point: these are the numbers the pilot sees on the app's currency page.
void main() {
  group('currency bounds', () {
    final now = DateTime(2026, 10, 28, 15, 30);

    test('mirror the app for the five periods', () {
      final year = currencyBounds('calendarYear', now);
      expect((year.start, year.end), (DateTime(2026), DateTime(2027)));

      // 365 inclusive days: today-364 up to tomorrow.
      final rolling = currencyBounds('rolling365', now);
      expect(rolling.start, DateTime(2025, 10, 29));
      expect(rolling.end, DateTime(2026, 10, 29));

      final month = currencyBounds('calendarMonth', now);
      expect(
          (month.start, month.end), (DateTime(2026, 10), DateTime(2026, 11)));

      // 30 inclusive days: today-29 up to tomorrow.
      final rolling30 = currencyBounds('rolling30', now);
      expect(rolling30.start, DateTime(2026, 9, 29));
      expect(rolling30.end, DateTime(2026, 10, 29));

      final all = currencyBounds('allTime', now);
      expect((all.start, all.end), (DateTime(0), DateTime(9999)));
    });

    test('an unknown period falls back to all time, like the app', () {
      final bounds = currencyBounds('rolling90', now);
      expect((bounds.start, bounds.end), (DateTime(0), DateTime(9999)));
      expect(currencyWindow('rolling90', now), isNull);
    });

    test('time metrics are hours and everything else is a count', () {
      for (final metric in [
        'totalTime',
        'dayTime',
        'nightTime',
        'instrumentTime'
      ]) {
        expect(isCurrencyTimeMetric(metric), isTrue, reason: metric);
        expect(currencyMetricUnit(metric), 'hours', reason: metric);
        expect(currencyValue(90, metric), 1.5, reason: metric);
      }
      for (final metric in [
        'approachCount',
        'landingCount',
        'takeoffCount',
        'flightCount'
      ]) {
        expect(isCurrencyTimeMetric(metric), isFalse, reason: metric);
        expect(currencyMetricUnit(metric), 'count', reason: metric);
        expect(currencyValue(90, metric), 90.0, reason: metric);
      }
    });
  });

  group('currency_status', () {
    late Directory tempDir;
    late String dbPath;
    final today = DateTime.now();

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('falcon_mcp_currency_test');
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

    Map<String, Map<String, dynamic>> rulesByPeriod(
            Map<String, dynamic> payload) =>
        {
          for (final rule in payload['rules'] as List)
            (rule as Map<String, dynamic>)['period'] as String: rule,
        };

    Map<String, Map<String, dynamic>> rulesById(Map<String, dynamic> payload) =>
        {
          for (final rule in payload['rules'] as List)
            (rule as Map<String, dynamic>)['id'] as String: rule,
        };

    Map<String, Map<String, dynamic>> rulesByMetric(
            Map<String, dynamic> payload) =>
        {
          for (final rule in payload['rules'] as List)
            (rule as Map<String, dynamic>)['metric'] as String: rule,
        };

    /// [offset] days from today at local midnight.
    DateTime inDays(int offset) =>
        DateTime(today.year, today.month, today.day + offset);

    void insertRules(List<Map<String, Object?>> rows) {
      withFixtureDb(dbPath, (db) {
        var index = 0;
        for (final row in rows) {
          final values = <String, Object?>{
            'id': 'uc-${index++}',
            'title': 'Rule $index',
            'sort_order': 0,
            'type': 'requirement',
            ...row,
          };
          db.execute(
            'INSERT INTO user_currency (${values.keys.join(', ')}) '
            'VALUES (${List.filled(values.length, '?').join(', ')})',
            values.values.toList(),
          );
        }
      });
    }

    test('sums each period inside the app boundaries', () async {
      // A flight on the boundary day of each window, and one just outside it.
      insertFlights(dbPath, [
        {'id': 'fl-today', 'date': inDays(0), 'total_time': 60},
        {'id': 'fl-29', 'date': inDays(-29), 'total_time': 360},
        {'id': 'fl-30', 'date': inDays(-30), 'total_time': 300},
        {'id': 'fl-32', 'date': inDays(-32), 'total_time': 180},
        {'id': 'fl-364', 'date': inDays(-364), 'total_time': 240},
        {'id': 'fl-367', 'date': inDays(-367), 'total_time': 120},
      ]);
      insertRules([
        for (final period in currencyPeriods)
          {
            'id': 'uc-$period',
            'title': period,
            'metric': 'totalTime',
            'period': period,
            'threshold': 1000,
          },
      ]);
      final server = await start();

      final payload = payloadOf(await server.call('currency_status', {}));
      final rules = rulesByPeriod(payload);
      expect(payload['count'], 5);
      expect(payload['units'], {'time': 'hours', 'counts': 'count'});

      // rolling365 holds every flight except the one 367 days back.
      expect(rules['rolling365']!['current'], 19.0);
      expect(rules['rolling365']!['window'], {
        'from': formatCalendarDate(inDays(-364)),
        'to': formatCalendarDate(inDays(0)),
      });
      // rolling30 starts 29 days ago, so the flight 30 days back is outside.
      expect(rules['rolling30']!['current'], 7.0);
      expect(rules['rolling30']!['window'], {
        'from': formatCalendarDate(inDays(-29)),
        'to': formatCalendarDate(inDays(0)),
      });
      // calendarMonth is the month to date: only today's flight, since 32 days
      // back is always a previous month.
      expect(rules['calendarMonth']!['current'], 1.0);
      // calendarYear is the year to date: a plain year comparison decides it.
      final yearMinutes = [0, -29, -30, -32, -364, -367]
          .where((offset) => inDays(offset).year == today.year)
          .fold<int>(
              0,
              (sum, offset) =>
                  sum +
                  switch (offset) {
                    -29 => 360,
                    -30 => 300,
                    -32 => 180,
                    -364 => 240,
                    -367 => 120,
                    _ => 60,
                  });
      expect(rules['calendarYear']!['current'], yearMinutes / 60);
      // allTime is everything, the 367-day flight included.
      expect(rules['allTime']!['current'], 21.0);
      expect(rules['allTime']!['window'], isNull);
    });

    test('computes all eight metrics, in the app units', () async {
      insertFlights(dbPath, [
        {
          'id': 'fl-rich',
          'date': inDays(-1),
          'total_time': 120,
          'day_time': 90,
          'night_time': 30,
          'actual_instrument': 20,
          'simulated_instrument': 10,
          'ground_instrument': 5,
          'approaches2d': 'ILS,RNAV',
          'approaches3d': '',
          'landings': 2,
          'takeoffs': 1,
        },
        {
          'id': 'fl-partial',
          'date': inDays(-2),
          'total_time': 60,
          'day_time': 60,
          'simulated_instrument': 30,
          'approaches3d': 'RNP',
          'landings': 3,
          'takeoffs': 4,
        },
        {
          'id': 'fl-draft',
          'date': inDays(-3),
          'approaches2d': 'ILS',
          'takeoffs': 5,
        },
      ]);
      insertRules([
        for (final metric in currencyMetrics)
          {
            'id': 'uc-$metric',
            'title': metric,
            'metric': metric,
            'period': 'allTime',
            'threshold': 100,
          },
      ]);
      final server = await start();

      final payload = payloadOf(await server.call('currency_status', {}));
      Map<String, dynamic> of(String metric) => rulesByMetric(payload)[metric]!;

      expect(of('totalTime')['current'], 3.0,
          reason: '180 minutes over two complete flights');
      expect(of('totalTime')['unit'], 'hours');
      expect(of('dayTime')['current'], 2.5, reason: '150 minutes');
      expect(of('nightTime')['current'], 0.5, reason: '30 minutes');
      // 20 + 10 + 5 actual, simulated and ground, then 30 simulated.
      expect(of('instrumentTime')['current'], 1.08);
      expect(of('approachCount')['current'], 4.0);
      expect(of('approachCount')['unit'], 'count');
      expect(of('landingCount')['current'], 5.0);
      expect(of('takeoffCount')['current'], 10.0);
      expect(of('flightCount')['current'], 3.0,
          reason: 'the app counts drafts as flights');
    });

    test('approaches are commas plus one per non-empty column, summed',
        () async {
      insertFlights(dbPath, [
        {'id': 'fl-ils', 'date': inDays(-1), 'approaches2d': 'ILS,RNAV'},
        {
          'id': 'fl-trailing',
          'date': inDays(-2),
          'approaches2d': 'ILS, RNAV, '
        },
        {'id': 'fl-empty', 'date': inDays(-3), 'approaches2d': ''},
        {'id': 'fl-null', 'date': inDays(-4)},
        {'id': 'fl-3d', 'date': inDays(-5), 'approaches3d': 'RNP'},
      ]);
      insertRules([
        {
          'id': 'uc-approaches',
          'title': 'Approaches',
          'metric': 'approachCount',
          'period': 'allTime',
          'threshold': 3,
          'type': 'limit',
        },
      ]);
      final server = await start();

      final payload = payloadOf(await server.call('currency_status', {}));
      // 2 + 3 + 0 + 0 + 1: the trailing comma is a third item, exactly as the
      // app counts it, and NULL or empty columns contribute nothing.
      expect(rulesById(payload)['uc-approaches']!['current'], 6.0);
    });

    test('a requirement is exceeded when short, a limit when reached',
        () async {
      insertFlights(dbPath, [
        {'id': 'fl-today', 'date': inDays(0), 'total_time': 180},
      ]);
      insertRules([
        {
          'id': 'uc-short',
          'metric': 'totalTime',
          'period': 'allTime',
          'threshold': 90,
          'type': 'requirement',
        },
        {
          'id': 'uc-met',
          'metric': 'totalTime',
          'period': 'allTime',
          'threshold': 2,
          'type': 'requirement',
        },
        {
          'id': 'uc-limit-under',
          'metric': 'totalTime',
          'period': 'allTime',
          'threshold': 4,
          'type': 'limit',
        },
        {
          'id': 'uc-limit-at',
          'metric': 'totalTime',
          'period': 'allTime',
          'threshold': 3,
          'type': 'limit',
        },
        {
          'id': 'uc-limit-over',
          'metric': 'totalTime',
          'period': 'allTime',
          'threshold': 2,
          'type': 'limit',
        },
      ]);
      final server = await start();

      final payload = payloadOf(await server.call('currency_status', {}));
      final rules = rulesById(payload);

      // 3.0 hours flown in total.
      expect(rules['uc-short']!['current'], 3.0);
      expect(rules['uc-short']!['is_exceeded'], isTrue,
          reason: 'a requirement is exceeded when you are below it');
      expect(rules['uc-short']!['remaining'], 87.0);
      expect(rules['uc-short']!['over_by'], isNull);
      expect(rules['uc-short']!['progress'], 0.03);
      expect(rules['uc-short']!['rule_text'],
          'at least 90 hours of total time over all time');

      expect(rules['uc-met']!['is_exceeded'], isFalse);
      expect(rules['uc-met']!['remaining'], 0.0,
          reason: 'nothing more is needed once a requirement is met');
      expect(rules['uc-met']!['progress'], 1.0,
          reason: 'progress is clamped, the app shows 100 percent');

      expect(rules['uc-limit-under']!['is_exceeded'], isFalse);
      expect(rules['uc-limit-under']!['over_by'], 0.0);
      expect(rules['uc-limit-under']!['progress'], 0.75);
      expect(rules['uc-limit-under']!['rule_text'],
          'no more than 4 hours of total time over all time');
      // Exactly the threshold is over: the app uses >= for a limit.
      expect(rules['uc-limit-at']!['is_exceeded'], isTrue);
      expect(rules['uc-limit-at']!['over_by'], 0.0);
      expect(rules['uc-limit-over']!['is_exceeded'], isTrue);
      expect(rules['uc-limit-over']!['over_by'], 1.0);
    });

    test('a metric with no rule gets the raw total and says so', () async {
      insertFlights(dbPath, [
        {
          'id': 'fl-today',
          'date': inDays(0),
          'total_time': 120,
          'night_time': 30
        },
        {
          'id': 'fl-old',
          'date': inDays(-400),
          'total_time': 60,
          'night_time': 60
        },
      ]);
      insertRules([
        {
          'id': 'uc-total',
          'metric': 'totalTime',
          'period': 'allTime',
          'threshold': 100,
          'type': 'requirement',
        },
      ]);
      final server = await start();

      final asked = payloadOf(
          await server.call('currency_status', {'metric': 'nightTime'}));
      expect(asked['count'], 1);
      final unconfigured = asked['unconfigured'] as Map;
      expect(unconfigured['metric'], 'nightTime');
      expect(unconfigured['period'], 'rolling365');
      expect(unconfigured['current'], 0.5,
          reason: "30 night minutes in the last 365 days; the 400-day flight "
              'is outside it');
      expect(unconfigured['unit'], 'hours');
      expect(unconfigured['window'], {
        'from': formatCalendarDate(inDays(-364)),
        'to': formatCalendarDate(inDays(0)),
      });
      expect(unconfigured['note'], contains('no rule configured'));
      expect(unconfigured.containsKey('is_exceeded'), isFalse,
          reason: 'no rule means no pass or fail');

      // A different window for the same question.
      final allTime = payloadOf(await server.call(
          'currency_status', {'metric': 'nightTime', 'period': 'allTime'}));
      expect((allTime['unconfigured'] as Map)['current'], 1.5);

      // A metric that does have a rule gets no unconfigured block.
      final covered = payloadOf(
          await server.call('currency_status', {'metric': 'totalTime'}));
      expect(covered.containsKey('unconfigured'), isFalse);
    });

    test('matches the app: no owner filter, drafts counted', () async {
      insertFlights(dbPath, [
        {'id': 'fl-local', 'date': inDays(-1), 'total_time': 60},
        {
          'id': 'fl-other',
          'date': inDays(-2),
          'total_time': 60,
          'owner_id': 'someone-else',
        },
        {'id': 'fl-draft', 'date': inDays(-3)},
      ]);
      insertRules([
        {
          'id': 'uc-flights',
          'metric': 'flightCount',
          'period': 'allTime',
          'threshold': 100,
          'type': 'limit',
        },
      ]);
      final server = await start();

      final payload = payloadOf(await server.call('currency_status', {}));
      expect(rulesById(payload)['uc-flights']!['current'], 3.0,
          reason: 'the app counts every row, another owner and drafts '
              'included, so the pilot can reproduce this number in the app');
    });

    test('one unusable rule does not fail the others', () async {
      insertFlights(dbPath, [
        {'id': 'fl-today', 'date': inDays(0), 'total_time': 60},
      ]);
      insertRules([
        {
          'id': 'uc-bad-metric',
          'metric': 'nightHours',
          'period': 'rolling365',
          'threshold': 10,
        },
        {
          'id': 'uc-bad-period',
          'metric': 'totalTime',
          'period': 'rolling90',
          'threshold': 10,
        },
      ]);
      final server = await start();

      final result = await server.call('currency_status', {});
      expect(result.isError, isFalse, reason: '${result.payload}');
      final rules = rulesById(payloadOf(result));
      expect(rules['uc-bad-metric']!['error'],
          contains('unknown metric "nightHours"'));
      // An unknown period is all time, as in the app's switch default.
      expect(rules['uc-bad-period']!['current'], 1.0);
      expect(rules['uc-bad-period']!['window'], isNull);
    });

    test('rejects arguments it cannot apply', () async {
      final server = await start();

      final badMetric =
          await server.call('currency_status', {'metric': 'nightHours'});
      expect(badMetric.isError, isTrue);
      expect('${badMetric.payload}', contains('metric'));

      final badPeriod = await server.call(
          'currency_status', {'metric': 'nightTime', 'period': 'last_90_days'});
      expect(badPeriod.isError, isTrue);
      expect('${badPeriod.payload}', contains('period'));

      // A window with no metric to apply it to would be a silently dropped
      // argument.
      final orphan =
          await server.call('currency_status', {'period': 'rolling30'});
      expect(orphan.isError, isTrue);
      expect('${orphan.payload}', contains('period'));
    });
  });
}
