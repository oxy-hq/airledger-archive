# `.view.yml` ↔ `.input.yml` pairing

**Principle.** Each tracker lives in two paired YAML files: a semantic-layer
`.view.yml` that other tools (oxy, airlayer) can ingest unmodified, and an
input-layer `.input.yml` that this app owns. Splitting the files keeps the
semantic schema clean while letting the form/UI/logging behavior evolve
without affecting other consumers.

This document explains the split, the pairing mechanism, and the
validation rules `applyInputOverlay` enforces.

---

## Why two files

The semantic layer (entities, dimensions, measures) is a stable contract
that airlayer compiles into SQL and oxy reads to plan agents. The input
layer (widgets, defaults, show-when rules, history settings) is private to
the form-based logger. Mixing them would force airlayer to learn to ignore
fields it doesn't care about, and would block the schema author from
adding UI behavior without re-deploying the analytical layer.

The split mirrors what airlayer does with `config.yml` — see
[`oxy-compatibility.md`](./oxy-compatibility.md) for the parallel
principle on database configs.

---

## File layout

A tracker named `<name>` is a pair:

```
views/<name>.view.yml     ← semantic layer (airlayer-compatible)
views/<name>.input.yml    ← input/UI layer (airledger-only)
```

Both files live in the same `views/` directory of the schemas repo (e.g.
`~/repos/airledger-fitness/views/`). `tool/sync_assets.sh` copies them flat
into `assets/schemas/`; `SchemaLoader` pairs them by basename at load time.

### What goes in `<name>.view.yml`

```yaml
name: strength
description: …
datasource: gsheets
table: strength
entities:   [...]
dimensions: [...]   # { name, type, expr, description }
measures:   [...]   # { name, type, expr, description }
```

Anything an external semantic-layer consumer needs. No widget config, no
form behavior, no UI flags. The expressions in `measures.expr` reference
column names (the `expr:` field on each dimension), not the lower-case
dimension `name`s.

### What goes in `<name>.input.yml`

```yaml
target: <name>.view.yml   # required back-pointer

# View-level UI/logging config
date_field:   date
icon:         dumbbell
spreadsheet_id: …
plannable:    { log_field: start_time, log_format: time_string }
list_display: { title: exercise, subtitle: "${weight} × ${reps}" }
post_log:     { model: sonnet, prompt: "…" }
top_metric:   max_e1rm     # references a measure declared on the .view.yml

# Per-field overlays — keyed by dimension name
fields:
  exercise:
    widget: autocomplete
    required: true
    history: true          # opt into the history-panel icon
    options: [...]
  weight:
    widget: number
    required: true
    show_when: { exercise: { not_in_group: [isometric, timed] } }
  date:
    widget: date
    default: today
  day_of_week:
    derive: { from: date, format: weekday_long }

# Named value sets — referenced by show_when predicates above
groups:
  isometric: [Plank, …]
  timed:     [Handstand Practice]
```

Anything that drives the form, the timeline, the templates UI, or the
post-log hook lives here.

---

## How they get loaded

1. `tool/sync_assets.sh` flat-copies both files into `assets/schemas/`.
2. At app start, `SchemaLoader` walks `assets/schemas/` for every
   `<name>.view.yml`.
3. For each one, `parseViewSchema(...)` builds a bare semantic
   `ViewSchema` (no input fields populated).
4. If `<name>.input.yml` is present, `parseInputOverlay(...)` parses it
   into an `InputOverlay`.
5. `applyInputOverlay(view, overlay)` produces the merged `ViewSchema`
   that the app actually uses. The overlay's dim entries get layered onto
   the view's dims by name; top-level overlay fields populate the
   view-level slots.

The merged `ViewSchema` is the *only* shape the rest of the app sees —
nothing downstream of `SchemaLoader` knows the two files exist separately.

---

## Pairing mechanism

Two checks ensure the pairing is intentional:

1. **`target:` back-pointer.** The input file must declare
   `target: <basename>.view.yml`. This is parsed and the trailing
   `.view.yml` is stripped to derive the expected view name.
2. **Name match.** `applyInputOverlay` throws if the derived view name
   doesn't equal the paired `.view.yml`'s `name:` field.

So renaming one file but not the other fails loudly at startup, not
silently at runtime.

---

## Cross-file references

Some `.input.yml` fields *point at* names declared on the `.view.yml`. The
overlay-apply step validates each reference and throws on a miss:

| `.input.yml` field | Refers to | Validation |
|--------------------|-----------|------------|
| `fields.<dimName>` | a dimension on `.view.yml` | throws `dimName` not declared |
| `top_metric: <name>` | a measure on `.view.yml` | throws `name` not a measure |
| `date_field: <name>` | a dimension on `.view.yml` | not currently checked |
| `plannable.log_field: <name>` | a dimension on `.view.yml` | not currently checked |
| `list_display.title: <name>` | a dimension on `.view.yml` | not currently checked |
| `show_when.<dim>` | another dimension on `.view.yml` | not currently checked |

The unchecked references are TODOs — the pattern is the same shape as the
two checked ones and adding fail-loud validation is ~5 lines per case.

---

## Field-placement rubric

When adding a new field to the schema, place it by asking "would an
external analytical tool benefit from seeing this?":

| Field kind | Belongs in | Examples |
|-----------|------------|----------|
| Entity/dimension/measure/expr/description | `.view.yml` | Standard semantic layer |
| Widget config, defaults, placeholders, history flag | `.input.yml` `fields:` | `widget: autocomplete`, `now_button: true` |
| Show-when rules and derives | `.input.yml` `fields:` | Hides fields based on form state |
| Form/UI ergonomics (date_field, list_display, icon) | `.input.yml` top-level | What the timeline header shows |
| References to measures for UI behavior | `.input.yml` top-level | `top_metric` |
| Post-log hooks (LLM, etc.) | `.input.yml` top-level | `post_log` |
| Named value sets used by show_when | `.input.yml` `groups:` | `isometric`, `timed` |
| Storage target (spreadsheet id) | Either, but prefer `.input.yml` | Pick one to avoid ambiguity |

---

## Adding a new tracker

1. Write `views/<name>.view.yml` with `name`, `entities`, `dimensions`
   (including an `id`), `measures` you'll want analytically.
2. Write `views/<name>.input.yml` with `target: <name>.view.yml`,
   `date_field`, per-field overlays, any `groups` your show_when rules
   need.
3. Run `tool/sync_assets.sh`.
4. (Optional) `dart run tool/check_schema.dart assets/schemas/<name>.view.yml`
   to verify parsing.
5. Build + install. On first launch the home screen lists the new tracker;
   first tap triggers `ensureSheet(view)` which creates the tab and writes
   headers.
