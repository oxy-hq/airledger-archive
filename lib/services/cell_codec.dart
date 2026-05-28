import '../models/view_schema.dart';

/// Converts between typed Dart values and the values the Sheets API exchanges.
///
/// We send native types (num, bool, String) where possible so Sheets stores
/// them with the right cell type. Strings sent for numeric values would
/// otherwise display a leading apostrophe (Sheets' "this looks numeric but is
/// text" marker). Dates and datetimes are emitted as ISO strings — Sheets
/// shows them as text, which is what we want for stable round-tripping.
class CellCodec {
  /// Converts a Dart value into the form to write to a Sheets cell. Returns
  /// `num` for number dimensions, `bool` for boolean dimensions, and `String`
  /// for everything else (including empty string for null).
  static Object encode(DimensionType type, Object? value) {
    if (value == null) return '';
    switch (type) {
      case DimensionType.string:
        return value.toString();
      case DimensionType.number:
        if (value is num) return value;
        final parsed = num.tryParse(value.toString());
        return parsed ?? value.toString();
      case DimensionType.date:
        if (value is DateTime) {
          final d = value;
          return '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
        }
        return value.toString();
      case DimensionType.datetime:
        if (value is DateTime) return value.toIso8601String();
        return value.toString();
      case DimensionType.boolean:
        if (value is bool) return value;
        return value.toString().toLowerCase() == 'true';
    }
  }

  /// Decodes a cell value (Object? from Sheets) into a typed Dart value.
  /// Returns null for empty cells.
  static Object? decode(DimensionType type, Object? raw) {
    if (raw == null) return null;
    final s = raw.toString();
    if (s.isEmpty) return null;
    switch (type) {
      case DimensionType.string:
        return s;
      case DimensionType.number:
        return num.tryParse(s) ?? 0;
      case DimensionType.date:
        return DateTime.tryParse(s);
      case DimensionType.datetime:
        return DateTime.tryParse(s);
      case DimensionType.boolean:
        return s.toLowerCase() == 'true';
    }
  }
}
