import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/view_schema.dart';
import '../services/app_config.dart';
import '../services/schema_loader.dart';
import '../services/settings_store.dart';
import '../services/sheets_repository.dart';
import 'apps_screen.dart';
import 'settings_screen.dart';
import 'timeline_screen.dart';

/// App entrypoint screen. Loads settings + config + schemas, connects to
/// Sheets, and presents the list of views.
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
    final settings = await SettingsStore.load();
    final assetConfig = await AppConfig.load();
    final packageInfo = await PackageInfo.fromPlatform();

    // Settings overrides the bundled asset config; either falls back to the
    // other if missing.
    final spreadsheetId =
        settings.spreadsheetId ?? assetConfig.spreadsheetId;

    final views = await SchemaLoader.loadAll();
    final keyJson = await rootBundle.loadString('assets/service-account.json');
    final repo = await SheetsRepository.connectFromKey(
      defaultSpreadsheetId: spreadsheetId,
      serviceAccountKeyJson: keyJson,
    );
    for (final view in views) {
      await repo.ensureSheet(view);
    }
    return _Bootstrap(
      views: views,
      repository: repo,
      settings: settings,
      appName: packageInfo.appName,
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    // Settings may have changed — reload bootstrap to pick up new
    // spreadsheet id / appearance.
    if (mounted) setState(() => _bootstrap = _initialize());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Bootstrap>(
      future: _bootstrap,
      builder: (context, snap) {
        final appName = snap.data?.appName ?? 'Ledger';
        return Scaffold(
          appBar: AppBar(
            title: Text(appName),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => setState(() => _bootstrap = _initialize()),
                tooltip: 'Reload schemas',
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
                tooltip: 'Settings',
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
              return ListView.separated(
                itemCount: data.views.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  if (i == data.views.length) {
                    return ListTile(
                      leading: const Icon(Icons.bar_chart),
                      title: const Text('Apps'),
                      subtitle:
                          const Text('Interactive analytics from .app.yml'),
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
                        ),
                      ),
                    ),
                  );
                },
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
  final Settings settings;

  /// OS-level app label (from strings.xml, which brand.dart writes per
  /// `app_name:` in the schemas repo's `ledger.yaml`).
  final String appName;

  _Bootstrap({
    required this.views,
    required this.repository,
    required this.settings,
    required this.appName,
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
