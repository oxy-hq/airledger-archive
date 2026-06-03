import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;

import 'schema_sync.dart';

/// One .yml file as seen by the loaders, regardless of source. Source can
/// be the SchemaSync cache (filesystem) or the bundled assets — the
/// loader doesn't have to care.
class SchemaFile {
  /// The path basename (e.g. `strength.view.yml`). Loaders use this for
  /// pattern-matching (.view.yml vs .input.yml vs .template.yml).
  final String basename;

  /// Full source path — opaque to loaders, used internally by [read].
  final String _path;

  /// Reads the file contents.
  final Future<String> Function() read;

  SchemaFile._({
    required this.basename,
    required String path,
    required this.read,
  }) : _path = path;

  @override
  String toString() => 'SchemaFile($basename @ $_path)';
}

/// Returns all schema/template/app YAML files from the active source.
///
/// Active source = SchemaSync cache when it has anything (i.e. the user
/// has refreshed at least once since install), otherwise bundled assets.
/// We don't merge the two — once a sync runs, the cache is the source of
/// truth and assets become a stale fallback for the next fresh install.
///
/// Same iteration order regardless of source: alphabetical by basename so
/// loaders see a deterministic list.
Future<List<SchemaFile>> listAllSchemaFiles() async {
  if (await SchemaSync.hasCachedSchemas()) {
    final dir = await SchemaSync.cacheDir();
    if (dir != null) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return [
        for (final f in files)
          SchemaFile._(
            basename: p.basename(f.path),
            path: f.path,
            read: () async => f.readAsString(),
          ),
      ];
    }
  }
  const assetPrefix = 'assets/schemas/';
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final paths = manifest
      .listAssets()
      .where((k) => k.startsWith(assetPrefix) && k.endsWith('.yml'))
      .toList()
    ..sort();
  return [
    for (final pth in paths)
      SchemaFile._(
        basename: pth.substring(assetPrefix.length),
        path: pth,
        read: () => rootBundle.loadString(pth),
      ),
  ];
}
