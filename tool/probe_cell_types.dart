// ignore_for_file: avoid_print
//
// Probe a specific row in the strength tab. Reads each cell with both
// UNFORMATTED_VALUE (Sheets' native cell type) and FORMATTED_VALUE
// (what the UI shows) so we can spot text-stored-as-number cells
// (where the UI prefixes them with `'`).

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

const _spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
const _tab = 'strength';

Future<void> main(List<String> args) async {
  final sheetRow = args.isEmpty ? 16 : int.parse(args[0]);
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
    final hdr = await api.spreadsheets.values.get(
      _spreadsheetId,
      "'$_tab'!1:1",
      valueRenderOption: 'UNFORMATTED_VALUE',
    );
    final unf = await api.spreadsheets.values.get(
      _spreadsheetId,
      "'$_tab'!$sheetRow:$sheetRow",
      valueRenderOption: 'UNFORMATTED_VALUE',
    );
    final form = await api.spreadsheets.values.get(
      _spreadsheetId,
      "'$_tab'!$sheetRow:$sheetRow",
      valueRenderOption: 'FORMATTED_VALUE',
    );
    final headers = (hdr.values?[0] ?? []).map((e) => e.toString()).toList();
    final unfCells = unf.values?[0] ?? [];
    final formCells = form.values?[0] ?? [];
    print('=== sheet row $sheetRow ===');
    for (var i = 0; i < headers.length; i++) {
      final u = i < unfCells.length ? unfCells[i] : null;
      final f = i < formCells.length ? formCells[i] : null;
      print('  ${headers[i]}:');
      print('    UNFORMATTED: ${u?.runtimeType} = ${_repr(u)}');
      print('    FORMATTED:   ${f?.runtimeType} = ${_repr(f)}');
    }
  } finally {
    client.close();
  }
}

String _repr(Object? v) {
  if (v == null) return 'null';
  if (v is String) return '"$v"';
  return v.toString();
}
