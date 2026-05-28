// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:ledger/models/view_schema.dart';
import 'package:ledger/services/schema_parser.dart';

/// Rewrites a sheet tab so numeric / boolean cells are stored with the
/// correct Sheets cell type. Fixes the legacy state where every value was
/// written as text (leading apostrophe in the UI for numeric-looking strings).
///
/// Uses the schema for the view to decide which columns should be which type.
/// Untyped columns (no matching dimension in the view) are written back
/// unchanged.
///
/// Usage:
///   dart run tool/fix_cell_types.dart <spreadsheet_id> <view_name> [--confirm]
///
/// Example:
///   dart run tool/fix_cell_types.dart 1C1r... strength --confirm
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/fix_cell_types.dart '
        '<spreadsheet_id> <view_name> [--confirm]');
    exit(1);
  }
  final spreadsheetId = args[0];
  final viewName = args[1];
  final confirmed = args.contains('--confirm');

  final home = Platform.environment['HOME']!;

  // Load the view schema from the synced assets so we know each column's type.
  final schemaPath =
      '${Directory.current.path}/assets/schemas/$viewName.view.yml';
  if (!await File(schemaPath).exists()) {
    print('no schema at $schemaPath');
    print('did you run ./tool/sync_assets.sh first?');
    exit(1);
  }
  final view = parseViewSchema(await File(schemaPath).readAsString());
  print('view: ${view.name} (table: ${view.table})');

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
  if (rows.length < 2) {
    print('nothing to fix (rows: ${rows.length})');
    exit(0);
  }
  final headers = rows.first.map((e) => e.toString()).toList();
  print('headers: $headers');

  // Map column index → dimension type (null if no matching dimension).
  final colTypes = <int, DimensionType>{};
  for (var i = 0; i < headers.length; i++) {
    final dim = view.dimensionByExpr(headers[i]);
    if (dim == null) continue;
    colTypes[i] = dim.type;
  }
  print('typed columns: ${colTypes.entries.map((e) => "${headers[e.key]}=${e.value.name}").join(", ")}');

  // Walk rows, coerce stringy numbers/bools per column type, count changes.
  var changes = 0;
  final fixedRows = <List<Object?>>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final fixed = <Object?>[];
    for (var c = 0; c < headers.length; c++) {
      final raw = c < row.length ? row[c] : null;
      final type = colTypes[c];
      if (type == null) {
        fixed.add(raw ?? '');
        continue;
      }
      final coerced = _coerce(type, raw);
      if (coerced != raw) changes++;
      fixed.add(coerced);
    }
    fixedRows.add(fixed);
  }

  print('\nwould change $changes cells across ${fixedRows.length} rows');
  if (!confirmed) {
    print('(pass --confirm to write)');
    print('sample diffs (first 5 changed):');
    var shown = 0;
    for (var r = 0; r < fixedRows.length && shown < 5; r++) {
      final orig = rows[r + 1];
      for (var c = 0; c < fixedRows[r].length; c++) {
        final o = c < orig.length ? orig[c] : null;
        final n = fixedRows[r][c];
        if (o != n && shown < 5) {
          print('  row ${r + 2} col ${headers[c]}: ${o.runtimeType}=$o -> ${n.runtimeType}=$n');
          shown++;
        }
      }
    }
    exit(0);
  }

  if (changes == 0) {
    print('nothing to do');
    exit(0);
  }

  // Write back via `values.update` with explicit row ranges — NOT `append`.
  // `append` to "A1" has a footgun: if the first header cell is empty, Sheets
  // treats the whole "table at A1" as empty and the first appended row lands
  // ON row 1, wiping the headers. Using update + explicit ranges sidesteps it.
  print('clearing data rows ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    spreadsheetId,
    "'$tab'!A2:Z",
  );

  print('writing ${fixedRows.length} typed rows in batches of 2000 ...');
  const batchSize = 2000;
  for (var start = 0; start < fixedRows.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, fixedRows.length);
    final batch = fixedRows.sublist(start, end);
    final firstRowNum = start + 2; // row 1 is header
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

Object? _coerce(DimensionType type, Object? raw) {
  if (raw == null) return '';
  if (raw is String && raw.isEmpty) return '';
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
