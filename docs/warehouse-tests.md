# Warehouse integration tests

The Postgres connector ships with an integration test that exercises full
CRUD against a real database. The pattern mirrors
`~/repos/airlayer/scripts/test-db-up.sh` and
`~/repos/airlayer/docker-compose.test.yml`.

## Running

```sh
# 1. Make sure Docker Desktop (or Colima) is running.
# 2. Bring up the test Postgres container — auto-picks a free port.
./scripts/test-db-up.sh

# 3. Source the port the script chose, then run the test.
set -a && source .test-ports.env && set +a
flutter test test/integration/postgres_test.dart

# 4. Stop the container when done.
docker compose -f docker-compose.test.yml down
```

## What's tested

- `ensureTable` creates the destination table if missing, then is
  **additive** on subsequent calls — adding a new dimension causes an
  `ALTER TABLE ADD COLUMN IF NOT EXISTS` without disturbing existing data.
- `create` auto-assigns a UUID `id` and returns the inserted record.
- `list(view, onDate: today)` filters by the configured `date_field`.
- `update` patches columns by `id`.
- `delete` removes by `id`.

## Adding more warehouses

Mirror the airlayer pattern: add a service to `docker-compose.test.yml`,
update `scripts/test-db-up.sh` to find a free port for it, and write
a `test/integration/<warehouse>_test.dart` that uses the same connector
contract. The `WarehouseConnector` interface is the single seam — every
backend implements it identically.

For warehouses without docker images (BigQuery, Snowflake), follow
airlayer's `.env.example` pattern: real credentials in `.env`
(gitignored), `.env.example` documents the required keys, the test
suite skips when the env vars are absent.

## CI

Not wired up yet. A reasonable layout when we add CI:

```yaml
# .github/workflows/test.yml
jobs:
  postgres:
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: airledger_test
          POSTGRES_USER: airledger
          POSTGRES_PASSWORD: airledgertest
        ports:
          - 5432:5432
    steps:
      - run: flutter test test/integration/postgres_test.dart
        env:
          AIRLEDGER_PG_PORT: 5432
```
