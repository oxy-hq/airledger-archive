// ignore_for_file: avoid_print
//
// One-shot cleanup: rows that the engine wrote with the old RAW
// valueInputOption have their Date / Start Time / End Time cells
// stored as text strings instead of Sheets' native date/time types.
// In the UI those text cells display with a leading apostrophe (`'`).
//
// This walks the strength tab, finds every row where one of those
// columns is currently a String, and re-writes it via batchUpdate
// with valueInputOption=USER_ENTERED so Sheets parses each value
// like a user typed it — converting "2026-06-20" → date,
// "8:55:00 PM" → time, etc.
//
// Columns we touch (header → column letter):
//   Date         → B
//   Start Time   → G
//   End Time     → K
//
// Other cells are untouched.

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

const _spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
const _tab = 'strength';

// Sheet columns (1-based for sheet ranges → letters for A1 notation).
const _cols = <String, String>{
  'Date': 'B',
  'Start Time': 'G',
  'End Time': 'K',
};

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

    final fixes = <sheets.ValueRange>[];
    for (final entry in _cols.entries) {
      final header = entry.key;
      final col = entry.value;
      print('Scanning column $col ($header)...');
      final resp = await api.spreadsheets.values.get(
        _spreadsheetId,
        "'$_tab'!$col:$col",
        valueRenderOption: 'UNFORMATTED_VALUE',
      );
      final rows = resp.values ?? [];
      var fixed = 0;
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.isEmpty) continue;
        final v = row[0];
        // Only act on String cells — actual numeric/date cells are
        // already typed correctly and don't need touching.
        if (v is String && v.isNotEmpty) {
          // Sheet rows are 1-based; i=1 means sheet row 2.
          final sheetRow = i + 1;
          fixes.add(sheets.ValueRange(
            range: "'$_tab'!$col$sheetRow",
            values: [
              [v],
            ],
          ));
          fixed++;
        }
      }
      print('  → $fixed text-stored cells to re-parse');
    }

    if (fixes.isEmpty) {
      print('Nothing to fix.');
      exit(0);
    }
    print('\nWriting ${fixes.length} cells with USER_ENTERED...');
    // Batch can get large; chunk to stay under request size limits.
    const chunkSize = 1000;
    var written = 0;
    for (var start = 0; start < fixes.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, fixes.length);
      final chunk = fixes.sublist(start, end);
      await api.spreadsheets.values.batchUpdate(
        sheets.BatchUpdateValuesRequest(
          valueInputOption: 'USER_ENTERED',
          data: chunk,
        ),
        _spreadsheetId,
      );
      written += chunk.length;
      print('  written $written/${fixes.length}');
    }
    print('✓ Done.');
  } finally {
    client.close();
  }
}
