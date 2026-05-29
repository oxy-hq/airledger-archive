#!/usr/bin/env bash
# Start the local Postgres for integration tests. Auto-picks a free port
# if the default is occupied, writes it to .test-ports.env.
set -euo pipefail
cd "$(dirname "$0")/.."

find_free_port() {
  local port=$1
  while lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
    echo "  Port $port occupied, trying $((port + 1))..." >&2
    port=$((port + 1))
  done
  echo "$port"
}

PG_PORT=$(find_free_port "${AIRLEDGER_PG_PORT:-15433}")
cat > .test-ports.env <<EOF
AIRLEDGER_PG_PORT=$PG_PORT
EOF
echo "Postgres port: $PG_PORT"
export AIRLEDGER_PG_PORT=$PG_PORT
docker compose -f docker-compose.test.yml up -d "$@"
echo ""
echo "Wait a moment, then run tests:"
echo "  set -a && source .test-ports.env && set +a"
echo "  flutter test test/integration/postgres_test.dart"
