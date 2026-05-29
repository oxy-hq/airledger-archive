# Sharing `config.yml` across oxy, airlayer, and ledger

**Principle.** Compatibility is maintained through the YAML schema, not
through code dependencies. Each tool parses the same `config.yml` shape —
same `type:` tags, same field names. No tool imports another's Rust/Dart
types.

This document captures the pattern airlayer already uses to stay compatible
with oxy, and prescribes that ledger follow the same pattern as we add
warehouse support beyond Google Sheets.

---

## The pattern, as implemented in airlayer

In `~/repos/airlayer/src/executor/mod.rs` airlayer declares its own
`DatabaseConnection` enum:

```rust
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum DatabaseConnection {
    #[cfg(feature = "exec-postgres")]
    Postgres(PostgresConnection),
    #[cfg(feature = "exec-mysql")]
    Mysql(MySqlConnection),
    #[cfg(feature = "exec-snowflake")]
    Snowflake(SnowflakeConnection),
    #[cfg(feature = "exec-bigquery")]
    Bigquery(BigQueryConnection),
    // ...etc — one variant per warehouse airlayer knows how to execute
}
```

Crucially:

1. **It does not import from oxy.** `airlayer`'s `Cargo.toml` has no
   `oxy = ...` dependency. The enum is independently declared.
2. **It mirrors oxy's serde tags exactly.** `#[serde(tag = "type")]` with
   `rename_all = "lowercase"` (or explicit `#[serde(rename = "...")]` per
   variant) matches oxy's discriminator. A `databases:` entry written for
   oxy parses correctly in airlayer too.
3. **Per-variant struct fields match oxy's fields.** `PostgresConnection`
   has the same `host`, `port`, `dbname`, etc. that oxy's `Postgres` does.
   Where airlayer needs only a subset, it reads only the subset — extra
   oxy-only fields deserialize into `_serde_other` or are ignored via
   `#[serde(default)]`.
4. **Feature-gated implementations.** `exec-postgres`, `exec-snowflake`,
   `exec-bigquery`, etc. let downstream consumers compile only the
   connectors they need. The compatibility schema is decoupled from the
   actual connector code.
5. **The shared artifact is `config.yml`, not a Rust crate.** A customer
   writes one `config.yml`. Oxy reads it for the analyst, airlayer reads
   it for execution, ledger reads it for CRUD. Three independent
   implementations, one contract.

When oxy adds a new warehouse (or a new field on an existing one), the
update propagates to airlayer (and to ledger) through the YAML, not
through a Cargo bump.

---

## Applying the pattern to ledger

Ledger today supports only Google Sheets. To expand to oxy's warehouse
list, the same principle applies: ledger declares a Dart `DatabaseConfig`
discriminated union that mirrors oxy's `DatabaseType`, with the same
discriminator and variant names. Ledger does **not** import oxy or
airlayer at the code level.

### Warehouse list (as of 2026-05-28, from `oxy-internal/crates/core/src/config/model.rs`)

| `type:` value         | Notes |
|-----------------------|-------|
| `bigquery`            | service-account JSON or key path |
| `postgres`            | host/port/user/password/db |
| `redshift`            | postgres-wire-compatible |
| `mysql`               | host/port/user/password/db |
| `snowflake`           | account + auth (key pair / OAuth / password) |
| `clickhouse`          | HTTP interface |
| `duckdb`              | local file or in-memory |
| `motherduck`          | hosted DuckDB |
| `airhouse`            | oxy's postgres-wire on duckdb dialect |
| `airhouse_managed`    | airhouse with oxy-managed credentials |
| `databricks`          | HTTP SQL endpoint |
| `domo`                | HTTP API |

Plus the special case ledger already has:

| `sheets`              | a Google Sheet by spreadsheet id |

`sheets` is not currently in oxy's enum (oxy is read-only / warehouse-side;
Sheets is more of a CRUD substrate). The pattern still applies: ledger
declares it as one variant of the same enum shape, and any tool that
wants to read it can.

### Dart `DatabaseConfig` (proposed shape)

