import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/remote_sync.dart';
import '../services/settings_store.dart';

/// User-facing settings: database + schemas source + branding. Saves to
/// `SettingsStore`. The "Refresh schemas" action pulls from the configured
/// GitHub repo into the local cache.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<Settings> _loaded;
  DbType _dbType = DbType.sheets;
  final _spreadsheet = TextEditingController();
  final _githubRepo = TextEditingController();
  final _githubBranch = TextEditingController(text: 'main');
  final _githubToken = TextEditingController();
  DateTime? _lastSync;
  bool _syncing = false;
  bool _saving = false;
  String? _changedSnackbar;

  @override
  void initState() {
    super.initState();
    _loaded = SettingsStore.load().then((s) {
      _dbType = s.dbType;
      _spreadsheet.text = s.spreadsheetIdRaw ?? '';
      _githubRepo.text = s.githubRepo ?? '';
      _githubBranch.text = s.githubBranch;
      _githubToken.text = s.githubToken ?? '';
      _lastSync = s.lastSync;
      return s;
    });
  }

  @override
  void dispose() {
    for (final c in [
      _spreadsheet,
      _githubRepo,
      _githubBranch,
      _githubToken,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Settings _collect() {
    return Settings(
      dbType: _dbType,
      spreadsheetIdRaw:
          _spreadsheet.text.isEmpty ? null : _spreadsheet.text,
      githubRepo: _githubRepo.text.isEmpty ? null : _githubRepo.text,
      githubBranch: _githubBranch.text.isEmpty ? 'main' : _githubBranch.text,
      githubToken: _githubToken.text.isEmpty ? null : _githubToken.text,
      lastSync: _lastSync,
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await SettingsStore.save(_collect());
      _changedSnackbar = 'Saved. Reopen the app to apply.';
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_changedSnackbar != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_changedSnackbar!)),
          );
          _changedSnackbar = null;
        }
      }
    }
  }

  Future<void> _refresh() async {
    // Persist current edits before sync so RemoteSync sees the right repo.
    await SettingsStore.save(_collect());
    setState(() => _syncing = true);
    try {
      final result = await RemoteSync.refresh(_collect());
      _lastSync = result.syncedAt;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Synced ${result.viewCount} view(s), '
            '${result.templateCount} template(s), '
            '${result.appCount} app(s). Reopen to apply.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: FutureBuilder<Settings>(
        future: _loaded,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Section(
                title: 'Database',
                children: [
                  _label(context, 'Type'),
                  DropdownButtonFormField<DbType>(
                    initialValue: _dbType,
                    items: const [
                      DropdownMenuItem(
                        value: DbType.sheets,
                        child: Text('Google Sheets'),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _dbType = v ?? DbType.sheets),
                  ),
                  const SizedBox(height: 12),
                  _label(context, 'Spreadsheet URL or ID'),
                  TextField(
                    controller: _spreadsheet,
                    decoration: const InputDecoration(
                      hintText: 'https://docs.google.com/spreadsheets/d/…',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Schemas',
                trailing: _lastSync == null
                    ? null
                    : Text(
                        'Synced ${_relativeTime(_lastSync!)}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                children: [
                  _label(context, 'GitHub repo'),
                  TextField(
                    controller: _githubRepo,
                    decoration: const InputDecoration(
                      hintText: 'org/name (e.g. rsyi/ledger-schemas)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label(context, 'Branch'),
                            TextField(
                              controller: _githubBranch,
                              decoration:
                                  const InputDecoration(hintText: 'main'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label(context, 'Personal access token (optional)'),
                            TextField(
                              controller: _githubToken,
                              obscureText: true,
                              decoration: const InputDecoration(
                                hintText: 'For private repos',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _syncing ? null : _refresh,
                    icon: _syncing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync, size: 18),
                    label: const Text('Refresh schemas'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Branding (app name + launcher icon) is set in '
                'ledger-schemas/ledger.yaml and applied at build time via '
                '`dart run ~/repos/ledger/tool/brand.dart`.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _label(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          s,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      );

  static String _relativeTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inDays < 1) return '${delta.inHours}h ago';
    return DateFormat('MMM d').format(t);
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;

  const _Section({
    required this.title,
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}
