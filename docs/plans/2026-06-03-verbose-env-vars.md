# Verbose Env Vars Implementation Plan — ✅ COMPLETED

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `--verbose` output to print, on a separate `+ env …` line, the environment variables lgx sets for itself and for `lg`.

**Tech Stack:** let-go (Clojure dialect, `.lg`), bash e2e harness.

---

## Design

**Scope.** Print only the vars lgx actively writes into the environment:
`LG_READ_CLJ` (set for the `lg` child) and `LGX_RUN` (lgx's own
run-marker). Vars lgx merely *reads* (`LGX_LG`, `LGX_HOME`, template vars)
are out of scope.

**Single chokepoint.** `runner/invoke-lg!` is where every `lg` invocation
flows through and where the `+ …` command trace already prints. Both vars
are observable there:
- `LG_READ_CLJ` is set inside `invoke-lg!` itself.
- `LGX_RUN` is set by callers (`cmd-run` in `lgx.lg`, `:run` task steps in
  `tasks.lg`) *before* `invoke-lg!` runs, so it is already in the
  environment.

Adding the env line here covers `run`, `build`, `test`, and user tasks for
free — no per-command changes.

**Reflect reality, don't hardcode.** A pure helper `env-trace-line` takes a
name→value lookup fn and an ordered list of var names, keeps the non-blank
ones, and formats a single line. `invoke-lg!` passes `os/getenv` as the
lookup. Consequences:
- `run` shows `+ env LG_READ_CLJ=1 LGX_RUN=1`.
- `build`/`test` show `+ env LG_READ_CLJ=1` (those paths never set
  `LGX_RUN`).
- A task step that restores `LGX_RUN` to `""` drops it from the line
  (`str/blank?` filters it), matching the real child environment.

Making the helper take a lookup fn (rather than calling `os/getenv`
directly) keeps it pure and unit-testable with a plain map — no global env
mutation in tests. A map doubles as the lookup fn: `({"LGX_RUN" "1"}
"LGX_RUN")` returns the value, missing keys return `nil`, and `str/blank?`
is nil-safe (same pattern already used by `lg-binary`).

**One ordering fix.** Today `(os/setenv "LG_READ_CLJ" "1")` runs *after*
the trace print. Move it to the top of `invoke-lg!` so the env line
reflects it. No behavior change for `lg` — it is set before `os/sh` either
way; the existing explanatory comment moves with it.

**Output shape:**
```
+ env LG_READ_CLJ=1 LGX_RUN=1
+ lg -source-paths /a/b -e '(println :ok)'
```

**Testing.** The pure `env-trace-line` is covered by a focused unit test
(map lookups, ordering, blank-filtering, empty case). The end-to-end wiring
is covered by extending the existing verbose e2e scenarios (12 for `run`,
30 for `build`).

## File Structure

- Modify: `lgx/runner.lg` — add `lgx-set-env-names` + pure `env-trace-line`
  helper; reorder `invoke-lg!` to set `LG_READ_CLJ` first and print the env
  line before the command line.
- Create: `test/lgx/runner_test.lg` — unit tests for `env-trace-line`.
- Modify: `tests/e2e.sh` — add env-line assertions to scenarios 12 and 30.
- Modify: `README.md` — extend the `--verbose` description (around line 97).
- Modify: `lgx.lg` — extend the `--verbose` usage string (line 29).

## Implementation Steps

### Task 1: Pure env-trace-line helper in runner.lg

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [x] **Step 1: Write the focused unit test**
  Create `test/lgx/runner_test.lg` (ns `lgx.runner-test`, requiring
  `lgx.runner` and the test framework — mirror an existing test such as
  `test/lgx/home_test.lg`). Assert `env-trace-line` behavior using map
  lookups, no global env:
  - `(env-trace-line {"LG_READ_CLJ" "1" "LGX_RUN" "1"})` →
    `"+ env LG_READ_CLJ=1 LGX_RUN=1\n"` (LG_READ_CLJ first).
  - `(env-trace-line {"LG_READ_CLJ" "1"})` → `"+ env LG_READ_CLJ=1\n"`
    (LGX_RUN absent when blank/missing).
  - `(env-trace-line {"LG_READ_CLJ" "" "LGX_RUN" ""})` → `nil`
    (all blank → no line).

- [x] **Step 2: Run the focused test (expected: fail)**
  Run: `bash tests/run.sh`
  Expected: the new `lgx.runner-test` assertions fail (helper not defined
  yet); other tests still pass.
  Result: test file failed to compile — `Can't resolve
  runner/env-trace-line` (expected red).

- [x] **Step 3: Implement the helper**
  In `lgx/runner.lg`, add an ordered name list and a pure formatter:
  - `(def ^:private lgx-set-env-names ["LG_READ_CLJ" "LGX_RUN"])` — the
    vars lgx sets, in display order.
  - `env-trace-line [lookup]` (public so the test can call it): map each
    name through `lookup`, keep `NAME=VALUE` for non-blank values
    (`str/blank?`), and return `"+ env <joined>\n"` or `nil` when none.
    Reuse `str/join`. Keep it free of `os/getenv` so it stays pure.

