// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

/// One-shot resort of a sheet tab into the canonical ledger order:
///   - newest date first (descending by Date column)
///   - within a date, chronological (ascending by Start Time column when
///     present; otherwise preserves sheet row order)
///
/// Header row is left in place. Writes go via clear + append, so the rest of
/// the workbook is untouched.
///
/// Usage:
///   dart run tool/reorder_sheet.dart <spreadsheet_id> <tab> [--confirm]
///   dart run tool/reorder_sheet.dart 1C1r... strength --confirm
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/reorder_sheet.dart <spreadsheet_id> <tab> [--confirm]');
    exit(1);
  }
  final spreadsheetId = args[0];
  final tab = args[1];
  final confirmed = args.contains('--confirm');

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

  print('reading $tab from $spreadsheetId ...');
  final resp = await api.spreadsheets.values.get(spreadsheetId, "'$tab'");
  final rows = resp.values ?? [];
  if (rows.length < 2) {
    print('nothing to reorder (rows: ${rows.length})');
    exit(0);
  }
  final headers = rows.first.map((e) => e.toString()).toList();
  final dateCol = headers.indexOf('Date');
  if (dateCol < 0) {
    print('no "Date" column in headers: $headers');
    exit(1);
  }
  final timeCol = headers.indexOf('Start Time');

  final data = rows.sublist(1);
  print('rows: ${data.length}');

  // Stable sort: by date desc, then by start_time asc (blanks last).
  // Stable means rows with the same date+time keep their original relative
  // order — important if Start Time is missing for several rows on the same
  // date.
  final indexed = data
      .asMap()
      .entries
      .map((e) => _Indexed(e.key, e.value))
      .toList();
  indexed.sort((a, b) {
    final ad = a.row.length > dateCol ? a.row[dateCol].toString() : '';
    final bd = b.row.length > dateCol ? b.row[dateCol].toString() : '';
    final dc = bd.compareTo(ad); // date desc
    if (dc != 0) return dc;
    if (timeCol < 0) return a.idx.compareTo(b.idx);
    final at = a.row.length > timeCol ? a.row[timeCol].toString().trim() : '';
    final bt = b.row.length > timeCol ? b.row[timeCol].toString().trim() : '';
    if (at.isEmpty && bt.isEmpty) return a.idx.compareTo(b.idx);
    if (at.isEmpty) return 1;
    if (bt.isEmpty) return -1;
    final tc = at.compareTo(bt); // time asc
    if (tc != 0) return tc;
    return a.idx.compareTo(b.idx);
  });
  final sorted = indexed.map((e) => e.row).toList();

  // Detect a no-op (already in order).
  var changed = false;
  for (var i = 0; i < sorted.length; i++) {
    if (!_listEquals(sorted[i], data[i])) {
      changed = true;
      break;
    }
  }
  if (!changed) {
    print('already in order, nothing to do');
    exit(0);
  }

  print('would reorder ${sorted.length} rows');
  if (!confirmed) {
    print('(pass --confirm to write the new order)');
    print('first 3 rows after sort:');
    for (final r in sorted.take(3)) {
      print('  $r');
    }
    exit(0);
  }

  print('clearing existing data rows ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    spreadsheetId,
    "'$tab'!A2:Z",
  );
  // Use `update` with explicit ranges instead of `append` — if the header
  // row's first cell is empty, `append A1` overwrites row 1 with data.
  print('writing ${sorted.length} sorted rows ...');
  const batchSize = 2000;
  for (var start = 0; start < sorted.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, sorted.length);
    final batch = sorted.sublist(start, end);
    final firstRowNum = start + 2;
    await api.spreadsheets.values.update(
      sheets.ValueRange(values: batch),
      spreadsheetId,
      "'$tab'!A$firstRowNum",
      valueInputOption: 'RAW',
    );
  }
  print('DONE');
  exit(0);
}

class _Indexed {
  final int idx;
  final List<Object?> row;
  _Indexed(this.idx, this.row);
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
