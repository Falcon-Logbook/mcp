import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Expiry reads: status computed at read time, thresholds from settings with the
/// 90/30 fallback, overdue rows included by default. The numbers here are the
/// ones the app's expiry page shows for the same rows.
///
/// Day counts are whole calendar days in the logbook zone, so a DST change
/// cannot stretch or shrink them; the one-day tolerance below is only for a
/// run that crosses local midnight between computing the fixtures and asking
/// the server. Filter boundaries are checked against the days the server
/// itself reports, and fixed-date counts are asserted exactly in the pure
/// group below.
void main() {
  group('expiry status', () {
    final today = DateTime(2026, 10, 28);

    test('days until due ignores the time of day', () {
      expect(daysUntilDue(DateTime(2026, 10, 28), today), 0);
      expect(daysUntilDue(DateTime(2026, 10, 29), today), 1);
      expect(daysUntilDue(DateTime(2026, 10, 27), today), -1);
      // The app's add dialog seeds due_date with now + 365 days, so the stored
      // value carries a time of day.
      expect(daysUntilDue(DateTime(2027, 10, 28, 14, 32, 11), today), 365);
      expect(daysUntilDue(DateTime(2027, 10, 29, 0, 0, 1), today), 366);
    });

    test('status thresholds are inclusive of the threshold day', () {
      // Defaults are 90 green and 30 orange.
      expect(expiryStatusForDays(29), 'red');
      expect(expiryStatusForDays(30), 'orange');
      expect(expiryStatusForDays(89), 'orange');
      expect(expiryStatusForDays(90), 'green');
      // Overdue and due today are both red.
      expect(expiryStatusForDays(-1), 'red');
      expect(expiryStatusForDays(-365), 'red');
      expect(expiryStatusForDays(0), 'red');
    });

    test('configured thresholds replace the defaults', () {
      expect(expiryStatusForDays(20, greenThreshold: 45, orangeThreshold: 20),
          'orange');
      expect(expiryStatusForDays(19, greenThreshold: 45, orangeThreshold: 20),
          'red');
      expect(expiryStatusForDays(45, greenThreshold: 45, orangeThreshold: 20),
          'green');
    });
  });

  group('list_expiries', () {
    late Directory tempDir;
    late String dbPath;
    final today = DateTime.now();

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('falcon_mcp_expiry_test');
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

    List<String> idsOf(Map<String, dynamic> payload) => [
          for (final row in payload['expiries'] as List)
            (row as Map)['id'] as String,
        ];

    /// [offset] days from today at local midnight, the way the app stores a due
    /// date.
    DateTime inDays(int offset) =>
        DateTime(today.year, today.month, today.day + offset);

    void insertExpiries(List<Map<String, Object?>> rows) {
      withFixtureDb(dbPath, (db) {
        for (final row in rows) {
          final values = <String, Object?>{
            for (final entry in row.entries)
              entry.key: entry.value is DateTime
                  ? epochForDayStart(entry.value as DateTime)
                  : entry.value,
          };
          db.execute(
            'INSERT INTO expiries (${values.keys.join(', ')}) '
            'VALUES (${List.filled(values.length, '?').join(', ')})',
            values.values.toList(),
          );
        }
      });
    }

    void insertSettings({
      required int green,
      required int orange,
      String? owner,
      int? updatedAt,
    }) {
      withFixtureDb(dbPath, (db) {
        db.execute(
          'INSERT INTO expiry_settings '
          '(id, green_threshold, orange_threshold, owner_id, updated_at) '
          'VALUES (?, ?, ?, ?, ?)',
          [uuidV4(), green, orange, owner, updatedAt],
        );
      });
    }

    test(
        'computes status and days with the 90/30 fallback and sorts by due '
        'date', () async {
      insertExpiries([
        {
          'id': 'ex-medical',
          'name': 'Class 1 Medical',
          'due_date': inDays(200)
        },
        {'id': 'ex-asic', 'name': 'ASIC', 'due_date': inDays(0)},
        {'id': 'ex-licence', 'name': 'Licence', 'due_date': inDays(35)},
        {'id': 'ex-rating', 'name': 'Type rating', 'due_date': inDays(-40)},
        {'id': 'ex-ifr', 'name': 'Instrument rating', 'due_date': inDays(95)},
      ]);
      final server = await start();

      final payload = payloadOf(await server.call('list_expiries', {}));
      // No expiry_settings row: the app falls back to 90 green and 30 orange.
      expect(payload['thresholds'],
          {'green': 90, 'orange': 30, 'source': 'defaults'});
      expect(payload['checked_on'], formatCalendarDate(today));
      expect(payload['include_past'], isTrue);
      expect(payload['due_within_days'], isNull);
      expect(payload['count'], 5);
      expect(payload['total'], 5);

      final rows = (payload['expiries'] as List).cast<Map<String, dynamic>>();
      expect(
        [for (final row in rows) row['id']],
        ['ex-rating', 'ex-asic', 'ex-licence', 'ex-ifr', 'ex-medical'],
        reason: 'soonest first, with the overdue row at the top',
      );
      expect(
        [for (final row in rows) row['due_date']],
        [
          for (final offset in [-40, 0, 35, 95, 200])
            formatCalendarDate(inDays(offset)),
        ],
        reason: 'the local date, not the ISO timestamp the column holds',
      );
      expect(
        [for (final row in rows) row['days_remaining']],
        [
          closeTo(-40, 1),
          closeTo(0, 1),
          closeTo(35, 1),
          closeTo(95, 1),
          closeTo(200, 1),
        ],
      );
      expect(
        [for (final row in rows) row['status']],
        ['red', 'red', 'orange', 'green', 'green'],
        reason: 'overdue is red, due today is red, 35 is below 90, 95 and 200 '
            'are green',
      );
    });

    test('thresholds come from expiry_settings, local row first', () async {
      insertExpiries([
        {'id': 'ex-a', 'name': 'A', 'due_date': inDays(5)},
        {'id': 'ex-b', 'name': 'B', 'due_date': inDays(15)},
        {'id': 'ex-c', 'name': 'C', 'due_date': inDays(45)},
      ]);
      // A second device's row is older and stricter; the local row must win.
      insertSettings(green: 5, orange: 1, owner: 'someone-else', updatedAt: 1);
      insertSettings(green: 40, orange: 10, updatedAt: 2);
      final server = await start();

      final payload = payloadOf(await server.call('list_expiries', {}));
      expect(payload['thresholds'],
          {'green': 40, 'orange': 10, 'source': 'settings'});
      expect(
        [
          for (final row in payload['expiries'] as List)
            ((row as Map)['id'], row['status'])
        ],
        [('ex-a', 'red'), ('ex-b', 'orange'), ('ex-c', 'green')],
        reason: 'with the 90/30 defaults the same rows would be '
            'red, red, orange',
      );
    });

    test(
        'due_within_days counts forward from the reported days and '
        'include_past keeps the overdue rows', () async {
      insertExpiries([
        {'id': 'ex-overdue', 'name': 'Overdue', 'due_date': inDays(-40)},
        {'id': 'ex-exactly', 'name': 'Exactly', 'due_date': inDays(30)},
        {'id': 'ex-later', 'name': 'Later', 'due_date': inDays(400)},
      ]);
      final server = await start();

      final all = payloadOf(await server.call('list_expiries', {}));
      final reported = {
        for (final row in all['expiries'] as List)
          (row as Map)['id'] as String: row['days_remaining'] as int,
      };
      // The overdue row satisfies "due within 30 days" only while past rows are
      // included, and it sorts first.
      final within = payloadOf(
          await server.call('list_expiries', {'due_within_days': 30}));
      expect(within['due_within_days'], 30);
      expect(idsOf(within), ['ex-overdue', 'ex-exactly']);
      expect(reported['ex-overdue'], lessThan(0));

      // The boundary is the reported day count itself: N is included, N-1 is
      // not. Deriving N from the response keeps this honest across a DST change.
      final boundary = reported['ex-exactly']!;
      expect(
          idsOf(payloadOf(await server
              .call('list_expiries', {'due_within_days': boundary}))),
          contains('ex-exactly'));
      expect(
          idsOf(payloadOf(await server
              .call('list_expiries', {'due_within_days': boundary - 1}))),
          isNot(contains('ex-exactly')));

      final noPast = payloadOf(await server.call(
          'list_expiries', {'due_within_days': 30, 'include_past': false}));
      expect(idsOf(noPast), ['ex-exactly']);
      expect(noPast['include_past'], isFalse);
    });

    test('filters by owner and pages with limit', () async {
      insertExpiries([
        {'id': 'ex-local', 'name': 'Local', 'due_date': inDays(1)},
        {
          'id': 'ex-shared',
          'name': 'Shared',
          'due_date': inDays(2),
          'owner_id': 'someone-else',
        },
        {'id': 'ex-third', 'name': 'Third', 'due_date': inDays(3)},
      ]);
      final server = await start();

      final local = payloadOf(await server.call('list_expiries', {}));
      expect(idsOf(local), ['ex-local', 'ex-third']);

      final shared = payloadOf(
          await server.call('list_expiries', {'include_shared': true}));
      expect(idsOf(shared), ['ex-local', 'ex-shared', 'ex-third']);

      final page = payloadOf(await server.call('list_expiries', {'limit': 1}));
      expect(page['count'], 1);
      expect(page['total'], 2,
          reason: 'total counts every local row that matched, not the page');
      expect(idsOf(page), ['ex-local']);
    });

    test('rejects arguments it cannot apply', () async {
      final server = await start();

      final negative =
          await server.call('list_expiries', {'due_within_days': -1});
      expect(negative.isError, isTrue);
      expect('${negative.payload}', contains('due_within_days'));

      final zeroLimit = await server.call('list_expiries', {'limit': 0});
      expect(zeroLimit.isError, isTrue);
      expect('${zeroLimit.payload}', contains('limit'));

      final stale = await server.call('list_expiries', {'dueWithinDays': 30});
      expect(stale.isError, isTrue);
      expect('${stale.payload}', contains('dueWithinDays'));
    });
  });
}
