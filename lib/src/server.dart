import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'config.dart';
import 'db.dart';
import 'util.dart';

// ============================================================
// Field metadata
// ============================================================

enum _Kind { text, integer, real, boolean, date, clock }

/// One writable column: how to coerce it and how to advertise it to clients.
class _Column {
  const _Column(this.name, this.kind, {this.min, this.max, this.note});

  final String name;
  final _Kind kind;
  final num? min;
  final num? max;
  final String? note;

  JsonSchema get schema => switch (kind) {
        _Kind.text => JsonSchema.string(description: note),
        _Kind.integer => JsonSchema.integer(
            description: note,
            minimum: min?.toInt(),
            maximum: max?.toInt(),
          ),
        _Kind.real =>
          JsonSchema.number(description: note, minimum: min, maximum: max),
        _Kind.boolean => JsonSchema.boolean(description: note),
        _Kind.date => JsonSchema.string(description: note, format: 'date'),
        // No pattern: the shapes accepted are wider than any single regex a
        // client could read, and the SDK enforces a pattern before the tool
        // runs, which would turn a valid 930 into a validation failure.
        _Kind.clock => JsonSchema.string(description: note),
      };
}

const _flightColumns = <_Column>[
  _Column('date', _Kind.date,
      note: 'Flight date as YYYY-MM-DD (local). Required when creating.'),
  _Column('day_order', _Kind.integer,
      min: 0, note: 'Order within the day; 0 is first.'),
  _Column('aircraft_id', _Kind.text,
      note:
          'Aircraft row id. Derived automatically from aircraft_registration when it matches.'),
  _Column('aircraft_registration', _Kind.text,
      note:
          'Registration as displayed, e.g. VH-XZO. Matched against the aircraft table to set aircraft_id.'),
  _Column('flight_type', _Kind.text, note: "'route' or 'details'."),
  _Column('crew_role', _Kind.text,
      note: "'pilotInCommand', 'copilot' or 'student'."),
  _Column('crew_member_id', _Kind.text,
      note:
          'Crew row id. Derived automatically from crew_members_name when it matches.'),
  _Column('crew_members_name', _Kind.text,
      note: 'Other crew member display name.'),
  _Column('route', _Kind.text, note: 'Route text, e.g. "YSSY - NZQN".'),
  _Column('flight_number', _Kind.text),
  _Column('total_time', _Kind.integer,
      min: 0,
      max: maxFlightMinutes,
      note: 'Minutes, 1 to $maxFlightMinutes (8760 hours). Omit it to create a '
          'draft, or pass draft: true on an update to clear it.'),
  _Column('day_time', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('night_time', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('calc_time_mode', _Kind.text,
      note: "'utc', 'local', 'time' or 'hobbsTacho'."),
  _Column('time_start', _Kind.clock,
      note: 'Block-off clock time, 24-hour. Accepts 9, 930, 9:30, 09:30 or '
          '0930 and stores HH:MM.'),
  _Column('time_stop', _Kind.clock,
      note: 'Block-on clock time, 24-hour. Accepts 9, 930, 9:30, 09:30 or '
          '0930 and stores HH:MM.'),
  _Column('hobbs_start', _Kind.real, min: 0),
  _Column('hobbs_stop', _Kind.real, min: 0),
  _Column('actual_instrument', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('simulated_instrument', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('ground_instrument', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('icus_day_time', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('icus_night_time', _Kind.integer,
      min: 0, max: maxFlightMinutes, note: 'Minutes.'),
  _Column('approaches2d', _Kind.text),
  _Column('approaches3d', _Kind.text),
  _Column('approach_details', _Kind.text),
  _Column('takeoffs', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('landings', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('takeoff_day', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('takeoff_night', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('landing_day', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('landing_night', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('water_takeoffs', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('water_landings', _Kind.integer, min: 0, max: maxFlightCount),
  _Column('is_simulator', _Kind.boolean),
  _Column('is_ifr', _Kind.boolean),
  _Column('custom_columns', _Kind.text,
      note: 'JSON blob for user-defined columns.'),
];

const _aircraftColumns = <_Column>[
  _Column('type', _Kind.text, note: 'Aircraft type, e.g. B738.'),
  _Column('country_code', _Kind.text,
      note: "Registration country code, e.g. VH. Empty for none."),
  _Column('registration', _Kind.text,
      note: 'Bare registration without country code, e.g. XZO.'),
  _Column('multi_engine', _Kind.boolean),
  _Column('ifr', _Kind.boolean),
  _Column('complex', _Kind.boolean),
  _Column('pressurised', _Kind.boolean),
  _Column('tailwheel', _Kind.boolean),
  _Column('simulator', _Kind.boolean),
  _Column('helicopter', _Kind.boolean),
  _Column('float_plane', _Kind.boolean),
  _Column('archived', _Kind.boolean),
];

const _crewColumns = <_Column>[
  _Column('name', _Kind.text,
      note:
          'Display name. Derived from first_name and last_name when omitted.'),
  _Column('first_name', _Kind.text),
  _Column('last_name', _Kind.text),
  _Column('note', _Kind.text),
  _Column('archived', _Kind.boolean),
];

const _customAirportColumns = <_Column>[
  _Column('icao', _Kind.text, note: '4-letter ICAO code.'),
  _Column('iata', _Kind.text),
  _Column('name', _Kind.text, note: 'Airport name. Required when creating.'),
  _Column('city', _Kind.text),
  _Column('subd', _Kind.text, note: 'State or subdivision.'),
  _Column('country', _Kind.text),
  _Column('lat', _Kind.real, min: -90, max: 90),
  _Column('lon', _Kind.real, min: -180, max: 180),
  _Column('elevation', _Kind.integer, note: 'Feet.'),
  _Column('tz', _Kind.text, note: 'IANA timezone, e.g. Australia/Sydney.'),
];

const _savedRouteColumns = <_Column>[
  _Column('flight_number', _Kind.text),
  _Column('departure_icao', _Kind.text),
  _Column('arrival_icao', _Kind.text),
  _Column('distance_nm', _Kind.real, min: 0),
];

const _flightSettingsColumns = <_Column>[
  _Column('pilot_name', _Kind.text),
  _Column('default_flight_type', _Kind.text, note: "'route' or 'details'."),
  _Column('date_format', _Kind.text, note: 'e.g. dd mmm yyyy.'),
  _Column('flight_time_format', _Kind.text,
      note: "'hhmm', 'decimal1' or 'decimal2'."),
  _Column('calculate_time_mode', _Kind.text,
      note: "'utc', 'local', 'time' or 'hobbsTacho'."),
  _Column('logbook_country', _Kind.text, note: "'AU', 'NZ' or empty for none."),
  _Column('show_summary_card', _Kind.boolean),
  _Column('show_day_night', _Kind.boolean),
  _Column('show_routes_in_wizard', _Kind.boolean),
  _Column('show_logbook_view', _Kind.boolean),
  _Column('show_flight_number', _Kind.boolean),
];

const _flightTypes = {'route', 'details'};
const _timeFormats = {'hhmm', 'decimal1', 'decimal2'};
const _calculateTimeModes = {'utc', 'local', 'time', 'hobbsTacho'};
const _crewRoles = {'pilotInCommand', 'copilot', 'student'};

/// Columns that hold a duration in whole minutes.
const Set<String> _minuteColumns = {
  'total_time',
  'day_time',
  'night_time',
  'actual_instrument',
  'simulated_instrument',
  'ground_instrument',
  'icus_day_time',
  'icus_night_time',
};

/// Time fields that also accept an `_hours` argument, converted once at the
/// boundary. The column itself keeps its minutes name.
const Map<String, String> _hoursAliases = {
  'total_time': 'total_time_hours',
  'day_time': 'day_time_hours',
  'night_time': 'night_time_hours',
};

/// Every response that carries a time or date field states its units here,
/// once per response rather than per row. `date` describes what a read
/// serialises, which is the local ISO-8601 string [epochToIso] renders, not the
/// epoch integer the column stores.
const Map<String, String> _units = {
  'time': 'minutes',
  'date': 'iso8601_local',
};

/// The columns a flight summary carries: what was flown, when, in what, with
/// whom and how long. Every key is present even when the value is null, so a
/// missing reading reads as "not recorded" rather than as a key the caller has
/// to know about.
const List<String> _slimFlightKeys = [
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
];

/// [row] as a flight read returns it: the twelve-field summary, or every column
/// when [full]. A column the live database does not have stays null rather than
/// disappearing from the row.
Map<String, dynamic> _flightView(Map<String, dynamic> row,
        {bool full = false}) =>
    full ? row : {for (final key in _slimFlightKeys) key: row[key]};

/// The `full` argument on the paged flight reads. The cost is stated here
/// because this is the argument a caller weighs.
JsonSchema get _fullFlightSchema => JsonSchema.boolean(
    description: 'Every column instead of the twelve-field summary, at about '
        'four times the tokens.');

/// The `limit` argument on the paged flight reads: 20 rows by default, 200 at
/// most, so the page size is honest and `has_more` says what is left.
JsonSchema get _flightLimitSchema => JsonSchema.integer(
    minimum: 1, maximum: 200, description: 'Default 20, maximum 200.');

/// Arguments that select the date window, shared by every filtered read.
const Set<String> _dateFilterKeys = {'date_from', 'date_to', 'period'};

/// Arguments that switch a read from local rows to all owners' rows.
const String _includeSharedKey = 'include_shared';

/// The filter arguments every flight read accepts.
const Set<String> _flightFilterKeys = {
  ..._dateFilterKeys,
  _includeSharedKey,
};

// ============================================================
// Errors, results, coercion
// ============================================================

/// A problem the caller can fix. Reported as an MCP tool error, not a crash.
class _ToolError implements Exception {
  _ToolError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A tool result as compact JSON: a client can pretty-print for a human, and an
/// agent reading a page of rows does not pay for indentation it cannot use.
TextContent _jsonContent(Object? value) => TextContent(text: jsonEncode(value));

CallToolResult _ok(Object? value) =>
    CallToolResult.fromContent([_jsonContent(value)]);

CallToolResult _fail(String message) =>
    CallToolResult(content: [TextContent(text: message)], isError: true);

/// Coerces a JSON argument to the SQLite value for [column].
Object? _coerce(_Column column, Object? raw) {
  if (raw == null) return null;
  switch (column.kind) {
    case _Kind.text:
      return asText(raw);
    case _Kind.integer:
      final value = asInt(raw);
      if (value == null) {
        final alias = _hoursAliases[column.name];
        if (alias != null) {
          throw _ToolError(
              '${column.name} must be an integer number of minutes; '
              'use $alias to pass hours');
        }
        throw _ToolError(_minuteColumns.contains(column.name)
            ? '${column.name} must be an integer number of minutes'
            : '${column.name} must be an integer');
      }
      _checkRange(column, value);
      return value;
    case _Kind.real:
      final value = asDouble(raw);
      if (value == null) throw _ToolError('${column.name} must be a number');
      _checkRange(column, value);
      return value;
    case _Kind.boolean:
      final value = asBool(raw);
      if (value == null) throw _ToolError('${column.name} must be a boolean');
      return value ? 1 : 0;
    case _Kind.date:
      final value = dateToEpoch(raw);
      if (value == null) {
        throw _ToolError('${column.name} must be a date such as 2026-10-27');
      }
      return value;
    case _Kind.clock:
      final value = canonicalClockTime(raw);
      if (value == null) {
        throw _ToolError(
            '${column.name} must be a 24-hour clock time: 9, 930, 9:30, '
            '09:30 or 0930 (got "$raw")');
      }
      return value;
  }
}

void _checkRange(_Column column, num value) {
  if (column.min != null && value < column.min!) {
    throw _ToolError(
        '${column.name} must be >= ${column.min}${_unitSuffix(column)}');
  }
  if (column.max != null && value > column.max!) {
    throw _ToolError(
        '${column.name} must be <= ${column.max}${_unitSuffix(column)}');
  }
}

/// The unit a range error names, so `<= 525600` cannot be read as a count and
/// the pilot-facing limit is unambiguous.
String _unitSuffix(_Column column) {
  if (!_minuteColumns.contains(column.name)) return '';
  if (column.max == maxFlightMinutes) {
    return ' minutes (${maxFlightMinutes ~/ 60} hours)';
  }
  return ' minutes';
}

Map<String, JsonSchema> _propertiesOf(List<_Column> columns) => {
      for (final column in columns) column.name: column.schema,
    };

Set<String> _fieldNames(List<_Column> columns,
        [Set<String> extra = const {}]) =>
    {for (final column in columns) column.name, ...extra};

/// The subset of [columns] that exists in the live database, so a v18 file does
/// not advertise v19-only fields.
List<_Column> _supported(FalconDb db, String table, List<_Column> columns) {
  final available = db.columnsOf(table).toSet();
  return [
    for (final column in columns)
      if (available.contains(column.name)) column,
  ];
}

/// Rejects argument names this server does not write, so a stale field name
/// fails loudly instead of being silently dropped.
void _rejectUnknown(Map<String, dynamic> args, Set<String> allowed) {
  final unknown = args.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isEmpty) return;
  throw _ToolError(
    'Unknown field(s): ${unknown.join(', ')}. '
    'Supported fields: ${allowed.toList()..sort()}',
  );
}

/// Adds every argument present in [args] to the column/value lists.
/// Unknown-to-this-schema columns for the live table are rejected.
void _collect(
  FalconDb db,
  String table,
  List<_Column> spec,
  Map<String, dynamic> args,
  List<String> columns,
  List<Object?> values, {
  bool keepNulls = false,
}) {
  final available = db.columnsOf(table).toSet();
  for (final column in spec) {
    if (!args.containsKey(column.name)) continue;
    if (!available.contains(column.name)) {
      throw _ToolError(
        'This database (schema ${db.schemaVersion}) has no $table.${column.name} column. '
        'Supported: ${spec.map((c) => c.name).where(available.contains).join(', ')}',
      );
    }
    final raw = args[column.name];
    if (raw == null && !keepNulls) continue;
    columns.add(column.name);
    values.add(_coerce(column, raw));
  }
}

// ============================================================
// Read filters and paging
// ============================================================

/// Schema properties for the date window arguments, shared by filtered reads.
Map<String, JsonSchema> _dateFilterProperties() => {
      'date_from': JsonSchema.string(
          format: 'date',
          description: 'Inclusive start date, exactly YYYY-MM-DD.'),
      'date_to': JsonSchema.string(
          format: 'date',
          description: 'Inclusive end date, exactly YYYY-MM-DD.'),
      'period': JsonSchema.string(
        enumValues: datePresets,
        description: 'Named window instead of date_from/date_to, resolved on '
            'the server: ${datePresets.join(', ')}.',
      ),
    };

/// A date window resolved from arguments: WHERE terms, their parameters, and
/// the inclusive calendar bounds to echo back.
typedef _DateWindow = ({
  List<String> where,
  List<Object?> params,
  String? from,
  String? to,
});

DateTime? _readDate(Map<String, dynamic> args, String name) {
  final raw = args[name];
  if (raw == null) return null;
  final date = parseCalendarDate(raw);
  if (date == null) {
    throw _ToolError(
        '$name must be $dateFormatHint, for example 2025-01-31 (got "$raw")');
  }
  return date;
}

/// Builds the date predicate for a read. Anything that cannot be applied as
/// written is a tool error: a filter that silently does not apply reports
/// career totals as if they were the requested window.
_DateWindow _flightDateFilter(Map<String, dynamic> args,
    {required DateTime now}) {
  final where = <String>[];
  final params = <Object?>[];
  final period = asText(args['period']);

  if (period != null &&
      (args['date_from'] != null || args['date_to'] != null)) {
    throw _ToolError('Use either period or date_from/date_to, not both.');
  }

  DateTime? from;
  DateTime? to;
  if (period != null) {
    final resolved = resolveDatePreset(period, now: now);
    if (resolved == null) {
      throw _ToolError(
          'period must be one of ${datePresets.join(', ')} (got "$period")');
    }
    from = resolved.from;
    to = resolved.to;
  } else {
    from = _readDate(args, 'date_from');
    to = _readDate(args, 'date_to');
    if (from != null && to != null && from.isAfter(to)) {
      throw _ToolError('date_from (${formatCalendarDate(from)}) must not be '
          'after date_to (${formatCalendarDate(to)})');
    }
  }

  if (from != null) {
    where.add('date >= ?');
    params.add(epochForDayStart(from));
  }
  if (to != null) {
    // Half open: local midnight of the day after the last requested day.
    where.add('date < ?');
    params.add(epochForDayAfter(to));
  }
  return (
    where: where,
    params: params,
    from: from == null ? null : formatCalendarDate(from),
    to: to == null ? null : formatCalendarDate(to),
  );
}

/// The applied boundaries, echoed in the response so a caller can check them.
Map<String, dynamic> _rangeOf(_DateWindow window) =>
    {'from': window.from, 'to': window.to};

/// ` WHERE a AND b`, or nothing when [where] is empty.
String _whereSql(List<String> where) =>
    where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';

/// The app's local-rows rule: `owner_id` NULL or `'local'`. Empty when shared
/// rows are requested or the table has no owner column.
String _ownerClause(FalconDb db, String table, {required bool includeShared}) =>
    !includeShared && db.columnsOf(table).contains('owner_id')
        ? "(owner_id IS NULL OR owner_id = 'local')"
        : '';

/// Total rows matching the same WHERE, and whether the page leaves more
/// behind. [params] must not already carry the LIMIT/OFFSET values.
({int total, bool hasMore}) _pageInfo(
  FalconDb db,
  String fromWhere,
  List<Object?> params, {
  required int offset,
  required int count,
}) {
  final rows =
      db.query('SELECT COUNT(*) AS total FROM $fromWhere', List.of(params));
  final total = rows.isEmpty ? 0 : asInt(rows.first['total']) ?? 0;
  return (total: total, hasMore: offset + count < total);
}

// ============================================================
// Audit log
// ============================================================

class _Auditor {
  _Auditor(this.dbPath);

  final String dbPath;

  void record(
    String tool,
    Map<String, dynamic> args, {
    String? id,
    String? error,
  }) {
    appendAudit(dbPath, {
      'ts': DateTime.now().toUtc().toIso8601String(),
      'tool': tool,
      'args': args,
      'result': error == null ? 'ok' : 'error',
      if (id != null) 'id': id,
      if (error != null) 'error': error,
    });
  }
}

/// Runs a write callback in one transaction, auditing the outcome and converting
/// validation failures into tool errors instead of crashes.
///
/// The transaction is here rather than in each tool so every write is atomic: a
/// refusal part way through a body leaves no partial row behind, and a read the
/// body makes before writing sees the same snapshot as the write. Bodies that
/// open their own transaction nest as a savepoint.
CallToolResult _runWrite(
  FalconDb db,
  _Auditor auditor,
  String tool,
  Map<String, dynamic> args,
  Object? Function() body,
) {
  try {
    final result = db.transaction(body);
    final id = result is Map ? result['id'] : null;
    auditor.record(tool, args, id: id?.toString());
    return _ok(result);
  } on _ToolError catch (error) {
    auditor.record(tool, args, error: error.message);
    return _fail(error.message);
  } catch (error) {
    auditor.record(tool, args, error: error.toString());
    return _fail('$tool failed: $error');
  }
}

// ============================================================
// Domain helpers
// ============================================================

String _normalizeKey(String value) =>
    value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Display registration the app would show: country code plus registration,
/// unless the stored value already carries the country code.
String _displayRegistration(String? countryCode, String registration) {
  final code = (countryCode ?? '').trim();
  if (code.isEmpty ||
      registration.toUpperCase().startsWith(code.toUpperCase())) {
    return registration;
  }
  return '$code-$registration';
}

/// Finds the aircraft matching a registration written either bare (`XZO`) or
/// in display form (`VH-XZO`).
({String id, String display})? _matchAircraft(
    FalconDb db, String registration) {
  final wanted = _normalizeKey(registration);
  if (wanted.isEmpty) return null;
  final rows = db.query(
    'SELECT id, country_code, registration, archived FROM aircraft ORDER BY archived ASC',
  );
  for (final row in rows) {
    final reg = row['registration'] as String? ?? '';
    if (reg.isEmpty) continue;
    final display = _displayRegistration(row['country_code'] as String?, reg);
    if (_normalizeKey(reg) == wanted || _normalizeKey(display) == wanted) {
      return (id: row['id'] as String, display: display);
    }
  }
  return null;
}

/// Finds the crew member row matching a display name, preferring active ones.
String? _matchCrewMemberId(FalconDb db, String name) {
  final wanted = _normalizeKey(name);
  if (wanted.isEmpty) return null;
  final rows = db.query(
    'SELECT id, name, first_name, last_name, archived FROM crew_members ORDER BY archived ASC',
  );
  for (final row in rows) {
    final candidates = <String>[
      row['name'] as String? ?? '',
      '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}',
      '${row['last_name'] ?? ''} ${row['first_name'] ?? ''}',
    ];
    for (final candidate in candidates) {
      if (candidate.trim().isNotEmpty && _normalizeKey(candidate) == wanted) {
        return row['id'] as String;
      }
    }
  }
  return null;
}

/// Converts every `*_hours` argument to the minutes the column stores, so the
/// conversion happens once. Supplying both forms of one field is an error.
Map<String, dynamic> _minutesFromHours(Map<String, dynamic> args) {
  final out = Map<String, dynamic>.of(args);
  for (final entry in _hoursAliases.entries) {
    final alias = entry.value;
    if (!out.containsKey(alias)) continue;
    if (out[entry.key] != null) {
      throw _ToolError(
          'Supply either ${entry.key} (minutes) or $alias (hours), not both.');
    }
    final hours = asDouble(out.remove(alias));
    if (hours == null) throw _ToolError('$alias must be a number of hours');
    if (hours < 0) throw _ToolError('$alias must be >= 0');
    out[entry.key] = (hours * 60).round();
  }
  return out;
}

/// Applies `draft: true`: the flight's total time is cleared, which is the only
/// thing that makes it a draft. Supplying a total at the same time is a
/// contradiction, so it is refused rather than one of the two winning silently.
void _applyDraft(Map<String, dynamic> fields, Map<String, dynamic> args) {
  if (!args.containsKey('draft')) return;
  final draft = asBool(args['draft']);
  if (draft == null) throw _ToolError('draft must be true or false');
  if (!draft) return;
  if (fields.containsKey('total_time')) {
    throw _ToolError(
        'Supply either total_time or draft: true, not both. draft: true clears '
        'total_time and makes the flight a draft.');
  }
  fields['total_time'] = null;
}

/// Input schema for the flight write tools: the live columns, the `_hours`
/// aliases for the duration fields this database has, and `draft`.
Map<String, JsonSchema> _flightWriteProperties(FalconDb db) {
  final available = db.columnsOf('flights').toSet();
  return {
    ..._propertiesOf(_supported(db, 'flights', _flightColumns)),
    for (final entry in _hoursAliases.entries)
      if (available.contains(entry.key))
        entry.value: JsonSchema.number(
          minimum: 0,
          description: 'Hours, converted to ${entry.key} minutes.',
        ),
    'draft': JsonSchema.boolean(
      description: 'true clears total_time, which is what makes a flight a '
          'draft. Cannot be combined with total_time. Clients cannot send a '
          'null total_time, so this is the only way to clear a time.',
    ),
  };
}

/// The columns that describe the day/night split. A disagreement between them
/// is the one flight condition the app can never show, so it is checked on
/// write.
const Set<String> _splitFields = {'total_time', 'day_time', 'night_time'};

/// Builds the column/value map for a flight from tool arguments, deriving the
/// aircraft and crew foreign keys the app expects.
({Map<String, Object?> values, List<String> warnings}) _flightValues(
  FalconDb db,
  Map<String, dynamic> args,
) {
  final values = <String, Object?>{};
  final warnings = <String>[];
  _rejectUnknown(args,
      _fieldNames(_flightColumns, {'id', ..._hoursAliases.values, 'draft'}));
  final fields = _minutesFromHours(args);
  _applyDraft(fields, args);
  if (fields.containsKey('date') && asText(fields['date']) == null) {
    throw _ToolError('date cannot be empty');
  }
  final columns = <String>[];
  final raw = <Object?>[];
  _collect(db, 'flights', _flightColumns, fields, columns, raw,
      keepNulls: true);
  for (var i = 0; i < columns.length; i++) {
    values[columns[i]] = raw[i];
  }
  // 0 is not a draft to the app: it stores and displays a complete flight with
  // no duration, which the pilot cannot see and cannot fix from the logbook
  // list. Only an absent total_time makes a draft, so this is refused rather
  // than silently rewritten.
  if (values['total_time'] == 0) {
    throw _ToolError(
        'total_time must be at least 1 minute: the app stores 0 as a complete '
        'flight with no duration, not a draft. Pass draft: true to clear the '
        'time.');
  }

  if (fields.containsKey('aircraft_registration')) {
    final text = asText(fields['aircraft_registration']);
    if (text == null) {
      values['aircraft_registration'] = null;
      values['aircraft_id'] = null;
    } else {
      final match = _matchAircraft(db, text);
      if (match == null) {
        warnings.add(
            'No aircraft matched "$text"; the flight is not linked to an aircraft.');
        values['aircraft_registration'] = text;
        values['aircraft_id'] = null;
      } else {
        values['aircraft_registration'] = match.display;
        values['aircraft_id'] = match.id;
      }
    }
  } else if (fields.containsKey('aircraft_id')) {
    final aircraftId = asText(fields['aircraft_id']);
    if (aircraftId != null &&
        db.query(
            'SELECT id FROM aircraft WHERE id = ?', [aircraftId]).isEmpty) {
      throw _ToolError('Aircraft not found: $aircraftId');
    }
    values['aircraft_id'] = aircraftId;
  }

  if (fields.containsKey('crew_members_name')) {
    final name = asText(fields['crew_members_name']);
    if (name == null) {
      values['crew_members_name'] = null;
      values['crew_member_id'] = null;
    } else {
      values['crew_members_name'] = name;
      values['crew_member_id'] = _matchCrewMemberId(db, name);
    }
  } else if (fields.containsKey('crew_member_id')) {
    final crewId = asText(fields['crew_member_id']);
    if (crewId != null &&
        db.query(
            'SELECT id FROM crew_members WHERE id = ?', [crewId]).isEmpty) {
      throw _ToolError('Crew member not found: $crewId');
    }
    values['crew_member_id'] = crewId;
  }

  for (final entry in <String, Set<String>>{
    'flight_type': _flightTypes,
    'crew_role': _crewRoles,
    'calc_time_mode': _calculateTimeModes,
  }.entries) {
    final value = values[entry.key];
    if (value is String && value.isNotEmpty && !entry.value.contains(value)) {
      throw _ToolError(
        '${entry.key} must be one of ${entry.value.join(', ')} (got "$value")',
      );
    }
  }
  return (values: values, warnings: warnings);
}

/// What is wrong with a day/night split, as the app understands it: `total_time`
/// set and either one side equal to it or both sides summing to it is complete.
///
/// Returns null when the row is as complete as it needs to be.
String? _splitViolation(int? total, int? day, int? night) {
  if (total == null) {
    return day == null && night == null ? null : 'split_without_total';
  }
  if (day != null && night != null) return day + night == total ? null : 'sum';
  if (day != null) return day == total ? null : 'day';
  if (night != null) return night == total ? null : 'night';
  return null;
}

/// Checks the split [row] would have after a write.
///
/// Two sides that do not sum to the total is an error: no Falcon screen can
/// produce that row, and the app's own wizard refuses it. A one-sided split, or
/// a split with no total, is only a warning, because the app saves those itself
/// (a simulator session has no day/night split, and a draft can carry one side).
///
/// [before] and [written] let an update leave a pre-existing problem alone: an
/// agent fixing a route must not be forced to repair times it did not touch.
List<String> _checkDayNight(
  Map<String, Object?> row, {
  Map<String, dynamic>? before,
  Set<String>? written,
}) {
  final total = asInt(row['total_time']);
  final day = asInt(row['day_time']);
  final night = asInt(row['night_time']);
  final violation = _splitViolation(total, day, night);
  if (violation == null) return const [];
  if (before != null &&
      written != null &&
      !written.any(_splitFields.contains) &&
      _splitViolation(asInt(before['total_time']), asInt(before['day_time']),
              asInt(before['night_time'])) ==
          violation) {
    return const [];
  }
  return switch (violation) {
    'sum' => throw _ToolError('day_time + night_time (${day! + night!}) must '
        'equal total_time ($total). The app cannot display a split that does '
        'not add up.'),
    'split_without_total' => [
        'day_time/night_time are set but total_time is not, so the app shows '
            'this flight as a draft.'
      ],
    'day' => [
        'day_time ($day) does not equal total_time ($total). The app stores '
            'this one-sided split as given.'
      ],
    _ => [
        'night_time ($night) does not equal total_time ($total). The app '
            'stores this one-sided split as given.'
      ],
  };
}

/// The flight row [id] as the read tools present it, or null when it is gone.
Map<String, dynamic>? _flightRow(FalconDb db, String id) {
  final rows = db.query('SELECT * FROM flights WHERE id = ?', [id]);
  return rows.isEmpty ? null : rows.first;
}

/// The next free `day_order` for the local day of [date], computed the way the
/// app computes it on save (`_nextDayOrderForDate`): the highest local order on
/// that day plus one, or 0 for the first flight of the day.
int _nextDayOrder(FalconDb db, int date) {
  final day = DateTime.fromMillisecondsSinceEpoch(date * 1000);
  final where = <String>['date >= ?', 'date < ?'];
  final owner = _ownerClause(db, 'flights', includeShared: false);
  if (owner.isNotEmpty) where.add(owner);
  final rows = db.query(
    'SELECT COALESCE(MAX(day_order), -1) + 1 AS next FROM flights'
    '${_whereSql(where)}',
    [epochForDayStart(day), epochForDayAfter(day)],
  );
  return rows.isEmpty ? 0 : asInt(rows.first['next']) ?? 0;
}

/// Whether [date] is still the local day [storedDate] represents. [storedDate]
/// is the `date` column as the row mapper renders it, local ISO text.
bool _sameLocalDay(Object? storedDate, int date) =>
    storedDate == epochToIso(date);

/// Records a sync tombstone so a deleted row is not resurrected by Postgres
/// sync, mirroring the app's delete path. No-op when no provider has synced.
void _recordTombstones(FalconDb db, String table, Object id) {
  if (!db.hasTable('sync_state') || !db.hasTable('sync_deletions')) return;
  final providers = db
      .query('SELECT DISTINCT provider FROM sync_state')
      .map((row) => row['provider'])
      .whereType<String>()
      .toSet();
  final now = nowEpochSeconds();
  for (final provider in providers) {
    db.execute(
      'INSERT INTO sync_deletions (sync_table, row_id, provider, created_at) VALUES (?, ?, ?, ?)',
      [table, id.toString(), provider, now],
    );
  }
}

Map<String, dynamic> _deleted(String table, Object id) => {
      'status': 'deleted',
      'id': id,
      'table': table,
    };

/// Inserts [fields] into [table], filling in any remaining writable columns
/// from [args] first.
void _insert(
  FalconDb db,
  String table,
  Map<String, Object?> fields,
  List<_Column> spec,
  Map<String, dynamic> args,
) {
  final columns = <String>[];
  final values = <Object?>[];
  _collect(
    db,
    table,
    [
      for (final column in spec)
        if (!fields.containsKey(column.name)) column
    ],
    args,
    columns,
    values,
  );
  for (var i = 0; i < columns.length; i++) {
    fields[columns[i]] = values[i];
  }
  db.execute(
    'INSERT INTO $table (${fields.keys.join(', ')}) VALUES (${List.filled(fields.length, '?').join(', ')})',
    fields.values.toList(),
  );
}

/// Strips a country-code prefix so the app's bare-registration form is stored.
String _bareRegistration(String registration, String countryCode) {
  final upper = registration.trim().toUpperCase();
  if (countryCode.isEmpty) return upper;
  final code = countryCode.toUpperCase();
  if (upper == code) return upper;
  if (upper.startsWith('$code-') || upper.startsWith('$code ')) {
    return upper.substring(code.length + 1).trim();
  }
  return upper;
}

/// The id a create should use. A caller-supplied id is accepted only when it is
/// a UUID v4 and unused: imports need stable ids, and substituting a fresh one
/// silently would defeat that.
String _createId(FalconDb db, String table, Map<String, dynamic> args) {
  final requested = asText(args['id']);
  if (requested == null) return uuidV4();
  if (!isUuidV4(requested)) {
    throw _ToolError(
        'id must be a UUID v4 (got "$requested"). Omit id to have one '
        'generated: the synced id columns are UUID, so any other shape cannot '
        'be pushed to the cloud.');
  }
  if (db.query('SELECT id FROM $table WHERE id = ?', [requested]).isNotEmpty) {
    throw _ToolError('A $table row with id $requested already exists.');
  }
  return requested;
}

/// `updated_at` for a row being created, when the live table has the column.
/// Without it a sync push keeps re-selecting the new row forever.
Map<String, Object?> _createdStamp(FalconDb db, String table) => {
      if (db.columnsOf(table).contains('updated_at'))
        'updated_at': nowEpochSeconds(),
    };

/// Optional id for a create tool: a UUID v4 the caller wants to keep.
JsonSchema get _createIdSchema => JsonSchema.string(
    description: 'Optional id for an import: a UUID v4 that must be unused. '
        'Omit it and one is generated.');

// ============================================================
// Server
// ============================================================

Future<void> runServer(String dbPath, {bool readonly = true}) async {
  final db = openDb(dbPath, readonly: readonly);

  final version = db.schemaVersion;
  if (version < minSchemaVersion || version > maxSchemaVersion) {
    db.close();
    throw FalconDbException(
      'Falcon DB schema version mismatch at $dbPath: found $version, '
      'supported $minSchemaVersion-$maxSchemaVersion. '
      'Update the Falcon app or this MCP server so they match.',
    );
  }

  final auditor = _Auditor(dbPath);

  final server = McpServer(
    const Implementation(name: 'falcon_mcp', version: serverVersion),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(
        resources: ServerCapabilitiesResources(),
        tools: ServerCapabilitiesTools(),
        prompts: ServerCapabilitiesPrompts(),
      ),
    ),
  );

  const readOnlyAnnotations = ToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    openWorldHint: false,
  );

  // ============================================================
  // READ TOOLS
  // ============================================================

  server.registerTool(
    'db_info',
    description:
        'Show database path, schema version, table list, and whether writes are enabled.',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, const {});
        return _ok({
          'path': dbPath,
          'schemaVersion': version,
          'supportedSchemaVersions': '$minSchemaVersion-$maxSchemaVersion',
          'readonly': readonly,
          'tables': db.tables,
        });
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('db_info failed: $error');
      }
    },
  );

  List<Map<String, dynamic>> describeTable(String table) => db.tableInfo(table);

  server.registerTool(
    'get_schema',
    description:
        'Describe database tables and columns (name, type, nullability, default, PK). Optionally filter to one table.',
    inputSchema: JsonSchema.object(properties: {
      'table':
          JsonSchema.string(description: 'Table name. Omit for all tables.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'table'});
        final only = asText(args['table']);
        if (only != null && !db.hasTable(only)) {
          return _fail(
              'Unknown table: $only. Known tables: ${db.tables.join(', ')}');
        }
        final tables = only != null ? [only] : db.tables;
        return _ok({for (final table in tables) table: describeTable(table)});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_schema failed: $error');
      }
    },
  );

  server.registerTool(
    'list_flights',
    description:
        'List flights, newest first (date, then day_order, then id). Times are '
        'minutes and dates come back as local ISO-8601 strings; filters take '
        'YYYY-MM-DD. Returns count (rows on this page), total (all matching '
        'rows), has_more, offset and the applied range. Each flight is a '
        'twelve-field summary unless full is true. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'limit': _flightLimitSchema,
      'offset': JsonSchema.integer(minimum: 0),
      'full': _fullFlightSchema,
      ..._dateFilterProperties(),
      'aircraft_registration': JsonSchema.string(),
      'flight_type': JsonSchema.string(),
      'crew_members_name': JsonSchema.string(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {
          'limit',
          'offset',
          'full',
          'aircraft_registration',
          'flight_type',
          'crew_members_name',
          ..._flightFilterKeys,
        });
        final limit = asInt(args['limit']) ?? 20;
        if (limit < 1) return _fail('limit must be >= 1');
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0');
        final full = asBool(args['full']) ?? false;
        final window = _flightDateFilter(args, now: DateTime.now());
        final where = [...window.where];
        final params = [...window.params];
        for (final filter in const [
          'aircraft_registration',
          'flight_type',
          'crew_members_name'
        ]) {
          final value = asText(args[filter]);
          if (value != null) {
            where.add('$filter = ?');
            params.add(value);
          }
        }
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        if (owner.isNotEmpty) where.add(owner);
        final fromWhere = 'flights${_whereSql(where)}';
        final rows = db.query(
            'SELECT * FROM $fromWhere '
            'ORDER BY date DESC, day_order DESC, id LIMIT ? OFFSET ?',
            [...params, limit, offset]);
        final page = _pageInfo(db, fromWhere, params,
            offset: offset, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'offset': offset,
          'range': _rangeOf(window),
          'units': _units,
          'flights': [for (final row in rows) _flightView(row, full: full)],
        });
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('list_flights failed: $error');
      }
    },
  );

  server.registerTool(
    'get_flight',
    description:
        'Get a single flight by id, with every column. Times are minutes and '
        'dates come back as local ISO-8601 strings. This is the detail call: '
        'use it when a summary row does not answer the question. Local rows '
        'only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'id': JsonSchema.string(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Allow a row owned by another device or account. Default false.'),
    }, required: [
      'id'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'id', _includeSharedKey});
        final id = asText(args['id']);
        if (id == null) return _fail('Missing or invalid id');
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM flights WHERE id = ?'
            '${owner.isEmpty ? '' : ' AND $owner'}',
            [id]);
        if (rows.isEmpty) return _fail('Flight not found: $id');
        return _ok({...rows.first, 'units': _units});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_flight failed: $error');
      }
    },
  );

  server.registerTool(
    'search_flights',
    description:
        'Search flights by free text (route, flight number, crew name, '
        'registration). Times are minutes and dates come back as local ISO-8601 '
        'strings; filters take YYYY-MM-DD. Returns count (rows on this page), '
        'total (all matching rows), has_more, offset and the applied range. '
        'Ordered newest first (date, then day_order, then id). Each flight is a '
        'twelve-field summary unless full is true. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'query': JsonSchema.string(),
      'limit': _flightLimitSchema,
      'offset': JsonSchema.integer(minimum: 0),
      'full': _fullFlightSchema,
      ..._dateFilterProperties(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }, required: [
      'query'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {
          'query',
          'limit',
          'offset',
          'full',
          ..._flightFilterKeys,
        });
        final text = asText(args['query']);
        if (text == null) return _fail('Missing or invalid query');
        final limit = asInt(args['limit']) ?? 20;
        if (limit < 1) return _fail('limit must be >= 1');
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0');
        final full = asBool(args['full']) ?? false;
        final like = '%${escapeLike(text)}%';
        final window = _flightDateFilter(args, now: DateTime.now());
        final where = <String>[
          "(route LIKE ? ESCAPE '\\' OR flight_number LIKE ? ESCAPE '\\' "
              "OR crew_members_name LIKE ? ESCAPE '\\' "
              "OR aircraft_registration LIKE ? ESCAPE '\\')",
          ...window.where,
        ];
        final params = <Object?>[
          like,
          like,
          like,
          like,
          ...window.params,
        ];
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        if (owner.isNotEmpty) where.add(owner);
        final fromWhere = 'flights WHERE ${where.join(' AND ')}';
        final rows = db.query(
            'SELECT * FROM $fromWhere '
            'ORDER BY date DESC, day_order DESC, id LIMIT ? OFFSET ?',
            [...params, limit, offset]);
        final page = _pageInfo(db, fromWhere, params,
            offset: offset, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'offset': offset,
          'range': _rangeOf(window),
          'units': _units,
          'flights': [for (final row in rows) _flightView(row, full: full)],
        });
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('search_flights failed: $error');
      }
    },
  );

  server.registerTool(
    'list_aircraft',
    description:
        'List aircraft, optionally including archived ones. Local rows only '
        'unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'include_archived': JsonSchema.boolean(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'include_archived', _includeSharedKey, 'limit'});
        final include = asBool(args['include_archived']) ?? false;
        final limit = asInt(args['limit']) ?? 200;
        final owner = _ownerClause(db, 'aircraft',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final where = [
          if (!include) 'archived = 0',
          if (owner.isNotEmpty) owner,
        ];
        final rows = db.query(
            'SELECT * FROM aircraft${_whereSql(where)} '
            'ORDER BY registration LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'aircraft': rows});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('list_aircraft failed: $error');
      }
    },
  );

  server.registerTool(
    'get_aircraft',
    description: 'Get aircraft by id. Local rows only unless include_shared '
        'is true.',
    inputSchema: JsonSchema.object(properties: {
      'id': JsonSchema.string(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Allow a row owned by another device or account. Default false.'),
    }, required: [
      'id'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'id', _includeSharedKey});
        final id = asText(args['id']);
        if (id == null) return _fail('Missing or invalid id');
        final owner = _ownerClause(db, 'aircraft',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM aircraft WHERE id = ?'
            '${owner.isEmpty ? '' : ' AND $owner'}',
            [id]);
        if (rows.isEmpty) return _fail('Aircraft not found: $id');
        return _ok(rows.first);
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_aircraft failed: $error');
      }
    },
  );

  server.registerTool(
    'list_airports',
    description: 'Search airports (built-in) by ICAO/IATA/name/city.',
    inputSchema: JsonSchema.object(properties: {
      'query': JsonSchema.string(),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'query', 'limit'});
        final limit = asInt(args['limit']) ?? 50;
        final text = asText(args['query']);
        if (text != null) {
          final like = '%${escapeLike(text)}%';
          final rows = db.query(
            "SELECT * FROM airports WHERE icao LIKE ? ESCAPE '\\' OR iata LIKE ? ESCAPE '\\' "
            "OR name LIKE ? ESCAPE '\\' OR city LIKE ? ESCAPE '\\' LIMIT ?",
            [like, like, like, like, limit],
          );
          return _ok({'count': rows.length, 'airports': rows});
        }
        final rows = db.query('SELECT * FROM airports LIMIT ?', [limit]);
        return _ok({'count': rows.length, 'airports': rows});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('list_airports failed: $error');
      }
    },
  );

  server.registerTool(
    'list_custom_airports',
    description: 'List user-defined custom airports. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {_includeSharedKey, 'limit'});
        final limit = asInt(args['limit']) ?? 200;
        final owner = _ownerClause(db, 'custom_airports',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM custom_airports'
            '${owner.isEmpty ? '' : ' WHERE $owner'} '
            'ORDER BY name LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'airports': rows});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('list_custom_airports failed: $error');
      }
    },
  );

  server.registerTool(
    'list_crew',
    description:
        'List crew members, optionally including archived ones. Local rows '
        'only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'include_archived': JsonSchema.boolean(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'include_archived', _includeSharedKey, 'limit'});
        final include = asBool(args['include_archived']) ?? false;
        final limit = asInt(args['limit']) ?? 200;
        final owner = _ownerClause(db, 'crew_members',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final where = [
          if (!include) 'archived = 0',
          if (owner.isNotEmpty) owner,
        ];
        final rows = db.query(
            'SELECT * FROM crew_members${_whereSql(where)} '
            'ORDER BY name LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'crew': rows});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('list_crew failed: $error');
      }
    },
  );

  server.registerTool(
    'list_saved_routes',
    description:
        'List saved routes. Local rows only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {_includeSharedKey, 'limit'});
        final limit = asInt(args['limit']) ?? 200;
        final owner = _ownerClause(db, 'saved_routes',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM saved_routes'
            '${owner.isEmpty ? '' : ' WHERE $owner'} '
            'ORDER BY flight_number LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'routes': rows});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('list_saved_routes failed: $error');
      }
    },
  );

  server.registerTool(
    'logbook_stats',
    description:
        'Aggregate logbook statistics. All times are minutes. flights counts '
        'every local row including drafts, flights_complete counts rows with a '
        'total time, and drafts counts the rest. Time and movement sums skip '
        'empty values. sim_flights and sim_minutes report the simulator part, '
        'which stays included in the other sums. Filters (date_from/date_to as '
        'YYYY-MM-DD, or period) apply to every number in the response, and the '
        'applied range is echoed back.',
    inputSchema: JsonSchema.object(properties: {
      ..._dateFilterProperties(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, _flightFilterKeys);
        final window = _flightDateFilter(args, now: DateTime.now());
        final where = [...window.where];
        final params = [...window.params];
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        if (owner.isNotEmpty) where.add(owner);
        final sql = 'SELECT COUNT(*) AS flights, '
            'COALESCE(SUM(CASE WHEN total_time IS NOT NULL THEN 1 ELSE 0 END), 0) AS flights_complete, '
            'COALESCE(SUM(CASE WHEN total_time IS NULL THEN 1 ELSE 0 END), 0) AS drafts, '
            'COALESCE(SUM(total_time), 0) AS total_minutes, '
            'COALESCE(SUM(night_time), 0) AS night_minutes, '
            'COALESCE(SUM(day_time), 0) AS day_minutes, '
            'COALESCE(SUM(landings), 0) AS landings, '
            'COALESCE(SUM(takeoffs), 0) AS takeoffs, '
            'COALESCE(SUM(CASE WHEN is_simulator = 1 THEN 1 ELSE 0 END), 0) AS sim_flights, '
            'COALESCE(SUM(CASE WHEN is_simulator = 1 THEN total_time ELSE 0 END), 0) AS sim_minutes '
            'FROM flights${_whereSql(where)}';
        final rows = db.query(sql, params);
        final stats = rows.isEmpty ? <String, dynamic>{} : rows.first;
        return _ok({
          ...stats,
          'range': _rangeOf(window),
          'units': _units,
        });
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('logbook_stats failed: $error');
      }
    },
  );

  server.registerTool(
    'get_flight_settings',
    description: 'Get flight settings (pilot name, formats, country, etc.).',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, const {});
        final rows = db.query('SELECT * FROM flights_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_flight_settings failed: $error');
      }
    },
  );

  server.registerTool(
    'get_app_settings',
    description: 'Get app settings (storage mode, theme, accent, etc.).',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, const {});
        final rows = db.query('SELECT * FROM app_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_app_settings failed: $error');
      }
    },
  );

  server.registerTool(
    'get_general_settings',
    description:
        'Get general settings (startup tab, language, coordinates format, etc.).',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, const {});
        final rows = db.query('SELECT * FROM general_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_general_settings failed: $error');
      }
    },
  );

  server.registerTool(
    'get_recent_logs',
    description: 'Read recent log entries for diagnostics.',
    inputSchema: JsonSchema.object(properties: {
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'limit'});
        final limit = asInt(args['limit']) ?? 50;
        final rows = db.query(
            'SELECT * FROM log_entries ORDER BY timestamp DESC, id DESC LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'logs': rows});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('get_recent_logs failed: $error');
      }
    },
  );

  server.registerTool(
    'find_missing_times',
    description:
        'Find flights with no total time (drafts) or no day/night split. Times '
        'are minutes and dates come back as local ISO-8601 strings. Each flight '
        'is a twelve-field summary unless full is true. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'limit': _flightLimitSchema,
      'full': _fullFlightSchema,
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'limit', 'full', _includeSharedKey});
        final limit = asInt(args['limit']) ?? 200;
        final full = asBool(args['full']) ?? false;
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
          'SELECT * FROM flights '
          'WHERE (total_time IS NULL OR (day_time IS NULL AND night_time IS NULL))'
          '${owner.isEmpty ? '' : ' AND $owner'} '
          'ORDER BY date DESC, day_order DESC, id LIMIT ?',
          [limit],
        );
        return _ok({
          'count': rows.length,
          'units': _units,
          'flights': [for (final row in rows) _flightView(row, full: full)],
        });
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('find_missing_times failed: $error');
      }
    },
  );

  server.registerTool(
    'dedupe_crew',
    description: 'Find crew members with duplicate normalized names. Local '
        'rows only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {_includeSharedKey});
        final owner = _ownerClause(db, 'crew_members',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM crew_members${owner.isEmpty ? '' : ' WHERE $owner'}');
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final row in rows) {
          final key = _normalizeKey(row['name'] as String? ?? '');
          if (key.isEmpty) continue;
          groups.putIfAbsent(key, () => []).add(row);
        }
        final duplicates = [
          for (final entry in groups.entries)
            if (entry.value.length > 1)
              {'name': entry.key, 'members': entry.value},
        ];
        return _ok({'groups': duplicates.length, 'duplicates': duplicates});
      } on _ToolError catch (error) {
        return _fail(error.message);
      } catch (error) {
        return _fail('dedupe_crew failed: $error');
      }
    },
  );

  // ============================================================
  // WRITE TOOLS - only registered when writes are enabled
  // ============================================================
  if (!readonly) {
    // --- flights ---

    server.registerTool(
      'create_flight',
      description:
          'Create a flight. Times are minutes; total_time_hours, day_time_hours '
          'and night_time_hours are accepted instead. Sets aircraft_id and '
          'crew_member_id automatically when the registration or crew name '
          'matches. day_order is computed for the date. Returns the row as '
          'written as flight, with draft telling you whether it counts as a '
          'draft, and warnings for anything odd but legal.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': _createIdSchema,
          ..._flightWriteProperties(db),
        },
        required: ['date'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'create_flight', args, () {
        if (asText(args['date']) == null) throw _ToolError('date is required');
        final flight = _flightValues(db, args);
        final date = asInt(flight.values['date']);
        if (date == null) throw _ToolError('date is required');
        final id = _createId(db, 'flights', args);
        final dayOrder = _nextDayOrder(db, date);
        final fields = <String, Object?>{
          'id': id,
          'day_order': dayOrder,
          ..._createdStamp(db, 'flights'),
          ...flight.values,
        };
        db.execute(
          'INSERT INTO flights (${fields.keys.join(', ')}) VALUES (${List.filled(fields.length, '?').join(', ')})',
          fields.values.toList(),
        );
        final row = _flightRow(db, id)!;
        final warnings = [
          ...flight.warnings,
          ..._checkDayNight(row),
        ];
        return {
          'status': 'created',
          'id': id,
          'day_order': row['day_order'],
          'draft': row['total_time'] == null,
          'flight': row,
          if (warnings.isNotEmpty) 'warnings': warnings,
        };
      }),
    );

    server.registerTool(
      'update_flight',
      description:
          'Update a flight by id. Only the fields provided are changed. Times '
          'are minutes; total_time_hours, day_time_hours and night_time_hours '
          'are accepted instead. draft: true clears total_time, because a null '
          'total_time cannot be sent. Recomputes day_order when date moves the '
          'flight to another day. Returns the row as written as flight.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._flightWriteProperties(db),
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_flight', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        final before = _flightRow(db, id);
        if (before == null) throw _ToolError('Flight not found: $id');
        final flight = _flightValues(db, args);
        if (flight.values.isEmpty) throw _ToolError('No fields to update');
        final values = Map<String, Object?>.of(flight.values);
        final date = asInt(values['date']);
        if (date != null && !_sameLocalDay(before['date'], date)) {
          values['day_order'] = _nextDayOrder(db, date);
        }
        final assignments = [for (final column in values.keys) '$column = ?'];
        final changed = db.execute(
          'UPDATE flights SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
          [...values.values, nowEpochSeconds(), id],
        );
        if (changed != 1) throw _ToolError('Flight not found: $id');
        final row = _flightRow(db, id)!;
        final warnings = [
          ...flight.warnings,
          ..._checkDayNight(row, before: before, written: values.keys.toSet()),
        ];
        return {
          'status': 'updated',
          'id': id,
          'day_order': row['day_order'],
          'draft': row['total_time'] == null,
          'flight': row,
          if (warnings.isNotEmpty) 'warnings': warnings,
        };
      }),
    );

    server.registerTool(
      'delete_flight',
      description: 'Delete a flight by id.',
      inputSchema: JsonSchema.object(
          properties: {'id': JsonSchema.string()}, required: ['id']),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: true, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'delete_flight', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db.query('SELECT id FROM flights WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Flight not found: $id');
        }
        db.transaction(() {
          db.execute('DELETE FROM flights WHERE id = ?', [id]);
          _recordTombstones(db, 'flights', id);
        });
        return _deleted('flights', id);
      }),
    );

    // --- aircraft ---

    server.registerTool(
      'add_aircraft',
      description:
          'Add an aircraft. Registration is the bare registration without country code.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': _createIdSchema,
          ..._propertiesOf(_supported(db, 'aircraft', _aircraftColumns)),
        },
        required: ['type', 'registration'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_aircraft', args, () {
        _rejectUnknown(args, _fieldNames(_aircraftColumns, {'id'}));
        final type = asText(args['type']);
        final registration = asText(args['registration']);
        if (type == null) throw _ToolError('type is required');
        if (registration == null) throw _ToolError('registration is required');
        final countryCode = (asText(args['country_code']) ?? '').toUpperCase();
        final bare = _bareRegistration(registration, countryCode);
        if (bare.isEmpty) throw _ToolError('registration is required');
        final clash = db.query(
          'SELECT id FROM aircraft WHERE UPPER(country_code) = ? AND UPPER(registration) = ?',
          [countryCode, bare],
        );
        if (clash.isNotEmpty) {
          throw _ToolError(
              'Aircraft $countryCode-$bare already exists (id ${clash.first['id']}).');
        }
        final id = _createId(db, 'aircraft', args);
        _insert(
          db,
          'aircraft',
          {
            'id': id,
            'type': type,
            'country_code': countryCode,
            'registration': bare,
            ..._createdStamp(db, 'aircraft'),
          },
          _aircraftColumns,
          args,
        );
        return {'status': 'created', 'id': id};
      }),
    );

    server.registerTool(
      'update_aircraft',
      description:
          'Update an aircraft by id. Only the fields provided are changed.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._propertiesOf(_supported(db, 'aircraft', _aircraftColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_aircraft', args, () {
        _rejectUnknown(args, _fieldNames(_aircraftColumns, {'id'}));
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        final rows = db.query('SELECT * FROM aircraft WHERE id = ?', [id]);
        if (rows.isEmpty) throw _ToolError('Aircraft not found: $id');

        // Normalise to the app's storage form before writing.
        final current = rows.first;
        final countryCode = args.containsKey('country_code')
            ? (asText(args['country_code']) ?? '').toUpperCase()
            : (current['country_code'] as String? ?? '').toUpperCase();
        final registration = asText(args['registration']);
        final bare = registration == null
            ? null
            : _bareRegistration(registration, countryCode);
        if (registration != null && bare!.isEmpty) {
          throw _ToolError('registration cannot be empty');
        }
        if (registration != null || args.containsKey('country_code')) {
          final clash = db.query(
            'SELECT id FROM aircraft WHERE UPPER(country_code) = ? AND UPPER(registration) = ? AND id != ?',
            [
              countryCode,
              bare ?? (current['registration'] as String? ?? ''),
              id
            ],
          );
          if (clash.isNotEmpty) {
            throw _ToolError(
                'Another aircraft already uses $countryCode-$bare (id ${clash.first['id']}).');
          }
        }

        final normalized = Map<String, dynamic>.from(args);
        if (registration != null) normalized['registration'] = bare;
        if (args.containsKey('country_code')) {
          normalized['country_code'] = countryCode;
        }

        final columns = <String>[];
        final values = <Object?>[];
        _collect(db, 'aircraft', _aircraftColumns, normalized, columns, values);
        if (columns.isEmpty) throw _ToolError('No fields to update');
        final assignments = [for (final column in columns) '$column = ?'];
        db.execute(
          'UPDATE aircraft SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
          [...values, nowEpochSeconds(), id],
        );
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_aircraft',
      description:
          'Delete an aircraft by id. Flights keep their registration text but lose the link.',
      inputSchema: JsonSchema.object(
          properties: {'id': JsonSchema.string()}, required: ['id']),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: true, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'delete_aircraft', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db.query('SELECT id FROM aircraft WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Aircraft not found: $id');
        }
        db.transaction(() {
          db.execute('DELETE FROM aircraft WHERE id = ?', [id]);
          _recordTombstones(db, 'aircraft', id);
        });
        return _deleted('aircraft', id);
      }),
    );

    // --- crew ---

    server.registerTool(
      'add_crew',
      description: 'Add a crew member.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': _createIdSchema,
          ..._propertiesOf(_supported(db, 'crew_members', _crewColumns)),
        },
        required: ['first_name', 'last_name'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_crew', args, () {
        _rejectUnknown(args, _fieldNames(_crewColumns, {'id'}));
        final firstName = asText(args['first_name']);
        final lastName = asText(args['last_name']);
        if (firstName == null) throw _ToolError('first_name is required');
        if (lastName == null) throw _ToolError('last_name is required');
        final name = asText(args['name']) ?? '$firstName $lastName';
        final id = _createId(db, 'crew_members', args);
        _insert(
          db,
          'crew_members',
          {
            'id': id,
            'name': name,
            'first_name': firstName,
            'last_name': lastName,
            ..._createdStamp(db, 'crew_members'),
          },
          _crewColumns,
          args,
        );
        return {'status': 'created', 'id': id, 'name': name};
      }),
    );

    server.registerTool(
      'update_crew',
      description:
          'Update a crew member by id. Only the fields provided are changed.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._propertiesOf(_supported(db, 'crew_members', _crewColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_crew', args, () {
        _rejectUnknown(args, _fieldNames(_crewColumns, {'id'}));
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db
            .query('SELECT id FROM crew_members WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Crew member not found: $id');
        }
        final columns = <String>[];
        final values = <Object?>[];
        _collect(db, 'crew_members', _crewColumns, args, columns, values);
        if (columns.isEmpty) throw _ToolError('No fields to update');
        final assignments = [for (final column in columns) '$column = ?'];
        db.execute(
          'UPDATE crew_members SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
          [...values, nowEpochSeconds(), id],
        );
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_crew',
      description:
          'Delete a crew member by id. Flights keep the crew name but lose the link.',
      inputSchema: JsonSchema.object(
          properties: {'id': JsonSchema.string()}, required: ['id']),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: true, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'delete_crew', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db
            .query('SELECT id FROM crew_members WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Crew member not found: $id');
        }
        db.transaction(() {
          db.execute('DELETE FROM crew_members WHERE id = ?', [id]);
          _recordTombstones(db, 'crew_members', id);
        });
        return _deleted('crew_members', id);
      }),
    );

    // --- custom airports ---

    server.registerTool(
      'add_custom_airport',
      description:
          'Add a custom airport that is not in the built-in airport list.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': _createIdSchema,
          ..._propertiesOf(
              _supported(db, 'custom_airports', _customAirportColumns)),
        },
        required: ['name'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_custom_airport', args, () {
        _rejectUnknown(args, _fieldNames(_customAirportColumns, {'id'}));
        final name = asText(args['name']);
        if (name == null) throw _ToolError('name is required');
        final id = _createId(db, 'custom_airports', args);
        _insert(
          db,
          'custom_airports',
          {
            'id': id,
            'name': name,
            ..._createdStamp(db, 'custom_airports'),
          },
          _customAirportColumns,
          args,
        );
        return {'status': 'created', 'id': id};
      }),
    );

    server.registerTool(
      'update_custom_airport',
      description:
          'Update a custom airport by id. Only the fields provided are changed.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._propertiesOf(
              _supported(db, 'custom_airports', _customAirportColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_custom_airport', args, () {
        _rejectUnknown(args, _fieldNames(_customAirportColumns, {'id'}));
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db.query(
            'SELECT id FROM custom_airports WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Custom airport not found: $id');
        }
        final columns = <String>[];
        final values = <Object?>[];
        _collect(db, 'custom_airports', _customAirportColumns, args, columns,
            values);
        if (columns.isEmpty) throw _ToolError('No fields to update');
        final assignments = [for (final column in columns) '$column = ?'];
        db.execute(
          'UPDATE custom_airports SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
          [...values, nowEpochSeconds(), id],
        );
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_custom_airport',
      description: 'Delete a custom airport by id.',
      inputSchema: JsonSchema.object(
          properties: {'id': JsonSchema.string()}, required: ['id']),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: true, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'delete_custom_airport', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db.query(
            'SELECT id FROM custom_airports WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Custom airport not found: $id');
        }
        db.transaction(() {
          db.execute('DELETE FROM custom_airports WHERE id = ?', [id]);
          _recordTombstones(db, 'custom_airports', id);
        });
        return _deleted('custom_airports', id);
      }),
    );

    // --- saved routes ---

    server.registerTool(
      'add_saved_route',
      description: 'Add a saved route.',
      inputSchema: JsonSchema.object(
        properties:
            _propertiesOf(_supported(db, 'saved_routes', _savedRouteColumns)),
        required: ['flight_number', 'departure_icao', 'arrival_icao'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_saved_route', args, () {
        _rejectUnknown(args, _fieldNames(_savedRouteColumns, {'id'}));
        final flightNumber = asText(args['flight_number']);
        final departure = asText(args['departure_icao']);
        final arrival = asText(args['arrival_icao']);
        if (flightNumber == null) throw _ToolError('flight_number is required');
        if (departure == null) throw _ToolError('departure_icao is required');
        if (arrival == null) throw _ToolError('arrival_icao is required');
        _insert(
          db,
          'saved_routes',
          {
            'flight_number': flightNumber,
            'departure_icao': departure.toUpperCase(),
            'arrival_icao': arrival.toUpperCase(),
          },
          _savedRouteColumns,
          args,
        );
        return {'status': 'created', 'id': db.lastInsertRowId()};
      }),
    );

    server.registerTool(
      'update_saved_route',
      description:
          'Update a saved route by id. Only the fields provided are changed.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.integer(),
          ..._propertiesOf(_supported(db, 'saved_routes', _savedRouteColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_saved_route', args, () {
        _rejectUnknown(args, _fieldNames(_savedRouteColumns, {'id'}));
        final id = asInt(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db
            .query('SELECT id FROM saved_routes WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Saved route not found: $id');
        }
        final columns = <String>[];
        final values = <Object?>[];
        _collect(db, 'saved_routes', _savedRouteColumns, args, columns, values);
        if (columns.isEmpty) throw _ToolError('No fields to update');
        final assignments = [for (final column in columns) '$column = ?'];
        db.execute(
          'UPDATE saved_routes SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
          [...values, nowEpochSeconds(), id],
        );
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_saved_route',
      description:
          'Delete a saved route by id. Flights that referenced it are unlinked.',
      inputSchema: JsonSchema.object(
          properties: {'id': JsonSchema.integer()}, required: ['id']),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: true, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'delete_saved_route', args, () {
        final id = asInt(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db
            .query('SELECT id FROM saved_routes WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Saved route not found: $id');
        }
        // The app clears route_id on linked flights when a route is deleted.
        db.transaction(() {
          db.execute(
              'UPDATE flights SET route_id = NULL WHERE route_id = ?', [id]);
          db.execute('DELETE FROM saved_routes WHERE id = ?', [id]);
        });
        return _deleted('saved_routes', id);
      }),
    );

    // --- flight settings ---

    server.registerTool(
      'update_flight_settings',
      description:
          'Update flight settings (pilot name, formats, country, display '
          'toggles). Creates the settings row when there is none. Returns the '
          'settings as written as settings.',
      inputSchema: JsonSchema.object(
        properties: _propertiesOf(
            _supported(db, 'flights_settings', _flightSettingsColumns)),
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_flight_settings', args, () {
        _rejectUnknown(args, _fieldNames(_flightSettingsColumns));
        final columns = <String>[];
        final values = <Object?>[];
        _collect(db, 'flights_settings', _flightSettingsColumns, args, columns,
            values);
        if (columns.isEmpty) throw _ToolError('No fields to update');
        for (final entry in <String, Set<String>>{
          'default_flight_type': _flightTypes,
          'flight_time_format': _timeFormats,
          'calculate_time_mode': _calculateTimeModes,
        }.entries) {
          final value = args[entry.key];
          if (value is String &&
              value.isNotEmpty &&
              !entry.value.contains(value)) {
            throw _ToolError(
              '${entry.key} must be one of ${entry.value.join(', ')} (got "$value")',
            );
          }
        }
        final existing = db.query('SELECT id FROM flights_settings LIMIT 1');
        // The app generates a UUID for its settings row, and 'default' is not a
        // UUID, so a new row gets one too and the id is never an argument.
        final id = existing.isEmpty
            ? uuidV4()
            : asText(existing.first['id']) ?? uuidV4();
        final assignments = [for (final column in columns) '$column = ?'];
        final fields = <String, Object?>{
          'id': id,
          ..._createdStamp(db, 'flights_settings'),
        };
        db.transaction(() {
          if (db.query(
              'SELECT id FROM flights_settings WHERE id = ?', [id]).isEmpty) {
            db.execute(
              'INSERT INTO flights_settings (${fields.keys.join(', ')}) '
              'VALUES (${List.filled(fields.length, '?').join(', ')})',
              fields.values.toList(),
            );
          }
          db.execute(
            'UPDATE flights_settings SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
            [...values, nowEpochSeconds(), id],
          );
        });
        return {
          'status': 'updated',
          'id': id,
          'settings': db
              .query('SELECT * FROM flights_settings WHERE id = ?', [id]).first,
        };
      }),
    );
  }

  // ============================================================
  // RESOURCES
  // ============================================================

  server.registerResource(
    'flights',
    'falcon://flights',
    (
      description: 'The 20 most recent local flights as JSON: {rows, units}, '
          'with each row a twelve-field summary. Use list_flights for filters, '
          'paging and full rows.',
      mimeType: 'application/json',
    ),
    (uri, extra) async {
      // A resource takes no arguments, so it answers with local rows only, the
      // same default as list_flights. Use list_flights include_shared for the
      // rest, and full: true for every column.
      final owner = _ownerClause(db, 'flights', includeShared: false);
      final rows = db
          .query('SELECT * FROM flights${owner.isEmpty ? '' : ' WHERE $owner'} '
              'ORDER BY date DESC, day_order DESC, id LIMIT 20');
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'application/json',
            text: jsonEncode({
              'rows': [for (final row in rows) _flightView(row)],
              'units': _units,
            }),
          ),
        ],
      );
    },
  );

  server.registerResource(
    'overview',
    'falcon://overview',
    (description: 'What this server can do.', mimeType: 'text/plain'),
    (uri, extra) async {
      final writeMode =
          readonly ? 'read-only (writes disabled)' : 'read and write';
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text:
                'Falcon MCP server ($writeMode): a local Falcon pilot logbook (SQLite).\n'
                'Tools cover flights, aircraft, airports, crew, saved routes, stats, settings, logs'
                '${readonly ? '' : ', and writes'}.\n'
                'Use the falcon_help prompt for the tool list and falcon://conventions for field semantics.',
          ),
        ],
      );
    },
  );

  server.registerResource(
    'conventions',
    'falcon://conventions',
    (
      description:
          'Field semantics: dates, minutes, registration format, drafts.',
      mimeType: 'text/plain'
    ),
    (uri, extra) async {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text: 'FALCON DB CONVENTIONS\n\n'
                '- Dates and timestamps are stored as unix epoch seconds and returned as local ISO-8601 strings, for example 2026-10-27T00:00:00.000. The flights.date column holds local midnight of the flight date; tool inputs accept YYYY-MM-DD and are converted the same way.\n'
                '- Read filters accept only YYYY-MM-DD (or a named period) and reject anything else instead of ignoring it. Every filtered response echoes the applied window as range {from, to}.\n'
                '- Flight time columns (total_time, day_time, night_time, actual_instrument, simulated_instrument, icus_day_time, icus_night_time) are integer MINUTES. Responses state this in a units object. Write tools also accept total_time_hours, day_time_hours and night_time_hours.\n'
                '- Flight time is capped at 525600 minutes (8760 hours) and takeoff/landing counts at 10000, the same limits the app enforces. A value outside either is refused, and the error names the limit.\n'
                '- day_time and night_time must add up to total_time when both are supplied: the app cannot display any other split, so it is refused. A one-sided split (for example day_time equal to total_time with no night_time) is stored as given and reported in warnings, because the app saves those itself.\n'
                '- time_start and time_stop are 24-hour clock times stored as HH:MM. Write tools accept 9, 930, 9:30, 09:30 or 0930 and refuse anything else, so 9am is rejected rather than stored. They pair with calc_time_mode (utc, local, time, hobbsTacho) and hobbs_start/hobbs_stop when that mode was used. They are not stored as durations.\n'
                '- A flight is a DRAFT when total_time IS NULL. Set total_time (1 minute or more) to make it complete. total_time 0 is refused: the app stores 0 as a complete flight with no duration, which the pilot cannot see or fix. To clear a time and make a flight a draft again, pass draft: true, because a null total_time cannot be sent over MCP. Lists include drafts; totals exclude them.\n'
                '- ids for flights, aircraft, crew_members, custom_airports and flights_settings are RFC 4122 version 4 UUIDs, lowercase and hyphenated, the shape the cloud schema requires before a row can sync. A create tool accepts an optional UUID v4 id so an import can keep its own, and refuses any other shape. saved_routes keeps its integer id.\n'
                '- day_order is the order of a flight within its date: a create takes the next free order for that day, and an update recomputes it when the date moves the flight to another day. updated_at records the last write.\n'
                '- Flights are ordered date DESC, day_order DESC, id, the same as the app. Flights on the same date are newest-first within the day.\n'
                '- Reads return local rows only (owner_id NULL or "local") unless include_shared is true. Paged reads return count (rows on this page), total (all matching rows), has_more and offset, and default to 20 rows with a maximum of 200. A listed flight is a twelve-field summary unless full: true.\n'
                '- aircraft.registration is the BARE registration (e.g. country_code=VH, registration=XZO). The app displays country_code + "-" + registration.\n'
                '- flights.aircraft_registration is the display registration (e.g. VH-XZO). Write tools accept either form and set aircraft_id from the matching aircraft row; flights.crew_members_name is matched the same way to set crew_member_id.\n'
                '- flight_type values: route, details. crew_role values: pilotInCommand, copilot, student.\n'
                '- calculate_time_mode values: utc, local, time, hobbsTacho. flight_time_format values: hhmm, decimal1, decimal2.\n'
                '- logbook_country is "AU", "NZ", or null.\n'
                '- total_time is the authoritative flight duration; takeoffs/landings are counts per flight row.\n'
                '- is_simulator and is_ifr are stored as 0/1.\n'
                '- Deleting a flight, aircraft, crew member or custom airport also records a sync tombstone when a Postgres sync provider has been used, so the deletion propagates.\n'
                '- Use get_schema for exact table/column names before writing.',
          ),
        ],
      );
    },
  );

  server.registerResource(
    'schema',
    'falcon://schema',
    (
      description: 'All tables with their columns, as JSON.',
      mimeType: 'application/json'
    ),
    (uri, extra) async {
      final out = <String, dynamic>{
        for (final table in db.tables) table: describeTable(table),
      };
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'application/json',
            text: jsonEncode(out),
          ),
        ],
      );
    },
  );

  // ============================================================
  // PROMPT
  // ============================================================

  server.registerPrompt(
    'falcon_help',
    description:
        'How to use the Falcon MCP server: available tools and example questions.',
    callback: (args, extra) async {
      final writeTools = readonly
          ? 'Write tools are disabled because this server runs in read-only mode.\n'
          : 'Write tools: create_flight, update_flight, delete_flight, add_aircraft, update_aircraft, '
              'delete_aircraft, add_crew, update_crew, delete_crew, add_custom_airport, update_custom_airport, '
              'delete_custom_airport, add_saved_route, update_saved_route, delete_saved_route, '
              'update_flight_settings.\n'
              'Writes apply immediately; each one is recorded in an audit log next to the database.\n';
      return GetPromptResult(
        messages: [
          PromptMessage(
            role: PromptMessageRole.user,
            content: TextContent(
              text: 'You have access to the Falcon MCP server, which reads'
                  '${readonly ? '' : ' and edits'} a local Falcon pilot logbook (SQLite).\n\n'
                  'Read tools: db_info, get_schema, list_flights, get_flight, search_flights, list_aircraft, '
                  'get_aircraft, list_airports, list_custom_airports, list_crew, list_saved_routes, logbook_stats, '
                  'get_flight_settings, get_app_settings, get_general_settings, get_recent_logs, '
                  'find_missing_times, dedupe_crew.\n'
                  '$writeTools\n'
                  'Call get_schema for exact table/column names and read the falcon://conventions resource for field semantics (dates, minutes, registration format, draft rule).\n'
                  'Example questions: "How many hours did I fly last year?", "List flights into YSSY in 2025", '
                  '"Are there flights missing block times?", "Add a flight today in VH-XZO from YSSY to NZQN".\n'
                  'Always confirm destructive or bulk operations with the user first.',
            ),
          ),
        ],
      );
    },
  );

  await server.connect(StdioServerTransport());
}
