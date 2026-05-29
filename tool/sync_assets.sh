#!/usr/bin/env bash
# Copies external sources (schemas repo, service-account key, config) into the
# Flutter assets/ directory so the app can load them at runtime on every
# platform (Android, iOS, macOS, web).
#
# Run this before `flutter run` whenever schemas change.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMAS_SRC="${SCHEMAS_SRC:-$HOME/repos/ledger-schemas/views}"
TEMPLATES_SRC="${TEMPLATES_SRC:-$HOME/repos/ledger-schemas/templates}"
APPS_SRC="${APPS_SRC:-$HOME/repos/ledger-schemas/apps}"
SA_KEY_SRC="${SA_KEY_SRC:-$HOME/.config/ledger/service-account.json}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/.config/ledger/config.yaml}"

mkdir -p assets/schemas assets/templates assets/apps

# Schemas: clear and recopy so deletions in the source propagate. Copies
# all paired files (.view.yml, .input.yml, .template.yml) into one flat
# assets/schemas/ dir — basename pairing keeps them associated.
rm -f assets/schemas/*.yml
shopt -s nullglob 2>/dev/null || true
for ext in view.yml input.yml template.yml; do
  files=("$SCHEMAS_SRC"/*."$ext")
  if [ ${#files[@]} -gt 0 ] && [ -e "${files[0]}" ]; then
    cp "$SCHEMAS_SRC"/*."$ext" assets/schemas/ 2>/dev/null || true
  fi
done
echo "synced $(ls assets/schemas/*.view.yml 2>/dev/null | wc -l | tr -d ' ') view(s)"\
  " + $(ls assets/schemas/*.input.yml 2>/dev/null | wc -l | tr -d ' ') input overlay(s)"\
  " + $(ls assets/schemas/*.template.yml 2>/dev/null | wc -l | tr -d ' ') template(s) from $SCHEMAS_SRC"

# Legacy templates/ dir is no longer used — clear any stale artifacts so
# they don't leak into the bundle. Templates now live alongside views,
# paired by basename: views/<view>.<name>.template.yml.
rm -rf assets/templates

# Apps: mirror apps/*.app.yml
rm -rf assets/apps
mkdir -p assets/apps
if [ -d "$APPS_SRC" ]; then
  cp -R "$APPS_SRC"/. assets/apps/
  echo "synced $(find assets/apps -name '*.app.yml' | wc -l | tr -d ' ') app(s) from $APPS_SRC"
else
  echo "no apps dir at $APPS_SRC (skipping)"
fi

# Service account key
cp "$SA_KEY_SRC" assets/service-account.json
echo "synced service-account.json"

# Config: extract just the bits the app needs at runtime (spreadsheet_id).
# The other config keys (paths) are now baked into asset paths.
SPREADSHEET_ID=$(grep -E '^spreadsheet_id:' "$CONFIG_SRC" | sed 's/spreadsheet_id:[[:space:]]*//')
cat > assets/config.yaml <<EOF
spreadsheet_id: $SPREADSHEET_ID
EOF
echo "synced config.yaml (spreadsheet_id=$SPREADSHEET_ID)"
