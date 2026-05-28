import 'package:jinja/jinja.dart' hide Template;

import '../models/app_def.dart';
import '../models/view_schema.dart';
import 'analytics_engine.dart';

/// Executes an [AppDef]: resolves controls, substitutes them into tasks via
/// Jinja, runs each task through [AnalyticsEngine], and returns a result
/// map keyed by task name.
///
/// The UI layer ([AppViewerScreen]) holds the live control state and calls
/// [run] every time a control changes.
class AppRuntime {
  final AppDef app;
  final List<ViewSchema> views;
  final AnalyticsEngine engine;

  AppRuntime({required this.app, required this.views, required this.engine});

  /// Fetch the options list for a [DimensionOptionsSource] — the dropdown
  /// builder calls this once when the screen mounts.
  Future<List<String>> resolveOptions(DimensionOptionsSource source) async {
    final view = _viewByName(source.view);
    final dim = view.dimensionByName(source.dimension)
        ?? (throw StateError('No dimension ${source.dimension} on ${source.view}'));
    final orderClause = switch (source.order) {
      'alpha' => 'ORDER BY "${dim.expr}" ASC',
      'count_asc' => 'ORDER BY n ASC',
      _ => 'ORDER BY n DESC',
    };
    final limitClause = source.limit == null ? '' : 'LIMIT ${source.limit}';
    final sql = '''
      SELECT "${dim.expr}" AS v, COUNT(*) AS n
      FROM "${view.table}"
      WHERE "${dim.expr}" IS NOT NULL AND "${dim.expr}" != ''
      GROUP BY 1
      $orderClause
      $limitClause
    ''';
    final rows = await engine.db.query(sql);
    return rows.map((r) => r['v']!.toString()).toList();
  }

  /// Runs every task. Returns a map of task name → result rows.
  Future<Map<String, List<Map<String, Object?>>>> run(
    Map<String, String?> controlValues,
  ) async {
    final out = <String, List<Map<String, Object?>>>{};
    for (final task in app.tasks) {
      if (task is SemanticQueryTask) {
        final view = _viewByName(task.view);
        final query = _buildSemanticQuery(task, controlValues);
        final rows = await engine.run(view, query: query);
        out[task.name] = rows;
      }
    }
    return out;
  }

  /// Build the JSON query object airlayer expects, with `{{ controls.x }}`
  /// substituted in any string fields.
  Map<String, dynamic> _buildSemanticQuery(
    SemanticQueryTask task,
    Map<String, String?> controlValues,
  ) {
    final env = Environment();
    final context = {'controls': controlValues};
    String sub(String s) => env.fromString(s).render(context);
    dynamic subDeep(dynamic v) {
      if (v is String) return sub(v);
      if (v is Map) return {for (final k in v.keys) k.toString(): subDeep(v[k])};
      if (v is List) return v.map(subDeep).toList();
      return v;
    }

    final filters = task.filters
        .map((f) {
          final dim = (f['dim'] ?? f['field'] ?? f['member']).toString();
          final op = (f['op'] ?? 'eq').toString();
          final value = subDeep(f['value']);
          if (value == null || (value is String && value.isEmpty)) return null;
          return {
            'member': dim,
            'operator': _airlayerOp(op),
            'values': value is List ? value : [value],
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    return {
      if (task.measures.isNotEmpty) 'measures': task.measures,
      if (task.dimensions.isNotEmpty) 'dimensions': task.dimensions,
      if (filters.isNotEmpty) 'filters': filters,
      if (task.order.isNotEmpty) 'order': task.order,
      if (task.limit != null) 'limit': task.limit,
    };
  }

  /// Map our friendly filter ops to airlayer's expected operator strings.
  String _airlayerOp(String op) {
    switch (op) {
      case 'eq':
      case '=':
        return 'equals';
      case 'neq':
      case '!=':
        return 'notEquals';
      case 'in':
        return 'equals'; // multi-value via `values: [...]`
      case 'gt':
        return 'gt';
      case 'gte':
        return 'gte';
      case 'lt':
        return 'lt';
      case 'lte':
        return 'lte';
      default:
        return op;
    }
  }

  ViewSchema _viewByName(String name) {
    return views.firstWhere(
      (v) => v.name == name,
      orElse: () => throw StateError('No view named $name'),
    );
  }
}
