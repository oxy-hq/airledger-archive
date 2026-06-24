/// Discriminated-union mirror of oxy's `DatabaseType` enum (see
/// `oxy-internal/crates/core/src/config/model.rs`). Each variant parses
/// the same YAML shape oxy and airlayer parse — same `type:` tag, same
/// per-variant field names.
///
/// This is the **YAML contract** half of the oxy-compatibility principle
/// (see `docs/oxy-compatibility.md`). Ledger does NOT import oxy or
/// airlayer code; it independently declares a parallel set of structs.
/// Adding a new warehouse to oxy propagates to ledger via a YAML field
/// addition, not a Cargo / pub bump.
///
/// Each variant carries the fields needed to construct a connection.
/// Whether a given variant has a concrete connector implementation is a
/// separate concern (see `services/warehouse_connector.dart` and the
/// connector registry).
library;

sealed class DatabaseConfig {
  /// Unique name of this datasource (matches the `datasource:` field on a
  /// `.view.yml`).
  final String name;

  const DatabaseConfig({required this.name});

  /// The lowercase `type:` discriminator from `config.yml`.
  String get typeName;

  /// Parses one `databases:` entry from `config.yml`.
  static DatabaseConfig fromYaml(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String) {
      throw const FormatException('databases entry missing `name:`');
    }
    final type = json['type'];
    if (type is! String) {
      throw FormatException('databases entry "$name" missing `type:`');
    }
    return switch (type) {
      'sheets' => SheetsConfig.fromJson(name, json),
      'sqlite_ledger' => SqliteLedgerConfig.fromJson(name, json),
      'bigquery' => BigQueryConfig.fromJson(name, json),
      'duckdb' => DuckDBConfig.fromJson(name, json),
      'snowflake' => SnowflakeConfig.fromJson(name, json),
      'postgres' => PostgresConfig.fromJson(name, json),
      'airhouse' => AirhouseConfig.fromJson(name, json),
      'airhouse_managed' => AirhouseManagedConfig.fromJson(name, json),
      'redshift' => RedshiftConfig.fromJson(name, json),
      'mysql' => MysqlConfig.fromJson(name, json),
      'clickhouse' => ClickhouseConfig.fromJson(name, json),
      'domo' => DomoConfig.fromJson(name, json),
      'motherduck' => MotherduckConfig.fromJson(name, json),
      'databricks' => DatabricksConfig.fromJson(name, json),
      _ => UnknownConfig(name: name, typeName: type, raw: json),
    };
  }
}

/// Google Sheets — ledger's native CRUD substrate. Not in oxy's enum
/// (oxy is warehouse-side, sheets is more of a transactional store);
/// declared here so config.yml can list it alongside warehouses.
class SheetsConfig extends DatabaseConfig {
  final String? spreadsheetId;
  final String? spreadsheetIdVar; // env-var name; resolved at sync time
  final String? serviceAccountKeyPath;

  const SheetsConfig({
    required super.name,
    this.spreadsheetId,
    this.spreadsheetIdVar,
    this.serviceAccountKeyPath,
  });

  @override
  String get typeName => 'sheets';

  factory SheetsConfig.fromJson(String name, Map<String, dynamic> j) =>
      SheetsConfig(
        name: name,
        spreadsheetId: j['spreadsheet_id'] as String?,
        spreadsheetIdVar: j['spreadsheet_id_var'] as String?,
        serviceAccountKeyPath: j['service_account_key_path'] as String?,
      );
}

/// On-device SQLite ledger — airledger's local durable store, the
/// pluggable alternative to Sheets. No connection fields: the connector
/// owns a single `ledger.db` in the app documents dir. Not in oxy's enum
/// (it's a transactional store, like sheets).
class SqliteLedgerConfig extends DatabaseConfig {
  const SqliteLedgerConfig({required super.name});

  @override
  String get typeName => 'sqlite_ledger';

  factory SqliteLedgerConfig.fromJson(String name, Map<String, dynamic> _) =>
      SqliteLedgerConfig(name: name);
}

class PostgresConfig extends DatabaseConfig {
  final String? host;
  final String? hostVar;
  final int? port;
  final String? user;
  final String? userVar;
  final String? password;
  final String? passwordVar;
  final String? database;
  final String? databaseVar;
  final String? sslMode;

  const PostgresConfig({
    required super.name,
    this.host,
    this.hostVar,
    this.port,
    this.user,
    this.userVar,
    this.password,
    this.passwordVar,
    this.database,
    this.databaseVar,
    this.sslMode,
  });

  @override
  String get typeName => 'postgres';

