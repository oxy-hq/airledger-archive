import 'package:shared_preferences/shared_preferences.dart';

import '../models/template.dart';

/// Persists the last-used variable values for each template so the apply
/// dialog can pre-fill them next time instead of falling back to the YAML
/// default. Stored in `shared_preferences` under
/// `template_var:<template_id>:<var_name>`.
///
/// Numbers are stored as doubles; everything else as strings. The cache is
/// best-effort — a missing key returns null and the caller falls back to the
/// YAML default.
class TemplateVarsCache {
  static const _prefix = 'template_var:';

  /// Resolves the values for [template]: cached value > YAML default > null.
  static Future<Map<String, Object?>> resolve(Template template) async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, Object?>{};
    for (final v in template.variables) {
      final key = _key(template, v.name);
      switch (v.type) {
        case TemplateVarType.number:
          final cached = prefs.getDouble(key);
          out[v.name] = cached ?? _asNum(v.defaultValue);
          break;
        case TemplateVarType.string:
          final cached = prefs.getString(key);
          out[v.name] = cached ?? v.defaultValue?.toString();
          break;
      }
    }
    return out;
  }

  /// Saves [values] back as the new defaults for [template].
  static Future<void> save(
    Template template,
    Map<String, Object?> values,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    for (final v in template.variables) {
      final key = _key(template, v.name);
      final value = values[v.name];
      if (value == null) {
        await prefs.remove(key);
        continue;
      }
      switch (v.type) {
        case TemplateVarType.number:
          final n = _asNum(value);
          if (n != null) await prefs.setDouble(key, n.toDouble());
          break;
        case TemplateVarType.string:
          await prefs.setString(key, value.toString());
          break;
      }
    }
  }

  static String _key(Template t, String varName) =>
      '$_prefix${t.id}:$varName';

  static num? _asNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v;
    return num.tryParse(v.toString());
  }
}
