/// Route parsing, following the app's rule so a read answer can say which way a
/// flight went.
///
/// `flights.route` is free text. The app only treats it as a pair when it is
/// exactly `"AAA - BBB"` (`app/lib/database/utils/flight_time_utils.dart`,
/// `parseRouteString`): split on `" - "` (space, dash, space), exactly two
/// segments, each 3 or 4 characters, equal in length. Anything else, including
/// `"YSSY-NZQN"` and `"YSSY - NZQN - YBBN"`, is a description and has no
/// departure or arrival. Case is kept as written, because the app keeps it.
library;

/// The direction [route] describes, or null when the text is a description
/// rather than a pair.
({String departure, String arrival})? parseRoute(String? route) {
  if (route == null) return null;
  final parts = route.split(' - ');
  if (parts.length != 2) return null;
  final departure = parts[0].trim();
  final arrival = parts[1].trim();
  if (departure.length < 3 || departure.length > 4) return null;
  if (departure.length != arrival.length) return null;
  return (departure: departure, arrival: arrival);
}
