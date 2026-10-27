import 'dart:io';

import 'package:args/args.dart';
import 'package:falcon_mcp/falcon_mcp.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('db', help: 'Path to falcon_db.sqlite')
    ..addFlag('version', negatable: false, help: 'Print version');

  final result = parser.parse(args);
  if (result['version'] == true) {
    stdout.writeln('falcon_mcp 0.1.0');
    return;
  }

  final dbPath = resolveDbPath(override: result['db'] as String?);
  await runServer(dbPath);
}
