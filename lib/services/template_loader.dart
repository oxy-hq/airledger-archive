import 'package:yaml/yaml.dart';

import '../models/template.dart';
import 'schema_files.dart';

/// Loads template YAML files. Templates live next to their paired
/// `.view.yml` using oxy-style basename pairing (mirrors the agent +
/// `.test.yml` precedent in oxy-internal):
///
///   views/strength.view.yml                  ← parent (semantic)
///   views/strength.input.yml                 ← paired input overlay
///   views/strength.cut_deadlift_heavy.template.yml   ← paired template
///   views/strength.cut_squat_heavy.template.yml
///
/// Source: bundled assets initially, SchemaSync cache after a refresh.
/// See [listAllSchemaFiles].
class TemplateLoader {
  /// Returns all templates for [viewName], sorted by name.
  static Future<List<Template>> loadForView(String viewName) async {
    final files = await listAllSchemaFiles();
    final matching = files
        .where((f) => _isTemplateFor(f.basename, viewName))
        .toList();
    final templates = <Template>[];
    for (final f in matching) {
      final raw = await f.read();
      templates.add(_parse(raw, f.basename, viewName));
    }
    templates.sort((a, b) => a.name.compareTo(b.name));
    return templates;
  }

  static bool _isTemplateFor(String basename, String viewName) {
    if (!basename.endsWith('.template.yml')) return false;
    if (!basename.startsWith('$viewName.')) return false;
    final middle = basename.substring(
        viewName.length + 1, basename.length - '.template.yml'.length);
    return middle.isNotEmpty;
  }

  static Template _parse(String yamlText, String basename, String expectedView) {
    final node = loadYaml(yamlText);
    if (node is! YamlMap) {
      throw const FormatException('Template YAML must be a map');
    }
    final target = node['target'];
    if (target is! String || !target.endsWith('.view.yml')) {
      throw FormatException(
        'Template $basename: missing or malformed `target:`. '
        'Expected: target: <view_name>.view.yml',
      );
    }
    final declaredView =
        target.substring(0, target.length - '.view.yml'.length);
    if (declaredView != expectedView) {
      throw FormatException(
        'Template $basename: target ($declaredView) does not match '
        'expected view ($expectedView)',
      );
    }

    final entriesNode = node['entries'];
    if (entriesNode is! YamlList) {
      throw const FormatException('Template must have an `entries` list');
    }
    final entries = <Map<String, Object?>>[];
    for (final e in entriesNode) {
      if (e is! YamlMap) {
        throw const FormatException('Each entry must be a map');
      }
      entries.add({for (final k in e.keys) k.toString(): e[k]});
    }

    final variables = <TemplateVariable>[];
    final varsNode = node['variables'];
    if (varsNode is YamlList) {
      for (final v in varsNode) {
        if (v is! YamlMap) {
          throw const FormatException('Each variable must be a map');
        }
        variables.add(_parseVariable(v));
      }
    }

    final middle = basename.substring(
      expectedView.length + 1,
      basename.length - '.template.yml'.length,
    );
    return Template(
      name: (node['name'] as String?) ?? middle,
      view: expectedView,
      description: node['description'] as String?,
      variables: variables,
      entries: entries,
    );
  }

  static TemplateVariable _parseVariable(YamlMap v) {
    final name = v['name'] as String;
    final typeStr = (v['type'] as String?) ?? 'string';
    final type = typeStr == 'number'
        ? TemplateVarType.number
        : TemplateVarType.string;
    return TemplateVariable(
      name: name,
      label: (v['label'] as String?) ?? name,
      type: type,
      defaultValue: v['default'],
    );
  }
}
