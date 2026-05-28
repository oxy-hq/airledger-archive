import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import '../models/template.dart';
import 'remote_sync.dart';

/// Loads template YAML files. Priority order:
/// 1. Local cache (`<documents>/templates/<view>/*.yml`) — populated by
///    [RemoteSync.refresh] from a configured GitHub repo.
/// 2. Bundled assets (`assets/templates/<view>/*.yml`) — fallback.
class TemplateLoader {
  static const _prefix = 'assets/templates/';

  /// Returns all templates for [viewName], sorted by name.
  static Future<List<Template>> loadForView(String viewName) async {
    final cached = await _loadFromCache(viewName);
    if (cached.isNotEmpty) return cached;
    return _loadFromAssets(viewName);
  }

  static Future<List<Template>> _loadFromCache(String viewName) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir =
        Directory('${docs.path}/${RemoteSync.templatesDirName}/$viewName');
    if (!dir.existsSync()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))
        .toList();
    if (files.isEmpty) return const [];
    final templates = <Template>[];
    for (final f in files) {
      templates.add(_parse(f.readAsStringSync()));
    }
    templates.sort((a, b) => a.name.compareTo(b.name));
    return templates;
  }

  static Future<List<Template>> _loadFromAssets(String viewName) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final viewPrefix = '$_prefix$viewName/';
    final paths = manifest
        .listAssets()
        .where((k) => k.startsWith(viewPrefix) && k.endsWith('.yml'))
        .toList();
    final templates = <Template>[];
    for (final path in paths) {
      final raw = await rootBundle.loadString(path);
      templates.add(_parse(raw));
    }
    templates.sort((a, b) => a.name.compareTo(b.name));
    return templates;
  }

  static Template _parse(String yamlText) {
    final node = loadYaml(yamlText);
    if (node is! YamlMap) {
      throw const FormatException('Template YAML must be a map');
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

    return Template(
      name: node['name'] as String,
      view: node['view'] as String,
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
