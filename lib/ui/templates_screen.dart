import 'package:flutter/material.dart';

import '../models/planned_entry.dart';
import '../models/template.dart';
import '../models/view_schema.dart';
import '../services/pinned_templates.dart';
import '../services/plan_store.dart';
import '../services/sheets_repository.dart';
import '../services/template_interpolator.dart';
import '../services/template_loader.dart';
import '../services/template_vars_cache.dart';
import 'template_vars_dialog.dart';

/// Shows templates available for [view]; tapping one prompts for any declared
/// variables, then creates N "planned" records in the view's table for
/// [onDate]. Pinned templates float to the top.
class TemplatesScreen extends StatefulWidget {
  final ViewSchema view;
  final SheetsRepository repository;
  final DateTime onDate;

  const TemplatesScreen({
    super.key,
    required this.view,
    required this.repository,
    required this.onDate,
  });

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  late Future<_ScreenData> _data;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_ScreenData> _load() async {
    final templates = await TemplateLoader.loadForView(widget.view.name);
    final pinned = await PinnedTemplates.loadForView(widget.view.name);
    return _ScreenData(templates: templates, pinned: pinned);
  }

  /// Sorts pinned templates first (preserving the alphabetical order TemplateLoader
  /// returned), then the rest. Returns the flattened list plus the pinned cutoff
  /// so the UI can draw a divider.
  ({List<Template> sorted, int pinnedCount}) _orderForDisplay(_ScreenData d) {
    final pinned = <Template>[];
    final rest = <Template>[];
    for (final t in d.templates) {
      (d.pinned.contains(t.name) ? pinned : rest).add(t);
    }
    return (sorted: [...pinned, ...rest], pinnedCount: pinned.length);
  }

