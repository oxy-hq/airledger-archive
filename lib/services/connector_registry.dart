import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'postgres_connector.dart';
import 'sheets_repository.dart';
import 'warehouse_connector.dart';

/// Routes a `.view.yml`'s `datasource:` to a concrete [WarehouseConnector].
///
/// Built once at app startup from the parsed `databases:` array of the
/// discovered `config.yml`. If no `config.yml` is present, the registry
/// holds just the bundled `gsheets` fallback so existing sheets-only setups
/// keep working without any config changes.
class ConnectorRegistry {
  final Map<String, WarehouseConnector> _byName;
  final WarehouseConnector? _fallback;

  ConnectorRegistry._({
    required Map<String, WarehouseConnector> byName,
    WarehouseConnector? fallback,
  })  : _byName = byName,
        _fallback = fallback;

  /// Builds a registry by instantiating one connector per [DatabaseConfig].
  /// Live network connections (Postgres / etc.) are opened during build.
  /// `bundledSheets` is wired in as both the `gsheets` entry (if no other
  /// sheets config exists) and the registry's general fallback.
  static Future<ConnectorRegistry> build({
    required List<DatabaseConfig> configs,
    SheetsRepository? bundledSheets,
  }) async {
    final byName = <String, WarehouseConnector>{};
    for (final cfg in configs) {
      byName[cfg.name] = await _instantiate(cfg, bundledSheets);
    }
    if (bundledSheets != null && byName['gsheets'] == null) {
      byName['gsheets'] = bundledSheets;
    }
    return ConnectorRegistry._(byName: byName, fallback: bundledSheets);
  }

  /// Resolves the connector for [view]'s `datasource:`. Falls back to the
  /// bundled connector if no exact match is found, throws if neither
  /// exists.
  WarehouseConnector forView(ViewSchema view) {
    final name = view.datasource;
    final hit = _byName[name];
    if (hit != null) return hit;
    final fb = _fallback;
    if (fb != null) return fb;
    throw StateError(
      'No connector configured for view "${view.name}" '
      '(datasource "$name"). Add an entry to config.yml or use the '
      'bundled gsheets fallback.',
    );
  }

  /// All connectors keyed by their config name — useful for startup
  /// `ensureTable` passes.
  Iterable<WarehouseConnector> get all => _byName.values;

  static Future<WarehouseConnector> _instantiate(
    DatabaseConfig cfg,
    SheetsRepository? bundledSheets,
  ) async {
    return switch (cfg) {
      // Sheets uses the bundled connection — a fresh one would require auth,
      // which the bundled instance already holds.
      SheetsConfig() => bundledSheets ?? UnimplementedConnector(cfg),
      // Postgres family (postgres / redshift / airhouse share the wire
      // protocol). Redshift / Airhouse expose their PostgresConfig via
      // their `.postgres` getters.
      PostgresConfig() => await PostgresConnector.connect(cfg),
      RedshiftConfig() => await PostgresConnector.connect(cfg.postgres),
      AirhouseConfig() => await PostgresConnector.connect(cfg.postgres),
      // Other warehouse types parse cleanly but throw at use time.
      // See docs/oxy-compatibility.md for the implementation plan.
      _ => UnimplementedConnector(cfg),
    };
  }
}
