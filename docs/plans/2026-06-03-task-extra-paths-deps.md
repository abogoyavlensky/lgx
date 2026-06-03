# Task `:extra-paths` / `:extra-deps` Implementation Plan — ✅ COMPLETED

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a project task declare optional `:extra-paths` and `:extra-deps` keys that augment the resolved `-source-paths` for that task's `:run` steps, with extra deps overriding same-named project deps for that task only.

**Tech Stack:** let-go (Clojure dialect, `.lg`), bash e2e harness.

---

## Design

### Schema

A task gains two optional keys alongside `:doc` and `:do`:

```edn
{:tasks
 {:repl {:doc         "REPL with dev tooling"
         :extra-paths ["dev"]
         :extra-deps  {some/nrepl {:git/url "https://github.com/x/nrepl"
                                   :git/tag "v1"}}
         :do          [{:run "dev/repl.lg"}]}}}
```

- `:extra-paths` — a vector of project-root-relative source paths. Same
  rules and validation as top-level `:paths` (non-blank strings, no
  leading `/`, no `..` segments). A missing directory logs the same
  warning `resolve-project-paths` already emits, but still passes through.
- `:extra-deps` — a map of `lib -> coord`. Same coord grammar and
  validation as top-level `:deps` (git `:git/sha`/`:git/tag`,
  `:local/root`, optional `:deps/root`). A relative `:local/root` in an
  extra-dep resolves against the **project root**, because it is declared
  in the project's own `lgx.edn`.

### Scope of effect

Extras augment only the `-source-paths` passed to `lg` for `:run` steps.
`:sh` steps are plain shell and are unaffected (exposing the resolved
path list to `:sh` via an env var is a separate, upstream-dependent
feature and an explicit non-goal here).

The task basis is computed **once** before the step chain runs, so a
task's `:extra-deps` are fetched up front — showing the normal
`installing N dep(s)...` block on first fetch — even for a task that
happens to have no `:run` step.

### Resolution & precedence (extra wins, silently)

A new pure helper `config/merge-coords` produces the task's coord list:

- Start from the project's coord pairs, **preserving their order**.
- When an extra-dep shares a lib name with a project coord, **replace
  that coord in place** (the extra wins; position is preserved).
- Append extras whose lib name is new, after the project coords.

The merged (deduped) list is then fed to the existing `ensure-all!`
exactly as today. Because the override is resolved at the config level —
before resolution — there is no duplicate lib name at the top level, so
the override is **silent**: `ensure-all!`'s "already resolved … ignoring"
warning never fires for an intentional extra-over-project override. The
warning still fires for genuine transitive conflicts, unchanged.

Feeding the merged top-level list to `ensure-all!` (breadth-first,
top-level seeded first) means an extra coord wins over both the
project-level coord **and** any transitively pulled coord for that lib —
which is the point of "override".

### Path ordering

Resulting `-source-paths` order for a task's `:run` step:

```
project :paths  →  task :extra-paths  →  project dep paths
                →  new extra-dep paths  →  transitive dep paths
```

(overridden coords substitute their path in the project dep's original
position). Project-local source first (own + extra), then deps — the
same shape as the existing basis, with extras slotted in.

### Wiring

`project-basis` in `lgx.lg` is refactored into a small `basis` helper
that takes explicit `coords` and a raw `paths` list; `project-basis`
becomes the no-extras caller used by `run`/`build`/`test`. `cmd-task`
reads `:extra-deps`/`:extra-paths` off the already-validated task map,
builds the merged coords (`config/merge-coords`) and the
`project :paths ++ :extra-paths` list, calls `basis`, prints installs,
then runs the steps as today.

### Validation

In `config/validate-task!`:

- Add a strict allowed-keys check: a task map may contain only
  `#{:doc :do :extra-paths :extra-deps}`. An unknown key (e.g. a typo
  `:extra-dep`) fails loudly with a clear message, consistent with how
  steps and `:targets` already reject unknown keys. This catches the
  silent-no-op failure mode where a misspelled key would otherwise be
  ignored.
- When `:extra-paths` is present, validate it with the existing
  `validate-paths!`.
- When `:extra-deps` is present, require a map and run each `[lib coord]`
  through the existing `validate-coord!`.

Dependency `lgx.edn` files are unaffected: `config/coords-at` reads only a
dep's `:deps`, never its `:tasks`.

