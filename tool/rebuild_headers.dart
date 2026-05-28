// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:ledger/models/view_schema.dart';
import 'package:ledger/services/schema_parser.dart';

/// Recovery tool: rewrites a tab so that
///   - row 1 = headers (taken from the schema's dimension `expr`s, in order)
///   - row 2..N = existing data, aligned to those headers by current position
///
/// Use this when the header row got eaten (e.g. by an `append` against a
/// table whose A1 cell was empty — Sheets treats that as "no table" and
/// overwrites row 1 with the first appended row).
///
/// Behavior:
///   1. Reads every row in the tab.
///   2. Heuristically detects if row 1 is already proper headers (by checking
///      whether row 1's first non-empty cell matches any dimension expr).
///   3. Builds the canonical header row from the schema.
///   4. Writes header + all data rows back using `values.update` with explicit
///      ranges (NOT `append`, which has the empty-A1 footgun).
///
/// Usage:
///   dart run tool/rebuild_headers.dart <spreadsheet_id> <view_name> [--confirm]
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/rebuild_headers.dart '
        '<spreadsheet_id> <view_name> [--confirm]');
    exit(1);
  }
  final spreadsheetId = args[0];
  final viewName = args[1];
  final confirmed = args.contains('--confirm');

  final schemaPath =
      '${Directory.current.path}/assets/schemas/$viewName.view.yml';
  if (!await File(schemaPath).exists()) {
    print('no schema at $schemaPath');
    print('did you run ./tool/sync_assets.sh first?');
    exit(1);
  }
  final view = parseViewSchema(await File(schemaPath).readAsString());
  print('view: ${view.name} (table: ${view.table})');

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

  final tab = view.table;
  print('\nreading $tab from $spreadsheetId ...');
  final resp = await api.spreadsheets.values.get(spreadsheetId, "'$tab'");
  final rows = resp.values ?? [];
  if (rows.isEmpty) {
    print('empty tab; nothing to do');
    exit(0);
  }

  final wantHeaders = view.dimensions.map((d) => d.expr).toList();
  print('want headers: $wantHeaders');

  // Detect whether row 1 is already proper headers.
  final firstRow = rows.first.map((e) => e.toString()).toList();
  final firstRowLooksLikeHeaders = firstRow.any(
    (cell) => cell.isNotEmpty && view.dimensionByExpr(cell) != null,
  );
  print('current row 1: $firstRow');
  print('row 1 looks like headers: $firstRowLooksLikeHeaders');

  final dataRows = firstRowLooksLikeHeaders ? rows.sublist(1) : rows;
  print('data rows: ${dataRows.length}');

  // Pad / trim each data row to exactly wantHeaders.length cells AND coerce
  // each cell to the dimension's native type (so numeric strings become
  // numbers, etc.). Without coercion we'd write strings back and re-introduce
  // the leading-apostrophe display on numeric columns.
  final colTypes = <int, DimensionType>{
    for (var i = 0; i < view.dimensions.length; i++) i: view.dimensions[i].type,
  };
  final aligned = dataRows.map((r) {
    final out = <Object?>[];
    for (var i = 0; i < wantHeaders.length; i++) {
      final raw = i < r.length ? r[i] : '';
      out.add(_coerce(colTypes[i], raw));
    }
    return out;
  }).toList();

  print('\nwould write:');
  print('  row 1 = ${wantHeaders.length} headers');
  print('  rows 2..${aligned.length + 1} = ${aligned.length} data rows '
      '(each padded to ${wantHeaders.length} cells)');
  if (!confirmed) {
    print('(pass --confirm to write)');
    exit(0);
  }

  // Clear the whole used range first (including row 1), so any extra columns
  // from prior misaligned state get wiped.
  print('\nclearing $tab!A:Z ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    spreadsheetId,
    "'$tab'!A:Z",
  );

  // Write headers at A1 via update (not append — append has the empty-A1
  // footgun that ate them in the first place).
  print('writing headers at A1 ...');
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: [wantHeaders]),
    spreadsheetId,
    "'$tab'!A1",
    valueInputOption: 'RAW',
  );

  // Write data rows in batches via update with explicit ranges.
  const batchSize = 2000;
  print('writing ${aligned.length} data rows in batches of $batchSize ...');
  for (var start = 0; start < aligned.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, aligned.length);
    final batch = aligned.sublist(start, end);
    final firstRowNum = start + 2;
    await api.spreadsheets.values.update(
      sheets.ValueRange(values: batch),
      spreadsheetId,
      "'$tab'!A$firstRowNum",
      valueInputOption: 'RAW',
    );
    print('  wrote rows $firstRowNum..${firstRowNum + batch.length - 1}');
  }

  print('\nDONE');
  exit(0);
}

Object? _coerce(DimensionType? type, Object? raw) {
  if (raw == null) return '';
  if (raw is String && raw.isEmpty) return '';
  if (type == null) return raw;
  switch (type) {
    case DimensionType.number:
      if (raw is num) return raw;
      final n = num.tryParse(raw.toString());
      return n ?? raw;
    case DimensionType.boolean:
      if (raw is bool) return raw;
      final s = raw.toString().toLowerCase();
      if (s == 'true') return true;
      if (s == 'false') return false;
      return raw;
    case DimensionType.string:
    case DimensionType.date:
    case DimensionType.datetime:
      return raw;
  }
}
