import 'dart:math';

import 'db.dart';
import 'util.dart';
import 'zone.dart';

/// The app's `CurrencyMetric` enum, in enum order.
const List<String> currencyMetrics = [
  'totalTime',
  'dayTime',
  'nightTime',
  'instrumentTime',
  'approachCount',
  'landingCount',
  'takeoffCount',
  'flightCount',
];

/// The app's `CurrencyPeriod` enum, in enum order. There is no rolling 90.
const List<String> currencyPeriods = [
  'calendarYear',
  'rolling365',
  'calendarMonth',
  'rolling30',
  'allTime',
];

/// The window used to answer about a metric that has no rule: a year is the
/// span every other currency answer is framed around.
const String defaultCurrencyPeriod = 'rolling365';

/// Whether [metric] is stored in minutes and reported in hours. The app divides
/// those four by 60, which is why a rule's threshold is hours.
bool isCurrencyTimeMetric(String metric) => const {
      'totalTime',
      'dayTime',
      'nightTime',
      'instrumentTime',
    }.contains(metric);

/// `hours` for a time metric, `count` for everything else.
String currencyMetricUnit(String metric) =>
    isCurrencyTimeMetric(metric) ? 'hours' : 'count';

/// Plain-English names, the app's own labels.
const Map<String, String> currencyMetricLabels = {
  'totalTime': 'total time',
  'dayTime': 'day time',
  'nightTime': 'night time',
  'instrumentTime': 'instrument time',
  'approachCount': 'approaches',
  'landingCount': 'landings',
  'takeoffCount': 'takeoffs',
  'flightCount': 'flights',
};

/// The period bounds `currency_dao.dart:218-238` uses: calendar arithmetic in
/// the logbook zone, never the server's own zone. An unknown period falls back
/// to all time, the same as the app's `switch` default.
///
/// [start] is inclusive and [end] is exclusive.
({DateTime start, DateTime end}) currencyBounds(String period, DateTime now) {
  final today = logbookDateOf(now);
  return switch (period) {
    'calendarYear' => (
        start: logbookDateAt(today.year, 1, 1),
        end: logbookDateAt(today.year + 1, 1, 1),
      ),
    'rolling365' => (
        start: logbookDateAt(today.year, today.month, today.day - 364),
        end: logbookDateAt(today.year, today.month, today.day + 1),
      ),
    'calendarMonth' => (
        start: logbookDateAt(today.year, today.month, 1),
        end: logbookDateAt(today.year, today.month + 1, 1),
      ),
    'rolling30' => (
        start: logbookDateAt(today.year, today.month, today.day - 29),
        end: logbookDateAt(today.year, today.month, today.day + 1),
      ),
    _ => (
        start: logbookDateAt(0, 1, 1),
        end: logbookDateAt(9999, 1, 1),
      ),
  };
}

/// One aggregate per metric, mirroring `_batchAggregates` (`currency_dao.dart`
/// 145-199). This map is the allowlist: a metric name never reaches SQL any
/// other way.
///
/// `flightCount` counts every row including drafts (`COUNT(*)`), and nothing
/// filters by owner, which is what the app does. `landingCount` and
/// `takeoffCount` are the two metrics the app throws on because its
/// `_validColumns` omits `landings` and `takeoffs`; the sums here are the ones
/// the form implies.
const Map<String, String> _aggregateSql = {
  'totalTime': 'COALESCE(SUM("total_time"), 0)',
  'dayTime': 'COALESCE(SUM("day_time"), 0)',
  'nightTime': 'COALESCE(SUM("night_time"), 0)',
  'instrumentTime': 'COALESCE(SUM(COALESCE("actual_instrument", 0) + '
      'COALESCE("simulated_instrument", 0) + '
      'COALESCE("ground_instrument", 0)), 0)',
  // Commas plus one per non-empty column, then summed: counting commas alone
  // undercounts by one per column, and a trailing comma counts twice, the same
  // as the app.
  'approachCount': 'COALESCE(SUM('
      'CASE WHEN "approaches2d" IS NOT NULL AND "approaches2d" != \'\' '
      'THEN LENGTH("approaches2d") - LENGTH(REPLACE("approaches2d", \',\', \'\')) + 1 '
      'ELSE 0 END + '
      'CASE WHEN "approaches3d" IS NOT NULL AND "approaches3d" != \'\' '
      'THEN LENGTH("approaches3d") - LENGTH(REPLACE("approaches3d", \',\', \'\')) + 1 '
      'ELSE 0 END'
      '), 0)',
  'landingCount': 'COALESCE(SUM("landings"), 0)',
  'takeoffCount': 'COALESCE(SUM("takeoffs"), 0)',
  'flightCount': 'COUNT(*)',
};

/// The raw sum for [metric] over `date >= start AND date < end`, in the stored
/// unit (minutes for a time metric). No owner filter and no draft filter, to
/// match the app.
int currencyRawTotal(
  FalconDb db,
  String metric, {
  required DateTime start,
  required DateTime end,
}) {
  final sql = _aggregateSql[metric];
  if (sql == null) {
    throw ArgumentError.value(metric, 'metric', 'not a currency metric');
  }
  final rows = db.query(
    'SELECT $sql AS value FROM flights WHERE "date" >= ? AND "date" < ?',
    [epochForDayStart(start), epochForDayStart(end)],
  );
  if (rows.isEmpty) return 0;
  return asInt(rows.first['value']) ?? 0;
}

