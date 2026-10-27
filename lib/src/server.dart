import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'config.dart';
import 'db.dart';

int? _dateToEpoch(String? s, {bool endOfDay = false}) {
  if (s == null || s.trim().isEmpty) return null;
  try {
    final d = DateTime.parse(s.trim());
    final base = DateTime(d.year, d.month, d.day);
    if (endOfDay) {
      return base.add(const Duration(days: 1)).subtract(const Duration(seconds: 1)).millisecondsSinceEpoch ~/ 1000;
    }
    return base.millisecondsSinceEpoch ~/ 1000;
  } catch (_) {
    return null;
  }
}

String _auditPath(String dbPath) {
  final idx = dbPath.lastIndexOf('.');
  final base = idx < 0 ? dbPath : dbPath.substring(0, idx);
  return '$base.mcp_audit.jsonl';
}

void _audit(String dbPath, String tool, Map<String, dynamic> args, String result, [String? detail]) {
  try {
    final f = File(_auditPath(dbPath));
    final entry = <String, dynamic>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'tool': tool,
      'args': args,
      'result': result,
    };
    if (detail != null) entry['detail'] = detail;
    f.writeAsStringSync('${jsonEncode(entry)}\n', mode: FileMode.append);
  } catch (_) {}
}

Future<void> runServer(String dbPath, {bool readonly = true}) async {
  final db = openDb(dbPath);

  final sv = db.schemaVersion;
  if (sv < minSchemaVersion || sv > maxSchemaVersion) {
    throw StateError('Falcon DB schema version mismatch: found $sv, supported $minSchemaVersion-$maxSchemaVersion.');
  }

  final server = McpServer(
    const Implementation(name: 'falcon_mcp', version: '0.3.0'),
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

  // ============================================================
  // READ TOOLS
  // ============================================================

  server.registerTool('db_info', description: 'Show database path, schema version, and table list.',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async => ok({'path': dbPath, 'schemaVersion': sv, 'tables': db.tables, 'readonly': readonly}));

  server.registerTool('list_flights',
      description: 'List flights with optional filters (date range, aircraft registration, flight type).',
      inputSchema: JsonSchema.object(properties: {
        'limit': JsonSchema.integer(),
        'offset': JsonSchema.integer(),
        'date_from': JsonSchema.string(),
        'date_to': JsonSchema.string(),
        'aircraft_registration': JsonSchema.string(),
        'flight_type': JsonSchema.string(),
      }),
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
      });

  server.registerTool('get_flight', description: 'Get a single flight by id.',
      inputSchema: JsonSchema.object(properties: {'id': JsonSchema.string()}, required: ['id']),
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
      });

  server.registerTool('search_flights',
      description: 'Search flights by free text (route, flight number, crew name, registration).',
      inputSchema: JsonSchema.object(properties: {'query': JsonSchema.string(), 'limit': JsonSchema.integer()}, required: ['query']),
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
      });

  server.registerTool('list_aircraft', description: 'List aircraft (optionally include archived).',
      inputSchema: JsonSchema.object(properties: {'include_archived': JsonSchema.boolean(), 'limit': JsonSchema.integer()}),
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
      });

  server.registerTool('get_aircraft', description: 'Get aircraft by id.',
      inputSchema: JsonSchema.object(properties: {'id': JsonSchema.string()}, required: ['id']),
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
      });

  server.registerTool('list_airports', description: 'Search airports (built-in) by ICAO/IATA/name/city.',
      inputSchema: JsonSchema.object(properties: {'query': JsonSchema.string(), 'limit': JsonSchema.integer()}),
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
      });

  server.registerTool('list_custom_airports', description: 'List user-defined custom airports.',
      inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
      callback: (args, extra) async {
        try {
          final limit = (args['limit'] as num?)?.toInt() ?? 200;
          final rows = db.query('SELECT * FROM custom_airports LIMIT ?', [limit]);
          return ok({'count': rows.length, 'airports': rows});
        } catch (e) {
          return fail('list_custom_airports failed: $e');
        }
      });

  server.registerTool('list_crew', description: 'List crew members (optionally include archived).',
      inputSchema: JsonSchema.object(properties: {'include_archived': JsonSchema.boolean(), 'limit': JsonSchema.integer()}),
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
      });

  server.registerTool('list_saved_routes', description: 'List saved routes.',
      inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
      callback: (args, extra) async {
        try {
          final limit = (args['limit'] as num?)?.toInt() ?? 200;
          final rows = db.query('SELECT * FROM saved_routes LIMIT ?', [limit]);
          return ok({'count': rows.length, 'routes': rows});
        } catch (e) {
          return fail('list_saved_routes failed: $e');
        }
      });

  server.registerTool('logbook_stats',
      description: 'Aggregate logbook statistics (flight count, total/night minutes, landings, takeoffs).',
      inputSchema: JsonSchema.object(properties: {'date_from': JsonSchema.string(), 'date_to': JsonSchema.string()}),
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
      });

  server.registerTool('get_flight_settings', description: 'Get flight settings (pilot name, formats, country, etc.).',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async {
        try {
          final rows = db.query('SELECT * FROM flights_settings LIMIT 1');
          return ok(rows.isEmpty ? {} : rows.first);
        } catch (e) {
          return fail('get_flight_settings failed: $e');
        }
      });

  server.registerTool('get_app_settings', description: 'Get app settings (storage mode, theme, accent, etc.).',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async {
        try {
          final rows = db.query('SELECT * FROM app_settings LIMIT 1');
          return ok(rows.isEmpty ? {} : rows.first);
        } catch (e) {
          return fail('get_app_settings failed: $e');
        }
      });

  server.registerTool('get_general_settings', description: 'Get general settings (startup tab, language, coordinates format, etc.).',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async {
        try {
          final rows = db.query('SELECT * FROM general_settings LIMIT 1');
          return ok(rows.isEmpty ? {} : rows.first);
        } catch (e) {
          return fail('get_general_settings failed: $e');
        }
      });

  server.registerTool('get_sync_status', description: 'Get sync state per table/provider and pending tombstone count.',
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
      });

  server.registerTool('get_recent_logs', description: 'Read recent log entries for diagnostics.',
      inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
      callback: (args, extra) async {
        try {
          final limit = (args['limit'] as num?)?.toInt() ?? 50;
          final rows = db.query('SELECT * FROM log_entries ORDER BY timestamp DESC LIMIT ?', [limit]);
          return ok({'count': rows.length, 'logs': rows});
        } catch (e) {
          return fail('get_recent_logs failed: $e');
        }
      });

  server.registerTool('find_missing_times',
      description: 'Find flights missing total time or block times.',
      inputSchema: JsonSchema.object(properties: {'limit': JsonSchema.integer()}),
      callback: (args, extra) async {
        try {
          final limit = (args['limit'] as num?)?.toInt() ?? 200;
          final rows = db.query(
            'SELECT * FROM flights WHERE total_time IS NULL OR block_off IS NULL OR block_on IS NULL ORDER BY date DESC LIMIT ?',
            [limit],
          );
          return ok({'count': rows.length, 'flights': rows});
        } catch (e) {
          return fail('find_missing_times failed: $e');
        }
      });

  server.registerTool('dedupe_crew',
      description: 'Find crew members with duplicate normalized names.',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async {
        try {
          final rows = db.query('SELECT * FROM crew_members');
          final groups = <String, List<Map<String, dynamic>>>{};
          for (final r in rows) {
            final key = (r['name'] as String? ?? '').trim().toLowerCase();
            groups.putIfAbsent(key, () => []).add(r);
          }
          final dupes = groups.entries.where((e) => e.value.length > 1).map((e) => {
                'name': e.key,
                'members': e.value,
              }).toList();
          return ok({'groups': dupes.length, 'duplicates': dupes});
        } catch (e) {
          return fail('dedupe_crew failed: $e');
        }
      });

  // ============================================================
  // WRITE TOOLS (confirm required) - only when not readonly
  // ============================================================
  if (!readonly) {

  // --- create_flight ---
  server.registerTool('create_flight',
      description: 'Create a flight. ',
      inputSchema: JsonSchema.object(properties: {
        'date': JsonSchema.string(),
        'aircraft_registration': JsonSchema.string(),
        'flight_type': JsonSchema.string(),
        'route': JsonSchema.string(),
        'flight_number': JsonSchema.string(),
        'crew_members_name': JsonSchema.string(),
        'total_time': JsonSchema.integer(),
        'day_time': JsonSchema.integer(),
        'night_time': JsonSchema.integer(),
        'block_off': JsonSchema.integer(),
        'block_on': JsonSchema.integer(),
        'block_on_next_day': JsonSchema.boolean(),
        'takeoffs': JsonSchema.integer(),
        'landings': JsonSchema.integer(),
        'actual_instrument': JsonSchema.integer(),
        'simulated_instrument': JsonSchema.integer(),
        'is_simulator': JsonSchema.boolean(),
        'is_ifr': JsonSchema.boolean(),
        'day_order': JsonSchema.integer(),
      }, required: ['date']),
      callback: (args, extra) async {
        try {
          final dateStr = args['date'] as String;
          final epoch = _dateToEpoch(dateStr);
          if (epoch == null) return fail('Invalid date: $dateStr');
          final id = 'mcp_${DateTime.now().millisecondsSinceEpoch}';
          final cols = <String>['id', 'date'];
          final vals = <Object?>[id, epoch];
          void add(String col, Object? v) {
            if (v != null) {
              cols.add(col);
              vals.add(v);
            }
          }

          add('aircraft_registration', args['aircraft_registration']);
          add('flight_type', args['flight_type']);
          add('route', args['route']);
          add('flight_number', args['flight_number']);
          add('crew_members_name', args['crew_members_name']);
          add('total_time', args['total_time']);
          add('day_time', args['day_time']);
          add('night_time', args['night_time']);
          add('block_off', args['block_off']);
          add('block_on', args['block_on']);
          if (args['block_on_next_day'] != null) {
            add('block_on_next_day', (args['block_on_next_day'] == true) ? 1 : 0);
          }
          add('takeoffs', args['takeoffs']);
          add('landings', args['landings']);
          add('actual_instrument', args['actual_instrument']);
          add('simulated_instrument', args['simulated_instrument']);
          if (args['is_simulator'] != null) {
            add('is_simulator', (args['is_simulator'] == true) ? 1 : 0);
          }
          if (args['is_ifr'] != null) {
            add('is_ifr', (args['is_ifr'] == true) ? 1 : 0);
          }
          add('day_order', args['day_order']);
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          cols.add('created_at');
          vals.add(nowSec);


          final placeholders = List.filled(cols.length, '?').join(',');
          db.execute('INSERT INTO flights (${cols.join(',')}) VALUES ($placeholders)', vals);
          _audit(dbPath, 'create_flight', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'created', 'id': id});
        } catch (e) {
          _audit(dbPath, 'create_flight', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('create_flight failed: $e');
        }
      });

  // --- update_flight ---
  server.registerTool('update_flight',
      description: 'Update a flight by id. ',
      inputSchema: JsonSchema.object(properties: {
        'id': JsonSchema.string(),
        'date': JsonSchema.string(),
        'aircraft_registration': JsonSchema.string(),
        'flight_type': JsonSchema.string(),
        'route': JsonSchema.string(),
        'flight_number': JsonSchema.string(),
        'crew_members_name': JsonSchema.string(),
        'total_time': JsonSchema.integer(),
        'day_time': JsonSchema.integer(),
        'night_time': JsonSchema.integer(),
        'block_off': JsonSchema.integer(),
        'block_on': JsonSchema.integer(),
        'block_on_next_day': JsonSchema.boolean(),
        'takeoffs': JsonSchema.integer(),
        'landings': JsonSchema.integer(),
        'actual_instrument': JsonSchema.integer(),
        'simulated_instrument': JsonSchema.integer(),
        'is_simulator': JsonSchema.boolean(),
        'is_ifr': JsonSchema.boolean(),
        'day_order': JsonSchema.integer(),
      }, required: ['id']),
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM flights WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Flight not found: $id');

          final sets = <String>[];
          final vals = <Object?>[];
          void setCol(String col, Object? v) {
            sets.add('$col = ?');
            vals.add(v);
          }

          if (args['date'] != null) {
            final epoch = _dateToEpoch(args['date'] as String);
            if (epoch == null) return fail('Invalid date');
            setCol('date', epoch);
          }
          if (args.containsKey('aircraft_registration')) setCol('aircraft_registration', args['aircraft_registration']);
          if (args.containsKey('flight_type')) setCol('flight_type', args['flight_type']);
          if (args.containsKey('route')) setCol('route', args['route']);
          if (args.containsKey('flight_number')) setCol('flight_number', args['flight_number']);
          if (args.containsKey('crew_members_name')) setCol('crew_members_name', args['crew_members_name']);
          if (args.containsKey('total_time')) setCol('total_time', args['total_time']);
          if (args.containsKey('day_time')) setCol('day_time', args['day_time']);
          if (args.containsKey('night_time')) setCol('night_time', args['night_time']);
          if (args.containsKey('block_off')) setCol('block_off', args['block_off']);
          if (args.containsKey('block_on')) setCol('block_on', args['block_on']);
          if (args.containsKey('block_on_next_day')) {
            setCol('block_on_next_day', (args['block_on_next_day'] == true) ? 1 : 0);
          }
          if (args.containsKey('takeoffs')) setCol('takeoffs', args['takeoffs']);
          if (args.containsKey('landings')) setCol('landings', args['landings']);
          if (args.containsKey('actual_instrument')) setCol('actual_instrument', args['actual_instrument']);
          if (args.containsKey('simulated_instrument')) setCol('simulated_instrument', args['simulated_instrument']);
          if (args.containsKey('is_simulator')) {
            setCol('is_simulator', (args['is_simulator'] == true) ? 1 : 0);
          }
          if (args.containsKey('is_ifr')) {
            setCol('is_ifr', (args['is_ifr'] == true) ? 1 : 0);
          }
          if (args.containsKey('day_order')) setCol('day_order', args['day_order']);

          if (sets.isEmpty) return fail('No fields to update');

          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          sets.add('updated_at = ?');
          vals.add(nowSec);


          vals.add(id);
          db.execute('UPDATE flights SET ${sets.join(', ')} WHERE id = ?', vals);
          _audit(dbPath, 'update_flight', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'updated', 'id': id});
        } catch (e) {
          _audit(dbPath, 'update_flight', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('update_flight failed: $e');
        }
      });

  server.registerTool('delete_flight',
      description: 'Delete a flight by id. ',
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM flights WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Flight not found: $id');
          db.execute('DELETE FROM flights WHERE id = ?', [id]);
          _audit(dbPath, 'delete_flight', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'deleted', 'id': id});
        } catch (e) {
          _audit(dbPath, 'delete_flight', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('delete_flight failed: $e');
        }
      });

  // --- aircraft ---
  server.registerTool('add_aircraft',
      description: 'Add an aircraft. ',
      inputSchema: JsonSchema.object(properties: {
        'type': JsonSchema.string(),
        'country_code': JsonSchema.string(),
        'registration': JsonSchema.string(),
        'multi_engine': JsonSchema.boolean(),
        'ifr': JsonSchema.boolean(),
        'complex': JsonSchema.boolean(),
        'pressurised': JsonSchema.boolean(),
        'tailwheel': JsonSchema.boolean(),
        'simulator': JsonSchema.boolean(),
        'helicopter': JsonSchema.boolean(),
        'float_plane': JsonSchema.boolean(),
        'archived': JsonSchema.boolean(),
      }, required: ['type', 'country_code', 'registration']),
      callback: (args, extra) async {
        try {
          final id = 'mcp_ac_${DateTime.now().millisecondsSinceEpoch}';
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final cols = ['id', 'type', 'country_code', 'registration', 'created_at'];
          final vals = <Object?>[id, args['type'], args['country_code'], args['registration'], nowSec];
          void add(String col, Object? v, {bool boolToInt = false}) {
            if (v != null) {
              cols.add(col);
              vals.add(boolToInt ? ((v == true) ? 1 : 0) : v);
            }
          }

          add('multi_engine', args['multi_engine'], boolToInt: true);
          add('ifr', args['ifr'], boolToInt: true);
          add('complex', args['complex'], boolToInt: true);
          add('pressurised', args['pressurised'], boolToInt: true);
          add('tailwheel', args['tailwheel'], boolToInt: true);
          add('simulator', args['simulator'], boolToInt: true);
          add('helicopter', args['helicopter'], boolToInt: true);
          add('float_plane', args['float_plane'], boolToInt: true);
          add('archived', args['archived'], boolToInt: true);

          final placeholders = List.filled(cols.length, '?').join(',');
          db.execute('INSERT INTO aircraft (${cols.join(',')}) VALUES ($placeholders)', vals);
          _audit(dbPath, 'add_aircraft', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'created', 'id': id});
        } catch (e) {
          _audit(dbPath, 'add_aircraft', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('add_aircraft failed: $e');
        }
      });

  server.registerTool('update_aircraft',
      description: 'Update an aircraft by id. ',
      inputSchema: JsonSchema.object(properties: {
        'id': JsonSchema.string(),
        'type': JsonSchema.string(),
        'country_code': JsonSchema.string(),
        'registration': JsonSchema.string(),
        'multi_engine': JsonSchema.boolean(),
        'ifr': JsonSchema.boolean(),
        'complex': JsonSchema.boolean(),
        'pressurised': JsonSchema.boolean(),
        'tailwheel': JsonSchema.boolean(),
        'simulator': JsonSchema.boolean(),
        'helicopter': JsonSchema.boolean(),
        'float_plane': JsonSchema.boolean(),
        'archived': JsonSchema.boolean(),
      }, required: ['id']),
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM aircraft WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Aircraft not found: $id');

          final sets = <String>[];
          final vals = <Object?>[];
          void setCol(String col, Object? v, {bool boolToInt = false}) {
            sets.add('$col = ?');
            vals.add(boolToInt ? ((v == true) ? 1 : 0) : v);
          }

          if (args.containsKey('type')) setCol('type', args['type']);
          if (args.containsKey('country_code')) setCol('country_code', args['country_code']);
          if (args.containsKey('registration')) setCol('registration', args['registration']);
          if (args.containsKey('multi_engine')) setCol('multi_engine', args['multi_engine'], boolToInt: true);
          if (args.containsKey('ifr')) setCol('ifr', args['ifr'], boolToInt: true);
          if (args.containsKey('complex')) setCol('complex', args['complex'], boolToInt: true);
          if (args.containsKey('pressurised')) setCol('pressurised', args['pressurised'], boolToInt: true);
          if (args.containsKey('tailwheel')) setCol('tailwheel', args['tailwheel'], boolToInt: true);
          if (args.containsKey('simulator')) setCol('simulator', args['simulator'], boolToInt: true);
          if (args.containsKey('helicopter')) setCol('helicopter', args['helicopter'], boolToInt: true);
          if (args.containsKey('float_plane')) setCol('float_plane', args['float_plane'], boolToInt: true);
          if (args.containsKey('archived')) setCol('archived', args['archived'], boolToInt: true);

          if (sets.isEmpty) return fail('No fields to update');
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          sets.add('updated_at = ?');
          vals.add(nowSec);

          vals.add(id);
          db.execute('UPDATE aircraft SET ${sets.join(', ')} WHERE id = ?', vals);
          _audit(dbPath, 'update_aircraft', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'updated', 'id': id});
        } catch (e) {
          _audit(dbPath, 'update_aircraft', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('update_aircraft failed: $e');
        }
      });

  server.registerTool('delete_aircraft',
      description: 'Delete an aircraft by id. ',
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM aircraft WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Aircraft not found: $id');
          db.execute('DELETE FROM aircraft WHERE id = ?', [id]);
          _audit(dbPath, 'delete_aircraft', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'deleted', 'id': id});
        } catch (e) {
          _audit(dbPath, 'delete_aircraft', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('delete_aircraft failed: $e');
        }
      });

  // --- crew ---
  server.registerTool('add_crew',
      description: 'Add a crew member. ',
      inputSchema: JsonSchema.object(properties: {
        'name': JsonSchema.string(),
        'first_name': JsonSchema.string(),
        'last_name': JsonSchema.string(),
        'note': JsonSchema.string(),
        'archived': JsonSchema.boolean(),
      }, required: ['name', 'first_name', 'last_name']),
      callback: (args, extra) async {
        try {
          final id = 'mcp_cr_${DateTime.now().millisecondsSinceEpoch}';
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final cols = ['id', 'name', 'first_name', 'last_name', 'created_at'];
          final vals = <Object?>[id, args['name'], args['first_name'], args['last_name'], nowSec];
          if (args['note'] != null) {
            cols.add('note');
            vals.add(args['note']);
          }
          if (args['archived'] != null) {
            cols.add('archived');
            vals.add((args['archived'] == true) ? 1 : 0);
          }
          final placeholders = List.filled(cols.length, '?').join(',');
          db.execute('INSERT INTO crew_members (${cols.join(',')}) VALUES ($placeholders)', vals);
          _audit(dbPath, 'add_crew', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'created', 'id': id});
        } catch (e) {
          _audit(dbPath, 'add_crew', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('add_crew failed: $e');
        }
      });

  server.registerTool('update_crew',
      description: 'Update a crew member by id. ',
      inputSchema: JsonSchema.object(properties: {
        'id': JsonSchema.string(),
        'name': JsonSchema.string(),
        'first_name': JsonSchema.string(),
        'last_name': JsonSchema.string(),
        'note': JsonSchema.string(),
        'archived': JsonSchema.boolean(),
      }, required: ['id']),
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM crew_members WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Crew member not found: $id');

          final sets = <String>[];
          final vals = <Object?>[];
          void setCol(String col, Object? v, {bool boolToInt = false}) {
            sets.add('$col = ?');
            vals.add(boolToInt ? ((v == true) ? 1 : 0) : v);
          }

          if (args.containsKey('name')) setCol('name', args['name']);
          if (args.containsKey('first_name')) setCol('first_name', args['first_name']);
          if (args.containsKey('last_name')) setCol('last_name', args['last_name']);
          if (args.containsKey('note')) setCol('note', args['note']);
          if (args.containsKey('archived')) setCol('archived', args['archived'], boolToInt: true);

          if (sets.isEmpty) return fail('No fields to update');
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          sets.add('updated_at = ?');
          vals.add(nowSec);

          vals.add(id);
          db.execute('UPDATE crew_members SET ${sets.join(', ')} WHERE id = ?', vals);
          _audit(dbPath, 'update_crew', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'updated', 'id': id});
        } catch (e) {
          _audit(dbPath, 'update_crew', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('update_crew failed: $e');
        }
      });

  server.registerTool('delete_crew',
      description: 'Delete a crew member by id. ',
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM crew_members WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Crew member not found: $id');
          db.execute('DELETE FROM crew_members WHERE id = ?', [id]);
          _audit(dbPath, 'delete_crew', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'deleted', 'id': id});
        } catch (e) {
          _audit(dbPath, 'delete_crew', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('delete_crew failed: $e');
        }
      });

  // --- custom airports ---
  server.registerTool('add_custom_airport',
      description: 'Add a custom airport. ',
      inputSchema: JsonSchema.object(properties: {
        'name': JsonSchema.string(),
        'icao': JsonSchema.string(),
        'iata': JsonSchema.string(),
        'city': JsonSchema.string(),
        'country': JsonSchema.string(),
        'lat': JsonSchema.number(),
        'lon': JsonSchema.number(),
        'elevation': JsonSchema.integer(),
        'tz': JsonSchema.string(),
      }, required: ['name']),
      callback: (args, extra) async {
        try {
          final id = 'mcp_ap_${DateTime.now().millisecondsSinceEpoch}';
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final cols = ['id', 'name', 'created_at'];
          final vals = <Object?>[id, args['name'], nowSec];
          void add(String col, Object? v) {
            if (v != null) {
              cols.add(col);
              vals.add(v);
            }
          }

          add('icao', args['icao']);
          add('iata', args['iata']);
          add('city', args['city']);
          add('country', args['country']);
          add('lat', args['lat']);
          add('lon', args['lon']);
          add('elevation', args['elevation']);
          add('tz', args['tz']);
          if (args['owner_id'] != null) add('owner_id', args['owner_id']);

          final placeholders = List.filled(cols.length, '?').join(',');
          db.execute('INSERT INTO custom_airports (${cols.join(',')}) VALUES ($placeholders)', vals);
          _audit(dbPath, 'add_custom_airport', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'created', 'id': id});
        } catch (e) {
          _audit(dbPath, 'add_custom_airport', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('add_custom_airport failed: $e');
        }
      });

  server.registerTool('delete_custom_airport',
      description: 'Delete a custom airport by id. ',
      callback: (args, extra) async {
        try {
          final id = args['id'];
          if (id is! String || id.isEmpty) return fail('Missing or invalid id');
          final existing = db.query('SELECT * FROM custom_airports WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Custom airport not found: $id');
          db.execute('DELETE FROM custom_airports WHERE id = ?', [id]);
          _audit(dbPath, 'delete_custom_airport', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'deleted', 'id': id});
        } catch (e) {
          _audit(dbPath, 'delete_custom_airport', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('delete_custom_airport failed: $e');
        }
      });

  // --- saved routes ---
  server.registerTool('add_saved_route',
      description: 'Add a saved route. ',
      inputSchema: JsonSchema.object(properties: {
        'flight_number': JsonSchema.string(),
        'departure_icao': JsonSchema.string(),
        'arrival_icao': JsonSchema.string(),
        'distance_nm': JsonSchema.number(),
      }, required: ['flight_number', 'departure_icao', 'arrival_icao']),
      callback: (args, extra) async {
        try {
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final cols = ['flight_number', 'departure_icao', 'arrival_icao', 'created_at'];
          final vals = <Object?>[args['flight_number'], args['departure_icao'], args['arrival_icao'], nowSec];
          if (args['distance_nm'] != null) {
            cols.add('distance_nm');
            vals.add(args['distance_nm']);
          }
          final placeholders = List.filled(cols.length, '?').join(',');
          db.execute('INSERT INTO saved_routes (${cols.join(',')}) VALUES ($placeholders)', vals);
          final id = db.lastInsertRowId();
          _audit(dbPath, 'add_saved_route', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'created', 'id': id});
        } catch (e) {
          _audit(dbPath, 'add_saved_route', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('add_saved_route failed: $e');
        }
      });

  server.registerTool('update_saved_route',
      description: 'Update a saved route by id. ',
      inputSchema: JsonSchema.object(properties: {
        'id': JsonSchema.integer(),
        'flight_number': JsonSchema.string(),
        'departure_icao': JsonSchema.string(),
        'arrival_icao': JsonSchema.string(),
        'distance_nm': JsonSchema.number(),
      }, required: ['id']),
      callback: (args, extra) async {
        try {
          final id = args['id'];
          final existing = db.query('SELECT * FROM saved_routes WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Saved route not found: $id');

          final sets = <String>[];
          final vals = <Object?>[];
          void setCol(String col, Object? v) {
            sets.add('$col = ?');
            vals.add(v);
          }

          if (args.containsKey('flight_number')) setCol('flight_number', args['flight_number']);
          if (args.containsKey('departure_icao')) setCol('departure_icao', args['departure_icao']);
          if (args.containsKey('arrival_icao')) setCol('arrival_icao', args['arrival_icao']);
          if (args.containsKey('distance_nm')) setCol('distance_nm', args['distance_nm']);

          if (sets.isEmpty) return fail('No fields to update');
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          sets.add('updated_at = ?');
          vals.add(nowSec);

          vals.add(id);
          db.execute('UPDATE saved_routes SET ${sets.join(', ')} WHERE id = ?', vals);
          _audit(dbPath, 'update_saved_route', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'updated', 'id': id});
        } catch (e) {
          _audit(dbPath, 'update_saved_route', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('update_saved_route failed: $e');
        }
      });

  server.registerTool('delete_saved_route',
      description: 'Delete a saved route by id. ',
      callback: (args, extra) async {
        try {
          final id = args['id'];
          final existing = db.query('SELECT * FROM saved_routes WHERE id = ?', [id]);
          if (existing.isEmpty) return fail('Saved route not found: $id');
          db.execute('DELETE FROM saved_routes WHERE id = ?', [id]);
          _audit(dbPath, 'delete_saved_route', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'deleted', 'id': id});
        } catch (e) {
          _audit(dbPath, 'delete_saved_route', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('delete_saved_route failed: $e');
        }
      });

  // --- settings update ---
  server.registerTool('update_flight_settings',
      description: 'Update flight settings. ',
      inputSchema: JsonSchema.object(properties: {
        'id': JsonSchema.string(),
        'pilot_name': JsonSchema.string(),
        'default_flight_type': JsonSchema.string(),
        'date_format': JsonSchema.string(),
        'flight_time_format': JsonSchema.string(),
        'calculate_time_mode': JsonSchema.string(),
        'logbook_country': JsonSchema.string(),
        'show_summary_card': JsonSchema.boolean(),
        'show_day_night': JsonSchema.boolean(),
        'show_routes_in_wizard': JsonSchema.boolean(),
        'show_logbook_view': JsonSchema.boolean(),
        'show_flight_number': JsonSchema.boolean(),
      }),
      callback: (args, extra) async {
        try {
          final rows = db.query('SELECT id FROM flights_settings LIMIT 1');
          final id = (args['id'] is String && (args['id'] as String).isNotEmpty)
              ? args['id'] as String
              : (rows.isEmpty ? 'default' : rows.first['id'] as String);

          final sets = <String>[];
          final vals = <Object?>[];
          void setCol(String col, Object? v, {bool boolToInt = false}) {
            sets.add('$col = ?');
            vals.add(boolToInt ? ((v == true) ? 1 : 0) : v);
          }

          if (args.containsKey('pilot_name')) setCol('pilot_name', args['pilot_name']);
          if (args.containsKey('default_flight_type')) setCol('default_flight_type', args['default_flight_type']);
          if (args.containsKey('date_format')) setCol('date_format', args['date_format']);
          if (args.containsKey('flight_time_format')) setCol('flight_time_format', args['flight_time_format']);
          if (args.containsKey('calculate_time_mode')) setCol('calculate_time_mode', args['calculate_time_mode']);
          if (args.containsKey('logbook_country')) setCol('logbook_country', args['logbook_country']);
          if (args.containsKey('show_summary_card')) setCol('show_summary_card', args['show_summary_card'], boolToInt: true);
          if (args.containsKey('show_day_night')) setCol('show_day_night', args['show_day_night'], boolToInt: true);
          if (args.containsKey('show_routes_in_wizard')) setCol('show_routes_in_wizard', args['show_routes_in_wizard'], boolToInt: true);
          if (args.containsKey('show_logbook_view')) setCol('show_logbook_view', args['show_logbook_view'], boolToInt: true);
          if (args.containsKey('show_flight_number')) setCol('show_flight_number', args['show_flight_number'], boolToInt: true);

          if (sets.isEmpty) return fail('No fields to update');
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          sets.add('updated_at = ?');
          vals.add(nowSec);


          // Upsert: if no row exists, insert.
          final existing = db.query('SELECT id FROM flights_settings WHERE id = ?', [id]);
          if (existing.isEmpty) {
            db.execute('INSERT INTO flights_settings (id) VALUES (?)', [id]);
          }
          vals.add(id);
          db.execute('UPDATE flights_settings SET ${sets.join(', ')} WHERE id = ?', vals);
          _audit(dbPath, 'update_flight_settings', args.cast<String, dynamic>(), 'ok', 'id=$id');
          return ok({'status': 'updated', 'id': id});
        } catch (e) {
          _audit(dbPath, 'update_flight_settings', args.cast<String, dynamic>(), 'error', e.toString());
          return fail('update_flight_settings failed: $e');
        }
      });

  } // end writes

  // ============================================================
  // RESOURCES
  // ============================================================

  server.registerResource('flights', 'falcon://flights', null, (uri, extra) async {
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
  });

  await server.connect(StdioServerTransport());
}
