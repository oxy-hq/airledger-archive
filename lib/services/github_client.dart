import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/github_config.dart';

/// Thin wrapper around the GitHub REST API for the operations the app
/// needs — reading files for hot-reload + the chat's read tools, and
/// creating branches/commits/PRs for the chat's write tool. Authenticated
/// via the bearer token in [GithubConfig].
///
/// Failures throw [GithubException] with the HTTP status + a short
/// reason — the caller decides whether to surface to the user (chat
/// tools) or fall back silently (hot-reload).
class GithubClient {
  final GithubConfig config;
  final http.Client _http;

  GithubClient(this.config, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${config.token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Uri _api(String path) => Uri.parse('https://api.github.com$path');

  /// Lists files in [path] on [ref] (defaults to default_branch). Returns
  /// (name, path, type) tuples — type is 'file' or 'dir'. Subdirs aren't
  /// recursed; the caller iterates if needed.
  Future<List<({String name, String path, String type, String? sha})>>
      listDir(String path, {String? ref}) async {
    final url = _api(
      '/repos/${config.owner}/${config.repo}/contents/$path'
      '${ref != null ? "?ref=$ref" : "?ref=${config.defaultBranch}"}',
    );
    final resp = await _http.get(url, headers: _headers);
    _check(resp, 'list $path');
    final body = jsonDecode(resp.body);
    if (body is! List) {
      // Single-file response — caller probably meant readFile.
      return [];
    }
    return [
      for (final entry in body)
        (
          name: entry['name'] as String,
          path: entry['path'] as String,
          type: entry['type'] as String,
          sha: entry['sha'] as String?,
        ),
    ];
  }

  /// Reads a file's contents (UTF-8 decoded) from [path] on [ref].
  /// Returns null if the file doesn't exist (404). Other failures throw.
  Future<({String content, String sha})?> readFile(
    String path, {
    String? ref,
  }) async {
    final url = _api(
      '/repos/${config.owner}/${config.repo}/contents/$path'
      '${ref != null ? "?ref=$ref" : "?ref=${config.defaultBranch}"}',
    );
    final resp = await _http.get(url, headers: _headers);
    if (resp.statusCode == 404) return null;
    _check(resp, 'read $path');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final encoded = (body['content'] as String).replaceAll('\n', '');
    final content = utf8.decode(base64.decode(encoded));
    return (content: content, sha: body['sha'] as String);
  }

  /// SHA of the head commit on [branch] (defaults to default_branch).
  /// Used to base new branches off of when proposing a PR.
  Future<String> branchHeadSha(String branch) async {
    final url = _api(
      '/repos/${config.owner}/${config.repo}/git/refs/heads/$branch',
    );
    final resp = await _http.get(url, headers: _headers);
    _check(resp, 'get ref heads/$branch');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final obj = body['object'] as Map<String, dynamic>;
    return obj['sha'] as String;
  }

  /// Creates [branch] pointed at [fromSha]. Throws on conflict (already
  /// exists) so the caller can pick a unique name.
  Future<void> createBranch(String branch, String fromSha) async {
    final url = _api('/repos/${config.owner}/${config.repo}/git/refs');
    final resp = await _http.post(
      url,
      headers: _headers,
      body: jsonEncode({'ref': 'refs/heads/$branch', 'sha': fromSha}),
    );
    _check(resp, 'create branch $branch');
  }

  /// Creates-or-updates [path] on [branch] with [content]. If [sha] is
  /// provided the call is an update (PUT requires the previous blob's
  /// sha when overwriting); omitting it creates a new file. Returns the
  /// new commit SHA.
  Future<String> putFile({
    required String path,
    required String content,
    required String branch,
    required String message,
    String? sha,
  }) async {
    final url = _api(
      '/repos/${config.owner}/${config.repo}/contents/$path',
    );
    final body = <String, dynamic>{
      'message': message,
      'content': base64.encode(utf8.encode(content)),
      'branch': branch,
      if (sha != null) 'sha': sha,
    };
    final resp = await _http.put(url, headers: _headers, body: jsonEncode(body));
    _check(resp, 'put $path');
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final commit = decoded['commit'] as Map<String, dynamic>;
    return commit['sha'] as String;
  }

  /// Opens a PR from [head] into [base] with the given title + body.
  /// Returns (number, htmlUrl).
  Future<({int number, String htmlUrl})> openPullRequest({
    required String head,
    required String base,
    required String title,
    String? body,
  }) async {
    final url = _api('/repos/${config.owner}/${config.repo}/pulls');
    final resp = await _http.post(
      url,
      headers: _headers,
      body: jsonEncode({
        'head': head,
        'base': base,
        'title': title,
        if (body != null) 'body': body,
      }),
    );
    _check(resp, 'open PR $head -> $base');
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    return (
      number: decoded['number'] as int,
      htmlUrl: decoded['html_url'] as String,
    );
  }

  void _check(http.Response resp, String op) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    String reason = resp.body;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['message'] is String) {
        reason = decoded['message'] as String;
      }
    } catch (_) {}
    throw GithubException(op: op, status: resp.statusCode, message: reason);
  }
}

class GithubException implements Exception {
  final String op;
  final int status;
  final String message;
  GithubException({
    required this.op,
    required this.status,
    required this.message,
  });

  @override
  String toString() => 'GitHub $op failed ($status): $message';
}
