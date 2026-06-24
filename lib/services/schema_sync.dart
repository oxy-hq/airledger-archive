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

  /// Name of the marker file (inside the cache dir) holding the signature
  /// of the last successful sync. Not a `.yml`, so the loaders skip it.
  static const _sigFileName = '.sig';

  SchemaSync(this.github);

  /// A cheap fingerprint of the repo's current schema state: the sorted
  /// list of `<name>:<blob-sha>` for every `.yml` under viewsPath, hashed
  /// down to one string. GitHub's contents listing returns each file's
  /// git blob sha (which changes iff its content changes), so this is a
  /// SINGLE API call — no file bodies downloaded. The poller compares it
  /// against [cachedSignature] and only does a full [refresh] on a diff.
  /// Returns null on any network/API error (caller treats as "unknown,
  /// try again next tick").
  Future<String?> remoteSignature() async {
    try {
      final entries = await github.listDir(github.config.viewsPath);
      final parts = [
        for (final e in entries)
          if (e.type == 'file' && e.path.endsWith('.yml'))
            '${e.name}:${e.sha ?? ''}',
      ]..sort();
      return parts.join('|');
    } catch (_) {
      return null;
    }
  }

  /// The signature recorded by the last successful [refresh], or null if
  /// the cache has never been written (or predates signature tracking).
  static Future<String?> cachedSignature() async {
    final d = await cacheDir();
    if (d == null) return null;
    final f = File(p.join(d.path, _sigFileName));
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

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
    final sigParts = <String>[];

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
        sigParts.add('${e.name}:${e.sha ?? ''}');
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

    // Record the signature of this fetch so the poller can detect future
    // changes without re-downloading. Matches remoteSignature()'s format.
    sigParts.sort();
    final signature = sigParts.join('|');
    File(p.join(tmpDir.path, _sigFileName)).writeAsStringSync(signature);

    // Swap tmp → final atomically (delete + rename).
    if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);
    tmpDir.renameSync(finalDir.path);

    return SchemaSyncResult(
      fetched: fetched,
      skipped: skipped,
      error: null,
      when: DateTime.now(),
      signature: signature,
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

  /// Signature of the synced state (null on error). The poller stores this
  /// to skip redundant refreshes until the repo changes again.
  final String? signature;

  SchemaSyncResult({
    required this.fetched,
    required this.skipped,
    required this.error,
    required this.when,
    this.signature,
  });

  bool get ok => error == null;
}
