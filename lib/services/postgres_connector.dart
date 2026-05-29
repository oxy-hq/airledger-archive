import 'dart:math';

import 'package:postgres/postgres.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'cell_codec.dart';
import 'sheets_repository.dart' show Record, rowIndexKey;
import 'warehouse_connector.dart';

/// Postgres / Redshift / Airhouse connector. The three speak the same wire
/// protocol (Postgres) and share field shapes in [PostgresConfig]. Variant
/// detection happens at the registry level; this class just executes SQL.
///
/// CRUD design:
///   - **ensureTable** issues `CREATE TABLE IF NOT EXISTS` from the view's
///     dimensions, then `ALTER TABLE … ADD COLUMN IF NOT EXISTS` for any
///     dimensions that aren't yet on the existing table. Additive — never
///     drops or renames.
///   - **list** runs `SELECT * FROM table [WHERE date_field = $1]` and
///     attaches `__row` as the index in the returned list (a counter,
///     not a sheet row position). Used by the in-memory delete path.
///   - **create** auto-assigns a UUID for `id` if the view has one and
///     the record doesn't. Insert-at-top semantics aren't applicable to
///     SQL (rows have no inherent order) — `__row` is set to 0 to keep
///     the [WarehouseConnector] contract consistent with sheets.
///   - **update** / **delete** resolve by `id`. The `__row` index from
///     [list] isn't used (SQL row numbers aren't stable).
class PostgresConnector implements WarehouseConnector {
  @override
  final PostgresConfig config;

  final Connection _conn;

  PostgresConnector._(this.config, this._conn);

  /// Opens a connection from [config]. Caller is responsible for closing
  /// it via [close] when done.
  static Future<PostgresConnector> connect(PostgresConfig config) async {
    final host = config.host;
    if (host == null) {
      throw StateError('PostgresConfig "${config.name}" has no host');
    }
    final conn = await Connection.open(
      Endpoint(
        host: host,
        port: config.port ?? 5432,
        database: config.database ?? 'postgres',
        username: config.user,
        password: config.password,
      ),
      settings: ConnectionSettings(
        sslMode: _resolveSslMode(config.sslMode),
      ),
    );
    return PostgresConnector._(config, conn);
  }

  static SslMode _resolveSslMode(String? mode) {
    switch (mode) {
      case 'disable':
        return SslMode.disable;
      case 'require':
        return SslMode.require;
      case 'verify-full':
        return SslMode.verifyFull;
      default:
        return SslMode.disable;
    }
  }

  Future<void> close() => _conn.close();

  @override
  Future<void> ensureTable(ViewSchema view) async {
    final table = _quoteIdent(view.table);

    // 1. Create the table if it doesn't exist.
    final createCols = view.dimensions
        .map((d) => '${_quoteIdent(d.expr)} ${_pgType(d.type)}')
        .join(', ');
    final pkCol = view.dimensionByName('id') != null
        ? ', PRIMARY KEY (${_quoteIdent("id")})'
        : '';
    await _conn.execute('CREATE TABLE IF NOT EXISTS $table ($createCols$pkCol)');

    // 2. ALTER TABLE ADD COLUMN IF NOT EXISTS for new dimensions.
    for (final d in view.dimensions) {
      await _conn.execute(
        'ALTER TABLE $table ADD COLUMN IF NOT EXISTS '
        '${_quoteIdent(d.expr)} ${_pgType(d.type)}',
      );
    }
  }

  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    final table = _quoteIdent(view.table);
    final dateField = view.dateField == null
        ? null
        : view.dimensionByName(view.dateField!);

    final useFilter = dateField != null && onDate != null;
    final sql = useFilter
        ? 'SELECT * FROM $table WHERE ${_quoteIdent(dateField.expr)} = \$1'
        : 'SELECT * FROM $table';
    final params = useFilter
        ? <Object>[DateTime(onDate.year, onDate.month, onDate.day)]
        : const <Object>[];

    final result = await _conn.execute(sql, parameters: params);

