import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'package:jinja/jinja.dart' hide Template;

import '../models/planned_entry.dart';
import '../models/view_schema.dart';
import '../services/derive.dart';
import '../services/list_display_render.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/log_now.dart';
import '../services/plan_store.dart';
import '../services/sheets_repository.dart';
import 'form_screen.dart';
import 'templates_screen.dart';

/// One row in the timeline. Three flavors:
/// - `_Item.planned`        — from PlanStore, not in sheet yet
/// - `_Item.logged`         — from sheet, no template association
/// - `_Item.loggedFromPlanned` — was planned, just promoted to sheet via
///   "Log now" in this session. Keeps the planned ref so the template group
///   stays attached visually (header doesn't lose count, row stays in place).
///   On the next reload the planned ref vanishes and it becomes a pure
///   `logged` item.
class _Item {
  final Record? logged;
  final PlannedEntry? planned;

  _Item.logged(this.logged) : planned = null;
  _Item.planned(this.planned) : logged = null;
  _Item.loggedFromPlanned({required this.planned, required this.logged});

  /// True only for items that haven't been written to the sheet yet.
  bool get isPlanned => planned != null && logged == null;

  /// True for both `logged` and `loggedFromPlanned` — i.e. anything that's
  /// persisted in the sheet.
  bool get isLogged => logged != null;

  /// Template association (used for grouping). Persists across the log-now
  /// transition for the current session.
  String? get templateName => planned?.templateName;

  /// Values to show / edit. Logged values are the source of truth once the
  /// sheet has accepted them.
  Map<String, Object?> get values => logged ?? planned!.values;

  String get keyString =>
      planned?.localId ??
      logged?['id']?.toString() ??
      '${identityHashCode(this)}';
}

/// Date-filtered list of records for a single view. Merges:
///   - logged rows from the sheet (filtered to selected date)
///   - planned rows from local plan store (filtered to selected date)
/// Planned rows appear at the top so they're easy to act on during a workout.
class TimelineScreen extends StatefulWidget {
  final ViewSchema view;
  final SheetsRepository repository;
  final LlmClient? llm;
  final LlmResponseCache? llmCache;

  const TimelineScreen({
    super.key,
    required this.view,
    required this.repository,
    this.llm,
    this.llmCache,
  });

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  DateTime _selectedDate = _today();
  late Future<List<_Item>> _items;
  // Multiselect state — populated only while selection mode is active. We key
  // by `_Item.keyString` so the set survives _reload() (where _Item instances
  // are rebuilt) for any items that still exist.
  final Set<String> _selectedKeys = {};
  bool _bulkDeleting = false;