- [x] **Step 4: Run verification**
  Run: `bash tests/run.sh`
  Expected: all unit + e2e tests pass.
  Result: 192 tests, 269 assertions, 0 failures (4 new env-trace-line
  tests green).

### Task 2: Wire env line into invoke-lg! and reorder LG_READ_CLJ

**Files:**
- Modify: `lgx/runner.lg`
- Test: `tests/e2e.sh`

- [x] **Step 1: Extend the e2e assertions**
  In `tests/e2e.sh`:
  - Scenario 12 (`--verbose run`): assert the captured stderr contains
    `+ env ` and `LG_READ_CLJ=1` and `LGX_RUN=1`.
  - Scenario 30 (`--verbose build`): assert stderr contains `+ env ` and
    `LG_READ_CLJ=1`, and assert it does **not** contain `LGX_RUN`
    (`assert_not_contains` already exists in the harness).

- [x] **Step 2: Run the e2e tests (expected: fail)**
  Run: `bash tests/run.sh`
  Expected: the new scenario 12/30 assertions fail (env line not emitted
  yet).
  Result: scenario 12 failed on `+ env ` assertion (expected red).

- [x] **Step 3: Implement the wiring**
  In `invoke-lg!` (`lgx/runner.lg`):
  - Move `(os/setenv "LG_READ_CLJ" "1")` (with its explanatory comment) to
    the top of the fn, before the `let`.
  - Inside the `(when verbose? …)` block, before the existing
    `+ <bin> <args>` print, emit the env line:
    `(when-let [line (env-trace-line os/getenv)] (write! *err* line))`.

- [x] **Step 4: Run verification**
  Run: `bash tests/run.sh`
  Expected: all unit + e2e tests pass (scenarios 12 and 30 green).
  Result: all 151 e2e assertions passed (+5 new); env line renders as
  `+ env LG_READ_CLJ=1 LGX_RUN=1` on run, `+ env LG_READ_CLJ=1` on build.

### Task 3: Update docs for the new verbose output

**Files:**
- Modify: `README.md`
- Modify: `lgx.lg`

- [x] **Step 1: Update README**
  In `README.md` (the `--verbose` paragraph near line 97), add that
  `--verbose` also prints a `+ env …` line listing the env vars lgx sets:
  `LG_READ_CLJ=1` for every `lg` invocation, plus `LGX_RUN=1` on `run`
  paths.

- [x] **Step 2: Update the usage string**
  In `lgx.lg` (the `--verbose` line in the usage text, line 29), note that
  it prints the env vars lgx sets alongside the `lg` invocation.

- [x] **Step 3: Verify formatting and run full suite**
  Run: `make fmt-check && bash tests/run.sh`
  Expected: formatting clean; all tests pass.
  Result: formatting clean; all 151 e2e assertions + unit tests pass.

---

## Implementation Summary

All three tasks landed as designed.

- `lgx/runner.lg`: added `lgx-set-env-names` (`["LG_READ_CLJ" "LGX_RUN"]`)
  and the pure `env-trace-line` helper (takes a lookup fn, keeps non-blank
  vars in order, returns the `+ env …\n` line or `nil`). Reordered
  `invoke-lg!` so `LG_READ_CLJ` is set at the top, and emit the env line
  before the existing command trace under `--verbose`.
- `test/lgx/runner_test.lg` (new): 4 unit tests for `env-trace-line` using
  map lookups — order, missing var, blank var, all-blank → nil.
- `tests/e2e.sh`: scenario 12 (`run`) asserts the env line shows both
  `LG_READ_CLJ=1` and `LGX_RUN=1`; scenario 30 (`build`) asserts
  `LG_READ_CLJ=1` and that `LGX_RUN` is absent.
- Docs: README `--verbose` paragraph and the `lgx.lg` usage string.

Verified output:
```
+ env LG_READ_CLJ=1 LGX_RUN=1     # run / :run task paths
+ env LG_READ_CLJ=1               # build / test paths (no LGX_RUN)
```

**Verification:** `make fmt-check` clean; `bash tests/run.sh` →
192 unit tests / 269 assertions / 0 failures, 151 e2e assertions passed.
Second-opinion review via `review-with-codex` (scope: uncommitted)
returned no actionable issues.

**Notes / issues encountered:**
- A test file that fails to *compile* (e.g. referencing an undefined fn)
  prints the error but the harness still exits 0 — so the "red" step
  showed up only in stderr, not as a non-zero exit. Pre-existing harness
  behavior, unrelated to this change, but worth knowing when writing
  failing-first tests.
- Changes are left uncommitted (the plan doc itself was committed earlier
  by liteplan). Commit when ready.