```dart
sealed class DatabaseConfig {
  final String name;
  const DatabaseConfig({required this.name});

  static DatabaseConfig fromYaml(Map<String, dynamic> json) {
    final type = json['type'] as String;
    final name = json['name'] as String;
    return switch (type) {
      'sheets'     => SheetsConfig.fromJson(name, json),
      'bigquery'   => BigQueryConfig.fromJson(name, json),
      'postgres'   => PostgresConfig.fromJson(name, json),
      'snowflake'  => SnowflakeConfig.fromJson(name, json),
      'clickhouse' => ClickHouseConfig.fromJson(name, json),
      // ...etc
      _ => UnsupportedConfig(name: name, type: type, raw: json),
    };
  }
}

class PostgresConfig extends DatabaseConfig { /* host, port, ... */ }
class BigQueryConfig extends DatabaseConfig { /* key_path, project, ... */ }
// ...
class UnsupportedConfig extends DatabaseConfig {
  final String type;
  final Map<String, dynamic> raw;
  // Parses successfully but cannot connect — surfaces a clear "warehouse
  // type X is not supported by this build of ledger" at use time.
}
```

`UnsupportedConfig` is the same trick airlayer uses with feature flags:
the schema parses unconditionally, but only the variants whose connector
is compiled in are usable. This keeps the YAML contract intact even when
a given build can't actually connect.

### Per-view routing

Each `view.yml` already has a `datasource:` field. The contract is:
`datasource:` matches a `name:` in the `databases:` array of the shared
`config.yml`. Ledger looks up the named entry, instantiates the
appropriate `DatabaseConnector`, and runs CRUD through it.

```yaml
# inventory.view.yml
name: inventory
datasource: clickhouse   # → resolves to databases[?(name=clickhouse)]
table: restaurant_analytics___inventory
```

Today, `datasource` is parsed but unused; SheetsRepository is hardcoded.
The first implementation step is making `datasource` actually route.

---

## Repo layout (proposed)

The customer holds one repo per business. Inside, oxy and ledger live as
sibling concerns sharing `config.yml`:

```
~/customer-repos/pokehouse/pokehouse-oxy/
  oxy/
    config.yml          # databases + models — read by oxy + airlayer + ledger
    semantics.yml       # semantic layer (read by oxy + airlayer)
    *.app.yml           # oxy apps (analyst-facing)
    workflows/
  ledger/
    ledger.yaml         # branding (app_name, icon, package_id) — ledger-only
    views/*.view.yml    # CRUD forms (each names a datasource from config.yml)
    templates/*/*.yml   # planned-entry presets
    apps/*.app.yml      # ledger apps (analytics built on the CRUD substrate)
```

`ledger.yaml` adds one optional field to point at the shared config:

```yaml
app_name: "Poke House Inventory"
package_id: com.robertyi.pokehouse
icon: assets/icon.png

# Path to the shared oxy config — relative to ledger.yaml.
# If omitted, ledger walks up from ledger.yaml's directory looking for
# a config.yml (see "Config discovery" below).
oxy_config: ../oxy/config.yml

# Optional: which database from config.yml to use when a view doesn't
# specify `datasource:`. Today's sheets-only views work unchanged
# (datasource defaults to a baked-in sheets connection).
default_database: clickhouse
```

The `brand.dart` CLI grows a small responsibility: when it syncs assets,
it also copies the resolved `config.yml` into `assets/config.yml`, so the
bundled APK has everything it needs at runtime.

### Config discovery (mirrors airlayer)

Airlayer walks up from `cwd` looking for `config.yml`
(`~/repos/airlayer/src/cli/mod.rs:find_project_root`). Explicit `--config`
always wins; otherwise the first ancestor directory containing
`config.yml` is the project root.

Ledger uses the same logic, with one small extension: at each ancestor
level, look for *either* `./config.yml` or `./oxy/config.yml`. That
covers both layouts — config-at-customer-root *and* config-nested-under
`oxy/`, which is the convention in `customer-repos/<customer>-oxy/`.

```
Starting from /<ledger.yaml dir>/, at each level:
  ./config.yml      ?  → if found, that's the project root.
  ./oxy/config.yml  ?  → if found, the *enclosing* dir is the project
                          root, and oxy/ is the data-tier subdir.
  cd ..
```

Explicit `oxy_config:` in `ledger.yaml` (or `--config` on the CLI) always
short-circuits the search. The discovery code lives at
`lib/services/oxy_config_discovery.dart`.

### Why monorepo (oxy/ + ledger/ siblings)

- One git history, one PR review, one source of truth.
- Schema changes that affect both (a new column in a clickhouse table that
  shows up in both an oxy semantic measure and a ledger view) land in one
  commit.
- The shared `config.yml` has only one canonical location.
- `ledger.yaml` becomes a small overlay rather than a full configuration.

The alternative — two repos (`pokehouse-oxy/`, `pokehouse-ledger/`) —
requires either path-traversal references or a publish/consume pattern,
both of which add friction for a single-developer setup.

