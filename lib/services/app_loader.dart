import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:yaml/yaml.dart';

import '../models/app_def.dart';

/// Loads `.app.yml` files bundled under `assets/apps/`. Each one is a
/// declarative app spec consumed by [AppRuntime]. Same flow as
/// [TemplateLoader] / [SchemaLoader].
class AppLoader {
  static const _prefix = 'assets/apps/';

  static Future<List<AppDef>> loadAll() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest
        .listAssets()
        .where((k) => k.startsWith(_prefix) && k.endsWith('.app.yml'))
        .toList()
      ..sort();
    final out = <AppDef>[];
    for (final path in paths) {
      final raw = await rootBundle.loadString(path);
      out.add(_parse(raw));
    }
    return out;
  }

  static AppDef _parse(String yamlText) {
    final node = loadYaml(yamlText);
    if (node is! YamlMap) {
      throw const FormatException('App YAML must be a map');
    }
    return AppDef(
      name: node['name'] as String,
      title: node['title'] as String?,
      description: node['description'] as String?,
      controls: _parseControls(node['controls']),
      tasks: _parseTasks(node['tasks']),
      displays: _parseDisplays(node['display'] ?? node['displays']),
    );
  }

  static List<ControlDef> _parseControls(dynamic node) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw const FormatException('`controls` must be a list');
    }
    return node.map((c) => _parseControl(c as YamlMap)).toList();
  }

  static ControlDef _parseControl(YamlMap node) {
    final type = (node['type'] as String?) ?? 'dropdown';
    if (type != 'dropdown') {
      throw FormatException('Unsupported control type: $type');
    }
    final optsView = node['options_from'];
    return DropdownControl(
      id: node['id'] as String,
      label: node['label'] as String?,
      options: node['options'] == null
          ? null
          : (node['options'] as YamlList).map((e) => e.toString()).toList(),
      optionsView: optsView == null
          ? null
          : DimensionOptionsSource(
              view: (optsView as YamlMap)['view'] as String,
              dimension: optsView['dimension'] as String,
              order: (optsView['order'] as String?) ?? 'count_desc',
              limit: (optsView['limit'] as int?),
            ),
      defaultValue: node['default'] as String?,
    );
  }

  static List<TaskDef> _parseTasks(dynamic node) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw const FormatException('`tasks` must be a list');
    }
    return node.map((t) => _parseTask(t as YamlMap)).toList();
  }

  static TaskDef _parseTask(YamlMap node) {
    final name = node['name'] as String;
    final sq = node['semantic_query'];
    if (sq is YamlMap) {
      return SemanticQueryTask(
        name: name,
        view: sq['view'] as String,
        measures: _stringList(sq['measures']),
        dimensions: _stringList(sq['dimensions']),
        filters: _mapList(sq['filters']),
        order: _mapList(sq['order']),
        limit: sq['limit'] as int?,
      );
    }
    throw FormatException('Task $name has no recognized body (need semantic_query)');
  }

  static List<DisplayDef> _parseDisplays(dynamic node) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw const FormatException('`display` must be a list');
    }
    return node.map((d) => _parseDisplay(d as YamlMap)).toList();
  }

  static DisplayDef _parseDisplay(YamlMap node) {
    if (node.containsKey('markdown')) {
      return MarkdownDisplay(node['markdown'].toString());
    }
    if (node.containsKey('line_chart')) {
      final body = node['line_chart'] as YamlMap;
      return LineChartDisplay(
        taskData: body['data'] as String,
        x: body['x'] as String,
        y: body['y'] as String,
        title: body['title'] as String?,
      );
    }
    if (node.containsKey('table')) {
      final body = node['table'] as YamlMap;
      return TableDisplay(
        taskData: body['data'] as String,
        columns: body['columns'] == null
            ? null
            : (body['columns'] as YamlList).map((e) => e.toString()).toList(),
      );
    }
    throw FormatException('Unknown display type: ${node.keys.toList()}');
  }

  static List<String> _stringList(dynamic node) {
    if (node == null) return const [];
    return (node as YamlList).map((e) => e.toString()).toList();
  }

  static List<Map<String, dynamic>> _mapList(dynamic node) {
    if (node == null) return const [];
    return (node as YamlList)
        .map((e) => {for (final k in (e as YamlMap).keys) k.toString(): e[k]})
        .toList();
  }
}