    final records = <Record>[];
    for (var i = 0; i < result.length; i++) {
      final row = result[i];
      final record = <String, Object?>{};
      for (var c = 0; c < result.schema.columns.length; c++) {
        final colName = result.schema.columns[c].columnName;
        if (colName == null) continue;
        final dim = view.dimensionByExpr(colName);
        if (dim == null) continue;
        record[dim.name] = row[c];
      }
      record[rowIndexKey] = i;
      records.add(record);
    }
    if (useFilter && view.plannable != null) {
      final logField = view.plannable!.logField;
      records.sort((a, b) {
        final av = a[logField]?.toString() ?? '';
        final bv = b[logField]?.toString() ?? '';
        if (av.isEmpty && bv.isEmpty) return 0;
        if (av.isEmpty) return 1;
        if (bv.isEmpty) return -1;
        return av.compareTo(bv);
      });
    }
    return records;
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async {
    final table = _quoteIdent(view.table);
    final toWrite = Map<String, Object?>.from(record);
    if (view.dimensionByName('id') != null && toWrite['id'] == null) {
      toWrite['id'] = _uuid();
    }

    final cols = <String>[];
    final placeholders = <String>[];
    final values = <Object?>[];
    var idx = 1;
    for (final d in view.dimensions) {
      if (!toWrite.containsKey(d.name)) continue;
      cols.add(_quoteIdent(d.expr));
      placeholders.add('\$$idx');
      values.add(_encodeValue(d.type, toWrite[d.name]));
      idx++;
    }

    await _conn.execute(
      'INSERT INTO $table (${cols.join(', ')}) '
      'VALUES (${placeholders.join(', ')})',
      parameters: values,
    );

    toWrite[rowIndexKey] = 0;
    return toWrite;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {
    final id = record['id'];
    if (id == null) {
      throw ArgumentError('PostgresConnector.update requires `id`');
    }
    final table = _quoteIdent(view.table);
    final sets = <String>[];
    final values = <Object?>[];
    var idx = 1;
    for (final d in view.dimensions) {
      if (d.name == 'id') continue;
      if (!record.containsKey(d.name)) continue;
      sets.add('${_quoteIdent(d.expr)} = \$$idx');
      values.add(_encodeValue(d.type, record[d.name]));
      idx++;
    }
    values.add(id.toString());
    await _conn.execute(
      'UPDATE $table SET ${sets.join(', ')} WHERE id = \$$idx',
      parameters: values,
    );
  }

  @override
  Future<void> delete(ViewSchema view, Record record) async {
    final id = record['id']?.toString();
    if (id == null || id.isEmpty) return;
    final table = _quoteIdent(view.table);
    await _conn.execute(
      'DELETE FROM $table WHERE id = \$1',
      parameters: [id],
    );
  }

  // ────── helpers ──────

  static String _quoteIdent(String s) => '"${s.replaceAll('"', '""')}"';

  static String _pgType(DimensionType t) {
    switch (t) {
      case DimensionType.string:
        return 'TEXT';
      case DimensionType.number:
        return 'DOUBLE PRECISION';
      case DimensionType.date:
        return 'DATE';
      case DimensionType.datetime:
        return 'TIMESTAMP';
      case DimensionType.boolean:
        return 'BOOLEAN';
    }
  }

  static Object? _encodeValue(DimensionType t, Object? value) {
    if (value == null) return null;
    if (t == DimensionType.date && value is String) {
      return DateTime.tryParse(value);
    }
    if (t == DimensionType.datetime && value is String) {
      return DateTime.tryParse(value);
    }
    // Reuse CellCodec.encode for shared coercion (handles num/bool/etc).
    final encoded = CellCodec.encode(t, value);
    return encoded;
  }

  static final _rand = Random.secure();

  static String _uuid() {
    final r = List<int>.generate(16, (_) => _rand.nextInt(256));
    r[6] = (r[6] & 0x0f) | 0x40;
    r[8] = (r[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = r.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
