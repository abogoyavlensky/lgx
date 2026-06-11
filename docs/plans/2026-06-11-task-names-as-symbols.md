# Task Names as Symbols Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change custom task names in `lgx.edn` `:tasks` from keywords (`:ci`) to symbols (`ci`), with a hard validation break that tells keyword users the fix.

**Tech Stack:** let-go (`.lg` sources), lgx mini spec engine (`lgx/spec.lg`), bash e2e suite.

---

## Design

### Why

Symbols reserve the keyword space inside the `:tasks` map for future
tool-level options, the same partition bb.edn uses (user tasks are
symbols; keyword keys like `:init`, `:requires` belong to the tool).
Tasks are commands invoked by bare name (`lgx ci`), so symbols also fit
the Clojure idiom of symbols naming callables. `:contexts` names and
task `:with` references stay keywords — a context is an overlay
(attribute), not a command.

### Migration policy

Hard break, no transition period, no normalization. A keyword task name
becomes a validation error whose message states the fix:

```
task names are symbols; write ci instead of :ci
```

One canonical form; no legacy code path to maintain.

### Components

**1. Validation (`lgx/config.lg`).** Replace `reserved-name-errors`
with `task-name-errors`, used as the `:map-of` key schema. Three cases,
checked in order:

- keyword → `"task names are symbols; write <name> instead of :<name>"`
- any other non-symbol → `"must be a symbol, got <pr-str value>"`
- symbol in `reserved-task-names` → existing
  `conflicts with built-in command "<name>"` message (reserved set and
  its comment are unchanged)

The `:tasks` schema entry becomes
`[:map-of [:fn task-name-errors] task-schema]`. The spec engine already
has a `:symbol` leaf (used by `deps-schema`) and needs no changes.
`with-refs-errors` and `normalize-config` are key-agnostic — untouched.

**2. CLI dispatch and help (`lgx.lg`).** Two swaps: `dispatch` looks up
the argv string with `(symbol cmd)` instead of `(keyword cmd)`, and
`tasks-block` rebuilds keys with `(symbol n)` instead of `(keyword n)`.
`task-line`, `cmd-task`, and `tasks/run-task!` already pass the name
through `name`/strings, so headers and step output need no changes.

**3. Docs.** README Tasks and Contexts sections drop the colon from
task names, the "Task names are keywords" sentence becomes "Task names
are symbols" with a note that contexts remain keywords.
ARCHITECTURE.md's sample validation error updates to the symbol
rendering. `examples/` and the `lgx new` scaffold define no tasks.

### Error handling

The feature *is* an error-handling change (the keyword hint). No other
failure modes change: error paths render through `spec/error->line`,
which prints symbols without a leading colon
(`:tasks lint :do [0] — ...`).

### Testing strategy

Unit tests in `test/lgx/config_test.lg` flip existing task fixtures to
symbol keys and add three new cases: keyword name → hint message,
string name → "must be a symbol" message, reserved symbol names still
rejected. E2E fixtures in `tests/e2e.sh` flip task names in heredoc
configs; the one assertion embedding a rendered task path updates; one
new e2e scenario asserts the keyword-name hint surfaces to the user.

**Commit cadence note:** after Task 1 the e2e suite is red (its
fixtures still use keyword names), so Task 1 has no commit step; the
single code commit lands at the end of Task 2 when `make test` is
green. Task 3 (docs) commits separately.

## File Structure

No new files. Modified:

- `lgx/config.lg` — `task-name-errors` validator; `:tasks` schema entry.
- `lgx.lg` — `dispatch` and `tasks-block` key construction.
- `test/lgx/config_test.lg` — task fixtures and expected paths/messages;
  three new deftests.
- `tests/e2e.sh` — heredoc fixtures with `:tasks`; one path assertion;
  one new scenario.
- `README.md` — Tasks and Contexts sections.
- `docs/ARCHITECTURE.md` — sample error line.

---

