import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';

/// Pulls schemas (`views/*.view.yml`) and templates (`templates/<view>/*.yml`)
/// from a configured GitHub repo into the app's local cache. After a sync,
/// [SchemaLoader] and [TemplateLoader] prefer the cache over the bundled
/// assets, so updates land without an APK rebuild.
class RemoteSync {
  /// Subdirs under the app documents directory.
  static const schemasDirName = 'schemas';
  static const templatesDirName = 'templates';
  static const appsDirName = 'apps';

  /// Refreshes the local cache from [s.githubRepo]. Throws on misconfig or
  /// network failure. Updates `SettingsStore.markSynced` on success.
  static Future<RemoteSyncResult> refresh(Settings s) async {
    final repo = s.githubRepo;
    if (repo == null || repo.isEmpty) {
      throw const RemoteSyncException(
        'No GitHub repo configured. Set `org/name` in Settings.',
      );
    }
    final docs = await getApplicationDocumentsDirectory();
    final schemasDir = Directory('${docs.path}/$schemasDirName');
    final templatesRoot = Directory('${docs.path}/$templatesDirName');
    final appsDir = Directory('${docs.path}/$appsDirName');
    schemasDir.createSync(recursive: true);
    templatesRoot.createSync(recursive: true);
    appsDir.createSync(recursive: true);

    // 1. Schemas
    final views =
        await _list(repo, s.githubBranch, 'views', s.githubToken);
    int viewCount = 0;
    for (final f in views.where((f) =>
        f.type == 'file' && f.name.endsWith('.view.yml'))) {
      final body = await _fetchRaw(f.downloadUrl!, s.githubToken);
      await File('${schemasDir.path}/${f.name}').writeAsString(body);
      viewCount++;
    }

    // 2. Templates — recursively descend templates/<view>/*.yml
    int templateCount = 0;
    final templateDirs =
        await _list(repo, s.githubBranch, 'templates', s.githubToken);
    // Clear out stale template subdirs so deletions in the repo propagate.
    if (templatesRoot.existsSync()) {
      for (final entity in templatesRoot.listSync()) {
        if (entity is Directory) entity.deleteSync(recursive: true);
      }
    }
    for (final viewDir in templateDirs.where((d) => d.type == 'dir')) {
      final localViewDir =
          Directory('${templatesRoot.path}/${viewDir.name}');
      localViewDir.createSync(recursive: true);
      final files = await _list(
          repo, s.githubBranch, 'templates/${viewDir.name}', s.githubToken);
      for (final f in files.where((f) =>
          f.type == 'file' && f.name.endsWith('.yml'))) {
        final body = await _fetchRaw(f.downloadUrl!, s.githubToken);
        await File('${localViewDir.path}/${f.name}').writeAsString(body);
        templateCount++;
      }
    }

    // 3. Apps (optional; ignore 404)
    int appCount = 0;
    try {
      final apps = await _list(repo, s.githubBranch, 'apps', s.githubToken);
      for (final f in apps.where((f) =>
          f.type == 'file' && f.name.endsWith('.app.yml'))) {
        final body = await _fetchRaw(f.downloadUrl!, s.githubToken);
        await File('${appsDir.path}/${f.name}').writeAsString(body);
        appCount++;
      }
    } on RemoteSyncException catch (e) {
      // The apps/ dir may not exist in the repo — that's fine.
      if (!e.message.contains('404')) rethrow;
    }

    final now = DateTime.now();
    await SettingsStore.markSynced(now);
    return RemoteSyncResult(
      viewCount: viewCount,
      templateCount: templateCount,
      appCount: appCount,
      syncedAt: now,
    );
  }

  static Future<List<_GhEntry>> _list(
    String repo,
    String branch,
    String path,
    String? token,
  ) async {
    final uri = Uri.parse(
        'https://api.github.com/repos/$repo/contents/$path?ref=$branch');
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final resp = await http.get(uri, headers: headers);
    if (resp.statusCode != 200) {
      throw RemoteSyncException(
        'GitHub list $repo/$path failed (${resp.statusCode}): ${resp.body}',
      );
    }
    final list = jsonDecode(resp.body) as List;
    return list
        .map((e) => _GhEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<String> _fetchRaw(String url, String? token) async {
    final headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final resp = await http.get(Uri.parse(url), headers: headers);
    if (resp.statusCode != 200) {
      throw RemoteSyncException(
        'GitHub fetch failed (${resp.statusCode}) for $url',
      );
    }
    return resp.body;
  }
}

class _GhEntry {
  final String name;
  final String type; // "file" | "dir"
  final String? downloadUrl;
  _GhEntry({
    required this.name,
    required this.type,
    required this.downloadUrl,
  });
  factory _GhEntry.fromJson(Map<String, dynamic> j) => _GhEntry(
        name: j['name'] as String,
        type: j['type'] as String,
        downloadUrl: j['download_url'] as String?,
      );
}

class RemoteSyncResult {
  final int viewCount;
  final int templateCount;
  final int appCount;
  final DateTime syncedAt;
  RemoteSyncResult({
    required this.viewCount,
    required this.templateCount,
    required this.appCount,
    required this.syncedAt,
  });
}

class RemoteSyncException implements Exception {
  final String message;
  const RemoteSyncException(this.message);
  @override
  String toString() => 'RemoteSyncException: $message';
}
