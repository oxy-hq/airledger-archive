import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/view_schema.dart';

/// Resolves an input.default value into an actual Dart value at form-creation
/// time. Supports the strings 'now' (DateTime.now()) and 'today' (date only).
Object? resolveDefault(Dimension dim) {
  final raw = dim.input?.defaultValue;
  if (raw == null) return null;
  if (raw is String) {
    if (raw == 'now') return DateTime.now();
    if (raw == 'today') {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }
  }
  return raw;
}

/// Dispatches to the correct field widget for [dim.input.widget].
///
/// [adHocSuggestions] are autocomplete values the user has previously
/// entered that aren't in the schema's `samples` — only consumed by the
/// autocomplete widget; ignored by everything else.
Widget buildFieldWidget({
  Key? key,
  required Dimension dim,
  required Object? value,
  required ValueChanged<Object?> onChanged,
  List<String>? adHocSuggestions,
}) {
  final widget = dim.input?.widget ?? _widgetForType(dim.type);
  switch (widget) {
    case WidgetType.text:
      return _TextFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
      );
    case WidgetType.longtext:
      return _TextFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        maxLines: 4,
      );
    case WidgetType.number:
      return _NumberFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
      );
    case WidgetType.date:
      return _DateFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        includeTime: false,
      );
    case WidgetType.datetime:
      return _DateFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        includeTime: true,
      );
    case WidgetType.dropdown:
      return _DropdownFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
      );
    case WidgetType.autocomplete:
      return _AutocompleteFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        adHocSuggestions: adHocSuggestions ?? const [],
      );
  }
}

WidgetType _widgetForType(DimensionType t) {
  switch (t) {
    case DimensionType.number:
      return WidgetType.number;
    case DimensionType.date:
      return WidgetType.date;
    case DimensionType.datetime:
      return WidgetType.datetime;
    case DimensionType.string:
    case DimensionType.boolean:
      return WidgetType.text;
  }
}

String _labelFor(Dimension dim) {
  final required = dim.input?.required == true ? ' *' : '';
  return '${dim.name}$required';
}

class _TextFieldWidget extends StatefulWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final int maxLines;

  const _TextFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    this.maxLines = 1,
  });

  @override
  State<_TextFieldWidget> createState() => _TextFieldWidgetState();
}

class _TextFieldWidgetState extends State<_TextFieldWidget> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value?.toString() ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nowButton = widget.dim.input?.nowButton ?? false;
    return TextField(
      controller: _controller,
      maxLines: widget.maxLines,
      decoration: InputDecoration(
        labelText: _labelFor(widget.dim),
        hintText: widget.dim.input?.placeholder,
        helperText: widget.dim.description,
        border: const OutlineInputBorder(),
        suffixIcon: nowButton
            ? IconButton(
                icon: const Icon(Icons.schedule),
                tooltip: 'Now',
                onPressed: () {
                  final now = DateFormat('h:mm:ss a').format(DateTime.now());
                  _controller.text = now;
                  widget.onChanged(now);
                },
              )
            : null,
      ),
      onChanged: (s) => widget.onChanged(s.isEmpty ? null : s),
    );
  }
}

class _NumberFieldWidget extends StatefulWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  const _NumberFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_NumberFieldWidget> createState() => _NumberFieldWidgetState();
}

class _NumberFieldWidgetState extends State<_NumberFieldWidget> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value?.toString() ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = widget.dim.input;
    return TextField(
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: _labelFor(widget.dim),
        hintText: input?.placeholder,
        helperText: widget.dim.description,
        border: const OutlineInputBorder(),
      ),
      onChanged: (s) {
        if (s.isEmpty) {
          widget.onChanged(null);
          return;
        }
        final n = num.tryParse(s);
        widget.onChanged(n);
      },
    );
  }
}

