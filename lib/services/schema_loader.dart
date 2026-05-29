import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/view_schema.dart';
import 'input_parser.dart';
import 'remote_sync.dart';
import 'schema_parser.dart';

/// Loads `.view.yml` files paired with `.input.yml` overlays.
///
/// Priority order per file:
/// 1. Local cache (`<documents>/schemas/`) — populated by
///    [RemoteSync.refresh] from a configured GitHub repo.
/// 2. Bundled assets (`assets/schemas/`).
///
/// For each `<name>.view.yml` found, the loader looks for a paired
/// `<name>.input.yml` in the same directory. If present, the overlay is
/// applied to populate input-layer fields. If absent, the view loads
/// with only the semantic-layer fields (suitable for read-only / analytics
/// views).
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
    final viewFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.view.yml'))
        .toList();
    if (viewFiles.isEmpty) return const [];
    final views = <ViewSchema>[];
    for (final viewFile in viewFiles) {
      try {
        final view = parseViewSchema(viewFile.readAsStringSync());
        // Look for paired .input.yml
        final inputPath =
            viewFile.path.replaceAll(RegExp(r'\.view\.yml$'), '.input.yml');
        final inputFile = File(inputPath);
        if (inputFile.existsSync()) {
          final overlay = parseInputOverlay(inputFile.readAsStringSync());
          views.add(applyInputOverlay(view, overlay));
        } else {
          views.add(view);
        }
      } catch (e) {
        throw SchemaLoadException('Failed to parse ${viewFile.path}: $e');
      }
    }
    views.sort((a, b) => a.name.compareTo(b.name));
    return views;
  }

  static Future<List<ViewSchema>> _loadFromAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final allAssets = manifest.listAssets().toSet();
    final viewPaths = allAssets
        .where((k) =>
            k.startsWith(_schemaAssetPrefix) && k.endsWith('.view.yml'))
        .toList();

    final views = <ViewSchema>[];
    for (final path in viewPaths) {
      final raw = await rootBundle.loadString(path);
      try {
        final view = parseViewSchema(raw);
        // Paired .input.yml lookup
        final inputPath =
            path.replaceAll(RegExp(r'\.view\.yml$'), '.input.yml');
        if (allAssets.contains(inputPath)) {
          final inputRaw = await rootBundle.loadString(inputPath);
          final overlay = parseInputOverlay(inputRaw);
          views.add(applyInputOverlay(view, overlay));
        } else {
          views.add(view);
        }
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