### Testing strategy

- **Unit** (`test/lgx/config_test.lg`): validation accepts
  extra-paths/extra-deps (and both together); rejects non-vector
  extra-paths, a `..` extra-path, non-map extra-deps, a malformed
  extra-dep coord, and an unknown task key. `merge-coords`: no extras →
  unchanged; new lib → appended; colliding lib → replaced in place with
  order and count preserved. (Override precedence is fully covered here,
  so the e2e scenarios stay additive.)
- **E2E** (`tests/e2e.sh`, using the existing hermetic `file://`
  bare-repo seeding): one task whose `:run` step requires a namespace
  provided only by an `:extra-paths` dir; one whose `:run` step requires
  a namespace provided only by an `:extra-deps` git lib (asserting both
  the install block and the script output).
- **Docs**: README `### Tasks` section, the roadmap checkbox, and the
  `ARCHITECTURE.md` `### lgx <task>` section.

## File Structure

- Modify: `lgx/config.lg` — add `merge-coords` (pure); extend
  `validate-task!` with allowed-keys + extra-paths/extra-deps validation.
- Modify: `test/lgx/config_test.lg` — unit tests for the new validation
  and for `merge-coords`.
- Modify: `lgx.lg` — refactor `project-basis` into a `basis` helper taking
  explicit coords + raw paths; rewrite `cmd-task` to build and use the
  task basis.
- Modify: `tests/e2e.sh` — two new scenarios (extra-paths, extra-deps).
- Modify: `README.md` — document the keys in `### Tasks`; tick the roadmap
  item.
- Modify: `docs/ARCHITECTURE.md` — document extras in `### lgx <task>`.

## Implementation Steps

### Task 1: Validation for `:extra-paths` / `:extra-deps` + strict task keys

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing unit tests**
  In `test/lgx/config_test.lg`, near the existing `;; :tasks validation`
  block (around line 270), add `deftest`s using the file's `threw?`
  helper and `is`:
  - accepts a task with `:extra-paths ["dev"]` (config round-trips
    through `validate-config!`).
  - accepts a task with `:extra-deps {foo/bar {:git/url "u" :git/sha "s"}}`.
  - accepts a task with both keys plus `:doc`/`:do`.
  - rejects `:extra-paths "dev"` (not a vector) → `:threw`.
  - rejects `:extra-paths ["../x"]` (`..` segment) → `:threw`.
  - rejects `:extra-deps [:not :a :map]` → `:threw`.
  - rejects `:extra-deps {foo/bar {:git/url "u"}}` (no sha/tag) → `:threw`.
  - rejects an unknown task key, e.g.
    `{:tasks {:t {:do [{:sh "x"}] :extra-dep {}}}}` → `:threw`.

- [x] **Step 2: Run unit tests to verify they fail**
  Run: `bin/lgx test test/lgx/config_test.lg` (build first with
  `make build` if `bin/lgx` is stale, or run the whole suite via
  `bash tests/run.sh`).
  Expected: the new assertions fail — accepts-cases throw (keys not yet
  allowed) or rejects-cases don't throw (validation not added yet).

- [x] **Step 3: Implement validation in `validate-task!`**
  In `lgx/config.lg`, extend `validate-task!` (lines ~139–168):
  - Add `(def ^:private allowed-task-keys #{:doc :do :extra-paths :extra-deps})`
    near the other `allowed-*` sets, and at the top of `validate-task!`
    reject any task key not in that set with a `bad!` message naming the
    unknown key(s) and listing the allowed ones (mirror the
    `validate-step!` / `validate-targets!` unknown-key style).
  - After the existing `:do` validation, add:
    `(when (contains? task :extra-paths) (validate-paths! (:extra-paths task)))`.
  - And:
    `(when (contains? task :extra-deps) ...)` — require a map (`bad!`
    otherwise, message like `task <name> :extra-deps must be a map`), then
    `(doseq [[lib c] (:extra-deps task)] (validate-coord! lib c))`.
  `validate-paths!` and `validate-coord!` are already defined above
  `validate-task!`, so no reordering is needed.

- [x] **Step 4: Run unit tests to verify they pass**
  Run: `bash tests/run.sh` (or `bin/lgx test test/lgx/config_test.lg`
  after `make build`).
  Expected: all config_test assertions pass; rest of suite unaffected.

