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

  test('serverVersion matches pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $serverVersion'));
  });
}
