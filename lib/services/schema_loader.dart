import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/view_schema.dart';
import 'remote_sync.dart';
import 'schema_parser.dart';

/// Loads `.view.yml` files. Priority order:
/// 1. Local cache (`<documents>/schemas/*.view.yml`) — populated by
///    [RemoteSync.refresh] from a configured GitHub repo.
/// 2. Bundled assets (`assets/schemas/*.view.yml`) — fallback when no remote
///    sync has run.
class SchemaLoader {
  static const _schemaAssetPrefix = 'assets/schemas/';

  static Future<List<ViewSchema>> loadAll() async {
    final cached = await _loadFromCache();
    if (cached.isNotEmpty) return cached;
    return _loadFromAssets();
  }

  static Future<List<ViewSchema>> _loadFromCache() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/${RemoteSync.schemasDirName}');
    if (!dir.existsSync()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.view.yml'))
        .toList();
    if (files.isEmpty) return const [];
    final views = <ViewSchema>[];
    for (final f in files) {
      try {
        views.add(parseViewSchema(f.readAsStringSync()));
      } catch (e) {
        throw SchemaLoadException('Failed to parse ${f.path}: $e');
      }
    }
    views.sort((a, b) => a.name.compareTo(b.name));
    return views;
  }

  static Future<List<ViewSchema>> _loadFromAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final viewPaths = manifest
        .listAssets()
        .where((k) =>
            k.startsWith(_schemaAssetPrefix) && k.endsWith('.view.yml'))
        .toList();

    final views = <ViewSchema>[];
    for (final path in viewPaths) {
      final raw = await rootBundle.loadString(path);
      try {
        views.add(parseViewSchema(raw));
      } catch (e) {
        throw SchemaLoadException('Failed to parse $path: $e');
      }
    }
    views.sort((a, b) => a.name.compareTo(b.name));
    return views;
  }
}

class SchemaLoadException implements Exception {
  final String message;
  const SchemaLoadException(this.message);
  @override
  String toString() => 'SchemaLoadException: $message';
}
