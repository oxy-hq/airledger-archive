import 'package:jinja/jinja.dart' hide Template;

import '../models/template.dart';
import '../models/view_schema.dart';
import 'cell_codec.dart';

/// Renders a template's entries: each string value is run through Jinja with
/// the user-supplied variable map, then coerced back into the dimension's
/// native Dart type (so `"95"` becomes `95` for a number column).
class TemplateInterpolator {
  // dart `jinja: ^0.6.6` doesn't register `round`, and its built-in `int`
  // filter is a `String -> int` parse (not a numeric cast), which throws on
  // floats. Register a `round` that does real number rounding so templates
  // can compute clean plate weights via `(x * pct) | round`.
  static final _env = Environment(filters: {
    'round': (Object? value) {
      final n = value is num ? value : num.tryParse(value.toString());
      return n?.round() ?? value;
    },
  });

  /// Returns a fresh list of records (dimension-name → value) ready to hand to
  /// the repository. [vars] holds the resolved variable values keyed by name.
  static List<Map<String, Object?>> apply(
    Template template,
    ViewSchema view,
    Map<String, Object?> vars,
  ) {
    return template.entries
        .map((entry) => _applyOne(entry, view, vars))
        .toList();
  }

  static Map<String, Object?> _applyOne(
    Map<String, Object?> entry,
    ViewSchema view,
    Map<String, Object?> vars,
  ) {
    final out = <String, Object?>{};
    for (final field in entry.keys) {
      final raw = entry[field];
      final rendered = _render(raw, vars);
      out[field] = _coerce(view, field, rendered);
    }
    return out;
  }

  /// Runs Jinja on string values only; leaves non-string literals
  /// (numbers, bools, etc) untouched. A string with no `{{` is also returned
  /// as-is to skip the template engine round-trip.
  static Object? _render(Object? value, Map<String, Object?> vars) {
    if (value is! String) return value;
    if (!value.contains('{{') && !value.contains('{%')) return value;
    final template = _env.fromString(value);
    return template.render(vars);
  }

  /// Coerces a rendered value into the dimension's native type. Jinja outputs
  /// strings, so a number column needs `"95"` → `95`. Reuses [CellCodec.decode]
  /// for consistency with the read path.
  static Object? _coerce(ViewSchema view, String field, Object? rendered) {
    final dim = view.dimensionByName(field);
    if (dim == null || rendered == null) return rendered;
    if (rendered is String) {
      return CellCodec.decode(dim.type, rendered);
    }
    return rendered;
  }
}
