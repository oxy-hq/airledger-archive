/// Pure-Dart YAML → input-layer overlay parser.
///
/// `.input.yml` files carry the input-layer concerns for a paired
/// `<name>.view.yml`:
///
///   - view-level: `date_field`, `plannable`, `list_display`,
///     `spreadsheet_id`
///   - per-dimension: `input`, `samples`, `show_when`, `derive`
///
/// The `view:` field is the back-pointer (must match the paired
/// `.view.yml`'s `name:`). Per-dimension overlays are keyed by dimension
/// name.
///
/// Applying an overlay returns a new [ViewSchema] with the input-layer
/// fields populated. See `schema_parser.dart` for the semantic-layer
/// half.
library;

import 'package:yaml/yaml.dart';

import '../models/view_schema.dart';

class InputOverlay {
  final String viewName;
  final String? dateField;
  final Plannable? plannable;
  final ListDisplay? listDisplay;
  final String? spreadsheetId;

  /// Per-dimension overlays, keyed by dimension name.
  final Map<String, DimensionOverlay> dimensions;

  InputOverlay({
    required this.viewName,
    this.dateField,
    this.plannable,
    this.listDisplay,
    this.spreadsheetId,
    this.dimensions = const {},
  });
}

class DimensionOverlay {
  final InputSpec? input;
  final List<String>? samples;
  final Map<String, Object?>? showWhen;
  final Derive? derive;

  DimensionOverlay({this.input, this.samples, this.showWhen, this.derive});
}

InputOverlay parseInputOverlay(String yamlText) {
  final node = loadYaml(yamlText);
  if (node is! YamlMap) {
    throw const FormatException('Top-level YAML must be a map');
  }
  // `target:` points at the paired .view.yml by full filename, mirroring
  // oxy's .test.yml → target: <agent>.agent.yml convention. The view name
  // is derived from the basename minus the .view.yml extension.
  final target = node['target'];
  if (target is! String || !target.endsWith('.view.yml')) {
    throw const FormatException(
      'Missing or malformed `target:` field in .input.yml. '
      'Expected: target: <view_name>.view.yml',
    );
  }
  final viewName = target.substring(0, target.length - '.view.yml'.length);
  final dimensions = <String, DimensionOverlay>{};
  final dimsNode = node['dimensions'];
  if (dimsNode is YamlMap) {
    for (final entry in dimsNode.entries) {
      final dimName = entry.key.toString();
      final v = entry.value;
      if (v is! YamlMap) {
        throw FormatException(
          'Dimension overlay for "$dimName" must be a map',
        );
      }
      dimensions[dimName] = _parseDimensionOverlay(v);
    }
  } else if (dimsNode != null) {
    throw const FormatException(
      'dimensions: must be a map keyed by dimension name in .input.yml',
    );
  }
  return InputOverlay(
    viewName: viewName,
    dateField: node['date_field'] as String?,
    plannable: node['plannable'] == null
        ? null
        : _parsePlannable(node['plannable'] as YamlMap),
    listDisplay: node['list_display'] == null
        ? null
        : _parseListDisplay(node['list_display'] as YamlMap),
    spreadsheetId: node['spreadsheet_id'] as String?,
    dimensions: dimensions,
  );
}

DimensionOverlay _parseDimensionOverlay(YamlMap node) {
  return DimensionOverlay(
    input: node['input'] == null ? null : _parseInput(node['input'] as YamlMap),
    samples: node['samples'] == null
        ? null
        : (node['samples'] as YamlList).map((e) => e.toString()).toList(),
    showWhen: node['show_when'] == null
        ? null
        : <String, Object?>{
            for (final entry in (node['show_when'] as YamlMap).entries)
              entry.key.toString(): entry.value,
          },
    derive: node['derive'] == null
        ? null
        : _parseDerive(node['derive'] as YamlMap),
  );
}

Plannable _parsePlannable(YamlMap node) {
  return Plannable(
    logField: _requireString(node, 'log_field'),
    logFormat: _parseLogFormat(_requireString(node, 'log_format')),
  );
}

