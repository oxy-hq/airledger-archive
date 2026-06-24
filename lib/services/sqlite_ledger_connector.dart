import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'cell_codec.dart';
import 'sheets_repository.dart' show Record, rowIndexKey;
import 'warehouse_connector.dart';

/// On-device [WarehouseConnector] that stores transactions in a local
/// SQLite file (`ledger.db`) instead of a remote sheet/warehouse. Selected
/// by a view's `datasource: sqlite_ledger`.
///
/// This is the "SQLite as the durable ledger" half of the pluggable-ledger
/// design: deployments that don't need Google-account data ownership can
/// keep their ledger entirely on the device. The Sheets path is untouched —
/// views without this datasource resolve to the bundled sheets connector.
///
/// Storage model: one flat `rows` table keyed by an autoincrement `seq`,
/// with the record's dimension values serialized to JSON via [CellCodec]
/// (the same round-trip RowCache/PlannedEntry use, so `DateTime`/`num`
/// types survive). `row_id` mirrors the view's `id` dimension and is the
/// stable handle for update/delete — unlike Sheets' positional `__row`,
/// a SQLite ledger row never shifts, so we resolve writes by `id`.
class SqliteLedgerConnector implements WarehouseConnector {
  @override
  final DatabaseConfig config;

  static const _uuid = Uuid();
  Database? _db;

  SqliteLedgerConnector(this.config);

  /// Lazily opens `ledger.db`. Lazy so registering the connector at startup
  /// (even for deployments that never use it) costs nothing until a view
  /// actually reads/writes.
  Future<Database> _database() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      p.join(dir.path, 'ledger.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE rows ('
          'seq INTEGER PRIMARY KEY AUTOINCREMENT, '
          'view TEXT NOT NULL, '
          'row_id TEXT, '
          'payload TEXT NOT NULL, '
          'created_at INTEGER NOT NULL)',
        );
        await db.execute('CREATE INDEX ix_rows_view ON rows(view)');
        await db.execute('CREATE INDEX ix_rows_view_id ON rows(view, row_id)');
      },
    );
    _db = db;
    return db;
  }

  /// No-op: the flat `rows` table is schemaless (values live in a JSON
  /// payload), so there's nothing to migrate when a view's dimensions
  /// change. Present to satisfy the interface + startup `ensureTable` pass.
  @override
  Future<void> ensureTable(ViewSchema view) async {
    await _database();
  }

  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    final db = await _database();
    // Newest-first (highest seq), mirroring Sheets' insert-at-top order.
    final res = await db.query(
      'rows',
      columns: ['seq', 'row_id', 'payload'],
      where: 'view = ?',
      whereArgs: [view.name],
      orderBy: 'seq DESC',
    );
    final records = <Record>[];
    for (var i = 0; i < res.length; i++) {
      final row = _decode(view, res[i]['payload'] as String);
      // __row is a display rank (0 == newest), matching Sheets so the
      // timeline's __row-ascending sort yields newest-first. It is NOT a
      // write handle — update/delete resolve by `id` (see _seqForId).
      row[rowIndexKey] = i;
      records.add(row);
    }
    if (onDate != null && view.dateField != null) {
      return _filterAndSortByDate(view, records, onDate);
    }
    return records;
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async {
    final db = await _database();
    final toWrite = Map<String, Object?>.from(record);
    if (view.dimensionByName('id') != null) {
      toWrite['id'] ??= _uuid.v4();
    }
    await db.insert('rows', {
      'view': view.name,
      'row_id': toWrite['id']?.toString(),
      'payload': _encode(view, toWrite),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    toWrite[rowIndexKey] = 0; // newest row is at the top
    return toWrite;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {
    final db = await _database();
    final seq = await _seqForId(db, view, record);
    if (seq == null) {
      throw StateError(
        'Cannot update: no ledger row for id=${record['id']} in '
        '"${view.name}" (sqlite ledger resolves by id)',
      );
    }
    await db.update(
      'rows',
      {
        'row_id': record['id']?.toString(),
        'payload': _encode(view, record),
      },
      where: 'seq = ?',
      whereArgs: [seq],
    );
  }

  @override
  Future<void> delete(ViewSchema view, Record record) async {
    final db = await _database();
    final seq = await _seqForId(db, view, record);
    if (seq == null) return; // already gone / never existed
    await db.delete('rows', where: 'seq = ?', whereArgs: [seq]);
  }

  // --- internals ---

  /// Resolves the DB `seq` for a record by its `id` (the stable handle).
  /// Returns null if the record has no id or no matching row.
  Future<int?> _seqForId(Database db, ViewSchema view, Record record) async {
    final id = record['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final res = await db.query(
      'rows',
      columns: ['seq'],
      where: 'view = ? AND row_id = ?',
      whereArgs: [view.name, id],
      limit: 1,
    );
    if (res.isEmpty) return null;
    return res.first['seq'] as int;
  }

  String _encode(ViewSchema view, Record record) {
    final values = <String, dynamic>{};
    for (final entry in record.entries) {
      if (entry.key == rowIndexKey) continue;
      final dim = view.dimensionByName(entry.key);
      if (dim == null) continue;
      values[entry.key] = CellCodec.encode(dim.type, entry.value);
    }
    return jsonEncode({'values': values});
  }

  Record _decode(ViewSchema view, String payload) {
    final row = <String, Object?>{};
    final raw = (jsonDecode(payload) as Map)['values'] as Map;
    for (final entry in raw.entries) {
      final name = entry.key.toString();
      final dim = view.dimensionByName(name);
      if (dim == null) continue;
      final v = entry.value;
      row[name] = v is String ? CellCodec.decode(dim.type, v) : v;
    }
    return row;
  }

  /// Mirrors [SheetsRepository.list]'s date filter + within-day ordering so
  /// SQLite-ledger views behave identically to sheets-ledger views in the
  /// timeline: keep rows whose `date_field` is [onDate], then sort ascending
  /// by the plannable log field (start_time) parsed as a time-of-day.
  List<Record> _filterAndSortByDate(
    ViewSchema view,
    List<Record> records,
    DateTime onDate,
  ) {
    final filtered = records.where((r) {
      final v = r[view.dateField];
      if (v is! DateTime) return false;
      return v.year == onDate.year &&
          v.month == onDate.month &&
          v.day == onDate.day;
    }).toList();
    final logField = view.plannable?.logField;
    filtered.sort((a, b) {
      if (logField != null) {
        final av = a[logField]?.toString() ?? '';
        final bv = b[logField]?.toString() ?? '';
        if (av.isEmpty && bv.isEmpty) return 0;
        if (av.isEmpty) return 1;
        if (bv.isEmpty) return -1;
        final at = _parseTime(av);
        final bt = _parseTime(bv);
        if (at != null && bt != null) return at.compareTo(bt);
        return av.compareTo(bv);
      }
      final ar = a[rowIndexKey] as int? ?? 0;
      final br = b[rowIndexKey] as int? ?? 0;
      return ar.compareTo(br);
    });
    return filtered;
  }

  static Duration? _parseTime(String s) {
    for (final fmt in const ['h:mm:ss a', 'h:mm a', 'H:mm:ss', 'H:mm']) {
      try {
        final dt = DateFormat(fmt).parseLoose(s);
        return Duration(hours: dt.hour, minutes: dt.minute, seconds: dt.second);
      } catch (_) {/* try next */}
    }
    return null;
  }
}
