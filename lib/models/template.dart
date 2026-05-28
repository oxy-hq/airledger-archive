/// A reusable preset that fans out into N partially-filled records when
/// applied. Drives the "predefined workouts" feature.
///
/// Templates live in `assets/templates/<view>/<name>.yml`. The `entries`
/// list contains maps of dimension-name → value; missing fields are left
/// blank when records are created. Entry values may be Jinja2 expressions
/// (e.g. `"{{ squat - 20 }}"`) that reference [variables] — see
/// `TemplateInterpolator`.
class Template {
  final String name;
  final String view;
  final String? description;
  final List<TemplateVariable> variables;
  final List<Map<String, Object?>> entries;

  Template({
    required this.name,
    required this.view,
    this.description,
    this.variables = const [],
    required this.entries,
  });

  /// Stable id used to namespace cached variable values.
  String get id => '$view/$name';
}

/// A named input the user supplies (or accepts the default of) when applying
/// a template. Referenced in entries via `{{ name }}` (or any Jinja expression).
class TemplateVariable {
  final String name;
  final String label;
  final TemplateVarType type;
  final Object? defaultValue;

  TemplateVariable({
    required this.name,
    required this.label,
    required this.type,
    this.defaultValue,
  });
}

enum TemplateVarType { number, string }
