// ignore_for_file: avoid_print
// One-shot: append two BTWHSP set logs to the strength tab.
// dart run tool/add_btwhsp_logs.dart --confirm

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  if (!args.contains('--confirm')) {
    print('Pass --confirm to append rows.');
    exit(1);
  }
  const spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const tab = 'strength';
  const date = '2026-06-17';
  const dow = 'Wednesday';
  const ex = 'Back to Wall Handstand Pushup';
  const uuid = Uuid();

  final keyJson = await File(
    '${Platform.environment['HOME']}/.config/airledger/service-account.json',
  ).readAsString();
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(keyJson),
    [sheets.SheetsApi.spreadsheetsScope],
  );
  final api = sheets.SheetsApi(client);

  // Read headers to map column → field, so writes survive any column
  // reorder/addition in the sheet without breaking.
  final hdrResp =
      await api.spreadsheets.values.get(spreadsheetId, "'$tab'!1:1");
  final headers =
      (hdrResp.values?.first ?? const []).map((e) => e.toString()).toList();
  print('headers: $headers');

  Object cell(String header, Map<String, Object?> row) {
    final v = row[header];
    if (v == null) return '';
    return v;
  }

  Map<String, Object?> entry(String time, num reps) => {
        'id': uuid.v4(),
        'Date': date,
        'Day of Week': dow,
        'Exercise': ex,
        'Weight': 0,
        'Reps': reps,
        'Start Time': time,
        'Notes': '',
      };

  final entries = [
    entry('10:19:00 AM', 1),
    entry('10:41:00 AM', 4),
  ];

  final rows = entries
      .map((e) => headers.map((h) => cell(h, e)).toList())
      .toList();

  // Use append rather than update — the strength tab has data in column A, so
  // append lands the row at the bottom of the table (above any trailing
  // blanks). Sheets' RAW mode preserves number types.
  await api.spreadsheets.values.append(
    sheets.ValueRange(values: rows),
    spreadsheetId,
    "'$tab'!A1",
    valueInputOption: 'RAW',
    insertDataOption: 'INSERT_ROWS',
  );
  print('appended ${rows.length} rows to $tab');
  client.close();
}
