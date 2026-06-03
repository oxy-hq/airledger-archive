import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/view_schema.dart';

/// Per-(view, dimension) local store of ad-hoc autocomplete values — things
/// the user typed into an autocomplete field that weren't in the schema's
/// `samples:` list. Surfaced in future autocomplete dropdowns alongside the
/// canonical samples, with a visual marker so the user can tell which
/// suggestions are theirs vs. the schema's.
///
/// Backed by `shared_preferences` under one JSON-array key per (view,
/// dim): `ac_cache:<view_name>:<dim_name>`. Tiny — a few hundred strings
/// per field at most.
///
/// Values are stored in insert order (most-recently-added first). De-dupes
/// case-insensitively and ignores anything already present in
/// [Dimension.samples] so the canonical list stays authoritative.
class AutocompleteCache {
  static const _prefix = 'ac_cache:';
  static String _key(String viewName, String dimName) =>
      '$_prefix$viewName:$dimName';

  /// Returns the cached ad-hoc values for this view+dim, newest-first.
  /// Empty if nothing's been added yet.
  static Future<List<String>> load(
      ViewSchema view, String dimName) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(view.name, dimName));
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Adds [value] to the cache for view+dim, if it's not already in
  /// [Dimension.samples] (canonical list wins) and not already cached.
  /// Inserts at the front so most-recent-first ordering survives. No-op
  /// for empty/null values.
  static Future<void> add(
    ViewSchema view,
    Dimension dim,
    String? value,
  ) async {
    if (value == null) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final samples = dim.samples ?? const <String>[];
    final lower = trimmed.toLowerCase();
    if (samples.any((s) => s.toLowerCase() == lower)) return;
    final existing = await load(view, dim.name);
    if (existing.any((s) => s.toLowerCase() == lower)) return;
    final updated = [trimmed, ...existing];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(view.name, dim.name), jsonEncode(updated));
  }

  /// Removes [value] from the cache (case-insensitive). Returns true if
  /// the value was present. Exposed for future "clear ad-hoc value" UX.
  static Future<bool> remove(
    ViewSchema view,
    String dimName,
    String value,
  ) async {
    final existing = await load(view, dimName);
    final lower = value.toLowerCase();
    final filtered =
        existing.where((s) => s.toLowerCase() != lower).toList();
    if (filtered.length == existing.length) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(view.name, dimName),
      jsonEncode(filtered),
    );
    return true;
  }
}
