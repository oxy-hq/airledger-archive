// ignore_for_file: avoid_print
// One-shot: scrub SQL-expression columns that the buggy ensureSheet
// (pre-fix) appended to the strength/weight/cardio/meals tabs.
//
// Scan rule: any header containing '(' or ')' is a zombie. Real airledger
// column names never have parens, but every leaked airlayer expression
// does (`CAST(...)`, `EXTRACT(...)`, `DATE_TRUNC(...)`, `STDDEV_SAMP(...)`,
// etc.). The double-quoted aliases like `"Day of Week"` are also dropped —
// they're duplicate analytical aliases, the bare `Day of Week` column is
// the canonical one.
//
// Usage:
//   dart run tool/cleanup_zombie_columns.dart                # dry run
//   dart run tool/cleanup_zombie_columns.dart --confirm      # delete
//   dart run tool/cleanup_zombie_columns.dart --tab strength # one tab only

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

Future<void> main(List<String> args) async {
  final confirm = args.contains('--confirm');
  final tabIdx = args.indexOf('--tab');
  final onlyTab = tabIdx >= 0 && tabIdx + 1 < args.length ? args[tabIdx + 1] : null;
  const spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const candidateTabs = ['strength', 'weight', 'cardio', 'meals'];

  final keyJson = await File(
    '${Platform.environment['HOME']}/.config/airledger/service-account.json',
  ).readAsString();
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(keyJson),
    [sheets.SheetsApi.spreadsheetsScope],
  );
  final api = sheets.SheetsApi(client);

  // Pull sheet ids in one round-trip so we can submit deleteDimension in
  // one batchUpdate per tab.
  final ss = await api.spreadsheets.get(spreadsheetId);
  final sheetIds = <String, int>{};
  for (final s in ss.sheets ?? const <sheets.Sheet>[]) {
    final title = s.properties?.title;
    final id = s.properties?.sheetId;
    if (title != null && id != null) sheetIds[title] = id;
  }

  final tabs = onlyTab != null ? [onlyTab] : candidateTabs;
  for (final tab in tabs) {
    final sheetId = sheetIds[tab];
    if (sheetId == null) {
      print('[$tab] tab not found — skipping');
      continue;
    }
    final hdrResp =
        await api.spreadsheets.values.get(spreadsheetId, "'$tab'!1:1");
    final headers =
        (hdrResp.values?.first ?? const []).map((e) => e.toString()).toList();

    // Detect zombies. Two rules — both conservative:
    //   1. Header contains '(' or ')' → SQL expression (CAST, EXTRACT,
    //      TRY_CAST, DATE_TRUNC, STDDEV_SAMP, POWER, NULLIF, strftime,
    //      DAYNAME, ...). Always safe to delete; airledger column names
    //      never contain parens.
    //   2. Header is a quoted identifier (`"Treadmill Speed"`) AND the
    //      same string without quotes ALSO exists as a header. The quoted
    //      form is a duplicate appended by ensureSheet against an
    //      analytical view; the unquoted form is the canonical data
    //      column. Drop the quoted duplicate, keep the canonical. If the
    //      unquoted twin is missing, leave the quoted one alone (it might
    //      be the only home for real data — manual review required).
    final canonical = headers.toSet();
    final zombies = <int>[];
    for (var i = 0; i < headers.length; i++) {
      final h = headers[i];
      if (h.contains('(') || h.contains(')')) {
        zombies.add(i);
        continue;
      }
      if (h.startsWith('"') && h.endsWith('"') && h.length > 2) {
        final unquoted = h.substring(1, h.length - 1);
        if (canonical.contains(unquoted)) zombies.add(i);
      }
    }

    if (zombies.isEmpty) {
      print('[$tab] clean — no zombies');
      continue;
    }
    print('[$tab] ${headers.length} columns total, ${zombies.length} zombies:');
    for (final i in zombies) {
      print('  col ${_a1(i)}: ${headers[i]}');
    }
    if (!confirm) {
      print('  (dry run — pass --confirm to delete)');
      continue;
    }

    // Build delete requests in descending-index order so the deletes don't
    // invalidate each other's column positions.
    final sortedDesc = [...zombies]..sort((a, b) => b.compareTo(a));
    final requests = <sheets.Request>[
      for (final i in sortedDesc)
        sheets.Request(
          deleteDimension: sheets.DeleteDimensionRequest(
            range: sheets.DimensionRange(
              sheetId: sheetId,
              dimension: 'COLUMNS',
              startIndex: i,
              endIndex: i + 1,
            ),
          ),
        ),
    ];
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: requests),
      spreadsheetId,
    );
    print('  ✓ deleted ${zombies.length} column(s)');
  }
  client.close();
}

/// Spreadsheet column letter for a 0-based index. 0→A, 25→Z, 26→AA.
String _a1(int idx) {
  var i = idx;
  final buf = StringBuffer();
  while (i >= 0) {
    buf.write(String.fromCharCode('A'.codeUnitAt(0) + (i % 26)));
    i = (i ~/ 26) - 1;
  }
  return buf.toString().split('').reversed.join();
}