  bool get _selectionMode => _selectedKeys.isNotEmpty;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _items = _fetch();
    widget.llmCache?.addListener(_onLlmUpdate);
  }

  @override
  void dispose() {
    widget.llmCache?.removeListener(_onLlmUpdate);
    super.dispose();
  }

  void _onLlmUpdate() {
    if (mounted) setState(() {});
  }

  Future<List<_Item>> _fetch() async {
    final logged = widget.view.dateField == null
        ? await widget.repository.list(widget.view)
        : await widget.repository.list(widget.view, onDate: _selectedDate);
    final planned = await PlanStore.loadForDate(widget.view, _selectedDate);
    return [
      ...planned.map(_Item.planned),
      ...logged.map(_Item.logged),
    ];
  }

  void _reload() {
    setState(() {
      _items = _fetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back button exits selection mode instead of the screen when active.
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Column(
          children: [
            if (widget.view.dateField != null)
              _DateBar(
                selected: _selectedDate,
                onChanged: (d) {
                  setState(() => _selectedDate = d);
                  _reload();
                },
              ),
            Expanded(
              child: FutureBuilder<List<_Item>>(
                future: _items,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _ErrorView(error: snap.error.toString());
                  }
                  final items = snap.data ?? [];
                  if (items.isEmpty) {
                    return const Center(child: Text('No entries.'));
                  }
                  final rows = _groupByTemplate(items);
                  return ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, i) {
                      // No divider directly above or below a template header —
                      // the header has its own background, so adjacent dividers
                      // would look noisy.
                      final above = rows[i];
                      final below = rows[i + 1];
                      if (above is _HeaderRow || below is _HeaderRow) {
                        return const SizedBox.shrink();
                      }
                      return const Divider(height: 1);
                    },
                    itemBuilder: (_, i) {
                      final row = rows[i];
                      if (row is _HeaderRow) {
                        return _TemplateHeader(
                          name: row.name,
                          totalCount: row.totalCount,
                          doneCount: row.doneCount,
                          onDelete: () => _deleteTemplateGroup(row.name),
                        );
                      }
                      final item = row as _Item;
                      final selected = _selectedKeys.contains(item.keyString);
                      return _RecordTile(
                        view: widget.view,
                        item: item,
                        selected: selected,
                        selectionMode: _selectionMode,
                        llmCache: widget.llmCache,
                        onTap: _selectionMode
                            ? () => _toggleSelect(item)
                            : () => _edit(item),
                        onLongPress: () => _toggleSelect(item),
                        onDelete: () => _delete(item),
                        onLogNow: () => _logNow(item),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                onPressed: _create,
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  AppBar _buildNormalAppBar() {
    return AppBar(
      title: Text(widget.view.name),
      actions: [
        IconButton(
          icon: const Icon(Icons.list_alt),
          onPressed: _openTemplates,
          tooltip: 'Templates',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _reload,
          tooltip: 'Refresh',
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
        tooltip: 'Clear selection',
      ),
      title: Text('${_selectedKeys.length} selected'),
      actions: [
        IconButton(
          icon: _bulkDeleting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.delete),
          onPressed: _bulkDeleting ? null : _bulkDelete,
          tooltip: 'Delete selected',
        ),
      ],
    );
  }

  void _toggleSelect(_Item item) {
    setState(() {
      if (_selectedKeys.contains(item.keyString)) {
        _selectedKeys.remove(item.keyString);
      } else {
        _selectedKeys.add(item.keyString);
      }
    });
  }

  void _clearSelection() {
    setState(_selectedKeys.clear);
  }

  /// Resolves the currently-selected keys back to live `_Item`s (the future may
  /// have refreshed since selection started — any vanished item is silently
  /// skipped). Runs PlanStore.remove for planned, repo.delete for logged.
  Future<void> _bulkDelete() async {
    final items = await _items;
    final selected =
        items.where((it) => _selectedKeys.contains(it.keyString)).toList();
    if (selected.isEmpty) {
      _clearSelection();
      return;
    }
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${selected.length} entries?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _bulkDeleting = true);
    try {
      await _deleteOptimistic(
        selected.map((it) => it.keyString).toSet(),
      );
    } finally {
      if (mounted) setState(() => _bulkDeleting = false);
    }
  }

  Future<void> _openTemplates() async {
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TemplatesScreen(
          view: widget.view,
          repository: widget.repository,
          onDate: _selectedDate,
        ),
      ),
    );
    if (applied == true) _reload();
  }

  Future<void> _create() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FormScreen(
          view: widget.view,
          repository: widget.repository,
        ),
      ),
    );
    if (saved == true) _reload();
  }

  Future<void> _edit(_Item item) async {
    if (item.isPlanned) {
      // Save on a planned entry = log. Form is pre-filled with the planned
      // values; the user tweaks them and tapping save commits to the sheet
      // and removes the planned row (same path as the Play button).
      final result = await Navigator.of(context).push<Map<String, Object?>>(
        MaterialPageRoute(
          builder: (_) => FormScreen(
            view: widget.view,
            repository: widget.repository,
            existing: Map<String, Object?>.from(item.planned!.values),
            planMode: true,
          ),
        ),
      );
      if (result == null) return;
      await _logNow(item, overrideValues: result);
    } else {
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => FormScreen(
            view: widget.view,
            repository: widget.repository,
            existing: item.logged,
          ),
        ),
      );
      if (saved == true) _reload();
    }
  }

  Future<void> _delete(_Item item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(item.isPlanned
            ? 'Remove this planned entry?'
            : 'Delete this entry?'),
        content: Text(_titleFor(widget.view, item.values)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(item.isPlanned ? 'Remove' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _deleteOptimistic({item.keyString});
  }

  /// Optimistic delete: drops the matching items from the in-memory list
  /// immediately (no spinner / no re-fetch from Sheets), then runs the actual
  /// backend deletes in the background. On error, snackbars and re-syncs from
  /// the source of truth.
  Future<void> _deleteOptimistic(Set<String> keys) async {
    final current = await _items;
    final toDelete =
        current.where((it) => keys.contains(it.keyString)).toList();
    if (toDelete.isEmpty) return;
    final remaining =
        current.where((it) => !keys.contains(it.keyString)).toList();
    setState(() {
      _items = Future.value(remaining);
      _selectedKeys.removeAll(keys);
    });
    try {
      for (final item in toDelete) {
        if (item.isPlanned) {
          await PlanStore.remove(widget.view, item.planned!.localId);
        } else {
          await widget.repository.delete(widget.view, item.logged!);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e — refreshing')),
      );
      _reload();
    }
  }

  Future<void> _deleteTemplateGroup(String templateName) async {
    final current = await _items;
    final groupKeys = current
        .where((it) =>
            it.isPlanned && it.planned!.templateName == templateName)
        .map((it) => it.keyString)
        .toSet();
    if (groupKeys.isEmpty) return;
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove $templateName?'),
        content: Text('Drops ${groupKeys.length} planned entries.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _deleteOptimistic(groupKeys);
  }

  /// Promotes a planned entry into a sheet row. The entry's start_time is
  /// stamped with now (unless the user already set one via edit), derives
  /// are applied, then it's written to the sheet and removed from local plan.
  ///
  /// Optimistic: the row stays exactly where it is in the list (under its
  /// template header) and just visually flips to "done". The Sheets `create`
  /// happens in the background; on failure we surface a snackbar and
  /// re-sync from the source of truth.
  Future<void> _logNow(_Item item, {Map<String, Object?>? overrideValues}) async {
    if (!item.isPlanned) return;
    final planned = item.planned!;
    // `overrideValues` is the post-edit values map (from the Save-on-planned
    // path). When present, it takes precedence over `planned.values` so any
    // tweaks the user made in the form survive into the logged row.
    final values =
        Map<String, Object?>.from(overrideValues ?? planned.values);
    final plannable = widget.view.plannable;
    if (plannable != null) {
      final existing = values[plannable.logField];
      if (existing == null || (existing is String && existing.isEmpty)) {
        values[plannable.logField] = logNowValue(plannable.logFormat);
      }
    }
    final dateDim = widget.view.dateField;
    // Only backfill from the planning date if the user didn't set their own
    // date in the edit form. Honoring a user-entered date matters for the
    // "logging yesterday's set today" case.
    if (dateDim != null && values[dateDim] == null) {
      values[dateDim] = planned.date;
    }
    applyDerives(widget.view, values);
    // Pre-assign id so we can resolve the row for future edits/deletes without
    // re-fetching from Sheets (the create call doesn't return the row index).
    if (widget.view.dimensionByName('id') != null && values['id'] == null) {
      values['id'] = const Uuid().v4();
    }

    // Optimistic: remove the planned row from where it was and append the
    // freshly-logged row at the END of the merged list (bottom of the
    // logged section). Matches reload: list() sorts a date's logged rows
    // ascending by the plannable log_field (start_time), so a row with
    // start_time = now lands at the bottom of that day's logged rows.
    //
    // Drop the template association (use _Item.logged not
    // loggedFromPlanned) so the just-logged row doesn't drag its template
    // header into the logged section. The template's progress counter
    // ("2 / 5 done") rebuilds from the remaining planned rows on the next
    // _reload — same-session it temporarily under-counts, which is
    // acceptable for an optimistic UI.
    //
    // The +1 row-index shift on existing logged rows mirrors the server-
    // side insert at sheet row 2 that create() is about to do.
    values[rowIndexKey] = 0;
    final current = await _items;
    final idx = current.indexWhere((it) => it.keyString == planned.localId);
    if (idx >= 0) {
      SheetsRepository.shiftRowIndexes(
        current.where((it) => it.isLogged).map((it) => it.logged!),
        by: 1,
      );
      final updated = List<_Item>.from(current);
      updated.removeAt(idx);
      updated.add(_Item.logged(values));
      setState(() => _items = Future.value(updated));
    }

    try {
      await widget.repository.create(widget.view, values);
      await PlanStore.remove(widget.view, planned.localId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Log failed: $e — refreshing')),
      );
      _reload();
      return;
    }

    // Fire the post-log LLM hook (if configured) in the background.
    // Response lands in llmCache and the tile rebuilds when ready.
    final hook = widget.view.postLog;
    final llm = widget.llm;
    final cache = widget.llmCache;
    final rowId = values['id']?.toString();
    if (hook != null && llm != null && cache != null && rowId != null) {
      _runPostLogHook(hook, values, rowId, llm, cache);
    }
  }

  /// Renders the post-log Jinja prompt with row + historical context, calls
  /// the model, stores the response in the cache. Fire-and-forget — the
  /// timeline rebuilds via the cache listener when the response arrives.
  ///
  /// Jinja context exposed to the prompt:
  ///   - `row`            the just-logged record (Map)
  ///   - `view.name`, `view.description`
  ///   - `today`          rows logged today (this view) — list of Maps
  ///   - `last_7_days`    rows in last 7 calendar days
  ///   - `last_30_days`   rows in last 30 calendar days
  ///   - `recent`         most-recent 50 rows regardless of date
  ///   - `all`            every row for this view
  ///   - `last_n_days(n)` callable — rows in last n calendar days
  ///   - `last_n_weeks(n)` callable — rows in last n*7 calendar days
  ///   - `last_n_months(n)` callable — rows in last n*30 calendar days
  void _runPostLogHook(
    PostLogHook hook,
    Record row,
    String rowId,
    LlmClient llm,
    LlmResponseCache cache,
  ) {
    if (!llm.has(hook.model)) return;
    cache.markPending(rowId);
    () async {
      try {
        final dateField = widget.view.dateField;

        // Pull all history for this view (best-effort: empty if it fails so
        // the prompt still renders rather than the hook silently dropping).
        List<Record> allRows = [];
        try {
          allRows = await widget.repository.list(widget.view);
        } catch (_) {
          allRows = [];
        }

        // Sort newest-first by dateField (rows without a parseable date sink
        // to the bottom). Stable enough for "recent" / iteration semantics.
        DateTime? rowDay(Record r) {
          if (dateField == null) return null;
          final v = r[dateField];
          if (v is DateTime) return DateTime(v.year, v.month, v.day);
          if (v is String) {
            final d = DateTime.tryParse(v);
            if (d != null) return DateTime(d.year, d.month, d.day);
          }
          return null;
        }

        allRows.sort((a, b) {
          final da = rowDay(a);
          final db = rowDay(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });

        final now = DateTime.now();
        final todayDay = DateTime(now.year, now.month, now.day);

        // "Last N days" = the trailing N calendar days *including today*.
        // n=1 → today only; n=7 → today + 6 prior days.
        List<Record> lastNDays(int n) {
          if (dateField == null || n <= 0) return const [];
          final cutoff = todayDay.subtract(Duration(days: n - 1));
          return allRows.where((r) {
            final d = rowDay(r);
            return d != null && !d.isBefore(cutoff);
          }).toList();
        }

        final todayRows = lastNDays(1);
        final last7 = lastNDays(7);
        final last30 = lastNDays(30);
        final recent = allRows.take(50).toList();

        final env = Environment(
          globals: {
            'last_n_days': ([Object? n]) => lastNDays(_coerceInt(n, 7)),
            'last_n_weeks': ([Object? n]) => lastNDays(_coerceInt(n, 1) * 7),
            'last_n_months': ([Object? n]) =>
                lastNDays(_coerceInt(n, 1) * 30),
          },
        );
        final tpl = env.fromString(hook.prompt);
        final rendered = tpl.render({
          'row': row,
          'view': {
            'name': widget.view.name,
            'description': widget.view.description,
          },
          'today': todayRows,
          'last_7_days': last7,
          'last_30_days': last30,
          'recent': recent,
          'all': allRows,
        });
        final response = await llm.complete(hook.model, rendered);
        cache.put(rowId, response);
      } catch (e) {
        cache.putError(rowId, e.toString());
      }
    }();
  }
}

/// Coerces a value handed to a Jinja callable (anything — int, num, String,
/// null) into a Dart int. Falls back to [fallback] when missing or
/// uncoercible. Used so prompts like `last_n_days(7)` and `last_n_days("7")`
/// both work.
int _coerceInt(Object? v, int fallback) {
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _titleFor(ViewSchema view, Map<String, Object?> record) =>
    ListDisplayRender.title(view, record);

String? _subtitleFor(ViewSchema view, Map<String, Object?> record) =>
    ListDisplayRender.subtitle(view, record);

/// Walks the ordered item list once, emitting a `_HeaderRow` data marker
/// whenever the planned-template attribution changes. Logged items and
/// ad-hoc planned items (no template) emit no header. Assumes items are
/// already grouped contiguously by template — true because `PlanStore.addAll`
/// appends in apply order and we never interleave.
List<Object> _groupByTemplate(List<_Item> items) {
  final out = <Object>[];
  String? lastHeader;
  // Pre-count done / total per template name. `loggedFromPlanned` items count
  // toward both totals and dones; pure `planned` items count toward totals only.
  final totals = <String, int>{};
  final dones = <String, int>{};
  for (final it in items) {
    final t = it.templateName;
    if (t == null) continue;
    totals[t] = (totals[t] ?? 0) + 1;
    if (it.isLogged) dones[t] = (dones[t] ?? 0) + 1;
  }
  for (final item in items) {
    final templateName = item.templateName;
    if (templateName != null && templateName != lastHeader) {
      out.add(_HeaderRow(
        name: templateName,
        totalCount: totals[templateName] ?? 0,
        doneCount: dones[templateName] ?? 0,
      ));
      lastHeader = templateName;
    } else if (templateName == null) {
      lastHeader = null;
    }
    out.add(item);
  }
  return out;
}

/// Data-only marker for a template group header. The actual widget
/// (`_TemplateHeader`) is constructed in the timeline's itemBuilder so it can
/// close over the delete callback.
class _HeaderRow {
  final String name;
  final int totalCount;
  final int doneCount;
  _HeaderRow({
    required this.name,
    required this.totalCount,
    required this.doneCount,
  });
}

/// Section header rendered above the planned items that came from the same
/// template apply. The trailing delete button removes the whole group
/// (after confirm).
class _TemplateHeader extends StatelessWidget {
  final String name;
  final int totalCount;
  final int doneCount;
  final VoidCallback onDelete;

  const _TemplateHeader({
    required this.name,
    required this.totalCount,
    required this.doneCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 10, bottom: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              '$doneCount / $totalCount',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: scheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            tooltip: 'Remove group',
          ),
        ],
      ),
    );
  }
}

class _DateBar extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onChanged;

  const _DateBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat('EEE, MMM d');
    final isToday = _isSameDay(selected, _now());

    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: scheme.outline, width: 1),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 24),
            color: scheme.onSurface,
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                onChanged(selected.subtract(const Duration(days: 1))),
          ),
          Expanded(
            child: TextButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: selected,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(_now().year + 5),
                );
                if (picked != null) onChanged(picked);
              },
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurface,
              ),
              child: Text(
                isToday ? 'Today' : formatter.format(selected),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 24),
            color: scheme.onSurface,
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                onChanged(selected.add(const Duration(days: 1))),
          ),
        ],
      ),
    );
  }

  static DateTime _now() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _RecordTile extends StatelessWidget {
  final ViewSchema view;
  final _Item item;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onLogNow;
  final LlmResponseCache? llmCache;

  const _RecordTile({
    required this.view,
    required this.item,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    required this.onLogNow,
    this.llmCache,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitleFor(view, item.values);
    final scheme = Theme.of(context).colorScheme;
    final rowId = item.logged?['id']?.toString();
    final llmResponse =
        rowId == null ? null : llmCache?.get(rowId);
    final llmPending =
        rowId == null ? false : (llmCache?.isPending(rowId) ?? false);
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 0,
      horizontalTitleGap: 14,
      minVerticalPadding: 10,
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.4),
      // The leading slot doubles as the log-button when the row is planned:
      // the empty orange circle is tappable (with a Material ripple to
      // signal "this is a button") and tap = log. Replaces the separate
      // trailing play button — same affordance the user's intuition was
      // already reaching for.
      leading: selectionMode
          ? Icon(
              selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected ? scheme.secondary : scheme.outlineVariant,
            )
          : (item.isPlanned
              ? _LogCircle(onTap: onLogNow)
              : const Padding(
                  padding: EdgeInsets.all(11),
                  child: Icon(Icons.check_circle,
                      size: 22, color: Colors.green),
                )),
      title: Text(_titleFor(view, item.values)),
      subtitle: (subtitle == null && llmResponse == null && !llmPending)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle != null) Text(subtitle),
                if (llmPending)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                    ),
                  )
                else if (llmResponse != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      llmResponse,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                            height: 1.35,
                          ),
                    ),
                  ),
              ],
            ),
      // No trailing action — the leading circle is now the log button.
      trailing: null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
    // Swipe-to-delete is disabled in selection mode — too easy to fire
    // accidentally while scrolling through a long selection.
    if (selectionMode) return tile;
    return Dismissible(
      key: ValueKey(item.keyString),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: tile,
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text('Error: $error', textAlign: TextAlign.center),
      ),
    );
  }
}

/// Tappable empty-circle that fills the row's leading slot for planned
/// items. Tap = promote-to-logged (calls onLogNow). The Material ink
/// ripple is what makes the affordance read "this is a button" instead
/// of "this is a status icon" — the visual is otherwise identical to
/// the static green check the row flips to once logged.
class _LogCircle extends StatelessWidget {
  final VoidCallback onTap;
  const _LogCircle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        // 44x44 hit target — Material accessibility minimum — even though
        // the visual circle is only 22px. The extra padding is invisible
        // but catches near-misses comfortably.
        customBorder: const CircleBorder(),
        child: const Padding(
          padding: EdgeInsets.all(11),
          child: Icon(
            Icons.radio_button_unchecked,
            size: 22,
            color: Colors.orange,
          ),
        ),
      ),
    );
  }
}