### Task 1: Symbol task-name validation in config.lg

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Update existing unit tests and write new failing ones**
  In `test/lgx/config_test.lg`:
  - Flip every task fixture key from keyword to symbol — e.g.
    `{:tasks {:fmt {...}}}` becomes `{:tasks {'fmt {...}}}` (quote the
    symbol in test source so it isn't evaluated). Affected deftests are
    the `load-*` task/step/with tests (roughly lines 244–600; grep
    `:tasks {:` to find every fixture).
  - Update expected error paths to match: `{:path [:tasks :fmt :do]}`
    becomes `{:path [:tasks 'fmt :do]}`.
  - Rewrite `load-rejects-non-keyword-task-name` as
    `load-rejects-keyword-task-name`: fixture `{:tasks {:fmt {:do ...}}}`,
    expected path `[:tasks :fmt]`, msg
    `"task names are symbols; write fmt instead of :fmt"`.
  - Add `load-rejects-non-symbol-task-name`: fixture
    `{:tasks {"fmt" {:do ...}}}`, expected msg
    `"must be a symbol, got \"fmt\""`.
  - Update `load-rejects-reserved-task-names` to build names with
    `(symbol n)` instead of `(keyword n)`; the expected message text is
    unchanged.

- [x] **Step 2: Run unit tests to verify they fail**
  Run from the repo root: `make build && bin/lgx test`
  Expected: FAIL — keyword fixtures now expected to error but still
  pass validation, and the new hint message doesn't exist yet.

- [x] **Step 3: Implement task-name-errors**
  In `lgx/config.lg`, replace `reserved-name-errors` with
  `task-name-errors` — a cond over the three cases from the design
  (keyword hint / non-symbol type error / reserved-name conflict;
  returns nil for a valid name). Change the `:tasks` entry in
  `lgx-schema` from
  `[:map-of [:and :keyword [:fn reserved-name-errors]] task-schema]` to
  `[:map-of [:fn task-name-errors] task-schema]`.

- [x] **Step 4: Run unit tests to verify they pass**
  Run: `make build && bin/lgx test`
  Expected: PASS (e2e not run here; it is red until Task 2).

### Task 2: CLI dispatch, help listing, and e2e suite

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh`

- [x] **Step 1: Switch dispatch and help to symbols**
  In `lgx.lg`: in `dispatch`, change the task lookup key from
  `(keyword cmd)` to `(symbol cmd)`; in `tasks-block`, change
  `(task-line (keyword n) (get t (keyword n)))` to use `(symbol n)`.

- [x] **Step 2: Flip e2e fixtures to symbol task names**
  In `tests/e2e.sh`, every heredoc `lgx.edn` with a `:tasks` map drops
  the colon on task names (grep `:tasks` — about 20 fixtures, e.g.
  `{:tasks {:hello {...}}}` → `{:tasks {hello {...}}}`). Task `:with`
  values and `:contexts` names stay keywords. Update the one assertion
  embedding a rendered task path (scenario around line 2196):
  `":tasks :lint :do [0] — unknown key :shh ..."` becomes
  `":tasks lint :do [0] — unknown key :shh ..."` (fixture key `:lint`
  → `lint` in the same scenario).

- [x] **Step 3: Add e2e scenario for the keyword hint**
  New scenario alongside the invalid-config one: project whose lgx.edn
  has `{:tasks {:ci {:do [{:sh "echo hi"}]}}}`; running any
  config-loading command exits non-zero and output contains
  `task names are symbols; write ci instead of :ci`. Follow the
  existing scenario style (`set +e` … `assert_contains`).

- [x] **Step 4: Run the full suite**
  Run: `make test`
  Expected: PASS (unit + e2e). Note: if the macOS shell shares this
  checkout, avoid running `make test` there concurrently — parallel
  runs clobber `bin/lgx`.

- [x] **Step 5: Commit**
  `git commit -m "Change task names from keywords to symbols"`
  (covers Task 1 + Task 2 changes; see commit cadence note above).

### Task 3: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Update README Tasks and Contexts sections**
  In the `### Tasks (:tasks)` section: drop the colon from task names
  in both edn examples (`:lint`/`:ci`/`:greet` and `:repl`); change
  "Task names are keywords" to "Task names are symbols" and add that
  context names (and `:with` references) remain keywords. In the
  `### Contexts (:contexts)` section, fix the task key in the example
  (`:repl` → `repl`); the `:dev`/`:test` context names stay.

- [x] **Step 2: Update ARCHITECTURE.md sample error**
  The sample validation error line (around line 96) changes from
  `:tasks :lint :do [0] — unknown key :shh ...` to
  `:tasks lint :do [0] — unknown key :shh ...`. Skim the file's other
  `:tasks` mentions for stale keyword task names.

- [x] **Step 3: Verify docs mention no keyword task names**
  Run: `grep -rn ':tasks {:' README.md docs/ARCHITECTURE.md examples/`
  Expected: no matches.

- [x] **Step 4: Commit**
  `git commit -m "Document task names as symbols"`

---

## Status: COMPLETED (2026-06-11)

Implemented across three commits on `task-as-symbols`:

- `086e220` — validation (`task-name-errors` keyword hint / type error /
  reserved check), CLI dispatch and help via `(symbol ...)`, unit and e2e
  fixtures flipped, new hint scenario.
- `b6fe69b` — README Tasks/Contexts sections and ARCHITECTURE.md updated.
- `7d01c85` — follow-up from codex review: namespaced task names
  (`foo/bar`) handled correctly — the migration hint keeps the namespace
  (`(subs (str k) 1)`, not `(name k)`), the reserved-name check compares
  the full printed name so `foo/run` is not rejected, and help iterates
  task keys directly instead of rebuilding them from `(name k)`. Relies
  on let-go's `(symbol "foo/bar")` parsing the namespace (verified;
  unlike JVM Clojure).

Final state: 302 unit tests / 437 assertions, 231 e2e assertions, all
passing. Codex review of the full branch: no diff-introduced issues.
