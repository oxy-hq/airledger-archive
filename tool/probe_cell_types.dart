// ignore_for_file: avoid_print
//
// One-off probe to confirm whether numeric columns in `strength` are
// stored as Sheets numbers (good) or text-with-leading-apostrophe
// (the bug under investigation). Reads the top 5 data rows with
// valueRenderOption=UNFORMATTED_VALUE (which surfaces the actual cell
// type) and prints each cell's runtime type.

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

Future<void> main() async {
  const spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const tab = 'strength';
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

  // Header + the top 30 data rows so we can see how many lack IDs.
  final resp = await api.spreadsheets.values.get(
    spreadsheetId,
    "'$tab'!1:31",
    valueRenderOption: 'UNFORMATTED_VALUE',
  );
  final rows = resp.values ?? [];
  if (rows.isEmpty) {
    print('empty');
    exit(0);
  }
  final headers = rows[0].map((e) => e.toString()).toList();
  for (var r = 1; r < rows.length; r++) {
    print('--- row $r ---');
    final row = rows[r];
    for (var i = 0; i < row.length; i++) {
      final v = row[i];
      print('  ${headers[i]}: ${v.runtimeType} = ${jsonRepr(v)}');
    }
  }
  client.close();
}

String jsonRepr(Object? v) {
  if (v is String) return '"$v"';
  return v.toString();
}
