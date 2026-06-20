/// Engine-backed sheets connector: implements [`WarehouseConnector`]
/// by routing every CRUD call through the Rust engine's
/// [`EngineSheetsRepository`] (FFI handle).
///
/// Mirrors the Dart [`SheetsRepository`] shape so the rest of the
/// app (timeline, form, repository registry) can swap between
/// implementations behind the `useEngine` flag without touching its
/// callers.
library;

import 'package:airledger_engine/airledger_engine.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'engine.dart';
import 'engine_schema_adapter.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';

class EngineSheetsConnector implements WarehouseConnector {
  @override
  final SheetsConfig config;
  final String defaultSpreadsheetId;
  final EngineSheetsRepository _repo;

  EngineSheetsConnector._(this.config, this.defaultSpreadsheetId, this._repo);

  /// Opens an engine-backed sheets connection. Mirrors
  /// [`SheetsRepository.connectFromKey`] — same params, same
  /// failure mode (throws if the service-account JSON is malformed).
  static Future<EngineSheetsConnector> connectFromKey({
    required String defaultSpreadsheetId,
    required String serviceAccountKeyJson,
    SheetsConfig? config,
  }) async {
    final repo = getEngine().connectSheets(
      defaultSpreadsheetId: defaultSpreadsheetId,
      serviceAccountJson: serviceAccountKeyJson,
    );
    return EngineSheetsConnector._(
      config ?? SheetsConfig(name: 'gsheets', spreadsheetId: defaultSpreadsheetId),
      defaultSpreadsheetId,
      repo,
    );
  }

  /// Release the underlying Rust handle. The Finalizer cleans up
  /// at GC time if the app forgets, but explicit close is cheap.
  void close() => _repo.close();

  @override
  Future<void> ensureTable(ViewSchema view) async {
    _repo.ensureSheet(viewSchemaToEngineJson(view));
  }

  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    final raw = _repo.list(
      viewSchemaToEngineJson(view),
      onDate: onDate,
    );
    return raw.map((r) {
      final rec = recordFromEngineJson(r);
      // Engine puts __row in as an int via the tagged envelope; the
      // codec lifts that to a Dart int automatically. Same key the
      // pure-Dart SheetsRepository uses, so existing call sites in
      // form_screen / timeline_screen keep working.
      return rec;
    }).toList();
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async {
    final raw = _repo.create(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
    return recordFromEngineJson(raw);
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {
    _repo.update(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
  }

  @override
  Future<void> delete(ViewSchema view, Record record) async {
    _repo.delete(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
  }
}

