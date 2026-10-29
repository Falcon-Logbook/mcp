import 'dart:io';

// latest_all rather than latest: the smaller file carries only canonical zone
// names, so legitimate IANA links such as UTC, GMT or Australia/Canberra would
// be refused in FALCON_TZ. This one knows every name the tz database does.
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Thrown when the logbook zone cannot be used: the name `FALCON_TZ` carries
/// is not in the IANA database. The CLI prints the message and refuses to
/// start, because silently falling back to the system zone would move every
/// calendar date the server answers with.
class LogbookZoneException implements Exception {
  LogbookZoneException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The system zone as a [tz.Location]: the offset at any instant is the host
/// process's own, read from [DateTime], so with no `FALCON_TZ` every helper
/// does exactly what local [DateTime] arithmetic did before the logbook zone
/// existed. Transition boundaries are not modelled (the host decides the
/// offset for each instant), so a lookup answers one instant at a time.
class _SystemLocation extends tz.Location {
  _SystemLocation()
      : super(
          'system',
          const [tz.minTime],
          const [0],
          const [tz.TimeZone(Duration.zero, isDst: false, abbreviation: 'UTC')],
        );

  @override
  tz.TzInstant lookupTimeZone(int millisecondsSinceEpoch) {
    final local = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
    // dart:io exposes the offset and the abbreviation but not the DST flag;
    // nothing reads it here, only the offset drives the arithmetic.
    return tz.TzInstant(
      tz.TimeZone(local.timeZoneOffset,
          isDst: false, abbreviation: local.timeZoneName),
      tz.minTime,
      tz.maxTime,
    );
  }
}

bool _databaseReady = false;
final _SystemLocation _system = _SystemLocation();
tz.Location? _configured;

/// Loads the IANA time zone database once. Idempotent, and called by every
/// entry point below, so no date is ever built before the database exists.
void ensureTimezoneDatabase() {
  if (_databaseReady) return;
  tzdata.initializeTimeZones();
  _databaseReady = true;
}

/// The zone every calendar date in the logbook is read and written in.
///
/// This is whatever [configureLogbookZone] resolved: the `FALCON_TZ` IANA name
/// when it is set, otherwise the system zone. Library code and in-process
/// tests can use it without configuring anything first; only the CLI decides
/// the zone from the environment.
tz.Location get logbookZone {
  ensureTimezoneDatabase();
  return _configured ??= _defaultZone();
}

/// The system zone, registered as [tz.local] so an unset `FALCON_TZ` really
/// is the zone the host process runs in.
tz.Location _defaultZone() {
  tz.setLocalLocation(_system);
  return tz.local;
}

/// Resolves the logbook zone from [name], an IANA time zone name such as
/// `Australia/Sydney`. Null, blank or whitespace means the system zone, the
/// behaviour the server had before `FALCON_TZ` existed.
///
/// Throws [LogbookZoneException] when the name is not in the IANA database,
/// naming `FALCON_TZ`, the rejected value and the underlying error. A wrong
/// zone must stop the server, never silently shift every calendar date.
tz.Location configureLogbookZone({String? name}) {
  ensureTimezoneDatabase();
  final text = (name ?? '').trim();
  if (text.isEmpty) return _configured = _defaultZone();
  final tz.Location location;
  try {
    location = tz.getLocation(text);
  } catch (error) {
    throw LogbookZoneException(
      'FALCON_TZ "$text" is not a valid IANA time zone name: $error',
    );
  }
  return _configured = location;
}

/// [configureLogbookZone] for the `FALCON_TZ` environment variable.
tz.Location configureLogbookZoneFromEnvironment() =>
    configureLogbookZone(name: Platform.environment['FALCON_TZ']);

/// The current instant as a wall clock in the logbook zone. Every "today" or
/// "now" that decides a calendar day comes from here, never from
/// [DateTime.now], so the answer does not move with the server's own zone.
tz.TZDateTime nowInLogbookZone() => tz.TZDateTime.now(logbookZone);

/// Logbook-zone midnight at the start of the calendar date `year-month-day`.
///
/// Field values outside their range roll over the way [DateTime] rolls them
/// over (month 13 is next January), which callers rely on for day arithmetic;
/// a caller that must reject a rolled-over date checks the returned fields.
tz.TZDateTime logbookDateAt(int year, int month, int day) {
  final zone = logbookZone;
  if (identical(zone, _system)) {
    // The host resolves its own midnight: with no FALCON_TZ this is exactly
    // the DateTime(year, month, day) the pre-zone code built, down to how the
    // host resolves a midnight a DST change skipped.
    return tz.TZDateTime.from(DateTime(year, month, day), zone);
  }
  return tz.TZDateTime(zone, year, month, day);
}

/// The instant [seconds] unix epoch seconds after the epoch, shown as a wall
/// clock in the logbook zone. The time of day is kept; take the fields for the
/// calendar date.
tz.TZDateTime logbookDateFromEpoch(int seconds) =>
    tz.TZDateTime.fromMillisecondsSinceEpoch(logbookZone, seconds * 1000);

/// [value]'s own `year`, `month` and `day` fields rebuilt in the logbook
/// zone: the rule for "a [DateTime] means its Y-M-D in the logbook zone",
/// used wherever stored dates are compared field by field. A caller that
/// holds an instant rather than a date uses [logbookDateFromEpoch] instead.
tz.TZDateTime logbookDateOf(DateTime value) =>
    logbookDateAt(value.year, value.month, value.day);
