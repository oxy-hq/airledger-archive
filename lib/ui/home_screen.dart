import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/view_schema.dart';
import '../services/app_config.dart';
import '../services/connector_registry.dart';
import '../services/github_client.dart';
import '../services/icon_resolver.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/schema_loader.dart';
import '../services/schema_sync.dart';
import '../services/sheets_repository.dart';
import 'apps_screen.dart';
import 'chat_screen.dart';
import 'timeline_screen.dart';
import 'today_dashboard.dart';

/// App entrypoint screen. Loads config + schemas, connects to the
/// warehouse, and presents:
///
///   1. A compact "today" dashboard at the top showing per-view counts
///   2. The list of views
///   3. An "Apps" entry for `.app.yml` analytics
///
/// Database + schemas are baked into the APK at build time (via
/// `tool/brand.dart` resolving `config.yml` + `.env`). No in-app
/// settings page — what's bundled is what runs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_Bootstrap> _bootstrap;

  @override
  void initState() {
    super.initState();
    _bootstrap = _initialize();
  }

  Future<_Bootstrap> _initialize() async {
    final assetConfig = await AppConfig.load();
    final packageInfo = await PackageInfo.fromPlatform();

    final views = await SchemaLoader.loadAll();
    final keyJson =
        await rootBundle.loadString('assets/service-account.json');
    final repo = await SheetsRepository.connectFromKey(
      defaultSpreadsheetId: assetConfig.spreadsheetId,
      serviceAccountKeyJson: keyJson,
    );
    final registry = await ConnectorRegistry.build(
      configs: const [],
      bundledSheets: repo,
    );
    for (final view in views) {
      await registry.forView(view).ensureTable(view);
    }
    // disable_post_log in config.yml gates every piece of the LLM plumbing.
    // When set, we hand TimelineScreen `null` llm/cache so the post-log hook
    // is a no-op even for views that declare one — useful for builds (Poke
    // House) where we don't want any LLM behavior at all.
    final llm = assetConfig.disablePostLog
        ? null
        : LlmClient(assetConfig.models);
    final llmCache =
        assetConfig.disablePostLog ? null : LlmResponseCache();
    return _Bootstrap(
      views: views,
      repository: repo,
      registry: registry,
      appName: packageInfo.appName,
      llm: llm,
      llmCache: llmCache,
      models: assetConfig.models,
      github: assetConfig.github,
    );
  }

  /// Pulls schemas/templates from GitHub, then rebuilds the view list
  /// from the refreshed cache. Surfaces success/error via a snackbar.
  Future<void> _syncFromGithub(GithubConfig cfg) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Syncing schemas from GitHub…'),
        duration: Duration(seconds: 30),
      ),
    );
    try {
      final result = await SchemaSync(GithubClient(cfg)).refresh();
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      if (!result.ok) {
        messenger.showSnackBar(
          SnackBar(content: Text('Sync failed: ${result.error}')),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Synced ${result.fetched} file(s) from '
            '${cfg.repoFullName}@${cfg.defaultBranch}',
          ),
        ),
      );
      setState(() => _bootstrap = _initialize());
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Sync failed: $e')));
    }
  }

  /// Picks the first Anthropic model from config — chat only supports
  /// Anthropic right now (the tool-use loop is Anthropic-shaped).
  ModelConfig? _chatModel(List<ModelConfig> models) {
    for (final m in models) {
      if (m.vendor == ModelVendor.anthropic) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Bootstrap>(
      future: _bootstrap,
      builder: (context, snap) {
        final appName = snap.data?.appName ?? 'Airledger';
        final boot = snap.data;
        final github = boot?.github;
        final chatModel =
            boot == null ? null : _chatModel(boot.models);
        return Scaffold(
          appBar: AppBar(
            title: Text(appName),
            actions: [
              if (chatModel != null)
                IconButton(
                  icon: const Icon(Icons.smart_toy_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        model: chatModel,
                        github:
                            github == null ? null : GithubClient(github),
                      ),
                    ),
                  ),
                  tooltip: 'Chat',
                ),
              if (github != null)
                IconButton(
                  icon: const Icon(Icons.cloud_download_outlined),
                  onPressed: () => _syncFromGithub(github),
                  tooltip: 'Sync schemas from GitHub',
                ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => setState(() => _bootstrap = _initialize()),
                tooltip: 'Reload',
              ),
            ],
          ),
          body: Builder(
            builder: (context) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorView(error: snap.error.toString());
              }
              final data = snap.data!;
              if (data.views.isEmpty) {
                return const Center(child: Text('No views available.'));
              }
              return Column(
                children: [
                  TodayDashboard(
                    views: data.views,
                    registry: data.registry,
                    repository: data.repository,
                  ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: data.views.length + 1,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        if (i == data.views.length) {
                          return ListTile(
                            leading: const Icon(Icons.bar_chart),
                            title: const Text('Apps'),
                            subtitle: const Text(
                                'Interactive analytics from .app.yml'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AppsScreen(
                                  views: data.views,
                                  repository: data.repository,
                                ),
                              ),
                            ),
                          );
                        }
                        final view = data.views[i];
                        return ListTile(
                          leading: IconResolver.resolve(
                            view.icon,
                            size: 22,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          title: Text(view.name),
                          subtitle: view.description == null
                              ? null
                              : Text(view.description!),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TimelineScreen(
                                view: view,
                                repository: data.repository,
                                llm: data.llm,
                                llmCache: data.llmCache,
                                chatModel: chatModel,
                                github: github == null
                                    ? null
                                    : GithubClient(github),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _Bootstrap {
  final List<ViewSchema> views;
  final SheetsRepository repository;
  final ConnectorRegistry registry;
  final LlmClient? llm;
  final LlmResponseCache? llmCache;

  /// OS-level app label (from strings.xml, which brand.dart writes per
  /// `app_name:` in the schemas repo's `ledger.yaml`).
  final String appName;

  /// Full models list — chat picks an Anthropic entry; post-log hook
  /// uses by-name lookup. Both share the same models: block in config.yml.
  final List<ModelConfig> models;

  /// GitHub config — drives schema sync + chat's repo tools. Null when
  /// the build has no github: in config.yml; UI hides the relevant
  /// buttons.
  final GithubConfig? github;

  _Bootstrap({
    required this.views,
    required this.repository,
    required this.registry,
    required this.appName,
    required this.llm,
    required this.llmCache,
    required this.models,
    required this.github,
  });
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Startup error',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SelectableText(
              error,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
