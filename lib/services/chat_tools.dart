import 'dart:convert';
import 'dart:math';

import 'package:intl/intl.dart';

import '../models/planned_entry.dart';
import '../models/view_schema.dart';
import 'analytics_engine.dart';
import 'chat_runner.dart';
import 'github_client.dart';
import 'plan_store.dart';
import 'sheets_repository.dart';
import 'template_interpolator.dart';
import 'template_loader.dart';

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
///   - list_templates        — templates available for this view
///   - read_template         — full template (variables + entries)
///   - apply_template        — creates planned entries on a target date
///                             (local PlanStore only, no sheet write)
class ChatToolset {
  final GithubClient? github;
  final ViewSchema? view;
  final SheetsRepository? repository;

  /// AnalyticsEngine (airlayer + LocalDb). When non-null and a view is
  /// in scope, the chat can call run_query to ask history questions —
  /// max squat in the last 6 months, total volume last week, etc. Per
  /// chat session we lazy-sync each view's sheet → SQLite cache on
  /// first query; tracked via [_syncedViews].
  final AnalyticsEngine? analytics;
  final Set<String> _syncedViews = {};

  /// Date the user is currently viewing in the timeline (used as the
  /// default for apply_template). Defaults to today when chat is opened
  /// from HomeScreen or any caller that doesn't have a selected date.
  final DateTime selectedDate;

  ChatToolset({
    this.github,
    this.view,
    this.repository,
    this.analytics,
    DateTime? selectedDate,
  }) : selectedDate = selectedDate ?? _today();

  /// Lazy-sync the view's sheet rows into LocalDb. No-op when analytics
  /// or repository are unavailable, or after the first call per session.
  Future<void> _ensureSynced(ViewSchema v) async {
    if (analytics == null || repository == null) return;
    if (_syncedViews.contains(v.name)) return;
    await analytics!.db.syncFromSheet(v, repository!);
    _syncedViews.add(v.name);
  }

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  List<ChatTool> build() {
    return [
      if (view != null) _readScreenContext(),
      if (view != null && analytics != null) _runQuery(),
      if (view != null) _listTemplates(),
      if (view != null) _readTemplate(),
      if (view != null) _applyTemplate(),
      if (view != null) _addPlannedEntry(),
      if (view != null && repository != null) _logEntry(),
      if (github != null) _listRepoDir(),
      if (github != null) _readRepoFile(),
      if (github != null) _proposeChange(),
    ];
  }

