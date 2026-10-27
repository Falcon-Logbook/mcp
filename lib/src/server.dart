import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'db.dart';

/// Convert a date-only string (YYYY-MM-DD) to unix seconds (UTC midnight).
/// Returns null if unparseable.
int? _dateToEpoch(String? s, {bool endOfDay = false}) {
  if (s == null || s.trim().isEmpty) return null;
  try {
    final d = DateTime.parse(s.trim()).toUtc();
    final base = DateTime.utc(d.year, d.month, d.day);
    if (endOfDay) {
      return base.add(const Duration(days: 1)).subtract(const Duration(seconds: 1)).millisecondsSinceEpoch ~/ 1000;
    }
    return base.millisecondsSinceEpoch ~/ 1000;
  } catch (_) {
    return null;
  }
}

Future<void> runServer(String dbPath) async {
  final db = openDb(dbPath);

  final sv = db.schemaVersion;
  const expected = 18;
  if (sv != expected) {
    throw StateError('Falcon DB schema version mismatch: found $sv, expected $expected.');
  }

  final server = McpServer(
    const Implementation(name: 'falcon_mcp', version: '0.1.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(
        resources: ServerCapabilitiesResources(),
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  TextContent jsonContent(Object value) =>
      TextContent(text: const JsonEncoder.withIndent('  ').convert(value));

  CallToolResult ok(Object value) =>
      CallToolResult.fromContent([jsonContent(value)]);

  CallToolResult fail(String msg) =>
      CallToolResult(content: [TextContent(text: msg)], isError: true);

  // --- db_info ---
  server.registerTool(
    'db_info',
    description: 'Show database path, schema version, and table list.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      return ok({'path': dbPath, 'schemaVersion': sv, 'tables': db.tables});
    },
  );

  // --- list_flights ---
  server.registerTool(
    'list_flights',
    description: 'List flights with optional filters (date range, aircraft registration, flight type).',
    inputSchema: JsonSchema.object(
      properties: {
        'limit': JsonSchema.integer(),
        'offset': JsonSchema.integer(),
        'date_from': JsonSchema.string(),
        'date_to': JsonSchema.string(),
        'aircraft_registration': JsonSchema.string(),
        'flight_type': JsonSchema.string(),
      },
    ),
    callback: (args, extra) async {
      try {
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final offset = (args['offset'] as num?)?.toInt() ?? 0;
        final where = <String>[];
        final params = <Object?>[];
        final fromEpoch = _dateToEpoch(args['date_from'] as String?);
        if (fromEpoch != null) {
          where.add('date >= ?');
          params.add(fromEpoch);
        }
        final toEpoch = _dateToEpoch(args['date_to'] as String?, endOfDay: true);
        if (toEpoch != null) {
          where.add('date <= ?');
          params.add(toEpoch);
        }
        final ar = args['aircraft_registration'];
        if (ar is String && ar.isNotEmpty) {
          where.add('aircraft_registration = ?');
          params.add(ar);
        }
        final ft = args['flight_type'];
        if (ft is String && ft.isNotEmpty) {
          where.add('flight_type = ?');
          params.add(ft);
        }
        final sql = 'SELECT * FROM flights'
            '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
            ' ORDER BY date DESC, day_order ASC LIMIT ? OFFSET ?';
        params.addAll([limit, offset]);
        final rows = db.query(sql, params);
        return ok({'count': rows.length, 'flights': rows});
      } catch (e) {
        return fail('list_flights failed: $e');
      }
    },
  );

  // --- get_flight ---
  server.registerTool(
    'get_flight',
    description: 'Get a single flight by id.',
    inputSchema: JsonSchema.object(
      properties: {'id': JsonSchema.string()},
      required: ['id'],
    ),
    callback: (args, extra) async {
      try {
        final id = args['id'];
        if (id is! String || id.isEmpty) return fail('Missing or invalid id');
        final rows = db.query('SELECT * FROM flights WHERE id = ?', [id]);
        if (rows.isEmpty) return fail('Flight not found: $id');
        return ok(rows.first);
      } catch (e) {
        return fail('get_flight failed: $e');
      }
    },
  );

  // --- search_flights ---
  server.registerTool(
    'search_flights',
    description: 'Search flights by free text (route, flight number, crew name, registration).',
    inputSchema: JsonSchema.object(
      properties: {
        'query': JsonSchema.string(),
        'limit': JsonSchema.integer(),
      },
      required: ['query'],
    ),
    callback: (args, extra) async {
      try {
        final q = args['query'];
        if (q is! String || q.isEmpty) return fail('Missing or invalid query');
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final like = '%$q%';
        final rows = db.query(
          'SELECT * FROM flights WHERE route LIKE ? OR flight_number LIKE ? OR crew_members_name LIKE ? OR aircraft_registration LIKE ? ORDER BY date DESC LIMIT ?',
          [like, like, like, like, limit],
        );
        return ok({'count': rows.length, 'flights': rows});
      } catch (e) {
        return fail('search_flights failed: $e');
      }
    },
  );

  // --- list_aircraft ---
  server.registerTool(
    'list_aircraft',
    description: 'List aircraft (optionally include archived).',
    inputSchema: JsonSchema.object(
      properties: {
        'include_archived': JsonSchema.boolean(),
        'limit': JsonSchema.integer(),
      },
    ),
    callback: (args, extra) async {
      try {
        final include = args['include_archived'] == true;
        final limit = (args['limit'] as num?)?.toInt() ?? 200;
        final sql = include
            ? 'SELECT * FROM aircraft ORDER BY registration LIMIT ?'
            : 'SELECT * FROM aircraft WHERE archived = 0 ORDER BY registration LIMIT ?';
        final rows = db.query(sql, [limit]);
        return ok({'count': rows.length, 'aircraft': rows});
      } catch (e) {
        return fail('list_aircraft failed: $e');
      }
    },
  );

  // --- get_aircraft ---
  server.registerTool(
    'get_aircraft',
    description: 'Get aircraft by id.',
    inputSchema: JsonSchema.object(
      properties: {'id': JsonSchema.string()},
      required: ['id'],
    ),
    callback: (args, extra) async {
      try {
        final id = args['id'];
        if (id is! String || id.isEmpty) return fail('Missing or invalid id');
        final rows = db.query('SELECT * FROM aircraft WHERE id = ?', [id]);
        if (rows.isEmpty) return fail('Aircraft not found: $id');
        return ok(rows.first);
      } catch (e) {
        return fail('get_aircraft failed: $e');
      }
    },
  );

  // --- list_airports ---
  server.registerTool(
    'list_airports',
    description: 'Search airports (built-in) by ICAO/IATA/name/city.',
    inputSchema: JsonSchema.object(
      properties: {
        'query': JsonSchema.string(),
        'limit': JsonSchema.integer(),
      },
    ),
    callback: (args, extra) async {
      try {
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final q = args['query'];
        if (q is String && q.isNotEmpty) {
          final like = '%$q%';
          final rows = db.query(
            'SELECT * FROM airports WHERE icao LIKE ? OR iata LIKE ? OR name LIKE ? OR city LIKE ? LIMIT ?',
            [like, like, like, like, limit],
          );
          return ok({'count': rows.length, 'airports': rows});
        }
        final rows = db.query('SELECT * FROM airports LIMIT ?', [limit]);
        return ok({'count': rows.length, 'airports': rows});
      } catch (e) {
        return fail('list_airports failed: $e');
      }
    },
  );

  // --- list_custom_airports ---
  server.registerTool(
    'list_custom_airports',
    description: 'List user-defined custom airports.',
    inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
    callback: (args, extra) async {
      try {
        final limit = (args['limit'] as num?)?.toInt() ?? 200;
        final rows = db.query('SELECT * FROM custom_airports LIMIT ?', [limit]);
        return ok({'count': rows.length, 'airports': rows});
      } catch (e) {
        return fail('list_custom_airports failed: $e');
      }
    },
  );

  // --- list_crew ---
  server.registerTool(
    'list_crew',
    description: 'List crew members (optionally include archived).',
    inputSchema: JsonSchema.object(
      properties: {
        'include_archived': JsonSchema.boolean(),
        'limit': JsonSchema.integer(),
      },
    ),
    callback: (args, extra) async {
      try {
        final include = args['include_archived'] == true;
        final limit = (args['limit'] as num?)?.toInt() ?? 200;
        final sql = include
            ? 'SELECT * FROM crew_members ORDER BY name LIMIT ?'
            : 'SELECT * FROM crew_members WHERE archived = 0 ORDER BY name LIMIT ?';
        final rows = db.query(sql, [limit]);
        return ok({'count': rows.length, 'crew': rows});
      } catch (e) {
        return fail('list_crew failed: $e');
      }
    },
  );

  // --- list_saved_routes ---
  server.registerTool(
    'list_saved_routes',
    description: 'List saved routes.',
    inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
    callback: (args, extra) async {
      try {
        final limit = (args['limit'] as num?)?.toInt() ?? 200;
        final rows = db.query('SELECT * FROM saved_routes LIMIT ?', [limit]);
        return ok({'count': rows.length, 'routes': rows});
      } catch (e) {
        return fail('list_saved_routes failed: $e');
      }
    },
  );

  // --- logbook_stats ---
  server.registerTool(
    'logbook_stats',
    description: 'Aggregate logbook statistics (flight count, total/night minutes, landings, takeoffs).',
    inputSchema: JsonSchema.object(
      properties: {
        'date_from': JsonSchema.string(),
        'date_to': JsonSchema.string(),
      },
    ),
    callback: (args, extra) async {
      try {
        final where = <String>[];
        final params = <Object?>[];
        final fromEpoch = _dateToEpoch(args['date_from'] as String?);
        if (fromEpoch != null) {
          where.add('date >= ?');
          params.add(fromEpoch);
        }
        final toEpoch = _dateToEpoch(args['date_to'] as String?, endOfDay: true);
        if (toEpoch != null) {
          where.add('date <= ?');
          params.add(toEpoch);
        }
        final sql = 'SELECT COUNT(*) AS flights, '
            'COALESCE(SUM(total_time),0) AS total_minutes, '
            'COALESCE(SUM(night_time),0) AS night_minutes, '
            'COALESCE(SUM(day_time),0) AS day_minutes, '
            'COALESCE(SUM(landings),0) AS landings, '
            'COALESCE(SUM(takeoffs),0) AS takeoffs '
            'FROM flights${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}';
        final rows = db.query(sql, params);
        return ok(rows.isEmpty ? {} : rows.first);
      } catch (e) {
        return fail('logbook_stats failed: $e');
      }
    },
  );

  // --- settings ---
  server.registerTool(
    'get_flight_settings',
    description: 'Get flight settings (pilot name, formats, country, etc.).',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      try {
        final rows = db.query('SELECT * FROM flights_settings LIMIT 1');
        return ok(rows.isEmpty ? {} : rows.first);
      } catch (e) {
        return fail('get_flight_settings failed: $e');
      }
    },
  );

  server.registerTool(
    'get_app_settings',
    description: 'Get app settings (storage mode, theme, accent, etc.).',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      try {
        final rows = db.query('SELECT * FROM app_settings LIMIT 1');
        return ok(rows.isEmpty ? {} : rows.first);
      } catch (e) {
        return fail('get_app_settings failed: $e');
      }
    },
  );

  server.registerTool(
    'get_general_settings',
    description: 'Get general settings (startup tab, language, coordinates format, etc.).',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      try {
        final rows = db.query('SELECT * FROM general_settings LIMIT 1');
        return ok(rows.isEmpty ? {} : rows.first);
      } catch (e) {
        return fail('get_general_settings failed: $e');
      }
    },
  );

  // --- sync status ---
  server.registerTool(
    'get_sync_status',
    description: 'Get sync state per table/provider and pending tombstone count.',
    inputSchema: JsonSchema.object(properties: {}),
    callback: (args, extra) async {
      try {
        final state = db.query('SELECT * FROM sync_state');
        final deletions = db.query('SELECT COUNT(*) AS pending FROM sync_deletions');
        final pending = deletions.isEmpty ? 0 : deletions.first['pending'];
        return ok({'syncState': state, 'pendingDeletions': pending});
      } catch (e) {
        return fail('get_sync_status failed: $e');
      }
    },
  );

  // --- logs ---
  server.registerTool(
    'get_recent_logs',
    description: 'Read recent log entries for diagnostics.',
    inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
    callback: (args, extra) async {
      try {
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final rows = db.query(
          'SELECT * FROM log_entries ORDER BY timestamp DESC LIMIT ?',
          [limit],
        );
        return ok({'count': rows.length, 'logs': rows});
      } catch (e) {
        return fail('get_recent_logs failed: $e');
      }
    },
  );

  // --- resources ---
  server.registerResource(
    'flights',
    'falcon://flights',
    null,
    (uri, extra) async {
      final rows = db.query('SELECT * FROM flights ORDER BY date DESC LIMIT 100');
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

  await server.connect(StdioServerTransport());
}
