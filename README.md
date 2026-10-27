<p align="center">
  <img src="https://img.shields.io/badge/Dart-3.4+-blue?logo=dart" alt="Dart">
  <img src="https://img.shields.io/badge/MCP-2025--11--25-green" alt="MCP">
</p>

# Falcon MCP Server

Talk to your logbook with AI. Falcon MCP is a [Model Context Protocol](https://modelcontextprotocol.io) server that lets your preferred AI assistant (Claude, ChatGPT, Gemini, Codex, and others) read and edit your Falcon Logbook.

Built by [Team Super Panda](https://www.teamsuperpanda.com).

---

## Why this exists

Your logbook is the most personal dataset you own as a pilot. It holds every flight you have ever flown: hours, aircraft, routes, crew, landings, night time, instrument time. But getting answers out of it usually means scrolling, filtering, and counting by hand.

Falcon MCP puts that data one question away. Instead of building reports yourself, you ask:

- "How many hours did I fly last year, and how much of it was at night?"
- "Which aircraft have I flown the most, and when did I last fly each one?"
- "Show me all flights into YSSY in 2025."
- "How many landings do I have in the last 90 days?"
- "Are there any flights missing block times or total time?"
- "Summarize my instrument time by month."

The AI reads your local Falcon database directly, so the answers are based on your real data, not guesses. Nothing leaves your computer unless you choose to use a cloud AI provider, and even then only the question and the relevant rows travel, not your whole logbook.

---

## What it does

Falcon MCP is a small, fast program that runs on your machine alongside your logbook. It speaks the Model Context Protocol over standard input/output, so any MCP-capable AI client can launch it and ask it questions.

- **Flight queries** - list, search, and filter flights by date, aircraft, route, flight number, or free text.
- **Flight writes** - create, update, and delete flights (with dry-run preview and confirmation).
- **Aircraft** - list and inspect your fleet, including archived airframes.
- **Airports** - search the built-in airport database and your custom airports by ICAO, IATA, name, or city.
- **Crew** - list crew members, including archived ones.
- **Routes** - list saved routes.
- **Statistics** - totals for flights, hours, night time, landings, and takeoffs, with optional date ranges.
- **Settings & diagnostics** - read flight settings and recent log entries to help troubleshoot.

Reads are always allowed. Writes (create/update/delete) default to a dry-run preview and require `confirm=true` to apply. Every write is recorded in a local audit log. Your logbook stays authoritative.

---

## Benefits

- **Answers in seconds.** No manual filtering or counting. Ask in plain English and get the numbers.
- **Your data stays yours.** The server reads your local SQLite file. There is no Falcon cloud, no telemetry, no account. It works fully offline.
- **No lock-in.** MCP is an open standard. Use Claude today, a different model tomorrow. The server does not care which AI you prefer.
- **Safe by design.** Read-only tools, a schema version gate that refuses to run against an unexpected database, and no network exposure by default.
- **Complements the app.** Falcon stays the single writer of your logbook. The MCP server never modifies it, so there are no sync conflicts or stale screens.

---

## Who it is for

- **Pilots** who want quick answers from their logbook without clicking through filters.
- **Instructors and operators** tracking currency, hours, and aircraft usage across many entries.
- **Anyone** who wants an AI copilot for their logbook data but does not want to upload it anywhere.

If you have never used an MCP server before, think of it as a safe bridge between your logbook and an AI chat: it can read freely and writes only with your explicit confirmation.

---

## Requirements

- A Falcon Logbook database file (`falcon_db.sqlite`), produced by the Falcon app.
- Dart SDK 3.4 or newer (only needed to build; the compiled binary has no Dart dependency).
- An MCP-capable AI client on your computer (see below).
- `libsqlite3` available on your system (present on almost all Linux, macOS, and Windows installs).

---

## Build

```bash
git clone https://github.com/Falcon-Logbook/mcp.git
cd mcp
dart pub get
dart compile exe bin/falcon_mcp.dart -o falcon_mcp
```

The result is a single native executable, `falcon_mcp`.

---

## Run

Point it at your database with an environment variable or a flag:

```bash
FALCON_DB_PATH=/path/to/falcon_db.sqlite ./falcon_mcp
# or
./falcon_mcp --db /path/to/falcon_db.sqlite
```

The server refuses to start if the database schema version does not match the supported version (currently 18). This protects you from silent corruption when the app and server drift apart.

Your database path is usually:

- Linux: `~/Documents/Falcon/falcon_db.sqlite`
- macOS: `~/Library/Application Support/Falcon/falcon_db.sqlite`
- Windows: `%APPDATA%\Falcon\falcon_db.sqlite`

If you chose a custom path in the app, use that.

---

## Use with an AI client

Falcon MCP is a **stdio** server: the client launches it as a subprocess and talks to it over standard input/output. It cannot be used from a browser. You need a local MCP client.

### Claude Desktop

Edit `claude_desktop_config.json`:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "falcon": {
      "command": "/path/to/falcon_mcp",
      "env": {
        "FALCON_DB_PATH": "/path/to/falcon_db.sqlite"
      }
    }
  }
}
```

Restart Claude Desktop. A Falcon tool icon appears in the chat.

### Claude Code

```bash
claude mcp add falcon -- /path/to/falcon_mcp --db /path/to/falcon_db.sqlite
```

### Codex / other stdio clients

Register a stdio server pointing at the `falcon_mcp` binary, passing `--db /path/to/falcon_db.sqlite` (or setting `FALCON_DB_PATH`).

### Cursor, Windsurf, and others

Add an MCP server entry of type `stdio` with the command path and the `--db` argument. Consult your client's docs for the exact config file location.

> **Note:** claude.ai (web) cannot launch a local stdio server. Use Claude Desktop, Claude Code, or another local client instead. Remote (HTTPS) mode is planned but not available yet.

---

## Tools

| Tool | Description |
|---|---|
| `db_info` | Database path, schema version, and table list |
| `list_flights` | List flights with optional filters (date range, aircraft registration, flight type) |
| `get_flight` | Get a single flight by id |
| `search_flights` | Free-text search over route, flight number, crew name, registration |
| `list_aircraft` | List aircraft, optionally including archived |
| `get_aircraft` | Get aircraft by id |
| `list_airports` | Search built-in airports by ICAO/IATA/name/city |
| `list_custom_airports` | List user-defined airports |
| `list_crew` | List crew members, optionally including archived |
| `list_saved_routes` | List saved routes |
| `logbook_stats` | Totals for flights, minutes, night time, landings, takeoffs (optional date range) |
| `get_flight_settings` | Pilot name, formats, country, display preferences |
| `get_app_settings` | Storage mode, theme, accent, and app preferences |
| `get_general_settings` | Startup tab, language, coordinates format, etc. |
| `get_sync_status` | Sync state per table/provider and pending tombstone count |
| `get_recent_logs` | Recent log entries for diagnostics |
| `create_flight` | Create a flight (dry run unless confirm=true) |
| `update_flight` | Update a flight by id (dry run unless confirm=true) |
| `delete_flight` | Delete a flight by id (dry run unless confirm=true) |
| `add_aircraft` | Add an aircraft (dry run unless confirm=true) |
| `update_aircraft` | Update an aircraft by id (dry run unless confirm=true) |
| `delete_aircraft` | Delete an aircraft by id (dry run unless confirm=true) |
| `add_crew` | Add a crew member (dry run unless confirm=true) |
| `update_crew` | Update a crew member by id (dry run unless confirm=true) |
| `delete_crew` | Delete a crew member by id (dry run unless confirm=true) |
| `add_custom_airport` | Add a custom airport (dry run unless confirm=true) |
| `delete_custom_airport` | Delete a custom airport by id (dry run unless confirm=true) |
| `add_saved_route` | Add a saved route (dry run unless confirm=true) |
| `update_saved_route` | Update a saved route by id (dry run unless confirm=true) |
| `delete_saved_route` | Delete a saved route by id (dry run unless confirm=true) |
| `update_flight_settings` | Update flight settings (dry run unless confirm=true) |
| `find_missing_times` | Find flights missing total/block times |
| `dedupe_crew` | Find crew members with duplicate names |

Resource: `falcon://flights` (latest 100 flights as JSON).

