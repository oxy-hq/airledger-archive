/// Dart-side subset of oxy's `.app.yml` format.
///
/// An app is a small declarative spec for an interactive analytics view:
///
///   - `controls`  — user inputs (dropdown, etc.) that get substituted into
///                   tasks via Jinja-style `{{ controls.<id> }}` references
///   - `tasks`     — data computations (semantic queries today; execute_sql
///                   later) that produce rows
///   - `display`   — UI elements (markdown text, line chart, table) that
///                   render task results
///
/// Apps live as `<schemas_repo>/apps/<name>.app.yml` and get bundled into
/// the Flutter app via `tool/sync_assets.sh`, then parsed at runtime.
library;

/// Top-level app definition.
class AppDef {
  final String name;
  final String? title;
  final String? description;
  final List<ControlDef> controls;
  final List<TaskDef> tasks;
  final List<DisplayDef> displays;

  AppDef({
    required this.name,
    this.title,
    this.description,
    this.controls = const [],
    this.tasks = const [],
    this.displays = const [],
  });
}

// ---- Controls --------------------------------------------------------------

/// A user-editable input that drives task substitution. Today: dropdown only.
sealed class ControlDef {
  final String id;
  final String? label;
  ControlDef({required this.id, this.label});
}

/// A dropdown whose options come either from a static list or from querying
/// distinct values of a dimension in a view (e.g. all distinct exercises in
/// the strength view, ordered by use frequency).
class DropdownControl extends ControlDef {
  /// Static options. Mutually exclusive with [optionsView].
  final List<String>? options;

  /// Dynamic options: pull distinct values from a view's dimension.
  final DimensionOptionsSource? optionsView;

  /// Default selection if [options] is non-empty.
  final String? defaultValue;

  DropdownControl({
    required super.id,
    super.label,
    this.options,
    this.optionsView,
    this.defaultValue,
  });
}

class DimensionOptionsSource {
  final String view;
  final String dimension;

  /// One of: `count_desc` (most-frequent first), `alpha` (alphabetical), or
  /// `count_asc`. Defaults to `count_desc`.
  final String order;
  final int? limit;

  DimensionOptionsSource({
    required this.view,
    required this.dimension,
    this.order = 'count_desc',
    this.limit,
  });
}

// ---- Tasks -----------------------------------------------------------------

sealed class TaskDef {
  final String name;
  TaskDef({required this.name});
}

/// `semantic_query`: declarative; routed through airlayer.compile. Strings in
/// any field can reference `{{ controls.<id> }}` and get substituted at run
/// time.
class SemanticQueryTask extends TaskDef {
  final String view;
  final List<String> measures;
  final List<String> dimensions;

  /// Each entry is a `{dim, op, value}` filter map. We keep filters as raw
  /// maps so we don't have to track airlayer's filter grammar in lockstep.
  final List<Map<String, dynamic>> filters;
  final List<Map<String, dynamic>> order;
  final int? limit;

  SemanticQueryTask({
    required super.name,
    required this.view,
    this.measures = const [],
    this.dimensions = const [],
    this.filters = const [],
    this.order = const [],
    this.limit,
  });
}

// ---- Display ---------------------------------------------------------------

sealed class DisplayDef {}

/// Inline markdown block. `text` may contain `{{ controls.<id> }}`.
class MarkdownDisplay extends DisplayDef {
  final String text;
  MarkdownDisplay(this.text);
}

/// fl_chart line chart: x and y are column names in [taskData]'s result rows.
class LineChartDisplay extends DisplayDef {
  final String taskData;
  final String x;
  final String y;
  final String? title;

  LineChartDisplay({
    required this.taskData,
    required this.x,
    required this.y,
    this.title,
  });
}

/// Tabular dump of a task's result rows. Useful for debugging an app.
class TableDisplay extends DisplayDef {
  final String taskData;
  final List<String>? columns;

  TableDisplay({required this.taskData, this.columns});
}
