# Run help and other config-free commands without `lgx.edn` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow commands that don't strictly need an `lgx.edn` (`lgx`, `lgx help`/`-h`/`--help`, unknown-command error) to work outside any project directory instead of dying with `error: no lgx.edn found in this or any parent directory`.

**Tech Stack:** let-go (`.lg`), bundled lgx CLI, existing bash-based e2e harness in `tests/e2e.sh`.

---

## Design

### Root cause

`lgx/config.lg:8` defines `find-project!` to exit the process via `(os/exit 1)` when no `lgx.edn` is found walking up from CWD. `lgx.lg:261-262` tries to recover via:

```clojure
(defn- try-find-project []
  (try (config/find-project!) (catch _ nil)))
```

…but `os/exit` is not a catchable exception in let-go — the process terminates before `catch` runs. So every path through `try-find-project` (currently `print-usage!` and `lookup-task`) implicitly requires `lgx.edn` despite the wrapper's intent.

### Affected commands

Broken outside a project today, fixed by this change:

- `lgx` (no args) — dispatches to `print-usage!`
- `lgx help` / `lgx -h` / `lgx --help` — dispatch to `print-usage!`
- `lgx <unknown>` — `lookup-task` dies before the "not a lgx command" message can print

Already work outside a project (no change): `version`/`-v`/`--version`, `new <name>`.

Commands that legitimately require `lgx.edn` keep their current behavior (`install`, `run`, `build`, `test`, user tasks via `find-project!`).

### Fix

Split `find-project!` into:

- `find-project` — returns the project root dir or `nil`
- `find-project!` — calls `find-project`; exits with the same message if `nil`

In `lgx.lg`, delete `try-find-project` and replace its two call sites with `config/find-project`. The `try/catch` was load-bearing only against the broken assumption; with a nil-returning variant it's unnecessary.

### Testing

E2E coverage is the natural fit — `find-project` walks the real filesystem, and the bug is a process-level behavior. Add a scenario in `tests/e2e.sh` that `cd`s into a tmpdir with no `lgx.edn` and asserts each fixed command exits with the right code and prints the right output.

Skip a unit test in `test/lgx/config_test.lg` — the existing tests in that file are all pure validation; introducing FS setup just for one helper isn't worth it.

### Out of scope

- The missing-`lgx.edn` error in `find-project!` uses `println` (stdout). Routing to `*err*` is a separate cleanup.
- No "hint" text like "run `lgx new` to scaffold a project" — keeps the change minimal.

---

## File Structure

- Modify: `lgx/config.lg` — add `find-project`, refactor `find-project!` to delegate.
- Modify: `lgx.lg` — drop `try-find-project`, call `config/find-project` directly from `print-usage!` and `lookup-task`.
- Modify: `tests/e2e.sh` — add a new scenario covering the four fixed cases plus a `version` regression check.

---

## Implementation Steps

### Task 1: Split `find-project!` in `lgx/config.lg`

**Files:**
- Modify: `lgx/config.lg`

- [ ] **Step 1: Add `find-project` and refactor `find-project!`**
  Replace the current `find-project!` definition with two functions. `find-project` walks up from `(os/cwd)` looking for `lgx.edn` and returns the directory or `nil` (no side effects). `find-project!` calls `find-project`; if the result is `nil`, it prints the existing `error: no lgx.edn found in this or any parent directory` line and `(os/exit 1)`; otherwise it returns the dir. Keep the existing error message verbatim so callers that rely on this output are unaffected.

### Task 2: Drop `try-find-project` in `lgx.lg`

**Files:**
- Modify: `lgx.lg`

- [ ] **Step 1: Replace `try-find-project` call sites**
  Delete the `try-find-project` definition at `lgx.lg:261-262`. Update `print-usage!` (`lgx.lg:264-266`) and `lookup-task` (`lgx.lg:268-273`) to call `config/find-project` directly. No `try/catch` needed — `config/find-project` returns `nil` when there's no project.

### Task 3: Add e2e coverage for config-free commands

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Add a "no-project" scenario**
  Append a new numbered scenario near scenarios 1-3 (`version`, `help`, unknown command). Create a tmpdir with no `lgx.edn` and run from inside it:
  - `lgx help` → exit 0, output contains `Usage:` and `lgx install`
  - `lgx --help` → exit 0, output contains `Usage:`
  - `lgx -h` → exit 0, output contains `Usage:`
  - `lgx` (no args) → exit 1, stdout/stderr contains `Usage:` and does NOT contain `no lgx.edn`
  - `lgx nope` → exit 1, stderr contains `lgx: 'nope' is not a lgx command.` (not the missing-config error)
  - `lgx version` → exit 0, output contains `lgx ` (regression check that already-working path is unaffected)

  Use the existing `assert_contains` / `assert_not_contains` helpers and the `set +e; …; rc=$?; set -e` pattern from scenario 3 to capture non-zero exits.

### Task 4: Build and run the full e2e suite

**Files:**
- None modified.

- [ ] **Step 1: Rebuild the bundled binary**
  Run: `make build` (or the equivalent `lg -b` invocation the project uses — check the `Makefile`)
  Expected: builds `bin/lgx` without errors.

- [ ] **Step 2: Run the e2e suite**
  Run: `bash tests/e2e.sh`
  Expected: all scenarios pass, including the new no-project scenario from Task 3.

- [ ] **Step 3: Run unit tests**
  Run: `lgx test` (from the lgx project root)
  Expected: all existing tests still pass — no unit test changes were made, this is a regression check.
