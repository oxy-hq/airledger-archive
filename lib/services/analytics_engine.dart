import 'package:airlayer/airlayer.dart';

import '../models/view_schema.dart';
import 'local_db.dart';

/// Bridges airlayer (SQL compilation) and LocalDb (execution). One instance
/// owns the native airlayer binding and the local SQLite cache, so the rest
/// of the app can ask "give me rows for query X" without caring about either.
class AnalyticsEngine {
  final Airlayer _airlayer;
  final LocalDb _db;

  AnalyticsEngine._(this._airlayer, this._db);

  static Future<AnalyticsEngine> create() async {
    final airlayer = Airlayer.load();
    final db = await LocalDb.open();
    return AnalyticsEngine._(airlayer, db);
  }

  String get airlayerVersion => _airlayer.version;
  LocalDb get db => _db;

  /// Build a view YAML on the fly from a [ViewSchema]. We do this rather than
  /// loading the raw `.view.yml` file because airlayer needs the dialect
  /// pinned to `sqlite` (the ledger app's view files declare `datasource:
  /// gsheets` which isn't a SQL dialect).
  ///
  /// Dimension exprs are quoted because sheet column headers can contain
  /// spaces ("Start Time"). Measure exprs are passed through verbatim so
  /// formulas like `Weight * (1 + Reps / 30.0)` Just Work.
  String viewYamlForAnalytics(ViewSchema view) {
    final buf = StringBuffer()
      ..writeln('name: ${view.name}')
      ..writeln('datasource: local')
      ..writeln('dialect: sqlite')
      ..writeln('table: "${view.table}"')
      ..writeln('dimensions:');
    for (final d in view.dimensions) {
      buf..writeln('  - name: ${d.name}')
        ..writeln('    type: ${_dimType(d.type)}')
        ..writeln('    expr: \'"${d.expr}"\'');
    }
    buf.writeln('measures:');
    // Always include row_count so any view supports `<view>.row_count` queries
    // even when the schema author didn't declare it explicitly.
    buf.writeln('  - name: row_count');
    buf.writeln('    type: count');
    for (final m in view.measures) {
      if (m.name == 'row_count') continue; // dedupe
      buf
        ..writeln('  - name: ${m.name}')
        ..writeln('    type: ${_measureType(m.type)}');
      if (m.expr != null) {
        buf.writeln('    expr: ${_escapeYamlString(m.expr!)}');
      }
    }
    return buf.toString();
  }

  /// Compile [query] against [view] and execute the resulting SQL against
  /// the local SQLite cache. Returns the result rows (column name → value).
  Future<List<Map<String, Object?>>> run(
    ViewSchema view, {
    required Map<String, dynamic> query,
    String? extraViewYaml,
  }) async {
    final yaml = extraViewYaml ?? viewYamlForAnalytics(view);
    final compiled = _airlayer.compile(
      views: [yaml],
      query: query,
      dialect: 'sqlite',
    );
    return _db.query(compiled.sql, compiled.params);
  }

  String _dimType(DimensionType t) {
    switch (t) {
      case DimensionType.string:
        return 'string';
      case DimensionType.number:
        return 'number';
      case DimensionType.date:
        return 'date';
      case DimensionType.datetime:
        return 'datetime';
      case DimensionType.boolean:
        return 'boolean';
    }
  }

  String _measureType(MeasureType t) {
    switch (t) {
      case MeasureType.count:
        return 'count';
      case MeasureType.sum:
        return 'sum';
      case MeasureType.average:
        return 'average';
      case MeasureType.max:
        return 'max';
      case MeasureType.min:
        return 'min';
      case MeasureType.countDistinct:
        return 'count_distinct';
      case MeasureType.custom:
        return 'custom';
      case MeasureType.number:
        return 'number';
    }
  }

  /// Quote a measure expression for YAML emission. Single quotes are safest:
  /// they preserve double quotes verbatim (useful for "Column Name"
  /// references) and only require doubling internal single quotes.
  String _escapeYamlString(String s) {
    final escaped = s.replaceAll("'", "''");
    return "'$escaped'";
  }
}
