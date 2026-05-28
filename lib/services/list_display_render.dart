import '../models/view_schema.dart';

/// Renders `list_display.title` / `list_display.subtitle` for a record.
/// Shared between the timeline and the templates apply-preview so both show
/// rows the same way. The subtitle template uses `${field}` placeholders
/// (Sheets-style), not Jinja — kept simple intentionally.
class ListDisplayRender {
  static String title(ViewSchema view, Map<String, Object?> record) {
    final titleField = view.listDisplay?.title ?? view.dimensions.first.name;
    final v = record[titleField];
    return v?.toString() ?? '—';
  }

  static String? subtitle(ViewSchema view, Map<String, Object?> record) {
    final template = view.listDisplay?.subtitle;
    if (template == null) return null;
    final s = interpolate(template, record).trim();
    return s.isEmpty ? null : s;
  }

  static String interpolate(String template, Map<String, Object?> record) {
    final re = RegExp(r'\$\{([^}]+)\}');
    return template.replaceAllMapped(re, (m) {
      final key = m.group(1)!;
      final v = record[key];
      return v?.toString() ?? '';
    });
  }
}
