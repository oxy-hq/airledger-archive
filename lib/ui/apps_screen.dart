import 'package:flutter/material.dart';

import '../models/app_def.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/app_loader.dart';
import '../services/sheets_repository.dart';
import 'app_viewer_screen.dart';

/// Picker for the bundled .app.yml apps. Initializes the analytics engine
/// (which loads libairlayer + opens the local SQLite cache), syncs any
/// views referenced by an app from the sheet, then hands off to the
/// per-app viewer.
class AppsScreen extends StatefulWidget {
  final List<ViewSchema> views;
  final SheetsRepository repository;

  const AppsScreen({super.key, required this.views, required this.repository});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  late Future<_Bootstrap> _bootstrap;

  @override
  void initState() {
    super.initState();
    _bootstrap = _init();
  }

  Future<_Bootstrap> _init() async {
    final engine = await AnalyticsEngine.create();
    final apps = await AppLoader.loadAll();
    // Sync the views any app references. For now: sync every view used
    // by any task. Cheap (one sheet read per view).
    final neededViewNames = <String>{
      for (final app in apps)
        for (final task in app.tasks)
          if (task is SemanticQueryTask) task.view,
    };
    // Controls that pull options from a view need that view synced too.
    for (final app in apps) {
      for (final c in app.controls) {
        if (c is DropdownControl && c.optionsView != null) {
          neededViewNames.add(c.optionsView!.view);
        }
      }
    }
    for (final name in neededViewNames) {
      final view = widget.views.firstWhere(
        (v) => v.name == name,
        orElse: () => throw StateError('App references unknown view: $name'),
      );
      await engine.db.syncFromSheet(view, widget.repository);
    }
    return _Bootstrap(engine: engine, apps: apps);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Apps')),
      body: FutureBuilder<_Bootstrap>(
        future: _bootstrap,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading airlayer + syncing data ...'),
                ],
              ),
            );
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText('Error: ${snap.error}'),
            );
          }
          final data = snap.data!;
          if (data.apps.isEmpty) {
            return const Center(child: Text('No apps in assets/apps/.'));
          }
          return ListView.separated(
            itemCount: data.apps.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final app = data.apps[i];
              return ListTile(
                leading: const Icon(Icons.bar_chart),
                title: Text(app.title ?? app.name),
                subtitle: app.description == null ? null : Text(app.description!),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AppViewerScreen(
                      app: app,
                      views: widget.views,
                      engine: data.engine,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Bootstrap {
  final AnalyticsEngine engine;
  final List<AppDef> apps;
  _Bootstrap({required this.engine, required this.apps});
}
