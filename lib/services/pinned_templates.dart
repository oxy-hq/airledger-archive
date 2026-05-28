import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-view set of pinned template names, stored in `shared_preferences`
/// under `pinned_templates:<view_name>` as a JSON array. Pinned templates
/// float to the top of the templates list.
///
/// Identity is the template's `name:` field (not its file path), so renaming
/// a template breaks its pin. That's acceptable for a single-device app
/// where pins are easy to re-apply.
class PinnedTemplates {
  static const _prefix = 'pinned_templates:';
  static String _key(String viewName) => '$_prefix$viewName';

  static Future<Set<String>> loadForView(String viewName) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(viewName));
    if (raw == null) return <String>{};
    final list = jsonDecode(raw) as List;
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> _save(String viewName, Set<String> names) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(viewName), jsonEncode(names.toList()));
  }

  /// Toggles the pinned state of [templateName] for [viewName].
  /// Returns the new state (true = now pinned).
  static Future<bool> toggle(String viewName, String templateName) async {
    final pinned = await loadForView(viewName);
    final isNowPinned = !pinned.contains(templateName);
    if (isNowPinned) {
      pinned.add(templateName);
    } else {
      pinned.remove(templateName);
    }
    await _save(viewName, pinned);
    return isNowPinned;
  }
}
