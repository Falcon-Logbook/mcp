import 'dart:io';

import 'package:args/args.dart';
import 'package:falcon_mcp/falcon_mcp.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('db', help: 'Path to falcon_db.sqlite')
    ..addFlag(
      'readonly',
      defaultsTo: true,
      help: 'Read-only mode (no writes). Set --no-readonly to enable writes.',
    )
    ..addFlag('version', negatable: false, help: 'Print version');

  final ArgResults result;
  try {
    result = parser.parse(args);
  } on FormatException catch (error) {
    stderr.writeln('falcon_mcp: ${error.message}\n\n${parser.usage}');
    exit(64);
  }

  if (result['version'] == true) {
    stdout.writeln('falcon_mcp $serverVersion');
    return;
  }

  // An explicit flag wins over FALCON_READONLY so `--no-readonly` always works.
  var readonly = result['readonly'] as bool;
  if (!result.wasParsed('readonly')) {
    final fromEnv = asBool(Platform.environment['FALCON_READONLY']);
    if (fromEnv != null) readonly = fromEnv;
  }

  final dbPath = resolveDbPath(override: result['db'] as String?);
  // stdout is the MCP channel; diagnostics go to stderr only.
  stderr.writeln(
    'falcon_mcp $serverVersion: db=$dbPath mode=${readonly ? 'readonly' : 'readwrite'}',
  );

  try {
    await runServer(dbPath, readonly: readonly);
  } on FalconDbException catch (error) {
    stderr.writeln('falcon_mcp: ${error.message}');
    exit(1);
  } catch (error) {
    stderr.writeln('falcon_mcp: failed to start with $dbPath: $error');
    exit(1);
  }
}
