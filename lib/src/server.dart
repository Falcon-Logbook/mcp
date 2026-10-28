import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'config.dart';
import 'currency.dart';
import 'db.dart';
import 'expiry.dart';
import 'totals.dart';
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

  /// How this column is advertised to a client. [notes] false keeps the type,
  /// the bounds and the format and drops the prose, for the second tool that
  /// would otherwise carry the same note again.
  JsonSchema schema({bool notes = true}) => switch (kind) {
        _Kind.text => JsonSchema.string(description: notes ? note : null),
        _Kind.integer => JsonSchema.integer(
            description: notes ? note : null,
            minimum: min?.toInt(),
            maximum: max?.toInt(),
          ),
        _Kind.real => JsonSchema.number(
            description: notes ? note : null, minimum: min, maximum: max),
        _Kind.boolean => JsonSchema.boolean(description: notes ? note : null),
        _Kind.date =>
          JsonSchema.string(description: notes ? note : null, format: 'date'),
        // No pattern: the shapes accepted are wider than any single regex a
        // client could read, and the SDK enforces a pattern before the tool
        // runs, which would turn a valid 930 into a validation failure.
        _Kind.clock => JsonSchema.string(description: notes ? note : null),
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

/// The single-row settings tables `get_settings` answers for, alphabetical. The
/// app has nine settings tables; `aircraft_type_settings` is keyed by
/// `(type, owner_id)` rather than being a singleton, so it is not here. This list
/// is the allowlist: a table name reaches SQL only through it.
const List<String> _settingsTables = [
  'aircraft_settings',
  'app_settings',
  'crew_settings',
  'expiry_settings',
  'flights_settings',
  'general_settings',
  'routes_settings',
  'sidebar_settings',
];

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

/// The `limit` argument on the two paged flight reads, `list_flights` and
/// `search_flights`: 20 rows by default, 200 at most, so the page size is honest
/// and `has_more` says what is left. `find_missing_times` is not paged and
/// returns every match up to the cap, so it declares its own default; reusing
/// this schema there would promise 20 rows and deliver 200.
JsonSchema get _flightLimitSchema => JsonSchema.integer(
    minimum: 1, maximum: 200, description: 'Default 20, maximum 200.');

/// The `limit` argument on `find_missing_times`, which exists to find every
/// draft rather than to page: 200 rows by default, which is what its callback
/// does, so the catalog and the response agree.
JsonSchema get _missingTimesLimitSchema => JsonSchema.integer(
    minimum: 1, maximum: 200, description: 'Default 200, maximum 200.');

/// The `limit` argument on `get_recent_logs`. A log response is a diagnostic
/// aid, so the page is small: 20 entries by default, 200 at most.
JsonSchema get _logLimitSchema => JsonSchema.integer(
    minimum: 1, maximum: 200, description: 'Default 20, maximum 200.');

/// The `limit` argument on `entity_totals`: 20 groups by default, 200 at most,
/// enough for a fleet and still cheaper than the flight rows it summarises.
JsonSchema get _entityTotalLimitSchema => JsonSchema.integer(
    minimum: 1, maximum: 200, description: 'Default 20, maximum 200.');

/// How much of a log message a projection carries. A log entry can hold a
/// multi-kilobyte message and a multi-kilobyte stack trace, neither of which is
/// worth 10k tokens, and the full text is in the app.
const int _logMessageLimit = 500;

/// [text] cut to [_logMessageLimit] characters, with an ellipsis when it was
/// longer, so a caller can tell a short message from a truncated one.
String _truncateMessage(String text) => text.length <= _logMessageLimit
    ? text
    : '${text.substring(0, _logMessageLimit - 3)}...';

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
///
/// [code] is a token a caller can branch on, [field] is the argument at fault,
/// and [tool] is named when several tools could have refused. [detail] is one
/// sentence: no SQL, no file path, no database text.
class _ToolError implements Exception {
  _ToolError(this.detail, {this.code = 'invalid_value', this.field, this.tool});

  final String detail;
  final String code;
  final String? field;
  final String? tool;

  @override
  String toString() => detail;
}

/// A tool result as compact JSON: a client can pretty-print for a human, and an
/// agent reading a page of rows does not pay for indentation it cannot use.
TextContent _jsonContent(Object? value) => TextContent(text: jsonEncode(value));

CallToolResult _ok(Object? value) =>
    CallToolResult.fromContent([_jsonContent(value)]);

/// A failed call as the envelope an agent can act on: a stable error code, the
/// field at fault, and one short sentence. Same encoding as a successful
/// result, so a caller parses one shape either way.
CallToolResult _fail(
  String detail, {
  String code = 'invalid_value',
  String? field,
  String? tool,
}) =>
    CallToolResult(
      content: [
        _jsonContent({
          'error': code,
          if (field != null) 'field': field,
          if (tool != null) 'tool': tool,
          'detail': detail,
        }),
      ],
      isError: true,
    );

/// [error] as a failed call, keeping the code, field and tool it was raised
/// with so the message does not have to repeat them in prose.
CallToolResult _failWith(_ToolError error) => _fail(
      error.detail,
      code: error.code,
      field: error.field,
      tool: error.tool,
    );

/// Anything thrown inside a callback as a [_ToolError].
///
/// Database text is never passed through: a [SqliteException] carries the SQL
/// statement and the database path, and an agent can act on none of it. The
/// primary result code says what kind of failure it was, which is all a caller
/// needs to decide whether a retry or a different value will help.
_ToolError _asToolError(Object error) {
  if (error is _ToolError) return error;
  if (error is SqliteException) {
    return switch (error.resultCode) {
      19 => _ToolError(
          'the database refused the row: a duplicate, a missing link or a '
          'value outside its allowed set',
          code: 'constraint',
        ),
      5 || 6 => _ToolError(
          'the database is locked by another process; retry in a moment',
          code: 'busy',
        ),
      _ => _ToolError('the database could not complete the request',
          code: 'internal'),
    };
  }
  return _ToolError('the server could not complete the request',
      code: 'internal');
}

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
              'use $alias to pass hours',
              field: column.name);
        }
        throw _ToolError(
            _minuteColumns.contains(column.name)
                ? '${column.name} must be an integer number of minutes'
                : '${column.name} must be an integer',
            field: column.name);
      }
      _checkRange(column, value);
      return value;
    case _Kind.real:
      final value = asDouble(raw);
      if (value == null) {
        throw _ToolError('${column.name} must be a number', field: column.name);
      }
      _checkRange(column, value);
      return value;
    case _Kind.boolean:
      final value = asBool(raw);
      if (value == null) {
        throw _ToolError('${column.name} must be a boolean',
            field: column.name);
      }
      return value ? 1 : 0;
    case _Kind.date:
      final value = dateToEpoch(raw);
      if (value == null) {
        throw _ToolError('${column.name} must be a date such as 2026-10-27',
            field: column.name);
      }
      return value;
    case _Kind.clock:
      final value = canonicalClockTime(raw);
      if (value == null) {
        throw _ToolError(
            '${column.name} must be a 24-hour clock time: 9, 930, 9:30, '
            '09:30 or 0930 (got "$raw")',
            field: column.name);
      }
      return value;
  }
}

