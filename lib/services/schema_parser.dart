/// Pure-Dart YAML → [ViewSchema] parser. No Flutter imports so the same
/// code is usable from `dart run` CLI tools and from the Flutter runtime.
library;

import 'package:yaml/yaml.dart';

import '../models/view_schema.dart';

/// Parses raw YAML text into a [ViewSchema].
ViewSchema parseViewSchema(String yamlText) {
  final node = loadYaml(yamlText);
  if (node is! YamlMap) {
    throw const FormatException('Top-level YAML must be a map');
  }
  return _parseView(node);
}

ViewSchema _parseView(YamlMap node) {
  final name = _requireString(node, 'name');
  return ViewSchema(
    name: name,
    description: node['description'] as String?,
    datasource: (node['datasource'] as String?) ?? 'gsheets',
    table: (node['table'] as String?) ?? name,
    dateField: node['date_field'] as String?,
    spreadsheetId: node['spreadsheet_id'] as String?,
    entities: _parseList(node['entities'], _parseEntity),
    dimensions: _parseList(node['dimensions'], _parseDimension),
    measures: _parseList(node['measures'], _parseMeasure),
    listDisplay: node['list_display'] == null
        ? null
        : _parseListDisplay(node['list_display'] as YamlMap),
    plannable: node['plannable'] == null
        ? null
        : _parsePlannable(node['plannable'] as YamlMap),
  );
}

Plannable _parsePlannable(YamlMap node) {
  return Plannable(
    logField: _requireString(node, 'log_field'),
    logFormat: _parseLogFormat(_requireString(node, 'log_format')),
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

Entity _parseEntity(YamlMap node) {
  final keys = <String>[];
  if (node['key'] != null) keys.add(node['key'] as String);
  if (node['keys'] != null) {
    for (final k in (node['keys'] as YamlList)) {
      keys.add(k as String);
    }
  }
  return Entity(
    name: _requireString(node, 'name'),
    type: _parseEntityType(_requireString(node, 'type')),
    keys: keys,
  );
}

Dimension _parseDimension(YamlMap node) {
  return Dimension(
    name: _requireString(node, 'name'),
    type: _parseDimensionType(_requireString(node, 'type')),
    expr: (node['expr'] as String?) ?? _requireString(node, 'name'),
    description: node['description'] as String?,
    samples: node['samples'] == null
        ? null
        : (node['samples'] as YamlList).map((e) => e.toString()).toList(),
    input: node['input'] == null ? null : _parseInput(node['input'] as YamlMap),
    derive: node['derive'] == null
        ? null
        : _parseDerive(node['derive'] as YamlMap),
    showWhen: node['show_when'] == null
        ? null
        : <String, Object?>{
            for (final entry in (node['show_when'] as YamlMap).entries)
              entry.key.toString(): entry.value,
          },
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

Measure _parseMeasure(YamlMap node) {
  return Measure(
    name: _requireString(node, 'name'),
    type: _parseMeasureType(_requireString(node, 'type')),
    expr: node['expr'] as String?,
    description: node['description'] as String?,
  );
}

ListDisplay _parseListDisplay(YamlMap node) {
  return ListDisplay(
    title: _requireString(node, 'title'),
    subtitle: node['subtitle'] as String?,
  );
}

List<T> _parseList<T>(dynamic node, T Function(YamlMap) fn) {
  if (node == null) return [];
  if (node is! YamlList) {
    throw const FormatException('Expected a list');
  }
  return node.map((e) => fn(e as YamlMap)).toList();
}

String _requireString(YamlMap node, String key) {
  final v = node[key];
  if (v is! String) {
    throw FormatException('Missing or non-string field: $key');
  }
  return v;
}

DimensionType _parseDimensionType(String s) {
  switch (s) {
    case 'string':
      return DimensionType.string;
    case 'number':
      return DimensionType.number;
    case 'date':
      return DimensionType.date;
    case 'datetime':
      return DimensionType.datetime;
    case 'boolean':
      return DimensionType.boolean;
    default:
      throw FormatException('Unknown dimension type: $s');
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

EntityType _parseEntityType(String s) {
  switch (s) {
    case 'primary':
      return EntityType.primary;
    case 'foreign':
      return EntityType.foreign;
    default:
      throw FormatException('Unknown entity type: $s');
  }
}

MeasureType _parseMeasureType(String s) {
  switch (s) {
    case 'count':
      return MeasureType.count;
    case 'sum':
      return MeasureType.sum;
    case 'average':
      return MeasureType.average;
    case 'max':
      return MeasureType.max;
    case 'min':
      return MeasureType.min;
    case 'count_distinct':
      return MeasureType.countDistinct;
    default:
      throw FormatException('Unknown measure type: $s');
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
