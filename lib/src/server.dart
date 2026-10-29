import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'ask_user.dart';
import 'config.dart';
import 'currency.dart';
import 'db.dart';
import 'expiry.dart';
import 'route.dart';
import 'totals.dart';
import 'util.dart';
import 'zone.dart';

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
  // Planned times, from Falcon-Logbook/app#231 (schema 20). _supported drops
  // them on a database that has not migrated, so an older file is never offered
  // a field it cannot store.
  _Column('scheduled_departure_utc', _Kind.integer,
      note: 'Planned departure as unix epoch seconds UTC. A leg with planned '
          'times stays a draft: leave total_time empty.'),
  _Column('scheduled_arrival_utc', _Kind.integer,
      note: 'Planned arrival as unix epoch seconds UTC.'),
  _Column('scheduled_block_minutes', _Kind.integer,
      min: 0,
      max: maxFlightMinutes,
      note: 'Planned block time in minutes. Kept as the plan, never as '
          'total_time: a scheduled block is not time flown.'),
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
  'scheduled_block_minutes',
};

/// Time fields that also accept an `_hours` argument, converted once at the
/// boundary. The column itself keeps its minutes name, so a caller can pass
/// `1.5` hours without doing the arithmetic that turns a 1.5 hour flight into
/// 1 minute.
///
/// `scheduled_block_minutes` is the planned block, so its alias is only
/// advertised on a database that has the column.
const Map<String, String> _hoursAliases = {
  'total_time': 'total_time_hours',
  'day_time': 'day_time_hours',
  'night_time': 'night_time_hours',
  'scheduled_block_minutes': 'scheduled_block_minutes_hours',
};

/// Every response that carries a time or date field states its units here,
/// once per response rather than per row. `date` describes what a read
/// serialises: the `YYYY-MM-DD` calendar date [epochToCalendarDate] renders in
/// the logbook zone, not the epoch integer the column stores. Timestamps come
/// back as ISO-8601 with an explicit offset ([epochToIso]).
const Map<String, String> _units = {
  'time': 'minutes',
  'date': 'calendar_date',
};

/// The columns a flight summary carries: what was flown, when, in what, with
/// whom and how long. Every key is present even when the value is null, so a
/// missing reading reads as "not recorded" rather than as a key the caller has
/// to know about. Exactly these twelve: the summary is a cost contract, and
/// `route` already carries the direction a summary answers.
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
/// plus the two derived route codes when [full].
///
/// `departure_icao` and `arrival_icao` are parsed from `route`, never stored:
/// they say which way the flight went and stay null when the route is a
/// description, the same call the app makes. They are on `full` rows and
/// `get_flight` only, not the summary, because two mostly-null keys on every
/// listed row cost more than the raw route text they restate.
Map<String, dynamic> _flightView(Map<String, dynamic> row,
    {bool full = false}) {
  if (full) return {...row, ..._routeCodes(asText(row['route']))};
  return {for (final key in _slimFlightKeys) key: row[key]};
}

/// The direction a flight's free-text route describes, as the two read keys.
/// Both are null when the route is a description, which is what the app shows
/// as text.
Map<String, dynamic> _routeCodes(String? route) {
  final parsed = parseRoute(route);
  return {
    'departure_icao': parsed?.departure,
    'arrival_icao': parsed?.arrival,
  };
}

/// The `full` argument on the paged flight reads. The cost is stated here
/// because this is the argument a caller weighs.
JsonSchema get _fullFlightSchema => JsonSchema.boolean(
    description: 'Every column instead of the summary, at about four times the '
        'tokens.');

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

/// The arguments that narrow a flight read by what or who was on it, shared by
/// `list_flights` and `search_flights` so the two accept the same filters.
const Set<String> _flightNarrowingKeys = {
  'aircraft_registration',
  'flight_type',
  'crew_members_name',
  'departure_icao',
  'arrival_icao',
};

/// Every argument `list_flights` and `search_flights` accept as a filter: the
/// shared window and owner arguments plus the ones that narrow by aircraft,
/// type, crew or route direction.
const Set<String> _flightPageFilterKeys = {
  ..._flightFilterKeys,
  ..._flightNarrowingKeys,
};

// ============================================================
// Errors, results, coercion
// ============================================================

/// A problem the caller can fix. Reported as an MCP tool error, not a crash.
///
/// [code] is a token a caller can branch on, [field] is the argument at fault,
/// and [tool] is named when several tools could have refused. [detail] is one
/// sentence: no SQL, no file path, no database text. [data] carries extra
/// fields for codes that answer a question, such as the current row of a
/// conflict.
class _ToolError implements Exception {
  _ToolError(
    this.detail, {
    this.code = 'invalid_value',
    this.field,
    this.tool,
    this.data,
  });

