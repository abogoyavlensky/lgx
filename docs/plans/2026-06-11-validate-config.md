# lgx.edn Validation via Mini Spec Engine Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the imperative lgx.edn validators with a minimal schema-as-data spec engine that collects all errors, reports them cleanly (no stack traces), and loads the config once per invocation.

**Tech Stack:** let-go (`.lg`), lgx's own test runner (`lgx test`), bash e2e harness (`tests/e2e.sh`).

---

## Design

### Problem

`lgx/config.lg` already validates lgx.edn thoroughly, but the implementation has four problems:

1. **Errors surface ugly.** An invalid config throws an `ex-info` that nothing
   catches, so the user sees a let-go stack trace after the message.
2. **First-error-only.** Validation stops at the first problem; the user fixes
   one, reruns, hits the next.
3. **Silent omission in help.** `tasks-block` in `lgx.lg` wraps `config/tasks`
   in `(try ... (catch _ {}))`, so a malformed `:tasks` silently disappears
   from the help output instead of failing.
4. **~280 lines of imperative `bad!` checks**, with subtly different phrasing
   for the same mistake in tasks vs contexts vs targets, and every accessor
   (`coords`, `paths`, `tasks`, `contexts`, `main`, `targets`) re-reads and
   re-validates the file — a single `lgx run` parses lgx.edn about four times.

### Solution overview

A new file `lgx/spec.lg` holds a minimal malli-in-spirit validation engine:
schemas are plain data, validation returns a vector of error maps (never
throws), and each error carries a path into the config. `config.lg` expresses
the whole lgx.edn format as one schema value, loads the file once per
invocation, and renders collected errors as a clean report. `lgx.lg` threads
the loaded config map instead of re-reading per accessor.

### Component 1: the spec engine (`lgx/spec.lg`)

Public API:

- `(spec/validate schema value)` → vector of `{:path [...] :msg "..."}`
  errors. Empty vector when valid. Never throws.
- `(spec/error->line err)` → one rendered line, e.g.
  `:tasks :build :do [0] — unknown step key :shh (allowed: :sh, :run)`.
  Path elements are joined with spaces; keywords and symbols print as
  themselves; vector indices print as `[n]`; an empty path renders just the
  message.

Schema language — eight forms, nothing else:

