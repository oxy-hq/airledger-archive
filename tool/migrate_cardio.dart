// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

/// Migrates the legacy 4x4 cardio sheet into the ledger workbook's cardio tab.
///   - Source: 1hiDgkewR-z7JCJ1yNkKpCB7klIY0HDGupLscmcUSnhQ '4x4'
///   - Dest:   1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4 'cardio'
///
/// Per-row transformations:
///   - Generate UUID for id
///   - Infer Type: treadmill if Treadmill Speed populated; stairmaster if
///     Stairmaster Speed populated; treadmill (default) otherwise
///   - Compute Day of Week from Date
///   - Convert "never reached" → blank in Zone 4/5 columns
///   - Rename Treadmill Incline (%) → Treadmill Incline, Treadmill Speed (mph)
///     → Treadmill Speed (units now live in schema description)
///
/// Creates the cardio tab if it doesn't exist; clears existing data before
/// writing.
///
/// Run: dart run tool/migrate_cardio.dart --confirm
Future<void> main(List<String> args) async {
  if (!args.contains('--confirm')) {
    print('DESTRUCTIVE: this clears the cardio tab in the ledger workbook');
    print('and replaces it with 88 rows from the 4x4 cardio sheet.');
    print('Pass --confirm to proceed.');
    exit(1);
  }

  const sourceId = '1hiDgkewR-z7JCJ1yNkKpCB7klIY0HDGupLscmcUSnhQ';
  const sourceTab = '4x4';
  const destId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const destTab = 'cardio';
  const uuid = Uuid();

  final destHeaders = <String>[
    'id',
    'Date',
    'Day of Week',
    'Type',
    'Treadmill Incline',
    'Treadmill Speed',
    'Stairmaster Speed',
    'Time Zone 4 Reached',
    'Time Zone 5 Reached',
    'Total Time',
    'Max Heart Rate',
    'Start Time',
    'Notes',
  ];

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

  print('reading $sourceTab from $sourceId ...');
  final src = await api.spreadsheets.values.get(sourceId, "'$sourceTab'");
  final rows = src.values ?? [];
  if (rows.length < 2) {
    print('source is empty, abort');
    exit(1);
  }
  final srcHeaders = rows.first.map((e) => e.toString()).toList();
  print('source columns: $srcHeaders');
  print('source rows: ${rows.length - 1}');

  int? srcIdx(String h) {
    final i = srcHeaders.indexOf(h);
    return i < 0 ? null : i;
  }
  final iDate = srcIdx('Date');
  final iIncline = srcIdx('Treadmill Incline (%)');
  final iTSpeed = srcIdx('Treadmill Speed (mph)');
  final iSSpeed = srcIdx('Stairmaster Speed');
  final iZ4 = srcIdx('Time Zone 4 Reached');
  final iZ5 = srcIdx('Time Zone 5 Reached');
  final iTotal = srcIdx('Total Time');
  final iHr = srcIdx('Max Heart Rate');
  final iNotes = srcIdx('Notes');
  if (iDate == null) {
    print('source missing Date column');
    exit(1);
  }

  // Detect treadmill vs stairmaster by which speed column is populated.
  String detectType(List<Object?> r) {
    final ss = iSSpeed != null && iSSpeed < r.length
        ? r[iSSpeed].toString().trim()
        : '';
    final ts = iTSpeed != null && iTSpeed < r.length
        ? r[iTSpeed].toString().trim()
        : '';
    if (ss.isNotEmpty) return 'stairmaster';
    if (ts.isNotEmpty) return 'treadmill';
    return 'treadmill'; // default for ambiguous old rows
  }

  String cleanZone(String s) {
    final t = s.trim().toLowerCase();
    if (t == 'never reached' || t == 'never' || t == 'no') return '';
    return s.trim();
  }

  String at(List<Object?> r, int? col) {
    if (col == null || col >= r.length) return '';
    return r[col].toString().trim();
  }

  print('\nbuilding target rows ...');
  final target = <List<String>>[];
  var stairs = 0;
  for (var i = 1; i < rows.length; i++) {
    final r = rows[i];
    final dateStr = at(r, iDate);
    if (dateStr.isEmpty) continue;
    final type = detectType(r);
    if (type == 'stairmaster') stairs++;

    String dow;
    try {
      final d = DateTime.parse(dateStr);
      dow = DateFormat('EEEE').format(d);
    } catch (_) {
      dow = '';
    }

    target.add([
      uuid.v4(),
      dateStr,
      dow,
      type,
      type == 'treadmill' ? at(r, iIncline) : '',
      type == 'treadmill' ? at(r, iTSpeed) : '',
      type == 'stairmaster' ? at(r, iSSpeed) : '',
      cleanZone(at(r, iZ4)),
      cleanZone(at(r, iZ5)),
      at(r, iTotal),
      at(r, iHr),
      '', // Start Time — none in source data
      at(r, iNotes),
    ]);
  }
  print('built ${target.length} target rows ($stairs stairmaster, '
      '${target.length - stairs} treadmill)');

  // Ensure destination tab exists.
  print('\nensuring $destTab tab exists in $destId ...');
  final ss = await api.spreadsheets.get(destId);
  final tabExists = (ss.sheets ?? []).any(
    (s) => s.properties?.title == destTab,
  );
  if (!tabExists) {
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(
        requests: [
          sheets.Request(
            addSheet: sheets.AddSheetRequest(
              properties: sheets.SheetProperties(title: destTab),
            ),
          ),
        ],
      ),
      destId,
    );
    print('  created');
  } else {
    print('  exists');
  }

  // Write headers (always, even if exists — keeps schema in sync).
  print('\nwriting headers ...');
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: [destHeaders]),
    destId,
    "'$destTab'!A1",
    valueInputOption: 'RAW',
  );

  // Clear existing data rows.
  print('clearing existing data rows ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    destId,
    "'$destTab'!A2:Z",
  );

  // Append target rows.
  print('appending ${target.length} rows ...');
  await api.spreadsheets.values.append(
    sheets.ValueRange(values: target),
    destId,
    "'$destTab'!A1",
    valueInputOption: 'RAW',
  );

  print('\nDONE');
  exit(0);
}