  factory PostgresConfig.fromJson(String name, Map<String, dynamic> j) =>
      PostgresConfig(
        name: name,
        host: j['host'] as String?,
        hostVar: j['host_var'] as String?,
        port: (j['port'] as num?)?.toInt(),
        user: j['user'] as String?,
        userVar: j['user_var'] as String?,
        password: j['password'] as String?,
        passwordVar: j['password_var'] as String?,
        database: j['database'] as String?,
        databaseVar: j['database_var'] as String?,
        sslMode: j['ssl_mode'] as String?,
      );
}

class RedshiftConfig extends DatabaseConfig {
  final PostgresConfig _pg;
  const RedshiftConfig._(this._pg) : super(name: '');
  // Redshift is postgres-wire compatible; reuse Postgres fields verbatim.
  factory RedshiftConfig.fromJson(String name, Map<String, dynamic> j) =>
      RedshiftConfig._(PostgresConfig.fromJson(name, j));
  PostgresConfig get postgres => PostgresConfig(
        name: _pg.name,
        host: _pg.host,
        hostVar: _pg.hostVar,
        port: _pg.port,
        user: _pg.user,
        userVar: _pg.userVar,
        password: _pg.password,
        passwordVar: _pg.passwordVar,
        database: _pg.database,
        databaseVar: _pg.databaseVar,
        sslMode: _pg.sslMode,
      );
  @override
  String get name => _pg.name;
  @override
  String get typeName => 'redshift';
}

class AirhouseConfig extends DatabaseConfig {
  // Airhouse speaks the postgres wire protocol with DuckDB SQL dialect.
  // Connection fields mirror Postgres exactly.
  final PostgresConfig _pg;
  const AirhouseConfig._(this._pg) : super(name: '');
  factory AirhouseConfig.fromJson(String name, Map<String, dynamic> j) =>
      AirhouseConfig._(PostgresConfig.fromJson(name, j));
  PostgresConfig get postgres => _pg;
  @override
  String get name => _pg.name;
  @override
  String get typeName => 'airhouse';
}

class AirhouseManagedConfig extends DatabaseConfig {
  // No fields — connection details come from oxy's per-user provisioning
  // (airhouse_users + org_secrets rows). Resolved at runtime through an
  // oxy auth dance not yet implemented in ledger.
  const AirhouseManagedConfig({required super.name});
  factory AirhouseManagedConfig.fromJson(String name, Map<String, dynamic> _) =>
      AirhouseManagedConfig(name: name);
  @override
  String get typeName => 'airhouse_managed';
}

class BigQueryConfig extends DatabaseConfig {
  final String? project;
  final String? dataset;
  final String? keyPath;
  final String? keyPathVar;

  const BigQueryConfig({
    required super.name,
    this.project,
    this.dataset,
    this.keyPath,
    this.keyPathVar,
  });

  @override
  String get typeName => 'bigquery';

  factory BigQueryConfig.fromJson(String name, Map<String, dynamic> j) =>
      BigQueryConfig(
        name: name,
        project: j['project'] as String?,
        dataset: j['dataset'] as String?,
        keyPath: j['key_path'] as String?,
        keyPathVar: j['key_path_var'] as String?,
      );
}

class SnowflakeConfig extends DatabaseConfig {
  final String? account;
  final String? user;
  final String? userVar;
  final String? password;
  final String? passwordVar;
  final String? privateKeyPath;
  final String? privateKeyPathVar;
  final String? warehouse;
  final String? database;
  final String? schema;
  final String? role;

  const SnowflakeConfig({
    required super.name,
    this.account,
    this.user,
    this.userVar,
    this.password,
    this.passwordVar,
    this.privateKeyPath,
    this.privateKeyPathVar,
    this.warehouse,
    this.database,
    this.schema,
    this.role,
  });

  @override
  String get typeName => 'snowflake';

  factory SnowflakeConfig.fromJson(String name, Map<String, dynamic> j) =>
      SnowflakeConfig(
        name: name,
        account: j['account'] as String?,
        user: j['user'] as String?,
        userVar: j['user_var'] as String?,
        password: j['password'] as String?,
        passwordVar: j['password_var'] as String?,
        privateKeyPath: j['private_key_path'] as String?,
        privateKeyPathVar: j['private_key_path_var'] as String?,
        warehouse: j['warehouse'] as String?,
        database: j['database'] as String?,
        schema: j['schema'] as String?,
        role: j['role'] as String?,
      );
}

class ClickhouseConfig extends DatabaseConfig {
  final String? host;
  final String? hostVar;
  final int? port;
  final String? user;
  final String? userVar;
  final String? password;
  final String? passwordVar;
  final String? database;
  final String? databaseVar;
  final Map<String, dynamic>? schemas;

  const ClickhouseConfig({
    required super.name,
    this.host,
    this.hostVar,
    this.port,
    this.user,
    this.userVar,
    this.password,
    this.passwordVar,
    this.database,
    this.databaseVar,
    this.schemas,
  });

  @override
  String get typeName => 'clickhouse';