---

## Privacy and safety

- **Local only.** The server reads your SQLite file directly. It opens no sockets and exposes no network endpoints.
- **Writes are gated.** Write tools default to a dry-run preview and require `confirm=true` to apply. Every write is recorded in a local audit log (`.mcp_audit.jsonl` next to your database).
- **Schema-gated.** The server refuses to run if the database schema version is unexpected.
- **No telemetry.** Nothing is sent anywhere by the server itself. (Your AI provider's own privacy policy still applies to the prompts you send it.)

---

## Tech

| Layer | Choice |
|---|---|
| Language | Dart |
| MCP protocol | `mcp_dart` (stdio transport) |
| Storage | `sqlite3` (read/write SQL) |
| Build | `dart compile exe` |

No Flutter dependency. The server is a plain Dart console program, so it stays small and fast.

---

## Status

Local server now supports read and write operations with dry-run previews, confirmation, and an audit log. In-app server, HTTP/SSE transport, and Falcon Cloud hosting are on the roadmap.

---

## Roadmap

- **Falcon Cloud MCP endpoint** - a hosted, HTTPS MCP server for Falcon Cloud subscribers, so AI assistants can reach your logbook from anywhere (including claude.ai web) without a local server. Same tool surface, authenticated per account.
- **HTTP/SSE transport** for the local server (in addition to stdio).
- **Postgres connection tools** - set up, test, and disconnect sync connections from the AI.
- **In-app MCP server** - embed the MCP endpoint inside the Falcon app to reuse the real DAOs and stay the single writer.

---

## License

Apache License 2.0. Copyright 2026 Team Super Panda. Free to use, modify and
redistribute, including commercially. See https://falconlogbook.com/license for
the full terms. The Falcon name and logo are trademarks, not licensed.
