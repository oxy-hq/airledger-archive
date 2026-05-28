// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

/// Prints all rows of a sheet tab (headers + last N data rows).
Future<void> main(List<String> args) async {
  final spreadsheetId = args.isNotEmpty
      ? args[0]
      : '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  final tab = args.length > 1 ? args[1] : 'strength';
  final lastN = args.length > 2 ? int.parse(args[2]) : 20;

  final home = Platform.environment['HOME']!;
  final keyJson = await File(
    '$home/.config/ledger/service-account.json',
  ).readAsString();
  final credentials = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(
    credentials,
    [sheets.SheetsApi.spreadsheetsScope],
  );
  final api = sheets.SheetsApi(client);
  final resp = await api.spreadsheets.values.get(spreadsheetId, "'$tab'");
  final values = resp.values ?? [];
  if (values.isEmpty) {
    print('empty');
    exit(0);
  }
  print('headers: ${values.first}');
  print('--- last $lastN of ${values.length - 1} rows ---');
  final start = (values.length - lastN).clamp(1, values.length);
  for (var i = start; i < values.length; i++) {
    print('row ${i + 1}: ${values[i]}');
  }
  exit(0);
}