void _checkRange(_Column column, num value) {
  if (column.min != null && value < column.min!) {
    throw _ToolError(
        '${column.name} must be >= ${column.min}${_unitSuffix(column)}',
        field: column.name);
  }
  if (column.max != null && value > column.max!) {
    throw _ToolError(
        '${column.name} must be <= ${column.max}${_unitSuffix(column)}',
        field: column.name);
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

Map<String, JsonSchema> _propertiesOf(List<_Column> columns,
        {bool notes = true}) =>
    {
      for (final column in columns) column.name: column.schema(notes: notes),
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

/// Every table with its column count: the cheap answer to "what is in this
/// database" that an agent needs before asking about one table. Describing all
/// 21 tables costs 33 KB, more than the whole read-only catalog, so nothing
/// returns every table's columns at once.
List<Map<String, Object>> _tableCounts(FalconDb db) => [
      for (final table in db.tables)
        {'name': table, 'columns': db.columnsOf(table).length},
    ];

/// One table's columns. The default form is what a write needs: a name, a type
/// and whether it is nullable. [full] adds the default value and the
/// primary-key flag, which is what a schema diff wants and a write does not.
List<Map<String, dynamic>> _columnInfo(FalconDb db, String table,
        {required bool full}) =>
    [
      for (final column in db.tableInfo(table))
        {
          'name': column['name'],
          'type': column['type'],
          'notnull': column['notnull'],
          if (full) 'default': column['default'],
          if (full) 'pk': column['pk'],
        },
    ];

/// [names] as one line, capped at eight so a typo error stays small: the first
/// eight alphabetically, then how many were left out. A caller who mistyped one
/// field needs to know the field is wrong and roughly what is accepted, not all
/// 44 names.
String _acceptedList(Iterable<String> names) {
  final sorted = names.toList()..sort();
  if (sorted.length <= 8) return sorted.join(', ');
  return '${sorted.take(8).join(', ')} and ${sorted.length - 8} more';
}

/// Rejects argument names this server does not write, so a stale field name
/// fails loudly instead of being silently dropped. [tool] is named because an
/// agent that called three tools in a row needs to know which one refused.
void _rejectUnknown(Map<String, dynamic> args, Set<String> allowed,
    {required String tool}) {
  final unknown = args.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isEmpty) return;
  throw _ToolError(
    'accepts ${_acceptedList(allowed)}',
    code: 'unknown_field',
    field: unknown.first,
    tool: tool,
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
        '$name must be $dateFormatHint, for example 2025-01-31 (got "$raw")',
        field: name);
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
    throw _ToolError('Use either period or date_from/date_to, not both.',
        field: 'period');
  }

  DateTime? from;
  DateTime? to;
  if (period != null) {
    final resolved = resolveDatePreset(period, now: now);
    if (resolved == null) {
      throw _ToolError(
          'period must be one of ${datePresets.join(', ')} (got "$period")',
          field: 'period');
    }
    from = resolved.from;
    to = resolved.to;
  } else {
    from = _readDate(args, 'date_from');
    to = _readDate(args, 'date_to');
    if (from != null && to != null && from.isAfter(to)) {
      throw _ToolError(
          'date_from (${formatCalendarDate(from)}) must not be '
          'after date_to (${formatCalendarDate(to)})',
          field: 'date_from');
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
/// rows are requested or the table has no owner column. [prefix] qualifies the
/// column for a query that joins another table carrying an owner_id, where a
/// bare name would be ambiguous.
String _ownerClause(FalconDb db, String table,
        {required bool includeShared, String prefix = ''}) =>
    !includeShared && db.columnsOf(table).contains('owner_id')
        ? "(${prefix}owner_id IS NULL OR ${prefix}owner_id = 'local')"
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
    auditor.record(tool, args, error: error.detail);
    return _failWith(error);
  } catch (error) {
    final failure = _asToolError(error);
    auditor.record(tool, args, error: failure.detail);
    return _failWith(failure);
  }
}

// ============================================================
// Domain helpers
// ============================================================

String _normalizeKey(String value) =>
    value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// A `*_date` column's value as a local [DateTime]. [FalconDb] renders an epoch
/// `*_date` column as a local ISO string, so that is what a read sees; an
/// integer is accepted too, for a query that bypasses the mapper.
DateTime? _localDate(Object? value) => switch (value) {
      int() => DateTime.fromMillisecondsSinceEpoch(value * 1000),
      String() => DateTime.tryParse(value)?.toLocal(),
      _ => null,
    };

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
          'Supply either ${entry.key} (minutes) or $alias (hours), not both.',
          field: alias);
    }
    final hours = asDouble(out.remove(alias));
    if (hours == null) {
      throw _ToolError('$alias must be a number of hours', field: alias);
    }
    if (hours < 0) throw _ToolError('$alias must be >= 0', field: alias);
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
  if (draft == null) {
    throw _ToolError('draft must be true or false', field: 'draft');
  }
  if (!draft) return;
  if (fields.containsKey('total_time')) {
    throw _ToolError(
        'Supply either total_time or draft: true, not both. draft: true clears '
        'total_time and makes the flight a draft.',
        field: 'draft');
  }
  fields['total_time'] = null;
}

