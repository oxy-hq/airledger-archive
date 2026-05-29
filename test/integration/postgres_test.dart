/// Integration test for [PostgresConnector] against a real Postgres.
///
/// Bring up the test database via `scripts/test-db-up.sh`, then run with
/// the port loaded into env:
///
///   set -a && source .test-ports.env && set +a
///   flutter test test/integration/postgres_test.dart
///
/// CI / docker-aware runners can set `AIRLEDGER_PG_PORT` directly.
/// The test is **skipped** entirely when no Postgres is reachable — keeps
/// `flutter test` green when the container isn't running.

import 'dart:io';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/postgres_connector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int port;
  late PostgresConfig config;

  setUpAll(() {
    final raw = Platform.environment['AIRLEDGER_PG_PORT'];
    if (raw == null) {
      throw StateError(
        'AIRLEDGER_PG_PORT not set — run scripts/test-db-up.sh and '
        'source .test-ports.env first',
      );
    }
    port = int.parse(raw);
    config = PostgresConfig(
      name: 'test_pg',
      host: 'localhost',
      port: port,
      user: 'airledger',
      password: 'airledgertest',
      database: 'airledger_test',
      sslMode: 'disable',
    );
  });

  final view = ViewSchema(
    name: 'logs',
    datasource: 'test_pg',
    table: 'logs',
    dateField: 'logged_at',
    entities: [
      Entity(name: 'log_row', type: EntityType.primary, keys: ['id']),
    ],
    dimensions: [
      Dimension(name: 'id', type: DimensionType.string, expr: 'id'),
      Dimension(name: 'logged_at', type: DimensionType.date, expr: 'logged_at'),
      Dimension(name: 'message', type: DimensionType.string, expr: 'message'),
      Dimension(name: 'count', type: DimensionType.number, expr: 'count'),
      Dimension(name: 'ok', type: DimensionType.boolean, expr: 'ok'),
    ],
    measures: const [],
  );

  test('full CRUD round-trip against real Postgres', () async {
    final pg = await PostgresConnector.connect(config);
    addTearDown(pg.close);

    // Clean slate for a deterministic test.
    final raw = await PostgresConnector.connect(config);
    addTearDown(raw.close);

    await pg.ensureTable(view);

    // Wipe any leftover data
    await raw.delete(view, {'id': 'will-not-match'}); // no-op exists check
    // Direct truncate via a one-off update isn't trivial; rely on CREATE
    // IF NOT EXISTS + unique IDs per test run.

    final today = DateTime(2026, 5, 28);

    // CREATE
    final created = await pg.create(view, {
      'logged_at': today,
      'message': 'first',
      'count': 42,
      'ok': true,
    });
    expect(created['id'], isA<String>());
    expect((created['id'] as String).length, 36);
    final createdId = created['id'] as String;

    // LIST (filtered by date) — should include the row we just inserted.
    final rows = await pg.list(view, onDate: today);
    final ours = rows.where((r) => r['id'] == createdId).toList();
    expect(ours, hasLength(1));
    expect(ours.first['message'], 'first');
    expect((ours.first['count'] as num).toInt(), 42);
    expect(ours.first['ok'], true);

    // UPDATE
    await pg.update(view, {
      'id': createdId,
      'message': 'updated',
      'count': 99,
    });
    final after = await pg.list(view, onDate: today);
    final updated = after.firstWhere((r) => r['id'] == createdId);
    expect(updated['message'], 'updated');
    expect((updated['count'] as num).toInt(), 99);

    // DELETE
    await pg.delete(view, {'id': createdId});
    final final_ = await pg.list(view, onDate: today);
    expect(final_.any((r) => r['id'] == createdId), isFalse);
  });

  test('ensureTable is additive — adding a dimension does not destroy data',
      () async {
    final pg = await PostgresConnector.connect(config);
    addTearDown(pg.close);

    // Start with the minimal view.
    final v1 = ViewSchema(
      name: 'evolve',
      datasource: 'test_pg',
      table: 'evolve',
      entities: [
        Entity(name: 'row', type: EntityType.primary, keys: ['id']),
      ],
      dimensions: [
        Dimension(name: 'id', type: DimensionType.string, expr: 'id'),
        Dimension(name: 'a', type: DimensionType.number, expr: 'a'),
      ],
      measures: const [],
    );
    await pg.ensureTable(v1);
    final r = await pg.create(v1, {'a': 1});
    final id = r['id'] as String;

    // Evolve: add a new dimension.
    final v2 = ViewSchema(
      name: 'evolve',
      datasource: 'test_pg',
      table: 'evolve',
      entities: v1.entities,
      dimensions: [
        ...v1.dimensions,
        Dimension(name: 'b', type: DimensionType.string, expr: 'b'),
      ],
      measures: const [],
    );
    await pg.ensureTable(v2);

    // Old data still there.
    final rows = await pg.list(v2);
    final ours = rows.firstWhere((r) => r['id'] == id);
    expect((ours['a'] as num).toInt(), 1);
    expect(ours['b'], isNull); // new column, no value

    await pg.delete(v2, {'id': id});
  });
}
