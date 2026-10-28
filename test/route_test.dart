import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:test/test.dart';

/// The app's rule, mirrored from `parseRouteString` and its tests
/// (`app/test/utils/flight_time_utils_test.dart`). A read answer that calls a
/// description a route would put a flight at the wrong airport, so the accepted
/// shape is pinned here case by case.
void main() {
  group('parseRoute', () {
    test('parses a pair split on space dash space', () {
      final route = parseRoute('NZWN - NZAA')!;
      expect(route.departure, 'NZWN');
      expect(route.arrival, 'NZAA');
    });

    test('parses three-letter IATA pairs too', () {
      final route = parseRoute('SYD - ZQN')!;
      expect(route.departure, 'SYD');
      expect(route.arrival, 'ZQN');
    });

    test('keeps the case it was written in, as the app does', () {
      final route = parseRoute('yssy - nzqn')!;
      expect(route.departure, 'yssy');
      expect(route.arrival, 'nzqn');
    });

    test('trims each segment, so an extra space is not a second code', () {
      final parsed = parseRoute('YSSY  - NZQN')!;
      expect(parsed.departure, 'YSSY');
      expect(parsed.arrival, 'NZQN');
    });

    test('treats anything without the spacing as a description', () {
      for (final text in [
        'YSSY-NZQN',
        'YSSY -NZQN',
        'YSSY- NZQN',
        'YSSY – NZQN', // en dash, not the app's separator
        'Some route description',
        'YSSY',
        '',
        '   ',
        'YSSY - NZQN - YBBN',
        'YSSY - ',
        ' - NZQN',
        ' - ',
        'YS - NZ',
        'YSSYY - NZQNX',
      ]) {
        expect(parseRoute(text), isNull, reason: 'must not parse "$text"');
      }
    });

    test('requires equal-length segments', () {
      expect(parseRoute('YSSY - NZQ'), isNull);
      expect(parseRoute('YS - YSSY'), isNull);
    });

    test('returns null for a null route', () {
      expect(parseRoute(null), isNull);
    });

    test('a pair with five-character codes is a description', () {
      // 5 characters is outside the app's 3 to 4 range even when both sides
      // match, so the app shows it as text and so does this server.
      expect(parseRoute('YSSYY - NZQNX'), isNull);
    });
  });
}
