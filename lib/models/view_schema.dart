/// Parsed representation of a `.view.yml` file from the schemas repo.
///
/// The schema combines two concerns in one file:
/// - The semantic layer (entities, dimensions, measures) — compatible with the
///   oxy/airlayer Cube-inspired format.
/// - The input layer (per-dimension `input:` block, top-level `date_field`,
///   `list_display`) — CRUD-specific extensions that the semantic-layer tools
///   ignore.
library;

enum DimensionType { string, number, date, datetime, boolean }

enum WidgetType { text, longtext, number, date, datetime, dropdown, autocomplete }

enum EntityType { primary, foreign }

enum MeasureType { count, sum, average, max, min, countDistinct }

/// Format used by the `derive:` block to compute a hidden field at save time.
enum DeriveFormat { weekdayLong, weekdayShort, isoDate, isoDateTime }

/// Format used by the `plannable.log_format` field for the "Log now" action.
enum LogFormat { timeString, isoTime, isoDateTime }

class ViewSchema {
  final String name;
  final String? description;
  final String datasource;
  final String table;
  final String? dateField;

  /// Optional per-view override of the default spreadsheet id (from
  /// `assets/config.yaml`). Lets one view target a different sheet without
  /// affecting others.
  final String? spreadsheetId;

  final List<Entity> entities;
  final List<Dimension> dimensions;
  final List<Measure> measures;
  final ListDisplay? listDisplay;
  final Plannable? plannable;

  /// Icon shown on the HomeScreen view tile and in tile leadings.
  /// Resolved via [IconResolver] — accepts lucide names (`dumbbell`),
  /// emoji (`💪`), or URLs.
  final String? icon;

  ViewSchema({
    required this.name,
    this.description,
    required this.datasource,
    required this.table,
    this.dateField,
    this.spreadsheetId,
    required this.entities,
    required this.dimensions,
    required this.measures,
    this.listDisplay,
    this.plannable,
    this.icon,
  });

  Dimension? dimensionByName(String name) =>
      dimensions.where((d) => d.name == name).firstOrNull;

  /// Looks up a dimension by its `expr` (the sheet column name).
  /// Falls back to `name` for backward compatibility with views whose
  /// dimensions don't specify expr.
  Dimension? dimensionByExpr(String expr) =>
      dimensions.where((d) => d.expr == expr).firstOrNull ??
      dimensions.where((d) => d.name == expr).firstOrNull;

  /// Dimensions that should appear in the entry form (input.editable != false
  /// and not derived).
  List<Dimension> get editableDimensions => dimensions
      .where((d) => (d.input?.editable ?? true) && d.derive == null)
      .toList();

  /// Dimensions with a `derive:` block (auto-computed at save time).
  List<Dimension> get derivedDimensions =>
      dimensions.where((d) => d.derive != null).toList();
}

class Entity {
  final String name;
  final EntityType type;
  final List<String> keys;

  Entity({required this.name, required this.type, required this.keys});
}

class Dimension {
  final String name;
  final DimensionType type;
  final String expr;
  final String? description;
  final List<String>? samples;
  final InputSpec? input;
  final Derive? derive;

  /// Conditional visibility: only show this dimension in the form when every
  /// (key, value) pair here matches the form's current values. Used for
  /// polymorphic records like cardio sets where treadmill-specific fields
  /// should only appear when type=treadmill.
  ///
  /// Comparison is loose: dimension values are compared by `==` after
  /// coercing both sides to their string form (handles num/string mismatches
  /// from form vs YAML).
  final Map<String, Object?>? showWhen;

  Dimension({
    required this.name,
    required this.type,
    required this.expr,
    this.description,
    this.samples,
    this.input,
    this.derive,
    this.showWhen,
  });

  /// Whether this dimension should be visible in the form given the current
  /// values map. Always visible when `show_when` is absent.
  bool isVisibleGiven(Map<String, Object?> values) {
    if (showWhen == null) return true;
    for (final entry in showWhen!.entries) {
      final actual = values[entry.key];
      if (actual?.toString() != entry.value?.toString()) return false;
    }
    return true;
  }
}

class InputSpec {
  final WidgetType widget;
  final bool required;
  final dynamic defaultValue;
  final num? min;
  final num? max;
  final List<String>? options;
  final String? placeholder;
  final bool editable;

  /// If true, the field renders a clock-icon suffix button that stamps the
  /// current time (formatted like "3:54:00 PM") into the field on tap.
  /// Useful for "Start Time"-style columns.
  final bool nowButton;

  InputSpec({
    required this.widget,
    this.required = false,
    this.defaultValue,
    this.min,
    this.max,
    this.options,
    this.placeholder,
    this.editable = true,
    this.nowButton = false,
  });
}

/// A small derived-field spec: take the value of dimension [from], pass it
/// through [format], and write the result into this dimension at save time.
/// Derived dimensions are hidden from the form.
class Derive {
  final String from;
  final DeriveFormat format;

  Derive({required this.from, required this.format});
}

class Measure {
  final String name;
  final MeasureType type;
  final String? expr;
  final String? description;

  Measure({
    required this.name,
    required this.type,
    this.expr,
    this.description,
  });
}

class ListDisplay {
  final String title;
  final String? subtitle;

  ListDisplay({required this.title, this.subtitle});
}

/// Config for "plan then log" workflow: rows with [logField] empty are
/// considered planned and get a "Log now" action in the timeline.
class Plannable {
  final String logField;
  final LogFormat logFormat;

  Plannable({required this.logField, required this.logFormat});
}