/// [raw] as the app reports it: hours for a time metric, a count otherwise.
double currencyValue(int raw, String metric) =>
    isCurrencyTimeMetric(metric) ? raw / 60.0 : raw.toDouble();

/// The inclusive logbook-zone dates the numbers were summed over, or null for
/// all time, which has no bound. The SQL upper bound is exclusive, so the
/// echoed `to` is the last included day.
Map<String, dynamic>? currencyWindow(String period, DateTime now) {
  if (!currencyPeriods.contains(period) || period == 'allTime') return null;
  final bounds = currencyBounds(period, now);
  return {
    'from': formatCalendarDate(bounds.start),
    'to': formatCalendarDate(
        logbookDateAt(bounds.end.year, bounds.end.month, bounds.end.day - 1)),
  };
}

/// One stored rule plus the numbers the app's currency page derives from it
/// (`currency_dao.dart:112-143`).
///
/// `is_exceeded` keeps the app's meaning: it is true when the rule needs
/// attention, which for a `requirement` is being *below* the threshold. For a
/// requirement only `remaining` is set and it is how much is still needed; for
/// a limit only `over_by` is set and it is how far over. Both are 0 when the
/// condition is satisfied.
///
/// A rule whose `metric` is not one of [currencyMetrics] makes the app throw
/// (`CurrencyMetric.values.byName`). Here it is returned with an `error` so one
/// bad row does not fail every other rule.
Map<String, dynamic> computeCurrencyRule(
    FalconDb db, Map<String, dynamic> rule, DateTime now) {
  final metric = asText(rule['metric']) ?? '';
  final period = asText(rule['period']) ?? defaultCurrencyPeriod;
  final type = asText(rule['type']) ?? 'limit';
  final threshold = asDouble(rule['threshold']) ?? 0;
  final base = <String, dynamic>{
    'id': rule['id'],
    'title': rule['title'],
    'metric': metric,
    'period': period,
    'type': type,
    'threshold': threshold,
  };
  if (!currencyMetrics.contains(metric)) {
    return {
      ...base,
      'error': 'unknown metric "$metric"; '
          'supported: ${currencyMetrics.join(', ')}',
    };
  }

  final bounds = currencyBounds(period, now);
  final current = currencyValue(
      currencyRawTotal(db, metric, start: bounds.start, end: bounds.end),
      metric);
  final progress = threshold > 0 ? (current / threshold).clamp(0.0, 1.0) : 0.0;
  final isRequirement = type == 'requirement';
  final isExceeded = isRequirement ? current < threshold : current >= threshold;
  return {
    ...base,
    'current': _round2(current),
    'unit': currencyMetricUnit(metric),
    'remaining': isRequirement ? _round2(max(0.0, threshold - current)) : null,
    'over_by': isRequirement ? null : _round2(max(0.0, current - threshold)),
    'progress': _round2(progress),
    'is_exceeded': isExceeded,
    'rule_text': currencyRuleText(
      metric: metric,
      period: period,
      type: type,
      threshold: threshold,
    ),
    'window': currencyWindow(period, now),
  };
}

/// The honest answer when no rule covers [metric]: the raw total for [period]
/// and a note saying so, never an invented pass or fail.
Map<String, dynamic> currencyUnconfigured(
    FalconDb db, String metric, String period, DateTime now) {
  final bounds = currencyBounds(period, now);
  final current = currencyValue(
      currencyRawTotal(db, metric, start: bounds.start, end: bounds.end),
      metric);
  return {
    'metric': metric,
    'period': period,
    'current': _round2(current),
    'unit': currencyMetricUnit(metric),
    'window': currencyWindow(period, now),
    'note': 'no rule configured for this metric; raw total only, '
        'not a pass or fail',
  };
}

/// "at least 90 hours of night time in the last 365 days", the reading of one
/// stored row.
String currencyRuleText({
  required String metric,
  required String period,
  required String type,
  required double threshold,
}) {
  final bound = type == 'requirement' ? 'at least' : 'no more than';
  final amount = _number(threshold);
  final label = currencyMetricLabels[metric] ?? metric;
  final quantity = isCurrencyTimeMetric(metric)
      ? '$amount hours of $label'
      : '$amount $label';
  return '$bound $quantity ${_periodPhrase(period)}';
}

String _periodPhrase(String period) => switch (period) {
      'calendarYear' => 'this calendar year',
      'rolling365' => 'in the last 365 days',
      'calendarMonth' => 'this calendar month',
      'rolling30' => 'in the last 30 days',
      _ => 'over all time',
    };

/// Two decimals, the precision a currency rule is worth: `41.2`, not
/// `41.199999999999996`.
double _round2(double value) => (value * 100).roundToDouble() / 100;

/// [value] without a pointless `.0`: `90`, not `90.0`.
String _number(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';
