import 'dart:convert';
import 'dart:math';

import '../models/view_schema.dart';
import 'chat_runner.dart';
import 'github_client.dart';
import 'sheets_repository.dart';

/// Builds the set of tools the chat LLM can call. Each tool is small,
/// composable, and only does one thing — the LLM orchestrates.
///
/// Tools provided when [github] is non-null:
///   - list_repo_dir         — directory listing under viewsPath
///   - read_repo_file        — fetch a file's contents
///   - propose_change        — open a PR with a single-file change
///
/// Tools provided when [view] is non-null (chat opened from a TimelineScreen):
///   - read_screen_context   — dump the view's schema + recent rows
class ChatToolset {
  final GithubClient? github;
  final ViewSchema? view;
  final SheetsRepository? repository;

  ChatToolset({this.github, this.view, this.repository});

  List<ChatTool> build() {
    return [
      if (view != null) _readScreenContext(),
      if (github != null) _listRepoDir(),
      if (github != null) _readRepoFile(),
      if (github != null) _proposeChange(),
    ];
  }

  ChatTool _readScreenContext() {
    return ChatTool(
      name: 'read_screen_context',
      description:
          'Returns the currently-open view: its name, description, '
          'dimensions (with types), and the 20 most recent logged rows. '
          'Call this first when the user asks about "this view" or "my '
          'data" — saves you from guessing what they\'re looking at.',
      inputSchema: const {
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      run: (input) async {
        final v = view!;
        final repo = repository;
        final dims = v.dimensions.map((d) => {
              'name': d.name,
              'type': d.type.name,
              if (d.description != null) 'description': d.description,
            }).toList();
        List<Map<String, Object?>>? recent;
        if (repo != null) {
          try {
            final rows = await repo.list(v);
            recent = rows
                .take(20)
                .map((r) => r.map((k, v) => MapEntry(k, _stringifyVal(v))))
                .toList();
          } catch (_) {
            // best-effort; chat continues without rows
          }
        }
        return const JsonEncoder.withIndent('  ').convert({
          'view': v.name,
          'description': v.description,
          'dimensions': dims,
          if (recent != null) 'recent_rows': recent,
        });
      },
    );
  }

  ChatTool _listRepoDir() {
    return ChatTool(
      name: 'list_repo_dir',
      description:
          'Lists files in the schemas repo. Pass `path` relative to the '
          'repo root (e.g. "views" or "views/"). Returns name + type '
          '(file/dir) per entry.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Repo-relative path. Use "views" for the '
                'schema/template directory.',
          },
        },
        'required': ['path'],
      },
      run: (input) async {
        final path = (input['path'] as String).trim();
        final entries = await github!.listDir(path);
        return entries
            .map((e) => '${e.type}\t${e.path}')
            .join('\n');
      },
    );
  }

  ChatTool _readRepoFile() {
    return ChatTool(
      name: 'read_repo_file',
      description:
          'Reads a file from the schemas repo and returns its full '
          'contents. Use this to inspect a template/view/input.yml '
          'before proposing changes.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Repo-relative path to the file '
                '(e.g. "views/strength.input.yml").',
          },
        },
        'required': ['path'],
      },
      run: (input) async {
        final path = (input['path'] as String).trim();
        final f = await github!.readFile(path);
        if (f == null) return 'File not found: $path';
        return f.content;
      },
    );
  }

  ChatTool _proposeChange() {
    return ChatTool(
      name: 'propose_change',
      description:
          'Creates a branch, commits a single-file change, and opens a '
          'PR against the default branch. Use this when the user agrees '
          'to a change you proposed — never auto-apply without their '
          'OK. Returns the PR URL on success.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Repo-relative path to write. Must already '
                'exist (we update existing files; creating new ones is '
                'not yet supported).',
          },
          'new_content': {
            'type': 'string',
            'description': 'Complete new file contents — not a diff. '
                'Preserve everything the user did not ask to change.',
          },
          'title': {
            'type': 'string',
            'description': 'Short PR title (the commit message also '
                'uses this).',
          },
          'body': {
            'type': 'string',
            'description': 'PR description — explain WHY in 1-3 '
                'sentences. The user will read this before merging.',
          },
        },
        'required': ['path', 'new_content', 'title'],
      },
      run: (input) async {
        final path = (input['path'] as String).trim();
        final newContent = input['new_content'] as String;
        final title = (input['title'] as String).trim();
        final body = (input['body'] as String?)?.trim();
        final gh = github!;
        final base = gh.config.defaultBranch;
        // Get the existing file (we need its sha to update it, and we
        // bail early if it doesn't exist).
        final existing = await gh.readFile(path);
        if (existing == null) {
          return 'Error: file $path does not exist on $base. The '
              'current propose_change only updates existing files.';
        }
        // Generate a branch name from the title + a short random suffix
        // so re-running a similar PR doesn't collide.
        final slug = _slugify(title);
        final suffix = _randomSuffix();
        final branch = 'airledger/$slug-$suffix';
        final baseSha = await gh.branchHeadSha(base);
        await gh.createBranch(branch, baseSha);
        await gh.putFile(
          path: path,
          content: newContent,
          branch: branch,
          message: title,
          sha: existing.sha,
        );
        final pr = await gh.openPullRequest(
          head: branch,
          base: base,
          title: title,
          body: body,
        );
        return 'PR opened: #${pr.number} ${pr.htmlUrl}';
      },
    );
  }

  static String _stringifyVal(Object? v) {
    if (v == null) return '';
    if (v is DateTime) return v.toIso8601String();
    return v.toString();
  }

  static String _slugify(String s) {
    final lower = s.toLowerCase();
    final cleaned = lower
        .replaceAll(RegExp(r'[^a-z0-9\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final trimmed =
        cleaned.replaceAll(RegExp(r'^-|-$'), '').substring(
              0,
              cleaned.length.clamp(0, 40),
            );
    return trimmed.isEmpty ? 'change' : trimmed;
  }

  static String _randomSuffix() {
    final r = Random();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
