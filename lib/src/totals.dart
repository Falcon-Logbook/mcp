import 'db.dart';
import 'util.dart';

/// The groupings `entity_totals` aggregates by, in the order the catalog lists
/// them. There is no `route`: the app has no route-pair accessor, so grouping by
/// route pair would be behaviour invented here rather than reproduced from the
/// app.
const List<String> entityTotalDimensions = [
  'aircraft',
  'crew',
  'type',
  'registration',
];

/// The orderings `entity_totals` accepts: the two numbers it reports, or the
/// label. Both numbers order descending and the label alphabetically, so the
/// same logbook always answers in the same order.
const List<String> entityTotalSorts = ['minutes', 'flights_complete', 'label'];

/// The default ordering: the minutes sum, the unit every other duration in this
/// server is reported in.
const String defaultEntityTotalSort = 'minutes';

/// One grouping: the column that keys it, the columns and joins the app's
/// matching accessor uses, and the row it returns.
class _Dimension {
  const _Dimension({
    required this.key,
    required this.join,
    required this.groupBy,
    required this.conditions,
    required this.row,
    required this.tiebreak,
    required this.label,
    this.select = '',
  });

  /// The grouped column: what the rows are keyed on.
  final String key;

  /// The dimension's own selected columns, each `expr AS name`, or empty.
  final String select;
  final String join;
  final String groupBy;

  /// What makes a row belong to this grouping at all. The app drops a missing
  /// link and an empty label, so a group is never keyed on an empty string; a
  /// crew name, unlike the key, may be null once the member is gone.
  final List<String> conditions;

  /// [key] plus this dimension's columns, as the tool returns them.
  final Map<String, dynamic> Function(Map<String, dynamic> row) row;

  /// The returned row's id, the deterministic tiebreak when the sorted field
  /// ties (two aircraft flown for exactly the same minutes).
  final String tiebreak;

  /// The returned row's display name, what the label sort orders by. Null when
  /// the entity behind the group is gone: a deleted aircraft row leaves the
  /// flight's link dangling, and a deleted crew member leaves no name.
  final String? Function(Map<String, dynamic> row) label;
}

final Map<String, _Dimension> _dimensions = {
  // getFlightTimeTotalsForAircraft and getFlightCountForAircraft both key on
  // flights.aircraft_id, so aircraft hours and aircraft counts agree here.
  'aircraft': _Dimension(
    key: 'flights.aircraft_id',
    select: 'aircraft.country_code AS country_code, '
        'aircraft.registration AS registration, '
        'aircraft.type AS aircraft_type, ',
    join: 'LEFT JOIN aircraft ON aircraft.id = flights.aircraft_id',
    groupBy: 'flights.aircraft_id, aircraft.country_code, '
        'aircraft.registration, aircraft.type',
    conditions: ['flights.aircraft_id IS NOT NULL'],
    row: (row) => {
      'aircraft_id': row['entity_key'],
      'registration': displayRegistration(
          row['country_code'] as String?, row['registration'] as String?),
      'aircraft_type': row['aircraft_type'],
    },
    tiebreak: 'aircraft_id',
    label: (row) => row['registration'] as String?,
  ),
  // getAllCrewFlightCounts and getMostFlownCrew key on flights.crew_member_id.
  // A name is not required: a member deleted since the flight loses the link but
  // the flight still counts.
  'crew': _Dimension(
    key: 'flights.crew_member_id',
    select: 'crew_members.name AS crew_name, ',
    join: 'LEFT JOIN crew_members ON crew_members.id = flights.crew_member_id',
    groupBy: 'flights.crew_member_id, crew_members.name',
    conditions: [
      'flights.crew_member_id IS NOT NULL',
      "flights.crew_member_id != ''",
    ],
    row: (row) => {
      'crew_member_id': row['entity_key'],
      'name': row['crew_name'],
    },
    tiebreak: 'crew_member_id',
    label: (row) => row['name'] as String?,
  ),
  // getMostFlownTypes joins aircraft and groups on its type, so a flight with
  // only registration text has no type to group under.
  'type': _Dimension(
    key: 'aircraft.type',
    select: 'aircraft.type AS aircraft_type, ',
    join: 'LEFT JOIN aircraft ON aircraft.id = flights.aircraft_id',
    groupBy: 'aircraft.type',
    conditions: ["aircraft.type IS NOT NULL", "aircraft.type != ''"],
    row: (row) => {'aircraft_type': row['entity_key']},
    tiebreak: 'aircraft_type',
    label: (row) => row['aircraft_type'] as String?,
  ),
  // getMostFlownRegistrations groups on the text column, not the link, so an
  // import with no aircraft rows still reports.
  'registration': _Dimension(
    key: 'flights.aircraft_registration',
    join: '',
    groupBy: 'flights.aircraft_registration',
    conditions: [
      'flights.aircraft_registration IS NOT NULL',
      "flights.aircraft_registration != ''",
    ],
    row: (row) => {'aircraft_registration': row['entity_key']},
    tiebreak: 'aircraft_registration',
    label: (row) => row['aircraft_registration'] as String?,
  ),
};