  factory ClickhouseConfig.fromJson(String name, Map<String, dynamic> j) =>
      ClickhouseConfig(
        name: name,
        host: j['host'] as String?,
        hostVar: j['host_var'] as String?,
        port: (j['port'] as num?)?.toInt(),
        user: j['user'] as String?,
        userVar: j['user_var'] as String?,
        password: j['password'] as String?,
        passwordVar: j['password_var'] as String?,
        database: j['database'] as String?,
        databaseVar: j['database_var'] as String?,
        schemas: (j['schemas'] as Map?)?.cast<String, dynamic>(),
      );
}

class MysqlConfig extends DatabaseConfig {
  final String? host;
  final String? hostVar;
  final int? port;
  final String? user;
  final String? userVar;
  final String? password;
  final String? passwordVar;
  final String? database;
  final String? databaseVar;

  const MysqlConfig({
    required super.name,
    this.host,
    this.hostVar,
    this.port,
    this.user,
    this.userVar,
    this.password,
    this.passwordVar,
    this.database,
    this.databaseVar,
  });

  @override
  String get typeName => 'mysql';

  factory MysqlConfig.fromJson(String name, Map<String, dynamic> j) =>
      MysqlConfig(
        name: name,
        host: j['host'] as String?,
        hostVar: j['host_var'] as String?,
        port: (j['port'] as num?)?.toInt(),
        user: j['user'] as String?,
        userVar: j['user_var'] as String?,
        password: j['password'] as String?,
        passwordVar: j['password_var'] as String?,
        database: j['database'] as String?,
        databaseVar: j['database_var'] as String?,
      );
}

class DuckDBConfig extends DatabaseConfig {
  final String? path;
  final String? pathVar;

  const DuckDBConfig({required super.name, this.path, this.pathVar});

  @override
  String get typeName => 'duckdb';

  factory DuckDBConfig.fromJson(String name, Map<String, dynamic> j) =>
      DuckDBConfig(
        name: name,
        path: j['path'] as String?,
        pathVar: j['path_var'] as String?,
      );
}

class MotherduckConfig extends DatabaseConfig {
  final String? token;
  final String? tokenVar;
  final String? database;

  const MotherduckConfig({
    required super.name,
    this.token,
    this.tokenVar,
    this.database,
  });

  @override
  String get typeName => 'motherduck';

  factory MotherduckConfig.fromJson(String name, Map<String, dynamic> j) =>
      MotherduckConfig(
        name: name,
        token: j['token'] as String?,
        tokenVar: j['token_var'] as String?,
        database: j['database'] as String?,
      );
}

class DatabricksConfig extends DatabaseConfig {
  final String? host;
  final String? hostVar;
  final String? httpPath;
  final String? token;
  final String? tokenVar;
  final String? catalog;
  final String? schema;

  const DatabricksConfig({
    required super.name,
    this.host,
    this.hostVar,
    this.httpPath,
    this.token,
    this.tokenVar,
    this.catalog,
    this.schema,
  });

  @override
  String get typeName => 'databricks';

  factory DatabricksConfig.fromJson(String name, Map<String, dynamic> j) =>
      DatabricksConfig(
        name: name,
        host: j['host'] as String?,
        hostVar: j['host_var'] as String?,
        httpPath: j['http_path'] as String?,
        token: j['token'] as String?,
        tokenVar: j['token_var'] as String?,
        catalog: j['catalog'] as String?,
        schema: j['schema'] as String?,
      );
}

class DomoConfig extends DatabaseConfig {
  final String? clientId;
  final String? clientIdVar;
  final String? secret;
  final String? secretVar;

  const DomoConfig({
    required super.name,
    this.clientId,
    this.clientIdVar,
    this.secret,
    this.secretVar,
  });

  @override
  String get typeName => 'domo';

  factory DomoConfig.fromJson(String name, Map<String, dynamic> j) =>
      DomoConfig(
        name: name,
        clientId: j['client_id'] as String?,
        clientIdVar: j['client_id_var'] as String?,
        secret: j['secret'] as String?,
        secretVar: j['secret_var'] as String?,
      );
}

/// Catch-all for `type:` values we don't know about. Parses cleanly so the
/// app can keep loading other views; throws at use time when a view tries
/// to route to this datasource.
class UnknownConfig extends DatabaseConfig {
  final String unknownType;
  final Map<String, dynamic> raw;

  const UnknownConfig({
    required super.name,
    required String typeName,
    required this.raw,
  }) : unknownType = typeName;

  @override
  String get typeName => unknownType;
}

/// Parses the `databases:` array of a `config.yml`. Tolerates entries with
/// unknown types (they become `UnknownConfig`); fails only on entries
/// missing the `name:` or `type:` discriminators.
List<DatabaseConfig> parseDatabasesList(List<dynamic> raw) {
  return raw
      .map((e) => DatabaseConfig.fromYaml((e as Map).cast<String, dynamic>()))
      .toList();
}