  Future<void> _togglePin(Template template) async {
    await PinnedTemplates.toggle(widget.view.name, template.name);
    setState(() => _data = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Templates: ${widget.view.name}'),
      ),
      body: FutureBuilder<_ScreenData>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: ${snap.error}'),
            );
          }
          final data = snap.data;
          if (data == null || data.templates.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No templates for "${widget.view.name}".\n\n'
                  'Add YAML files to '
                  '~/repos/ledger-schemas/templates/${widget.view.name}/ '
                  'and re-run tool/sync_assets.sh.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final order = _orderForDisplay(data);
          final templates = order.sorted;
          final pinnedCount = order.pinnedCount;
          // Reserve index 0 for the "Use last session" virtual tile when
          // the view has a date_field (the only views where "session"
          // makes sense). It's not a real Template — separate code path
          // that pulls from history instead of YAML.
          final hasLastSession = widget.view.dateField != null;
          final indexOffset = hasLastSession ? 1 : 0;
          return ListView.separated(
            itemCount: templates.length + indexOffset,
            separatorBuilder: (_, i) {
              // Heavier divider between the virtual last-session tile
              // and the real templates, AND between pinned and unpinned.
              if (hasLastSession && i == 0) {
                return const Divider(thickness: 1.5, height: 1.5);
              }
              if (pinnedCount > 0 &&
                  i == pinnedCount - 1 + indexOffset) {
                return const Divider(thickness: 1.5, height: 1.5);
              }
              return const Divider(height: 1);
            },
            itemBuilder: (_, i) {
              if (hasLastSession && i == 0) {
                return _LastSessionTile(
                  disabled: _applying,
                  onTap: _useLastSession,
                );
              }
              final t = templates[i - indexOffset];
              return _TemplateTile(
                template: t,
                pinned: data.pinned.contains(t.name),
                onApply: () => _apply(t),
                onTogglePin: () => _togglePin(t),
                disabled: _applying,
              );
            },
          );
        },
      ),
    );
  }

  /// Pulls every row from the sheet, finds the date with the most recent
  /// activity, copies those rows as planned entries for [onDate]. Each
  /// row becomes one planned entry; the user can tweak and log them
  /// individually. Fields that are inherently per-session (now_button
  /// stamps like start_time, end_time, and explicit zone-reach times)
  /// get stripped so they're re-recorded fresh.
  Future<void> _useLastSession() async {
    if (_applying) return;
    setState(() => _applying = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dateField = widget.view.dateField;
      if (dateField == null) throw 'view has no date_field';
      final all = await widget.repository.list(widget.view);
      // Exclude any row dated today — "last session" means the previous
      // one, not the one we're mid-way through.
      final now = DateTime.now();
      final todayKey = '${now.year}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      DateTime? newest;
      final byDate = <String, List<Record>>{};
      for (final r in all) {
        final v = r[dateField];
        DateTime? dt;
        if (v is DateTime) dt = DateTime(v.year, v.month, v.day);
        if (v is String) {
          final p = DateTime.tryParse(v);
          if (p != null) dt = DateTime(p.year, p.month, p.day);
        }
        if (dt == null) continue;
        final key =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        if (key == todayKey) continue;
        byDate.putIfAbsent(key, () => []).add(r);
        if (newest == null || dt.isAfter(newest)) newest = dt;
      }
      if (newest == null) throw 'no prior sessions to copy';
      final key =
          '${newest.year}-${newest.month.toString().padLeft(2, '0')}-${newest.day.toString().padLeft(2, '0')}';
      final rows = byDate[key]!;

      // Heuristic strip: fields whose input declares now_button (clearly
      // per-session stamps) and obvious session-time names. Keeps
      // weight/reps/incline/speed/notes intact across sessions.
      bool isSessionField(Dimension d) {
        if (d.name == 'id') return true;
        if (d.name == dateField) return true;
        if (d.derive != null) return true;
        if (d.input?.nowButton == true) return true;
        if (d.name.contains('_time') || d.name.contains('_reached')) {
          return true;
        }
        return false;
      }

      final planned = <PlannedEntry>[];
      for (final r in rows) {
        final values = <String, Object?>{};
        for (final dim in widget.view.dimensions) {
          if (isSessionField(dim)) continue;
          if (r[dim.name] != null) values[dim.name] = r[dim.name];
        }
        planned.add(PlannedEntry.create(
          view: widget.view,
          date: widget.onDate,
          values: values,
          templateName: 'Last session',
        ));
      }
      await PlanStore.addAll(widget.view, planned);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      messenger.showSnackBar(SnackBar(content: Text('Apply failed: $e')));
    }
  }

  Future<void> _apply(Template template) async {
    // Resolve variable values: cached > YAML default > null. The dialog shows
    // a live preview of the rendered entries — even when there are no
    // variables, so the user always confirms against the actual set list.
    final initial = await TemplateVarsCache.resolve(template);
    if (!mounted) return;
    final vars = await TemplateVarsDialog.show(
      context,
      template: template,
      view: widget.view,
      initialValues: initial,
    );
    if (vars == null) return;
    if (template.variables.isNotEmpty) {
      await TemplateVarsCache.save(template, vars);
    }

    setState(() => _applying = true);
    try {
      final rendered = TemplateInterpolator.apply(
        template,
        widget.view,
        vars,
      );
      // Local plan only — entries don't touch the sheet until logged.
      final dateDim = widget.view.dateField;
      final planned = <PlannedEntry>[];
      for (final entry in rendered) {
        final values = Map<String, Object?>.from(entry);
        if (dateDim != null) values.remove(dateDim);
        planned.add(PlannedEntry.create(
          view: widget.view,
          date: widget.onDate,
          values: values,
          templateName: template.name,
        ));
      }
      await PlanStore.addAll(widget.view, planned);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Apply failed: $e')),
      );
    }
  }
}

class _ScreenData {
  final List<Template> templates;
  final Set<String> pinned;
  _ScreenData({required this.templates, required this.pinned});
}

/// Virtual tile pinned above the real templates. Pulls the most recent
/// date's logged rows into the plan store as planned entries — the
/// "today is yesterday's workout" gesture for any view with history.
class _LastSessionTile extends StatelessWidget {
  final VoidCallback onTap;
  final bool disabled;

  const _LastSessionTile({required this.onTap, required this.disabled});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.history, color: scheme.primary),
      title: const Text('Use last session'),
      subtitle: const Text(
        'Copy the most recent session as today\'s plan',
        maxLines: 2,
      ),
      trailing: const Icon(Icons.add),
      onTap: disabled ? null : onTap,
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final Template template;
  final bool pinned;
  final VoidCallback onApply;
  final VoidCallback onTogglePin;
  final bool disabled;

  const _TemplateTile({
    required this.template,
    required this.pinned,
    required this.onApply,
    required this.onTogglePin,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(template.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (template.description != null) Text(template.description!),
          Text(
            '${template.entries.length} entries'
            '${template.variables.isEmpty ? '' : ' · ${template.variables.length} vars'}',
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              pinned ? Icons.star : Icons.star_outline,
              color: pinned
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
            onPressed: onTogglePin,
            tooltip: pinned ? 'Unpin' : 'Pin',
          ),
          const Icon(Icons.add),
        ],
      ),
      onTap: disabled ? null : onApply,
    );
  }
}
