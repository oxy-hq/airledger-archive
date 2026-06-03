import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';

import '../models/github_config.dart';
import '../models/model_config.dart';

/// Runtime config bundled in the APK at `assets/config.yaml`.
/// Baked at build time by `tool/brand.dart` from the schemas repo's
/// `config.yml` + `.env`.
class AppConfig {
  final String spreadsheetId;
  final List<ModelConfig> models;

  /// Top-level kill-switch for post-log LLM hooks. When true, the timeline
  /// skips the post-log hook even if a view has one defined and a model is
  /// configured. Set via `disable_post_log: true` in the repo `config.yml`.
  /// Useful for builds (e.g. Poke House) that want every other piece of
  /// the LLM plumbing inert.
  final bool disablePostLog;

  /// Optional GitHub config — drives the schema hot-reload + chat assistant.
  /// Null when the build has no `github:` block; the relevant features
  /// stay inert.
  final GithubConfig? github;

  AppConfig({
    required this.spreadsheetId,
    required this.models,
    this.disablePostLog = false,
    this.github,
  });

  static Future<AppConfig> load() async {
    final raw = await rootBundle.loadString('assets/config.yaml');
    final node = loadYaml(raw);
    if (node is! YamlMap) {
      throw const ConfigException(
        'assets/config.yaml: top-level must be a map',
      );
    }
    final spreadsheetId = node['spreadsheet_id'] as String?;
    if (spreadsheetId == null) {
      throw const ConfigException(
        'assets/config.yaml: missing spreadsheet_id',
      );
    }
    final modelsNode = node['models'];
    final models = <ModelConfig>[];
    if (modelsNode is YamlList) {
      for (final entry in modelsNode) {
        if (entry is! YamlMap) continue;
        models.add(ModelConfig.fromYaml(_yamlMapToJson(entry)));
      }
    }
    return AppConfig(
      spreadsheetId: spreadsheetId,
      models: models,
      disablePostLog: (node['disable_post_log'] as bool?) ?? false,
      github: node['github'] is YamlMap
          ? GithubConfig.fromYaml(_yamlMapToJson(node['github'] as YamlMap))
          : null,
    );
  }
}

Map<String, dynamic> _yamlMapToJson(YamlMap m) => {
      for (final entry in m.entries) entry.key.toString(): entry.value,
    };

class ConfigException implements Exception {
  final String message;
  const ConfigException(this.message);
  @override
  String toString() => message;
}