/// Input schema for the flight write tools: the live columns, the `_hours`
/// aliases for the duration fields this database has, and `draft`.
///
/// A field means the same thing on a create and on an update, so the per-column
/// notes are written once, on `create_flight`. `update_flight` passes [notes]
/// false and carries the same names, types, bounds and formats without the
/// prose: that is what a caller plans a call from, and paying for the same
/// explanations twice is the catalog's largest avoidable cost.
Map<String, JsonSchema> _flightWriteProperties(FalconDb db,
    {required bool notes}) {
  final available = db.columnsOf('flights').toSet();
  return {
    ..._propertiesOf(_supported(db, 'flights', _flightColumns), notes: notes),
    for (final entry in _hoursAliases.entries)
      if (available.contains(entry.key))
        entry.value: JsonSchema.number(
          minimum: 0,
          description:
              notes ? 'Hours, converted to ${entry.key} minutes.' : null,
        ),
    'draft': JsonSchema.boolean(
      description: notes
          ? 'true clears total_time, which is what makes a flight a draft. '
              'Cannot be combined with total_time. Clients cannot send a '
              'null total_time, so this is the only way to clear a time.'
          : 'true clears total_time, making the flight a draft.',
    ),
  };
}

/// The columns that describe the day/night split. A disagreement between them
/// is the one flight condition the app can never show, so it is checked on
/// write.
const Set<String> _splitFields = {'total_time', 'day_time', 'night_time'};

