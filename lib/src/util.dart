import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final RegExp _dateOnly = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$');

/// Converts a date-ish input into the unix epoch seconds the Falcon database
/// stores. Dates are interpreted in local time, matching the app: the `date`
/// column holds local midnight of the flight date.
///
/// [endOfDay] returns 23:59:59 of the same local day, useful for inclusive
/// upper bounds.
int? dateToEpoch(Object? value, {bool endOfDay = false}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;

  final match = _dateOnly.firstMatch(text);
  if (match != null) {
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final start = DateTime(year, month, day);
    // DateTime normalises out-of-range values (month 13 -> next January), so
    // reject anything that does not round-trip.
    if (start.year != year || start.month != month || start.day != day) {
      return null;
    }
    return _epochFor(start, endOfDay: endOfDay);
  }

  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final local = parsed.toLocal();
  return _epochFor(DateTime(local.year, local.month, local.day),
      endOfDay: endOfDay);
}

/// The only date form a read tool accepts, and the text every rejection names.
const String dateFormatHint = 'YYYY-MM-DD';

final RegExp _strictDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Parses a date argument for a read filter. Accepts exactly `YYYY-MM-DD` and
/// returns null for anything else: timestamps, compact forms, impossible
/// dates, blanks. A caller must treat null as a rejection, never as "no
/// filter", because dropping the filter turns a period answer into a career
/// answer.
///
/// [dateToEpoch] stays as it is for the write path, where a wider input form
/// is already part of the contract.
DateTime? parseCalendarDate(Object? value) {
  if (value is! String) return null;
  final match = _strictDate.firstMatch(value.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

/// Local midnight at the start of [day], as the `date` column stores it.
int epochForDayStart(DateTime day) =>
    DateTime(day.year, day.month, day.day).millisecondsSinceEpoch ~/ 1000;

/// Local midnight at the start of the day after [day]: the exclusive upper
/// bound that includes every row on [day].
int epochForDayAfter(DateTime day) =>
    DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch ~/ 1000;

/// [day] as `YYYY-MM-DD`, the form read filters accept and echo back.
String formatCalendarDate(DateTime day) {
  final year = day.year.toString().padLeft(4, '0');
  final month = day.month.toString().padLeft(2, '0');
  final date = day.day.toString().padLeft(2, '0');
  return '$year-$month-$date';
}

/// Named date windows a tool can ask for instead of doing its own arithmetic.
const List<String> datePresets = [
  'last_7_days',
  'last_30_days',
  'last_90_days',
  'this_month',
  'this_year',
  'last_year',
];

/// Resolves one of [datePresets] against [now]. Both bounds are inclusive
/// calendar dates, matching the app: a last-N-days window is today plus the
/// N-1 preceding dates. Returns null for an unknown preset.
({DateTime from, DateTime to})? resolveDatePreset(String preset,
    {required DateTime now}) {
  // Calendar arithmetic rather than Duration so a DST change cannot move a
  // boundary off midnight.
  return switch (preset) {
    'last_7_days' => (
        from: DateTime(now.year, now.month, now.day - 6),
        to: DateTime(now.year, now.month, now.day),
      ),
    'last_30_days' => (
        from: DateTime(now.year, now.month, now.day - 29),
        to: DateTime(now.year, now.month, now.day),
      ),
    'last_90_days' => (
        from: DateTime(now.year, now.month, now.day - 89),
        to: DateTime(now.year, now.month, now.day),
      ),
    'this_month' => (
        from: DateTime(now.year, now.month, 1),
        to: DateTime(now.year, now.month + 1, 0),
      ),
    'this_year' => (
        from: DateTime(now.year, 1, 1),
        to: DateTime(now.year, 12, 31),
      ),
    'last_year' => (
        from: DateTime(now.year - 1, 1, 1),
        to: DateTime(now.year - 1, 12, 31),
      ),
    _ => null,
  };
}

int _epochFor(DateTime start, {required bool endOfDay}) {
  if (!endOfDay) return start.millisecondsSinceEpoch ~/ 1000;
  // Calendar arithmetic rather than +24h so DST days stay at 23:59:59.
  final next = DateTime(start.year, start.month, start.day + 1);
  return next.millisecondsSinceEpoch ~/ 1000 - 1;
}

/// Formats epoch seconds as a local ISO-8601 string.
String epochToIso(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toIso8601String();

/// Current time as unix epoch seconds, matching the app's `created_at`/
/// `updated_at` columns.
int nowEpochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Coerces loose JSON input into an int without throwing.
int? asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) {
    return value == value.roundToDouble() ? value.toInt() : null;
  }
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Coerces loose JSON input into a double without throwing.
double? asDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    return double.tryParse(value.trim().replaceAll(',', '.'));
  }
  return null;
}

/// Coerces loose JSON input into a bool. Accepts real bools, 0/1 numbers and
/// the usual string spellings, because clients vary in how they encode flags.
bool? asBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return switch (value.trim().toLowerCase()) {
      'true' || '1' || 'yes' || 'y' || 'on' => true,
      'false' || '0' || 'no' || 'n' || 'off' => false,
      _ => null,
    };
  }
  return null;
}

/// Coerces loose JSON input into trimmed non-empty text, or null.
String? asText(Object? value) {
  if (value == null) return null;
  final text = (value is String ? value : value.toString()).trim();
  return text.isEmpty ? null : text;
}

/// Escapes LIKE wildcards so user input is matched literally. Use together
/// with `ESCAPE '\'` in the SQL.
String escapeLike(String value) =>
    value.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');

/// Audit log path for a database: `<db-name>.mcp_audit.jsonl` alongside it.
String auditPathFor(String dbPath) {
  final dir = p.dirname(dbPath);
  final base = p.basenameWithoutExtension(dbPath);
  final name = base.isEmpty ? p.basename(dbPath) : base;
  return p.join(dir, '$name.mcp_audit.jsonl');
}

/// Appends one JSON line to the audit log next to [dbPath]. Never throws:
/// auditing must not break a tool call that otherwise succeeded.
void appendAudit(String dbPath, Map<String, dynamic> entry) {
  try {
    final file = File(auditPathFor(dbPath));
    final line = jsonEncode(entry, toEncodable: (value) => value.toString());
    file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // Best effort only.
  }
}
