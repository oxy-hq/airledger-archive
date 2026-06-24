import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/view_schema.dart';
import 'cell_codec.dart';
import 'sheets_repository.dart' show Record, rowIndexKey;

/// Local read-cache of warehouse rows, used to paint the timeline
/// instantly while a fresh copy is fetched in the background
/// (stale-while-revalidate). **The sheet stays the system of record** —
/// this is a performance cache only. CRUD writes still go straight to the
/// connector; callers refresh the cache (via [put], or a forced re-fetch)
/// after a write so it never drifts into being treated as truth.
///
/// Storage: one SQLite row per `(view, date_key)`. `date_key` is a
/// `yyyy-MM-dd` string for date-scoped queries, or the sentinel
/// [allDatesKey] for the unfiltered "every row" query that drives the
/// calendar markers. The payload is a JSON array of rows encoded with
/// [CellCodec] — same round-trip the plan store uses, so `DateTime` and
/// `num` cell types survive (raw JSON would flatten them to strings).
class RowCache {
  /// Sentinel date_key for the unfiltered `list(view)` result.
  static const allDatesKey = '__all__';

  static Database? _db;

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'row_cache.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE rows ('
        'view TEXT NOT NULL, '
        'date_key TEXT NOT NULL, '
        'payload TEXT NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'PRIMARY KEY (view, date_key))',
      ),
    );
    _db = db;
    return db;
  }

  /// Returns the cached rows for `(view, dateKey)`, or null on a miss (or
  /// if the platform has no app-documents dir / the DB can't open — in
  /// which case the caller simply falls through to a live fetch).
  static Future<List<Record>?> get(ViewSchema view, String dateKey) async {
    try {
      final db = await _open();
      final res = await db.query(
        'rows',
        columns: ['payload'],
        where: 'view = ? AND date_key = ?',
        whereArgs: [view.name, dateKey],
        limit: 1,
      );
      if (res.isEmpty) return null;
      final list = jsonDecode(res.first['payload'] as String) as List;
      return [for (final e in list) _decodeRow(view, e as Map)];
    } catch (_) {
      return null;
    }
  }

  /// Replaces the cached rows for `(view, dateKey)`. Best-effort: a write
  /// failure is swallowed (the cache is an optimization, never required).
  static Future<void> put(
    ViewSchema view,
    String dateKey,
    List<Record> rows,
  ) async {
    try {
      final db = await _open();
      final payload = jsonEncode([for (final r in rows) _encodeRow(view, r)]);
      await db.insert(
        'rows',
        {
          'view': view.name,
          'date_key': dateKey,
          'payload': payload,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // ignore — next live fetch repopulates
    }
  }

  /// Drops every cached entry for [viewName]. Useful if a view's schema
  /// changed shape (e.g. after a GitHub schema sync) and stale payloads
  /// might no longer decode cleanly.
  static Future<void> clearView(String viewName) async {
    try {
      final db = await _open();
      await db.delete('rows', where: 'view = ?', whereArgs: [viewName]);
    } catch (_) {}
  }

  /// A cheap content fingerprint of a row list — used by the timeline to
  /// decide whether a background refresh actually changed anything before
  /// rebuilding (avoids resetting scroll/expansion on no-op refreshes).
  static String signature(ViewSchema view, List<Record> rows) =>
      jsonEncode([for (final r in rows) _encodeRow(view, r)]);

  // Encodes one row to a JSON-safe map: known dimensions via CellCodec
  // (matching PlannedEntry), plus the hidden __row index so update/delete
  // can still resolve the row off a cached read.
  static Map<String, dynamic> _encodeRow(ViewSchema view, Record row) {
    final values = <String, dynamic>{};
    for (final entry in row.entries) {
      if (entry.key == rowIndexKey) continue;
      final dim = view.dimensionByName(entry.key);
      if (dim == null) continue;
      values[entry.key] = CellCodec.encode(dim.type, entry.value);
    }
    return {
      'values': values,
      if (row[rowIndexKey] is int) rowIndexKey: row[rowIndexKey],
    };
  }

  static Record _decodeRow(ViewSchema view, Map json) {
    final row = <String, Object?>{};
    final raw = (json['values'] as Map);
    for (final entry in raw.entries) {
      final name = entry.key.toString();
      final dim = view.dimensionByName(name);
      if (dim == null) continue;
      final v = entry.value;
      // CellCodec.decode parses strings; typed primitives pass through.
      row[name] = v is String ? CellCodec.decode(dim.type, v) : v;
    }
    final idx = json[rowIndexKey];
    if (idx is int) row[rowIndexKey] = idx;
    return row;
  }
}
