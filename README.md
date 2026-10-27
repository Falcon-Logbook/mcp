<p align="center">
 <img src="https://img.shields.io/badge/Dart-3.4+-blue?logo=dart" alt="Dart">
 <img src="https://img.shields.io/badge/MCP-2026--07--28-green" alt="MCP">
</p>

# Falcon MCP Server

**Talk to your logbook with AI.** Falcon MCP is a small program that runs on your computer and lets your preferred AI assistant (Claude, ChatGPT, Gemini, Codex, and others) read and edit your Falcon Logbook. Ask questions in plain English and get real answers from your own flight data.

Built by [Team Super Panda](https://www.teamsuperpanda.com).

---

## What it is

Falcon MCP is a bridge between your logbook and an AI chat. It runs locally on your machine, reads your Falcon SQLite database directly, and exposes your data to any AI client that speaks the [Model Context Protocol](https://modelcontextprotocol.io). Nothing is uploaded anywhere: your data stays on your computer unless you choose to use a cloud AI provider, and even then only the question and the relevant rows travel.

**Desktop only.** It targets the database the Falcon desktop app writes on Windows, macOS and Linux. There is no Falcon Cloud support and none is planned: the server has no hosted endpoint, no account, no sync awareness, and it never opens a connection to a Falcon server. It also cannot reach the database inside the mobile app, which is sandboxed to that device.

It works whether the Falcon app is open or closed.

---

## What it does

- **Answer questions** - "How many hours did I fly last year, at night?" "Which aircraft have I flown the most?" "Show flights into YSSY in 2025." "How many landings in the last 90 days?"
- **Find gaps** - flights missing block times or total time, duplicate crew members.
- **Statistics** - totals for flights, hours, night time, landings, and takeoffs, by date range.
- **Search and filter** - flights by date, aircraft, route, flight number, or free text; airports by ICAO/IATA/name/city; aircraft and crew lists.
- **Edit** - create, update, and delete flights, aircraft, crew, airports, and saved routes.
- **Diagnostics** - read settings and recent log entries to troubleshoot.

Reads and writes are both available. Every write is recorded in a local audit log (`<database-name>.mcp_audit.jsonl` next to your database).

---

## Benefits

- **Answers in seconds.** No manual filtering or counting. Ask in plain English, get the numbers.
- **Your data stays yours.** The server reads your local SQLite file. No Falcon Cloud, no telemetry, no account. Fully offline.
- **No lock-in.** MCP is an open standard. Use Claude today, a different model tomorrow.
- **Safe by design.** A schema version gate refuses unexpected databases, writes are off unless you enable them, and there is no network exposure (stdio mode).
- **Complements the app.** Falcon stays the authority for your logbook: the server writes the same rows the app writes, including aircraft and crew links.

---

## Get your AI to install it for you

Paste this prompt to your AI agent (Claude Code, Codex, Cursor, OpenCode, or any other) and it will install and configure Falcon MCP for you:

```
Set up the Falcon MCP server for me.

You are an AI agent. Detect which environment/client you are running in
(OpenCode, Claude Code, Claude Desktop, Codex, Cursor, Windsurf, or other)
and follow that client's documented way of registering a local stdio MCP server.
If you are unsure how to register an MCP server in this client, search the web
for "<client name> MCP server setup stdio" and follow the official instructions.

Steps:
1. Check that Dart SDK 3.4+ is installed (`dart --version`). If not, install it for this OS.
2. Clone https://github.com/Falcon-Logbook/mcp into a sensible local directory and run `dart pub get`.
3. Compile: `dart compile exe bin/falcon_mcp.dart -o <bin-dir>/falcon_mcp` (use ~/.local/bin or equivalent).
4. Check that SQLite is available. The server loads the system library itself
   (including the Linux runtime name libsqlite3.so.0). If your system only has a
   differently named library, create a symlink: `mkdir -p ~/.local/lib &&
   ln -sf /path/to/libsqlite3.so ~/.local/lib/libsqlite3.so` and add
   `LD_LIBRARY_PATH=~/.local/lib` for the server.
5. Ask me:
   - Where is my Falcon database? If I am not sure, search common locations:
       Linux:   ~/Documents/Falcon/falcon_db.sqlite, ~/.local/share/com.teamsuperpanda.falcon/falcon_db.sqlite
       macOS:   ~/Library/Application Support/com.teamsuperpanda.falcon/Falcon/falcon_db.sqlite
       Windows: %APPDATA%\com.teamsuperpanda.falcon\Falcon\falcon_db.sqlite
     and any custom path stored in db_path.conf inside the app-support directory above.
     Pick the first match and confirm with me.
   - Do I want read-only mode (safe, AI can only read) or read+write mode (AI can create/update/delete)?
6. Register the server as a local stdio MCP server named "Falcon" in this client's config,
   passing the binary path and these environment variables:
     FALCON_DB_PATH=<db path>
     FALCON_READONLY=<true|false>
     LD_LIBRARY_PATH=<path to libsqlite3 dir> (Linux only)
7. Restart/reload the client if required and verify by calling db_info.
8. Tell me the mode I chose and how to flip it later (pass --no-readonly or set FALCON_READONLY=false).
   An explicit flag always wins over the environment variable.
```

### Read-only vs read+write

- Default: read-only (`FALCON_READONLY=true`). Only read tools are exposed and the database is opened read-only.
- To allow edits: pass `--no-readonly` (or `FALCON_READONLY=false`). Write tools are available immediately.
- An explicit `--readonly`/`--no-readonly` flag overrides `FALCON_READONLY`.
- Your agent should ask which mode you want during setup and never enable writes without your explicit consent.

---

## Requirements

- A Falcon Logbook database file (`falcon_db.sqlite`), produced by the Falcon app.
- An MCP-capable AI client on your computer (Claude Desktop, Claude Code, Codex, Cursor, etc.).
- Dart SDK 3.4+ and `libsqlite3` are only needed to build and run the server binary, not the app; your agent handles this.

---

## For developers

### Build

```bash
git clone https://github.com/Falcon-Logbook/mcp.git
cd mcp
dart pub get
dart compile exe bin/falcon_mcp.dart -o falcon_mcp
```

### Run

```bash
FALCON_DB_PATH=/path/to/falcon_db.sqlite ./falcon_mcp
# or
./falcon_mcp --db /path/to/falcon_db.sqlite
# enable writes
./falcon_mcp --db /path/to/falcon_db.sqlite --no-readonly
```

The database path is resolved in this order: `--db`, then `FALCON_DB_PATH`, then the app's `db_path.conf`, then the platform default (`~/Documents/Falcon/falcon_db.sqlite` on Linux). A configured path that no longer exists is ignored.

The server refuses to start if the database schema version is outside the supported range (currently 18-19), and it never creates an empty database. Queries select whole rows, writes only touch known columns, and tool schemas only advertise columns the file actually has, so additive columns from newer migrations are tolerated and v19-only fields are hidden on a v18 file.

### Tools

| Tool | Description |
|---|---|
| `db_info` | Database path, schema version, table list, readonly flag |
| `get_schema` | Describe tables and columns (name, type, nullability, default, PK) |
| `list_flights` | List flights with optional filters (date range, aircraft registration, flight type, crew name) |
| `get_flight` | Get a single flight by id |
| `search_flights` | Free-text search over route, flight number, crew name, registration |
| `list_aircraft` | List aircraft, optionally including archived |
| `get_aircraft` | Get aircraft by id |
| `list_airports` | Search built-in airports by ICAO/IATA/name/city |
| `list_custom_airports` | List user-defined custom airports |
| `list_crew` | List crew members, optionally including archived |
| `list_saved_routes` | List saved routes |
| `logbook_stats` | Totals for flights, drafts, minutes, night time, landings, takeoffs (optional date range) |
| `get_flight_settings` | Pilot name, formats, country, display preferences |
| `get_app_settings` | Storage mode, theme, accent, and app preferences |
| `get_general_settings` | Startup tab, language, coordinates format, etc. |
| `get_recent_logs` | Recent log entries for diagnostics |
| `find_missing_times` | Find draft flights (no total time) or flights with no day/night split |
| `dedupe_crew` | Find crew members with duplicate names |
| `create_flight` | Create a flight |
| `update_flight` | Update a flight by id |
| `delete_flight` | Delete a flight by id |
| `add_aircraft` | Add an aircraft |
| `update_aircraft` | Update an aircraft by id |
| `delete_aircraft` | Delete an aircraft by id |
| `add_crew` | Add a crew member |
| `update_crew` | Update a crew member by id |
| `delete_crew` | Delete a crew member by id |
| `add_custom_airport` | Add a custom airport |
| `update_custom_airport` | Update a custom airport by id |
| `delete_custom_airport` | Delete a custom airport by id |
| `add_saved_route` | Add a saved route |
| `update_saved_route` | Update a saved route by id |
| `delete_saved_route` | Delete a saved route by id |
| `update_flight_settings` | Update flight settings |

Write tools derive the same links the app does: `aircraft_registration` is matched against the aircraft table (bare `XZO` and display `VH-XZO` both work) to set `aircraft_id`, and `crew_members_name` sets `crew_member_id`. Unknown argument names are rejected instead of silently ignored, and `get_schema` plus `falcon://conventions` describe every writable column.

Resources: `falcon://flights` (latest 100 flights as JSON), `falcon://overview`, `falcon://conventions` (field semantics: dates, minutes, registration format, draft rule), `falcon://schema`.
Prompt: `falcon_help` (tool list and example questions, write tools only listed when enabled).

### Tech

| Layer | Choice |
|---|---|
| Language | Dart |
| MCP protocol | `mcp_dart` (stdio transport) |
| Storage | `sqlite3` (read/write SQL) |
| Build | `dart compile exe` |

No Flutter dependency. The server is a plain Dart console program, so it stays small and fast.

### Test

```bash
dart test
```

The suite builds a temporary database with the real Falcon schema and drives the server over stdio, so writes are exercised end to end without touching your own logbook.

### Privacy and safety

- **Local only.** The server reads your SQLite file directly. It opens no sockets and exposes no network endpoints (stdio mode).
- **Writes are direct.** Write tools apply immediately. Every write is recorded in a local audit log (`<database-name>.mcp_audit.jsonl` next to your database).
- **Same shape as the app.** Foreign keys are enforced, deletes record the same tombstones the app writes (only when a sync provider has already been used, so a later sync does not resurrect the row), and deleting a saved route unlinks the flights that used it. That is app parity on the local file, not cloud support: the server never talks to a sync server.
- **Schema-gated.** The server refuses to run if the database schema version is unexpected.
- **No telemetry.** Nothing is sent anywhere by the server itself.

### Roadmap

- **Exports and reports** - let the agent produce the app's exports and PDF reports, not just the rows behind them. Tracked as an issue.
- **HTTP/SSE transport** for the local server (in addition to stdio).
- **In-app MCP server** - embed the MCP endpoint inside the Falcon app to reuse the real DAOs and stay the single writer.

Not planned: anything Falcon Cloud. No hosted endpoint, no sync administration. The server is a local reader and writer of one desktop database file.

---

## License

Apache License 2.0. Copyright 2026 Team Super Panda. Free to use, modify and
redistribute, including commercially. See https://falconlogbook.com/license for
the full terms. The Falcon name and logo are trademarks, not licensed.