InputSpec _parseInput(YamlMap node) {
  return InputSpec(
    widget: _parseWidgetType((node['widget'] as String?) ?? 'text'),
    required: (node['required'] as bool?) ?? false,
    defaultValue: node['default'],
    min: node['min'] as num?,
    max: node['max'] as num?,
    options: node['options'] == null
        ? null
        : (node['options'] as YamlList).map((e) => e.toString()).toList(),
    placeholder: node['placeholder'] as String?,
    editable: (node['editable'] as bool?) ?? true,
    nowButton: (node['now_button'] as bool?) ?? false,
  );
}

Derive _parseDerive(YamlMap node) {
  return Derive(
    from: _requireString(node, 'from'),
    format: _parseDeriveFormat(_requireString(node, 'format')),
  );
}

ListDisplay _parseListDisplay(YamlMap node) {
  return ListDisplay(
    title: _requireString(node, 'title'),
    subtitle: node['subtitle'] as String?,
  );
}

LogFormat _parseLogFormat(String s) {
  switch (s) {
    case 'time_string':
      return LogFormat.timeString;
    case 'iso_time':
      return LogFormat.isoTime;
    case 'iso_datetime':
      return LogFormat.isoDateTime;
    default:
      throw FormatException('Unknown log format: $s');
  }
}

WidgetType _parseWidgetType(String s) {
  switch (s) {
    case 'text':
      return WidgetType.text;
    case 'longtext':
      return WidgetType.longtext;
    case 'number':
      return WidgetType.number;
    case 'date':
      return WidgetType.date;
    case 'datetime':
      return WidgetType.datetime;
    case 'dropdown':
      return WidgetType.dropdown;
    case 'autocomplete':
      return WidgetType.autocomplete;
    default:
      throw FormatException('Unknown widget type: $s');
  }
}

DeriveFormat _parseDeriveFormat(String s) {
  switch (s) {
    case 'weekday_long':
      return DeriveFormat.weekdayLong;
    case 'weekday_short':
      return DeriveFormat.weekdayShort;
    case 'iso_date':
      return DeriveFormat.isoDate;
    case 'iso_datetime':
      return DeriveFormat.isoDateTime;
    default:
      throw FormatException('Unknown derive format: $s');
  }
}

String _requireString(YamlMap node, String key) {
  final v = node[key];
  if (v is! String) {
    throw FormatException('Missing or non-string field: $key');
  }
  return v;
}

/// Merges [overlay] into [view], returning a new [ViewSchema] with
/// input-layer fields populated. Throws if [overlay] references a
/// dimension not declared in [view].
ViewSchema applyInputOverlay(ViewSchema view, InputOverlay overlay) {
  if (overlay.viewName != view.name) {
    throw FormatException(
      'Input overlay view-name mismatch: '
      '${view.name} (.view.yml) != ${overlay.viewName} (.input.yml)',
    );
  }
  final declared = {for (final d in view.dimensions) d.name};
  for (final dimName in overlay.dimensions.keys) {
    if (!declared.contains(dimName)) {
      throw FormatException(
        '.input.yml references dimension "$dimName" '
        'that is not declared in .view.yml ($declared)',
      );
    }
  }
  final newDimensions = view.dimensions.map((d) {
    final o = overlay.dimensions[d.name];
    if (o == null) return d;
    return Dimension(
      name: d.name,
      type: d.type,
      expr: d.expr,
      description: d.description,
      input: o.input,
      samples: o.samples,
      showWhen: o.showWhen,
      derive: o.derive,
    );
  }).toList();
  return ViewSchema(
    name: view.name,
    description: view.description,
    datasource: view.datasource,
    table: view.table,
    dateField: overlay.dateField,
    spreadsheetId: overlay.spreadsheetId,
    entities: view.entities,
    dimensions: newDimensions,
    measures: view.measures,
    listDisplay: overlay.listDisplay,
    plannable: overlay.plannable,
  );
}
