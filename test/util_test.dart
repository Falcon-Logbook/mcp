import 'dart:io';

import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('dateToEpoch', () {
    test('uses local midnight for a date-only value', () {
      final epoch = dateToEpoch('2026-10-27');
      final local = DateTime.fromMillisecondsSinceEpoch(epoch! * 1000);
      expect(local.hour, 0);
      expect(local.minute, 0);
      expect(local.year, 2026);
      expect(local.month, 10);
      expect(local.day, 27);
    });

    test('end of day is 23:59:59 on the same local day', () {
      final epoch = dateToEpoch('2026-10-27', endOfDay: true)!;
      expect(epoch - dateToEpoch('2026-10-27')!, 24 * 3600 - 1);
      final local = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
      expect(local.day, 27);
      expect(local.hour, 23);
      expect(local.minute, 59);
      expect(local.second, 59);
    });

    test('rejects out-of-range components instead of normalising them', () {
      expect(dateToEpoch('2026-10-32'), isNull);
      expect(dateToEpoch('2026-13-01'), isNull);
    });

    test('rejects empty and non-date input', () {
      expect(dateToEpoch(null), isNull);
      expect(dateToEpoch('   '), isNull);
      expect(dateToEpoch('not a date'), isNull);
      expect(dateToEpoch(1761408000), isNull);
    });

    test('accepts an ISO timestamp and keeps its local day', () {
      expect(dateToEpoch('2026-10-27T12:34:00'), dateToEpoch('2026-10-27'));
    });
  });

  group('parseCalendarDate', () {
    test('accepts exactly YYYY-MM-DD', () {
      // The result is the day's logbook-zone midnight (a TZDateTime), so the
      // fields and the resolved instant are what is asserted, not object
      // equality with a plain DateTime.
      for (final input in ['2025-01-31', ' 2025-01-31 ']) {
        final date = parseCalendarDate(input)!;
        expect([date.year, date.month, date.day], [2025, 1, 31]);
        expect(epochForDayStart(date),
            DateTime(2025, 1, 31).millisecondsSinceEpoch ~/ 1000);
      }
      expect(
          formatCalendarDate(parseCalendarDate('2025-01-05')!), '2025-01-05');
    });

    test('rejects every other form a read filter must not guess at', () {
      for (final bad in <Object?>[
        null,
        '',
        '   ',
        '2025',
        '20250101',
        '2025-13-01',
        '2025-02-30',
        '2025-1-31',
        '2026-10-26T20:00:00Z',
        1761408000,
      ]) {
        expect(parseCalendarDate(bad), isNull, reason: 'must reject $bad');
      }
    });

    test('day bounds are local midnight and the next local midnight', () {
      final day = DateTime(2025, 1, 5);
      final start =
          DateTime.fromMillisecondsSinceEpoch(epochForDayStart(day) * 1000);
      expect([start.year, start.month, start.day], [2025, 1, 5]);
      expect([start.hour, start.minute, start.second], [0, 0, 0]);
      final next =
          DateTime.fromMillisecondsSinceEpoch(epochForDayAfter(day) * 1000);
      expect([next.year, next.month, next.day], [2025, 1, 6]);
      expect([next.hour, next.minute], [0, 0]);
    });
  });

  group('resolveDatePreset', () {
    final now = DateTime(2026, 10, 28, 14, 37);

    String from(String preset) =>
        formatCalendarDate(resolveDatePreset(preset, now: now)!.from);
    String to(String preset) =>
        formatCalendarDate(resolveDatePreset(preset, now: now)!.to);

    test('last N days includes today and the N-1 dates before it', () {
      expect([from('last_7_days'), to('last_7_days')],
          ['2026-10-22', '2026-10-28']);
      expect([from('last_30_days'), to('last_30_days')],
          ['2026-09-29', '2026-10-28']);
      expect([from('last_90_days'), to('last_90_days')],
          ['2026-07-31', '2026-10-28']);
    });

    test('calendar presets cover the whole period, not a rolling window', () {
      expect(
          [from('this_month'), to('this_month')], ['2026-10-01', '2026-10-31']);
      expect(
          [from('this_year'), to('this_year')], ['2026-01-01', '2026-12-31']);
      expect(
          [from('last_year'), to('last_year')], ['2025-01-01', '2025-12-31']);
    });

    test('steps back over a month and a year boundary', () {
      final january = DateTime(2026, 1, 3, 9);
      expect(
          formatCalendarDate(
              resolveDatePreset('last_7_days', now: january)!.from),
          '2025-12-28');
      expect(
          formatCalendarDate(resolveDatePreset('this_month', now: january)!.to),
          '2026-01-31');
    });

    test('an unknown preset resolves to null rather than an empty window', () {
      expect(resolveDatePreset('last_6_months', now: now), isNull);
      expect(resolveDatePreset('2025', now: now), isNull);
    });
  });

  group('uuidV4', () {
    test('generates a lowercase RFC 4122 version 4 id', () {
      final id = uuidV4();
      expect(isUuidV4(id), isTrue, reason: id);
      expect(id, matches(RegExp(r'^[0-9a-f-]+$')));
      expect(id, hasLength(36));
    });

    test('does not repeat itself', () {
      final ids = {for (var i = 0; i < 200; i++) uuidV4()};
      expect(ids, hasLength(200));
    });

    test('rejects the id shapes the server used to write', () {
      for (final bad in [
        'mcp_fl_65ed958f79727',
        'default',
        '',
        '3F1A6C1E-9B2D-4A57-8F0C-2D1E3B4A5C6D',
        '3f1a6c1e-9b2d-1a57-8f0c-2d1e3b4a5c6d',
        '3f1a6c1e-9b2d-4a57-0f0c-2d1e3b4a5c6d',
        '3f1a6c1e-9b2d-4a57-8f0c-2d1e3b4a5c6',
      ]) {
        expect(isUuidV4(bad), isFalse, reason: 'must reject "$bad"');
      }
    });
  });

  group('canonicalClockTime', () {
    test('reads 1 to 4 digits by digit count and pads to HH:MM', () {
      expect(canonicalClockTime('9'), '09:00');
      expect(canonicalClockTime('09'), '09:00');
      expect(canonicalClockTime('930'), '09:30');
      expect(canonicalClockTime('0930'), '09:30');
      expect(canonicalClockTime('9:30'), '09:30');
      expect(canonicalClockTime('09:30'), '09:30');
      expect(canonicalClockTime(' 23:59 '), '23:59');
      expect(canonicalClockTime('0'), '00:00');
    });

    test('refuses anything that is not a 24-hour clock time', () {
      for (final bad in <Object?>[
        null,
        '',
        '   ',
        '9am',
        '0930am',
        '24:00',
        '09:60',
        '2400',
        '0960',
        '12345',
        '1:5',
        '09:3',
        ':30',
        '-1',
        930,
      ]) {
        expect(canonicalClockTime(bad), isNull, reason: 'must reject $bad');
      }
    });
  });

  group('coercion', () {
    test('asBool understands bools, numbers and strings', () {
      expect(asBool(true), isTrue);
      expect(asBool('false'), isFalse);
      expect(asBool('TRUE'), isTrue);
      expect(asBool(0), isFalse);
      expect(asBool(1), isTrue);
      expect(asBool('maybe'), isNull);
      expect(asBool(null), isNull);
    });

    test('asInt rejects fractional numbers', () {
      expect(asInt(42), 42);
      expect(asInt('42'), 42);
      expect(asInt(42.0), 42);
      expect(asInt(42.5), isNull);
      expect(asInt(''), isNull);
      expect(asInt(null), isNull);
    });

    test('asDouble accepts comma decimals', () {
      expect(asDouble('1,5'), 1.5);
      expect(asDouble(2), 2.0);
      expect(asDouble('x'), isNull);
    });

    test('asText trims and treats blanks as absent', () {
      expect(asText('  VH-XZO '), 'VH-XZO');
      expect(asText('   '), isNull);
      expect(asText(7), '7');
      expect(asText(null), isNull);
    });

    test('escapeLike neutralises wildcards', () {
      expect(escapeLike('50%_off'), '50\\%\\_off');
      expect(escapeLike(r'back\slash'), r'back\\slash');
      expect(escapeLike('YSSY'), 'YSSY');
    });
  });

  group('auditPathFor', () {
    test('sits next to the database and keeps no sqlite extension', () {
      expect(
        auditPathFor('/home/pilot/Documents/Falcon/falcon_db.sqlite'),
        '/home/pilot/Documents/Falcon/falcon_db.mcp_audit.jsonl',
      );
    });

    test('handles a database name without extension', () {
      expect(auditPathFor('/data/falcondb'), '/data/falcondb.mcp_audit.jsonl');
    });

    test('does not treat a dotted directory as the extension', () {
      expect(
        auditPathFor('/home/pilot/my.logbook/falcon_db.sqlite'),
        '/home/pilot/my.logbook/falcon_db.mcp_audit.jsonl',
      );
    });
  });

  group('isoInstantToEpoch', () {
    test('parses the form reads render, with either offset spelling', () {
      expect(isoInstantToEpoch('2026-10-26T13:00:00.000+1100'), 1792980000);
      expect(isoInstantToEpoch('2026-10-26T13:00:00+11:00'), 1792980000);
      expect(isoInstantToEpoch('2023-11-14T22:15:00.000Z'), 1700000100);
    });

    test('round-trips the text epochToIso renders', () {
      expect(isoInstantToEpoch(epochToIso(1700000100)), 1700000100);
      expect(isoInstantToEpoch(epochToIso(1792980000)), 1792980000);
    });

    test('the same instant in different offsets parses alike', () {
      expect(
        isoInstantToEpoch('2026-10-26T02:00:00.000Z'),
        isoInstantToEpoch('2026-10-26T13:00:00.000+1100'),
      );
    });

    test('refuses values that do not name one stored instant', () {
      expect(isoInstantToEpoch('2026-10-26'), isNull);
      expect(isoInstantToEpoch('2026-10-26T13:00:00'), isNull);
      expect(isoInstantToEpoch('2026-02-30T13:00:00.000+1100'), isNull);
      expect(isoInstantToEpoch('2026-10-26T24:00:00.000+1100'), isNull);
      expect(isoInstantToEpoch('2026-10-26T13:00:00.500+1100'), isNull);
      expect(isoInstantToEpoch('2026-10-26T13:00:00.000+2500'), isNull);
      expect(isoInstantToEpoch('1761438000'), isNull);
      expect(isoInstantToEpoch(1761438000), isNull);
      expect(isoInstantToEpoch('  '), isNull);
    });
  });

  test('serverVersion matches pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $serverVersion'));
  });
}
