# CLAUDE.md

Operating guide for Claude (or any new contributor) working on the ledger app.
Read this end-to-end before making non-trivial changes.

## What this app is

Schema-driven mobile CRUD over Google Sheets. The user declares trackers in
YAML (`~/repos/ledger-schemas/views/*.view.yml`) and this Flutter app
generates the entry form, timeline, and persists rows to the Sheets API.

The deliberate design constraints:

- **Android-only target.** iOS was deprioritized because the user runs a Pixel
  10 Pro. Don't add iOS-specific code or assume a Mac/Xcode toolchain.
- **No backend.** The app talks to Sheets directly via a service-account
  key bundled into the APK. Avoid suggesting "stand up a server" reflexively.
- **YAML in a sibling repo.** Schemas live in `~/repos/ledger-schemas`, not in
  this repo. They get copied into `assets/` at build time.
- **Build-time bundling.** No hot-update path today. Schema edits require
  `./tool/sync_assets.sh && flutter build apk && adb install`.
- **Sheets is the system of record.** Don't introduce local caches as truth.
  The one exception: `PlanStore` holds *pre-log* planned entries that
  haven't been committed yet.

## Repo layout (three places to know)

```
~/repos/ledger/             this Flutter app (you are here)
~/repos/ledger-schemas/     YAML view definitions + templates
~/.config/ledger/           service-account.json + config.yaml
```

The `tool/sync_assets.sh` script reads from all three and writes to
`assets/`. The Flutter build then bundles `assets/` into the APK.

## Build + deploy loop

The preferred entrypoint is the `brand` CLI — it reads a config from the
schemas repo, patches the launcher label + icon, syncs assets, builds, and
installs in one shot:

```sh
dart run ~/repos/ledger/tool/brand.dart
# or with a custom config:
dart run ~/repos/ledger/tool/brand.dart --config /path/to/ledger.yaml
```

`ledger.yaml` (default `~/repos/ledger-schemas/ledger.yaml`) supports:

```yaml
app_name: "Fitness Logger"           # required-ish; defaults to "Ledger"
icon: assets/icon.png                # path relative to the yaml
adb_device: 57041FDCH002VN           # optional default device serial
package_id: com.robertyi.ledger      # optional, normally don't change
skip_icons: false                    # set true to skip icon regen
```

If no config exists at the default path, the CLI builds and installs the
generic "Ledger" branding. The Android manifest references
`@string/app_name`, so the launcher label is replaced by writing
`android/app/src/main/res/values/strings.xml` before each build.

Plain manual loop (without branding) if you just want to iterate on code:

```sh
./tool/sync_assets.sh                                       # if schemas changed
flutter build apk --release                                 # ~20s cached
adb -s 57041FDCH002VN install -r build/app/outputs/flutter-apk/app-release.apk
adb -s 57041FDCH002VN shell monkey -p com.robertyi.ledger \
    -c android.intent.category.LAUNCHER 1                   # launch
```

Notes:

- `--release` is fine even during development (AOT-compiled, signed with the
  local debug keystore — runs standalone, no debugger needed).
- The serial `57041FDCH002VN` is the user's Pixel 10 Pro. `flutter devices`
  to verify.
- Package id is `com.robertyi.ledger`. Not `com.example.ledger`.
- `flutter analyze` before building is cheap (~3s) and catches most errors.
  The `info`-level lints (doc comments, etc.) are fine to ignore.

For inspecting state on device:

```sh
adb -s 57041FDCH002VN logcat -c                             # clear
# (do the action)
adb -s 57041FDCH002VN logcat -d --pid=$(adb shell pidof com.robertyi.ledger)
```

Flutter `debugPrint(...)` shows up under the `flutter` tag in logcat. Don't
leave `debugPrint`s in committed code — release builds skip them but they're
visual noise.

## Asset pipeline

`tool/sync_assets.sh` reads:

| From                                                 | To                                  |
|------------------------------------------------------|-------------------------------------|
| `~/repos/ledger-schemas/views/*.view.yml`            | `assets/schemas/`                   |
| `~/repos/ledger-schemas/templates/<view>/*.yml`      | `assets/templates/<view>/`          |
| `~/.config/ledger/service-account.json`              | `assets/service-account.json`       |
| `~/.config/ledger/config.yaml` (spreadsheet_id only) | `assets/config.yaml`                |

`pubspec.yaml` declares the assets — keep its `flutter.assets:` block in
sync when adding new asset directories.

On device, `SchemaLoader` and `TemplateLoader` read via
`AssetManifest.loadFromAssetBundle(rootBundle)` + `rootBundle.loadString()`.
**There is no `dart:io` filesystem access** on Android for asset reads —
don't try to use `File()` on `assets/...` paths.

## Service account + spreadsheet

