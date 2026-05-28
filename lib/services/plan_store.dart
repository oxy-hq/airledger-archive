import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/planned_entry.dart';
import '../models/view_schema.dart';

/// Per-view local store of [PlannedEntry] rows. Backed by `shared_preferences`
/// under one JSON-array key per view: `plan:<view_name>`. Small and synchronous
/// enough that we don't bother with sqflite.
///
/// Entries are date-scoped at read time — the timeline asks for the entries
/// for a specific date, and we filter the full list. Past-date entries are
/// "cobwebs" that hang around silently until the user dismisses them; they
/// don't appear on the timeline (which filters by selected date).
class PlanStore {
  static const _prefix = 'plan:';
  static String _key(String viewName) => '$_prefix$viewName';

  static Future<List<PlannedEntry>> loadForDate(
    ViewSchema view,
    DateTime date,
  ) async {
    final all = await _loadAll(view);
    final target = DateFormat('yyyy-MM-dd').format(date);
    return all
        .where((e) => DateFormat('yyyy-MM-dd').format(e.date) == target)
        .toList();
  }

  static Future<List<PlannedEntry>> _loadAll(ViewSchema view) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(view.name));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => PlannedEntry.fromJson(
              (e as Map).cast<String, dynamic>(),
              view,
            ))
        .toList();
  }

  static Future<void> _saveAll(
    ViewSchema view,
    List<PlannedEntry> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final list = entries.map((e) => e.toJson(view)).toList();
    await prefs.setString(_key(view.name), jsonEncode(list));
  }

  /// Appends [entries] to the plan for [view]. Useful for template apply.
  static Future<void> addAll(
    ViewSchema view,
    List<PlannedEntry> entries,
  ) async {
    final all = await _loadAll(view);
    all.addAll(entries);
    await _saveAll(view, all);
  }

  /// Replaces a single entry by [PlannedEntry.localId]. No-op if not found.
  static Future<void> update(ViewSchema view, PlannedEntry entry) async {
    final all = await _loadAll(view);
    final idx = all.indexWhere((e) => e.localId == entry.localId);
    if (idx < 0) return;
    all[idx] = entry;
    await _saveAll(view, all);
  }

  /// Removes the entry with [localId]. No-op if not found.
  static Future<void> remove(ViewSchema view, String localId) async {
    final all = await _loadAll(view);
    all.removeWhere((e) => e.localId == localId);
    await _saveAll(view, all);
  }
}