/// Builds the column/value map for a flight from tool arguments, deriving the
/// aircraft and crew foreign keys the app expects. [tool] is the write tool
/// that asked, so an unknown field names the tool that refused it.
({Map<String, Object?> values, List<String> warnings}) _flightValues(
  FalconDb db,
  Map<String, dynamic> args, {
  required String tool,
}) {
  final values = <String, Object?>{};
  final warnings = <String>[];
  _rejectUnknown(args,
      _fieldNames(_flightColumns, {'id', ..._hoursAliases.values, 'draft'}),
      tool: tool);
  final fields = _minutesFromHours(args);
  _applyDraft(fields, args);
  if (fields.containsKey('date') && asText(fields['date']) == null) {
    throw _ToolError('date cannot be empty', field: 'date');
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
        'time.',
        field: 'total_time');
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
      throw _ToolError('Aircraft not found: $aircraftId',
          code: 'not_found', field: 'aircraft_id');
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
      throw _ToolError('Crew member not found: $crewId',
          code: 'not_found', field: 'crew_member_id');
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
        field: entry.key,
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
    throw _ToolError('A $table row with id $requested already exists.',
        code: 'constraint', field: 'id');
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
        _rejectUnknown(args, const {}, tool: 'db_info');
        return _ok({
          'path': dbPath,
          'schemaVersion': version,
          'supportedSchemaVersions': '$minSchemaVersion-$maxSchemaVersion',
          'readonly': readonly,
          'tables': db.tables,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'get_schema',
    description:
        'List table names with a column count. Pass table for that table\'s '
        'columns (name, type, notnull), and add detail: "full" for default and '
        'pk as well. Columns of every table at once are never returned.',
    inputSchema: JsonSchema.object(properties: {
      'table': JsonSchema.string(
          description:
              'Table name. Omit to list table names and their column counts.'),
      'detail': JsonSchema.string(
          description:
              'full: include a table\'s default and pk columns too. Needs table.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'table', 'detail'}, tool: 'get_schema');
        final only = asText(args['table']);
        final detail = asText(args['detail']);
        if (detail != null && detail != 'full') {
          return _fail('detail must be full (got "$detail")', field: 'detail');
        }
        if (only == null) {
          if (detail != null) {
            return _fail('detail: full needs a table; one table at a time',
                field: 'table');
          }
          return _ok({'tables': _tableCounts(db)});
        }
        if (!db.hasTable(only)) {
          return _fail('no table named $only; db_info lists the tables',
              code: 'not_found', field: 'table');
        }
        return _ok({only: _columnInfo(db, only, full: detail != null)});
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(
            args,
            {
              'limit',
              'offset',
              'full',
              'aircraft_registration',
              'flight_type',
              'crew_members_name',
              ..._flightFilterKeys,
            },
            tool: 'list_flights');
        final limit = asInt(args['limit']) ?? 20;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0', field: 'offset');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {'id', _includeSharedKey}, tool: 'get_flight');
        final id = asText(args['id']);
        if (id == null) return _fail('Missing or invalid id', field: 'id');
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM flights WHERE id = ?'
            '${owner.isEmpty ? '' : ' AND $owner'}',
            [id]);
        if (rows.isEmpty) {
          return _fail('Flight not found: $id', code: 'not_found', field: 'id');
        }
        return _ok({...rows.first, 'units': _units});
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(
            args,
            {
              'query',
              'limit',
              'offset',
              'full',
              ..._flightFilterKeys,
            },
            tool: 'search_flights');
        final text = asText(args['query']);
        if (text == null) {
          return _fail('Missing or invalid query', field: 'query');
        }
        final limit = asInt(args['limit']) ?? 20;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0', field: 'offset');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {'include_archived', _includeSharedKey, 'limit'},
            tool: 'list_aircraft');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {'id', _includeSharedKey}, tool: 'get_aircraft');
        final id = asText(args['id']);
        if (id == null) return _fail('Missing or invalid id', field: 'id');
        final owner = _ownerClause(db, 'aircraft',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final rows = db.query(
            'SELECT * FROM aircraft WHERE id = ?'
            '${owner.isEmpty ? '' : ' AND $owner'}',
            [id]);
        if (rows.isEmpty) {
          return _fail('Aircraft not found: $id',
              code: 'not_found', field: 'id');
        }
        return _ok(rows.first);
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {'query', 'limit'}, tool: 'list_airports');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {_includeSharedKey, 'limit'},
            tool: 'list_custom_airports');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {'include_archived', _includeSharedKey, 'limit'},
            tool: 'list_crew');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {_includeSharedKey, 'limit'},
            tool: 'list_saved_routes');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'list_expiries',
    description:
        'List document expiries (medical, licence, type rating) with the days '
        'from today and the red/orange/green status the app shows. Red includes '
        'today and anything overdue. due_date is YYYY-MM-DD and checked_on is '
        'the day the status was computed for. Ordered by due date, soonest '
        'first. Overdue rows are included unless include_past is false, and '
        'due_within_days counts forward from today, so it keeps an overdue row '
        'only while include_past is true. Thresholds come from expiry_settings, '
        'or 90 and 30 days when that table has no row. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'include_past': JsonSchema.boolean(
          description: 'Include overdue rows. Default true, because an expired '
              'document is the one row that matters.'),
      'due_within_days': JsonSchema.integer(
          minimum: 0,
          description: 'Only rows due within this many days, counting forward '
              'from today.'),
      'limit': JsonSchema.integer(
          minimum: 1, maximum: 1000, description: 'Default 100, maximum 1000.'),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args,
            {'include_past', 'due_within_days', 'limit', _includeSharedKey},
            tool: 'list_expiries');
        if (!db.hasTable('expiries')) {
          return _fail(
              'This database (schema ${db.schemaVersion}) has no '
              'expiries table',
              code: 'not_found',
              field: 'expiries');
        }
        final includePast = asBool(args['include_past']) ?? true;
        final rawDays = args['due_within_days'];
        final dueWithinDays = rawDays == null ? null : asInt(rawDays);
        if (rawDays != null && (dueWithinDays == null || dueWithinDays < 0)) {
          return _fail(
              'due_within_days must be a whole number of days, 0 or '
              'more (got "$rawDays")',
              field: 'due_within_days');
        }
        final limit = asInt(args['limit']) ?? 100;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');

        final thresholds = readExpiryThresholds(db);
        final today = DateTime.now();
        final owner = _ownerClause(db, 'expiries',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        // The app sorts on due date alone; the id tiebreak keeps two documents
        // due the same day in a stable order instead of an arbitrary one.
        final rows = db.query('SELECT id, name, due_date FROM expiries'
            '${owner.isEmpty ? '' : ' WHERE $owner'} '
            'ORDER BY due_date, id');
        final expiries = <Map<String, dynamic>>[];
        var matched = 0;
        for (final row in rows) {
          final due = _localDate(row['due_date']);
          if (due == null) continue;
          final days = daysUntilDue(due, today);
          if (!includePast && days < 0) continue;
          if (dueWithinDays != null && days > dueWithinDays) continue;
          matched++;
          if (expiries.length >= limit) continue;
          expiries.add({
            'id': row['id'],
            'name': row['name'],
            'due_date': formatCalendarDate(due),
            'days_remaining': days,
            'status': expiryStatusForDays(days,
                greenThreshold: thresholds.green,
                orangeThreshold: thresholds.orange),
          });
        }
        return _ok({
          'checked_on': formatCalendarDate(today),
          'thresholds': {
            'green': thresholds.green,
            'orange': thresholds.orange,
            'source': thresholds.source,
          },
          'include_past': includePast,
          'due_within_days': dueWithinDays,
          'count': expiries.length,
          'total': matched,
          'expiries': expiries,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, _flightFilterKeys, tool: 'logbook_stats');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'entity_totals',
    description:
        'Per-entity totals: minutes and the number of flights per aircraft, crew '
        'member, aircraft type or registration, rather than the flight rows '
        'behind them. Grouping follows the app: aircraft and crew group on the '
        'link, type on the linked aircraft\'s type, registration on the flight\'s '
        'registration text, so a flight with no aircraft link counts under '
        'registration only. Drafts have no total time, so they are in neither '
        'number, and an entity with no complete flight is not listed: flights '
        'here counts complete flights, unlike logbook_stats where it counts every '
        'row. Simulator flights are included unless include_simulator is false. '
        'Sorted by minutes unless sort says otherwise, and total is the number of '
        'groups before limit. Local rows only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'type': JsonSchema.string(
          description:
              'What to group by: ${entityTotalDimensions.join(', ')}.'),
      'sort': JsonSchema.string(
          description: 'minutes and flights order descending, label '
              'alphabetically. Default $defaultEntityTotalSort.'),
      'limit': _entityTotalLimitSchema,
      'include_simulator': JsonSchema.boolean(
          description:
              'Include simulator flights in both numbers. Default true, '
              'as the app does.'),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }, required: [
      'type'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args,
            {'type', 'sort', 'limit', 'include_simulator', _includeSharedKey},
            tool: 'entity_totals');
        final rawType = args['type'];
        final type = asText(rawType);
        if (type == null || !entityTotalDimensions.contains(type)) {
          return _fail(
              'type must be one of ${entityTotalDimensions.join(', ')} '
              '(got "$rawType")',
              field: 'type');
        }
        final rawSort = args['sort'];
        final sort = asText(rawSort) ?? defaultEntityTotalSort;
        if (!entityTotalSorts.contains(sort)) {
          return _fail(
              'sort must be one of ${entityTotalSorts.join(', ')} '
              '(got "$rawSort")',
              field: 'sort');
        }
        final limit = asInt(args['limit']) ?? 20;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');
        final includeSimulator = asBool(args['include_simulator']) ?? true;
        // Qualified for the joins this query makes: crew_members and aircraft
        // carry an owner_id too.
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false,
            prefix: 'flights.');
        final totals = readEntityTotals(
          db,
          type: type,
          sort: sort,
          limit: limit,
          includeSimulator: includeSimulator,
          ownerClause: owner,
        );
        return _ok({
          'type': type,
          'sort': sort,
          'include_simulator': includeSimulator,
          'count': totals.entities.length,
          'total': totals.total,
          'units': _units,
          'entities': totals.entities,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'currency_status',
    description:
        'The pilot\'s currency rules, computed as the app\'s currency page '
        'computes them. Thresholds are hours for the four time metrics (the app '
        'divides those by 60) and counts otherwise. is_exceeded keeps the app\'s '
        'meaning, attention needed: for a requirement it is true when you are '
        'short of the threshold, for a limit when you reach it. remaining is '
        'what a requirement still needs, over_by how far over a limit is, both '
        '0 once satisfied. Matches that page, including its missing owner '
        'filter, so a synced logbook can mix owners and drafts count as flights. '
        'Landings and takeoffs work here; the app cannot display those two '
        'rules. Pass metric to ask about one with no rule: you get the raw total '
        'for period and a note saying so.',
    inputSchema: JsonSchema.object(properties: {
      'metric': JsonSchema.string(
        enumValues: currencyMetrics,
        description: 'Ask whether a rule covers this metric. Omit for just the '
            'configured rules.',
      ),
      'period': JsonSchema.string(
        enumValues: currencyPeriods,
        description: 'Window for the raw total when metric has no rule. '
            'Default $defaultCurrencyPeriod. Only valid with metric.',
      ),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'metric', 'period'}, tool: 'currency_status');
        if (!db.hasTable('user_currency')) {
          return _fail(
              'This database (schema ${db.schemaVersion}) has no '
              'user_currency table',
              code: 'not_found',
              field: 'user_currency');
        }
        final metric = asText(args['metric']);
        if (metric != null && !currencyMetrics.contains(metric)) {
          return _fail(
              'metric must be one of ${currencyMetrics.join(', ')} (got '
              '"$metric")',
              field: 'metric');
        }
        final rawPeriod = asText(args['period']);
        final period = rawPeriod ?? defaultCurrencyPeriod;
        if (!currencyPeriods.contains(period)) {
          return _fail(
              'period must be one of ${currencyPeriods.join(', ')} '
              '(got "$period")',
              field: 'period');
        }
        if (rawPeriod != null && metric == null) {
          return _fail(
              'period only applies with metric: pass metric (one of '
              '${currencyMetrics.join(', ')}) to ask about a metric, or omit '
              'both for the configured rules',
              field: 'period');
        }

        final now = DateTime.now();
        // No owner filter and no is_active filter: the app reads every row
        // (`currency_dao.dart:14-20, 74`) and renders them in table order.
        final rows = db.query(
            'SELECT id, title, metric, period, threshold, type FROM user_currency '
            'ORDER BY rowid');
        final rules = [
          for (final row in rows) computeCurrencyRule(db, row, now),
        ];
        final unconfigured =
            metric != null && !rules.any((rule) => rule['metric'] == metric)
                ? currencyUnconfigured(db, metric, period, now)
                : null;
        return _ok({
          'checked_on': formatCalendarDate(now),
          'units': {'time': 'hours', 'counts': 'count'},
          'count': rules.length,
          'rules': rules,
          if (unconfigured != null) 'unconfigured': unconfigured,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, const {}, tool: 'get_flight_settings');
        final rows = db.query('SELECT * FROM flights_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, const {}, tool: 'get_app_settings');
        final rows = db.query('SELECT * FROM app_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, const {}, tool: 'get_general_settings');
        final rows = db.query('SELECT * FROM general_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'get_settings',
    description:
        'Get one settings table\'s row: ${_settingsTables.join(', ')}. Each holds '
        'a single row, and a fresh database has none until the app opens that '
        'screen, so an empty table answers {} rather than an error. Never '
        'creates the row. aircraft_type_settings is keyed by aircraft type '
        'rather than being a singleton, so it is not here.',
    inputSchema: JsonSchema.object(properties: {
      'table': JsonSchema.string(
          description: 'Settings table to read, one of the names above.'),
    }, required: [
      'table'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'table'}, tool: 'get_settings');
        final raw = args['table'];
        final table = asText(raw);
        if (table == null || !_settingsTables.contains(table)) {
          return _fail(
              'table must be one of ${_settingsTables.join(', ')} (got "$raw")',
              field: 'table');
        }
        if (!db.hasTable(table)) {
          return _fail(
              'This database (schema ${db.schemaVersion}) has no $table table',
              code: 'not_found',
              field: 'table');
        }
        // The same read the app's settings getters make: the first row, and
        // nothing inserted when there is none.
        final rows = db.query('SELECT * FROM $table LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'get_recent_logs',
    description:
        'Read recent log entries for diagnostics, newest first. Each entry is '
        'timestamp, level, category and the message cut to $_logMessageLimit '
        'characters; the stack trace is left out unless include_stack is true. '
        'Default 20 entries, maximum 200.',
    inputSchema: JsonSchema.object(properties: {
      'limit': _logLimitSchema,
      'include_stack': JsonSchema.boolean(
          description: 'Include each entry\'s stack trace. Default false, '
              'because one trace can be larger than the rest of the response.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'limit', 'include_stack'},
            tool: 'get_recent_logs');
        final limit = asInt(args['limit']) ?? 20;
        final includeStack = asBool(args['include_stack']) ?? false;
        final rows = db.query(
            'SELECT timestamp, level, category, message, stack_trace '
            'FROM log_entries ORDER BY timestamp DESC, id DESC LIMIT ?',
            [limit]);
        return _ok({
          'count': rows.length,
          'logs': [
            for (final row in rows)
              {
                'timestamp': row['timestamp'],
                'level': row['level'],
                'category': row['category'],
                'message': _truncateMessage(asText(row['message']) ?? ''),
                if (includeStack) 'stack_trace': row['stack_trace'],
              },
          ],
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
      'limit': _missingTimesLimitSchema,
      'full': _fullFlightSchema,
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'limit', 'full', _includeSharedKey},
            tool: 'find_missing_times');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
        _rejectUnknown(args, {_includeSharedKey}, tool: 'dedupe_crew');
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
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
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
          ..._flightWriteProperties(db, notes: true),
        },
        required: ['date'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'create_flight', args, () {
        if (asText(args['date']) == null) {
          throw _ToolError('date is required', field: 'date');
        }
        final flight = _flightValues(db, args, tool: 'create_flight');
        final date = asInt(flight.values['date']);
        if (date == null) throw _ToolError('date is required', field: 'date');
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
          'flight to another day. Returns the row as written as flight. The '
          'field notes and limits are on create_flight, and field meaning is '
          'in falcon://conventions.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._flightWriteProperties(db, notes: false),
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_flight', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        final before = _flightRow(db, id);
        if (before == null) {
          throw _ToolError('Flight not found: $id',
              code: 'not_found', field: 'id');
        }
        final flight = _flightValues(db, args, tool: 'update_flight');
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
        if (changed != 1) {
          throw _ToolError('Flight not found: $id',
              code: 'not_found', field: 'id');
        }
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
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db.query('SELECT id FROM flights WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Flight not found: $id',
              code: 'not_found', field: 'id');
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
        _rejectUnknown(args, _fieldNames(_aircraftColumns, {'id'}),
            tool: 'add_aircraft');
        final type = asText(args['type']);
        final registration = asText(args['registration']);
        if (type == null) throw _ToolError('type is required', field: 'type');
        if (registration == null) {
          throw _ToolError('registration is required', field: 'registration');
        }
        final countryCode = (asText(args['country_code']) ?? '').toUpperCase();
        final bare = _bareRegistration(registration, countryCode);
        if (bare.isEmpty) {
          throw _ToolError('registration is required', field: 'registration');
        }
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
        _rejectUnknown(args, _fieldNames(_aircraftColumns, {'id'}),
            tool: 'update_aircraft');
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        final rows = db.query('SELECT * FROM aircraft WHERE id = ?', [id]);
        if (rows.isEmpty) {
          throw _ToolError('Aircraft not found: $id',
              code: 'not_found', field: 'id');
        }

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
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db.query('SELECT id FROM aircraft WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Aircraft not found: $id',
              code: 'not_found', field: 'id');
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
        _rejectUnknown(args, _fieldNames(_crewColumns, {'id'}),
            tool: 'add_crew');
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
        _rejectUnknown(args, _fieldNames(_crewColumns, {'id'}),
            tool: 'update_crew');
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db
            .query('SELECT id FROM crew_members WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Crew member not found: $id',
              code: 'not_found', field: 'id');
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
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db
            .query('SELECT id FROM crew_members WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Crew member not found: $id',
              code: 'not_found', field: 'id');
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
        _rejectUnknown(args, _fieldNames(_customAirportColumns, {'id'}),
            tool: 'add_custom_airport');
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
        _rejectUnknown(args, _fieldNames(_customAirportColumns, {'id'}),
            tool: 'update_custom_airport');
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db.query(
            'SELECT id FROM custom_airports WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Custom airport not found: $id',
              code: 'not_found', field: 'id');
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
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db.query(
            'SELECT id FROM custom_airports WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Custom airport not found: $id',
              code: 'not_found', field: 'id');
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
        _rejectUnknown(args, _fieldNames(_savedRouteColumns, {'id'}),
            tool: 'add_saved_route');
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
        _rejectUnknown(args, _fieldNames(_savedRouteColumns, {'id'}),
            tool: 'update_saved_route');
        final id = asInt(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db
            .query('SELECT id FROM saved_routes WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Saved route not found: $id',
              code: 'not_found', field: 'id');
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
        if (id == null) throw _ToolError('Missing or invalid id', field: 'id');
        if (db
            .query('SELECT id FROM saved_routes WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Saved route not found: $id',
              code: 'not_found', field: 'id');
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
        _rejectUnknown(args, _fieldNames(_flightSettingsColumns),
            tool: 'update_flight_settings');
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
              field: entry.key,
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
                'Tools cover flights, aircraft, airports, crew, saved routes, expiries, currency, stats, settings, logs'
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
                '- Expiry status is computed at read time, never stored: whole local days from today to due_date, below the orange threshold is red (which includes today and every overdue day), below the green threshold is orange, green above it. Thresholds come from expiry_settings (a local row first, then the newest), or 90 and 30 days when that table has no row. list_expiries includes overdue rows by default.\n'
                '- Currency thresholds are HOURS for the four time metrics, because the app divides those values by 60, and counts for the other four. is_exceeded means the rule needs attention: for a requirement that is being below the threshold, for a limit it is reaching it. currency_status reproduces the app\'s currency page, which applies no owner filter and counts drafts as flights, so its numbers can mix owners on a synced logbook.\n'
                '- entity_totals.flights counts COMPLETE flights, because it counts the rows its minutes come from; logbook_stats.flights counts every row including drafts. Aircraft and type group on flights.aircraft_id and crew groups on flights.crew_member_id, so a flight that only carries registration text is in the registration group alone.\n'
                '- Deleting a flight, aircraft, crew member or custom airport also records a sync tombstone when a Postgres sync provider has been used, so the deletion propagates.\n'
                '- A field means the same thing wherever it appears: create_flight and update_flight take the same flight fields with the same types and limits, the per-field notes are written once on create_flight, and what a field means is written here.\n'
                '- Use get_schema for table names and their column counts; pass table for one table\'s columns, and detail: "full" for its default and pk columns too.\n'
                '- A failed call returns {error, field, detail}: error is a stable code (unknown_field, invalid_value, not_found, constraint, busy, internal), field is the argument at fault, and unknown_field also names the tool. detail is one sentence, and the accepted list is capped at eight names plus a count.',
          ),
        ],
      );
    },
  );

  server.registerResource(
    'schema',
    'falcon://schema',
    (
      description: 'Table names with their column counts, as JSON. Read one '
          'table\'s columns with the get_schema tool.',
      mimeType: 'application/json'
    ),
    (uri, extra) async {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'application/json',
            text: jsonEncode({'tables': _tableCounts(db)}),
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
                  'entity_totals, list_expiries, currency_status, '
                  'get_flight_settings, get_app_settings, get_general_settings, get_settings, '
                  'get_recent_logs, find_missing_times, dedupe_crew.\n'
                  '$writeTools\n'
                  'Call get_schema for table names and column counts, pass table for one table\'s columns, and read the falcon://conventions resource for field semantics (dates, minutes, registration format, draft rule).\n'
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
