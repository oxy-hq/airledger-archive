import '../models/view_schema.dart';
import 'engine.dart';
import 'engine_schema_adapter.dart';
import 'input_parser.dart';
import 'schema_files.dart';
import 'schema_parser.dart';

/// Loads `.view.yml` files paired with `.input.yml` overlays.
///
/// File source: bundled assets initially, then the SchemaSync cache after
/// the user has refreshed once. See [listAllSchemaFiles] — the loader
/// doesn't need to know which.
///
/// Parser path is selected by [`useEngine`] in `engine.dart`: when true
/// every file routes through the Rust engine via FFI; when false the
/// pure-Dart parsers run instead. The latter stays around so we can
/// fall back without code changes if the engine regresses.
class SchemaLoader {
  static Future<List<ViewSchema>> loadAll() async {
    final files = await listAllSchemaFiles();
    // Index by basename for the .view.yml → .input.yml pairing.
    final byBasename = {for (final f in files) f.basename: f};
    final viewFiles =
        files.where((f) => f.basename.endsWith('.view.yml')).toList();

    final engine = useEngine ? getEngine() : null;
    final views = <ViewSchema>[];
    for (final f in viewFiles) {
      final raw = await f.read();
      try {
        final inputBasename =
            f.basename.replaceAll(RegExp(r'\.view\.yml$'), '.input.yml');
        final inputFile = byBasename[inputBasename];
        if (engine != null) {
          // Rust engine path.
          if (inputFile != null) {
            final inputRaw = await inputFile.read();
            views.add(parseViewPairViaEngine(
              engine,
              viewYaml: raw,
              inputYaml: inputRaw,
            ));
          } else {
            views.add(viewSchemaFromEngineJson(engine.parseView(raw)));
          }
        } else {
          // Pure-Dart fallback.
          final view = parseViewSchema(raw);
          if (inputFile != null) {
            final inputRaw = await inputFile.read();
            final overlay = parseInputOverlay(inputRaw);
            views.add(applyInputOverlay(view, overlay));
          } else {
            views.add(view);
          }
        }
      } catch (e) {
        throw SchemaLoadException('Failed to parse ${f.basename}: $e');
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
