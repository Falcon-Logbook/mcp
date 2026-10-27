import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

bool _resolved = false;

/// Makes package:sqlite3 find the system SQLite when only the runtime soname is
/// installed, which is the usual Linux case (`libsqlite3.so.0` without the
/// `libsqlite3.so` development symlink).
///
/// Safe to call repeatedly; the first successful candidate wins.
void ensureSqliteLibrary() {
  if (_resolved) return;
  _resolved = true;
  for (final candidate in _candidates()) {
    try {
      DynamicLibrary.open(candidate);
    } catch (_) {
      continue;
    }
    open.overrideForAll(() => DynamicLibrary.open(candidate));
    return;
  }
}

List<String> _candidates() {
  if (Platform.isLinux) return const ['libsqlite3.so', 'libsqlite3.so.0'];
  if (Platform.isMacOS) {
    return const ['libsqlite3.dylib', '/usr/lib/libsqlite3.dylib'];
  }
  if (Platform.isWindows) return const ['sqlite3.dll', 'winsqlite3.dll'];
  return const [];
}
