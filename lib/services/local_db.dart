import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/view_schema.dart';
import 'cell_codec.dart';
import 'sheets_repository.dart';

/// Local SQLite mirror of the Sheets data, used as the analytics substrate.
///
/// The sheet is the source of truth (CRUD writes go there); SQLite is a
/// read-cache populated by `syncFromSheet(...)`. airlayer compiles
/// `dialect: sqlite` SQL against this DB and we execute via sqflite.
///
/// One table per view, named after `view.table`. The schema mirrors the
/// view's dimensions: each dimension becomes a column whose name matches
/// `dimension.expr` (the same column header as in the sheet) and whose
/// SQLite affinity is derived from `dimension.type`.
///
/// The cache is destructive on sync: each view's table is dropped + recreated
/// on every sync. Adequate for ledger's data size (~32k strength rows fits
/// in a second or two of writes).
class LocalDb {
  final Database _db;
  LocalDb._(this._db);

  static Future<LocalDb> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'ledger_cache.db');
    final db = await openDatabase(path, version: 1);
    return LocalDb._(db);
  }

  Database get raw => _db;

  /// Pulls every row of [view] from the sheet via [repo] and replaces the
  /// matching SQLite table. Safe to call repeatedly; runs as a single
  /// transaction so partial failures don't leave a half-populated cache.
  Future<int> syncFromSheet(ViewSchema view, SheetsRepository repo) async {
    final rows = await repo.list(view);
    final table = view.table;
    final columns = view.dimensions
        .map((d) => _ColumnSpec(d.expr, _affinity(d.type)))
        .toList();

    await _db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS "$table"');
      final colDefs = columns
          .map((c) => '"${c.name}" ${c.affinity}')
          .join(', ');
      await txn.execute('CREATE TABLE "$table" ($colDefs)');

      // sqflite has a SQLite limit of ~999 host parameters per statement;
      // chunk inserts to stay under it.
      const chunkRows = 100;
      for (var start = 0; start < rows.length; start += chunkRows) {
        final end = (start + chunkRows).clamp(0, rows.length);
        final slice = rows.sublist(start, end);
        final placeholders = slice
            .map((_) => '(${List.filled(columns.length, '?').join(', ')})')
            .join(', ');
        final values = <Object?>[];
        for (final row in slice) {
          for (final dim in view.dimensions) {
            final v = row[dim.name];
            values.add(_toSqlite(dim.type, v));
          }
        }
        final cols = columns.map((c) => '"${c.name}"').join(', ');
        await txn.rawInsert(
          'INSERT INTO "$table" ($cols) VALUES $placeholders',
          values,
        );
      }
    });

    return rows.length;
  }

  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) {
    return _db.rawQuery(sql, args);
  }

  Future<void> close() => _db.close();

  // ---- internals ----

  /// SQLite type-affinity rules use the declared type loosely; we pick
  /// affinities that round-trip cleanly with [CellCodec]-encoded values.
  String _affinity(DimensionType type) {
    switch (type) {
      case DimensionType.number:
        return 'REAL';
      case DimensionType.boolean:
        return 'INTEGER';
      case DimensionType.string:
      case DimensionType.date:
      case DimensionType.datetime:
        return 'TEXT';
    }
  }

  /// Convert a typed Dart value into something sqflite will accept directly
  /// (num, String, int for bool). DateTimes go to ISO strings via the same
  /// codec the sheet round-trips through.
  Object? _toSqlite(DimensionType type, Object? v) {
    if (v == null) return null;
    if (type == DimensionType.boolean) {
      if (v is bool) return v ? 1 : 0;
    }
    if (type == DimensionType.date || type == DimensionType.datetime) {
      if (v is DateTime) return CellCodec.encode(type, v);
    }
    if (type == DimensionType.number && v is num) return v;
    return v.toString();
  }
}

class _ColumnSpec {
  final String name;
  final String affinity;
  _ColumnSpec(this.name, this.affinity);
}