Auth is `googleapis_auth.clientViaServiceAccount(...)` with
`SheetsApi.spreadsheetsScope`. The SA is `fitness-logger@ryi-data-entry.iam`
(reused from the predecessor project). Default spreadsheet:
`1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4`.

Each view picks a spreadsheet via:
- `view.spreadsheetId` override if present
- otherwise the default from `assets/config.yaml`

The SA must have `Editor` access to whatever spreadsheet a view points at.

## Schema features

See [`../ledger-schemas/README.md`](../ledger-schemas/README.md) for the full
schema reference. Quick map of where each feature is implemented:

| Schema field            | Model                            | Behavior                                           |
|-------------------------|----------------------------------|----------------------------------------------------|
| `input.widget`          | `field_widgets.dart`             | dispatches to widget class per `WidgetType`        |
| `input.default: today`  | `field_widgets.resolveDefault`   | runs at form create                                |
| `input.now_button: true`| `_TextFieldWidget`               | suffix clock icon stamps current time              |
| `input.editable: false` | `view.editableDimensions`        | filtered out of the form                           |
| `derive:`               | `derive.applyDerives`            | runs at save (after form, before repo)             |
| `samples: [...]`        | autocomplete + dropdown options  | static suggestions                                 |
| `show_when: {k: v}`     | `dim.isVisibleGiven(values)`     | form filters per render; stale values dropped at save |
| `plannable:`            | `templates_screen` + timeline    | controls "Log now" stamping                        |
| `spreadsheet_id`        | `repo._spreadsheetIdFor(view)`   | per-view override                                  |

## Repository surface

`SheetsRepository` is the only thing that talks to Sheets. Methods:

- `connectFromKey({defaultSpreadsheetId, serviceAccountKeyJson})` — auth + return instance
- `ensureSheet(view)` — additive: creates the tab if missing, appends any
  missing header columns (preserves existing). Run once at startup per view.
- `list(view, {onDate})` — fetch all rows; optionally filter by `dateField`.
  Each returned record carries a hidden `__row` key (its zero-based data row
  index) so `update`/`delete` can find it even if `id` is missing.
- `create(view, record)` — appends a row. Auto-assigns `id` UUID if the view
  has an `id` dimension and the record doesn't.
- `update(view, record)` — resolves the row by `__row` (preferred) or `id`,
  preserves cells in columns the view doesn't know about.
- `delete(view, record)` — same resolution; removes the row via
  `deleteDimension`.

Three things to remember:

1. **Sheet column matching uses `dimension.expr`**, not `dimension.name`.
   `expr` is the actual header string in the sheet. The model exposes
   `view.dimensionByExpr(header)` for the read path.
2. **`valueInputOption: 'RAW'`** — strings go in literally, no formula
   parsing. Date/datetime values are formatted by `CellCodec.encode` to
   ISO strings.
3. **`ensureSheet` is additive.** It will never delete or reorder columns
   on the sheet — safe to run against pre-existing sheets with extra columns.

## Local-first plan store

Templates and "planned" rows do not touch the sheet. They live in
`shared_preferences` under `plan:<view>` as a JSON array of `PlannedEntry`s.

Flow:

```
templates_screen._apply       PlanStore.addAll       <- creates planned
timeline_screen._fetch        PlanStore.loadForDate  <- reads planned for date
                              + repo.list(...)       <- reads logged from sheet
                              -> List<_Item>         (planned merged on top)

timeline_screen._logNow       repo.create(record)    <- writes to sheet
                              PlanStore.remove(id)   <- removes from local plan

timeline_screen._edit         FormScreen(planMode)   <- returns updated values
                              PlanStore.update(...)  <- writes back to plan

timeline_screen._delete       PlanStore.remove OR repo.delete (branch on isPlanned)
```

Implications:

- `isPlanned` is **not** a function of "sheet row missing start_time" anymore.
  It's identity: `_Item` is either a `Record` from sheet (`logged`) or a
  `PlannedEntry` from local store (`planned`).
- Past planned entries that were never logged accumulate as silent cobwebs
  in `shared_preferences`. They don't show on the timeline (date-filtered),
  but they're not auto-cleaned. Add a periodic cleanup later if storage
  becomes a concern (currently negligible).
- Plans are per-device (no sync). Single-phone assumption.

## Data model glossary

- `Record = Map<String, Object?>` — one row from the sheet, keyed by
  dimension name. Carries `__row` if it came from `list()`.
- `PlannedEntry` — local-only pre-log row. Has its own `localId`. Values are
  encoded via `CellCodec` for JSON round-trip in shared_preferences.
- `_Item` (timeline_screen.dart) — sealed-ish wrapper that holds either a
  `Record` or a `PlannedEntry`. UI dispatches on `item.isPlanned`.
- `Template` — YAML preset that fans out into N entries when applied.
  Variables are Jinja2 expressions evaluated at apply time.

