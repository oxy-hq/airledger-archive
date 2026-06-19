// ignore_for_file: avoid_print
// One-shot: copy rows from the default-workbook's 4x4 tab to the
// dedicated cardio spreadsheet (where they should have gone). Triggered
// by the cardio.view.yml spreadsheet_id sitting in the wrong layer —
// the parser ignores it, so writes silently landed on the main sheet.
//
//   dart run tool/migrate_4x4_to_correct_sheet.dart           # dry run
//   dart run tool/migrate_4x4_to_correct_sheet.dart --confirm

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

Future<void> main(List<String> args) async {
  final confirm = args.contains('--confirm');
  const srcId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4'; // default
  const dstId = '1hiDgkewR-z7JCJ1yNkKpCB7klIY0HDGupLscmcUSnhQ';
  const tab = '4x4';

  final keyJson = await File(
    '${Platform.environment['HOME']}/.config/airledger/service-account.json',
  ).readAsString();
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(keyJson),
    [sheets.SheetsApi.spreadsheetsScope],
  );
  final api = sheets.SheetsApi(client);

  // 1. Read src tab.
  sheets.ValueRange srcResp;
  try {
    srcResp = await api.spreadsheets.values.get(srcId, "'$tab'");
  } catch (e) {
    print('No `$tab` tab on the default workbook ($srcId).');
    print('Either the cardio writes never happened or they went elsewhere.');
    print('Error: $e');
    client.close();
    return;
  }
  final srcRows = srcResp.values ?? [];
  if (srcRows.length < 2) {
    print('Default-workbook `$tab` tab has no data rows. Nothing to migrate.');
    client.close();
    return;
  }
  final srcHeaders =
      srcRows.first.map((e) => e.toString()).toList();
  final dataRows = srcRows.sublist(1);
  print('Found ${dataRows.length} data row(s) on default workbook `$tab` tab.');
  print('Headers: $srcHeaders');

  // 2. Ensure dst tab exists; read its headers.
  final ss = await api.spreadsheets.get(dstId);
  final tabExists = (ss.sheets ?? const <sheets.Sheet>[])
      .any((s) => s.properties?.title == tab);
  if (!tabExists) {
    if (!confirm) {
      print('[dry] dst tab `$tab` missing on $dstId — would create it');
    } else {
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(
          requests: [
            sheets.Request(
              addSheet: sheets.AddSheetRequest(
                properties: sheets.SheetProperties(title: tab),
              ),
            ),
          ],
        ),
        dstId,
      );
      print('Created dst tab `$tab` on $dstId');
    }
  }
  // Rename dst headers to the schema's canonical names so future
  // ensureSheet calls match existing columns instead of appending
  // duplicates. The dst spreadsheet pre-dates the schema; map the
  // user's preferred unit-suffixed forms to the canonical bare names.
  const headerRenames = <String, String>{
    'Treadmill Incline (%)': 'Treadmill Incline',
    'Treadmill Speed (mph)': 'Treadmill Speed',
  };
  final dstHdrResp =
      await api.spreadsheets.values.get(dstId, "'$tab'!1:1");
  final dstHeadersOriginal = (dstHdrResp.values?.first ?? const [])
      .map((e) => e.toString())
      .toList();
  final dstHeaders = [
    for (final h in dstHeadersOriginal) headerRenames[h] ?? h,
  ];
  final needsHeaderRename = dstHeaders.join('|') != dstHeadersOriginal.join('|');
  print('Dst headers (existing): $dstHeadersOriginal');
  if (needsHeaderRename) {
    print('Dst headers (canonical): $dstHeaders');
  }

  // 3. Final header list = dst (canonical) order + any src headers not
  //    already in dst, appended on the right. Preserves the user's
  //    column order on the dst sheet AND captures every src column so
  //    no migrated data is silently dropped.
  final headersToWrite = <String>[
    ...dstHeaders,
    for (final h in srcHeaders)
      if (!dstHeaders.contains(h)) h,
  ];
  final missingOnDst = headersToWrite.length - dstHeaders.length;
  if (missingOnDst > 0) {
    print('Will append $missingOnDst new column(s) to dst: '
        '${headersToWrite.sublist(dstHeaders.length)}');
  }

  // 4. Realign each src row to the dst header order.
  final remappedRows = <List<Object>>[];
  for (final row in dataRows) {
    final byHeader = <String, Object>{};
    for (var i = 0; i < srcHeaders.length && i < row.length; i++) {
      final v = row[i];
      if (v != null) byHeader[srcHeaders[i]] = v;
    }
    remappedRows.add([
      for (final h in headersToWrite) byHeader[h] ?? '',
    ]);
  }

  if (!confirm) {
    print('--- dry run ---');
    print('Would write ${remappedRows.length} row(s) to $dstId `$tab`');
    if (remappedRows.isNotEmpty) {
      print('First row preview: ${remappedRows.first}');
    }
    print('(pass --confirm to execute)');
    client.close();
    return;
  }

  // 5. Always write the full canonical+union header row. This
  //     simultaneously renames legacy headers (e.g. dropping unit
  //     suffixes) and adds any src columns the dst was missing.
  //     Existing data rows below stay put under their new column names.
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: [headersToWrite]),
    dstId,
    "'$tab'!A1",
    valueInputOption: 'RAW',
  );
  print('Wrote dst headers (canonical + union): ${headersToWrite.length} cols');

  // 6. Append data rows.
  await api.spreadsheets.values.append(
    sheets.ValueRange(values: remappedRows),
    dstId,
    "'$tab'!A1",
    valueInputOption: 'RAW',
    insertDataOption: 'INSERT_ROWS',
  );
  print('Appended ${remappedRows.length} row(s) to $dstId `$tab`');

  // 7. Wipe src data rows so they don't keep showing in the app once
  //    the schema fix is shipped. Keep the header row.
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    srcId,
    "'$tab'!A2:Z",
  );
  print('Cleared src data rows on $srcId `$tab`');

  client.close();
}
