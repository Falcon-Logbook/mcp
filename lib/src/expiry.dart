import 'db.dart';
import 'util.dart';
import 'zone.dart';

/// Fallbacks when `expiry_settings` has no row, matching
/// `AppConstants.expiryGreenThreshold` and `expiryOrangeThreshold`. The app
/// inserts that row lazily on the first read of its expiries page, so a
/// database the app has not opened that page on has no row at all.
const int defaultExpiryGreen = 90;
const int defaultExpiryOrange = 30;

/// Whole calendar days from [today] to [dueDate], ignoring the time of day.
///
/// Both sides are reduced to their calendar date in the logbook zone, then
/// subtracted as dates: a due date tomorrow is 1, today is 0 and yesterday is
/// -1, and a DST change cannot turn a 30-day window into 29 days and 23 hours.
/// A stored `due_date` is not necessarily midnight: the app's add dialog seeds
/// it with `DateTime.now().add(365 days)`.
int daysUntilDue(DateTime dueDate, DateTime today) {
  final due = logbookDateOf(dueDate);
  final now = logbookDateOf(today);
  return DateTime.utc(due.year, due.month, due.day)
      .difference(DateTime.utc(now.year, now.month, now.day))
      .inDays;
}

/// Urgency of an expiry [days] from today: `red`, `orange` or `green`.
///
/// Mirrors `expiryStatusForDays`: red is anything below the orange threshold,
/// which includes today (0) and every overdue day, then orange below the green
/// threshold, green from there up.
String expiryStatusForDays(int days,
    {int? greenThreshold, int? orangeThreshold}) {
  final green = greenThreshold ?? defaultExpiryGreen;
  final orange = orangeThreshold ?? defaultExpiryOrange;
  if (days < orange) return 'red';
  if (days < green) return 'orange';
  return 'green';
}

/// The thresholds an expiry status was computed with, and where they came from:
/// `settings` when `expiry_settings` has a row, `defaults` when it does not.
typedef ExpiryThresholds = ({int green, int orange, String source});

/// The `expiry_settings` row a read should use, or null when the table has
/// none.
///
/// A read path must not insert it: the app's `ensureSingletonRow` does, and in
/// read-only mode the same insert raises SQLITE_READONLY and turns a read into a
/// failure. Two rows can exist after a sync (each device inserts its own uuid),
/// so a local row wins over a shared one and the newest `updated_at` wins among
/// equals. `get_settings` returns this same row, so the thresholds it reports
/// and the ones `list_expiries` computes with cannot disagree.
Map<String, dynamic>? readExpirySettingsRow(FalconDb db) {
  final columns = db.columnsOf('expiry_settings');
  if (columns.isEmpty) return null;
  final order = [
    if (columns.contains('updated_at')) 'updated_at DESC',
    if (columns.contains('id')) 'id',
  ];
  final local = columns.contains('owner_id')
      ? "(owner_id IS NULL OR owner_id = 'local')"
      : null;
  final rows = db.query(
    'SELECT * FROM expiry_settings'
    '${local == null ? '' : ' WHERE $local'}'
    '${order.isEmpty ? '' : ' ORDER BY ${order.join(', ')}'} LIMIT 1',
  );
  return rows.isEmpty ? null : rows.first;
}

/// Reads the green/orange thresholds from [readExpirySettingsRow].
ExpiryThresholds readExpiryThresholds(FalconDb db) {
  const fallback = (
    green: defaultExpiryGreen,
    orange: defaultExpiryOrange,
    source: 'defaults',
  );
  final columns = db.columnsOf('expiry_settings');
  if (columns.isEmpty ||
      !columns.contains('green_threshold') ||
      !columns.contains('orange_threshold')) {
    return fallback;
  }
  final row = readExpirySettingsRow(db);
  if (row == null) return fallback;
  return (
    green: asInt(row['green_threshold']) ?? defaultExpiryGreen,
    orange: asInt(row['orange_threshold']) ?? defaultExpiryOrange,
    source: 'settings',
  );
}