/// The aggregates for one [type] — one page of them, starting at [offset] — and
/// how many groups matched before [limit] and [offset] were applied.
///
/// Both numbers cover the same rows: a flight is counted and summed only when it
/// has a total time, which is the filter `getFlightTimeTotalsForAircraft`,
/// `getFlightCountForAircraft` and `_getGroupedFlightCounts` all apply, so a
/// draft appears in neither and an entity with no complete flight is not listed.
/// The count is named `flights_complete` because that is what it is, the same
/// key `logbook_stats` uses for the same number; a bare `flights` there counts
/// every row including drafts.
///
/// [ownerClause] is the caller's local-rows clause, written against the `flights`
/// table and empty when shared rows are wanted. The app applies it to every one
/// of these accessors (`local_only.dart`).
///
/// [includeSimulator] is the app's behaviour when true: it counts simulator
/// flights in every one of these totals.
({List<Map<String, dynamic>> entities, int total}) readEntityTotals(
  FalconDb db, {
  required String type,
  required String sort,
  required int limit,
  required int offset,
  required bool includeSimulator,
  required String ownerClause,
}) {
  final spec = _dimensions[type];
  if (spec == null) {
    throw ArgumentError.value(type, 'type', 'not an entity total dimension');
  }

  final where = <String>[
    'flights.total_time IS NOT NULL',
    ...spec.conditions,
    if (!includeSimulator) 'flights.is_simulator = 0',
    if (ownerClause.isNotEmpty) ownerClause,
  ];
  // Every group at once, not a page: a fleet is hundreds of groups, not the
  // flight table behind them. Ordering and slicing happen in Dart so the label
  // sort can use the label the row actually returns — for aircraft that is
  // [displayRegistration]'s join of two columns, which SQL could repeat but
  // then the displayed and the ordered form would be two rules to keep equal.
  final rows = db.query(
      'SELECT ${spec.key} AS entity_key, ${spec.select}'
      'COALESCE(SUM(flights.total_time), 0) AS minutes, '
      'COUNT(*) AS flight_count '
      'FROM flights${spec.join.isEmpty ? '' : ' ${spec.join}'} '
      'WHERE ${where.join(' AND ')} '
      'GROUP BY ${spec.groupBy}');
  final entities = [
    for (final row in rows)
      {
        ...spec.row(row),
        'minutes': row['minutes'],
        'flights_complete': row['flight_count'],
      },
  ];
  entities.sort((a, b) => _compare(a, b, spec, sort));
  return (
    entities: entities.skip(offset).take(limit).toList(),
    total: entities.length,
  );
}

/// The ordering one dimension is sorted by: the sorted field, then the
/// dimension's own id, so the same logbook always answers in the same order.
int _compare(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
  _Dimension spec,
  String sort,
) {
  switch (sort) {
    case 'flights_complete':
      final byCount = (b['flights_complete'] as int)
          .compareTo(a['flights_complete'] as int);
      if (byCount != 0) return byCount;
    case 'label':
      final byLabel = _compareLabels(a, b, spec);
      if (byLabel != 0) return byLabel;
    default:
      final byMinutes = (b['minutes'] as int).compareTo(a['minutes'] as int);
      if (byMinutes != 0) return byMinutes;
  }
  return '${a[spec.tiebreak]}'.compareTo('${b[spec.tiebreak]}');
}

/// Label order, bytewise like SQLite's own collation elsewhere in this server,
/// with a group whose entity is gone at the end rather than the top.
int _compareLabels(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
  _Dimension spec,
) {
  final aLabel = spec.label(a);
  final bLabel = spec.label(b);
  if (aLabel == null || bLabel == null) {
    if (aLabel == null && bLabel == null) return 0;
    return aLabel == null ? 1 : -1;
  }
  return aLabel.compareTo(bLabel);
}
