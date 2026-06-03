import 'package:flutter/material.dart';

import '../models/view_schema.dart';
import '../services/autocomplete_cache.dart';
import '../services/derive.dart';
import '../services/sheets_repository.dart';
import 'widgets/field_widgets.dart';

/// Auto-generated entry form. Renders one input per editable dimension.
///
/// Three modes:
///   - **Create** (default): blank form with defaults from `input.default`.
///     On save, calls `repository.create` and pops with `true`.
///   - **Edit** (existing != null): pre-fills from `existing`. On save, calls
///     `repository.update` and pops with `true`.
///   - **Plan** (planMode == true): pre-fills from `existing`. On save, pops
///     with the edited values map (Map<String, Object?>) so the caller can
///     persist it locally instead of writing to the sheet.
class FormScreen extends StatefulWidget {
  final ViewSchema view;
  final SheetsRepository repository;
  final Record? existing;
  final bool planMode;

  const FormScreen({
    super.key,
    required this.view,
    required this.repository,
    this.existing,
    this.planMode = false,
  });

  bool get isEdit => existing != null;

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  late final Record _record;
  bool _saving = false;

  /// Recent rows for this view, fetched once on init. Used by the
  /// autocomplete autofill: when the user picks an exercise (or any other
  /// autocomplete value), we look up the most recent row matching that
  /// value and copy its other fields into the form. Null until the fetch
  /// resolves; an empty list once it does (no history → no autofill).
  List<Record>? _recentRows;

  /// Cached ad-hoc autocomplete values per dim name. Newest-first. These
  /// are values the user typed in past sessions that weren't in the
  /// schema's samples list. Merged with samples in the dropdown and
  /// marked distinctly so the user can tell schema vs. their own
  /// additions.
  final Map<String, List<String>> _adHocCache = {};

  @override
  void initState() {
    super.initState();
    _record = <String, Object?>{};
    if (widget.isEdit) {
      _record.addAll(widget.existing!);
    }
    // Apply defaults to any field not already populated. Matters not just
    // for fresh entries but also for editing planned (template-derived)
    // rows — the template may have left date/time/etc. blank and we still
    // want the form to land with sensible values rather than '—'.
    for (final dim in widget.view.editableDimensions) {
      if (_record[dim.name] != null) continue;
      final d = resolveDefault(dim);
      if (d != null) _record[dim.name] = d;
    }

    // Kick off the recent-rows fetch + ad-hoc cache load only if there's
    // an autocomplete dim. Most views skip this entirely.
    final autocompleteDims = widget.view.editableDimensions
        .where((d) => d.input?.widget == WidgetType.autocomplete)
        .toList();
    if (autocompleteDims.isNotEmpty) {
      _loadRecentRows();
      _loadAdHocCache(autocompleteDims);
    }
  }

  Future<void> _loadAdHocCache(List<Dimension> dims) async {
    for (final dim in dims) {
      final cached = await AutocompleteCache.load(widget.view, dim.name);
      if (!mounted) return;
      if (cached.isNotEmpty) {
        setState(() => _adHocCache[dim.name] = cached);
      }
    }
  }

  Future<void> _loadRecentRows() async {
    try {
      final rows = await widget.repository.list(widget.view);
      if (!mounted) return;
      _recentRows = rows;
    } catch (_) {
      // Best-effort — autofill silently disables if the fetch fails.
      _recentRows = const [];
    }
  }

  /// On autocomplete change: find the most recent row matching the new
  /// value and overwrite the form's other fields with it. "Most recent"
  /// = first match in sheet order, which is newest-first for plannable
  /// views since create() inserts at row 2.
  ///
  /// Skips: the autocomplete dim itself (user just chose that), date and
  /// datetime dims (user is on a specific date already), derived dims
  /// (computed at save time). Everything else is copied — including
  /// empty values, so picking a brand new exercise that has no history
  /// no-ops cleanly (no match → no copy).
  ///
  /// Only fires for plain create flow + planned-edit. Logged-edit (user
  /// fixing a typo) shouldn't have its other fields blown away just
  /// because they changed the exercise.
  void _autofillFromHistory(Dimension trigger, Object? newValue) {
    final rows = _recentRows;
    if (rows == null || rows.isEmpty) return;
    if (widget.isEdit && !widget.planMode) return;
    if (newValue == null || newValue.toString().isEmpty) return;
    final match = rows.firstWhere(
      (r) => r[trigger.name]?.toString() == newValue.toString(),
      orElse: () => const {},
    );
    if (match.isEmpty) return;
    for (final dim in widget.view.editableDimensions) {
      if (dim.name == trigger.name) continue;
      if (dim.type == DimensionType.date) continue;
      if (dim.type == DimensionType.datetime) continue;
      if (dim.derive != null) continue;
      if (match.containsKey(dim.name)) {
        _record[dim.name] = match[dim.name];
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Save on a planned entry promotes it to a logged row (no separate "Log
    // now" step). The title reflects that — "Log" rather than "Edit planned"
    // — so the user knows tapping save commits, not just stashes.
    final titlePrefix = widget.planMode
        ? 'Log'
        : (widget.isEdit ? 'Edit' : 'New');
    return Scaffold(
      appBar: AppBar(
        title: Text('$titlePrefix ${widget.view.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saving ? null : _save,
            tooltip: 'Save',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final dim in widget.view.editableDimensions)
              if (dim.isVisibleGiven(_record, widget.view.groups)) ...[
                buildFieldWidget(
                  key: ValueKey(dim.name),
                  dim: dim,
                  value: _record[dim.name],
                  adHocSuggestions: _adHocCache[dim.name],
                  onChanged: (v) => setState(() {
                    _record[dim.name] = v;
                    if (dim.input?.widget == WidgetType.autocomplete) {
                      _autofillFromHistory(dim, v);
                    }
                  }),
                ),
                const SizedBox(height: 12),
              ],
            if (_saving) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    // Drop values for fields hidden by show_when — they're stale (e.g. user
    // entered treadmill speed, then switched type to stairmaster) and would
    // otherwise pollute the row.
    for (final dim in widget.view.editableDimensions) {
      if (!dim.isVisibleGiven(_record, widget.view.groups)) {
        _record.remove(dim.name);
      }
    }
    final missing = <String>[];
    for (final dim in widget.view.editableDimensions) {
      if (!dim.isVisibleGiven(_record, widget.view.groups)) continue;
      if (dim.input?.required == true && _record[dim.name] == null) {
        missing.add(dim.name);
      }
    }
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Required: ${missing.join(", ")}')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      if (widget.planMode) {
        await _persistAdHocValues();
        if (!mounted) return;
        Navigator.of(context).pop(_record);
        return;
      }
      applyDerives(widget.view, _record);
      if (widget.isEdit) {
        await widget.repository.update(widget.view, _record);
      } else {
        await widget.repository.create(widget.view, _record);
      }
      await _persistAdHocValues();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  /// After a successful save, persist any autocomplete values the user
  /// entered that weren't in the schema's samples. They'll appear in
  /// future autocomplete dropdowns marked as ad-hoc.
  Future<void> _persistAdHocValues() async {
    for (final dim in widget.view.editableDimensions) {
      if (dim.input?.widget != WidgetType.autocomplete) continue;
      final v = _record[dim.name];
      if (v == null) continue;
      await AutocompleteCache.add(widget.view, dim, v.toString());
    }
  }
}
