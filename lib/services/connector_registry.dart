import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'bigquery_connector.dart';
import 'clickhouse_connector.dart';
import 'mysql_connector.dart';
import 'postgres_connector.dart';
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
  /// Live network connections (Postgres / MySQL / ClickHouse / BigQuery)
  /// are opened during build.
  ///
  /// [serviceAccountKeyJson] is required for BigQuery configs (and any
  /// other Google-auth-backed connector). When omitted, BigQuery configs
  /// fall through to [UnimplementedConnector].
  static Future<ConnectorRegistry> build({
    required List<DatabaseConfig> configs,
    WarehouseConnector? bundledSheets,
    String? serviceAccountKeyJson,
  }) async {
    final byName = <String, WarehouseConnector>{};
    for (final cfg in configs) {
      byName[cfg.name] = await _instantiate(
        cfg,
        bundledSheets: bundledSheets,
        serviceAccountKeyJson: serviceAccountKeyJson,
      );
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
    DatabaseConfig cfg, {
    WarehouseConnector? bundledSheets,
    String? serviceAccountKeyJson,
  }) async {
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
      MysqlConfig() => await MysqlConnector.connect(cfg),
      ClickhouseConfig() => await ClickhouseConnector.connect(cfg),
      BigQueryConfig() => serviceAccountKeyJson != null
          ? await BigQueryConnector.connect(
              cfg,
              serviceAccountKeyJson: serviceAccountKeyJson,
            )
          : UnimplementedConnector(cfg),
      // Other warehouse types parse cleanly but throw at use time.
      // See docs/oxy-compatibility.md for the implementation plan.
      _ => UnimplementedConnector(cfg),
    };
  }
}
