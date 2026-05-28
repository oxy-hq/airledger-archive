// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

/// Lists all tabs in a spreadsheet (id + title) so we can target the right one.
Future<void> main(List<String> args) async {
  final spreadsheetId = args.isNotEmpty
      ? args[0]
      : '1BqV635hjq0XN9tTjVtH_Y6kI-NfPI1rdEvALtFlM7Nk';
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
  final ss = await api.spreadsheets.get(spreadsheetId);
  for (final s in ss.sheets ?? <sheets.Sheet>[]) {
    final p = s.properties!;
    print('${p.sheetId}\t${p.title}');
  }
  exit(0);
}