  final String detail;
  final String code;
  final String? field;
  final String? tool;
  final Map<String, Object?>? data;

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
/// result, so a caller parses one shape either way. [data] merges extra
/// fields into the envelope, such as the current row of a conflict.
CallToolResult _fail(
  String detail, {
  String code = 'invalid_value',
  String? field,
  String? tool,
  Map<String, Object?>? data,
}) =>
    CallToolResult(
      content: [
        _jsonContent({
          'error': code,
          if (field != null) 'field': field,
          if (tool != null) 'tool': tool,
          if (data != null) ...data,
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
      data: error.data,
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
    // Half open: logbook-zone midnight of the day after the last requested
    // day.
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

/// Schema properties for the narrowing filters, shared by `list_flights` and
/// `search_flights`. Each one matches how the pilot writes it rather than how it
/// happens to be stored, because a filter that returns nothing teaches a caller
/// that there is no such flight.
Map<String, JsonSchema> _flightNarrowingProperties() => {
      'aircraft_registration':
          JsonSchema.string(description: 'Bare (XZO) or display (VH-XZO).'),
      'flight_type': JsonSchema.string(),
      'crew_members_name': JsonSchema.string(),
      'departure_icao': JsonSchema.string(),
      'arrival_icao': JsonSchema.string(),
    };

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

/// The aggregate row `logbook_stats` reports. `logbook_overview` reads the same
/// numbers from the same query over the same rows, so the two tools cannot
/// disagree about a logbook.
const String _flightAggregateSql = 'SELECT COUNT(*) AS flights, '
    'COALESCE(SUM(CASE WHEN total_time IS NOT NULL THEN 1 ELSE 0 END), 0) AS flights_complete, '
    'COALESCE(SUM(CASE WHEN total_time IS NULL THEN 1 ELSE 0 END), 0) AS drafts, '
    'COALESCE(SUM(CASE WHEN total_time = 0 THEN 1 ELSE 0 END), 0) AS zero_time, '
    'COALESCE(SUM(total_time), 0) AS total_minutes, '
    'COALESCE(SUM(night_time), 0) AS night_minutes, '
    'COALESCE(SUM(day_time), 0) AS day_minutes, '
    'COALESCE(SUM(landings), 0) AS landings, '
    'COALESCE(SUM(takeoffs), 0) AS takeoffs '
    'FROM flights';

/// The counts and sums, in minutes, of the flights [where] selects.
Map<String, dynamic> _flightAggregate(
    FalconDb db, List<String> where, List<Object?> params) {
  final rows = db.query('$_flightAggregateSql${_whereSql(where)}', params);
  return rows.isEmpty ? <String, dynamic>{} : rows.first;
}

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

/// `?, ?, ?` for [count] parameters, for the `IN` lists an alias filter builds.
String _marks(int count) => List.filled(count, '?').join(', ');

/// The WHERE terms for the narrowing filters on a flight read, normalised so a
/// near miss matches instead of quietly returning nothing.
///
/// `aircraft_registration` accepts either form the pilot writes, `XZO` or
/// `VH-XZO`, in any case, and additionally matches a flight linked to the same
/// aircraft when its stored text has drifted. `flight_type` compares without
/// case. `crew_members_name` compares without case and also matches a flight
/// whose `crew_member_id` resolves to a crew row of that name, because the
/// denormalised name can be null while the link is right. `departure_icao` and
/// `arrival_icao` match direction, never the whole string.
({List<String> where, List<Object?> params}) _flightNarrowing(
    FalconDb db, Map<String, dynamic> args) {
  final where = <String>[];
  final params = <Object?>[];

  final registration = asText(args['aircraft_registration']);
  if (registration != null) {
    final matches = _aircraftCandidates(db, registration);
    final displays = {
      _normalizeKey(registration),
      for (final match in matches) _normalizeKey(match.display),
    };
    final ids = [for (final match in matches) match.id];
    final terms = <String>[
      "upper(replace(replace(coalesce(aircraft_registration, ''), '-', ''), "
          "' ', '')) IN (${_marks(displays.length)})",
      if (ids.isNotEmpty) 'aircraft_id IN (${_marks(ids.length)})',
    ];
    where.add('(${terms.join(' OR ')})');
    params.addAll(displays);
    params.addAll(ids);
  }

  final type = asText(args['flight_type']);
  if (type != null) {
    where.add("lower(coalesce(flight_type, '')) = lower(?)");
    params.add(type);
  }

  final crew = asText(args['crew_members_name']);
  if (crew != null) {
    final ids = _crewIdsNamed(db, crew);
    final terms = <String>[
      "lower(coalesce(crew_members_name, '')) = lower(?)",
      if (ids.isNotEmpty) 'crew_member_id IN (${_marks(ids.length)})',
    ];
    where.add('(${terms.join(' OR ')})');
    params.add(crew);
    params.addAll(ids);
  }

  for (final direction in const ['departure_icao', 'arrival_icao']) {
    final code = asText(args[direction]);
    if (code == null) continue;
    where.add(_routeFilterSql(direction));
    params.add(code.toUpperCase());
  }
  return (where: where, params: params);
}

/// The departure or arrival segment of a route, as SQL: `parseRoute`'s rule in
/// a form the database can apply, so a filter and the derived read key agree
/// and `total`/`has_more` count the same rows the page holds.
const String _routeDepartureSql =
    "trim(substr(route, 1, instr(route, ' - ') - 1))";
const String _routeArrivalSql = "trim(substr(route, instr(route, ' - ') + 3))";

/// A WHERE term selecting rows whose route parses as an `AAA - BBB` pair and
/// whose [direction] segment equals the next parameter, compared without case.
///
/// The guards are the parser: one separator, a departure of 3 or 4 characters,
/// and an arrival the same length. A description, a bare code or a route with
/// two separators matches neither direction.
String _routeFilterSql(String direction) {
  final segment =
      direction == 'departure_icao' ? _routeDepartureSql : _routeArrivalSql;
  return "route IS NOT NULL "
      "AND instr(substr(route, instr(route, ' - ') + 3), ' - ') = 0 "
      'AND length($_routeDepartureSql) BETWEEN 3 AND 4 '
      'AND length($_routeDepartureSql) = length($_routeArrivalSql) '
      'AND UPPER($segment) = ?';
}

/// The match and rank SQL for one airport search.
///
/// The WHERE keeps every airport the text touches. The ORDER BY puts the one
/// the caller most likely means first: an exact code, then a prefix of one, then
/// a name or city that contains the text. ICAO breaks every tie, so the same
/// query returns the same order every time.
///
/// Both parameter lists are separate because the WHERE terms bind before the
/// ORDER BY terms; the caller appends them in that order.
({
  String where,
  List<Object?> whereParams,
  String order,
  List<Object?> orderParams,
}) _airportRank(String query) {
  final escaped = escapeLike(query.toUpperCase());
  final prefix = '$escaped%';
  final contains = '%$escaped%';
  return (
    where: "(upper(icao) LIKE ? ESCAPE '\\' "
        "OR upper(coalesce(iata, '')) LIKE ? ESCAPE '\\' "
        "OR upper(name) LIKE ? ESCAPE '\\' "
        "OR upper(coalesce(city, '')) LIKE ? ESCAPE '\\')",
    whereParams: [contains, contains, contains, contains],
    order: 'CASE '
        'WHEN upper(icao) = ? THEN 0 '
        "WHEN upper(coalesce(iata, '')) = ? THEN 1 "
        "WHEN upper(icao) LIKE ? ESCAPE '\\' THEN 2 "
        "WHEN upper(coalesce(iata, '')) LIKE ? ESCAPE '\\' THEN 3 "
        "WHEN upper(name) LIKE ? ESCAPE '\\' THEN 4 "
        'ELSE 5 END',
    orderParams: [escaped, escaped, prefix, prefix, contains],
  );
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
    String? result,
    List<String>? ids,
    List<String>? refs,
  }) {
    appendAudit(dbPath, {
      'ts': DateTime.now().toUtc().toIso8601String(),
      'tool': tool,
      'args': args,
      'result': result ?? (error == null ? 'ok' : 'error'),
      if (id != null) 'id': id,
      if (ids != null) 'ids': ids,
      if (refs != null) 'created_refs': refs,
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
  final dryRun = args['dry_run'] == true;
  try {
    final result = db.transaction(() {
      final value = body();
      // A dry run previews with the body's own machinery: it resolves ids and
      // links, renders the row as written and collects warnings, then this
      // throw rolls the transaction back. A validation failure on the way
      // still surfaces as that write's error, which is the point of a preview.
      if (dryRun) {
        throw _DryRun(Map<String, Object?>.of(value as Map<String, Object?>));
      }
      return value;
    });
    final id = result is Map ? result['id'] : null;
    final ids = result is Map ? result['affected_ids'] : null;
    final refs = result is Map ? result['created_refs'] : null;
    auditor.record(tool, args,
        id: id?.toString(),
        ids: ids is List ? ids.cast<String>() : null,
        refs: refs is List ? refs.cast<String>() : null);
    return _ok(result);
  } on _DryRun catch (dry) {
    final ids = dry.result['affected_ids'];
    final refs = dry.result['created_refs'];
    auditor.record(tool, args,
        id: dry.result['id']?.toString(),
        ids: ids is List ? ids.cast<String>() : null,
        refs: refs is List ? refs.cast<String>() : null,
        result: 'dry_run');
    return _ok({...dry.result, 'dry_run': true});
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

/// The rows that tie for a name or registration, as one short line for a
/// warning: id, display text, and for aircraft the country and archived flag.
/// Capped at four, because a warning must not become the response.
String _candidatesText(List<Map<String, dynamic>> candidates) {
  final shown = [
    for (final candidate in candidates.take(4))
      [
        candidate['id'],
        candidate['registration'] ?? candidate['name'],
        if (candidate['country_code'] != null) candidate['country_code'],
        if (candidate['archived'] == true) 'archived',
      ].join(' '),
  ];
  final rest = candidates.length - shown.length;
  return '${shown.join('; ')}${rest > 0 ? '; and $rest more' : ''}';
}

/// A `*_date` column's value as the calendar date in the logbook zone.
/// [FalconDb] renders an epoch `*_date` column as `YYYY-MM-DD`, so that is
/// what a read sees. An integer is accepted too, for a query that bypasses the
/// mapper, and a wider timestamp is converted as an instant: its date in the
/// logbook zone, never the fields the host zone happens to parse it into.
DateTime? _localDate(Object? value) {
  if (value is int) return logbookDateFromEpoch(value);
  if (value is! String) return null;
  final calendar = parseCalendarDate(value);
  if (calendar != null) return calendar;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return logbookDateFromEpoch(parsed.millisecondsSinceEpoch ~/ 1000);
}

/// Display registration the app would show: the one rule [displayRegistration]
/// writes, kept as a non-null wrapper for the matcher, which has already
/// skipped a blank registration.
String _displayRegistration(String? countryCode, String registration) =>
    displayRegistration(countryCode, registration) ?? registration;

/// Today's logbook-zone midnight as the epoch seconds a `date` column stores,
/// so "future" in a report means after today, not after this second.
int _todayLocalMidnightEpoch() => epochForDayStart(nowInLogbookZone());

/// The pilot's own registration country from `flights_settings`, or null. The
/// aircraft link prefers it when one bare registration exists under two
/// country codes, because the pilot's fleet is the likelier match.
String? _logbookCountry(FalconDb db) {
  if (!db.hasTable('flights_settings') ||
      !db.columnsOf('flights_settings').contains('logbook_country')) {
    return null;
  }
  final rows = db.query('SELECT logbook_country FROM flights_settings '
      "WHERE logbook_country IS NOT NULL AND logbook_country != '' LIMIT 1");
  return rows.isEmpty ? null : asText(rows.first['logbook_country']);
}

/// The registration country prefixes the pilot's own fleet carries, from
/// `flights_settings.logbook_country`.
///
/// `logbook_country` is the CAA authority ('AU' or 'NZ'), not a registration
/// prefix, so it maps to the prefix a fleet of that authority carries (VH,
/// ZK). The authority itself is accepted too, because the app's importer
/// writes `logbook_country` as the default aircraft country code. The aircraft
/// link prefers these when one bare registration exists under two codes,
/// because the pilot's own fleet is the likelier match.
Set<String> _preferredCountryCodes(FalconDb db) {
  final country = _logbookCountry(db)?.toUpperCase();
  if (country == null) return const {};
  final prefix = switch (country) {
    'AU' => 'VH',
    'NZ' => 'ZK',
    _ => null,
  };
  return prefix == null ? {country} : {country, prefix};
}

/// A list-of-ids argument as clean strings, refusing anything else so a
/// malformed call fails loudly instead of silently linking nothing.
List<String> _idListArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return const [];
  if (value is! List) {
    throw _ToolError('$key must be a list of ids', field: key);
  }
  final ids = <String>[];
  for (final entry in value) {
    final id = asText(entry);
    if (id == null) {
      throw _ToolError('$key must be a list of ids', field: key);
    }
    ids.add(id);
  }
  return ids;
}

/// Every aircraft whose stored registration or display form normalises to the
/// same key as [registration], active rows only when any are active.
///
/// [registration] may be written bare (`XZO`) or in display form (`VH-XZO`), in
/// any case.
List<({String id, String display, String countryCode, bool archived})>
    _aircraftCandidates(FalconDb db, String registration) {
  final wanted = _normalizeKey(registration);
  if (wanted.isEmpty) return const [];
  final rows = db.query(
    'SELECT id, country_code, registration, archived FROM aircraft '
    'ORDER BY archived ASC, registration',
  );
  final matches =
      <({String id, String display, String countryCode, bool archived})>[];
  for (final row in rows) {
    final reg = asText(row['registration']);
    if (reg == null) continue;
    final countryCode = asText(row['country_code']) ?? '';
    final display = _displayRegistration(countryCode, reg);
    if (_normalizeKey(reg) == wanted || _normalizeKey(display) == wanted) {
      matches.add((
        id: row['id'] as String,
        display: display,
        countryCode: countryCode,
        archived: asBool(row['archived']) ?? false,
      ));
    }
  }
  return _activeOr(matches, (match) => match.archived);
}

/// Every crew member whose name, first-last or last-first form normalises to the
/// same key as [name], active rows only when any are active.
List<({String id, String name, bool archived})> _crewCandidates(
    FalconDb db, String name) {
  final wanted = _normalizeKey(name);
  if (wanted.isEmpty) return const [];
  final rows = db.query(
    'SELECT id, name, first_name, last_name, archived FROM crew_members '
    'ORDER BY archived ASC, name',
  );
  final matches = <({String id, String name, bool archived})>[];
  for (final row in rows) {
    final forms = <String>[
      row['name'] as String? ?? '',
      '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}',
      '${row['last_name'] ?? ''} ${row['first_name'] ?? ''}',
    ];
    final trimmed = forms.map(asText).whereType<String>();
    if (!trimmed.any((form) => _normalizeKey(form) == wanted)) continue;
    matches.add((
      id: row['id'] as String,
      name: asText(row['name']) ?? '',
      archived: asBool(row['archived']) ?? false,
    ));
  }
  return _activeOr(matches, (match) => match.archived);
}

/// The rows to match against: the active ones when there are any, all of them
/// otherwise. An archived row is the fallback because the pilot may have retired
/// the only tail that matches.
List<T> _activeOr<T>(List<T> rows, bool Function(T row) archived) {
  final active = [
    for (final row in rows)
      if (!archived(row)) row,
  ];
  return active.isEmpty ? rows : active;
}

/// The aircraft a write should link to, or the rows that tie when the
/// registration names more than one.
///
/// Picking the first of two tails with the same registration would link the
/// flight to whichever row happens to sort first, so an ambiguous key leaves
/// the link unset and the candidates are reported instead.
({String? id, String? display, List<Map<String, dynamic>> candidates})
    _matchAircraft(FalconDb db, String registration) {
  final matches = _aircraftCandidates(db, registration);
  if (matches.length == 1) {
    final only = matches.single;
    return (id: only.id, display: only.display, candidates: const []);
  }
  return (
    id: null,
    display: null,
    candidates: [
      for (final match in matches)
        {
          'id': match.id,
          'registration': match.display,
          'country_code': match.countryCode,
          'archived': match.archived,
        },
    ],
  );
}

/// The crew member a write should link to, or the rows that tie. See
/// [_matchAircraft] for why a tie is not guessed.
({String? id, List<Map<String, dynamic>> candidates}) _matchCrewMemberId(
    FalconDb db, String name) {
  final matches = _crewCandidates(db, name);
  if (matches.length == 1) {
    return (id: matches.single.id, candidates: const []);
  }
  return (
    id: null,
    candidates: [
      for (final match in matches)
        {'id': match.id, 'name': match.name, 'archived': match.archived},
    ],
  );
}

/// The ids of every crew row a name filter could mean, so a flight linked by
/// `crew_member_id` matches a name filter even when its stored name is null.
List<String> _crewIdsNamed(FalconDb db, String name) =>
    [for (final match in _crewCandidates(db, name)) match.id];

/// The most rows any one `data_quality_report` class shows in its sample. A
/// count is the finding; four rows is enough to start acting on it.
const _reportSampleCap = 4;

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
  _rejectUnknown(
      args,
      _fieldNames(
          _flightColumns, {'id', ..._hoursAliases.values, 'draft', 'dry_run'}),
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
      values['aircraft_registration'] = match.display ?? text;
      values['aircraft_id'] = match.id;
      if (match.candidates.length > 1) {
        warnings.add(
            '${match.candidates.length} aircraft match "$text", so the flight '
            'is not linked: ${_candidatesText(match.candidates)}. Pass '
            'aircraft_id to choose one.');
      } else if (match.id == null) {
        warnings.add(
            'No aircraft matched "$text"; the flight is not linked to an aircraft.');
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
      final match = _matchCrewMemberId(db, name);
      values['crew_members_name'] = name;
      values['crew_member_id'] = match.id;
      if (match.candidates.length > 1) {
        warnings.add(
            '${match.candidates.length} crew members match "$name", so the '
            'flight is not linked: ${_candidatesText(match.candidates)}. Pass '
            'crew_member_id to choose one.');
      }
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

  // A route that does not parse is legal: the app stores it as a description.
  // It is worth saying, though, because it has no direction, so every
  // departure_icao/arrival_icao filter will miss it.
  final route = asText(values['route']);
  if (route != null && parseRoute(route) == null) {
    warnings.add(
        'route "$route" is not a two-airport route, so the app shows it as a '
        'description and it has no departure_icao or arrival_icao. Write it as '
        '"YSSY - NZQN" for a route.');
  }
  return (values: values, warnings: warnings);
}

/// What `find_missing_times` looks for: a flight whose times are not complete.
///
/// A draft has no total. A complete flight needs both sides of the split, and
/// the two sides must add up to the total, which is the rule the app's wizard
/// enforces on save. `day_time + night_time != total_time` is null when the
/// total is null, so the draft case is named first.
const String _missingTimePredicate =
    '(total_time IS NULL OR day_time IS NULL OR night_time IS NULL '
    'OR day_time + night_time != total_time)';

/// Why [row] is in that list, so a caller does not have to read three nulls.
String _missingTimeReason(Map<String, dynamic> row) {
  final total = asInt(row['total_time']);
  final day = asInt(row['day_time']);
  final night = asInt(row['night_time']);
  if (total == null) {
    return (asBool(row['is_simulator']) ?? false)
        ? 'simulator_no_duration'
        : 'draft';
  }
  if (day == null && night == null) return 'missing_split';
  if (day == null || night == null) return 'half_split';
  return 'split_mismatch';
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

// ============================================================
// Roster import
// ============================================================

/// The most rows one roster call takes. A roster is a month of flying and the
/// answer carries an entry per row, so past this the agent splits the roster
/// rather than paying for a response nobody reads.
const int _rosterRowCap = 500;

/// Roster-only row keys: what a pasted line carries that is not a flight
/// column. `client_ref` identifies a row across retries, `aircraft_type` is a
/// hint the validator uses to name a missing aircraft. Neither is stored.
const String _clientRefKey = 'client_ref';
const String _aircraftTypeKey = 'aircraft_type';

/// The planned-time columns, from Falcon-Logbook/app#231 (schema 20). All three
/// arrive together; a database that has none of them does not store planned
/// times at all.
const List<String> _plannedTimeFields = [
  'scheduled_departure_utc',
  'scheduled_arrival_utc',
  'scheduled_block_minutes',
];

/// Whether this database stores planned times. The schema gate is the live
/// table, not `maxSchemaVersion`: the app migration has not shipped, so a v19
/// file simply has no such columns.
bool _plannedTimesAvailable(FalconDb db) {
  final columns = db.columnsOf('flights').toSet();
  return _plannedTimeFields.every(columns.contains);
}

/// The fields one roster row may carry: the flight write fields, the `_hours`
/// aliases, `draft`, and the two roster-only keys. `_flightValues` builds the
/// row itself, so this set only says which names reach it.
final Set<String> _rosterRowFields = _fieldNames(_flightColumns, {
  ..._hoursAliases.values,
  'draft',
  _clientRefKey,
  _aircraftTypeKey,
});

/// One roster row after validation: the values `_flightValues` built, the
/// structured issues the roster rules (and its own refusal) raised, and the
/// prose warnings that carry no code.
///
/// [ok] is the atomicity decision: a row with an error-severity issue would not
/// be written, so `apply_flight_batch` refuses the whole batch by default.
class _RosterRow {
  _RosterRow(this.index, this.clientRef);

  final int index;
  final String? clientRef;
  Map<String, Object?>? values;
  final List<Map<String, dynamic>> issues = [];
  final List<String> warnings = [];

  bool get ok => !issues.any((issue) => issue['severity'] == 'error');

  /// The first error message, for a one-line `failed` reason.
  String get firstError {
    for (final issue in issues) {
      if (issue['severity'] == 'error') return '${issue['message']}';
    }
    return 'invalid row';
  }

  void add(
    String code,
    String message, {
    String? field,
    String severity = 'error',
    List<Map<String, dynamic>> candidates = const [],
  }) {
    issues.add({
      if (field != null) 'field': field,
      'code': code,
      'message': message,
      'severity': severity,
      if (candidates.isNotEmpty) 'candidates': candidates,
    });
  }

  /// The code of the skip this row is, if any: a duplicate is not a failure,
  /// it is a row the logbook already holds.
  String? get skipCode {
    for (final issue in issues) {
      final code = issue['code'];
      if (code == 'duplicate_existing' ||
          code == 'duplicate_batch' ||
          code == 'client_ref_seen') {
        return code as String;
      }
    }
    return null;
  }
}

/// The `flights` argument, as the rows a roster call works through.
List<dynamic> _rosterFlightRows(Map<String, dynamic> args) {
  final raw = args['flights'];
  if (raw is! List) {
    throw _ToolError('flights must be an array of flight objects',
        field: 'flights');
  }
  if (raw.length > _rosterRowCap) {
    throw _ToolError(
        'flights takes at most $_rosterRowCap rows; split the roster into '
        'batches of $_rosterRowCap or fewer',
        field: 'flights');
  }
  return raw;
}

/// The stated roster range, both bounds optional, refused when reversed.
({DateTime? from, DateTime? to}) _rosterRange(Map<String, dynamic> args) {
  final from = _readDate(args, 'date_from');
  final to = _readDate(args, 'date_to');
  if (from != null && to != null && from.isAfter(to)) {
    throw _ToolError(
        'date_from (${formatCalendarDate(from)}) must not be after '
        'date_to (${formatCalendarDate(to)})',
        field: 'date_from');
  }
  return (from: from, to: to);
}

/// The stable issue code for a refusal `_flightValues` raised on one row.
/// Every class a roster can hit has a code an agent can branch on; anything
/// else is one bad value.
String _rosterIssueCode(_ToolError error) => switch (error.field) {
      'crew_role' => 'invalid_crew_role',
      'flight_type' => 'invalid_flight_type',
      'calc_time_mode' => 'invalid_calc_time_mode',
      'aircraft_id' => 'aircraft_not_found',
      'crew_member_id' => 'crew_not_found',
      _ => error.code == 'unknown_field' ? 'unknown_field' : 'invalid_row',
    };

/// The active tails of [type], for the row that names a type but no
/// registration. Empty when the fleet has no such type, which is still said.
List<Map<String, dynamic>> _aircraftOfType(FalconDb db, String type) {
  final rows = db.query('SELECT id, type, country_code, registration, archived '
      'FROM aircraft ORDER BY archived ASC, registration');
  final wanted = _normalizeKey(type);
  final matches = <Map<String, dynamic>>[];
  for (final row in rows) {
    final stored = asText(row['type']);
    if (stored == null || _normalizeKey(stored) != wanted) continue;
    matches.add({
      'id': row['id'],
      'registration': _displayRegistration(
          asText(row['country_code']), asText(row['registration']) ?? ''),
      'archived': asBool(row['archived']) ?? false,
    });
  }
  final active = [
    for (final match in matches)
      if (match['archived'] != true) match,
  ];
  return active.isEmpty ? matches : active;
}

/// Whether the database holds any airport to resolve a route segment against.
/// An empty reference list is the app's airport import not having run, not a
/// typo, so the validator says nothing about segments in that case.
bool _hasAirports(FalconDb db) {
  for (final table in ['airports', 'custom_airports']) {
    if (!db.hasTable(table)) continue;
    if (db.query('SELECT 1 FROM $table LIMIT 1').isNotEmpty) return true;
  }
  return false;
}

/// Whether [code] is an ICAO or IATA code of a built-in or custom airport.
bool _airportExists(FalconDb db, String code) {
  final wanted = code.trim().toUpperCase();
  if (wanted.isEmpty) return false;
  for (final table in ['airports', 'custom_airports']) {
    if (!db.hasTable(table)) continue;
    final rows = db.query(
      'SELECT 1 FROM $table WHERE upper(icao) = ? '
      "OR upper(coalesce(iata, '')) = ? LIMIT 1",
      [wanted, wanted],
    );
    if (rows.isNotEmpty) return true;
  }
  return false;
}

/// The id of an existing flight with the same identity a roster row would
/// write: date, route, registration and total time. Null when there is none.
String? _existingFlightId(FalconDb db, Object? date, String? route,
    String? registration, Object? total) {
  final rows = db.query(
    "SELECT id FROM flights WHERE date = ? AND coalesce(route, '') = ? "
    "AND coalesce(aircraft_registration, '') = ? AND total_time IS ? LIMIT 1",
    [date, route ?? '', registration ?? '', total],
  );
  return rows.isEmpty ? null : rows.first['id'] as String?;
}

/// One row's identity for duplicate detection: date, route, registration and
/// total time, as the write would store them.
String _rosterIdentity(Map<String, Object?> values) => [
      values['date'],
      asText(values['route']) ?? '',
      asText(values['aircraft_registration']) ?? '',
      values['total_time'] ?? 'null',
    ].join('\u{1}');

// ------------------------------------------------------------
// Logbook import (mode: import)
// ------------------------------------------------------------

/// The row convention a batch call declares. `roster` (default) is a pasted
/// schedule of planned legs, exactly the behaviour the roster engine had
/// before this existed; `import` is rows read from a logbook file, where the
/// date and unit rules below are strict. A roster call pays for none of them.
JsonSchema get _importModeSchema => JsonSchema.string(
      enumValues: const ['roster', 'import'],
      description: 'roster (default): a pasted schedule, validated as today. '
          'import: rows read from a logbook file, validated strictly (date '
          'must be YYYY-MM-DD with serials and other readings refused, '
          'durations read in the declared units, unknown columns reported).',
    );

/// How the rows of an import write durations, declared once for the whole
/// call. The file's convention is never guessed per cell: mixed units in one
/// file are an error, not a conversion.
JsonSchema get _importUnitsSchema => JsonSchema.string(
      enumValues: const ['minutes', 'decimal_hours', 'hhmm'],
      description: 'How duration cells are written: minutes (default, whole '
          'minutes), decimal_hours (1.5 is 90 minutes) or hhmm (1:30 is 90 '
          'minutes). Used only when mode is import; a cell that does not match '
          'the declared unit is refused, never read in another one.',
    );

/// The declarations of one batch call, validated. [import] is the flag every
/// import-only rule gates on, so a roster call pays nothing for them.
({bool import, String units}) _importSettings(Map<String, dynamic> args) {
  final mode = asText(args['mode']) ?? 'roster';
  if (mode != 'roster' && mode != 'import') {
    throw _ToolError('mode must be one of roster, import (got "$mode")',
        field: 'mode');
  }
  final units = asText(args['units']) ?? 'minutes';
  if (!const {'minutes', 'decimal_hours', 'hhmm'}.contains(units)) {
    throw _ToolError(
        'units must be one of minutes, decimal_hours, hhmm (got "$units")',
        field: 'units');
  }
  return (import: mode == 'import', units: units);
}

/// The spreadsheet serial epoch: a serial cell shows 1899-12-30 plus that many
/// days (the one-day offset is the 1900 leap year bug, which Excel and Sheets
/// both inherit). What the cell shows is what the refusal names; the server
/// never converts one, because a wrong reading moves a flight between months
/// and years.
final DateTime _serialEpoch = DateTime.utc(1899, 12, 30);

/// The shapes an import date cell arrives in that are not the one accepted
/// form: the strict shape, the timestamp that starts with one, a bare number
/// (a spreadsheet serial), and three numeric fields with any separator.
final RegExp _isoDateShape = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final RegExp _isoDatePrefix = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:[Tt ].*)?$');
final RegExp _numberOnly = RegExp(r'^-?\d+(?:\.\d+)?$');
final RegExp _threeFields =
    RegExp(r'^(\d{1,4})[/.\-](\d{1,2})[/.\-](\d{1,4})$');
final RegExp _hhmmCell = RegExp(r'^(\d{1,2}):([0-5]\d)$');

/// The last serial a spreadsheet can show: 1899-12-30 plus this many days is
/// 9999-12-31, and a cell cannot hold a later date than that.
const int _maxSerial = 2958465;

/// The `YYYY-MM-DD` a spreadsheet cell with [serial] shows. A fractional
/// serial carries a time of day, so the day is floored.
///
/// Null when the serial is outside the range a cell can show (negative,
/// beyond [_maxSerial], or not a finite number): flooring it would throw, and
/// adding it as a [Duration] would wrap into a date the cell never showed.
String? _serialReading(num serial) {
  if (!serial.isFinite || serial < 0 || serial > _maxSerial) return null;
  final days = serial.floor();
  return formatCalendarDate(_serialEpoch.add(Duration(days: days)));
}

/// The refusal for an import `date` cell that is not strict `YYYY-MM-DD`, or
/// null when the cell is fine and the row builder can take it. A spreadsheet
/// serial is named with the date it shows, a text date with its probable
/// reading (both readings when a slash date is ambiguous), and neither is ever
/// converted: the pilot confirms and re-sends.
({String code, String message})? _importDateIssue(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) {
    if (raw is num) return _serialDateIssue(raw, '$raw');
    return (code: 'date_format', message: _dateMessage('$raw', const [], null));
  }
  final text = raw.trim();
  if (text.isEmpty) {
    return (
      code: 'date_missing',
      message: 'date is required: every import row needs the date it was flown',
    );
  }
  if (_isoDateShape.hasMatch(text)) {
    if (parseCalendarDate(text) != null) return null;
    return (
      code: 'date_format',
      message: 'date "$text" is not a real calendar date: its month or day '
          'does not exist. The server never fixes one up; ask the pilot for '
          'the date as YYYY-MM-DD.',
    );
  }
  final numeric = _numberOnly.hasMatch(text) ? num.tryParse(text) : null;
  if (numeric != null) return _serialDateIssue(numeric, text);
  final readings = _dateReadings(text);
  return (
    code: 'date_format',
    message: _dateMessage(text, readings.readings, readings.note),
  );
}

/// The refusal for a spreadsheet serial cell. [text] is the cell as written,
/// so a numeric string is echoed as typed rather than as the number Dart
/// parsed it into.
({String code, String message}) _serialDateIssue(num serial, String text) {
  final reading = _serialReading(serial);
  if (reading == null) {
    return (
      code: 'serial_date',
      message: 'date $text is a spreadsheet serial number outside the range a '
          'spreadsheet can show: the last one it can hold is $_maxSerial '
          '(9999-12-31). It is refused and never converted: ask the pilot to '
          'confirm the date and send it as YYYY-MM-DD.',
    );
  }
  return (
    code: 'serial_date',
    message: 'date $text is a spreadsheet serial number, which shows '
        '$reading (DateTime.utc(1899, 12, 30) plus '
        '${serial.floor()} days). Serial numbers are refused and never '
        'converted: ask the pilot to confirm the date and send it as '
        'YYYY-MM-DD.',
  );
}

/// The `date_format` refusal for [text] with the readings the server can see
/// in it. One reading is stated as probable, two are both named because the
/// server never guesses between D/M/Y and M/D/Y. [note] adds what the shape of
/// the cell says beyond its reading, such as a timestamp crossing the day
/// boundary in the logbook zone.
String _dateMessage(String text, List<String> readings, String? note) {
  if (readings.isEmpty) {
    return 'date "$text" is not YYYY-MM-DD and no reading can be guessed from '
        'it. Ask the pilot which date this row was flown and send it as '
        'YYYY-MM-DD.';
  }
  if (readings.length == 1) {
    return 'date "$text" is not YYYY-MM-DD; it probably means ${readings[0]}. '
        '${note == null ? '' : '$note '}'
        'Dates are refused and never converted: ask the pilot to confirm and '
        'send date as YYYY-MM-DD.';
  }
  return 'date "$text" is not YYYY-MM-DD and both of its first two fields are '
      '12 or less: it reads as ${readings[0]} (D/M/Y) or ${readings[1]} '
      '(M/D/Y). Ask the pilot which convention the file uses; the server '
      'never guesses.';
}

/// The zone designator that turns a timestamp into an instant: a trailing `Z`
/// or a `+hh:mm` / `-hh:mm` offset. Without one the text is a wall clock
/// reading, whose zone nobody knows.
final RegExp _timestampZone = RegExp(r'(?:[Zz]|[+-]\d{2}:?\d{2})$');

/// The logbook-zone calendar date a timestamp falls on, or null when [text] is
/// not one or carries no zone. A timestamp with a zone is an instant, so this
/// is the day it was flown in the logbook zone; a naive timestamp is only the
/// wall clock its text states, so its own fields are the safest reading.
String? _zonedDate(String text) {
  if (!_timestampZone.hasMatch(text)) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  return formatCalendarDate(
      logbookDateFromEpoch(parsed.millisecondsSinceEpoch ~/ 1000));
}

/// The probable `YYYY-MM-DD` readings of a non-ISO date cell: one when the
/// shape fixes it, two when a slash date could be D/M/Y or M/D/Y, none when
/// nothing can be guessed. Only real calendar dates are named.
///
/// A timestamp's reading is the logbook-zone day it falls on, and [note] says
/// so when that day differs from the date its text starts with: a row logged
/// late in the evening UTC is the next day's flight in the logbook zone.
({List<String> readings, String? note}) _dateReadings(String text) {
  String? reading(int year, int month, int day) {
    final date = logbookDateAt(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return formatCalendarDate(date);
  }

  final iso = _isoDatePrefix.firstMatch(text);
  if (iso != null) {
    final stated = iso.group(1)!;
    final date = parseCalendarDate(stated);
    if (date == null) return (readings: const [], note: null);
    final zoned = _zonedDate(text);
    if (zoned == null) {
      return (readings: [formatCalendarDate(date)], note: null);
    }
    return (
      readings: [zoned],
      note: zoned == stated
          ? null
          : 'Its text starts with $stated, but in the logbook zone that '
              'instant falls on $zoned.',
    );
  }
  final fields = _threeFields.firstMatch(text);
  if (fields == null) return (readings: const [], note: null);
  final first = int.parse(fields.group(1)!);
  final second = int.parse(fields.group(2)!);
  final third = int.parse(fields.group(3)!);
  // A four-digit first field is the year: 2026/10/27 is Y/M/D everywhere.
  if (fields.group(1)!.length == 4) {
    final date = reading(first, second, third);
    return (readings: date == null ? const [] : [date], note: null);
  }
  if (fields.group(3)!.length != 4) return (readings: const [], note: null);
  final year = third;
  if (first > 12 && second > 12) return (readings: const [], note: null);
  if (first > 12) {
    final date = reading(year, second, first);
    return (readings: date == null ? const [] : [date], note: null);
  }
  if (second > 12) {
    final date = reading(year, first, second);
    return (readings: date == null ? const [] : [date], note: null);
  }
  final readings = <String>[];
  final dmy = reading(year, second, first);
  if (dmy != null) readings.add(dmy);
  final mdy = reading(year, first, second);
  if (mdy != null) readings.add(mdy);
  return (readings: readings, note: null);
}

/// [exact] as the minute count a message names: at most two decimals, so
/// floating point noise is not reported as precision.
String _exactMinutes(double exact) =>
    exact.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

/// One duration cell of an import row as whole minutes in the declared
/// [units], or the refusal saying why it cannot be read.
///
/// The declared unit is the file's convention, chosen once on the call. A
/// cell that does not match is refused rather than read in another unit:
/// `1:30` in a decimal file and `1.5` in an hhmm file are exactly the mixed
/// units this rule stops.
({Object? value, String? code, String? message}) _importMinutes(
    String column, Object? raw, String units) {
  String mismatch() => '$column "$raw" is not $units: the call declared units '
      '$units for this file. Mixed units are refused, never guessed; ask the '
      'pilot which convention the column uses.';

  final int minutes;
  if (units == 'minutes') {
    final value = asInt(raw);
    if (value == null) {
      return (value: null, code: 'unit_mismatch', message: mismatch());
    }
    minutes = value;
  } else if (units == 'decimal_hours') {
    final hours = asDouble(raw);
    if (hours == null) {
      return (value: null, code: 'unit_mismatch', message: mismatch());
    }
    final exact = hours * 60;
    final rounded = exact.round();
    if ((exact - rounded).abs() > 1e-6) {
      return (
        value: null,
        code: 'unit_implausible',
        message: '$column $raw decimal_hours is ${_exactMinutes(exact)} '
            'minutes, which is not a whole minute. A duration is refused, '
            'never rounded; ask the pilot for the real value.',
      );
    }
    minutes = rounded;
  } else {
    final match = raw is String ? _hhmmCell.firstMatch(raw.trim()) : null;
    if (match == null) {
      return (value: null, code: 'unit_mismatch', message: mismatch());
    }
    minutes = int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
  }
  if (minutes < 0 || minutes > maxFlightMinutes) {
    return (
      value: null,
      code: 'unit_implausible',
      message: '$column "$raw" is $minutes minutes, outside 0 to '
          '$maxFlightMinutes minutes (${maxFlightMinutes ~/ 60} hours).',
    );
  }
  return (value: minutes, code: null, message: null);
}

/// The curated home for the source columns a logbook file carries that Falcon
/// has no exact name for: instructing, PIC, copilot, block, start/stop, rego,
/// type, remarks and date headers. Matched on the tokens of the source header,
/// most specific family first, and every column named is one the live write
/// path can store, so a hint never offers a column this build would refuse.
const List<({List<String> tokens, List<String> columns, String hint})>
    _importColumnAliases = [
  (
    tokens: ['BLOCKOFF'],
    columns: ['time_start'],
    hint: 'A block-off column is time_start, a HH:MM clock time.'
  ),
  (
    tokens: ['BLOCKON'],
    columns: ['time_stop'],
    hint: 'A block-on column is time_stop, a HH:MM clock time.'
  ),
  (
    tokens: ['START', 'OFF'],
    columns: ['time_start'],
    hint: 'An off or start column is time_start, a HH:MM clock time.'
  ),
  (
    tokens: ['STOP', 'ON'],
    columns: ['time_stop'],
    hint: 'An on or stop column is time_stop, a HH:MM clock time.'
  ),
  (
    tokens: ['INSTRUCT', 'INSTR', 'ICUS', 'PICUS'],
    columns: ['icus_day_time', 'icus_night_time'],
    hint: 'Instructing and PICUS time map to icus_day_time and icus_night_time.'
  ),
  (
    tokens: ['PIC'],
    columns: ['crew_role'],
    hint: 'A PIC column maps to crew_role = pilotInCommand per row.'
  ),
  (
    tokens: ['COPILOT', 'FIRSTOFFICER', 'SIC'],
    columns: ['crew_role'],
    hint: 'A copilot column maps to crew_role = copilot.'
  ),
  (
    tokens: ['TOTAL', 'BLOCK'],
    columns: ['total_time'],
    hint: 'A total or block column is total_time, in minutes.'
  ),
  (
    tokens: ['REGO', 'REGISTRATION', 'REG', 'TAIL'],
    columns: ['aircraft_registration'],
    hint:
        'A rego or tail column is aircraft_registration; never infer a tail from a type.'
  ),
  (
    tokens: ['TYPE'],
    columns: [],
    hint: 'An aircraft type has no flight column: pass it as the aircraft_type '
        'row hint and map tails with list_aircraft.'
  ),
  (
    tokens: ['REMARK', 'NOTE', 'COMMENT'],
    columns: ['custom_columns', 'approach_details'],
    hint: 'Remarks usually go to custom_columns or approach_details.'
  ),
  (
    tokens: ['DATE', 'DOF'],
    columns: ['date'],
    hint: 'The flight date is date, strict YYYY-MM-DD.'
  ),
  (
    tokens: ['ID'],
    columns: [],
    hint: 'An id column is not mapped: the batch mints its own ids, and a row '
        'is retried under its client_ref instead.'
  ),
];

/// The alias family [key] belongs to, if any. A token of the header equals one
/// of the family's tokens, or contains one long enough to mean something, so
/// `REMARKS` finds `REMARK` while the `ON` in `NOTES` finds nothing.
({List<String> columns, String hint})? _importAliasFor(String key) {
  final tokens = key
      .toUpperCase()
      .split(RegExp(r'[^A-Z0-9]+'))
      .where((token) => token.isNotEmpty);
  for (final family in _importColumnAliases) {
    for (final token in tokens) {
      for (final needle in family.tokens) {
        if (token == needle || (needle.length >= 4 && token.contains(needle))) {
          return (columns: family.columns, hint: family.hint);
        }
      }
    }
  }
  return null;
}

/// The flight columns this build can write: the live table and the write spec
/// agree on these, and every alternative an unknown column is offered comes
/// from here.
List<_Column> _writableFlightColumns(FalconDb db) =>
    _supported(db, 'flights', _flightColumns);

/// Writable columns whose names share a chunk with [key], for a source header
/// the curated list does not know.
List<String> _similarFlightColumns(String key, List<_Column> writable) {
  final wanted = _normalizeKey(key);
  if (wanted.length < 3) return const [];
  return [
    for (final column in writable)
      if (_normalizeKey(column.name).contains(wanted) ||
          (wanted.contains(_normalizeKey(column.name)) &&
              _normalizeKey(column.name).length >= 4))
        column.name,
  ];
}

/// The `unknown_column` issue for one source header: the real columns that
/// could hold it, plus the curated hint for the headers this flow sees over
/// and over. The key is removed from the row and the rest of the row is still
/// evaluated: an unknown column is a question for the pilot, never a silent
/// drop.
({String message, List<Map<String, dynamic>> candidates}) _unknownColumnIssue(
    FalconDb db, String key) {
  final writable = _writableFlightColumns(db);
  final alias = _importAliasFor(key);
  final wanted = {
    ...?alias?.columns,
    ..._similarFlightColumns(key, writable),
  };
  final matches = [
    for (final column in writable)
      if (wanted.contains(column.name)) column,
  ];
  final hint = alias == null ? '' : '${alias.hint} ';
  final names = [for (final column in matches) column.name];
  return (
    message: names.isEmpty
        ? 'Column "$key" is not a Falcon flight column; none of the columns '
            'this build can write (falcon://import) is a likely home. $hint'
            'Ask the pilot where the values go; never drop the column silently.'
        : 'Column "$key" is not a Falcon flight column; the closest this '
            'build can write are ${names.join(', ')} (all of them are in '
            'falcon://import). $hint'
            'Ask the pilot where the values go; never drop the column silently.',
    candidates: [
      for (final column in matches)
        {'name': column.name, 'note': _importColumnNote(column)},
    ],
  );
}

/// Columns that hold a unix epoch second rather than a count of things.
const Set<String> _epochColumns = {
  'scheduled_departure_utc',
  'scheduled_arrival_utc',
};

/// How the import column table describes a column's kind, unit included: a
/// duration cell reads as minutes, a count is not a duration, and a planned
/// time is an instant in unix seconds.
String _importColumnKind(_Column column) => switch (column.kind) {
      _Kind.text => 'text',
      _Kind.integer => _minuteColumns.contains(column.name)
          ? 'integer minutes'
          : _epochColumns.contains(column.name)
              ? 'unix seconds'
              : 'integer count',
      _Kind.real => 'number',
      _Kind.boolean => 'boolean',
      _Kind.date => 'date YYYY-MM-DD',
      _Kind.clock => 'clock HH:MM',
    };

/// What a column holds, for the import column table: the write catalog's own
/// note where there is one, the kind where the catalog carries the column
/// bare, which is still true and never a guess at the data.
String _importColumnNote(_Column column) =>
    column.note ??
    switch (column.kind) {
      _Kind.text => 'Free text.',
      _Kind.integer => 'Whole-number count.',
      _Kind.real => 'Number.',
      _Kind.boolean => 'true or false.',
      _Kind.date => 'Calendar date.',
      _Kind.clock => '24-hour clock time.',
    };

/// The import column table: one line per flight column this build can write,
/// generated from the live table and the write spec when the resource is read.
/// A database that has not migrated has no planned-time columns, so the table
/// names only what an import can actually send, and never a column the write
/// path would refuse.
String _importColumnTable(FalconDb db) => [
      for (final column in _writableFlightColumns(db))
        '- ${column.name} (${_importColumnKind(column)}): '
            '${_importColumnNote(column)}',
    ].join('\n');

/// `falcon://import`: the guided import contract. The question script, the
/// mapping and review rule, the strict date and unit rules, the loud
/// partial-failure rule, and the column table generated from the live
/// database at read time.
String _importResourceText(FalconDb db) => 'FALCON LOGBOOK IMPORT\n'
    '\n'
    'The server never reads the file: it sees SQLite and the rows you send, so '
    'this is a mapping contract with questions, validation and an atomic '
    'apply. You do the reading and the OCR. Anything that looks like "the '
    'server parses the CSV" is out of scope by design.\n'
    '\n'
    'QUESTIONS: ASK, DO NOT ASSUME\n'
    'Ask only what the file does not say, in a few grouped questions, never '
    'one field at a time and never again what the pilot has already answered. '
    'On a client that supports it, ask with ask_user (pickers and yes/no '
    'forms) and record each answer against its question id. The groups:\n'
    '1. Source and shape. What is it: a CSV, Excel or JSON export, PDF text, '
    'an image, or a pasted table? Where did it come from (ForeFlight, LogTen '
    'Pro, Garmin Pilot, a CASA-style paper logbook, an airline logbook, a '
    'hand-made spreadsheet)? If unknown, say so and work from the headers, '
    'and show the headers back exactly as written. How many rows?\n'
    '2. The date column. Which column holds the flight date? Dates here are '
    'strict YYYY-MM-DD: a spreadsheet serial number is refused with the date '
    'it shows (1899-12-30 plus the serial), and text like 27/10/2026 or '
    '2026-10-27T00:00:00Z is refused with its probable reading, both readings '
    'named when a slash date is ambiguous. Nothing is ever converted, because '
    'a wrong reading moves a flight between months and years.\n'
    '3. Duration units. Are the durations total time, day plus night, or '
    'block time? Are the cells whole minutes (units "minutes"), decimal hours '
    '(units "decimal_hours", 1.5 is 90 minutes) or H:MM (units "hhmm", 1:30 '
    'is 90 minutes)? Declare one convention for the whole call: mixed units '
    'in one file are an error, never a guess, and a cell that does not match '
    'the declared unit is refused with unit_mismatch or unit_implausible.\n'
    "4. Whose logbook. Is this the pilot's own logbook, or does it carry "
    "other pilots' rows too?\n"
    '5. Aircraft mapping. Which types and registrations appear, and which '
    'existing aircraft rows do they map to? Offer list_aircraft. Never infer '
    'a tail from a type that happens to match one aircraft, and never invent '
    'a registration.\n'
    '6. Roles. Is PIC per row, or the whole file as PIC? Any copilot, '
    'student or dual rows? crew_role drives currency, so it is never '
    'assumed.\n'
    '7. Simulator rows. Which rows are FNPT or FFS sessions (is_simulator)? '
    'Separate them out.\n'
    '8. Timezone. flights.date is the logbook-zone local midnight of the '
    'flight date, and the logbook zone is the one FALCON_TZ declares (an IANA '
    'name such as Australia/Sydney). Is the date column already the local '
    'calendar date, and could any row move if it was logged in UTC? Never '
    'infer a zone from a city name.\n'
    '\n'
    'SHOW THE MAPPING, GET AN EXPLICIT YES\n'
    'Render "source column -> Falcon column" for every source column, plus '
    'THREE sample rows already rendered as Falcon rows (create_flight field '
    'names), so the pilot can spot a shift before anything is written. Then '
    'get an explicit yes. If the pilot skips the review, skip the table but '
    'keep the dry run: never blind-import a file.\n'
    '\n'
    'UNKNOWN COLUMNS ARE QUESTIONS, NEVER DROPPED\n'
    'validate_flight_drafts reports every column it cannot map as '
    'unknown_column, with the real columns this build could write instead '
    '(also in the column table below, and from get_schema). Ask with those '
    'real options rather than dropping the column: ignore it (information '
    'lost), fold it into custom_columns, or map it to one of the named '
    'columns. The alias hints cover the usual source headers (instructing, '
    'PIC, copilot, block, start/stop, rego, type, remarks, date).\n'
    '\n'
    'PARTIAL FAILURE IS LOUD\n'
    'Silent partial success is the failure this flow exists to prevent. Name '
    'every row that did not land, with its index, its client_ref if it had '
    'one, and the reason. State the batch_id and how many rows landed. Say '
    'plainly that the rows that did land now carry updated_at like a manually '
    'entered flight and push to Postgres on the next sync.\n'
    '\n'
    'TOOLS\n'
    'validate_flight_drafts writes nothing: flights (up to 500, create_flight '
    'field names), mode: "import", the declared units, optional date_from and '
    'date_to. Each row answers ok, issues of {field, code, message, severity} '
    'and warnings; severity error is a row apply_flight_batch would refuse, '
    'warning is a row to ask about (would_create_draft means the row would '
    'land as a draft), info is stored as text. Import codes: serial_date, '
    'date_format, unit_mismatch, unit_implausible, unit_conflict, '
    'would_create_draft, unknown_column, plus the shared ones (invalid_row, '
    'split_mismatch, duplicate_existing, duplicate_batch, date_missing and '
    'the rest). Each row also accepts client_ref (retry identity) and '
    'aircraft_type (a hint, never stored).\n'
    'apply_flight_batch (write mode only) takes the same rows plus dry_run '
    '(default true: the same plan, nothing written), allow_partial (default '
    'false: atomic, one bad row writes nothing) and batch_id. An import row '
    'lands as it stands: complete when it carries a total, a draft when it '
    'does not. A duplicate in the logbook or the batch is skipped, never '
    'overwritten, and so is a client_ref an earlier batch already '
    'imported.\n'
    '\n'
    'COLUMN TABLE: FLIGHT COLUMNS THIS BUILD CAN WRITE\n'
    'Generated from this database when this resource is read. Never map to a '
    'column that is not listed here.\n'
    '${_importColumnTable(db)}\n';

/// Validates every row of a roster without writing anything, and returns one
/// [_RosterRow] per input row, in input order.
///
/// Each row goes through `_flightValues`, so the validator accepts exactly what
/// `create_flight` accepts and refuses exactly what it refuses. What is layered
/// on top is the roster's own business: the stated date window, the order of
/// the legs, duplicates in the logbook and in the batch, planned times this
/// database cannot store, and a total on a scheduled leg.
///
/// [settings] gates the import rules: strict dates, durations read in the
/// declared unit, unknown columns surfaced with real alternatives, and the
/// draft warning. A roster call passes the defaults and pays for none of them.
List<_RosterRow> _rosterRows(
  FalconDb db,
  Map<String, dynamic> args, {
  required String tool,
  required ({DateTime? from, DateTime? to}) range,
  required ({bool import, String units}) settings,
}) {
  final raw = _rosterFlightRows(args);
  final plannedAvailable = _plannedTimesAvailable(db);
  final airportsKnown = _hasAirports(db);
  final rows = <_RosterRow>[];
  DateTime? previousDate;
  final seen = <String, int>{};

  for (var index = 0; index < raw.length; index++) {
    final entry = raw[index];
    final row = entry is Map
        ? _RosterRow(index, asText(entry[_clientRefKey]))
        : _RosterRow(index, null);
    rows.add(row);
    if (entry is! Map) {
      row.add('invalid_row',
          'each flight must be an object using create_flight field names',
          field: 'flights[$index]');
      continue;
    }
    final flight = Map<String, dynamic>.from(entry);
    flight.remove(_clientRefKey);
    final aircraftType = asText(flight.remove(_aircraftTypeKey));

    // A planned time on a database without the columns is refused, not
    // silently dropped: the caller has to say whether the leg goes in as a
    // draft with no times or not at all.
    final planned = [
      for (final field in _plannedTimeFields)
        if (flight.containsKey(field)) field,
    ];
    if (planned.isNotEmpty && !plannedAvailable) {
      row.add(
        'planned_times_unsupported',
        'This database does not store planned times yet: it has no '
            '${_plannedTimeFields.join(', ')} columns (they come with '
            'Falcon-Logbook/app#231 and schema 20). Drop those fields and send the '
            'row with no total_time; it lands as a draft and the times are not '
            'stored.',
        field: planned.first,
      );
      for (final field in _plannedTimeFields) {
        flight.remove(field);
      }
    }

    if (settings.import) {
      // Unknown columns are reported with the real columns that could hold
      // them and removed, so the rest of the row is still evaluated and the
      // pilot's instructing time is a question rather than a silent drop.
      final unknown = [
        for (final key in flight.keys)
          if (!_rosterRowFields.contains(key)) key,
      ];
      for (final key in unknown) {
        flight.remove(key);
        final issue = _unknownColumnIssue(db, key);
        row.add('unknown_column', issue.message,
            field: key, candidates: issue.candidates);
      }

      // The date is strict YYYY-MM-DD here. One date issue skips the row
      // builder, so the row carries the refusal instead of a second generic
      // one from the coercion below.
      final dateIssue = _importDateIssue(flight['date']);
      if (dateIssue != null) {
        row.add(dateIssue.code, dateIssue.message, field: 'date');
        continue;
      }

      // Durations are read in the unit the call declared and converted to the
      // minutes the columns store. The `_hours` aliases are the write tools'
      // shorthand; an import has already declared its convention, so the
      // shorthand is refused instead of converting in a unit the file may not
      // use. A cell that does not convert is the row's clear issue, and the
      // row builder is skipped rather than asked to parse what it cannot.
      var unitFailed = false;
      for (final entry in _hoursAliases.entries) {
        if (!flight.containsKey(entry.value)) continue;
        row.add(
            'unit_conflict',
            '${entry.value} is refused on an import: the file\'s duration '
                'convention was declared once on the call as units '
                '"${settings.units}". Send ${entry.key} in ${settings.units} '
                'instead.',
            field: entry.value);
        flight.remove(entry.value);
        unitFailed = true;
      }
      for (final column in _minuteColumns) {
        if (!flight.containsKey(column)) continue;
        final raw = flight[column];
        if (raw == null) continue;
        final read = _importMinutes(column, raw, settings.units);
        if (read.code != null) {
          row.add(read.code!, read.message!, field: column);
          flight.remove(column);
          unitFailed = true;
          continue;
        }
        flight[column] = read.value;
      }
      if (unitFailed) continue;
    }

    try {
      _rejectUnknown(flight, _rosterRowFields, tool: tool);
      final built = _flightValues(db, flight, tool: tool);
      row.values = built.values;
      row.warnings.addAll(built.warnings.where((warning) =>
          !warning.startsWith('No aircraft matched ') &&
          !RegExp(r'^\d+ aircraft match ').hasMatch(warning) &&
          !RegExp(r'^\d+ crew members match ').hasMatch(warning) &&
          !warning.startsWith('route "')));
    } on _ToolError catch (error) {
      row.add(_rosterIssueCode(error), error.detail, field: error.field);
      continue;
    }

    final values = row.values!;
    final date = asInt(values['date']);
    if (date == null) {
      row.add(
          'date_missing',
          settings.import
              ? 'date is required: every import row needs the date it was flown'
              : 'date is required: every roster leg needs the local date it '
                  'operates on',
          field: 'date');
      continue;
    }
    // An import row with no total lands as a draft, which is right when the
    // source has no total for it and a silent gap when it does. It still
    // writes: the warning is for the confirmation before apply, not a block.
    if (settings.import &&
        values['total_time'] == null &&
        asBool(flight['draft']) != true) {
      row.add(
          'would_create_draft',
          'no total_time on the row: this would create a draft; confirm the '
              'source has no total for it',
          field: 'total_time',
          severity: 'warning');
    }
    final day = logbookDateFromEpoch(date);
    // An import has no roster: the range is what the file's own start and end
    // claim, and its rows are ordered by date rather than by departure.
    if (range.from != null && day.isBefore(range.from!)) {
      row.add(
        'date_out_of_range',
        '${formatCalendarDate(day)} is before the stated '
            '${settings.import ? 'start' : 'roster start'} '
            '${formatCalendarDate(range.from!)}',
        field: 'date',
        severity: 'warning',
      );
    }
    if (range.to != null && day.isAfter(range.to!)) {
      row.add(
        'date_out_of_range',
        '${formatCalendarDate(day)} is after the stated '
            '${settings.import ? 'end' : 'roster end'} '
            '${formatCalendarDate(range.to!)}',
        field: 'date',
        severity: 'warning',
      );
    }
    if (previousDate != null && day.isBefore(previousDate)) {
      row.add(
        'date_order',
        '${formatCalendarDate(day)} is before the previous '
            '${settings.import ? 'row' : 'leg'} '
            '(${formatCalendarDate(previousDate)}): check the dates or sort the '
            '${settings.import ? 'file' : 'roster'} by '
            '${settings.import ? 'date' : 'departure'}',
        field: 'date',
        severity: 'warning',
      );
    }
    previousDate = day;

    final scheduled = _plannedTimeFields.any((field) => values[field] != null);
    if (scheduled && values['total_time'] != null) {
      row.add(
        'scheduled_total_time',
        'This leg has planned times, so total_time must be left empty: a total '
            'makes the flight complete and adds hours that were never flown. Drop '
            'total_time and day_time/night_time; the planned block stays in '
            'scheduled_block_minutes.',
        field: 'total_time',
      );
    }

    try {
      row.warnings.addAll(_checkDayNight(values));
    } on _ToolError catch (error) {
      row.add('split_mismatch', error.detail);
    }

    final registration = asText(values['aircraft_registration']);
    if (registration != null) {
      final matches = _aircraftCandidates(db, registration);
      if (matches.isEmpty) {
        row.add(
          'aircraft_unmatched',
          'No aircraft matches "$registration", so the flight is not linked to '
              'one. Add it with add_aircraft, pass aircraft_id, or leave the '
              'registration blank if there is no tail yet.',
          field: 'aircraft_registration',
          severity: 'warning',
        );
      } else if (matches.length > 1) {
        row.add(
          'aircraft_ambiguous',
          '${matches.length} aircraft match "$registration", so the flight is '
              'not linked. Pass aircraft_id to choose one.',
          field: 'aircraft_registration',
          severity: 'warning',
          candidates: [
            for (final match in matches)
              {'id': match.id, 'registration': match.display},
          ],
        );
      }
    } else if (aircraftType != null) {
      final tails = _aircraftOfType(db, aircraftType);
      row.add(
        'aircraft_missing',
        tails.isEmpty
            ? 'The roster names aircraft type $aircraftType but no '
                'registration, and the fleet has no tail of that type. Leave '
                'the aircraft blank, or add the tail with add_aircraft.'
            : 'The roster names aircraft type $aircraftType but no '
                'registration. Pick one of these tails or leave the aircraft '
                'blank.',
        field: _aircraftTypeKey,
        severity: 'warning',
        candidates: tails,
      );
    }

    final crewName = asText(values['crew_members_name']);
    if (crewName != null) {
      final matches = _crewCandidates(db, crewName);
      if (matches.isEmpty) {
        row.add(
          'crew_unmatched',
          'No crew member matches "$crewName". The app stores the name as '
              'text, so the row still lands; add the person with add_crew to link '
              'the flight.',
          field: 'crew_members_name',
          severity: 'info',
        );
      } else if (matches.length > 1) {
        row.add(
          'crew_ambiguous',
          '${matches.length} crew members match "$crewName", so the flight is '
              'not linked. Pass crew_member_id to choose one.',
          field: 'crew_members_name',
          severity: 'warning',
          candidates: [
            for (final match in matches) {'id': match.id, 'name': match.name},
          ],
        );
      }
    }

    final route = asText(values['route']);
    final parsed = parseRoute(route);
    if (route != null && parsed == null) {
      row.add(
        'route_unparsable',
        'route "$route" is not an airport pair, so the app shows it as a '
            'description and it has no departure or arrival. Write it as '
            '"YSSY - NZQN".',
        field: 'route',
        severity: 'warning',
      );
    } else if (parsed != null && airportsKnown) {
      final unresolved = [
        for (final code in [parsed.departure, parsed.arrival])
          if (!_airportExists(db, code)) code,
      ];
      if (unresolved.isNotEmpty) {
        final matched = [
          for (final code in [parsed.departure, parsed.arrival])
            if (!unresolved.contains(code)) code,
        ];
        row.add(
          'airport_unresolved',
          'route "$route": ${unresolved.map((code) => '"$code"').join(' and ')} '
              'matches no airport'
              '${matched.isEmpty ? '' : ', while ${matched.map((code) => '"$code"').join(' and ')} does'}. '
              'Check the code, or add the airport with add_custom_airport before '
              'the row is written.',
          field: 'route',
          severity: 'warning',
        );
      }
    }

    final identity = _rosterIdentity(values);
    final firstIndex = seen[identity];
    if (firstIndex != null) {
      row.add(
          'duplicate_batch',
          'Same date, route, registration and total time as row $firstIndex in '
              'this batch',
          severity: 'warning');
    } else {
      seen[identity] = index;
      final existing = _existingFlightId(db, values['date'], route,
          asText(values['aircraft_registration']), values['total_time']);
      if (existing != null) {
        row.add(
          'duplicate_existing',
          'A flight with the same date, route, registration and total time '
              'already exists (id $existing), so the import skips this row.',
          severity: 'warning',
        );
      }
    }
  }
  return rows;
}

/// The per-row answer both roster tools share: the counts, the echoed range
/// when one was stated, and one entry per row with its code and its warnings.
Map<String, dynamic> _rosterReport(
  List<_RosterRow> rows,
  ({DateTime? from, DateTime? to}) range,
) =>
    {
      'valid': rows.where((row) => row.ok).length,
      'invalid': rows.where((row) => !row.ok).length,
      if (range.from != null || range.to != null)
        'range': {
          'from': range.from == null ? null : formatCalendarDate(range.from!),
          'to': range.to == null ? null : formatCalendarDate(range.to!),
        },
      'rows': [
        for (final row in rows)
          {
            'index': row.index,
            if (row.clientRef != null) 'client_ref': row.clientRef,
            'ok': row.ok,
            'issues': row.issues,
            if (row.warnings.isNotEmpty) 'warnings': row.warnings,
          },
      ],
    };

/// The `client_ref` values an earlier applied batch already created, from the
/// audit log: the log is the record of what a batch contained, so a retry needs
/// no extra column. Only rows that actually landed are here, so a row that
/// failed in a partial batch can be fixed and retried under the same ref.
Set<String> _importedClientRefs(String dbPath) {
  final refs = <String>{};
  for (final entry in readAudit(dbPath)) {
    if (entry['tool'] != 'apply_flight_batch') continue;
    if (entry['result'] != 'ok') continue;
    final created = entry['created_refs'];
    if (created is! List) continue;
    refs.addAll(created.whereType<String>());
  }
  return refs;
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
  final day = logbookDateFromEpoch(date);
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
/// is the `date` column as the row mapper renders it, the `YYYY-MM-DD`
/// calendar date in the logbook zone.
bool _sameLocalDay(Object? storedDate, int date) =>
    storedDate == epochToCalendarDate(date);

/// Records a sync tombstone so a deleted row is not resurrected by Postgres
/// sync, mirroring the app's `recordDeletion`. No-op when no provider has
/// synced.
///
/// One tombstone per provider, deduplicated: `sync_deletions` has no unique
/// index on `(sync_table, row_id, provider)`, so an existence check is what
/// keeps a repeated delete from stacking identical tombstone rows. Provider
/// names are normalised like the app's `normalizeSyncProvider`, because the
/// push reads tombstones `WHERE provider = ?` and a tombstone stored under a
/// legacy provider name would be invisible to it.
void _recordTombstones(FalconDb db, String table, Object id) {
  if (!db.hasTable('sync_state') || !db.hasTable('sync_deletions')) return;
  final providers = db
      .query('SELECT DISTINCT provider FROM sync_state')
      .map((row) => row['provider'])
      .whereType<String>()
      .map(normalizeSyncProvider)
      .toSet();
  final now = nowEpochSeconds();
  for (final provider in providers) {
    final known = db.query(
      'SELECT 1 FROM sync_deletions '
      'WHERE sync_table = ? AND row_id = ? AND provider = ? LIMIT 1',
      [table, id.toString(), provider],
    );
    if (known.isNotEmpty) continue;
    db.execute(
      'INSERT INTO sync_deletions (sync_table, row_id, provider, created_at) VALUES (?, ?, ?, ?)',
      [table, id.toString(), provider, now],
    );
  }
}

/// Deletes [id] from [table] and records its sync tombstones in one
/// transaction, for the four synced tables' delete tools.
///
/// The delete's affected-row count decides whether anything happened at all:
/// a row that a concurrent writer removed after the caller's existence check
/// ends in a [notFoundLabel] error instead of a deleted result that never
/// deleted anything, and no tombstone is written for a row that was already
/// gone.
void _deleteSyncedRow(FalconDb db, String table, Object id, String label) {
  db.transaction(() {
    final deleted = db.execute('DELETE FROM $table WHERE id = ?', [id]);
    if (deleted == 0) {
      throw _ToolError('$label not found: $id', code: 'not_found', field: 'id');
    }
    _recordTombstones(db, table, id);
  });
}

Map<String, dynamic> _deleted(String table, Object id) => {
      'status': 'deleted',
      'id': id,
      'table': table,
    };

/// The `expected_updated_at` argument every update tool accepts.
JsonSchema get _expectedUpdatedAtSchema => JsonSchema.integer(
    minimum: 0,
    description: 'The updated_at you read. A conflict returns the current row '
        'when it changed since. Omit to write unconditionally.');

/// The `dry_run` argument every write tool accepts.
JsonSchema get _dryRunSchema => JsonSchema.boolean(
    description:
        'True previews the write: the tool resolves, validates and answers '
        'exactly as it would, with dry_run: true on the response, and changes '
        'nothing.');

/// The `dry_run` argument the repair tools take, which default to a preview:
/// the agent must pass false explicitly to change rows.
JsonSchema get _repairDryRunSchema => JsonSchema.boolean(
    description:
        'Default true: the repair reports what it would change and touches '
        'nothing. Pass false to apply, for the same diff as the preview.');

/// Escapes a dry-run body with the result it built. Thrown after the body has
/// resolved everything it would write, so the enclosing transaction rolls back:
/// the preview answer is the write answer, minus the write.
class _DryRun {
  _DryRun(this.result);

  final Map<String, Object?> result;
}

/// The extra WHERE fragment and bind values that turn an update into an
/// optimistic one: with expected_updated_at the write applies only to the row
/// as the caller read it, so a concurrent change fails the write instead of
/// being silently overwritten. Empty when the field is omitted, which keeps
/// the unconditional write for callers that read nothing.
///
/// The fragment expects the statement's WHERE clause to end with `id = ?` and
/// the id to be bound last before these values.
(String, List<Object?>) _optimisticGuard(Map<String, dynamic> args) {
  final expected = asInt(args['expected_updated_at']);
  if (expected == null) return ('', const []);
  return (' AND updated_at = ?', [expected]);
}

/// The expected_updated_at argument, for the error message.
int? _expectedUpdatedAtOf(Map<String, dynamic> args) =>
    asInt(args['expected_updated_at']);

/// Throws unless [changed] says the update wrote the row it aimed at.
///
/// Zero rows means either the row is gone (not_found) or, when the caller
/// sent expected_updated_at, that another writer changed the row since it
/// was read. The conflict carries the current row, shaped by [shape] where a
/// tool has a row mapper, so a caller can retry against what is actually
/// there.
void _requireUpdated(
  FalconDb db, {
  required String table,
  required Object id,
  required int changed,
  required String label,
  required String tool,
  required int? expected,
  Map<String, Object?> Function(Map<String, dynamic> row)? shape,
}) {
  if (changed == 1) return;
  final rows = db.query('SELECT * FROM $table WHERE id = ?', [id]);
  if (rows.isEmpty) {
    throw _ToolError('$label not found: $id', code: 'not_found', field: 'id');
  }
  final current = rows.first;
  // The raw stamp: query() renders a `*_at` epoch as ISO text, and the
  // comparison has to name the stored value the caller will send next time.
  final stored = db.selectRaw(
      'SELECT updated_at FROM $table WHERE id = ?', [id]).first['updated_at'];
  throw _ToolError(
    stored is! int
        ? 'the row has no updated_at stamp yet, so it cannot be compared '
            'with $expected. Re-read the row and retry without '
            'expected_updated_at: the write stamps it, and later updates '
            'can expect it'
        : 'the row changed since it was read: its updated_at is $stored, '
            'not $expected. Re-read the row and retry with the newer value',
    code: 'conflict',
    field: 'expected_updated_at',
    tool: tool,
    data: {'current': shape?.call(current) ?? current},
  );
}

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
// Logbook overview
// ============================================================

/// How many rows one `attention` list carries. The count is what a first answer
/// needs; the list is the evidence, and a pilot with twenty expiries reads the
/// same one sentence as a pilot with two.
const int _overviewAttentionCap = 3;

/// [minutes] as hours to one decimal, the precision a logbook answer is read
/// at: `41.2`, not `41.199999999999996`, and not a float that costs bytes to say
/// nothing more.
double _hours(int minutes) => (minutes / 6).roundToDouble() / 10;

/// The `logbook_overview` payload: the facts a first answer to "what about my
/// logbook?" needs, in one small object with no flight rows.
///
/// Keys are left out rather than zeroed when the data behind them is not there:
/// no expiries, no currency rules, no settings row, no aircraft, no flights at
/// all. A zero claims the pilot has none of something; a missing key says this
/// logbook cannot tell. Nothing here carries the database path: an answer is
/// often screenshotted, and the path is noise to a pilot.
Map<String, dynamic> _logbookOverview(
  FalconDb db, {
  required int days,
  required bool readonly,
  required DateTime now,
}) {
  final owner = _ownerClause(db, 'flights', includeShared: false);
  final all = _flightAggregate(db, [if (owner.isNotEmpty) owner], const []);
  final flights = asInt(all['flights']) ?? 0;
  final drafts = asInt(all['drafts']) ?? 0;

  // The last [days] days, over the calendar arithmetic the date presets use (a
  // last-N-days window is today plus the N-1 days before it) and the same
  // aggregate `logbook_stats` reports, so the two numbers agree.
  final from = logbookDateAt(now.year, now.month, now.day - (days - 1));
  final window = _flightDateFilter(
    {'date_from': formatCalendarDate(from), 'date_to': formatCalendarDate(now)},
    now: now,
  );
  final recent = _flightAggregate(
    db,
    [...window.where, if (owner.isNotEmpty) owner],
    window.params,
  );

  final dueSoon = _expiriesDueSoon(db, now);
  final failing = _currencyFailing(db, now);
  final fleet = _fleetSummary(db);
  final activity = _recentActivity(db, now);

  return {
    'flights': flights,
    'hours': _hours(asInt(all['total_minutes']) ?? 0),
    'drafts': drafts,
    'recent': {
      'days': days,
      'flights': asInt(recent['flights']) ?? 0,
      'hours': _hours(asInt(recent['total_minutes']) ?? 0),
      'night_hours': _hours(asInt(recent['night_minutes']) ?? 0),
    },
    if (fleet != null) 'fleet': fleet,
    if (activity != null) 'recent_activity': activity,
    'attention': {
      'drafts': drafts,
      if (dueSoon != null) 'expiries_due_soon': dueSoon,
      if (failing != null) 'currency_failing': failing,
      'unlinked_flights': _unlinkedFlights(db),
    },
    'logbook': _logbookFacts(db, readonly: readonly),
  };
}

/// Flights with no aircraft linked, which is the number a link pass works
/// through.
int _unlinkedFlights(FalconDb db) {
  final owner = _ownerClause(db, 'flights', includeShared: false);
  final rows =
      db.query('SELECT COUNT(*) AS total FROM flights WHERE aircraft_id IS NULL'
          '${owner.isEmpty ? '' : ' AND $owner'}');
  return rows.isEmpty ? 0 : asInt(rows.first['total']) ?? 0;
}

/// The fleet line: how many aircraft the pilot keeps and the type with the most
/// time on it, the same totals `list_aircraft` and `entity_totals` report. Null
/// when there is no aircraft row, and the type is absent when no flight has a
/// complete time, because a zero there would be a claim about an empty fleet.
Map<String, dynamic>? _fleetSummary(FalconDb db) {
  if (!db.hasTable('aircraft')) return null;
  final owner = _ownerClause(db, 'aircraft', includeShared: false);
  final where = ['archived = 0', if (owner.isNotEmpty) owner];
  final rows =
      db.query('SELECT COUNT(*) AS total FROM aircraft${_whereSql(where)}');
  final aircraft = rows.isEmpty ? 0 : asInt(rows.first['total']) ?? 0;
  if (aircraft == 0) return null;
  final top = readEntityTotals(
    db,
    type: 'type',
    sort: defaultEntityTotalSort,
    limit: 1,
    offset: 0,
    includeSimulator: true,
    ownerClause:
        _ownerClause(db, 'flights', includeShared: false, prefix: 'flights.'),
  ).entities;
  return {
    'aircraft': aircraft,
    if (top.isNotEmpty) 'top_type': top.first['aircraft_type'],
    if (top.isNotEmpty)
      'top_type_hours': _hours(asInt(top.first['minutes']) ?? 0),
  };
}

/// When the last flight was, and how long ago that is in whole days. Null when
/// there is no flight to date.
Map<String, dynamic>? _recentActivity(FalconDb db, DateTime now) {
  final owner = _ownerClause(db, 'flights', includeShared: false);
  final rows = db.query('SELECT MAX(date) AS last FROM flights'
      '${owner.isEmpty ? '' : ' WHERE $owner'}');
  final epoch = rows.isEmpty ? null : asInt(rows.first['last']);
  if (epoch == null) return null;
  final last = logbookDateFromEpoch(epoch);
  // Whole calendar days from the flight's date to today, computed in the
  // logbook zone like the expiry counts, so a host in another zone cannot add
  // or lose a day.
  final days = DateTime.utc(now.year, now.month, now.day)
      .difference(DateTime.utc(last.year, last.month, last.day))
      .inDays;
  return {
    'last_flight_date': formatCalendarDate(last),
    'days_since_last_flight': days,
  };
}

/// Document expiries that are due soon or overdue, the rows the app shows in red
/// or orange, soonest first: the same status `list_expiries` reports, from the
/// same thresholds and the same day count.
///
/// Null when the database has no expiries table, when it holds no local row, or
/// when nothing is due soon, so a logbook with nothing expiring says nothing
/// about expiries rather than printing an empty list.
List<Map<String, dynamic>>? _expiriesDueSoon(FalconDb db, DateTime now) {
  if (!db.hasTable('expiries')) return null;
  final owner = _ownerClause(db, 'expiries', includeShared: false);
  final rows = db.query('SELECT id, name, due_date FROM expiries'
      '${owner.isEmpty ? '' : ' WHERE $owner'} ORDER BY due_date, id');
  if (rows.isEmpty) return null;
  final thresholds = readExpiryThresholds(db);
  final soon = <Map<String, dynamic>>[];
  for (final row in rows) {
    final due = _localDate(row['due_date']);
    if (due == null) continue;
    final days = daysUntilDue(due, now);
    final status = expiryStatusForDays(days,
        greenThreshold: thresholds.green, orangeThreshold: thresholds.orange);
    if (status == 'green') continue;
    soon.add({
      'name': row['name'],
      'due_date': formatCalendarDate(due),
      'days_remaining': days,
    });
    if (soon.length == _overviewAttentionCap) break;
  }
  return soon.isEmpty ? null : soon;
}

/// The pilot's own currency rules that need attention, in table order: the same
/// rules `currency_status` computes, and the same `is_exceeded` meaning, which is
/// being short of a requirement or over a limit.
///
/// Null when the database has no currency table, holds no rule, or every rule is
/// satisfied.
List<Map<String, dynamic>>? _currencyFailing(FalconDb db, DateTime now) {
  if (!db.hasTable('user_currency')) return null;
  final rows =
      db.query('SELECT id, title, metric, period, threshold, type FROM '
          'user_currency ORDER BY rowid');
  final failing = <Map<String, dynamic>>[];
  for (final row in rows) {
    // A rule with an unknown metric carries an error instead of a verdict, so
    // it is not one of these: `currency_status` is where it is reported.
    final rule = computeCurrencyRule(db, row, now);
    if (rule['is_exceeded'] != true) continue;
    failing.add({
      'title': rule['title'],
      'period': rule['period'],
      'current': rule['current'],
      'threshold': rule['threshold'],
    });
    if (failing.length == _overviewAttentionCap) break;
  }
  return failing.isEmpty ? null : failing;
}

/// Who the logbook belongs to and what it is: the pilot name and country from the
/// settings row, then the schema version and the mode. The settings keys are
/// left out when the app has never written that row, which a fresh database has
/// not: a name is never invented.
Map<String, dynamic> _logbookFacts(FalconDb db, {required bool readonly}) {
  final facts = <String, dynamic>{};
  if (db.hasTable('flights_settings')) {
    final columns = db.columnsOf('flights_settings');
    final wanted = [
      if (columns.contains('pilot_name')) 'pilot_name',
      if (columns.contains('logbook_country')) 'logbook_country',
    ];
    final rows = wanted.isEmpty
        ? const <Map<String, dynamic>>[]
        : db.query('SELECT ${wanted.join(', ')} FROM flights_settings LIMIT 1');
    if (rows.isNotEmpty) {
      final name = asText(rows.first['pilot_name']);
      final country = asText(rows.first['logbook_country']);
      if (name != null) facts['pilot_name'] = name;
      if (country != null) facts['country'] = country;
    }
  }
  facts['schema_version'] = db.schemaVersion;
  facts['readonly'] = readonly;
  return facts;
}

// ============================================================
// Help catalogue
// ============================================================

/// One capability group in `falcon_help`: a headline a pilot would say, the
/// questions in the pilot's voice, and the tools the group needs. A group is
/// printed only when every tool it needs is registered, so read-only mode has no
/// write group and a build missing a tool says nothing about it.
typedef _HelpGroup = ({
  String headline,
  List<String> questions,
  List<String> tools,
});

/// The groups, in the order a pilot meets them: numbers first, then the awkward
/// questions, then the write groups, then the overview itself. Seven at most,
/// which is what fits in one answer a pilot reads.
const List<_HelpGroup> _helpGroups = [
  (
    headline: 'Get the numbers out',
    questions: [
      'How many hours did I fly last year?',
      'What type have I flown most, and how much time is on it?',
    ],
    tools: ['logbook_stats', 'entity_totals'],
  ),
  (
    headline: 'Find a flight, and what is on it',
    questions: [
      'Which flights did I operate into Queenstown?',
      'Show me my last flight in detail.',
    ],
    tools: ['search_flights', 'get_flight'],
  ),
  (
    headline: 'Find what is missing',
    questions: [
      'Which flights are missing block times?',
      'Do I have the same crew member saved twice?',
    ],
    // The pre-flight half of a roster: a read tool, so it is here in both
    // modes, and the write half below only with writes on.
    tools: ['find_missing_times', 'dedupe_crew', 'validate_flight_drafts'],
  ),
  (
    headline: 'Is it still current?',
    questions: [
      'Is my medical still valid?',
      'Am I current to carry passengers at night?',
    ],
    tools: ['list_expiries', 'currency_status'],
  ),
  (
    headline: 'Draft what is ahead',
    questions: [
      'Draft next month\'s roster into my logbook.',
      'Save the route I fly every week.',
    ],
    tools: [
      'create_flight',
      'add_saved_route',
      'validate_flight_drafts',
      'apply_flight_batch',
    ],
  ),
  (
    headline: 'Fix a mistake',
    questions: [
      'The aircraft on last Tuesday\'s flight is wrong.',
      'Delete the duplicate flight from 3 May.',
    ],
    tools: ['update_flight', 'delete_flight'],
  ),
  (
    headline: 'Ask me what I can do',
    questions: [
      'What can you help me with?',
      'How does my logbook look?',
    ],
    tools: ['logbook_overview'],
  ),
];

/// `falcon_help` for this connection: one line of orientation, at most seven
/// groups in the pilot's language, then the rules. [tools] is what this
/// connection registered, so the catalogue is generated from the catalog rather
/// than hand-written, and nothing here is advertised that cannot be called.
String _falconHelpText({required Set<String> tools, required bool readonly}) {
  final text = StringBuffer()
    ..writeln('You are working in the pilot\'s own Falcon logbook. Falcon is a '
        'pilot logbook on this computer, and you read the database the desktop '
        'app writes. ${readonly ? 'You can look, not change anything.' : 'Writes are on: you can create and change rows, and every write is recorded.'}')
    ..writeln()
    ..writeln('What the pilot can ask for:');
  for (final group in _helpGroups) {
    if (!group.tools.every(tools.contains)) continue;
    text.writeln('- ${group.headline}');
    for (final question in group.questions) {
      text.writeln('  "$question"');
    }
  }
  text
    ..writeln()
    ..writeln('Rules:');
  if (tools.contains('logbook_overview')) {
    text.writeln('- A vague question starts with logbook_overview: answer from '
        'its own numbers, then offer three concrete next steps drawn from what '
        'is non-zero in its attention list.');
  }
  text
    ..writeln(
        '- An empty or brand new logbook is said so warmly, with the three '
        'things that would fill it: import an old logbook, draft a roster, add a '
        'first flight.')
    ..writeln('- Never invent an aircraft, a registration, a time or a date. '
        'Confirm before a write.')
    ..writeln('- When something is not configured, say so instead of guessing.')
    ..writeln('- When you need a decision, ask the pilot to pick from a list.')
    ..write('- Answer in the pilot\'s numbers, not in tool names.');
  return text.toString();
}

/// A prompt as the single user message every prompt here sends.
GetPromptResult _promptResult(String text) => GetPromptResult(
      messages: [
        PromptMessage(
          role: PromptMessageRole.user,
          content: TextContent(text: text),
        ),
      ],
    );

// ============================================================
// Server
// ============================================================

/// An [McpServer] that remembers the tools it registered.
///
/// `falcon_help` is generated from this set, so the catalogue describes this
/// connection as it stands: read-only mode registers no write tool, so no write
/// is advertised, and a build with a tool missing says nothing about it. A
/// hand-written list would drift the moment either changed, with nothing failing.
class _FalconServer extends McpServer {
  _FalconServer(super.serverInfo, {super.options});

  /// Every tool name registered so far, in registration order.
  final Set<String> toolNames = <String>{};

  @override
  RegisteredTool registerTool(
    String name, {
    String? title,
    String? description,
    ToolInputSchema? inputSchema,
    ToolOutputSchema? outputSchema,
    ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required ToolFunction callback,
  }) {
    toolNames.add(name);
    return super.registerTool(
      name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations,
      meta: meta,
      callback: callback,
    );
  }

  @override
  RegisteredStatelessTool registerStatelessTool(
    String name, {
    String? title,
    String? description,
    ToolInputSchema? inputSchema,
    ToolOutputSchema? outputSchema,
    JsonSchema? outputJsonSchema,
    ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required StatelessToolFunction callback,
  }) {
    toolNames.add(name);
    return super.registerStatelessTool(
      name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      outputJsonSchema: outputJsonSchema,
      annotations: annotations,
      meta: meta,
      callback: callback,
    );
  }
}

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

  final server = _FalconServer(
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

  // A question, over whichever path the connection allows: a form on a client
  // that declares elicitation, the same questions as data on one that does
  // not. It writes nothing, so it stays available in read-only mode.
  final askState = AskStateStore();

  server.registerStatelessTool(
    'ask_user',
    description:
        'Ask the pilot questions and get answers back, not in prose. A '
        'question has a stable id, a type (choice, multi, boolean, text) and '
        'options of value and label for choice and multi. Returns status '
        'answered with the answers by id, and the ids in defaulted that were '
        'filled in rather than answered, or declined or cancelled. On '
        'needs_input this client cannot show a form: ask the questions '
        'yourself, then call again with answers by id, with the questions '
        'repeated or not.',
    inputSchema: askUserInputSchema,
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, askUserArgumentFields, tool: 'ask_user');
        final capabilities =
            extra.clientCapabilities ?? server.server.getClientCapabilities();
        return await askUser(
          args,
          stateless: isStatelessProtocolVersion(extra.protocolVersion ?? ''),
          canElicit: capabilities?.elicitation?.supportsForm ?? false,
          elicit: server.elicitInput,
          state: askState,
          inputResponses: extra.inputResponses,
          requestState: extra.requestState,
        );
      } on AskUserError catch (error) {
        return _fail(
          error.message,
          code: error.code,
          field: error.field,
          tool: error.code == 'unknown_field' ? 'ask_user' : null,
        );
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

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
        'minutes and dates come back as YYYY-MM-DD calendar dates; filters '
        'take YYYY-MM-DD. Returns count (rows on this page), total (all '
        'matching '
        'rows), has_more, offset and the applied range. Each flight is a '
        'twelve-field summary unless full is true. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'limit': _flightLimitSchema,
      'offset': JsonSchema.integer(minimum: 0),
      'full': _fullFlightSchema,
      ..._dateFilterProperties(),
      ..._flightNarrowingProperties(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(
            args, {'limit', 'offset', 'full', ..._flightPageFilterKeys},
            tool: 'list_flights');
        final limit = asInt(args['limit']) ?? 20;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0', field: 'offset');
        final full = asBool(args['full']) ?? false;
        final window = _flightDateFilter(args, now: nowInLogbookZone());
        final narrowing = _flightNarrowing(db, args);
        final where = [...window.where, ...narrowing.where];
        final params = [...window.params, ...narrowing.params];
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
        'dates come back as YYYY-MM-DD calendar dates. This is the detail '
        'call: '
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
        return _ok({..._flightView(rows.first, full: true), 'units': _units});
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
        'registration). Times are minutes and dates come back as YYYY-MM-DD '
        'calendar dates; filters take YYYY-MM-DD. Returns count (rows on this '
        'page), '
        'total (all matching rows), has_more, offset and the applied range. '
        'Ordered newest first (date, then day_order, then id). Each flight is '
        'a twelve-field summary unless full is true. Local rows only unless '
        'include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'query': JsonSchema.string(),
      'limit': _flightLimitSchema,
      'offset': JsonSchema.integer(minimum: 0),
      'full': _fullFlightSchema,
      ..._dateFilterProperties(),
      ..._flightNarrowingProperties(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }, required: [
      'query'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args,
            {'query', 'limit', 'offset', 'full', ..._flightPageFilterKeys},
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
        final window = _flightDateFilter(args, now: nowInLogbookZone());
        final narrowing = _flightNarrowing(db, args);
        final where = <String>[
          "(route LIKE ? ESCAPE '\\' OR flight_number LIKE ? ESCAPE '\\' "
              "OR crew_members_name LIKE ? ESCAPE '\\' "
              "OR aircraft_registration LIKE ? ESCAPE '\\')",
          ...window.where,
          ...narrowing.where,
        ];
        final params = <Object?>[
          like,
          like,
          like,
          like,
          ...window.params,
          ...narrowing.params,
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
        final fromWhere = 'aircraft${_whereSql(where)}';
        final rows = db.query(
            'SELECT * FROM $fromWhere ORDER BY registration LIMIT ?', [limit]);
        final page =
            _pageInfo(db, fromWhere, const [], offset: 0, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'aircraft': rows,
        });
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
    description:
        'Search the built-in airports by ICAO, IATA, name or city, any case. '
        'Best match first; ties break on ICAO. query is required; country '
        'narrows to one code.',
    inputSchema: JsonSchema.object(properties: {
      'query': JsonSchema.string(description: 'Required.'),
      'country': JsonSchema.string(),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'query', 'country', 'limit'},
            tool: 'list_airports');
        final limit = asInt(args['limit']) ?? 50;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');
        final text = asText(args['query']);
        if (text == null) {
          return _fail('query is required: an ICAO, IATA, name or city',
              field: 'query');
        }
        final rank = _airportRank(text);
        final where = <String>[rank.where];
        final params = <Object?>[...rank.whereParams];
        final country = asText(args['country']);
        if (country != null) {
          where.add("upper(coalesce(country, '')) = ?");
          params.add(country.toUpperCase());
        }
        final fromWhere = 'airports${_whereSql(where)}';
        final rows = db.query(
            'SELECT * FROM $fromWhere ORDER BY ${rank.order}, icao LIMIT ?',
            [...params, ...rank.orderParams, limit]);
        final page =
            _pageInfo(db, fromWhere, params, offset: 0, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'airports': rows,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'list_custom_airports',
    description: 'List user-defined custom airports. Local rows only '
        'unless include_shared is true.',
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
        final fromWhere =
            'custom_airports${owner.isEmpty ? '' : ' WHERE $owner'}';
        final rows =
            db.query('SELECT * FROM $fromWhere ORDER BY name LIMIT ?', [limit]);
        final page =
            _pageInfo(db, fromWhere, const [], offset: 0, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'airports': rows,
        });
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
        final fromWhere = 'crew_members${_whereSql(where)}';
        final rows =
            db.query('SELECT * FROM $fromWhere ORDER BY name LIMIT ?', [limit]);
        final page =
            _pageInfo(db, fromWhere, const [], offset: 0, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'crew': rows,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  server.registerTool(
    'list_saved_routes',
    description: 'List saved routes. Local rows only unless include_shared '
        'is true.',
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
        final fromWhere = 'saved_routes${owner.isEmpty ? '' : ' WHERE $owner'}';
        final rows = db.query(
            'SELECT * FROM $fromWhere ORDER BY flight_number LIMIT ?', [limit]);
        final page =
            _pageInfo(db, fromWhere, const [], offset: 0, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'routes': rows,
        });
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
        final today = nowInLogbookZone();
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
        'every matching row including drafts, flights_complete counts rows '
        'with a total time, zero_time counts total_time = 0 rows, drafts '
        'counts the rest. Sums skip drafts; include_simulator: false (default true) leaves '
        'simulators out of every other number while sim_flights and '
        'sim_minutes still report that part. Filters (date_from/date_to as '
        'YYYY-MM-DD, or period) apply to every number and the applied range is '
        'echoed back.',
    inputSchema: JsonSchema.object(properties: {
      ..._dateFilterProperties(),
      'include_simulator': JsonSchema.boolean(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {..._flightFilterKeys, 'include_simulator'},
            tool: 'logbook_stats');
        final includeSimulator = asBool(args['include_simulator']) ?? true;
        final window = _flightDateFilter(args, now: nowInLogbookZone());
        final where = [
          ...window.where,
          if (!includeSimulator) 'is_simulator = 0',
        ];
        final params = [...window.params];
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        if (owner.isNotEmpty) where.add(owner);
        final stats = _flightAggregate(db, where, params);
        // The simulator split is reported whether or not it is counted above,
        // so a caller can always say how much of the logbook is in a device.
        final simWhere = [...window.where, 'is_simulator = 1'];
        if (owner.isNotEmpty) simWhere.add(owner);
        final simRows = db.query(
            'SELECT COUNT(*) AS sim_flights, '
            'COALESCE(SUM(total_time), 0) AS sim_minutes '
            'FROM flights${_whereSql(simWhere)}',
            window.params);
        return _ok({
          ...stats,
          'sim_flights':
              simRows.isEmpty ? 0 : asInt(simRows.first['sim_flights']) ?? 0,
          'sim_minutes':
              simRows.isEmpty ? 0 : asInt(simRows.first['sim_minutes']) ?? 0,
          'include_simulator': includeSimulator,
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

  // The first answer, and the opening of every later one that starts with "my
  // logbook": one small object of numbers with no rows behind it. `falcon_help`
  // and the prompts point here, and it stays readable in read-only mode because
  // it writes nothing.
  server.registerTool(
    'logbook_overview',
    description:
        'The logbook in one small payload: flights, hours, drafts, the last N '
        'days, the fleet, the last flight and what needs attention, then the '
        'pilot name and country. A key whose data is not there is left out, '
        'never zeroed, and no flight rows come back. Local rows only.',
    inputSchema: JsonSchema.object(properties: {
      'days': JsonSchema.integer(
          minimum: 1,
          maximum: 3650,
          description:
              'Window for recent, counted back from today. Default 90, '
              'maximum 3650.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'days'}, tool: 'logbook_overview');
        final days = asInt(args['days']) ?? 90;
        if (days < 1) return _fail('days must be >= 1', field: 'days');
        return _ok(_logbookOverview(db,
            days: days, readonly: readonly, now: nowInLogbookZone()));
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
        'Per-entity totals: minutes and the number of complete flights per '
        'aircraft, crew member, aircraft type or registration, rather than the '
        'flight rows behind them. Grouping follows the app: aircraft and crew '
        'group on the link, type on the linked aircraft\'s type, registration on '
        'the flight\'s registration text, so a flight with no aircraft link '
        'counts under registration only. Drafts have no total time, so they are '
        'in neither number, and an entity with no complete flight is not listed: '
        'flights_complete is the same number logbook_stats calls by that name, '
        'where its flights counts every row including drafts. Simulator flights '
        'are included unless include_simulator is false. '
        'Sorted by minutes unless sort says otherwise; count, total, has_more '
        'and offset page through the groups the way the flight lists do. Local '
        'rows only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'type': JsonSchema.string(
          enumValues: entityTotalDimensions, description: 'What to group by.'),
      'sort': JsonSchema.string(
          enumValues: entityTotalSorts,
          description: 'minutes and flights_complete order descending, label '
              'alphabetically. Default $defaultEntityTotalSort.'),
      'limit': _entityTotalLimitSchema,
      'offset': JsonSchema.integer(minimum: 0),
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
        _rejectUnknown(
            args,
            {
              'type',
              'sort',
              'limit',
              'offset',
              'include_simulator',
              _includeSharedKey
            },
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
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0', field: 'offset');
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
          offset: offset,
          includeSimulator: includeSimulator,
          ownerClause: owner,
        );
        return _ok({
          'type': type,
          'sort': sort,
          'include_simulator': includeSimulator,
          'count': totals.entities.length,
          'total': totals.total,
          'has_more': offset + totals.entities.length < totals.total,
          'offset': offset,
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

        final now = nowInLogbookZone();
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
        'Find flights whose times need attention: no total_time (a draft), a '
        'null day_time or night_time, or a day plus night that does not equal '
        'the total. Each row carries id, date, route, the three times, '
        'is_simulator and a reason. Simulators are excluded by default. '
        'Local rows only unless include_shared is true.',
    inputSchema: JsonSchema.object(properties: {
      'limit': _missingTimesLimitSchema,
      'include_simulator': JsonSchema.boolean(),
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {'limit', 'include_simulator', _includeSharedKey},
            tool: 'find_missing_times');
        final limit = asInt(args['limit']) ?? 200;
        if (limit < 1) return _fail('limit must be >= 1', field: 'limit');
        final includeSimulator = asBool(args['include_simulator']) ?? false;
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final where = <String>[
          _missingTimePredicate,
          if (!includeSimulator) 'is_simulator = 0',
          if (owner.isNotEmpty) owner,
        ];
        const params = <Object?>[];
        final fromWhere = 'flights${_whereSql(where)}';
        final rows = db.query(
            'SELECT id, date, route, total_time, day_time, night_time, '
            'is_simulator FROM $fromWhere '
            'ORDER BY date DESC, day_order DESC, id LIMIT ?',
            [limit]);
        final page =
            _pageInfo(db, fromWhere, params, offset: 0, count: rows.length);
        return _ok({
          'count': rows.length,
          'total': page.total,
          'has_more': page.hasMore,
          'units': _units,
          'flights': [
            for (final row in rows) {...row, 'reason': _missingTimeReason(row)},
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
    'dedupe_crew',
    description:
        'Find crew members whose names normalise to the same key, so the same '
        'pilot is saved twice. Each member is id, name and archived. Returns '
        'every duplicate group. Local rows only unless include_shared.',
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
        final rows = db.query('SELECT id, name, archived FROM crew_members'
            '${owner.isEmpty ? '' : ' WHERE $owner'} '
            'ORDER BY name, id');
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final row in rows) {
          final key = _normalizeKey(asText(row['name']) ?? '');
          if (key.isEmpty) continue;
          groups.putIfAbsent(key, () => []).add(row);
        }
        final duplicates = [
          for (final entry in groups.entries)
            if (entry.value.length > 1)
              {'name': entry.key, 'members': entry.value},
        ];
        return _ok({
          'count': duplicates.length,
          'duplicates': duplicates,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  // One pass over the logbook's defect classes, so an agent can see the whole
  // mess before repairing any of it.
  server.registerTool(
    'data_quality_report',
    description:
        'Every defect class an imported logbook can have, in one call: drafts, '
        'missing or mismatched day/night splits, absurd totals, unlinked '
        'aircraft and crew, duplicate crew and duplicate flights, unparsable '
        'routes, future dates, dangling route links, simulator oddities and '
        'orphaned registration text. Each class carries a count and a small '
        'sample; act on a class with merge_crew or the link tools. Read-only.',
    inputSchema: JsonSchema.object(properties: {
      _includeSharedKey: JsonSchema.boolean(
          description:
              'Include rows owned by another device or account. Default false.'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(args, {_includeSharedKey}, tool: 'data_quality_report');
        final owner = _ownerClause(db, 'flights',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final classes = <Map<String, dynamic>>[];
        final flights = db.query(
          'SELECT id, date, route, route_id, total_time, day_time, night_time,'
          ' is_simulator, aircraft_id, aircraft_registration,'
          ' crew_member_id, crew_members_name FROM flights'
          '${owner.isEmpty ? '' : ' WHERE $owner'} ORDER BY date DESC, id',
        );
        final routesTable = db.hasTable('saved_routes');

        // One rendering per flight, reused by the sample rows: id, date,
        // route, so an agent can act on a class without a second lookup.
        Map<String, dynamic> sample(Map<String, dynamic> row,
                [Map<String, dynamic>? extra]) =>
            {
              'id': row['id'],
              'date': row['date'],
              if (row['route'] != null) 'route': row['route'],
              ...?extra,
            };

        void addClass(String id, String label, List<Map<String, dynamic>> rows,
            {int? count}) {
          if (rows.isEmpty && (count ?? 0) == 0) return;
          classes.add({
            'id': id,
            'label': label,
            'count': count ?? rows.length,
            'sample': [
              for (final row in rows.take(_reportSampleCap)) row,
            ],
          });
        }

        final drafts = <Map<String, dynamic>>[];
        final missingSplit = <Map<String, dynamic>>[];
        final splitMismatch = <Map<String, dynamic>>[];
        final absurdTotals = <Map<String, dynamic>>[];
        final aircraftMatchable = <Map<String, dynamic>>[];
        final aircraftUnmatched = <Map<String, dynamic>>[];
        final crewMatchable = <Map<String, dynamic>>[];
        final routeUnparsable = <Map<String, dynamic>>[];
        final futureDates = <Map<String, dynamic>>[];
        final danglingRoute = <Map<String, dynamic>>[];
        final simulatorOdd = <Map<String, dynamic>>[];
        final orphanedText = <Map<String, dynamic>>[];
        final today = _todayLocalMidnightEpoch();
        for (final flight in flights) {
          final total = asInt(flight['total_time']);
          final day = asInt(flight['day_time']);
          final night = asInt(flight['night_time']);
          final sim = asBool(flight['is_simulator']) ?? false;
          final aircraftId = asText(flight['aircraft_id']);
          final registration = asText(flight['aircraft_registration'])?.trim();
          final crewId = asText(flight['crew_member_id']);
          final crewName = asText(flight['crew_members_name'])?.trim();
          if (total == null) drafts.add(sample(flight));
          if (total != null && !sim && (day == null || night == null)) {
            missingSplit.add(sample(flight));
          }
          if (total != null && day != null && night != null && !sim) {
            if (day + night != total) splitMismatch.add(sample(flight));
          }
          if (total != null && (total == 0 || total > maxFlightMinutes)) {
            absurdTotals.add(sample(flight));
          }
          if (aircraftId == null &&
              registration != null &&
              registration.isNotEmpty) {
            final matches = _aircraftCandidates(db, registration);
            final extra = <String, dynamic>{
              'aircraft_registration': registration,
              'candidates': matches.length,
            };
            if (matches.isEmpty) {
              aircraftUnmatched.add(sample(flight, extra));
            } else {
              aircraftMatchable.add(sample(flight, extra));
            }
          }
          if (crewId == null &&
              crewName != null &&
              crewName.isNotEmpty &&
              _crewCandidates(db, crewName).isNotEmpty) {
            crewMatchable.add(sample(flight));
          }
          final route = asText(flight['route'])?.trim();
          if (route != null && route.isNotEmpty && parseRoute(route) == null) {
            routeUnparsable.add(sample(flight));
          }
          final date = _localDate(flight['date']);
          if (date != null && date.millisecondsSinceEpoch ~/ 1000 > today) {
            futureDates.add(sample(flight));
          }
          if (routesTable &&
              flight['route_id'] != null &&
              db.query('SELECT id FROM saved_routes WHERE id = ?',
                  [flight['route_id']]).isEmpty) {
            danglingRoute.add(sample(flight));
          }
          if (sim && total == null) {
            simulatorOdd.add(sample(flight, {'reason': 'no_duration'}));
          } else if (sim &&
              aircraftId != null &&
              db.query(
                  'SELECT id FROM aircraft WHERE id = ? '
                  'AND coalesce(simulator, 0) = 0',
                  [aircraftId]).isNotEmpty) {
            simulatorOdd.add(sample(flight, {'reason': 'aircraft_not_sim'}));
          }
          if ((aircraftId != null) !=
              (registration != null && registration.isNotEmpty)) {
            orphanedText.add(sample(flight, {
              'aircraft_id': aircraftId,
              'aircraft_registration': registration,
            }));
          }
        }

        // Duplicate crews and flights are group lenses: the sample entry is
        // the group with every member id, not a lone row.
        final crewOwner = _ownerClause(db, 'crew_members',
            includeShared: asBool(args[_includeSharedKey]) ?? false);
        final crewRows = db.query('SELECT id, name, archived FROM crew_members'
            '${crewOwner.isEmpty ? '' : ' WHERE $crewOwner'} ORDER BY name, id');
        final crewGroups = <String, List<Map<String, dynamic>>>{};
        for (final row in crewRows) {
          final key = _normalizeKey(asText(row['name']) ?? '');
          if (key.isEmpty) continue;
          crewGroups.putIfAbsent(key, () => []).add(row);
        }
        final duplicateCrew = [
          for (final entry in crewGroups.entries)
            if (entry.value.length > 1)
              {
                'name': entry.key,
                'members': [
                  for (final member in entry.value)
                    {
                      'id': member['id'],
                      'name': member['name'],
                      'archived': member['archived'],
                    },
                ],
              },
        ];

        final flightGroups = <String, List<Map<String, dynamic>>>{};
        for (final flight in flights) {
          final key = [
            flight['date'],
            flight['route'],
            flight['aircraft_registration'],
            flight['total_time'],
          ].join('\u{1}');
          flightGroups.putIfAbsent(key, () => []).add(flight);
        }
        final duplicateFlights = [
          for (final entry in flightGroups.entries)
            if (entry.value.length > 1)
              {
                'date': entry.value.first['date'],
                'route': entry.value.first['route'],
                'aircraft_registration':
                    entry.value.first['aircraft_registration'],
                'total_time': entry.value.first['total_time'],
                'flight_ids': [for (final row in entry.value) row['id']],
              },
        ];

        addClass('drafts', 'Flights with no total_time (drafts)', drafts);
        addClass('missing_split',
            'Complete flights with a missing day/night split', missingSplit);
        addClass(
            'split_mismatch',
            'Flights whose day + night does not equal the total',
            splitMismatch);
        addClass(
            'absurd_totals',
            'Totals of zero, or above the app cap of $maxFlightMinutes minutes',
            absurdTotals);
        addClass(
            'aircraft_matchable',
            'Flights whose registration text matches an aircraft row, unlinked',
            aircraftMatchable);
        addClass(
            'aircraft_unmatched',
            'Flights whose registration text matches no aircraft row',
            aircraftUnmatched);
        addClass(
            'crew_matchable',
            'Flights whose crew name matches a crew member, unlinked',
            crewMatchable);
        addClass('duplicate_crew', 'Crew members whose names normalise alike',
            duplicateCrew);
        addClass('duplicate_flights',
            'Same date, route, registration and total', duplicateFlights);
        addClass(
            'route_unparsable',
            'Routes the app reads as free text, not an airport pair',
            routeUnparsable);
        addClass('future_dates', 'Flights dated after today', futureDates);
        addClass('dangling_route_link',
            'Route links pointing at no saved route', danglingRoute);
        addClass(
            'simulator_oddities',
            'Simulator sessions with no duration, or on a non-sim aircraft',
            simulatorOdd);
        addClass(
            'orphaned_aircraft_text',
            'One of the aircraft pair (link, registration text) set, other empty',
            orphanedText);

        return _ok({
          'generated_at': DateTime.now().toUtc().toIso8601String(),
          'total_flights': flights.length,
          'classes': classes,
        });
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  // A pasted roster is checked before anything is written. The write tool below
  // refuses on the same rule, but this one is read-only, so the questions the
  // agent has to ask (which tail, which airport, which crew) can be asked
  // before a single row lands.
  server.registerTool(
    'validate_flight_drafts',
    description:
        'Check a batch of proposed flights without writing anything. Pass '
        'flights as up to $_rosterRowCap objects using create_flight field '
        'names, plus optional date_from and date_to for the roster range. '
        'mode: roster (default) checks a pasted roster; import checks rows '
        'read from a logbook file, strictly: date must be YYYY-MM-DD (a '
        'spreadsheet serial or a text date is refused with its probable '
        'reading, never converted), duration cells must match the units '
        'declared on the call, and a column Falcon cannot store is reported '
        'with the real columns that could hold it, never dropped. units '
        '(minutes default, decimal_hours, hhmm) says how the file writes '
        'durations and applies only when mode is import. Returns valid and '
        'invalid counts and one entry per row with index, client_ref, ok, '
        'issues of {field, code, message, severity} and warnings. Severity '
        'error is a row apply_flight_batch would refuse; warning is a row '
        'worth asking about (unknown aircraft, an airport that does not '
        'resolve, a duplicate, a date out of range or out of order, and in '
        'import mode would_create_draft: a row with no total that would land '
        'as a draft); info is stored as text. A total_time on a leg with '
        'planned times is an error, because a total makes the flight '
        'complete. Row fields not in create_flight: client_ref (identity '
        'across retries) and aircraft_type (a hint, never stored). Write '
        'nothing and check the whole batch first, then apply it.',
    inputSchema: JsonSchema.object(properties: {
      'flights': JsonSchema.array(
        items: JsonSchema.object(properties: {}),
        description: 'Up to $_rosterRowCap flight objects, each with '
            'create_flight field names; date is required per row.',
      ),
      'date_from': JsonSchema.string(
          format: 'date',
          description: 'Inclusive start of the stated roster range.'),
      'date_to': JsonSchema.string(
          format: 'date', description: 'Inclusive end of the roster range.'),
      'mode': _importModeSchema,
      'units': _importUnitsSchema,
    }, required: [
      'flights'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        _rejectUnknown(
            args, {'flights', 'date_from', 'date_to', 'mode', 'units'},
            tool: 'validate_flight_drafts');
        final settings = _importSettings(args);
        final range = _rosterRange(args);
        final rows = _rosterRows(db, args,
            tool: 'validate_flight_drafts', range: range, settings: settings);
        return _ok(_rosterReport(rows, range));
      } on _ToolError catch (error) {
        return _failWith(error);
      } catch (error) {
        return _failWith(_asToolError(error));
      }
    },
  );

  if (!readonly) {
    // --- flights ---

    server.registerTool(
      'create_flight',
      description:
          'Create a flight. Times are minutes; total_time_hours, day_time_hours '
          'and night_time_hours are accepted instead. Sets aircraft_id and '
          'crew_member_id automatically when the registration or crew name '
          'matches, and names the candidates when a match is ambiguous. '
          'day_order is computed for the date. Returns the row as written as '
          'flight, with draft telling you whether it counts as a draft, and '
          'warnings for anything odd but legal.',
      inputSchema: JsonSchema.object(
        properties: {
          'dry_run': _dryRunSchema,
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

    // A whole roster lands in one call, one transaction and one audit entry,
    // through the same row builder as create_flight. It previews by default:
    // the resource tells the agent to show the plan and get an explicit yes
    // before passing dry_run: false.
    server.registerTool(
      'apply_flight_batch',
      description:
          'Create up to $_rosterRowCap flights from a roster or an import in '
          'one transaction, using create_flight field names per row. mode and '
          'units are as on validate_flight_drafts: an import row lands as it '
          'stands, complete when it carries a total and a draft when it does '
          'not. Defaults to dry_run: true, a preview with the same plan and '
          'verdicts and no rows written; pass dry_run: false to apply. Every '
          'row is validated first: by default any row with an error issue '
          '(the codes validate_flight_drafts reports) writes nothing and the '
          'response lists it with applied: 0. allow_partial: true writes the '
          'clean rows and reports the rest. A duplicate in the logbook or the '
          'batch is skipped, never overwritten, and so is a client_ref an '
          'earlier batch already imported. Returns batch_id, dry_run, '
          'applied, created ids, skipped and failed with {index, reason}. A '
          'leg with planned times lands as a draft with total_time empty.',
      inputSchema: JsonSchema.object(properties: {
        'dry_run': _dryRunSchema,
        'flights': JsonSchema.array(
          items: JsonSchema.object(properties: {}),
          description: 'Up to $_rosterRowCap flight objects, each with '
              'create_flight field names plus optional client_ref and '
              'aircraft_type; date is required per row.',
        ),
        'allow_partial': JsonSchema.boolean(
            description: 'Default false. true writes the rows with no error '
                'issue and reports each row it left out and why.'),
        'batch_id': JsonSchema.string(
            description: 'Optional id for this batch, recorded in the audit '
                'log. Generated when omitted.'),
        'mode': _importModeSchema,
        'units': _importUnitsSchema,
      }, required: [
        'flights'
      ]),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async {
        final batchId = asText(args['batch_id']) ?? uuidV4();
        final effectiveArgs = <String, dynamic>{
          ...args,
          'batch_id': batchId,
          // A batch write previews unless it is told to apply, like the
          // repairs: a plan the pilot has not seen must not fill the logbook.
          'dry_run': asBool(args['dry_run']) != false,
        };
        return _runWrite(db, auditor, 'apply_flight_batch', effectiveArgs, () {
          _rejectUnknown(
              args,
              {
                'flights',
                'dry_run',
                'allow_partial',
                'batch_id',
                'mode',
                'units',
              },
              tool: 'apply_flight_batch');
          final settings = _importSettings(args);
          final allowPartial = asBool(args['allow_partial']) ?? false;
          final rows = _rosterRows(db, args,
              tool: 'apply_flight_batch',
              range: (from: null, to: null),
              settings: settings);
          final imported = _importedClientRefs(dbPath);

          final failed = <Map<String, dynamic>>[
            for (final row in rows)
              if (!row.ok)
                {
                  'index': row.index,
                  'reason': row.firstError,
                  'issues': row.issues,
                },
          ];
          // Atomic by default: the whole roster is validated and one bad row
          // writes nothing. The answer is the validator's, not an error
          // envelope, so the agent can report exactly which rows to fix.
          if (!allowPartial && failed.isNotEmpty) {
            return {
              'batch_id': batchId,
              'dry_run': effectiveArgs['dry_run'] == true,
              'applied': 0,
              'created': const <String>[],
              'skipped': const <Map<String, dynamic>>[],
              'failed': failed,
              'valid': rows.where((row) => row.ok).length,
              'invalid': failed.length,
              'affected_ids': const <String>[],
              'created_refs': const <String>[],
            };
          }

          final created = <String>[];
          final createdRefs = <String>[];
          final skipped = <Map<String, dynamic>>[];
          for (final row in rows) {
            if (!row.ok) continue;
            final clientRef = row.clientRef;
            if (clientRef != null && imported.contains(clientRef)) {
              skipped.add({
                'index': row.index,
                'code': 'client_ref_seen',
                'reason': 'client_ref "$clientRef" was already imported in an '
                    'earlier batch',
              });
              continue;
            }
            final skip = row.skipCode;
            if (skip != null) {
              skipped.add({
                'index': row.index,
                'code': skip,
                'reason': row.issues
                    .firstWhere((issue) => issue['code'] == skip)['message'],
              });
              continue;
            }
            final values = row.values!;
            final date = asInt(values['date']);
            if (date == null) {
              failed.add({
                'index': row.index,
                'reason': 'date is required',
              });
              continue;
            }
            final id = uuidV4();
            final fields = <String, Object?>{
              'id': id,
              'day_order': _nextDayOrder(db, date),
              ..._createdStamp(db, 'flights'),
              ...values,
            };
            db.execute(
              'INSERT INTO flights (${fields.keys.join(', ')}) VALUES (${List.filled(fields.length, '?').join(', ')})',
              fields.values.toList(),
            );
            created.add(id);
            if (clientRef != null) {
              imported.add(clientRef);
              createdRefs.add(clientRef);
            }
          }

          return {
            'batch_id': batchId,
            'dry_run': effectiveArgs['dry_run'] == true,
            'applied': created.length,
            'created': created,
            'skipped': skipped,
            'failed': failed,
            'affected_ids': created,
            'created_refs': createdRefs,
          };
        });
      },
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
          'dry_run': _dryRunSchema,
          'id': JsonSchema.string(),
          'expected_updated_at': _expectedUpdatedAtSchema,
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
        // The guard is this tool's own argument; _flightValues rejects
        // unknown flight fields, and create_flight does not take it.
        final writeArgs = Map<String, dynamic>.of(args)
          ..remove('expected_updated_at');
        final flight = _flightValues(db, writeArgs, tool: 'update_flight');
        if (flight.values.isEmpty) throw _ToolError('No fields to update');
        final values = Map<String, Object?>.of(flight.values);
        final date = asInt(values['date']);
        if (date != null && !_sameLocalDay(before['date'], date)) {
          values['day_order'] = _nextDayOrder(db, date);
        }
        final assignments = [for (final column in values.keys) '$column = ?'];
        final guard = _optimisticGuard(args);
        final changed = db.execute(
          'UPDATE flights SET ${assignments.join(', ')}, updated_at = ? '
          'WHERE id = ?${guard.$1}',
          [...values.values, nowEpochSeconds(), id, ...guard.$2],
        );
        _requireUpdated(db,
            table: 'flights',
            id: id,
            changed: changed,
            label: 'Flight',
            tool: 'update_flight',
            expected: _expectedUpdatedAtOf(args));
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
          properties: {'dry_run': _dryRunSchema, 'id': JsonSchema.string()},
          required: ['id']),
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
        _deleteSyncedRow(db, 'flights', id, 'Flight');
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
          'dry_run': _dryRunSchema,
          'id': _createIdSchema,
          ..._propertiesOf(_supported(db, 'aircraft', _aircraftColumns)),
        },
        required: ['type', 'registration'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_aircraft', args, () {
        _rejectUnknown(args, _fieldNames(_aircraftColumns, {'id', 'dry_run'}),
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
          'dry_run': _dryRunSchema,
          'id': JsonSchema.string(),
          'expected_updated_at': _expectedUpdatedAtSchema,
          ..._propertiesOf(_supported(db, 'aircraft', _aircraftColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_aircraft', args, () {
        _rejectUnknown(
            args,
            _fieldNames(
                _aircraftColumns, {'id', 'expected_updated_at', 'dry_run'}),
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
        final guard = _optimisticGuard(args);
        final changed = db.execute(
          'UPDATE aircraft SET ${assignments.join(', ')}, updated_at = ? '
          'WHERE id = ?${guard.$1}',
          [...values, nowEpochSeconds(), id, ...guard.$2],
        );
        _requireUpdated(db,
            table: 'aircraft',
            id: id,
            changed: changed,
            label: 'Aircraft',
            tool: 'update_aircraft',
            expected: _expectedUpdatedAtOf(args));
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_aircraft',
      description:
          'Delete an aircraft by id. Flights keep their registration text but lose the link.',
      inputSchema: JsonSchema.object(
          properties: {'dry_run': _dryRunSchema, 'id': JsonSchema.string()},
          required: ['id']),
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
        _deleteSyncedRow(db, 'aircraft', id, 'Aircraft');
        return _deleted('aircraft', id);
      }),
    );

    // --- crew ---

    server.registerTool(
      'add_crew',
      description: 'Add a crew member.',
      inputSchema: JsonSchema.object(
        properties: {
          'dry_run': _dryRunSchema,
          'id': _createIdSchema,
          ..._propertiesOf(_supported(db, 'crew_members', _crewColumns)),
        },
        required: ['first_name', 'last_name'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_crew', args, () {
        _rejectUnknown(args, _fieldNames(_crewColumns, {'id', 'dry_run'}),
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
          'dry_run': _dryRunSchema,
          'id': JsonSchema.string(),
          'expected_updated_at': _expectedUpdatedAtSchema,
          ..._propertiesOf(_supported(db, 'crew_members', _crewColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_crew', args, () {
        _rejectUnknown(args,
            _fieldNames(_crewColumns, {'id', 'expected_updated_at', 'dry_run'}),
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
        final guard = _optimisticGuard(args);
        final changed = db.execute(
          'UPDATE crew_members SET ${assignments.join(', ')}, updated_at = ? '
          'WHERE id = ?${guard.$1}',
          [...values, nowEpochSeconds(), id, ...guard.$2],
        );
        _requireUpdated(db,
            table: 'crew_members',
            id: id,
            changed: changed,
            label: 'Crew member',
            tool: 'update_crew',
            expected: _expectedUpdatedAtOf(args));
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_crew',
      description:
          'Delete a crew member by id. Flights keep the crew name but lose the link.',
      inputSchema: JsonSchema.object(
          properties: {'dry_run': _dryRunSchema, 'id': JsonSchema.string()},
          required: ['id']),
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
        _deleteSyncedRow(db, 'crew_members', id, 'Crew member');
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
          'dry_run': _dryRunSchema,
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
        _rejectUnknown(
            args, _fieldNames(_customAirportColumns, {'id', 'dry_run'}),
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
          'dry_run': _dryRunSchema,
          'id': JsonSchema.string(),
          'expected_updated_at': _expectedUpdatedAtSchema,
          ..._propertiesOf(
              _supported(db, 'custom_airports', _customAirportColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_custom_airport', args, () {
        _rejectUnknown(
            args,
            _fieldNames(_customAirportColumns,
                {'id', 'expected_updated_at', 'dry_run'}),
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
        final guard = _optimisticGuard(args);
        final changed = db.execute(
          'UPDATE custom_airports SET ${assignments.join(', ')}, updated_at = ? '
          'WHERE id = ?${guard.$1}',
          [...values, nowEpochSeconds(), id, ...guard.$2],
        );
        _requireUpdated(db,
            table: 'custom_airports',
            id: id,
            changed: changed,
            label: 'Custom airport',
            tool: 'update_custom_airport',
            expected: _expectedUpdatedAtOf(args));
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_custom_airport',
      description: 'Delete a custom airport by id.',
      inputSchema: JsonSchema.object(
          properties: {'dry_run': _dryRunSchema, 'id': JsonSchema.string()},
          required: ['id']),
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
        _deleteSyncedRow(db, 'custom_airports', id, 'Custom airport');
        return _deleted('custom_airports', id);
      }),
    );

    // --- saved routes ---

    server.registerTool(
      'add_saved_route',
      description: 'Add a saved route.',
      inputSchema: JsonSchema.object(
        properties: {
          'dry_run': _dryRunSchema,
          ..._propertiesOf(_supported(db, 'saved_routes', _savedRouteColumns)),
        },
        required: ['flight_number', 'departure_icao', 'arrival_icao'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'add_saved_route', args, () {
        _rejectUnknown(args, _fieldNames(_savedRouteColumns, {'id', 'dry_run'}),
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
          'dry_run': _dryRunSchema,
          'id': JsonSchema.integer(),
          'expected_updated_at': _expectedUpdatedAtSchema,
          ..._propertiesOf(_supported(db, 'saved_routes', _savedRouteColumns))
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_saved_route', args, () {
        _rejectUnknown(
            args,
            _fieldNames(
                _savedRouteColumns, {'id', 'expected_updated_at', 'dry_run'}),
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
        final guard = _optimisticGuard(args);
        final changed = db.execute(
          'UPDATE saved_routes SET ${assignments.join(', ')}, updated_at = ? '
          'WHERE id = ?${guard.$1}',
          [...values, nowEpochSeconds(), id, ...guard.$2],
        );
        _requireUpdated(db,
            table: 'saved_routes',
            id: id,
            changed: changed,
            label: 'Saved route',
            tool: 'update_saved_route',
            expected: _expectedUpdatedAtOf(args));
        return {'status': 'updated', 'id': id};
      }),
    );

    server.registerTool(
      'delete_saved_route',
      description:
          'Delete a saved route by id. Flights that referenced it are unlinked.',
      inputSchema: JsonSchema.object(
          properties: {'dry_run': _dryRunSchema, 'id': JsonSchema.integer()},
          required: ['id']),
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
        // The delete's affected-row count decides whether anything happened:
        // a route a concurrent writer removed after the existence check ends
        // in a not_found error instead of unlinking flights for nothing.
        db.transaction(() {
          final deleted =
              db.execute('DELETE FROM saved_routes WHERE id = ?', [id]);
          if (deleted == 0) {
            throw _ToolError('Saved route not found: $id',
                code: 'not_found', field: 'id');
          }
          db.execute(
              'UPDATE flights SET route_id = NULL WHERE route_id = ?', [id]);
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
        properties: {
          'dry_run': _dryRunSchema,
          'expected_updated_at': _expectedUpdatedAtSchema,
          ..._propertiesOf(
              _supported(db, 'flights_settings', _flightSettingsColumns)),
        },
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(db, auditor, 'update_flight_settings', args, () {
        _rejectUnknown(
            args,
            _fieldNames(
                _flightSettingsColumns, {'expected_updated_at', 'dry_run'}),
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
        // The guard only makes sense on the update path: a row this call
        // inserts itself carries a stamp from now, not from the caller's
        // read, so expecting one could never match.
        final guard =
            existing.isEmpty ? ('', const <Object?>[]) : _optimisticGuard(args);
        db.transaction(() {
          if (db.query(
              'SELECT id FROM flights_settings WHERE id = ?', [id]).isEmpty) {
            db.execute(
              'INSERT INTO flights_settings (${fields.keys.join(', ')}) '
              'VALUES (${List.filled(fields.length, '?').join(', ')})',
              fields.values.toList(),
            );
          }
          final changed = db.execute(
            'UPDATE flights_settings SET ${assignments.join(', ')}, updated_at = ? '
            'WHERE id = ?${guard.$1}',
            [...values, nowEpochSeconds(), id, ...guard.$2],
          );
          _requireUpdated(db,
              table: 'flights_settings',
              id: id,
              changed: changed,
              label: 'Flight settings',
              tool: 'update_flight_settings',
              expected: existing.isEmpty ? null : _expectedUpdatedAtOf(args));
        });
        return {
          'status': 'updated',
          'id': id,
          'settings': db
              .query('SELECT * FROM flights_settings WHERE id = ?', [id]).first,
        };
      }),
    );

    // --- repairs: dry-run-first fixes for an imported logbook ---

    server.registerTool(
      'merge_crew',
      description:
          'Merge duplicate crew members the way the app does: flights pointing '
          'at the discarded rows are repointed at the survivor with the '
          "survivor's name, and each discarded row is deleted with a sync "
          'tombstone. dry_run defaults to true; pass false to apply. Find the '
          'ids with dedupe_crew. Refuses a missing id, into_id inside '
          'from_ids, and an archived survivor over an active row.',
      inputSchema: JsonSchema.object(
        properties: {
          'dry_run': _repairDryRunSchema,
          'into_id': JsonSchema.string(
              description: 'The crew member that survives the merge.'),
          'from_ids': JsonSchema.array(
            items: JsonSchema.string(),
            description: 'The crew members to merge away and delete.',
          ),
        },
        required: ['into_id', 'from_ids'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: true, openWorldHint: false),
      callback: (args, extra) async {
        // A repair defaults to a preview: the agent must say false to apply.
        final effectiveArgs = {
          ...args,
          'dry_run': asBool(args['dry_run']) != false,
        };
        return _runWrite(db, auditor, 'merge_crew', effectiveArgs, () {
          final intoId = asText(args['into_id']);
          if (intoId == null) {
            throw _ToolError('into_id is required', field: 'into_id');
          }
          final fromIds = _idListArg(args, 'from_ids');
          if (fromIds.isEmpty) {
            throw _ToolError(
                'from_ids needs at least one crew id to merge away',
                field: 'from_ids');
          }
          if (fromIds.contains(intoId)) {
            throw _ToolError('into_id must not also be in from_ids',
                field: 'into_id');
          }
          final keepRows = db.query(
              'SELECT id, name, first_name, last_name, archived '
              'FROM crew_members WHERE id = ?',
              [intoId]);
          if (keepRows.isEmpty) {
            throw _ToolError('Crew member not found: $intoId',
                code: 'not_found', field: 'into_id');
          }
          final keep = keepRows.first;
          final keepArchived = asBool(keep['archived']) ?? false;
          final keepName = (asText(keep['name']) ?? '').trim();
          final discards = <Map<String, dynamic>>[];
          for (final id in fromIds) {
            final rows = db.query(
                'SELECT id, name, archived FROM crew_members WHERE id = ?',
                [id]);
            if (rows.isEmpty) {
              throw _ToolError('Crew member not found: $id',
                  code: 'not_found', field: 'from_ids');
            }
            final discard = rows.single;
            if (keepArchived && !(asBool(discard['archived']) ?? false)) {
              throw _ToolError(
                  'The survivor ${keep['name']} is archived and $id is not; '
                  'merge into an active crew member instead.',
                  field: 'into_id');
            }
            discards.add(discard);
          }

          // The app's merge (crewDao.mergeCrewMembers): repoint every flight
          // linked to the discard, then the flights whose text names the
          // discard but whose link points elsewhere, then tombstone and
          // delete the discard. One transaction, so a refusal halfway leaves
          // every row as it was.
          var repointed = 0;
          var renamed = 0;
          final removed = <Map<String, dynamic>>[];
          final affectedIds = <String>[intoId];
          for (final discard in discards) {
            final discardId = discard['id'] as String;
            final discardName = (asText(discard['name']) ?? '').trim();
            affectedIds.addAll([
              for (final row in db.query(
                  'SELECT id FROM flights WHERE crew_member_id = ?',
                  [discardId]))
                row['id'] as String,
            ]);
            repointed += db.execute(
              'UPDATE flights SET crew_member_id = ?, crew_members_name = ?, '
              'updated_at = ? WHERE crew_member_id = ?',
              [intoId, keepName, nowEpochSeconds(), discardId],
            );
            if (discardName.isNotEmpty) {
              affectedIds.addAll([
                for (final row in db.query(
                    'SELECT id FROM flights WHERE crew_members_name = ? '
                    'AND crew_member_id IS NOT NULL AND crew_member_id != ?',
                    [discardName, intoId]))
                  row['id'] as String,
              ]);
              renamed += db.execute(
                'UPDATE flights SET crew_member_id = ?, crew_members_name = ?, '
                'updated_at = ? WHERE crew_members_name = ? '
                'AND crew_member_id IS NOT NULL AND crew_member_id != ?',
                [intoId, keepName, nowEpochSeconds(), discardName, intoId],
              );
            }
            _deleteSyncedRow(db, 'crew_members', discardId, 'Crew member');
            affectedIds.add(discardId);
            removed.add({'id': discardId, 'name': discard['name']});
          }
          return {
            'status': 'merged',
            'id': intoId,
            'name': keepName,
            'flights_repointed': repointed,
            'flights_renamed': renamed,
            'removed': removed,
            'affected_ids': affectedIds,
          };
        });
      },
    );

    server.registerTool(
      'link_flights_to_aircraft',
      description:
          'Link flights to aircraft by resolving their registration text '
          'against the fleet, the way a write does, so "VH-XZO" or "XZO" '
          'matches an aircraft stored as bare "XZO". Also fills registration '
          'text from the linked aircraft when the link is set and the text is '
          'empty. Ambiguous registrations (one tail under two countries) are '
          'reported, not guessed, unless logbook_country settles them. Never '
          'creates aircraft. dry_run defaults to true.',
      inputSchema: JsonSchema.object(properties: {
        'dry_run': _repairDryRunSchema,
        'aircraft_id': JsonSchema.string(
            description:
                'Link the named flights to this aircraft (the picker flow, '
                'after ask_user). Requires flight_ids.'),
        'flight_ids': JsonSchema.array(
          items: JsonSchema.string(),
          description: 'Link only these flights. Default: every flight with an '
              'unresolved aircraft pair.',
        ),
      }),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async {
        final effectiveArgs = {
          ...args,
          'dry_run': asBool(args['dry_run']) != false,
        };
        return _runWrite(db, auditor, 'link_flights_to_aircraft', effectiveArgs,
            () {
          final aircraftId = asText(args['aircraft_id']);
          final flightIds = _idListArg(args, 'flight_ids');
          final preferred = _preferredCountryCodes(db);

          // The picker flow: the user chose one aircraft, the agent names the
          // flights. Resolve nothing; link what it was told to.
          Map<String, dynamic>? target;
          if (aircraftId != null) {
            final rows = db.query(
                'SELECT id, country_code, registration FROM aircraft '
                'WHERE id = ?',
                [aircraftId]);
            if (rows.isEmpty) {
              throw _ToolError('Aircraft not found: $aircraftId',
                  code: 'not_found', field: 'aircraft_id');
            }
            if (flightIds.isEmpty) {
              throw _ToolError(
                  'aircraft_id names the target; pass flight_ids to say which '
                  'flights to link',
                  field: 'flight_ids');
            }
            target = rows.first;
          }

          final candidates = <Map<String, dynamic>>[];
          if (flightIds.isNotEmpty) {
            for (final id in flightIds) {
              final rows = db.query(
                  'SELECT id, date, route, aircraft_id,'
                  ' aircraft_registration FROM flights WHERE id = ?',
                  [id]);
              if (rows.isEmpty) {
                throw _ToolError('Flight not found: $id',
                    code: 'not_found', field: 'flight_ids');
              }
              candidates.add(rows.single);
            }
          } else {
            if (aircraftId != null) {
              throw _ToolError(
                  'Pass flight_ids to say which flights to link to $aircraftId',
                  field: 'flight_ids');
            }
            candidates.addAll(db.query(
              'SELECT id, date, route, aircraft_id, aircraft_registration '
              'FROM flights WHERE (aircraft_id IS NULL AND '
              "trim(coalesce(aircraft_registration, '')) != '') OR "
              "(aircraft_id IS NOT NULL AND "
              "trim(coalesce(aircraft_registration, '')) = '') "
              'ORDER BY date DESC, id',
            ));
          }

          var linked = 0;
          var reverseFixed = 0;
          final ambiguous = <Map<String, dynamic>>[];
          final unmatched = <Map<String, dynamic>>[];
          final affectedIds = <String>[];
          for (final flight in candidates) {
            final id = flight['id'] as String;
            final currentId = asText(flight['aircraft_id']);
            final registration =
                asText(flight['aircraft_registration'])?.trim();
            final hasText = registration != null && registration.isNotEmpty;

            String displayOf(Map<String, dynamic> aircraft) =>
                _displayRegistration(asText(aircraft['country_code']),
                    asText(aircraft['registration']) ?? '');

            void linkTo(String targetId, String display) {
              db.execute(
                'UPDATE flights SET aircraft_id = ?, aircraft_registration = ?,'
                ' updated_at = ? WHERE id = ?',
                [targetId, display, nowEpochSeconds(), id],
              );
              linked++;
              affectedIds.add(id);
            }

            if (target != null) {
              linkTo(target['id'] as String, displayOf(target));
              continue;
            }
            if (currentId != null && !hasText) {
              // The reverse case: the link is set and the text went missing.
              final rows = db.query(
                  'SELECT country_code, registration FROM aircraft '
                  'WHERE id = ?',
                  [currentId]);
              if (rows.isEmpty) {
                unmatched.add({
                  'flight_id': id,
                  'aircraft_id': currentId,
                  'detail': 'linked aircraft row no longer exists',
                });
              } else {
                db.execute(
                  'UPDATE flights SET aircraft_registration = ?, updated_at = ?'
                  ' WHERE id = ?',
                  [displayOf(rows.first), nowEpochSeconds(), id],
                );
                reverseFixed++;
                affectedIds.add(id);
              }
              continue;
            }
            if (currentId != null) continue;
            final matches = _aircraftCandidates(db, registration!);
            var chosen = matches;
            if (matches.length > 1 && preferred.isNotEmpty) {
              final inCountry = matches
                  .where((match) => preferred.contains(match.countryCode))
                  .toList();
              if (inCountry.length == 1) chosen = inCountry;
            }
            if (chosen.length == 1) {
              linkTo(chosen.single.id, chosen.single.display);
            } else if (matches.isEmpty) {
              unmatched.add(
                  {'flight_id': id, 'aircraft_registration': registration});
            } else {
              ambiguous.add({
                'flight_id': id,
                'aircraft_registration': registration,
                'candidates': [
                  for (final match in matches)
                    {'id': match.id, 'registration': match.display},
                ],
              });
            }
          }
          return {
            'status': 'linked',
            'linked': linked,
            if (reverseFixed > 0) 'reverse_fixed': reverseFixed,
            if (ambiguous.isNotEmpty)
              'ambiguous': ambiguous.length > _reportSampleCap * 5
                  ? ambiguous.take(_reportSampleCap * 5).toList()
                  : ambiguous,
            if (unmatched.isNotEmpty)
              'unmatched': unmatched.length > _reportSampleCap * 5
                  ? unmatched.take(_reportSampleCap * 5).toList()
                  : unmatched,
            'affected_ids': affectedIds,
          };
        });
      },
    );

    server.registerTool(
      'link_flights_to_crew',
      description:
          'Link flights to crew members by resolving their crew name text '
          'against the fleet, so "J Smith" matches a crew member stored as '
          '"John Smith" when the normaliser agrees. Ambiguous names (two crew '
          'whose names normalise alike) are reported, never guessed. dry_run '
          'defaults to true.',
      inputSchema: JsonSchema.object(properties: {
        'dry_run': _repairDryRunSchema,
        'flight_ids': JsonSchema.array(
          items: JsonSchema.string(),
          description:
              'Link only these flights. Default: every flight with a crew '
              'name but no crew link.',
        ),
      }),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async {
        final effectiveArgs = {
          ...args,
          'dry_run': asBool(args['dry_run']) != false,
        };
        return _runWrite(db, auditor, 'link_flights_to_crew', effectiveArgs,
            () {
          final flightIds = _idListArg(args, 'flight_ids');
          final candidates = <Map<String, dynamic>>[];
          if (flightIds.isNotEmpty) {
            for (final id in flightIds) {
              final rows = db.query(
                  'SELECT id, date, route, crew_member_id, crew_members_name '
                  'FROM flights WHERE id = ?',
                  [id]);
              if (rows.isEmpty) {
                throw _ToolError('Flight not found: $id',
                    code: 'not_found', field: 'flight_ids');
              }
              candidates.add(rows.single);
            }
          } else {
            candidates.addAll(db.query(
              "SELECT id, date, route, crew_member_id, crew_members_name FROM"
              " flights WHERE crew_member_id IS NULL AND"
              " trim(coalesce(crew_members_name, '')) != ''"
              ' ORDER BY date DESC, id',
            ));
          }

          var linked = 0;
          final ambiguous = <Map<String, dynamic>>[];
          final unmatched = <Map<String, dynamic>>[];
          final affectedIds = <String>[];
          for (final flight in candidates) {
            final id = flight['id'] as String;
            final name = asText(flight['crew_members_name'])?.trim();
            if (name == null || name.isEmpty) continue;
            final matches = _crewCandidates(db, name);
            if (matches.length == 1) {
              db.execute(
                'UPDATE flights SET crew_member_id = ?, updated_at = ? '
                'WHERE id = ?',
                [matches.single.id, nowEpochSeconds(), id],
              );
              linked++;
              affectedIds.add(id);
            } else if (matches.isEmpty) {
              unmatched.add({'flight_id': id, 'crew_members_name': name});
            } else {
              ambiguous.add({
                'flight_id': id,
                'crew_members_name': name,
                'candidates': [
                  for (final match in matches)
                    {'id': match.id, 'name': match.name},
                ],
              });
            }
          }
          return {
            'status': 'linked',
            'linked': linked,
            if (ambiguous.isNotEmpty)
              'ambiguous': ambiguous.length > _reportSampleCap * 5
                  ? ambiguous.take(_reportSampleCap * 5).toList()
                  : ambiguous,
            if (unmatched.isNotEmpty)
              'unmatched': unmatched.length > _reportSampleCap * 5
                  ? unmatched.take(_reportSampleCap * 5).toList()
                  : unmatched,
            'affected_ids': affectedIds,
          };
        });
      },
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
          'with each row a summary and times in minutes. Use list_flights for '
          'filters, paging and full rows.',
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
                'Use the falcon_help prompt for what it can do and falcon://conventions for field semantics.',
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
                '- Dates are calendar dates: stored as unix epoch seconds of the logbook zone\'s local midnight, returned as YYYY-MM-DD. Timestamps are stored as unix epoch seconds and returned as ISO-8601 with an explicit offset, for example 2026-10-27T00:00:00.000+1100. The logbook time zone is the zone the Falcon app wrote local midnights in, declared by the FALCON_TZ environment variable (an IANA name such as Australia/Sydney); when FALCON_TZ is unset the server\'s system zone applies. The flights.date column holds logbook-zone midnight of the flight date; tool inputs accept YYYY-MM-DD and are converted the same way. Calendar dates, filtered windows and counts are identical whatever zone the server itself runs in.\n'
                '- Read filters accept only YYYY-MM-DD (or a named period) and reject anything else instead of ignoring it. Every filtered response echoes the applied window as range {from, to}.\n'
                '- Flight time columns (total_time, day_time, night_time, actual_instrument, simulated_instrument, ground_instrument, icus_day_time, icus_night_time) are integer MINUTES. Responses state this in a units object. Write tools also accept an _hours form of any of them, for example total_time_hours or icus_night_time_hours.\n'
                '- Flight time is capped at 525600 minutes (8760 hours) and takeoff/landing counts at 10000, the same limits the app enforces. A value outside either is refused, and the error names the limit.\n'
                '- day_time and night_time must add up to total_time when both are supplied: the app cannot display any other split, so it is refused. A one-sided split (for example day_time equal to total_time with no night_time) is stored as given and reported in warnings, because the app saves those itself. find_missing_times lists every row the app cannot show complete, with a reason per row.\n'
                '- time_start and time_stop are 24-hour clock times stored as HH:MM. Write tools accept 9, 930, 9:30, 09:30 or 0930 and refuse anything else, so 9am is rejected rather than stored. They pair with calc_time_mode (utc, local, time, hobbsTacho) and hobbs_start/hobbs_stop when that mode was used. They are not stored as durations.\n'
                '- A flight is a DRAFT when total_time IS NULL. Set total_time (1 minute or more) to make it complete. total_time 0 is refused: the app stores 0 as a complete flight with no duration, which the pilot cannot see or fix. To clear a time and make a flight a draft again, pass draft: true, because a null total_time cannot be sent over MCP. Lists include drafts, sums exclude them, and logbook_stats separates flights, flights_complete, zero_time and drafts.\n'
                '- ids for flights, aircraft, crew_members, custom_airports and flights_settings are RFC 4122 version 4 UUIDs, lowercase and hyphenated, the shape the cloud schema requires before a row can sync. A create tool accepts an optional UUID v4 id so an import can keep its own, and refuses any other shape. saved_routes keeps its integer id.\n'
                '- day_order is the order of a flight within its date: a create takes the next free order for that day, and an update recomputes it when the date moves the flight to another day. updated_at records the last write.\n'
                '- Flights are ordered date DESC, day_order DESC, id, the same as the app. Flights on the same date are newest-first within the day.\n'
                '- Reads return local rows only (owner_id NULL or "local") unless include_shared is true. Paged reads return count (rows on this page), total (all matching rows), has_more and offset, and default to 20 rows with a maximum of 200; the list reads state in their own limit description how many they return and report total and has_more. A listed flight is a summary, with departure_icao and arrival_icao derived from route, unless full: true.\n'
                '- flights.route is free text. It is a route pair only when it is exactly "AAA - BBB": two segments split on " - ", each 3 or 4 characters and equal in length, the same rule the app applies. Anything else is a description and has no direction, so departure_icao and arrival_icao are null and the route filters cannot match it. The two codes are derived, not stored: full rows and get_flight carry them, the twelve-field summary does not. Write tools warn when a route will be stored as a description.\n'
                '- aircraft.registration is the BARE registration (e.g. country_code=VH, registration=XZO). The app displays country_code + "-" + registration.\n'
                '- flights.aircraft_registration is the display registration (e.g. VH-XZO). Write tools accept either form and set aircraft_id from the matching aircraft row; flights.crew_members_name is matched the same way to set crew_member_id. When more than one active row matches a name or registration, the link is left unset and the warning lists the candidates, so pass aircraft_id or crew_member_id to choose.\n'
                '- Read filters on flights match without case: aircraft_registration takes bare (XZO) or display (VH-XZO), flight_type takes route or details, and a crew_members_name filter also matches flights linked to that crew row. departure_icao and arrival_icao match one direction only and never a description. Airport search ranks an exact code first, then a prefix, then name or city, and ties break on ICAO.\n'
                '- flight_type values: route, details. crew_role values: pilotInCommand, copilot, student.\n'
                '- find_missing_times lists every row the app cannot show complete, with a reason per row: draft (no total), missing_split (both sides null), half_split (one side null), split_mismatch (the sides do not add up), or simulator_no_duration. Simulator sessions are excluded unless include_simulator is true, because the app expects them to carry a total and no split.\n'
                '- calculate_time_mode values: utc, local, time, hobbsTacho. flight_time_format values: hhmm, decimal1, decimal2.\n'
                '- logbook_country is "AU", "NZ", or null.\n'
                '- total_time is the authoritative flight duration; takeoffs/landings are counts per flight row.\n'
                '- is_simulator and is_ifr are stored as 0/1 and rendered as true or false, as are archived and the aircraft flags (multi_engine, ifr, complex, pressurised, tailwheel, simulator, helicopter, float_plane).\n'
                '- Expiry status is computed at read time, never stored: whole calendar days from today to due_date in the logbook zone, below the orange threshold is red (which includes today and every overdue day), below the green threshold is orange, green above it. Thresholds come from expiry_settings (a local row first, then the newest), or 90 and 30 days when that table has no row. list_expiries includes overdue rows by default.\n'
                '- Currency thresholds are HOURS for the four time metrics, because the app divides those values by 60, and counts for the other four. is_exceeded means the rule needs attention: for a requirement that is being below the threshold, for a limit it is reaching it. currency_status reproduces the app\'s currency page, which applies no owner filter and counts drafts as flights, so its numbers can mix owners on a synced logbook.\n'
                '- entity_totals.flights_complete counts COMPLETE flights, because it counts the rows its minutes come from; logbook_stats.flights counts every row including drafts, and its flights_complete is the same number. Aircraft and type group on flights.aircraft_id and crew groups on flights.crew_member_id, so a flight that only carries registration text is in the registration group alone. It pages with limit, offset, count, total and has_more like the flight lists, and the registration it reports for an aircraft is the app\'s display form (country code and tail joined, without doubling a tail that already carries the code).\n'
                '- get_settings reads one allowlisted single-row settings table at a time (aircraft_settings, app_settings, crew_settings, expiry_settings, flights_settings, general_settings, routes_settings, sidebar_settings) and returns {} when the app has never written that row, which means the app defaults apply; it never creates the row. aircraft_type_settings is keyed by type, not a singleton, and is not readable here.\n'
                '- Deleting a flight, aircraft, crew member or custom airport also records a sync tombstone when a Postgres sync provider has been used, so the deletion propagates.\n'
                '- A field means the same thing wherever it appears: create_flight and update_flight take the same flight fields with the same types and limits, the per-field notes are written once on create_flight, and what a field means is written here.\n'
                '- Use get_schema for table names and their column counts; pass table for one table\'s columns, and detail: "full" for its default and pk columns too.\n'
                '- Update tools accept expected_updated_at: the updated_at of the row as the caller read it. The write then applies only to an unchanged row, so a concurrent change from the app or another writer fails with a conflict that returns the current row, instead of being silently overwritten. Omitting it writes unconditionally, as before.\n'
                '- Every write tool accepts dry_run: true: it resolves, validates and answers exactly as the write would (the row as written, computed ids, warnings), marks the response dry_run: true, and commits nothing. A preview error is the write error, so a clean preview means the write will apply; an id a preview generated is not reserved, so pass your own or let the real call make one.\n'
                '- data_quality_report is one read-only call over every defect class an imported logbook can have: drafts, missing or mismatched splits, absurd totals, unlinked aircraft and crew, duplicate crew and flights, unparsable routes, future dates, dangling route links, simulator oddities, orphaned registration text. Each class carries a stable id, a count and a sample of up to 4 rows; a count is the finding, not the full list.\n'
                '- The repair tools merge_crew, link_flights_to_aircraft and link_flights_to_crew default to dry_run: true and say so on the response; pass dry_run: false to apply the same diff. They run in one transaction, stamp updated_at, tombstone deletions so sync propagates them, never create rows beyond the operation named, and never delete flights: duplicate flights are reported for a human to decide.\n'
                '- Planned times (scheduled_departure_utc, scheduled_arrival_utc, scheduled_block_minutes) come with Falcon-Logbook/app#231 and schema 20. The two instants are unix epoch seconds UTC and render as ISO-8601 with an explicit offset; the block is integer minutes. They exist only on a migrated database, so a write naming them on an older file is refused by name rather than silently dropped. A leg with planned times stays a draft: total_time empty, the block kept as the plan.\n'
                '- validate_flight_drafts and apply_flight_batch take a roster as flights, an array of objects using create_flight field names, up to 500 rows. Each row also accepts client_ref (an identity for retries) and aircraft_type (a hint, never stored). validate writes nothing and answers per row with ok, issues of {field, code, message, severity} and warnings; severity error is a row apply refuses. apply is atomic by default (one bad row writes nothing, applied: 0), allows partial with allow_partial: true, skips a duplicate or an already imported client_ref instead of overwriting, records one audit entry per batch with batch_id and the created ids, and previews with dry_run: true (its default). A roster leg is written as a draft through the same row builder as create_flight, so updated_at and sync behave the same.\n'
                '- A failed call returns {error, field, detail}: error is a stable code (unknown_field, invalid_value, not_found, conflict, constraint, busy, internal), field is the argument at fault, and unknown_field also names the tool. detail is one sentence, and the accepted list is capped at eight names plus a count. A conflict adds current, the row as it stands now.',
          ),
        ],
      );
    },
  );

  server.registerResource(
    'roster_import',
    'falcon://roster_import',
    (
      description:
          'How to turn a pasted roster into draft flights: the questions to '
              'ask, the plan to show, and the rules that keep a schedule out of the '
              'hours.',
      mimeType: 'text/plain'
    ),
    (uri, extra) async {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text: 'FALCON ROSTER IMPORT\n\n'
                'A roster is a schedule, not a logbook: it says what is planned, not what was flown. Read it yourself; this server cannot open a PDF, a spreadsheet or a screenshot and only ever sees the rows you send it. So this is protocol, validation and an atomic write, and every judgement about the file is yours.\n\n'
                'QUESTIONS: ASK, DO NOT ASSUME\n'
                'Ask only what you cannot read off the roster, in 3 to 5 grouped questions, never one field at a time, and never ask again anything the pilot has already answered. On a client that supports it, render them with ask_user (pickers and yes/no forms) and record each answer against its question id. The ten questions, grouped:\n'
                '1. Intent and basis. Confirm this is a roster or schedule to be drafted, not a flown logbook to be imported as complete. Are the times scheduled local, scheduled UTC, or actual block times? If local, airport-local or one base zone? Prefer UTC, and never infer a timezone from a city name.\n'
                '2. Times and aircraft. How should the times be stored? Recommended: planned times on the flight and total_time empty. Does the roster name a tail? If not, choose one of: a specific aircraft (offer list_aircraft), map by type, or leave the aircraft blank. Never infer a registration from a type that happens to match one aircraft. Are any legs FNPT/FFS sessions (is_simulator)?\n'
                '3. Crew and airports. Is the pilot pilotInCommand, copilot or student on these legs? A roster leg is not automatically pilotInCommand, and crew_role drives currency. For other crew: create missing people with add_crew, or store crew_members_name text only? Resolve every airport code with list_airports and show what matched; ask before adding a custom airport.\n'
                '4. Duplicates and order. For legs that already exist on that date and route: skip (the default), update, or create anyway? For several legs a day, order them by departure time ascending unless the pilot says otherwise.\n\n'
                'PLAN BEFORE WRITE\n'
                'Call validate_flight_drafts with the whole roster and the stated date_from/date_to. Then show a table of date, route, departure and arrival times, aircraft, crew role, and draft yes/no, with the row count and how many rows need attention, each with its code in one line. Change the plan until the pilot says yes explicitly. Only then call apply_flight_batch with dry_run: false.\n\n'
                'A SCHEDULE IS NOT A LOGBOOK\n'
                'Never write a scheduled time into total_time. A total makes the flight complete and adds hours the pilot never flew. A roster leg is a draft: total_time empty, the block kept as the plan. Planned times need the scheduled_departure_utc, scheduled_arrival_utc and scheduled_block_minutes columns, which come with Falcon-Logbook/app#231 (schema 20). Until this database has them, the tools say so and refuse a row that carries them: send the leg with no planned times and no total_time, and tell the pilot plainly that their app cannot store the planned times yet and where the times went.\n\n'
                'NEVER FABRICATE\n'
                'Never invent a registration, a tail, a timezone, a duration, a crew role, a crew member or an airport. Never guess which of several matching tails or crew a name means: ask, or pass the id. A blank field is honest; a filled-in guess is a wrong logbook.\n\n'
                'NEVER OVERWRITE\n'
                'Never overwrite an existing completed flight. A duplicate is skipped, not updated. Updating an existing draft is fine, with confirmation.\n\n'
                'REPORT EVERY ROW THAT DID NOT MAKE IT\n'
                'Silent partial success is the failure this flow exists to prevent. At the end, list every row that was skipped or failed, with its index, its client_ref if it had one, and the reason. Say how many landed, and name the batch_id.\n\n'
                'TOOLS AND CODES\n'
                'validate_flight_drafts writes nothing: flights (up to 500, create_flight field names), date_from, date_to, plus mode (roster by default; import checks a logbook file instead, see falcon://import) and units (the file\'s duration convention, used only in import mode). Every row answers ok, issues of {field, code, message, severity} and warnings; severity error means apply_flight_batch would refuse the row, warning means ask about it, info is stored as text. Codes: unknown_field, invalid_row, invalid_crew_role, invalid_flight_type, invalid_calc_time_mode, aircraft_not_found, crew_not_found, date_missing, date_out_of_range, date_order, aircraft_unmatched, aircraft_ambiguous, aircraft_missing, crew_unmatched, crew_ambiguous, route_unparsable, airport_unresolved, split_mismatch, duplicate_existing, duplicate_batch, scheduled_total_time, planned_times_unsupported.\n'
                'apply_flight_batch (write mode only) takes the same flights plus dry_run (default true: a preview with the same plan), allow_partial (default false: atomic) and batch_id. Per row it accepts client_ref, which makes a retry idempotent, and aircraft_type, a hint that is never stored. It returns batch_id, dry_run, applied, created ids, skipped and failed, each entry {index, reason}. A duplicate in the logbook or the batch is skipped, never overwritten.\n',
          ),
        ],
      );
    },
  );

  // The guided logbook import: the mapping contract, the questions that make
  // it safe, and the columns this build can actually write. The column table
  // is generated from the live database when the resource is read, so it can
  // never offer a column the write path would refuse.
  server.registerResource(
    'import',
    'falcon://import',
    (
      description:
          'Importing a logbook file: the questions to ask, the mapping to '
              'approve, and the flight columns this build can write.',
      mimeType: 'text/plain'
    ),
    (uri, extra) async {
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'text/plain',
            text: _importResourceText(db),
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
        'What this server can do for a pilot, grouped by task, and the rules it '
        'follows.',
    callback: (args, extra) async => _promptResult(
        _falconHelpText(tools: server.toolNames, readonly: readonly)),
  );

  // A vague first question is the moment the pilot decides whether this was
  // worth installing, so it gets the pilot's own numbers and three concrete next
  // steps rather than a menu.
  server.registerPrompt(
    'what_can_you_do',
    description: 'The pilot\'s own numbers, then three concrete next steps.',
    callback: (args, extra) async => _promptResult(
      'Call logbook_overview, then answer from the pilot\'s own numbers: '
      'flights, hours, what the recent window holds, the fleet and the last '
      'flight, in one or two sentences.\n'
      'Then offer exactly three concrete next steps, taken from the parts of '
      'attention that are not zero: drafts to finish, expiries due soon, a '
      'currency rule that needs attention, flights with no aircraft. Name '
      'the numbers behind each one.\n'
      'If the logbook is empty, or nothing in attention needs work, say so '
      'warmly and offer the three things that would fill it: import an old '
      'logbook, draft a roster, add a first flight.\n'
      'Do not list tools, and do not describe the server.',
    ),
  );

  // The periodic check a pilot does before a flight review, in one pass.
  server.registerPrompt(
    'logbook_review',
    description:
        'A guided periodic check: gaps, duplicates, expiries, currency.',
    callback: (args, extra) async => _promptResult(
      'Walk the pilot through a check of their logbook, in this order, one '
      'step at a time and with the count for each:\n'
      '1. find_missing_times: drafts and missing or odd day/night splits.\n'
      '2. dedupe_crew: the same crew member saved twice.\n'
      '3. data_quality_report: the rest of the defects, including flights '
      'with no aircraft linked.\n'
      '4. list_expiries: documents due or overdue.\n'
      '5. currency_status: the rules that need attention.\n'
      'Report each finding in one sentence with the number and the one or '
      'two rows that matter, then ask which to fix first. Never say a check '
      'passed without having called it, and never invent a row.',
    ),
  );

  // "Am I current?" answered from the pilot's own rules, not a generic one.
  server.registerPrompt(
    'currency_check',
    description:
        'The pilot\'s own currency rules, and what is short by how much.',
    callback: (args, extra) async => _promptResult(
      'Call currency_status and answer for each rule the pilot has '
      'configured: what it requires, the current value against the '
      'threshold, the window, and how much is short (remaining) or over '
      '(over_by).\n'
      'A metric with no rule is not a failure: say which ones have no rule '
      'rather than inventing a pass, and offer the raw total currency_status '
      'answers with metric and no rule.\n'
      'End with the rule that needs attention soonest, and by how much.',
    ),
  );

  // A pasted roster: the script lives in the resource, so the prompt is the
  // entry point and the resource is the contract.
  server.registerPrompt(
    'roster_import',
    description:
        'Turn a pasted roster into draft flights: ask, plan, then apply.',
    callback: (args, extra) async => _promptResult(
      'Read falcon://roster_import and follow it. Read the roster the pilot '
      'gave you, ask only the grouped questions whose answers are not on it '
      '(with ask_user where the client supports it), then call '
      'validate_flight_drafts and show the plan as a table with the row count '
      'and the rows needing attention.\n'
      'Get an explicit yes, then call apply_flight_batch with dry_run: false '
      'when writes are on. Write drafts only: never a scheduled time into '
      'total_time, never an invented tail, timezone, crew role or airport. '
      'Report every row that was skipped or failed, with its reason.',
    ),
  );

  // A logbook file to import: the resource is the contract, this is the entry
  // point. The mapping and the dry run come before every write.
  server.registerPrompt(
    'logbook_import_guide',
    description:
        'Import a logbook file into flights: ask, map, preview, then apply.',
    callback: (args, extra) async => _promptResult(
      'Read falcon://import and follow it. Read the file the pilot gave you '
      '(the reading and the OCR are yours; the server only ever sees rows), '
      'ask the grouped questions with ask_user where the client supports it, '
      'and declare the duration units once for the whole file.\n'
      'Show the mapping as "source column -> Falcon column" plus THREE sample '
      'rows already rendered as Falcon rows, and get an explicit yes before '
      'anything is written. If the pilot skips the review, keep the dry run; '
      'never blind-import.\n'
      'Then call validate_flight_drafts with mode: "import" and the declared '
      'units, walk the pilot through every issue and warning, and call '
      'apply_flight_batch with dry_run: false only once the rows are '
      'confirmed.\n'
      'Report every row that did not land, with its index, client_ref and '
      'reason, and name the batch_id. A refused date or unit is reported, '
      'never guessed, and an unknown column is a question with real options, '
      'never a silent drop.',
    ),
  );

  await server.connect(StdioServerTransport());
}
