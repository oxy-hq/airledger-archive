import 'package:flutter/material.dart';

import '../models/template.dart';
import '../models/view_schema.dart';
import '../services/list_display_render.dart';
import '../services/template_interpolator.dart';

/// Modal that asks the user for the template's declared variable values
/// before the entries get materialized. Pre-fills [initialValues] (usually
/// the last-used values from the cache or YAML defaults). Returns the new
/// values on confirm, or null on cancel.
///
/// Also shows a live preview of the rendered entries (with Jinja
/// substitutions applied) so the user can confirm computed weights before
/// committing.
class TemplateVarsDialog extends StatefulWidget {
  final Template template;
  final ViewSchema view;
  final Map<String, Object?> initialValues;

  const TemplateVarsDialog({
    super.key,
    required this.template,
    required this.view,
    required this.initialValues,
  });

  static Future<Map<String, Object?>?> show(
    BuildContext context, {
    required Template template,
    required ViewSchema view,
    required Map<String, Object?> initialValues,
  }) {
    return showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => TemplateVarsDialog(
        template: template,
        view: view,
        initialValues: initialValues,
      ),
    );
  }

  @override
  State<TemplateVarsDialog> createState() => _TemplateVarsDialogState();
}

class _TemplateVarsDialogState extends State<TemplateVarsDialog> {
  late final Map<String, TextEditingController> _controllers;
  List<Map<String, Object?>> _preview = const [];
  String? _previewError;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final v in widget.template.variables)
        v.name: TextEditingController(
          text: widget.initialValues[v.name]?.toString() ?? '',
        )..addListener(_onChanged),
    };
    _renderPreview();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Builds the current variable map from the text controllers. Used by both
  /// the preview re-render path and the final submit.
  Map<String, Object?> _collectValues() {
    final out = <String, Object?>{};
    for (final v in widget.template.variables) {
      final text = _controllers[v.name]?.text.trim() ?? '';
      if (text.isEmpty) {
        out[v.name] = null;
        continue;
      }
      switch (v.type) {
        case TemplateVarType.number:
          out[v.name] = num.tryParse(text) ?? text;
          break;
        case TemplateVarType.string:
          out[v.name] = text;
          break;
      }
    }
    return out;
  }

  void _onChanged() {
    setState(_renderPreview);
  }

  void _renderPreview() {
    try {
      _preview = TemplateInterpolator.apply(
        widget.template,
        widget.view,
        _collectValues(),
      );
      _previewError = null;
    } catch (e) {
      _preview = const [];
      _previewError = e.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.of(context).size;
    final maxPreviewHeight = mediaSize.height * 0.45;
    final entryCount = widget.template.entries.length;
    return AlertDialog(
      title: Text(widget.template.name),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: mediaSize.width),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.template.description != null) ...[
                Text(
                  widget.template.description!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
              for (final v in widget.template.variables) ...[
                TextField(
                  controller: _controllers[v.name],
                  keyboardType: v.type == TemplateVarType.number
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: v.label,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 4),
              Text(
                'Preview · $entryCount entries',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const Divider(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxPreviewHeight),
                child: _PreviewList(
                  view: widget.view,
                  entries: _preview,
                  error: _previewError,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _previewError != null
              ? null
              : () => Navigator.of(context).pop(_collectValues()),
          child: Text('Create $entryCount'),
        ),
      ],
    );
  }
}

class _PreviewList extends StatelessWidget {
  final ViewSchema view;
  final List<Map<String, Object?>> entries;
  final String? error;

  const _PreviewList({
    required this.view,
    required this.entries,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('(no entries)'),
      );
    }
    final textTheme = Theme.of(context).textTheme;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        final title = ListDisplayRender.title(view, e);
        final subtitle = ListDisplayRender.subtitle(view, e);
        final notes = e['notes']?.toString();
        final showNotes = notes != null && notes.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${i + 1}.',
                  style: textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.bodyMedium),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    if (showNotes)
                      Text(
                        notes,
                        style: textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
