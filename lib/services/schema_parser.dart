/// Pure-Dart YAML → [ViewSchema] parser for the semantic layer.
///
/// Recognizes ONLY semantic-layer fields:
///   name, description, datasource, table
///   entities, dimensions (name/type/expr/description), measures
///
/// Input-layer fields (`input:`, `samples:`, `derive:`, `show_when:`,
/// `plannable:`, `list_display:`, `date_field:`, `spreadsheet_id:`)
/// are silently ignored if present — they live in a paired
/// `<name>.input.yml` file. See `input_parser.dart` and
/// `docs/oxy-compatibility.md`.
///
/// No Flutter imports so the same code is usable from `dart run` tools.
library;

import 'package:yaml/yaml.dart';

import '../models/view_schema.dart';

/// Parses raw YAML text into a [ViewSchema] with empty input-layer fields.
/// Apply a [InputOverlay] from the paired `.input.yml` via
/// `applyInputOverlay` to populate them.
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
    entities: _parseList(node['entities'], _parseEntity),
    dimensions: _parseList(node['dimensions'], _parseDimension),
    measures: _parseList(node['measures'], _parseMeasure),
    // Input-layer fields are intentionally NOT read here. They're populated
    // when a `.input.yml` overlay is applied.
  );
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
    // input/samples/derive/show_when intentionally NOT read — overlay only.
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