| Form | Used for |
|---|---|
| `:string` / `:keyword` / `:symbol` / `:map` / `:vector` / `:any` | leaf type checks → `must be a string, got 42` (got-value via `pr-str`) |
| `[:map opts? [k opts? sch] ...]` | top level, task, context, targets, bin maps. Entry opts: `{:optional true}` (default required). Map opts: `{:closed true}` → unknown keys error with the allowed-keys list. Missing required key → `missing required key :out`. |
| `[:map-of key-sch val-sch]` | `:deps`, `:tasks`, `:contexts`. Key errors get the key itself appended to the path. |
| `[:vector opts? item-sch]` | `:paths`, `:do`, `:sh`/`:run` vectors. Opts: `{:min 1}` → `must contain at least 1 element`. |
| `[:or opts? s1 s2 ...]` | `:do` (step map or vector of steps), `:sh` value (string or vector of strings). When all branches fail, report the single `{:msg "..."}` from opts instead of per-branch noise. |
| `[:and s1 s2 ...]` | type check first, custom rule second; stops at the first sub-schema that produces errors. |
| `[:enum v1 v2 ...]` | fixed value sets → `must be one of: v1, v2, got x`. No current consumer in the lgx schema (closed maps cover today's key sets); included for engine completeness. |
| `[:fn f]` | custom rules. `(f value)` returns `nil` (valid), a message string, a `{:path [...] :msg "..."}` map (path is relative, engine prefixes the current path), or a vector of those. |

`[:fn f]` is the escape hatch that keeps the engine tiny while preserving the
current tailored messages: rel-path rules (`must be relative (no leading /)`,
`must not contain .. segments`, non-blank), coord shape (`cannot mix
:local/root with :git/* keys`, `must specify :git/sha or :git/tag`, `missing
:git/url`), reserved task names (`conflicts with built-in command "run"`),
step shape (exactly one action key of `:sh`/`:run`), and the root-level
cross-key check that every task's `:with` entry references a defined
`:contexts` key (returns errors with their own sub-paths).

Engine internals: a single recursive `(validate* schema path value)` that
dispatches on keyword leaf vs vector form, accumulating errors into a vector.
No registry, no transformers, no regex schemas, no lazy anything.

### Component 2: `config.lg` restructure

**Schema as data.** A private `lgx-schema` def builds the full lgx.edn format
from the forms above plus the `:fn` helpers. It replaces `validate-config!`,
`validate-coord!`, `validate-paths!`, `validate-task!`, `validate-step!`,
`validate-tasks!`, `validate-context!`, `validate-contexts!`,
`validate-main!`, `validate-targets!`, `validate-bin-target!`,
`validate-with!`, `validate-extra-deps!`, `validate-action-value!`,
`validate-local-root!`, `validate-git-coord!`, `validate-rel-path!`,
`normalize-task-steps!`, and `bad!`.

Behavior preserved from today:

- Coord maps stay **open** — unknown keys inside a dep coordinate are not
  errors (tools.deps forward-compat). All other maps are closed.
- Reserved task names: `run`, `nrepl`, `install`, `new`, `add`, `update`,
  `tasks`, `help`, `version`, `build`, `test` (the existing
  `reserved-task-names` set stays public — config_test.lg references it).
- A task requires `:do`; `:do` accepts a single step map or a non-empty vector
  of step maps; a step has exactly one of `:sh`/`:run`, valued a non-blank
  string or non-empty vector of strings.
- Allowed key sets per map are unchanged from the current `allowed-*` defs.

**Load once.** New public API:

- `(config/load-config project)` → `{:cfg <validated+normalized map>}` or
  `{:errors [{:path ... :msg ...} ...]}`. EDN reader failures are caught and
  returned as a single error (`could not parse lgx.edn: <ex-message>`) rather
  than escaping. (Named `load-config`, not `load`, to avoid colliding with
  any core `load`.)
- `(config/load-config! project)` → the cfg map, or prints the error report
  to stderr and exits 1.

Error report format (stderr, exit 1):

```
lgx: invalid lgx.edn (3 errors)

  :paths — must be a vector, got "src"
  :tasks :build :do [0] — unknown step key :shh (allowed: :sh, :run)
  :targets :bin — missing required key :out
```

Header is `(1 error)` singular when there is one. Errors print in the order
the engine produced them (document order). Report rendering lives in
`config.lg` (it owns the "lgx.edn" framing); per-line rendering is
`spec/error->line`.

**Normalization stays separate.** After validation passes, a small
`normalize-config` pass converts each task's single-map `:do` into a
one-element vector. Validation never mutates; normalization never validates.

**Accessors become pure.** `coords`, `paths`, `resource-paths`, `tasks`,
`contexts`, `main`, `targets` take the loaded cfg map instead of a project
root and do no I/O. Same names, same return shapes (e.g. `coords` still
returns a vector of `[lib coord]` pairs; `tasks` defaults to `{}`).

**Unchanged:** `find-project`, `find-project!`, `merge-coords`,
`context-overlay`, `config-name`.

**`coords-at` (dep configs) stays lenient** — only `:deps` is validated
(reusing the deps sub-schema via `spec/validate`); unknown top-level keys in a
dep's lgx.edn remain fine (documented forward-compat). On errors it now prints
a clean report naming the dep dir (`lgx: invalid lgx.edn in <dir> (N
errors)`) and exits 1, instead of today's uncaught throw.

### Component 3: CLI integration (`lgx.lg`)

All `config/*` call sites live in `lgx.lg`; nothing else consumes them.

- **Commands that load the config** (and fail with the report when invalid):
  `install`, `run`, `nrepl`, `build`, `test`, and every custom task. Each
  `cmd-*` does `find-project!` then `load-config!` once and threads `cfg`
  onward. `new` and `version` never touch lgx.edn and are unaffected.
- **Threading:** `overlay-basis` becomes `[project cfg cli-with task]`;
  `with->overlay!` takes `cfg`; `basis` keeps taking `project` (it resolves
  paths against the root) plus the already-extracted coords/paths.
- **Unknown command** (`lgx foo`): dispatch cannot know whether `foo` is a
  task without the config, so with a project present it runs `load-config!`
  first — invalid config prints the report and exits 1 (not a misleading
  `'foo' is not a lgx command`). No project at all keeps the current
  not-a-command error. On success the loaded cfg is passed into `cmd-task`
  so the task path loads the file exactly once.
- **Help** (`lgx help` / bare `lgx`): always prints built-in commands and
  options. `tasks-block` switches from `(catch _ {})` to `config/load-config`;
  on `:errors` it renders:

  ```
  Project tasks:
    (omitted — lgx.edn is invalid; run `lgx install` to see errors)
  ```

- **No stack traces anywhere:** the engine returns data, `load-config!` owns
  printing, so nothing config-related escapes to let-go's top-level handler.

### Error handling summary

| Situation | Behavior |
|---|---|
| Invalid lgx.edn, basis command | report to stderr, exit 1 |
| Invalid lgx.edn, unknown command | report to stderr, exit 1 |
| Invalid lgx.edn, help | help prints; tasks section shows one-line warning |
| Unparseable EDN | same report path, single `could not parse` error |
| Invalid `:deps` in a *dep's* lgx.edn | report naming the dep dir, exit 1 |
| Unknown keys in a dep coordinate | accepted (open map, forward-compat) |

### Testing strategy

- **`test/lgx/spec_test.lg` (new):** engine unit tests — every schema form
  (incl. `:enum`), nested paths, `[:or]` single-message behavior, closed-map
  allowed-keys lists, `{:min 1}`, `:fn` returning each of its four result
  shapes, error accumulation across siblings, `error->line` rendering (incl.
  empty path and index segments).
- **`test/lgx/config_test.lg` (rewritten):** valid minimal/full configs load;
  each error class produces the expected `{:path :msg}`; multiple errors
  aggregate; `:do` normalization; pure accessors; reserved task names;
  `coords-at` leniency preserved.
- **`tests/e2e.sh` (extended):** invalid config → stderr report with
  `(N errors)` header and no `stack trace` substring; `lgx help` with broken
  config shows the warning and still lists built-in commands; valid-config
  behavior unchanged (existing cases keep passing).
- Full suite: `make test` (bundles `bin/lgx`, runs unit tests, then e2e).

## File Structure

- **Create** `lgx/spec.lg` — the validation engine. Depends only on
  `string`; no lgx deps.
- **Create** `test/lgx/spec_test.lg` — engine unit tests.
- **Modify** `lgx/config.lg` — schema def, `:fn` helpers, `load-config` /
  `load-config!`, `normalize-config`, pure accessors, lenient `coords-at`.
  Net size should drop.
- **Modify** `test/lgx/config_test.lg` — rewrite to the new API.
- **Modify** `lgx.lg` — thread cfg; dispatch/unknown-command/help changes.
- **Modify** `tests/e2e.sh` — new invalid-config cases.
- **Modify** `docs/ARCHITECTURE.md` — add `lgx/spec.lg` to the component
  table; update the `lgx/config.lg` line and the "Read lgx.edn, validate the
  schema" flow note.

## Tasks

Run unit tests during development with `make build && ./bin/lgx test
test/lgx/<file>.lg` (the runner takes one file), and the full suite with
`make test`.

### Task 1: Spec engine — leaves, `:map`, `:vector`

**Files:**
- Create: `lgx/spec.lg`
- Create: `test/lgx/spec_test.lg`

- [x] **Step 1: Write failing tests**
  Cover: leaf types (`:string`, `:keyword`, `:symbol`, `:map`, `:vector`,
  `:any`) pass/fail with `must be a <type>, got <pr-str>` messages; `[:map]`
  required vs `{:optional true}` entries; `{:closed true}` unknown-key error
  listing allowed keys; nested maps produce nested paths; `[:vector]` item
  errors carry `[n]` index segments; `{:min 1}`; valid values return `[]`.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/spec_test.lg`
  Expected: FAIL (namespace `lgx.spec` missing / assertions fail).

- [x] **Step 3: Implement**
  `lgx/spec.lg` with private `validate*` recursion over `(schema, path,
  value)` and public `validate`. Keyword leaf → type predicate table. Vector
  form → dispatch on first element. Options map is optional in second
  position for `:map` / `:vector` (detect: map there that isn't an entry
  vector).

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && ./bin/lgx test test/lgx/spec_test.lg`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Add lgx.spec validation engine: leaves, :map, :vector"`

### Task 2: Spec engine — `:map-of`, `:or`, `:and`, `:enum`, `:fn`, `error->line`

**Files:**
- Modify: `lgx/spec.lg`
- Modify: `test/lgx/spec_test.lg`

- [x] **Step 1: Write failing tests**
  Cover: `[:map-of]` key and value errors (key errors append the offending
  key to the path); `[:or {:msg ...}]` reports only the single message when
  all branches fail and nothing when one passes; `[:and]` stops at the first
  failing sub-schema; `[:enum]` message lists allowed values; `[:fn]` with
  each return shape (nil / string / `{:path :msg}` map whose path gets
  prefixed / vector of those); `error->line` rendering for empty path,
  keyword segments, symbol segments, and `[n]` index segments.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/spec_test.lg`
  Expected: FAIL on the new assertions.

- [x] **Step 3: Implement**
  Add the four forms to `validate*`; add `error->line`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && ./bin/lgx test test/lgx/spec_test.lg`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Complete lgx.spec engine: :map-of, :or, :and, :enum, :fn"`

### Task 3: Config schema, `load-config`, normalization

**Files:**
- Modify: `lgx/config.lg`
- Modify: `test/lgx/config_test.lg`

- [x] **Step 1: Write failing tests**
  Rewrite `config_test.lg` against `config/load-config` using a temp project
  dir (write lgx.edn with `spit`, point `load-config` at the dir). Cover:
  valid minimal (`{}`) and full configs (deps git/tag/local, paths,
  resource-paths, main, targets, contexts, tasks with `:with` /
  `:extra-deps` / single-map `:do`); every error class with its expected
  `{:path ... :msg ...}` (non-map top level, unknown top-level key, bad
  paths entries, rel-path rules, coord mix / missing url / missing sha+tag,
  non-map tasks, reserved task name, unknown task key, missing `:do`, bad
  step, `:with` referencing unknown context, bad contexts, bad targets);
  multiple independent errors aggregate in one result; single-map `:do`
  normalizes to a one-element vector in `:cfg`; unparseable EDN yields one
  `could not parse` error.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/config_test.lg`
  Expected: FAIL (`load-config` missing).

- [x] **Step 3: Implement**
  In `config.lg`: `:fn` helper fns (rel-path, coord, step, reserved task
  name, root `:with`→`:contexts` check), `lgx-schema`, `normalize-config`,
  `load-config`, `load-config!` (report rendering + exit 1). Keep the old
  accessor/validator fns in place for now so `lgx.lg` still compiles —
  removal happens in Task 4.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && ./bin/lgx test test/lgx/config_test.lg`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Express lgx.edn schema as data; add load-config with error collection"`

### Task 4: Pure accessors, lenient `coords-at`, delete old validators

**Files:**
- Modify: `lgx/config.lg`
- Modify: `lgx.lg`
- Modify: `test/lgx/config_test.lg`

- [x] **Step 1: Write failing tests**
  Add tests: `coords` / `paths` / `resource-paths` / `tasks` / `contexts` /
  `main` / `targets` over a loaded cfg map (no I/O, correct defaults);
  `coords-at` still lenient (unknown top-level keys fine, missing file → `[]`,
  only `:deps` validated).

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/config_test.lg`
  Expected: FAIL (accessors still take a project root).

- [x] **Step 3: Implement**
  Convert accessors to pure fns over cfg; rewrite `coords-at` on the deps
  sub-schema with the dep-dir report; delete `validate-config!`, `bad!`, and
  all `validate-*` helpers; thread cfg through `lgx.lg`: each `cmd-*` calls
  `find-project!` + `load-config!`, `overlay-basis` / `with->overlay!` take
  cfg, dispatch loads before the task fallback (project present → report on
  invalid; no project → current not-a-command error), `cmd-task` receives
  the cfg, `tasks-block` / `usage-for` / `print-usage!` use `load-config`
  with the warning line on `:errors`.

- [x] **Step 4: Run full suite**
  Run: `make test`
  Expected: PASS (unit + existing e2e — existing e2e error-message
  assertions may need updating to the new report wording; update them as
  part of this step).

- [x] **Step 5: Commit**
  `git commit -m "Load lgx.edn once per invocation; thread cfg through commands"`

### Task 5: E2E coverage for the new error surface

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add e2e cases**
  In a throwaway project dir: (a) lgx.edn with several errors → `lgx run`
  exits 1, stderr contains `lgx: invalid lgx.edn (` and each expected error
  line, and does **not** contain `stack trace`; (b) same dir → `lgx help`
  exits 0, stdout contains `Built-in commands:` and the
  `(omitted — lgx.edn is invalid` warning; (c) unknown command in the broken
  dir → exits 1 with the report, not `is not a lgx command`; (d) unparseable
  EDN → single `could not parse` error.

- [x] **Step 2: Run the suite**
  Run: `make test`
  Expected: PASS, new cases included in the pass count.

- [x] **Step 3: Commit**
  `git commit -m "Add e2e coverage for lgx.edn validation reporting"`

### Task 6: Docs sync

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Update docs**
  Add `lgx/spec.lg` to the component table; update the `lgx/config.lg` line
  (schema-as-data, load-once) and the install-flow "validate the schema"
  note; mention the all-errors report. Check the `Verify against:` footers
  still name the right files.

- [x] **Step 2: Commit**
  `git commit -m "Document spec engine and load-once config in architecture"`

---

## Completion summary (2026-06-11)

**Status: completed.** All six tasks implemented and committed; full suite
green (299 unit tests, 226 e2e assertions).

What was built, per the design: `lgx/spec.lg` (eight-form schema-as-data
engine, ~170 lines), the lgx.edn format as one schema value in
`lgx/config.lg`, `load-config`/`load-config!` (read + validate + normalize
once per invocation), pure accessors, the all-errors stderr report with no
stack traces, the help-warning behavior, and the dispatch/unknown-command
report path. Architecture doc updated. Old imperative validators deleted
(`lgx/config.lg` shrank by ~240 lines net across Tasks 3-4).

Deviations from the plan, both reviewed in-session:

1. **`coords-at` error mechanics.** The plan said coords-at prints the
   dep-dir report and exits. Implemented instead as a thrown ex-info carrying
   the rendered report plus an `:lgx/invalid-dep-config` marker, caught by
   `coords-at!` in `lgx.lg` (print + exit 1). Same user-visible behavior,
   but unit-testable without killing the test process, and consistent with
   the existing `with->overlay!` marker-catch idiom.
2. **The plan's aggregation example used task name `:build`,** which is a
   reserved name — the test fixture was corrected to `:lint` (the engine had
   correctly flagged the conflict as a fourth error).

Per-task codex reviews found no must-fix issues; one P3 docs-wording nit on
the final commit (overbroad "never throws" claim) was fixed.
