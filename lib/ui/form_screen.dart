import 'package:flutter/material.dart';

import '../models/view_schema.dart';
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
              if (dim.isVisibleGiven(_record)) ...[
                buildFieldWidget(
                  key: ValueKey(dim.name),
                  dim: dim,
                  value: _record[dim.name],
                  onChanged: (v) => setState(() => _record[dim.name] = v),
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
      if (!dim.isVisibleGiven(_record)) {
        _record.remove(dim.name);
      }
    }
    final missing = <String>[];
    for (final dim in widget.view.editableDimensions) {
      if (!dim.isVisibleGiven(_record)) continue;
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
        Navigator.of(context).pop(_record);
        return;
      }
      applyDerives(widget.view, _record);
      if (widget.isEdit) {
        await widget.repository.update(widget.view, _record);
      } else {
        await widget.repository.create(widget.view, _record);
      }
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
}
