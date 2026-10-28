/// Schema fixture copied from a Falcon database at user_version 19.
///
/// Only the tables the MCP tools touch are included, with the real column
/// definitions (drift's generated DDL) so tests exercise realistic SQL.
const int fixtureSchemaVersion = 19;

const List<String> fixtureStatements = [
  // aircraft
  'CREATE TABLE "aircraft" ("id" TEXT NOT NULL, "type" TEXT NOT NULL, "country_code" TEXT NOT NULL, "registration" TEXT NOT NULL, "multi_engine" INTEGER NOT NULL DEFAULT 0 CHECK ("multi_engine" IN (0, 1)), "ifr" INTEGER NOT NULL DEFAULT 0 CHECK ("ifr" IN (0, 1)), "complex" INTEGER NOT NULL DEFAULT 0 CHECK ("complex" IN (0, 1)), "pressurised" INTEGER NOT NULL DEFAULT 0 CHECK ("pressurised" IN (0, 1)), "tailwheel" INTEGER NOT NULL DEFAULT 0 CHECK ("tailwheel" IN (0, 1)), "simulator" INTEGER NOT NULL DEFAULT 0 CHECK ("simulator" IN (0, 1)), "helicopter" INTEGER NOT NULL DEFAULT 0 CHECK ("helicopter" IN (0, 1)), "float_plane" INTEGER NOT NULL DEFAULT 0 CHECK ("float_plane" IN (0, 1)), "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "owner_id" TEXT NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // airports
  'CREATE TABLE "airports" ("icao" TEXT NOT NULL, "iata" TEXT NULL, "name" TEXT NOT NULL, "city" TEXT NULL, "subd" TEXT NULL, "country" TEXT NULL, "lat" REAL NOT NULL, "lon" REAL NOT NULL, "elevation" INTEGER NULL, "tz" TEXT NULL, PRIMARY KEY ("icao"))',
  // app_settings
  'CREATE TABLE "app_settings" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "storage_mode" TEXT NULL, "theme_mode" TEXT NOT NULL DEFAULT \'system\', "database_path" TEXT NULL, "backups_to_keep" INTEGER NOT NULL DEFAULT 3, "backup_frequency_days" INTEGER NOT NULL DEFAULT 7, "last_backed_up" INTEGER NULL, "accent_color" TEXT NOT NULL DEFAULT \'blue\', "font_family" TEXT NOT NULL DEFAULT \'inter\', "theme_key" TEXT NOT NULL DEFAULT \'falcon_default\', "oled_dark_mode" INTEGER NOT NULL DEFAULT 0 CHECK ("oled_dark_mode" IN (0, 1)), "has_seen_storage_explanation" INTEGER NOT NULL DEFAULT 0 CHECK ("has_seen_storage_explanation" IN (0, 1)), "background_launch_pending" INTEGER NOT NULL DEFAULT 0 CHECK ("background_launch_pending" IN (0, 1)), "hangar_doors_splash" INTEGER NOT NULL DEFAULT 1 CHECK ("hangar_doors_splash" IN (0, 1)), "created_at" INTEGER NULL, "updated_at" INTEGER NULL)',
  // crew_members
  'CREATE TABLE "crew_members" ("id" TEXT NOT NULL, "name" TEXT NOT NULL, "first_name" TEXT NOT NULL, "last_name" TEXT NOT NULL, "note" TEXT NULL, "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "owner_id" TEXT NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // custom_airports
  'CREATE TABLE "custom_airports" ("id" TEXT NOT NULL, "icao" TEXT NULL, "iata" TEXT NULL, "name" TEXT NOT NULL, "city" TEXT NULL, "subd" TEXT NULL, "country" TEXT NULL, "lat" REAL NULL, "lon" REAL NULL, "elevation" INTEGER NULL, "tz" TEXT NULL, "owner_id" TEXT NULL, "created_at" INTEGER NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // expiries
  'CREATE TABLE "expiries" ("id" TEXT NOT NULL, "name" TEXT NOT NULL, "due_date" INTEGER NOT NULL, "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "owner_id" TEXT NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // expiry_settings
  'CREATE TABLE "expiry_settings" ("id" TEXT NOT NULL, "green_threshold" INTEGER NOT NULL DEFAULT 90, "orange_threshold" INTEGER NOT NULL DEFAULT 30, "show_sidebar_badge" INTEGER NOT NULL DEFAULT 1 CHECK ("show_sidebar_badge" IN (0, 1)), "owner_id" TEXT NULL, "created_at" INTEGER NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // flights
  'CREATE TABLE "flights" ("id" TEXT NOT NULL, "date" INTEGER NOT NULL, "day_order" INTEGER NOT NULL DEFAULT 0, "aircraft_id" TEXT NULL REFERENCES aircraft (id) ON DELETE SET NULL, "flight_type" TEXT NULL, "crew_role" TEXT NULL, "crew_member_id" TEXT NULL REFERENCES crew_members (id) ON DELETE SET NULL, "crew_members_name" TEXT NULL, "route" TEXT NULL, "route_id" INTEGER NULL, "flight_number" TEXT NULL, "aircraft_registration" TEXT NULL, "total_time" INTEGER NULL, "day_time" INTEGER NULL, "night_time" INTEGER NULL, "calc_time_mode" TEXT NULL, "time_start" TEXT NULL, "time_stop" TEXT NULL, "hobbs_start" REAL NULL, "hobbs_stop" REAL NULL, "actual_instrument" INTEGER NULL, "simulated_instrument" INTEGER NULL, "ground_instrument" INTEGER NULL, "approaches2d" TEXT NULL, "approaches3d" TEXT NULL, "approach_details" TEXT NULL, "takeoffs" INTEGER NULL, "landings" INTEGER NULL, "takeoff_day" INTEGER NULL, "takeoff_night" INTEGER NULL, "landing_day" INTEGER NULL, "landing_night" INTEGER NULL, "water_takeoffs" INTEGER NULL, "water_landings" INTEGER NULL, "custom_columns" TEXT NULL, "is_simulator" INTEGER NOT NULL DEFAULT 0 CHECK ("is_simulator" IN (0, 1)), "is_ifr" INTEGER NULL CHECK ("is_ifr" IN (0, 1)), "icus_day_time" INTEGER NULL, "icus_night_time" INTEGER NULL, "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "owner_id" TEXT NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // flights_settings
  'CREATE TABLE "flights_settings" ("id" TEXT NOT NULL, "pilot_name" TEXT NOT NULL DEFAULT \'Self\', "default_flight_type" TEXT NOT NULL DEFAULT \'route\', "date_format" TEXT NOT NULL DEFAULT \'dd mmm yyyy\', "flight_time_format" TEXT NOT NULL DEFAULT \'decimal1\', "calculate_time_mode" TEXT NOT NULL DEFAULT \'utc\', "logbook_country" TEXT NULL, "show_summary_card" INTEGER NOT NULL DEFAULT 1 CHECK ("show_summary_card" IN (0, 1)), "show_day_night" INTEGER NOT NULL DEFAULT 0 CHECK ("show_day_night" IN (0, 1)), "show_routes_in_wizard" INTEGER NOT NULL DEFAULT 1 CHECK ("show_routes_in_wizard" IN (0, 1)), "show_logbook_view" INTEGER NOT NULL DEFAULT 0 CHECK ("show_logbook_view" IN (0, 1)), "show_flight_number" INTEGER NOT NULL DEFAULT 1 CHECK ("show_flight_number" IN (0, 1)), "owner_id" TEXT NULL, "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // general_settings
  'CREATE TABLE "general_settings" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "startup_tab" TEXT NOT NULL DEFAULT \'dashboard\', "language" TEXT NOT NULL DEFAULT \'system\', "airports_csv_hash" TEXT NULL, "coordinates_format" TEXT NOT NULL DEFAULT \'dd\', "dashboard_widgets_json" TEXT NULL, "created_at" INTEGER NULL, "updated_at" INTEGER NULL)',
  // aircraft_settings
  'CREATE TABLE "aircraft_settings" ("id" TEXT NOT NULL, "show_properties" INTEGER NOT NULL DEFAULT 1 CHECK ("show_properties" IN (0, 1)), "show_multi_engine" INTEGER NOT NULL DEFAULT 1 CHECK ("show_multi_engine" IN (0, 1)), "show_ifr" INTEGER NOT NULL DEFAULT 1 CHECK ("show_ifr" IN (0, 1)), "show_complex" INTEGER NOT NULL DEFAULT 1 CHECK ("show_complex" IN (0, 1)), "show_pressurised" INTEGER NOT NULL DEFAULT 1 CHECK ("show_pressurised" IN (0, 1)), "show_tailwheel" INTEGER NOT NULL DEFAULT 1 CHECK ("show_tailwheel" IN (0, 1)), "show_simulator" INTEGER NOT NULL DEFAULT 1 CHECK ("show_simulator" IN (0, 1)), "show_helicopter" INTEGER NOT NULL DEFAULT 1 CHECK ("show_helicopter" IN (0, 1)), "show_float_plane" INTEGER NOT NULL DEFAULT 1 CHECK ("show_float_plane" IN (0, 1)), "sort_order" TEXT NOT NULL DEFAULT \'registration\', "sort_direction" TEXT NOT NULL DEFAULT \'ascending\', "archive_enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("archive_enabled" IN (0, 1)), "show_table_view" INTEGER NOT NULL DEFAULT 0 CHECK ("show_table_view" IN (0, 1)), "default_country_code" TEXT NOT NULL DEFAULT \'\', "owner_id" TEXT NULL, "created_at" INTEGER NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // crew_settings
  'CREATE TABLE "crew_settings" ("id" TEXT NOT NULL, "name_display_format" TEXT NOT NULL DEFAULT \'firstLast\', "sort_order" TEXT NOT NULL DEFAULT \'firstLast\', "show_badge" INTEGER NOT NULL DEFAULT 1 CHECK ("show_badge" IN (0, 1)), "first_name_initial_only" INTEGER NOT NULL DEFAULT 0 CHECK ("first_name_initial_only" IN (0, 1)), "nickname_only" INTEGER NOT NULL DEFAULT 0 CHECK ("nickname_only" IN (0, 1)), "archive_enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("archive_enabled" IN (0, 1)), "show_table_view" INTEGER NOT NULL DEFAULT 0 CHECK ("show_table_view" IN (0, 1)), "owner_id" TEXT NULL, "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // routes_settings
  'CREATE TABLE "routes_settings" ("id" TEXT NOT NULL, "show_table_view" INTEGER NOT NULL DEFAULT 0 CHECK ("show_table_view" IN (0, 1)), "owner_id" TEXT NULL, "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  // sidebar_settings
  'CREATE TABLE "sidebar_settings" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "show_dashboard" INTEGER NOT NULL DEFAULT 1 CHECK ("show_dashboard" IN (0, 1)), "show_expiries" INTEGER NOT NULL DEFAULT 1 CHECK ("show_expiries" IN (0, 1)), "show_reports" INTEGER NOT NULL DEFAULT 1 CHECK ("show_reports" IN (0, 1)), "show_airports" INTEGER NOT NULL DEFAULT 1 CHECK ("show_airports" IN (0, 1)), "show_currency" INTEGER NOT NULL DEFAULT 1 CHECK ("show_currency" IN (0, 1)), "show_tools" INTEGER NOT NULL DEFAULT 1 CHECK ("show_tools" IN (0, 1)), "position" TEXT NOT NULL DEFAULT \'left\', "expiry_label" TEXT NULL, "reports_label" TEXT NULL, "airports_label" TEXT NULL, "currency_label" TEXT NULL, "tools_label" TEXT NULL, "dashboard_label" TEXT NULL, "flights_label" TEXT NULL, "aircraft_label" TEXT NULL, "crew_label" TEXT NULL, "dashboard_icon" TEXT NULL, "flights_icon" TEXT NULL, "aircraft_icon" TEXT NULL, "crew_icon" TEXT NULL, "expiry_icon" TEXT NULL, "currency_icon" TEXT NULL, "reports_icon" TEXT NULL, "airports_icon" TEXT NULL, "tools_icon" TEXT NULL, "show_routes" INTEGER NOT NULL DEFAULT 1 CHECK ("show_routes" IN (0, 1)), "routes_label" TEXT NULL, "routes_icon" TEXT NULL, "settings_icon" TEXT NULL, "item_order" TEXT NULL, "expanded_on_launch" INTEGER NOT NULL DEFAULT 1 CHECK ("expanded_on_launch" IN (0, 1)), "created_at" INTEGER NULL, "updated_at" INTEGER NULL)',
  // log_entries
  'CREATE TABLE "log_entries" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "timestamp" INTEGER NOT NULL, "category" TEXT NOT NULL, "level" TEXT NOT NULL, "message" TEXT NOT NULL, "details" TEXT NULL, "stack_trace" TEXT NULL)',
  // saved_routes
  'CREATE TABLE "saved_routes" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "flight_number" TEXT NOT NULL, "departure_icao" TEXT NOT NULL, "arrival_icao" TEXT NOT NULL, "distance_nm" REAL NULL, "owner_id" TEXT NULL, "created_at" INTEGER NOT NULL DEFAULT (CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)), "updated_at" INTEGER NULL)',
  // sync_deletions
  'CREATE TABLE "sync_deletions" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "sync_table" TEXT NOT NULL, "row_id" TEXT NOT NULL, "provider" TEXT NOT NULL, "created_at" INTEGER NOT NULL)',
  // sync_state
  'CREATE TABLE "sync_state" ("sync_table" TEXT NOT NULL, "provider" TEXT NOT NULL, "last_push_at" TEXT NULL, "last_pull_at" TEXT NULL, "last_push_count" INTEGER NOT NULL DEFAULT 0, "last_pull_count" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("sync_table", "provider"))',
  // user_currency
  'CREATE TABLE "user_currency" ("id" TEXT NOT NULL, "title" TEXT NOT NULL, "metric" TEXT NOT NULL, "period" TEXT NOT NULL, "threshold" REAL NOT NULL, "sort_order" INTEGER NOT NULL, "is_active" INTEGER NOT NULL DEFAULT 1 CHECK ("is_active" IN (0, 1)), "type" TEXT NOT NULL DEFAULT \'limit\', "owner_id" TEXT NULL, "created_at" INTEGER NULL, "updated_at" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE INDEX idx_crew_name ON crew_members (name)',
  'CREATE INDEX idx_crew_first_name ON crew_members (first_name)',
  'CREATE INDEX idx_crew_last_name ON crew_members (last_name)',
  'CREATE INDEX idx_aircraft_registration ON aircraft (registration)',
  'CREATE INDEX idx_aircraft_type ON aircraft (type)',
  'CREATE INDEX idx_flights_date ON flights (date)',
  'CREATE INDEX idx_flights_date_day_order ON flights (date, day_order)',
  'CREATE INDEX idx_flights_aircraft ON flights (aircraft_id)',
  'CREATE INDEX idx_flights_crew ON flights (crew_member_id)',
  'CREATE INDEX idx_flights_registration ON flights (aircraft_registration)',
  'CREATE INDEX idx_flights_type ON flights (flight_type)',
  'CREATE INDEX idx_flights_ifr ON flights (is_ifr)',
  'CREATE INDEX idx_flights_simulator ON flights (is_simulator)',
  'CREATE INDEX idx_flights_date_crew ON flights (date, crew_member_id)',
  'CREATE INDEX idx_flights_date_aircraft ON flights (date, aircraft_id)',
  'CREATE INDEX idx_flights_owner_updated ON flights (owner_id, updated_at)',
  'CREATE INDEX idx_flights_route ON flights (route_id)',
  'CREATE INDEX idx_expiries_due_date ON expiries (due_date)',
  'CREATE INDEX airports_name_idx ON airports (name)',
  'CREATE INDEX airports_country_idx ON airports (country)',
  'CREATE INDEX airports_iata_idx ON airports (iata)',
  'CREATE INDEX idx_log_entries_timestamp ON log_entries (timestamp)',
  'CREATE INDEX idx_log_entries_category ON log_entries (category)',
  'CREATE INDEX idx_log_entries_level ON log_entries (level)',
  'CREATE INDEX ix_sync_deletions_provider ON sync_deletions (sync_table, provider)',
  'CREATE UNIQUE INDEX uq_aircraft_registration ON aircraft(country_code, registration)',
];
