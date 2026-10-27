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

It works whether the Falcon app is open or closed.

---

## What it does

- **Answer questions** - "How many hours did I fly last year, at night?" "Which aircraft have I flown the most?" "Show flights into YSSY in 2025." "How many landings in the last 90 days?"
- **Find gaps** - flights missing block times or total time, duplicate crew members.
- **Statistics** - totals for flights, hours, night time, landings, and takeoffs, by date range.
- **Search and filter** - flights by date, aircraft, route, flight number, or free text; airports by ICAO/IATA/name/city; aircraft and crew lists.
- **Edit** - create, update, and delete flights, aircraft, crew, airports, and saved routes.
- **Diagnostics** - read settings and recent log entries to troubleshoot.

Reads and writes are both available. Every write is recorded in a local audit log (`.mcp_audit.jsonl` next to your database).

---

## Benefits

- **Answers in seconds.** No manual filtering or counting. Ask in plain English, get the numbers.
- **Your data stays yours.** The server reads your local SQLite file. No Falcon cloud, no telemetry, no account. Fully offline.
- **No lock-in.** MCP is an open standard. Use Claude today, a different model tomorrow.
- **Safe by design.** A schema version gate refuses unexpected databases, and there is no network exposure by default (stdio mode).
- **Complements the app.** Falcon stays the authority for your logbook; the MCP server only writes when you explicitly approve each change.

---

## Get your AI to install it for you

You do not need to install this yourself. Paste this prompt to your AI agent (Claude Code, Codex, etc.) and it will set everything up:

```
Set up the Falcon MCP server for me.

1. Check that Dart SDK 3.4+ is installed (`dart --version`). If not, install it.
2. Clone https://github.com/Falcon-Logbook/mcp into a local directory and run `dart pub get`.
3. Compile: `dart compile exe bin/falcon_mcp.dart -o ~/.local/bin/falcon_mcp`.
4. Ensure libsqlite3 is available (symlink /lib64/libsqlite3.so.0 to ~/.local/lib/libsqlite3.so if needed).
5. Ask me:
  - Where is my Falcon database? (default: ~/Documents/Falcon/falcon_db.sqlite)
  - Do I want read-only mode (safe, AI can only read) or read+write mode (AI can create/update/delete)?
6. Register the server in my MCP client config:
  - OpenCode: add a "Falcon" entry under "mcp" in ~/.config/opencode/opencode.json, type "local", command ["/home/<me>/.local/bin/falcon_mcp"], enabled true, environment FALCON_DB_PATH=<db path>, FALCON_READONLY=<true|false>, LD_LIBRARY_PATH=/home/<me>/.local/lib.
  - Claude Desktop: add to claude_desktop_config.json with command and env.
  - Claude Code: `claude mcp add falcon -- /home/<me>/.local/bin/falcon_mcp` with FALCON_DB_PATH set.
7. Restart the client and verify by calling db_info.
8. Tell me the readonly setting I chose and how to flip it later (pass --no-readonly or set FALCON_READONLY=false).
```

### Read-only vs read+write

- Default: read-only (`FALCON_READONLY=true`). Only read tools are exposed.
- To allow edits: pass `--no-readonly` (or `FALCON_READONLY=false`). Write tools are available immediately.
- Your agent should ask which mode you want during setup and never enable writes without your explicit consent.

---

## Requirements

- A Falcon Logbook database file (`falcon_db.sqlite`), produced by the Falcon app.
- An MCP-capable AI client on your computer (Claude Desktop, Claude Code, Codex, Cursor, etc.).
- Dart SDK 3.4+ and `libsqlite3` are only needed to build; your agent handles this.

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

The server refuses to start if the database schema version does not match the supported version (currently 18).

### Tools

| Tool | Description |
|---|---|
| `db_info` | Database path, schema version, table list, readonly flag |
| `list_flights` | List flights with optional filters (date range, aircraft registration, flight type) |
| `get_flight` | Get a single flight by id |
| `search_flights` | Free-text search over route, flight number, crew name, registration |
| `list_aircraft` | List aircraft, optionally including archived |
| `get_aircraft` | Get aircraft by id |
| `list_airports` | Search built-in airports by ICAO/IATA/name/city |
| `list_custom_airports` | List user-defined custom airports |
| `list_crew` | List crew members, optionally including archived |
| `list_saved_routes` | List saved routes |
| `logbook_stats` | Totals for flights, minutes, night time, landings, takeoffs (optional date range) |
| `get_flight_settings` | Pilot name, formats, country, display preferences |
| `get_app_settings` | Storage mode, theme, accent, and app preferences |
| `get_general_settings` | Startup tab, language, coordinates format, etc. |
| `get_sync_status` | Sync state per table/provider and pending tombstone count |
| `get_recent_logs` | Recent log entries for diagnostics |
| `find_missing_times` | Find flights missing total/block times |
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
| `delete_custom_airport` | Delete a custom airport by id |
| `add_saved_route` | Add a saved route |
| `update_saved_route` | Update a saved route by id |
| `delete_saved_route` | Delete a saved route by id |
| `update_flight_settings` | Update flight settings |

Resource: `falcon://flights` (latest 100 flights as JSON).

### Tech

| Layer | Choice |
|---|---|
| Language | Dart |
| MCP protocol | `mcp_dart` (stdio transport) |
| Storage | `sqlite3` (read/write SQL) |
| Build | `dart compile exe` |

No Flutter dependency. The server is a plain Dart console program, so it stays small and fast.

### Privacy and safety

- **Local only.** The server reads your SQLite file directly. It opens no sockets and exposes no network endpoints (stdio mode).
- **Writes are direct.** Write tools apply immediately. Every write is recorded in a local audit log (`.mcp_audit.jsonl` next to your database).
- **Schema-gated.** The server refuses to run if the database schema version is unexpected.
- **No telemetry.** Nothing is sent anywhere by the server itself.

### Roadmap

- **Falcon Cloud MCP endpoint** - a hosted, HTTPS MCP server for Falcon Cloud subscribers.
- **HTTP/SSE transport** for the local server (in addition to stdio).
- **Postgres connection tools** - set up, test, and disconnect sync connections from the AI.
- **In-app MCP server** - embed the MCP endpoint inside the Falcon app to reuse the real DAOs and stay the single writer.

---

## License

Apache License 2.0. Copyright 2026 Team Super Panda. Free to use, modify and
redistribute, including commercially. See https://falconlogbook.com/license for
the full terms. The Falcon name and logo are trademarks, not licensed.
