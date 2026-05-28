# ledger

Schema-driven mobile CRUD app. You declare a tracker as YAML (in the sibling
[ledger-schemas](../ledger-schemas) repo) and the app generates the entry
form, the timeline, and persists rows to Google Sheets — no per-tracker code.

## What's in the box

- **Auto-generated entry forms** from `view.yml` (text / number / date /
  datetime / dropdown / autocomplete / longtext widgets, plus a `now_button`
  helper for time fields)
- **Date-filtered timeline** with swipe-to-delete and Dismissible affordance
- **Polymorphic records** via `show_when:` — one tab can hold treadmill +
  stairmaster sets, form shows only relevant fields per row's type
- **Plan-then-log workflow**: templates create local-only "planned" entries;
  a single tap stamps the time and commits the row to the sheet
- **Jinja-templated workout presets** with cached per-template variables
  (e.g. set your squat working weight once; it pre-fills next time)
- **Per-dimension `derive:`** for computed columns (e.g. `day_of_week` from
  `date`)
- **Multi-sheet support**: per-view `spreadsheet_id` override

## Architecture in one minute

```
~/repos/ledger-schemas/         <- source of truth (YAML, plus templates/)
            |
            | tool/sync_assets.sh
            v
~/repos/ledger/assets/          <- copied here, then bundled into the APK
            |
            | flutter build apk
            v
On-device: AssetManifest reads YAMLs at runtime; SheetsRepository
talks to the Sheets API via service-account auth.
```

There is no on-device filesystem store of schemas — they're baked into the
APK. Plan to add a remote-fetch path (GitHub raw URL with local cache) so
schema edits don't require a rebuild.

## Setup

One-time, on a new machine:

1. Install Flutter 3.44+ and the Android SDK.
2. Place a Google Cloud service-account key at
   `~/.config/ledger/service-account.json`. The SA needs `Editor` access on
   the destination workbook.
3. Create `~/.config/ledger/config.yaml`:
   ```yaml
   schemas_dir: /path/to/ledger-schemas/views
   service_account_key_path: /Users/<you>/.config/ledger/service-account.json
   spreadsheet_id: <your default spreadsheet id>
   ```
4. Clone [ledger-schemas](../ledger-schemas) as a sibling repo.
5. `./tool/sync_assets.sh` — copies YAMLs + key + config into `assets/`.
6. `flutter pub get && flutter build apk --release`.
7. `adb install -r build/app/outputs/flutter-apk/app-release.apk`.

## Iterating

Schema change loop (most common):
```sh
# edit a .view.yml or template
./tool/sync_assets.sh
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell monkey -p com.robertyi.ledger -c android.intent.category.LAUNCHER 1
```

Code change loop is the same — `build apk --release` is fine for personal use
even during dev (Hot reload via `flutter run` works too if you prefer).

## Helper tools

In `tool/`:

- `sync_assets.sh` — copies schemas, templates, service-account key, and config
  into `assets/` so they're bundled into the APK
- `sheets_check.dart` — end-to-end smoke test (ensure-tab → create probe →
  list → delete)
- `check_schema.dart <path>` — parse a `.view.yml` and print what the parser
  saw (dimensions, plannable, samples count, etc.) — handy for catching YAML
  typos
- `list_tabs.dart <spreadsheet_id>` — list tab names + gids
- `dump_sheet.dart <id> <tab> [last_n]` — dump rows from a sheet
- `dump_exercises.dart <id> <tab> <column>` — distinct values in a column,
  sorted by frequency
- `consolidate_exercises.dart` — group exercise variants by word-set,
  produce a canonical-name list and a merge map
- `migrate_strength.dart --confirm` — destructive: rebuild ledger strength
  tab from the legacy fitness-logger Strength Tracker
- `migrate_cardio.dart --confirm` — destructive: rebuild ledger cardio tab
  from the legacy 4x4 sheet (infers `type`, cleans "never reached")
- `fix_cell_types.dart <id> <view> [--confirm]` — coerces stringy numbers /
  booleans in a tab to their native cell types (clears the leading-quote
  display in Sheets). Dry-runs by default.
- `reorder_sheet.dart <id> <tab> [--confirm]` — sorts rows by date desc /
  time asc. Run on demand; the app's insert path stays append-only.
- `rebuild_headers.dart <id> <view> [--confirm]` — recovery: rewrites the
  header row from the schema and re-aligns data underneath. Use after a
  `values.append` overwrites the header (see CLAUDE.md gotcha #9).

## Where things live

```
lib/
  main.dart                 LedgerApp + theme (hint-text styling)
  models/
    view_schema.dart        ViewSchema, Dimension, InputSpec, Plannable, ...
    template.dart           Template + TemplateVariable
    planned_entry.dart      Local plan row (pre-log)
  services/
    schema_parser.dart      Pure-Dart YAML -> ViewSchema
    schema_loader.dart      Flutter-side asset loading
    sheets_repository.dart  CRUD over Google Sheets (ensure tab, create,
                            list, update, delete; per-view spreadsheet)
    cell_codec.dart         Typed Dart <-> string for sheet cells
    derive.dart             Runs `derive:` specs (weekday, iso_date, ...)
    log_now.dart            Stamps current time per LogFormat
    template_loader.dart    YAML -> Template
    template_interpolator.dart  Jinja2 render + dimension-typed coercion
    template_vars_cache.dart    shared_preferences-backed last-used values
    plan_store.dart         shared_preferences-backed local PlannedEntry CRUD
  ui/
    home_screen.dart        Lists views from the schema bundle
    timeline_screen.dart    Merged timeline (logged + planned)
    form_screen.dart        Auto-generated form (also Plan mode)
    templates_screen.dart   Pick a template -> vars dialog -> add to plan
    template_vars_dialog.dart   Per-template input prompt
    widgets/field_widgets.dart  buildFieldWidget dispatch
assets/                     auto-populated by tool/sync_assets.sh
tool/                       Dart + bash scripts (see above)
```

See [CLAUDE.md](./CLAUDE.md) for deeper architectural notes and gotchas.