## Gotchas (have-bitten-us list)

1. **`jinja` package exports a class named `Template`.** It clashes with our
   model. Always import as `import 'package:jinja/jinja.dart' hide Template;`.
2. **`Map.entries.length` doesn't exist on iterables**. Use
   `.where(...).length` or `.toList().length`.
3. **Hot reload doesn't pick up new YAMLs** since they're assets. Need a
   full rebuild + reinstall.
4. **Sheets API trims trailing empty cells** on read. A row of width 9 that
   ends in 3 empty cells comes back as length 6. The `update` code iterates
   by header count, not row length, so writes are correct width.
5. **`flutter analyze` against `tool/*.dart`** can complain about scripts
   that intentionally use `print` — `// ignore_for_file: avoid_print` at the
   top of each script silences it.
6. **`dart run -e "..."` doesn't exist.** Write a real file in `tool/` and
   `dart run tool/<file>.dart`.
7. **Don't sleep / poll** for Sheets writes to land — the API call is
   awaited; if it returns ok, the write happened. Add a `debugPrint` if you
   want to verify, but trust the response.
8. **The form's `Save` button must drop hidden field values** at save time
   when `show_when` is in play. Otherwise stale values from a previous
   choice get persisted.
9. **`values.append` to "A1" eats the header row if cell A1 is empty.**
   The Sheets API decides "the table at A1 is empty, so write starting at
   A1," and the first appended row lands on top of the header. Use
   `values.update` with an explicit range like `A2` for bulk writes that
   need to preserve the header. The repository's `create()` is fine because
   we always have `id` (or another non-empty header) at column A — but be
   careful in `tool/` scripts. Recovery tool: `tool/rebuild_headers.dart`.
10. **`CellCodec.encode` returns `Object`, not `String`.** Numbers go to the
    sheet as `num` (so Sheets stores them as numbers, not text with a leading
    apostrophe). Don't `.toString()` the encoded value before passing to the
    Sheets API.
11. **dart `jinja: ^0.6.6`'s numeric filters are broken in two ways:**
    `round` isn't registered (raises "no filter named 'round'"), and `int`
    is defined as `int doInteger(String value, ...)` — a string-parse, not a
    numeric cast — so `(53.04) | int` throws "type 'double' is not a
    supported subtype of type 'string'". `TemplateInterpolator._env`
    registers a custom `round` filter that does real numeric rounding
    (`(n as num).round()`). For round-to-5 use `((x / 5) | round) * 5`.
    Don't reach for `| int` for float→int conversion — use `| round` instead.

## How to add a new tracker (worked example)

User asks: "I want to track sleep."

1. Write `~/repos/ledger-schemas/views/sleep.view.yml` with at minimum
   `name`, `entities`, `dimensions` (including an `id`), and `list_display`.
2. Run `./tool/sync_assets.sh` to copy it into `assets/schemas/`.
3. (Optional) Verify the YAML parses with `dart run tool/check_schema.dart
   /Users/<you>/repos/ledger/assets/schemas/sleep.view.yml`.
4. Build + install (see "Build + deploy loop" above).
5. On launch the home screen now shows `sleep`. On first tap, the app calls
   `ensureSheet(sleepView)` which creates the tab + writes headers.
6. If you want templates, drop them under
   `~/repos/ledger-schemas/templates/sleep/*.yml` and re-sync.

## How to migrate data into the ledger sheet

Pattern (see `tool/migrate_strength.dart` / `tool/migrate_cardio.dart`):

1. Pull rows from source via Sheets API.
2. Transform per row: generate UUID, normalize columns, apply any
   consolidation (e.g. word-set merge for exercise names), strip sentinels.
3. Ensure destination tab exists (`spreadsheets.batchUpdate addSheet`).
4. Write headers (`values.update A1`).
5. Clear existing data rows (`values.clear A2:Z`).
6. Append in batches (`values.append`, batch size ~2000 to stay well under
   the 10MB request limit).

Always gate destructive scripts behind `--confirm`.

## Common Claude pitfalls in this repo

- **Don't assume Sheets supports SQL.** It does have `QUERY(...)` but it's
  very limited. For analytics, the plan is sync-to-DuckDB-on-device.
- **Don't add iOS files** (`ios/` directory shouldn't exist). User won't
  test iOS.
- **Don't run `flutter create` over the project** — it will trample
  `pubspec.yaml`, `android/app/build.gradle`, and asset settings.
- **Don't `git commit` unless explicitly asked.** User has not been asking
  for commits during these sessions.
- **Don't `flutter pub upgrade`** without reason — version constraints are
  pinned for repeatable builds.

## Pointers

- Schema feature reference: `../ledger-schemas/README.md`
- User-facing project overview: `./README.md`
- Memory entries for this project: `~/.claude/projects/-Users-robertyi-repos-ledger/memory/MEMORY.md`
