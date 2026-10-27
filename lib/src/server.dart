import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'config.dart';
import 'db.dart';
import 'util.dart';

// ============================================================
// Field metadata
// ============================================================

enum _Kind { text, integer, real, boolean, date }

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
      min: 0, note: 'Minutes. Leave null to keep the flight a draft.'),
  _Column('day_time', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('night_time', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('calc_time_mode', _Kind.text,
      note: "'utc', 'local', 'time' or 'hobbsTacho'."),
  _Column('time_start', _Kind.text,
      note: 'Block-off clock time as entered, HH:MM.'),
  _Column('time_stop', _Kind.text,
      note: 'Block-on clock time as entered, HH:MM.'),
  _Column('hobbs_start', _Kind.real, min: 0),
  _Column('hobbs_stop', _Kind.real, min: 0),
  _Column('actual_instrument', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('simulated_instrument', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('ground_instrument', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('icus_day_time', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('icus_night_time', _Kind.integer, min: 0, note: 'Minutes.'),
  _Column('approaches2d', _Kind.text),
  _Column('approaches3d', _Kind.text),
  _Column('approach_details', _Kind.text),
  _Column('takeoffs', _Kind.integer, min: 0),
  _Column('landings', _Kind.integer, min: 0),
  _Column('takeoff_day', _Kind.integer, min: 0),
  _Column('takeoff_night', _Kind.integer, min: 0),
  _Column('landing_day', _Kind.integer, min: 0),
  _Column('landing_night', _Kind.integer, min: 0),
  _Column('water_takeoffs', _Kind.integer, min: 0),
  _Column('water_landings', _Kind.integer, min: 0),
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

TextContent _jsonContent(Object? value) =>
    TextContent(text: const JsonEncoder.withIndent('  ').convert(value));

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
      if (value == null) throw _ToolError('${column.name} must be an integer');
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
  }
}

void _checkRange(_Column column, num value) {
  if (column.min != null && value < column.min!) {
    throw _ToolError('${column.name} must be >= ${column.min}');
  }
  if (column.max != null && value > column.max!) {
    throw _ToolError('${column.name} must be <= ${column.max}');
  }
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

/// Runs a write callback, auditing the outcome and converting validation
/// failures into tool errors instead of crashes.
CallToolResult _runWrite(
  _Auditor auditor,
  String tool,
  Map<String, dynamic> args,
  Object? Function() body,
) {
  try {
    final result = body();
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

/// Builds the column/value map for a flight from tool arguments, deriving the
/// aircraft and crew foreign keys the app expects.
({Map<String, Object?> values, List<String> warnings}) _flightValues(
  FalconDb db,
  Map<String, dynamic> args,
) {
  final values = <String, Object?>{};
  final warnings = <String>[];
  _rejectUnknown(args, _fieldNames(_flightColumns, {'id'}));
  if (args.containsKey('date') && asText(args['date']) == null) {
    throw _ToolError('date cannot be empty');
  }
  final columns = <String>[];
  final raw = <Object?>[];
  _collect(db, 'flights', _flightColumns, args, columns, raw, keepNulls: true);
  for (var i = 0; i < columns.length; i++) {
    values[columns[i]] = raw[i];
  }

  if (args.containsKey('aircraft_registration')) {
    final text = asText(args['aircraft_registration']);
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
  } else if (args.containsKey('aircraft_id')) {
    final aircraftId = asText(args['aircraft_id']);
    if (aircraftId != null &&
        db.query(
            'SELECT id FROM aircraft WHERE id = ?', [aircraftId]).isEmpty) {
      throw _ToolError('Aircraft not found: $aircraftId');
    }
    values['aircraft_id'] = aircraftId;
  }

  if (args.containsKey('crew_members_name')) {
    final name = asText(args['crew_members_name']);
    if (name == null) {
      values['crew_members_name'] = null;
      values['crew_member_id'] = null;
    } else {
      values['crew_members_name'] = name;
      values['crew_member_id'] = _matchCrewMemberId(db, name);
    }
  } else if (args.containsKey('crew_member_id')) {
    final crewId = asText(args['crew_member_id']);
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

String _newId(String prefix) =>
    'mcp_${prefix}_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

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
    callback: (args, extra) async => _ok({
      'path': dbPath,
      'schemaVersion': version,
      'supportedSchemaVersions': '$minSchemaVersion-$maxSchemaVersion',
      'readonly': readonly,
      'tables': db.tables,
    }),
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
        final only = asText(args['table']);
        if (only != null && !db.hasTable(only)) {
          return _fail(
              'Unknown table: $only. Known tables: ${db.tables.join(', ')}');
        }
        final tables = only != null ? [only] : db.tables;
        return _ok({for (final table in tables) table: describeTable(table)});
      } catch (error) {
        return _fail('get_schema failed: $error');
      }
    },
  );

  server.registerTool(
    'list_flights',
    description:
        'List flights with optional filters (date range, aircraft registration, flight type).',
    inputSchema: JsonSchema.object(properties: {
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
      'offset': JsonSchema.integer(minimum: 0),
      'date_from': JsonSchema.string(format: 'date'),
      'date_to': JsonSchema.string(format: 'date'),
      'aircraft_registration': JsonSchema.string(),
      'flight_type': JsonSchema.string(),
      'crew_members_name': JsonSchema.string(),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final limit = asInt(args['limit']) ?? 50;
        if (limit < 1) return _fail('limit must be >= 1');
        final offset = asInt(args['offset']) ?? 0;
        if (offset < 0) return _fail('offset must be >= 0');
        final where = <String>[];
        final params = <Object?>[];
        final from = dateToEpoch(args['date_from']);
        if (from != null) {
          where.add('date >= ?');
          params.add(from);
        }
        final to = dateToEpoch(args['date_to'], endOfDay: true);
        if (to != null) {
          where.add('date <= ?');
          params.add(to);
        }
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
        final sql = 'SELECT * FROM flights'
            '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
            ' ORDER BY date DESC, day_order ASC LIMIT ? OFFSET ?';
        params.addAll([limit, offset]);
        final rows = db.query(sql, params);
        return _ok({'count': rows.length, 'flights': rows});
      } catch (error) {
        return _fail('list_flights failed: $error');
      }
    },
  );

  server.registerTool(
    'get_flight',
    description: 'Get a single flight by id.',
    inputSchema: JsonSchema.object(
        properties: {'id': JsonSchema.string()}, required: ['id']),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final id = asText(args['id']);
        if (id == null) return _fail('Missing or invalid id');
        final rows = db.query('SELECT * FROM flights WHERE id = ?', [id]);
        if (rows.isEmpty) return _fail('Flight not found: $id');
        return _ok(rows.first);
      } catch (error) {
        return _fail('get_flight failed: $error');
      }
    },
  );

  server.registerTool(
    'search_flights',
    description:
        'Search flights by free text (route, flight number, crew name, registration).',
    inputSchema: JsonSchema.object(properties: {
      'query': JsonSchema.string(),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }, required: [
      'query'
    ]),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final text = asText(args['query']);
        if (text == null) return _fail('Missing or invalid query');
        final limit = asInt(args['limit']) ?? 50;
        final like = '%${escapeLike(text)}%';
        final rows = db.query(
          "SELECT * FROM flights WHERE route LIKE ? ESCAPE '\\' OR flight_number LIKE ? ESCAPE '\\' "
          "OR crew_members_name LIKE ? ESCAPE '\\' OR aircraft_registration LIKE ? ESCAPE '\\' "
          'ORDER BY date DESC LIMIT ?',
          [like, like, like, like, limit],
        );
        return _ok({'count': rows.length, 'flights': rows});
      } catch (error) {
        return _fail('search_flights failed: $error');
      }
    },
  );

  server.registerTool(
    'list_aircraft',
    description: 'List aircraft (optionally include archived).',
    inputSchema: JsonSchema.object(properties: {
      'include_archived': JsonSchema.boolean(),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final include = asBool(args['include_archived']) ?? false;
        final limit = asInt(args['limit']) ?? 200;
        final sql = include
            ? 'SELECT * FROM aircraft ORDER BY registration LIMIT ?'
            : 'SELECT * FROM aircraft WHERE archived = 0 ORDER BY registration LIMIT ?';
        final rows = db.query(sql, [limit]);
        return _ok({'count': rows.length, 'aircraft': rows});
      } catch (error) {
        return _fail('list_aircraft failed: $error');
      }
    },
  );

  server.registerTool(
    'get_aircraft',
    description: 'Get aircraft by id.',
    inputSchema: JsonSchema.object(
        properties: {'id': JsonSchema.string()}, required: ['id']),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final id = asText(args['id']);
        if (id == null) return _fail('Missing or invalid id');
        final rows = db.query('SELECT * FROM aircraft WHERE id = ?', [id]);
        if (rows.isEmpty) return _fail('Aircraft not found: $id');
        return _ok(rows.first);
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
      } catch (error) {
        return _fail('list_airports failed: $error');
      }
    },
  );

  server.registerTool(
    'list_custom_airports',
    description: 'List user-defined custom airports.',
    inputSchema: JsonSchema.object(properties: {
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final limit = asInt(args['limit']) ?? 200;
        final rows = db.query(
            'SELECT * FROM custom_airports ORDER BY name LIMIT ?', [limit]);
        return _ok({'count': rows.length, 'airports': rows});
      } catch (error) {
        return _fail('list_custom_airports failed: $error');
      }
    },
  );

  server.registerTool(
    'list_crew',
    description: 'List crew members (optionally include archived).',
    inputSchema: JsonSchema.object(properties: {
      'include_archived': JsonSchema.boolean(),
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final include = asBool(args['include_archived']) ?? false;
        final limit = asInt(args['limit']) ?? 200;
        final sql = include
            ? 'SELECT * FROM crew_members ORDER BY name LIMIT ?'
            : 'SELECT * FROM crew_members WHERE archived = 0 ORDER BY name LIMIT ?';
        final rows = db.query(sql, [limit]);
        return _ok({'count': rows.length, 'crew': rows});
      } catch (error) {
        return _fail('list_crew failed: $error');
      }
    },
  );

  server.registerTool(
    'list_saved_routes',
    description: 'List saved routes.',
    inputSchema: JsonSchema.object(properties: {
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final limit = asInt(args['limit']) ?? 200;
        final rows = db.query(
            'SELECT * FROM saved_routes ORDER BY flight_number LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'routes': rows});
      } catch (error) {
        return _fail('list_saved_routes failed: $error');
      }
    },
  );

  server.registerTool(
    'logbook_stats',
    description:
        'Aggregate logbook statistics (flight count, drafts, total/night/day minutes, landings, takeoffs).',
    inputSchema: JsonSchema.object(properties: {
      'date_from': JsonSchema.string(format: 'date'),
      'date_to': JsonSchema.string(format: 'date'),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final where = <String>[];
        final params = <Object?>[];
        final from = dateToEpoch(args['date_from']);
        if (from != null) {
          where.add('date >= ?');
          params.add(from);
        }
        final to = dateToEpoch(args['date_to'], endOfDay: true);
        if (to != null) {
          where.add('date <= ?');
          params.add(to);
        }
        final sql = 'SELECT COUNT(*) AS flights, '
            'COALESCE(SUM(CASE WHEN total_time IS NULL THEN 1 ELSE 0 END), 0) AS drafts, '
            'COALESCE(SUM(total_time), 0) AS total_minutes, '
            'COALESCE(SUM(night_time), 0) AS night_minutes, '
            'COALESCE(SUM(day_time), 0) AS day_minutes, '
            'COALESCE(SUM(landings), 0) AS landings, '
            'COALESCE(SUM(takeoffs), 0) AS takeoffs '
            'FROM flights${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}';
        final rows = db.query(sql, params);
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
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
        final rows = db.query('SELECT * FROM flights_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
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
        final rows = db.query('SELECT * FROM app_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
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
        final rows = db.query('SELECT * FROM general_settings LIMIT 1');
        return _ok(rows.isEmpty ? <String, dynamic>{} : rows.first);
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
        final limit = asInt(args['limit']) ?? 50;
        final rows = db.query(
            'SELECT * FROM log_entries ORDER BY timestamp DESC, id DESC LIMIT ?',
            [limit]);
        return _ok({'count': rows.length, 'logs': rows});
      } catch (error) {
        return _fail('get_recent_logs failed: $error');
      }
    },
  );

  server.registerTool(
    'find_missing_times',
    description:
        'Find flights with no total time (drafts) or no day/night split.',
    inputSchema: JsonSchema.object(properties: {
      'limit': JsonSchema.integer(minimum: 1, maximum: 1000),
    }),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final limit = asInt(args['limit']) ?? 200;
        final rows = db.query(
          'SELECT * FROM flights '
          'WHERE total_time IS NULL OR (day_time IS NULL AND night_time IS NULL) '
          'ORDER BY date DESC LIMIT ?',
          [limit],
        );
        return _ok({'count': rows.length, 'flights': rows});
      } catch (error) {
        return _fail('find_missing_times failed: $error');
      }
    },
  );

  server.registerTool(
    'dedupe_crew',
    description: 'Find crew members with duplicate normalized names.',
    inputSchema: JsonSchema.object(properties: {}),
    annotations: readOnlyAnnotations,
    callback: (args, extra) async {
      try {
        final rows = db.query('SELECT * FROM crew_members');
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
          'Create a flight. Sets aircraft_id and crew_member_id automatically when the registration or crew name matches.',
      inputSchema: JsonSchema.object(
        properties: _propertiesOf(_supported(db, 'flights', _flightColumns)),
        required: ['date'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(auditor, 'create_flight', args, () {
        if (asText(args['date']) == null) throw _ToolError('date is required');
        final flight = _flightValues(db, args);
        final id = _newId('fl');
        final fields = <String, Object?>{'id': id, ...flight.values};
        db.execute(
          'INSERT INTO flights (${fields.keys.join(', ')}) VALUES (${List.filled(fields.length, '?').join(', ')})',
          fields.values.toList(),
        );
        return {
          'status': 'created',
          'id': id,
          if (flight.warnings.isNotEmpty) 'warnings': flight.warnings,
        };
      }),
    );

    server.registerTool(
      'update_flight',
      description:
          'Update a flight by id. Only the fields provided are changed.',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._propertiesOf(_supported(db, 'flights', _flightColumns)),
        },
        required: ['id'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(auditor, 'update_flight', args, () {
        final id = asText(args['id']);
        if (id == null) throw _ToolError('Missing or invalid id');
        if (db.query('SELECT id FROM flights WHERE id = ?', [id]).isEmpty) {
          throw _ToolError('Flight not found: $id');
        }
        final flight = _flightValues(db, args);
        if (flight.values.isEmpty) throw _ToolError('No fields to update');
        final assignments = [
          for (final column in flight.values.keys) '$column = ?'
        ];
        final values = <Object?>[
          ...flight.values.values,
          nowEpochSeconds(),
          id
        ];
        db.execute(
          'UPDATE flights SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
          values,
        );
        return {
          'status': 'updated',
          'id': id,
          if (flight.warnings.isNotEmpty) 'warnings': flight.warnings,
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
          _runWrite(auditor, 'delete_flight', args, () {
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
        properties: _propertiesOf(_supported(db, 'aircraft', _aircraftColumns)),
        required: ['type', 'registration'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(auditor, 'add_aircraft', args, () {
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
        final id = _newId('ac');
        _insert(
          db,
          'aircraft',
          {
            'id': id,
            'type': type,
            'country_code': countryCode,
            'registration': bare
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
          _runWrite(auditor, 'update_aircraft', args, () {
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
          _runWrite(auditor, 'delete_aircraft', args, () {
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
        properties: _propertiesOf(_supported(db, 'crew_members', _crewColumns)),
        required: ['first_name', 'last_name'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async => _runWrite(auditor, 'add_crew', args, () {
        _rejectUnknown(args, _fieldNames(_crewColumns, {'id'}));
        final firstName = asText(args['first_name']);
        final lastName = asText(args['last_name']);
        if (firstName == null) throw _ToolError('first_name is required');
        if (lastName == null) throw _ToolError('last_name is required');
        final name = asText(args['name']) ?? '$firstName $lastName';
        final id = _newId('cr');
        _insert(
          db,
          'crew_members',
          {
            'id': id,
            'name': name,
            'first_name': firstName,
            'last_name': lastName
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
          _runWrite(auditor, 'update_crew', args, () {
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
          _runWrite(auditor, 'delete_crew', args, () {
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
        properties: _propertiesOf(
            _supported(db, 'custom_airports', _customAirportColumns)),
        required: ['name'],
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(auditor, 'add_custom_airport', args, () {
        _rejectUnknown(args, _fieldNames(_customAirportColumns, {'id'}));
        final name = asText(args['name']);
        if (name == null) throw _ToolError('name is required');
        final id = _newId('ap');
        _insert(db, 'custom_airports', {'id': id, 'name': name},
            _customAirportColumns, args);
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
          _runWrite(auditor, 'update_custom_airport', args, () {
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
          _runWrite(auditor, 'delete_custom_airport', args, () {
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
          _runWrite(auditor, 'add_saved_route', args, () {
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
          _runWrite(auditor, 'update_saved_route', args, () {
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
          _runWrite(auditor, 'delete_saved_route', args, () {
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
          'Update flight settings (pilot name, formats, country, display toggles).',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          ..._propertiesOf(
              _supported(db, 'flights_settings', _flightSettingsColumns))
        },
      ),
      annotations: const ToolAnnotations(
          readOnlyHint: false, destructiveHint: false, openWorldHint: false),
      callback: (args, extra) async =>
          _runWrite(auditor, 'update_flight_settings', args, () {
        _rejectUnknown(args, _fieldNames(_flightSettingsColumns, {'id'}));
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
        final requested = asText(args['id']);
        final id = requested ??
            (existing.isEmpty
                ? 'default'
                : asText(existing.first['id']) ?? 'default');
        final assignments = [for (final column in columns) '$column = ?'];
        db.transaction(() {
          if (db.query(
              'SELECT id FROM flights_settings WHERE id = ?', [id]).isEmpty) {
            db.execute('INSERT INTO flights_settings (id) VALUES (?)', [id]);
          }
          db.execute(
            'UPDATE flights_settings SET ${assignments.join(', ')}, updated_at = ? WHERE id = ?',
            [...values, nowEpochSeconds(), id],
          );
        });
        return {'status': 'updated', 'id': id};
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
      description: 'The 100 most recent flights as JSON.',
      mimeType: 'application/json',
    ),
    (uri, extra) async {
      final rows = db.query(
          'SELECT * FROM flights ORDER BY date DESC, day_order ASC LIMIT 100');
      return ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri.toString(),
            mimeType: 'application/json',
            text: const JsonEncoder.withIndent('  ').convert(rows),
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
                '- Dates and timestamps are unix epoch seconds. The flights.date column holds local midnight of the flight date; tool inputs accept YYYY-MM-DD and are converted the same way.\n'
                '- Flight time columns (total_time, day_time, night_time, actual_instrument, simulated_instrument, icus_day_time, icus_night_time) are integer MINUTES.\n'
                '- time_start and time_stop are the raw HH:MM clock entries from the calculate-time dialog, paired with calc_time_mode (utc, local, time, hobbsTacho) and hobbs_start/hobbs_stop when that mode was used. They are not stored as durations.\n'
                '- A flight is displayed as a DRAFT by the app when total_time IS NULL. Set total_time to make it complete.\n'
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
            text: const JsonEncoder.withIndent('  ').convert(out),
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