class _DateFieldWidget extends StatelessWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final bool includeTime;

  const _DateFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    required this.includeTime,
  });

  @override
  Widget build(BuildContext context) {
    final current = value is DateTime ? value as DateTime : null;
    final formatter = includeTime
        ? DateFormat('yyyy-MM-dd HH:mm')
        : DateFormat('yyyy-MM-dd');
    final display = current == null ? '—' : formatter.format(current);

    return InkWell(
      onTap: () => _pick(context, current),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: _labelFor(dim),
          helperText: dim.description,
          border: const OutlineInputBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(display),
            const Icon(Icons.calendar_today, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, DateTime? current) async {
    final now = DateTime.now();
    final initialDate = current ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    if (!includeTime) {
      onChanged(DateTime(picked.year, picked.month, picked.day));
      return;
    }
    if (!context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    final t = time ?? TimeOfDay.fromDateTime(initialDate);
    onChanged(
      DateTime(picked.year, picked.month, picked.day, t.hour, t.minute),
    );
  }
}

/// Free-form text input with suggestions from `dim.samples`. Lets the user
/// pick from a known list or type a new value (ad hoc). Matching is
/// substring + case-insensitive; the full list shows when the field is empty
/// or freshly focused.
class _AutocompleteFieldWidget extends StatelessWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  /// User-saved ad-hoc values from past sessions (loaded from
  /// AutocompleteCache). Surfaced in the dropdown after the schema's
  /// `samples` with a distinct visual marker — italic + a small "•"
  /// prefix — so the user can tell their own additions from canonical
  /// schema entries.
  final List<String> adHocSuggestions;

  const _AutocompleteFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    required this.adHocSuggestions,
  });

  /// Returns `(label, isAdHoc)` pairs for every suggestion. Samples first
  /// (canonical), then ad-hoc (user's). De-duped case-insensitively
  /// against samples — defensive even though AutocompleteCache.add does
  /// this on the write side, in case the schema's samples gained an entry
  /// after the user already cached the same string.
  List<(String, bool)> _allOptions() {
    final samples = dim.samples ?? const <String>[];
    final sampleLower = samples.map((s) => s.toLowerCase()).toSet();
    final adHoc = adHocSuggestions
        .where((s) => !sampleLower.contains(s.toLowerCase()))
        .toList();
    return [
      for (final s in samples) (s, false),
      for (final s in adHoc) (s, true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final allOptions = _allOptions();
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: value?.toString() ?? ''),
      optionsBuilder: (input) {
        final q = input.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? allOptions
            : allOptions
                .where((o) => o.$1.toLowerCase().contains(q))
                .toList();
        return filtered.take(50).map((o) => o.$1);
      },
      onSelected: (s) => onChanged(s.isEmpty ? null : s),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: _labelFor(dim),
            hintText: dim.input?.placeholder,
            helperText: dim.description,
            border: const OutlineInputBorder(),
          ),
          onChanged: (s) => onChanged(s.isEmpty ? null : s),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        // Walk the un-truncated options list in parallel so we can show
        // the ad-hoc marker on user-added entries.
        final shown = options.toList();
        final adHocSet = <String>{
          for (final (s, isAdHoc) in allOptions)
            if (isAdHoc) s,
        };
        final scheme = Theme.of(context).colorScheme;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: shown.length,
                itemBuilder: (context, index) {
                  final option = shown[index];
                  final isAdHoc = adHocSet.contains(option);
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: isAdHoc
                          ? Row(
                              children: [
                                Text(
                                  '• ',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    option,
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(option),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DropdownFieldWidget extends StatelessWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  const _DropdownFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final options = dim.input?.options ?? dim.samples ?? const <String>[];
    final current = value?.toString();
    return DropdownButtonFormField<String>(
      initialValue: options.contains(current) ? current : null,
      decoration: InputDecoration(
        labelText: _labelFor(dim),
        helperText: dim.description,
        border: const OutlineInputBorder(),
      ),
      items: options
          .map((o) => DropdownMenuItem(value: o, child: Text(o)))
          .toList(),
      onChanged: onChanged,
    );
  }
}