  ChatTool _readScreenContext() {
    return ChatTool(
      name: 'read_screen_context',
      description:
          'Returns the currently-open view: name, description, '
          'dimensions, measures, and the 20 most recent logged rows. '
          'Call this FIRST whenever the user asks about "this view" '
          'or "my data" — gives you the schema so you know what to '
          'query and what to render.',
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
        final meas = v.measures.map((m) => {
              'name': m.name,
              'type': m.type.name,
              if (m.expr != null) 'expr': m.expr,
              if (m.description != null) 'description': m.description,
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
          'measures': meas,
          if (recent != null) 'recent_rows': recent,
        });
      },
    );
  }

  ChatTool _runQuery() {
    return ChatTool(
      name: 'run_query',
      description:
          'Runs an aggregate query against the current view\'s '
          'history via the airlayer semantic layer. Use this to answer '
          '"what\'s my max squat", "how much volume last week", "how '
          'many sets per exercise this month" — anything that needs '
          'an aggregation over many rows, vs. read_screen_context '
          'which only returns the last 20.\n\n'
          'Query shape mirrors airlayer:\n'
          '  measures:   list of measure names (e.g. ["max_e1rm"])\n'
          '  dimensions: optional group-by (e.g. ["exercise"])\n'
          '  filters:    optional list of {dim, op, value} where op '
          'is = / != / > / >= / < / <= / in\n'
          '  order:      optional list of {by, dir} where dir is asc/desc\n'
          '  limit:      optional int\n\n'
          'Call read_screen_context first to learn the view\'s measure '
          'names; passing an unknown one errors. First call per chat '
          'syncs sheet → SQLite cache (slow); subsequent calls are fast.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'measures': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Measure names to compute.',
          },
          'dimensions': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional group-by dimensions.',
          },
          'filters': {
            'type': 'array',
            'items': {'type': 'object'},
            'description': 'Optional {dim, op, value} filters.',
          },
          'order': {
            'type': 'array',
            'items': {'type': 'object'},
            'description': 'Optional [{by: <name>, dir: asc|desc}].',
          },
          'limit': {
            'type': 'integer',
            'description': 'Optional row cap.',
          },
        },
        'required': ['measures'],
      },
      run: (input) async {
        final v = view!;
        await _ensureSynced(v);
        // Build airlayer query. measure/dim names are passed bare —
        // airlayer auto-prefixes with the view name on compile.
        final query = <String, dynamic>{};
        final measures = (input['measures'] as List?)?.cast<dynamic>();
        if (measures != null) query['measures'] = measures;
        final dims = (input['dimensions'] as List?)?.cast<dynamic>();
        if (dims != null && dims.isNotEmpty) query['dimensions'] = dims;
        final filters = (input['filters'] as List?)?.cast<dynamic>();
        if (filters != null && filters.isNotEmpty) {
          query['filters'] = filters;
        }
        final order = (input['order'] as List?)?.cast<dynamic>();
        if (order != null && order.isNotEmpty) query['order'] = order;
        if (input['limit'] != null) query['limit'] = input['limit'];
        final rows = await analytics!.run(v, query: query);
        return const JsonEncoder.withIndent('  ').convert({
          'view': v.name,
          'row_count': rows.length,
          'rows': rows,
        });
      },
    );
  }

  ChatTool _listTemplates() {
    return ChatTool(
      name: 'list_templates',
      description:
          'Lists templates available for the currently-open view — '
          'name, description, and the variable spec (name, type, '
          'default). Use this to decide what could be applied today.',
      inputSchema: const {
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      run: (input) async {
        final templates = await TemplateLoader.loadForView(view!.name);
        return const JsonEncoder.withIndent('  ').convert([
          for (final t in templates)
            {
              'name': t.name,
              if (t.description != null) 'description': t.description,
              'entry_count': t.entries.length,
              'variables': t.variables
                  .map((v) => {
                        'name': v.name,
                        'type': v.type.name,
                        if (v.label != v.name) 'label': v.label,
                        if (v.defaultValue != null)
                          'default': v.defaultValue,
                      })
                  .toList(),
            },
        ]);
      },
    );
  }

  ChatTool _readTemplate() {
    return ChatTool(
      name: 'read_template',
      description:
          'Reads a template by name and returns its full content: '
          'variables and the entry rows (with any Jinja placeholders '
          'unrendered). Use this BEFORE apply_template so you understand '
          'what gets created.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Template name, e.g. "cut_squat_heavy".',
          },
        },
        'required': ['name'],
      },
      run: (input) async {
        final name = (input['name'] as String).trim();
        final templates = await TemplateLoader.loadForView(view!.name);
        final t = templates.firstWhere(
          (t) => t.name == name,
          orElse: () => throw StateError(
            'Template "$name" not found for ${view!.name}. Known: '
            '${templates.map((t) => t.name).join(", ")}',
          ),
        );
        return const JsonEncoder.withIndent('  ').convert({
          'name': t.name,
          'view': t.view,
          if (t.description != null) 'description': t.description,
          'variables': t.variables
              .map((v) => {
                    'name': v.name,
                    'type': v.type.name,
                    if (v.defaultValue != null)
                      'default': v.defaultValue,
                  })
              .toList(),
          'entries': t.entries,
        });
      },
    );
  }

  ChatTool _applyTemplate() {
    return ChatTool(
      name: 'apply_template',
      description:
          'Creates planned (not-yet-logged) entries for the named '
          'template on the target date. Variables in [variables] are '
          'interpolated into the template before planning. Default '
          'date is the day the user is currently viewing — pass an '
          'explicit ISO yyyy-MM-dd in [date] only when the user '
          'wants a different day. Only call AFTER showing the user '
          'what will be created and getting their OK.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Template name to apply.',
          },
          'variables': {
            'type': 'object',
            'description':
                'Map of variable name -> value. Variables not listed '
                'use the template\'s default. Numbers as numbers, '
                'strings as strings.',
            'additionalProperties': true,
          },
          'date': {
            'type': 'string',
            'description': 'Target date in yyyy-MM-dd. Defaults to '
                'the date the user is currently viewing.',
          },
        },
        'required': ['name'],
      },
      run: (input) async {
        final name = (input['name'] as String).trim();
        final vars = (input['variables'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v),
            ) ??
            <String, Object?>{};
        final dateStr = (input['date'] as String?)?.trim();
        final date = dateStr == null || dateStr.isEmpty
            ? selectedDate
            : DateTime.parse(dateStr);
        final templates = await TemplateLoader.loadForView(view!.name);
        final t = templates.firstWhere(
          (t) => t.name == name,
          orElse: () => throw StateError(
            'Template "$name" not found for ${view!.name}.',
          ),
        );
        // Fill in defaults for any variables the user/LLM didn't override.
        final merged = <String, Object?>{};
        for (final v in t.variables) {
          merged[v.name] = vars.containsKey(v.name)
              ? vars[v.name]
              : v.defaultValue;
        }
        final rendered = TemplateInterpolator.apply(t, view!, merged);
        final dateDim = view!.dateField;
        final planned = <PlannedEntry>[];
        for (final entry in rendered) {
          final values = Map<String, Object?>.from(entry);
          if (dateDim != null) values.remove(dateDim);
          planned.add(PlannedEntry.create(
            view: view!,
            date: date,
            values: values,
            templateName: t.name,
          ));
        }
        await PlanStore.addAll(view!, planned);
        return 'Applied template "$name" — ${planned.length} planned '
            'entries on ${DateFormat('yyyy-MM-dd').format(date)}. '
            'Refresh the timeline to see them.';
      },
    );
  }

  ChatTool _addPlannedEntry() {
    return ChatTool(
      name: 'add_planned_entry',
      description:
          'Creates a single planned (not-yet-logged) entry for the '
          'current view, populated with the [values] you provide. The '
          'entry shows up on the timeline as an orange circle the user '
          'taps to log. Use this for ad-hoc additions like a third set '
          'of squats at 225x5. For multiple-entry workouts driven by '
          'a template, prefer apply_template. Only call after the user '
          'agrees to the specific values.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'values': {
            'type': 'object',
            'description':
                'Field-name -> value map. Required fields for the view '
                'must be present (call read_screen_context to see the '
                'schema if unsure). Numbers as numbers, strings as '
                'strings.',
            'additionalProperties': true,
          },
          'date': {
            'type': 'string',
            'description': 'Target date in yyyy-MM-dd. Defaults to the '
                'date the user is currently viewing.',
          },
        },
        'required': ['values'],
      },
      run: (input) async {
        final values = (input['values'] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final dateStr = (input['date'] as String?)?.trim();
        final date = dateStr == null || dateStr.isEmpty
            ? selectedDate
            : DateTime.parse(dateStr);
        final dateDim = view!.dateField;
        // Strip the date dim from values — PlannedEntry stores it
        // separately at the row level.
        if (dateDim != null) values.remove(dateDim);
        final planned = PlannedEntry.create(
          view: view!,
          date: date,
          values: values,
        );
        await PlanStore.addAll(view!, [planned]);
        return 'Added planned entry for ${view!.name} on '
            '${DateFormat('yyyy-MM-dd').format(date)}. The user can tap '
            'the orange circle on the timeline to log it.';
      },
    );
  }

  ChatTool _logEntry() {
    return ChatTool(
      name: 'log_entry',
      description:
          'Skips the planned step and writes a row directly to the '
          'underlying sheet. Use ONLY when the user explicitly asks to '
          '"log" something (vs. "plan" or "add"). For most cases '
          'add_planned_entry is safer — the user can review/edit before '
          'committing.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'values': {
            'type': 'object',
            'description':
                'Field-name -> value map. Required fields for the view '
                'must be present.',
            'additionalProperties': true,
          },
          'date': {
            'type': 'string',
            'description':
                'Target date in yyyy-MM-dd. Defaults to today.',
          },
        },
        'required': ['values'],
      },
      run: (input) async {
        final values = (input['values'] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final dateStr = (input['date'] as String?)?.trim();
        final date = dateStr == null || dateStr.isEmpty
            ? selectedDate
            : DateTime.parse(dateStr);
        final dateDim = view!.dateField;
        if (dateDim != null) values[dateDim] = date;
        await repository!.create(view!, values);
        return 'Logged a row in ${view!.name} for '
            '${DateFormat('yyyy-MM-dd').format(date)}.';
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