---

## Implementation phases

This doc captures the principle; here's the order I'd expand ledger
toward full warehouse support, smallest first.

### Phase 1 — parse the contract (no behavior change)

- Add `oxy_config:` to `ledger.yaml`. When present, parse the referenced
  `config.yml`.
- Implement Dart `DatabaseConfig.fromYaml(...)` for the discriminated
  union (mirroring oxy's tags).
- All variants except `sheets` parse into `UnsupportedConfig` for now.
- Existing sheets-only views keep working exactly as today.

### Phase 2 — route by `datasource`

- `SheetsRepository` becomes one implementation of a `DatabaseConnector`
  interface (`list`, `create`, `update`, `delete`, `ensureSheet`).
- A registry maps `DatabaseConfig` variants to connector implementations.
- View loading resolves `datasource:` against `config.yml`. If the
  resolved config is `UnsupportedConfig`, the view surfaces a clear error
  ("clickhouse not supported by this build").

### Phase 3 — first non-sheets warehouse

- Postgres or BigQuery first — both have well-maintained Dart packages.
- Generic SQL CRUD: `INSERT … VALUES (…) RETURNING *`, `UPDATE … WHERE
  id = ?`, `DELETE … WHERE id = ?`, `SELECT * FROM … WHERE date_field
  BETWEEN …`.
- Validates the abstraction. Probably reveals a few shape mismatches
  between sheets-style CRUD and SQL-style CRUD (e.g. sheets has trailing
  empty cell trimming; SQL is exact-arity).

### Phase 4 — long tail via airlayer

- Snowflake, Databricks, Redshift, Domo, MotherDuck, etc. don't have
  great Dart clients. Route their CRUD through airlayer (which already
  has all the connector code as Rust crates).
- Adds a write-side to airlayer's FFI (currently read-only). The shape
  could be a single `execute_dml(config, sql)` that returns affected
  rows. Ledger generates the SQL; airlayer does the connection +
  transport.
- This mirrors how ledger already uses airlayer for analytics — it
  becomes the universal warehouse client and ledger stays Dart.

### Phase 5 — airhouse_managed and OAuth

- `airhouse_managed` (per-user credentials managed by oxy) requires a
  ledger ↔ oxy auth step. Out of scope for the initial pass — ledger
  starts with explicit credentials in `config.yml` or env-var lookups.

---

## What stays out of scope

Things this principle deliberately does *not* prescribe:

- **No oxy-core as a code dep.** Ledger never imports oxy's Rust types,
  even indirectly through airlayer. The contract is YAML.
- **No oxy server in the loop for CRUD.** Ledger talks to the warehouse
  (possibly via airlayer FFI), not to an oxy backend.
- **No schema generation from oxy.** Ledger's `.view.yml` files are
  authored by hand. We do not auto-generate forms from oxy's semantic
  layer. (We may add a tool that *suggests* a view from a semantic
  entity, but the suggestion is materialized as a hand-edited file.)

---

## Open questions

- **Default warehouse for sheets-only existing setups.** When a view has
  no `datasource:`, what's the right fallback — the bundled sheets
  config, the first entry of `config.yml`, or an explicit
  `default_database:` in `ledger.yaml`? Recommend `default_database:`
  in `ledger.yaml`, falling back to sheets when neither is set.
- **Credential storage on mobile.** `config.yml` may contain service
  account JSON or password references via env vars. On a mobile device
  there are no env vars. Options: (a) keep secrets in `config.yml` and
  rely on Android app-private storage; (b) bake secrets in at build time
  via `brand.dart`; (c) prompt the user once at first launch and store
  in Android Keystore. Lean toward (b) for v1 — secrets land in the APK
  alongside the schemas, no runtime prompts.
- **OAuth flows on mobile.** For warehouses that need OAuth (snowflake,
  databricks SSO), this is the same problem the web target hits.
  Probably needs a v2 pass with `flutter_appauth` or similar.

---

## See also

- `~/repos/airlayer/PHILOSOPHY.md` — the parent principle airlayer
  inherited from oxy (semantic layer as contract).
- `~/repos/airlayer/src/executor/mod.rs` — the actual airlayer
  `DatabaseConnection` enum that this doc points to as the reference
  implementation.
- `~/repos/oxy-internal/crates/core/src/config/model.rs` — the canonical
  oxy `DatabaseType` definition.
- This repo's `CLAUDE.md` — the operating guide; links here from the
  "Pointers" section.
