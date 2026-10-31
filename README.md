# Falcon MCP Server

**Your AI can read your logbook.** Ask in plain English, get answers from your own flights.

Falcon is a free and open source pilot logbook. The people's logbook. This is the door between that
logbook and the assistant you already use: a small program on your computer that lets Claude, Codex,
Cursor, or any other client that speaks the
[Model Context Protocol](https://modelcontextprotocol.io) work with your real Falcon data.

Desktop only. Windows, macOS, Linux. It reads the database file the Falcon desktop app writes, so it
cannot reach your phone.

Built by [Team Super Panda](https://www.teamsuperpanda.com).

---

## What it does

- **Drafts the flights before you fly them.** Hand it next month's roster, as a PDF, a screenshot or a
  pasted table, and it builds the flights while they are still ahead of you. Where the roster is thin
  it asks: which aircraft, if there is no tail on the line? UTC or local, for those times? The drafts
  stay out of your hours until you enter the real block times.
- **Brings the old logbook across.** Point it at an export from your last app, or a scanned logbook,
  and it maps the columns, shows you the mapping, and flags what Falcon does not recognise
  (instructing time, odd formats). It asks before it guesses.
- **Cleans up after the import.** Duplicate crew merged, flights missing an aircraft linked to the
  right one, the whole tidy found in one pass instead of edited one flight at a time.
- **Answers the awkward questions.** Hours by year, by type, by crew. Last 90 days. Landings to
  recency. Most-flown route. Worked out from your own data, and you can check the answer against the
  app.
- **Finds what is missing.** Drafts with no block times, flights with no day and night split,
  duplicate rows, missing links.
- **Produces your exports and reports.** The same exports and the same PDF reports the app makes,
  from the same data.
- **Tells you what it can do for you.** It reads your logbook and comes back with what it can help
  with, in your numbers rather than a generic feature list.

Falcon stays the authority. The agent is the shortcut.

---

## Ask it things like this

- "How many night hours did I fly in the last 90 days?"
- "How many landings do I have in the last 90 days, and where does that leave my recency?"
- "What is my most-flown route, and who was I flying with?"
- "Read this roster and draft the flights for next month."
- "Import this export from my old logbook and tell me what you do not recognise."
- "Merge the duplicate crew and link up the flights with no aircraft."
- "Is my medical still valid, and when does my type rating run out?"
- "Where are my gaps?"

When it needs something it does not know, it asks: which aircraft, UTC or local, which column is the
date. In a client that can show a form you get a picker or a short form. In one that cannot, the
same questions arrive as plain questions in the chat. If you leave an optional one alone, the answer
comes back marked as a default rather than as your choice, so a guess is never reported as your
answer. It does not invent an aircraft, a time or a column.

---

## Rosters

Paste a roster, a bid line or next month's schedule, as text, a PDF or a screenshot, and say "import my
roster".

- **What it asks.** Only what the roster does not say, in a few grouped questions: planned or flown, UTC
  or local, which aircraft when a line carries no tail, your crew role on these legs, who else is
  flying, and what to do about a leg that is already in the logbook. In a client that can show a form
  those arrive as pickers and yes/no answers; anywhere else they arrive as plain questions in the chat.
- **What it shows.** A table of date, route, departure and arrival, aircraft, crew role and draft
  yes/no, with the row count and the rows that need attention, before it writes anything.
- **What lands.** Draft flights. A schedule is not a logbook: the block time stays the plan and
  `total_time` stays empty, so nothing is added to your hours until you fly the leg and enter the real
  time. A leg that is already in the logbook is skipped, never overwritten, and every row that did not
  make it is named with the reason.
- **Planned times.** Keeping the planned departure, arrival and block on the flight needs the app's
  next schema (Falcon-Logbook/app#231, v20). Until that ships, the drafts carry no planned times: the
  tools say so plainly rather than putting the block into your total.

---

## Importing a logbook

Point it at an export from your last app, a scanned or digital paper logbook, or a pasted table, and
say "import my logbook". Your client reads the file (including the OCR); the server validates the
mapped rows and writes them.

- **The mapping is shown and confirmed first.** Every source column mapped to a Falcon column, plus
  three sample rows rendered as they would land, and an explicit yes from you before anything is
  written. Skip the review and it still keeps the dry run: it never blind-imports a file.
- **Units are declared once.** Whole minutes, decimal hours, or H:MM, for the whole file. A cell that
  does not match the declared convention is refused, never guessed: mixed units in one column are an
  error, not a conversion.
- **Dates are strict YYYY-MM-DD.** A spreadsheet serial number is refused with the date it shows, and
  a slash or timestamp date with its probable reading (both readings when it is ambiguous). None of
  them is ever converted for you, because a wrong reading moves a flight between months and years.
- **Unknown columns are surfaced, never dropped.** A column Falcon has no home for is reported with
  the real columns that could hold it (instructing time, block time, remarks), and you decide where
  it goes.
- **Writes are atomic.** One transaction for the batch: one bad row writes nothing unless `allow_partial`
  opts in, and then every row that did not land is named with its reason and the batch id.
- **Imported rows are ordinary flights afterwards.** They carry `updated_at` like anything you typed
  in, appear in the app, and push to Postgres on the next sync.

---

## How it stays yours

- **Read-only by default.** Writes happen only when you turn them on, with `--no-readonly` or
  `FALCON_READONLY=false`. An explicit flag wins over the environment variable. A read-only start
  can still leave `-wal` and `-shm` files beside the logbook, because SQLite maps them even for
  reads. When the directory cannot be written to at all (a read-only mount), the logbook is read
  through SQLite's `immutable=1` fallback instead: no locks and no side files, but no coordination
  with a live writer either, so keep the app closed and expect commits still in `-wal` to be
  missing.
- **Local and offline.** The server reads your SQLite file directly. It opens no sockets and sends
  nothing anywhere: no cloud, no account, no telemetry, and it never talks to a sync server.
- **Works with the app open or closed.**
- **Every write is logged** to an audit file next to your database, named after it
  (`<database-name>.mcp_audit.jsonl`), so you can see what changed and when.
- **Writes are checked before they land.** Flight times are capped at 525600 minutes (8760 hours)
  and counts at 10000, the same limits the app enforces; block times must be a real 24-hour clock
  time; day and night must add up to the total; and a zero total is refused, because the app would
  store it as a complete flight. New rows get the same UUID ids the app uses, so they sync. A
  refused write changes nothing. Every write tool takes `dry_run: true` to answer exactly what it
  would write and change nothing, and the roster import previews by default.
- **Free and open source.** Apache 2.0, same as the app.

---

## Install

You do not need to do this by hand. Paste the prompt below into your AI and let it do the work.

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
       Linux:   ~/Documents/Falcon/falcon_db.sqlite
       macOS:   ~/Library/Application Support/com.teamsuperpanda.falcon/Falcon/falcon_db.sqlite
       Windows: %APPDATA%\com.teamsuperpanda.falcon\Falcon\falcon_db.sqlite
     and any custom path stored in db_path.conf. That file lives in the app-support
     directory, e.g. ~/.local/share/com.teamsuperpanda.falcon on Linux,
     ~/Library/Application Support/com.teamsuperpanda.falcon on macOS,
     %APPDATA%\com.teamsuperpanda.falcon on Windows.
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

What happens next: it finds your database, asks whether you want reads alone or writes too, registers
itself, and reloads the client. Then ask it something small, like "how many hours did I fly last
year". If the number matches the app, you are set up.

---

## Clients and help

Supported: Claude Desktop, Claude Code, Codex, Cursor, and any other client that speaks MCP.

Something broken, or a question: open an issue at
[github.com/Falcon-Logbook/mcp/issues](https://github.com/Falcon-Logbook/mcp/issues).

---

## For developers

```bash
git clone https://github.com/Falcon-Logbook/mcp.git
cd mcp
dart pub get
dart compile exe bin/falcon_mcp.dart -o falcon_mcp
```

Run it with `./falcon_mcp --db /path/to/falcon_db.sqlite`, adding `--no-readonly` to allow writes.
The path resolves in this order: `--db`, `FALCON_DB_PATH`, the app's `db_path.conf`, the platform
default. A configured path that no longer exists is ignored. Transport is stdio; the binary is a
plain Dart console program, no Flutter. Tests run with `dart test` against a temporary database, so
your own logbook stays untouched.

### The logbook time zone (`FALCON_TZ`)

Flight dates are stored as the local midnight the Falcon app wrote in the time zone its device ran
in, so the server needs to know that zone to answer with the pilot's `YYYY-MM-DD` dates and day
windows. Set `FALCON_TZ` to it, as an IANA name such as `Australia/Sydney`, and every calendar date
(flight dates, date filters, expiry day counts, currency windows) is computed in that zone no matter
what zone the server itself runs in. When `FALCON_TZ` is unset the system zone applies, exactly the
behaviour the server had before the variable existed. An invalid IANA name stops the server at
startup, with the error on stderr and a non-zero exit, instead of silently falling back to another
zone and shifting every date.

Flight reads are shaped for context cost. `list_flights`, `search_flights`, `find_missing_times` and
the `falcon://flights` resource return a twelve-field summary per flight (id, date, route, flight
number, registration, crew name, total/day/night minutes, takeoffs, landings, simulator flag); add
`full: true` for every column at about four times the tokens. `get_flight` always returns the whole
row, because it is the detail call. Pages hold 20 rows by default and at most 200, and every paged
read returns `count`, `total`, `has_more` and `offset` so a client can page instead of inflating
`limit`. Responses are compact JSON; your client pretty-prints them if you want them readable.

The catalog is shaped the same way. `get_schema` returns table names with a column count; pass `table`
for one table's columns, and `detail: "full"` to add its default and primary-key columns. The
`falcon://schema` resource is the same table list, and no request returns the columns of every table at
once. The per-field notes for a flight are written once, on `create_flight`; `update_flight` takes the same
fields with the same types and limits and no repeated prose, and `falcon://conventions` is where the
meaning of a field lives. `get_recent_logs` returns timestamp, level, category and a message cut to 500
characters, 20 entries by default and 200 at most, and includes a stack trace only with
`include_stack: true`. A failed call returns `{"error", "field", "detail"}`, where `error` is a stable code
such as `unknown_field`, `invalid_value` or `not_found`, plus `tool` when an argument name was rejected;
raw database text and SQL are never passed through.

Apache License 2.0. Copyright 2026 Team Super Panda. Free to use, modify and redistribute, including
commercially. See [falconlogbook.com/license](https://falconlogbook.com/license) for the full terms.
The Falcon name and logo are trademarks, not licensed.
