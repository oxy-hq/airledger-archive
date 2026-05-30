// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

/// Migrates the legacy body-composition log into the fitness workbook's
/// new `weight` tab.
///   - Source: 1GfL65B3upDl188h28CwDSMJ8uhEXfG_fPPjdTES9f-I
///             'Body Composition (UTC) - Archive'
///   - Dest:   1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4 'weight'
///
/// Per-row transformations:
///   - Generate UUID for id
///   - Source 'Datetime (UTC)' (e.g. '2025-10-28 14:13:00') → date only
///     (e.g. '2025-10-28'). Time is dropped — weigh-in time-of-day is
///     either midnight in the archive or device sync time in recent rows,
///     and isn't meaningful for the use case.
///   - Compute day_of_week from date
///   - Pass body fat columns through verbatim (sparse — most rows blank)
///   - Drop rows with no date *and* no weight *and* no body-fat values
///
/// Creates the weight tab if it doesn't exist; clears existing data before
/// writing. Run: dart run tool/migrate_weight.dart --confirm
Future<void> main(List<String> args) async {
  if (!args.contains('--confirm')) {
    print('DESTRUCTIVE: this clears the weight tab in the fitness workbook');
    print('and replaces it with rows from the body-composition archive.');
    print('Pass --confirm to proceed.');
    exit(1);
  }

  const sourceId = '1GfL65B3upDl188h28CwDSMJ8uhEXfG_fPPjdTES9f-I';
  const sourceTab = 'Body Composition (UTC) - Archive';
  const destId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const destTab = 'weight';
  const uuid = Uuid();

  final destHeaders = <String>[
    'id',
    'date',
    'day_of_week',
    'weight_lbs',
    'body_fat_caliper',
    'body_fat_omron',
    'notes',
  ];

  final home = Platform.environment['HOME']!;
  final keyJson = await File(
    '$home/.config/airledger/service-account.json',
  ).readAsString();
  final credentials = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(
    credentials,
    [sheets.SheetsApi.spreadsheetsScope],
  );
  final api = sheets.SheetsApi(client);

  print('reading "$sourceTab" from $sourceId ...');
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

  final iDt = srcIdx('Datetime (UTC)');
  final iCaliper = srcIdx('Body Fat % (Caliper)');
  final iOmron = srcIdx('Body Fat % (Omron)');
  final iWeight = srcIdx('Weight (lbs)');
  if (iDt == null) {
    print('source missing "Datetime (UTC)" column');
    exit(1);
  }

  String at(List<Object?> r, int? col) {
    if (col == null || col >= r.length) return '';
    return r[col].toString().trim();
  }

  // Source dates look like '2025-10-28 14:13:00'. Take everything before
  // the space; parse what's left as ISO. Skip rows where we can't.
  String? toDate(String s) {
    if (s.isEmpty) return null;
    final datePart = s.split(' ').first;
    try {
      final d = DateTime.parse(datePart);
      return DateFormat('yyyy-MM-dd').format(d);
    } catch (_) {
      return null;
    }
  }

  print('\nbuilding target rows ...');
  final target = <List<String>>[];
  var dropped = 0;
  for (var i = 1; i < rows.length; i++) {
    final r = rows[i];
    final date = toDate(at(r, iDt));
    final weight = at(r, iWeight);
    final caliper = at(r, iCaliper);
    final omron = at(r, iOmron);
    if (date == null) {
      dropped++;
      continue;
    }
    // Drop fully-empty rows (date only, no measurements).
    if (weight.isEmpty && caliper.isEmpty && omron.isEmpty) {
      dropped++;
      continue;
    }
    final dow = DateFormat('EEEE').format(DateTime.parse(date));
    target.add([
      uuid.v4(),
      date,
      dow,
      weight,
      caliper,
      omron,
      '', // notes — none in source
    ]);
  }
  print('built ${target.length} target rows '
      '($dropped dropped: bad date or all-empty)');

  print('\nensuring "$destTab" tab exists in $destId ...');
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

  print('\nwriting headers ...');
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: [destHeaders]),
    destId,
    "'$destTab'!A1",
    valueInputOption: 'RAW',
  );

  print('clearing existing data rows ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    destId,
    "'$destTab'!A2:Z",
  );

  print('appending ${target.length} rows ...');
  await api.spreadsheets.values.append(
    sheets.ValueRange(values: target),
    destId,
    "'$destTab'!A1",
    valueInputOption: 'RAW',
    insertDataOption: 'INSERT_ROWS',
  );

  print('\n✓ migrated ${target.length} weight rows into $destId/$destTab');
  exit(0);
}
