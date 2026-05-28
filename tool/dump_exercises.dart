// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

/// One-shot CLI: dumps distinct values from a single column of a sheet.
///
/// Usage:
///   dart run tool/dump_exercises.dart <spreadsheet_id> <tab_name> <column_header>
///
/// Defaults target the legacy fitness-logger spreadsheet's strength tab and
/// its "Exercise" column. Uses the same service account as the Flutter app.
Future<void> main(List<String> args) async {
  final spreadsheetId = args.isNotEmpty
      ? args[0]
      : '1BqV635hjq0XN9tTjVtH_Y6kI-NfPI1rdEvALtFlM7Nk';
  final tab = args.length > 1 ? args[1] : 'strength';
  final columnHeader = args.length > 2 ? args[2] : 'Exercise';

  final home = Platform.environment['HOME']!;
  final keyPath = '$home/.config/ledger/service-account.json';
  final keyJson = await File(keyPath).readAsString();
  final credentials = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(
    credentials,
    [sheets.SheetsApi.spreadsheetsScope],
  );
  final api = sheets.SheetsApi(client);

  final resp = await api.spreadsheets.values.get(spreadsheetId, "'$tab'");
  final values = resp.values ?? [];
  if (values.isEmpty) {
    print('empty sheet');
    exit(1);
  }
  final headers = values.first.map((e) => e.toString()).toList();
  final col = headers.indexOf(columnHeader);
  if (col < 0) {
    print('no column "$columnHeader" in $headers');
    exit(1);
  }
  final counts = <String, int>{};
  for (var i = 1; i < values.length; i++) {
    final row = values[i];
    if (row.length <= col) continue;
    final v = row[col].toString().trim();
    if (v.isEmpty) continue;
    counts[v] = (counts[v] ?? 0) + 1;
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  print('${sorted.length} distinct values in $tab.$columnHeader:\n');
  for (final e in sorted) {
    print('${e.value.toString().padLeft(4)}  ${e.key}');
  }
  exit(0);
}
