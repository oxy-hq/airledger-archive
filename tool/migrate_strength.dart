// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:uuid/uuid.dart';

/// Migrates the legacy fitness-logger Strength Tracker tab into the ledger
/// strength tab.
///   - Clears existing data rows from the destination (keeps the header row)
///   - Generates a fresh UUID per row
///   - Canonicalizes exercise names via word-set consolidation (same rule as
///     tool/consolidate_exercises.dart) so historical variants like
///     "Close Grip Barbell Bench Press" and "Barbell Close Grip Bench Press"
///     collapse to the most-used spelling
///   - Preserves source row order (newest first)
///   - Appends in batches of 1000
///
/// Run: dart run tool/migrate_strength.dart --confirm
Future<void> main(List<String> args) async {
  if (!args.contains('--confirm')) {
    print('DESTRUCTIVE: this clears the strength tab in the ledger workbook');
    print('and replaces it with ~32k rows from the fitness-logger sheet.');
    print('Pass --confirm to proceed.');
    exit(1);
  }

  const sourceId = '1BqV635hjq0XN9tTjVtH_Y6kI-NfPI1rdEvALtFlM7Nk';
  const sourceTab = 'Strength Tracker';
  const destId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const destTab = 'strength';
  const uuid = Uuid();

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

  // Map source column index by header name for safety.
  int? idx(String h) {
    final i = srcHeaders.indexOf(h);
    return i < 0 ? null : i;
  }
  final iDate = idx('Date');
  final iDow = idx('Day of Week');
  final iEx = idx('Exercise');
  final iWeight = idx('Weight');
  final iReps = idx('Reps');
  final iStart = idx('Start Time');
  final iRpe = idx('RPE');
  final iNotes = idx('Notes');
  if (iDate == null ||
      iDow == null ||
      iEx == null ||
      iWeight == null ||
      iReps == null) {
    print('source missing required column');
    exit(1);
  }

  // Build the same consolidation map the autocomplete uses: group by word-set,
  // pick most-frequent variant as canonical.
  print('\nbuilding exercise consolidation map ...');
  final counts = <String, int>{};
  for (var i = 1; i < rows.length; i++) {
    if (rows[i].length <= iEx) continue;
    final raw = rows[i][iEx]
        .toString()
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (raw.isEmpty) continue;
    counts[raw] = (counts[raw] ?? 0) + 1;
  }
  final groups = <String, List<MapEntry<String, int>>>{};
  for (final e in counts.entries) {
    groups.putIfAbsent(_wordSetKey(e.key), () => []).add(e);
  }
  final merges = <String, String>{};
  for (final group in groups.values) {
    group.sort((a, b) => b.value.compareTo(a.value));
    final canonical = group.first.key;
    for (final e in group) {
      merges[e.key] = canonical;
    }
  }
  final actualMerges = merges.entries
      .where((e) => e.key != e.value)
      .length;
  print('${counts.length} variants → ${groups.length} canonical '
      '($actualMerges merges)');

  // Build target rows: id, Date, Day of Week, Exercise(canonical), Weight,
  // Reps, Start Time, RPE, Notes.
  print('\nbuilding target rows ...');
  final target = <List<String>>[];
  for (var i = 1; i < rows.length; i++) {
    final r = rows[i];
    String at(int? col) {
      if (col == null || col >= r.length) return '';
      return r[col].toString();
    }
    final exRaw = at(iEx).trim().replaceAll(RegExp(r'\s+'), ' ');
    if (exRaw.isEmpty) continue;
    final exCanon = merges[exRaw] ?? exRaw;
    target.add([
      uuid.v4(),
      at(iDate),
      at(iDow),
      exCanon,
      at(iWeight),
      at(iReps),
      at(iStart),
      at(iRpe),
      at(iNotes),
    ]);
  }
  print('built ${target.length} target rows');

  // Clear destination (keep row 1 = headers).
  print('\nclearing $destTab in $destId ...');
  await api.spreadsheets.values.clear(
    sheets.ClearValuesRequest(),
    destId,
    "'$destTab'!A2:Z",
  );

  // Batched append.
  const batchSize = 2000;
  print('\nappending in batches of $batchSize ...');
  for (var start = 0; start < target.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, target.length);
    final batch = target.sublist(start, end);
    await api.spreadsheets.values.append(
      sheets.ValueRange(values: batch),
      destId,
      "'$destTab'!A1",
      valueInputOption: 'RAW',
    );
    print('  wrote rows ${start + 1}..$end / ${target.length}');
  }

  print('\nDONE');
  exit(0);
}

String _wordSetKey(String s) {
  final words = s
      .toLowerCase()
      .split(RegExp(r'[\s\-_/.,()]+'))
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  return words.join('|');
}
