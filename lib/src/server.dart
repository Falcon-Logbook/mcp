import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'config.dart';
import 'db.dart';

Future<void> runServer(String dbPath) async {
  final db = openDb(dbPath);

  // Schema version gate.
  final sv = db.schemaVersion;
  if (sv != expectedSchemaVersion) {
    stderr.writeln(
      'Falcon DB schema version mismatch: found $sv, expected $expectedSchemaVersion. '
      'Refusing to run. Update the app or the server.',
    );
    db.close();
    exit(1);
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
        final df = args['date_from'];
        if (df is String && df.isNotEmpty) {
          where.add('date >= ?');
          params.add(df);
        }
        final dt = args['date_to'];
        if (dt is String && dt.isNotEmpty) {
          where.add('date <= ?');
          params.add(dt);
        }
        final ar = args['aircraft_registration'];
        if (ar is String && ar.isNotEmpty) {
          where.add('aircraftRegistration = ?');
          params.add(ar);
        }
        final ft = args['flight_type'];
        if (ft is String && ft.isNotEmpty) {
          where.add('flightType = ?');
          params.add(ft);
        }
        final sql = 'SELECT * FROM flights'
            '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
            ' ORDER BY date DESC, dayOrder ASC LIMIT ? OFFSET ?';
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
        final id = args['id'] as String;
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
    description: 'Search flights by free text (route, flight number, crew name).',
    inputSchema: JsonSchema.object(
      properties: {
        'query': JsonSchema.string(),
        'limit': JsonSchema.integer(),
      },
      required: ['query'],
    ),
    callback: (args, extra) async {
      try {
        final q = args['query'] as String;
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final like = '%$q%';
        final rows = db.query(
          'SELECT * FROM flights WHERE route LIKE ? OR flightNumber LIKE ? OR crewMembersName LIKE ? OR aircraftRegistration LIKE ? ORDER BY date DESC LIMIT ?',
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
        final id = args['id'] as String;
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
        final df = args['date_from'];
        if (df is String && df.isNotEmpty) {
          where.add('date >= ?');
          params.add(df);
        }
        final dt = args['date_to'];
        if (dt is String && dt.isNotEmpty) {
          where.add('date <= ?');
          params.add(dt);
        }
        final sql = 'SELECT COUNT(*) AS flights, '
            'COALESCE(SUM(totalTime),0) AS totalMinutes, '
            'COALESCE(SUM(nightTime),0) AS nightMinutes, '
            'COALESCE(SUM(dayTime),0) AS dayMinutes, '
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

  // --- get_settings ---
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

  // --- get_recent_logs ---
  server.registerTool(
    'get_recent_logs',
    description: 'Read recent log entries for diagnostics.',
    inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
    callback: (args, extra) async {
      try {
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final rows = db.query(
          'SELECT * FROM log_entries ORDER BY createdAt DESC LIMIT ?',
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
  // Keep process alive; stdin/stdout managed by transport.
}
