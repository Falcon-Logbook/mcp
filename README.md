# Falcon MCP Server

MCP (Model Context Protocol) server exposing a local Falcon Logbook SQLite
database to AI assistants (Claude, ChatGPT, Codex, Gemini, etc.).

Phase 1: **read-only**. Write tools are intentionally not implemented yet.

## Build

```bash
dart pub get
dart compile exe bin/falcon_mcp.dart -o falcon_mcp
```

Runtime requires `libsqlite3` (available on most systems).

## Run

```bash
FALCON_DB_PATH=/path/to/falcon_db.sqlite ./falcon_mcp
# or
./falcon_mcp --db /path/to/falcon_db.sqlite
```

The server refuses to start if the DB schema version does not match the
supported version (currently 18).

## Use with MCP clients

### Claude Desktop

Edit `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "falcon": {
      "command": "/path/to/falcon_mcp",
      "env": { "FALCON_DB_PATH": "/path/to/falcon_db.sqlite" }
    }
  }
}
```

### Codex / other stdio clients

Register a stdio server pointing at the `falcon_mcp` binary with the
`FALCON_DB_PATH` environment variable set (or pass `--db`).

## Tools (read-only)

- `db_info` - path, schema version, tables
- `list_flights`, `get_flight`, `search_flights`
- `list_aircraft`, `get_aircraft`
- `list_airports`, `list_custom_airports`
- `list_crew`
- `list_saved_routes`
- `logbook_stats`
- `get_flight_settings`
- `get_recent_logs`

Resource: `falcon://flights`.