- [x] **Step 5: Commit**
  `git commit -am "feat: validate task :extra-paths and :extra-deps"`

### Task 2: `merge-coords` helper

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing unit tests**
  In `test/lgx/config_test.lg`, add `deftest`s for `config/merge-coords`
  (takes two coord-pair vectors `[[lib coord] ...]`, returns a merged
  vector):
  - no extras: `(merge-coords project [])` equals `project`.
  - new lib: an extra with a lib name not in project is appended **after**
    the project pairs.
  - override in place: an extra sharing a project lib name replaces that
    pair's coord, keeps the same vector length, and keeps the lib at its
    original index (assert the index/order, e.g. via `(map first ...)`,
    and that the coord is the extra's).

- [x] **Step 2: Run unit tests to verify they fail**
  Run: `bin/lgx test test/lgx/config_test.lg` (or `bash tests/run.sh`).
  Expected: fail — `merge-coords` is unresolved (compile error) /
  assertions red.

- [x] **Step 3: Implement `merge-coords`**
  In `lgx/config.lg`, add a pure public `merge-coords [project-pairs
  extra-pairs]`:
  - Build a set of project lib names.
  - For each project pair, if an extra defines the same lib name, emit the
    extra's coord in place; else emit the project pair unchanged.
  - Append every extra pair whose lib name is not in the project set, in
    extra order.
  - Return a vector of `[lib coord]` pairs.
  Keep it free of disk I/O (callers pass `config/coords` output and the
  task's `(vec (:extra-deps task))`).

- [x] **Step 4: Run unit tests to verify they pass**
  Run: `bash tests/run.sh`.
  Expected: all config_test assertions pass.

- [x] **Step 5: Commit**
  `git commit -am "feat: add config/merge-coords (extra-over-project override)"`

### Task 3: Wire extras into `cmd-task` (basis refactor + e2e)

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh`

- [x] **Step 1: Write the failing e2e scenarios**
  In `tests/e2e.sh`, append two scenarios after the current final one
  (use the next free scenario numbers). Reuse the existing helpers.

  *Extra-paths scenario.* Make a project dir under a throwaway
  `LGX_HOME`. Write `dev/devtool.lg` (`(ns devtool) (defn banner []
  "DEV-OK")`) and a script `task-main.lg`
  (`(ns task.main (:require [devtool])) (println (devtool/banner))`).
  Write an `lgx.edn` with:
  `{:tasks {:devrun {:extra-paths ["dev"] :do [{:run "task-main.lg"}]}}}`.
  Run `(cd "$proj" && "$LGX" devrun)`, capture output, and
  `assert_contains "$out" "DEV-OK"` — the `:run` step resolved `devtool`
  only because `dev/` was added via `:extra-paths`.

  *Extra-deps scenario.* Use a throwaway `LGX_HOME` (a fresh temp dir) so
  the fetch is guaranteed cold. Seed a bare repo with `make_bare_repo` (it
  provides ns `test.fib` under `src/`). In a fresh project (no top-level
  `:deps`), write a script `fib-main.lg`
  (`(ns fib.main (:require [test.fib :as fib])) (println (fib/fib 10))`)
  and an `lgx.edn`:
  `{:tasks {:fibrun {:extra-deps {test/lib {:git/url "file://$bare"
  :git/sha "$sha"}} :do [{:run "fib-main.lg"}]}}}`.
  Run the task; `assert_contains "$out" "55"` (fib 10) and
  `assert_contains "$out" "installing 1 dep(s)..."` (matching scenarios
  7/10/11's exact wording — the extra-dep is fetched on this cold run).
  Follow the existing dep scenarios' guard pattern
  (`supports_source_paths` / lg availability) so the scenario skips
  cleanly where the others do.

- [x] **Step 2: Run e2e to verify it fails**
  Run: `bash tests/run.sh`.
  Expected: the new scenarios fail — `cmd-task` does not yet add extras,
  so `devtool` / `test.fib` fail to resolve in the `:run` step.

- [x] **Step 3: Refactor `project-basis` and wire `cmd-task`**
  In `lgx.lg`:
  - Extract a private `basis [project coords raw-paths]` from
    `project-basis` (lines ~112–123): it runs `ensure-all!` on `coords`,
    resolves `raw-paths` via `resolve-project-paths`, and returns
    `{:project :results :paths}` with `paths = own-paths ++ (mapv :path
    results)`. Redefine `project-basis [project]` as
    `(basis project (config/coords project) (config/paths project))` so
    `run`/`build`/`test` are unchanged.
  - Rewrite `cmd-task` (lines ~275–279) to build the task basis:
    `coords = (config/merge-coords (config/coords project) (vec (or
    (:extra-deps task) {})))`,
    `raw-paths = (vec (concat (config/paths project) (or (:extra-paths
    task) [])))`, then `(basis project coords raw-paths)`, `print-installs!`
    the results, and `(tasks/run-task! task paths verbose?)`.

- [x] **Step 4: Run e2e to verify it passes**
  Run: `bash tests/run.sh`.
  Expected: the two new scenarios pass; all existing scenarios still pass.

- [x] **Step 5: Commit**
  `git commit -am "feat: apply task :extra-paths and :extra-deps to :run steps"`

### Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Update README**
  In `README.md` `### Tasks (:tasks)` (around line 246), document the two
  optional per-task keys: `:extra-paths` (extra project-relative source
  dirs) and `:extra-deps` (extra coords, same grammar as top-level
  `:deps`) that augment the `-source-paths` for the task's `:run` steps;
  note that an extra-dep overrides a same-named project dep for that task
  only, and that `:sh` steps are unaffected. Add a short EDN example with
  both keys. Add a one-line note that per-task extras are the building
  block for the future `:contexts` roadmap item (so a later reader does
  not assume `:contexts` was dropped). In the Roadmap, change
  `- [ ] :extra-deps/:extra-paths - ad-hoc overrides for custom tasks.`
  to `- [x] ...`.

- [x] **Step 2: Update ARCHITECTURE.md**
  In `docs/ARCHITECTURE.md` `### lgx <task>` (around line 224), note that
  a task may declare `:extra-paths`/`:extra-deps`, that lgx merges the
  extras over the project basis (extra-deps override same-named project
  deps, silently) before resolving, and that the augmented source path
  applies to the task's `:run` steps.

- [x] **Step 3: Verify formatting and run the full suite**
  Run: `make fmt-check && bash tests/run.sh`.
  Expected: formatting clean; all unit + e2e tests pass.

- [x] **Step 4: Commit**
  `git commit -am "docs: document task :extra-paths and :extra-deps"`

---

## Implementation Summary

All four tasks landed as designed.

- `lgx/config.lg`: added `allowed-task-keys` (`#{:doc :do :extra-paths
  :extra-deps}`) + `validate-extra-deps!`, and extended `validate-task!`
  to reject unknown task keys and validate `:extra-paths`
  (`validate-paths!`) / `:extra-deps` (map of `validate-coord!`). Added
  the pure public `merge-coords [project-pairs extra-pairs]` — extras
  override a same-named project coord in place, new extras appended,
  order preserved; deduped before `ensure-all!` so the override is silent.
- `lgx.lg`: extracted `basis [project coords raw-paths]` from
  `project-basis` (which is now its no-extras caller). `cmd-task` merges
  the task's `:extra-deps` over project coords and appends `:extra-paths`
  after project `:paths`, then resolves via `basis`. Extras affect only
  `:run` steps' `-source-paths`; `:sh` steps are untouched.
- `test/lgx/config_test.lg`: 8 validation tests (accept extra-paths /
  extra-deps / both; reject non-vector extra-paths, `..` path, non-map
  extra-deps, bad coord, unknown task key) + 3 `merge-coords` tests
  (no-extras unchanged, new lib appended, collision overrides in place).
- `tests/e2e.sh`: scenario 71 (`:extra-paths` adds a `dev/` source dir so
  a `:run` step resolves `devtool`) and scenario 72 (`:extra-deps` cold-
  fetches a git lib — asserts `installing 1 dep(s)...` and `fib 10` = 55).
- Docs: README `### Tasks` (new `#### Per-task :extra-paths and
  :extra-deps` subsection + strict-keys note + `:contexts` forward
  reference + roadmap tick) and `docs/ARCHITECTURE.md` `### lgx <task>`.

**Verification:** `make fmt-check` clean; `bash tests/run.sh` →
89 unit tests / 118 assertions / 0 failures, 162 e2e assertions passed
(3 new). Second-opinion review via `review-with-codex` (scope: branch vs
master) found no code issues — its only finding was the same-PR doc
update, which Task 4 delivered.
