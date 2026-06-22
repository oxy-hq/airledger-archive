// ignore_for_file: avoid_print
//
// One-shot cleanup: the top N data rows in the `strength` tab were
// entered manually (engine writes were failing on the phone due to
// the deep-sleep token bug) and shipped with empty `id` cells.
//
// This scans the top of the tab, generates a v4 UUID for every row
// whose id column is blank, and writes them back in a single
// batchUpdate. Stops at the first row that already has an id —
// everything below is engine- or migration-stamped.

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:uuid/uuid.dart';

const _spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
const _tab = 'strength';
const _uuid = Uuid();

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final keyJson = await File(
    '$home/.config/ledger/service-account.json',
  ).readAsString();
  final creds = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(
    creds,
    [sheets.SheetsApi.spreadsheetsScope],
  );
  try {
    final api = sheets.SheetsApi(client);

    // Read the first column for the top 100 rows. Stop scanning at
    // the first row that has an id.
    final resp = await api.spreadsheets.values.get(
      _spreadsheetId,
      "'$_tab'!A1:A100",
    );
    final col = resp.values ?? [];
    if (col.isEmpty || col[0].isEmpty) {
      print('No header? aborting.');
      exit(1);
    }
    final missing = <int>[]; // 1-based sheet row indexes
    for (var i = 1; i < col.length; i++) {
      final cell = col[i];
      final value = cell.isEmpty ? '' : cell[0]?.toString() ?? '';
      if (value.isEmpty) {
        missing.add(i + 1); // sheet rows are 1-based, +1 because row 1 is header
      } else {
        // First row with an id ⇒ everything below is fine.
        break;
      }
    }
    if (missing.isEmpty) {
      print('No rows with empty id in the top section; nothing to do.');
      exit(0);
    }
    print('Backfilling ${missing.length} ids (rows ${missing.first}..${missing.last}):');

    // Build a values.batchUpdate that writes one cell per row.
    final data = <sheets.ValueRange>[];
    for (final row in missing) {
      final id = _uuid.v4();
      print('  row $row → $id');
      data.add(sheets.ValueRange(
        range: "'$_tab'!A$row",
        values: [
          [id],
        ],
      ));
    }
    await api.spreadsheets.values.batchUpdate(
      sheets.BatchUpdateValuesRequest(
        valueInputOption: 'RAW',
        data: data,
      ),
      _spreadsheetId,
    );
    print('✓ Done. ${missing.length} ids written.');
  } finally {
    client.close();
  }
}
