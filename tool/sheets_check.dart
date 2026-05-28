// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ledger/services/schema_parser.dart';
import 'package:ledger/services/sheets_repository.dart';
import 'package:yaml/yaml.dart';

/// End-to-end smoke test that does NOT touch the UI. Runs as a CLI script,
/// reading the same external sources that tool/sync_assets.sh copies into the
/// Flutter app bundle.
///
///   1. Reads config + schemas from filesystem
///   2. Connects to the Google Sheets workbook as the service account
///   3. Calls ensureSheet for each view (creates tabs + writes headers)
///   4. Creates a probe record, lists today's records, deletes the probe
Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final config = loadYaml(
    await File('$home/.config/ledger/config.yaml').readAsString(),
  ) as YamlMap;
  final spreadsheetId = config['spreadsheet_id'] as String;
  final schemasDir = config['schemas_dir'] as String;
  final keyPath = config['service_account_key_path'] as String;

  print('config:');
  print('  schemas_dir: $schemasDir');
  print('  spreadsheet_id: $spreadsheetId');

  final viewFiles = Directory(schemasDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.view.yml'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final views = [for (final f in viewFiles) parseViewSchema(f.readAsStringSync())];
  print('\n${views.length} views loaded: ${views.map((v) => v.name).join(", ")}');

  final keyJson = await File(keyPath).readAsString();
  final repo = await SheetsRepository.connectFromKey(
    defaultSpreadsheetId: spreadsheetId,
    serviceAccountKeyJson: keyJson,
  );

  for (final view in views) {
    print('\n--- ensureSheet: ${view.name} ---');
    await repo.ensureSheet(view);
    print('OK: tab "${view.table}" ready');
  }

  // Probe write/read/delete on the meals view.
  final meals = views.firstWhere((v) => v.name == 'meals');
  print('\n--- probe write/read/delete on meals ---');

  final probe = await repo.create(meals, {
    'eaten_at': DateTime.now(),
    'meal': '[smoke test probe — safe to delete]',
    'meal_type': 'snack',
    'calories': 1,
  });
  print('created probe id=${probe['id']}');

  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final rows = await repo.list(meals, onDate: todayDate);
  print('listed ${rows.length} rows for today');

  await repo.delete(meals, probe);
  print('deleted probe');

  print('\nALL OK');
  exit(0);
}
