import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../services/cell_codec.dart';
import 'view_schema.dart';

/// A row the user intends to log but hasn't yet. Lives only in local storage
/// (see `PlanStore`); never written to the sheet until promoted via "Log now"
/// (which calls `repository.create` and removes the entry from the plan).
///
/// Identified by a [localId] (not a sheet UUID) so we can update/remove
/// without round-tripping through the sheet.
class PlannedEntry {
  final String localId;
  final String viewName;
  final DateTime date;
  final Map<String, Object?> values;

  /// Name of the template this entry came from, if any. Used in the timeline
  /// to group rows under a template header. The originating template is a
  /// purely local-storage concern — once an entry is logged (promoted to the
  /// sheet), the template attachment is dropped.
  final String? templateName;

  PlannedEntry({
    required this.localId,
    required this.viewName,
    required this.date,
    required this.values,
    this.templateName,
  });

  factory PlannedEntry.create({
    required ViewSchema view,
    required DateTime date,
    required Map<String, Object?> values,
    String? templateName,
  }) {
    return PlannedEntry(
      localId: const Uuid().v4(),
      viewName: view.name,
      date: date,
      values: values,
      templateName: templateName,
    );
  }

  /// Serializes to JSON. Values are encoded via [CellCodec] so we round-trip
  /// the same way sheet cells do — DateTimes become ISO strings, numbers
  /// stay as `num`, booleans stay as `bool` (all are valid JSON types).
  Map<String, dynamic> toJson(ViewSchema view) {
    final v = <String, dynamic>{};
    for (final entry in values.entries) {
      final dim = view.dimensionByName(entry.key);
      if (dim == null) continue;
      v[entry.key] = CellCodec.encode(dim.type, entry.value);
    }
    return {
      'local_id': localId,
      'view': viewName,
      'date': DateFormat('yyyy-MM-dd').format(date),
      'values': v,
      if (templateName != null) 'template': templateName,
    };
  }

  static PlannedEntry fromJson(Map<String, dynamic> json, ViewSchema view) {
    final values = <String, Object?>{};
    final raw = json['values'] as Map;
    for (final entry in raw.entries) {
      final name = entry.key.toString();
      final dim = view.dimensionByName(name);
      if (dim == null) continue;
      // CellCodec.decode handles strings (legacy entries) and passes typed
      // primitives through unchanged for newer JSON-typed entries.
      final raw = entry.value;
      values[name] = raw is String ? CellCodec.decode(dim.type, raw) : raw;
    }
    return PlannedEntry(
      localId: json['local_id'] as String,
      viewName: view.name,
      date: DateTime.parse(json['date'] as String),
      values: values,
      templateName: json['template'] as String?,
    );
  }

  PlannedEntry copyWith({Map<String, Object?>? values}) {
    return PlannedEntry(
      localId: localId,
      viewName: viewName,
      date: date,
      values: values ?? this.values,
      templateName: templateName,
    );
  }
}
