import 'dart:io';

import 'package:args/args.dart';
import 'package:falcon_mcp/falcon_mcp.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('db', help: 'Path to falcon_db.sqlite')
    ..addFlag('readonly',
        defaultsTo: true,
        help: 'Run in read-only mode (no writes). Set --no-readonly to enable writes.')
    ..addFlag('version', negatable: false, help: 'Print version');

  final result = parser.parse(args);
  if (result['version'] == true) {
    stdout.writeln('falcon_mcp 0.3.0');
    return;
  }

  final dbPath = resolveDbPath(override: result['db'] as String?);

  // Env override for readonly
  var readonly = result['readonly'] as bool;
  final envRo = Platform.environment['FALCON_READONLY'];
  if (envRo != null) {
    readonly = envRo.toLowerCase() != 'false' && envRo != '0';
  }

  try {
    await runServer(dbPath, readonly: readonly);
  } catch (e) {
    stderr.writeln('Failed to open database at $dbPath: $e');
    exit(1);
  }
}
