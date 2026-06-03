// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'github_client.dart';

/// Fetches view/template/app YAML files from the schemas repo and writes
/// them to a local cache dir. The schema/template/app loaders prefer
/// this cache when present (else fall back to bundled assets), so a
/// PR merged on GitHub takes effect on the next app launch — no rebuild.
///
/// Scope: pulls every file under `<github.viewsPath>` in the repo at
/// `default_branch`. Subdirectories aren't recursed (we don't have any
/// yet); flatten if/when needed.
class SchemaSync {
  final GithubClient github;
  static const _cacheDirName = 'synced_schemas';

  SchemaSync(this.github);

  /// Resolves the cache dir path. Public so loaders can read from it.
  /// Returns null if the platform's app docs dir isn't available (test
  /// environments). Always-creates the dir on a hit.
  static Future<Directory?> cacheDir() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory(p.join(base.path, _cacheDirName));
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  /// True if the cache has at least one .view.yml file. Loaders use this
  /// as the "should I read from cache?" gate.
  static Future<bool> hasCachedSchemas() async {
    final d = await cacheDir();
    if (d == null) return false;
    final views = d.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.view.yml'),
        );
    return views.isNotEmpty;
  }

  /// Pulls every .yml file under viewsPath from the configured repo at
  /// default_branch, writes to the cache dir, and returns a small summary
  /// (counts + first error if any). Atomic-ish: writes go to a tmp dir
  /// first, then swap with the real cache dir, so a half-fetched state
  /// can't poison the cache.
  Future<SchemaSyncResult> refresh() async {
    final base = await getApplicationDocumentsDirectory();
    final finalDir = Directory(p.join(base.path, _cacheDirName));
    final tmpDir = Directory(p.join(base.path, '${_cacheDirName}_tmp'));
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    tmpDir.createSync(recursive: true);

    var fetched = 0;
    var skipped = 0;
    String? error;

    try {
      final entries = await github.listDir(github.config.viewsPath);
      for (final e in entries) {
        if (e.type != 'file' || !e.path.endsWith('.yml')) {
          skipped++;
          continue;
        }
        final file = await github.readFile(e.path);
        if (file == null) {
          skipped++;
          continue;
        }
        final out = File(p.join(tmpDir.path, e.name));
        out.writeAsStringSync(file.content);
        fetched++;
      }
    } catch (e) {
      error = e.toString();
      tmpDir.deleteSync(recursive: true);
      return SchemaSyncResult(
        fetched: 0,
        skipped: skipped,
        error: error,
        when: DateTime.now(),
      );
    }

    // Swap tmp → final atomically (delete + rename).
    if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);
    tmpDir.renameSync(finalDir.path);

    return SchemaSyncResult(
      fetched: fetched,
      skipped: skipped,
      error: null,
      when: DateTime.now(),
    );
  }

  /// Drops the cache (forces loaders to read bundled assets again).
  /// Useful for debugging or if a sync produced a bad cache.
  static Future<void> clearCache() async {
    final d = await cacheDir();
    if (d == null) return;
    if (d.existsSync()) d.deleteSync(recursive: true);
  }
}

class SchemaSyncResult {
  final int fetched;
  final int skipped;
  final String? error;
  final DateTime when;

  SchemaSyncResult({
    required this.fetched,
    required this.skipped,
    required this.error,
    required this.when,
  });

  bool get ok => error == null;
}
