# Suppress source-paths warning Implementation Plan

> **Status:** ✅ Complete — all tasks implemented and verified (2026-06-09).

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` on every `lg` spawn, with the same lifecycle and verbose-trace visibility as `LG_READ_CLJ=1`.

**Tech Stack:** let-go (`.lg`), bash e2e harness.

---

## Design

lgx always hands `lg` an explicit `-source-paths` built from resolved lib
paths, and that list deliberately omits `.`. On let-go builds that carry the
transition notice (`lg.go:637-647`), every spawn therefore prints
`WARNING: the current directory (".") is no longer added…` to stderr. The
notice's author anticipated exactly this consumer — "Tooling that owns the
search path deliberately omits '.' and can set
`LG_SUPPRESS_SOURCE_PATHS_WARNING` to silence this" — so lgx sets it
unconditionally, mirroring `LG_READ_CLJ=1`.

`LG_READ_CLJ` lives in two places in `lgx/runner.lg`:

1. The `os/setenv` call in `run-lg!` (the actual export, placed before the
   verbose trace so the env line reflects it).
2. The `lgx-set-env-names` vector, which drives the `--verbose` `+ env …`
   trace line.

The new var joins both, inserted **between** `LG_READ_CLJ` and `LGX_RUN`, so
the verbose line reads `+ env LG_READ_CLJ=1 LG_SUPPRESS_SOURCE_PATHS_WARNING=1
[LGX_RUN=1]`.

**Why existing tests keep passing.** `env-trace-line` emits only the vars
present and non-blank in its `lookup` map. The current unit tests pass maps
that omit the new name, and the e2e `assert_contains` checks match substrings
that the new var does not disturb. New coverage is added rather than rewriting
those.

**Error handling / edge cases.** None new. The export is unconditional; on an
older `lg` without the warning the var is simply unread. The "no WARNING on
stderr" e2e assertion is guarded by `supports_source_paths` and stays correct
even against an `lg` that never emitted the warning (absence trivially holds).

## File Structure

- `lgx/runner.lg` — modify. Add the `os/setenv` export in `run-lg!`; add the
  name to `lgx-set-env-names`; refresh the order-comment above the def.
- `test/lgx/runner_test.lg` — modify. New `deftest` locking the trace-line
  ordering of all three vars.
- `tests/e2e.sh` — modify. New Scenario 88: child sees the var, and a plain
  `lgx run` emits no `WARNING:` line.
- `README.md` — modify. The `--verbose` `+ env` bullet names the second var.
- `docs/ARCHITECTURE.md` — modify. External-dependencies `lg` note names it.

## Implementation Steps

### Task 1: Export the var and list it in the trace order

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [x] **Step 1: Write the focused unit test**
  In `test/lgx/runner_test.lg`, add a `deftest` (e.g.
  `env-trace-line-includes-suppress-warning`) asserting:
  `(runner/env-trace-line {"LG_READ_CLJ" "1" "LG_SUPPRESS_SOURCE_PATHS_WARNING" "1" "LGX_RUN" "1"})`
  → `"+ env LG_READ_CLJ=1 LG_SUPPRESS_SOURCE_PATHS_WARNING=1 LGX_RUN=1\n"`.
  This pins the insertion position (between `LG_READ_CLJ` and `LGX_RUN`).

- [x] **Step 2: Run the focused test (expect red)**
  Run: `lgx test`
  Expected: the new assertion fails because the var is not yet in
  `lgx-set-env-names`; existing assertions still pass.
  Result: 268 tests, 365 assertions, 1 failure — only
  `env-trace-line-includes-suppress-warning`.

- [x] **Step 3: Implement the change**
  In `lgx/runner.lg`:
  - Add `"LG_SUPPRESS_SOURCE_PATHS_WARNING"` to `lgx-set-env-names`, between
    `"LG_READ_CLJ"` and `"LGX_RUN"`. Update the comment above the def to name
    the new var and its purpose (suppresses lg's source-paths transition
    notice; lgx owns the search path).
  - In `run-lg!`, immediately after the existing
    `(os/setenv "LG_READ_CLJ" "1")`, add
    `(os/setenv "LG_SUPPRESS_SOURCE_PATHS_WARNING" "1")` with a one-line
    comment pointing at `lg.go`'s warning (lgx's explicit `-source-paths`
    omits `.`).

- [x] **Step 4: Run verification**
  Run: `lgx test`
  Expected: all unit tests pass, including the new ordering assertion.
  Result: 268 tests, 365 assertions, 0 failures.

### Task 2: End-to-end coverage

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add Scenario 88**
  Mirror Scenario 60's structure, guarded by `supports_source_paths`:
  - **Child sees the var.** `lgx run -e '(println (os/getenv
    "LG_SUPPRESS_SOURCE_PATHS_WARNING"))'` with stdout captured (stderr
    discarded); first line must equal `1`.
  - **No warning on stderr.** Run a plain `lgx run` (e.g.
    `-e '(println 1)'`) in a minimal project, capture **stderr**, and assert
    it does **not** contain `WARNING` via `assert_not_contains`.
  Added a `skip` branch for the non-`supports_source_paths` case.
  Codex review fix: the project's `lgx.edn` uses `{:paths ["."]}` (not `{}`),
  so lgx actually emits `-source-paths` (an absolute dir). With `{}`,
  `config/paths` is empty, lgx omits the flag, and lg never warns — the
  assertion would pass vacuously. Verified raw `lg -source-paths <dir>` fires
  the warning without the var and is silenced with it.

- [x] **Step 2: Run the e2e suite**
  Run: `make build && bash tests/e2e.sh` (rebuild first so e2e exercises the
  fixed bundle, matching `tests/run.sh`).
  Result: Scenario 88's 3 assertions pass; full suite green (199 assertions).

### Task 3: Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Update README**
  In the `--verbose` `+ env` bullet, note that lgx also exports
  `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` (silences lg's source-paths transition
  notice, since lgx always passes an explicit `-source-paths`).

- [x] **Step 2: Update ARCHITECTURE**
  In the External-dependencies `lg` note, add the second exported var
  alongside the `LG_READ_CLJ=1` sentence.

- [x] **Step 3: Verify docs render**
  Run: `grep -n "LG_SUPPRESS_SOURCE_PATHS_WARNING" README.md docs/ARCHITECTURE.md`
  Result: README.md:106 and docs/ARCHITECTURE.md:430 each name the var once.

---

## Implementation Summary

All three tasks landed and were verified end-to-end via `bash tests/run.sh`
(rebuild + unit + e2e): **268 unit tests / 365 assertions / 0 failures**, plus
**199 e2e assertions** passing.

**What changed:**

- `lgx/runner.lg` — `run-lg!` now calls
  `(os/setenv "LG_SUPPRESS_SOURCE_PATHS_WARNING" "1")` right after the
  `LG_READ_CLJ` export, and the name was inserted into `lgx-set-env-names`
  between `LG_READ_CLJ` and `LGX_RUN` (drives the `--verbose` `+ env …`
  line). Comments above both spots explain why (lgx owns the search path and
  always passes an explicit `-source-paths` that omits `.`).
- `test/lgx/runner_test.lg` — new `env-trace-line-includes-suppress-warning`
  deftest pinning the three-var trace order.
- `tests/e2e.sh` — new Scenario 88: the child `lg` sees the var, and a plain
  `lgx run` emits no `WARNING:` on stderr.
- `README.md`, `docs/ARCHITECTURE.md` — both now document the second exported
  var.

**Issues encountered / notes:**

- **Codex review caught a vacuous test.** The first draft of Scenario 88 used
  `lgx.edn = {}`, which leaves `config/paths` empty, so lgx omits
  `-source-paths` entirely and lg never warns — the assertion would pass
  regardless of the fix. Changed to `{:paths ["."]}` so lgx emits an absolute
  `-source-paths` (never literal `.`), genuinely exercising the warning path.
  Verified independently: raw `lg -source-paths <dir>` prints the warning
  without the var and is silent with it.
- The `bin/lgx` bundle must be rebuilt (`make build`) before the new
  suppression takes effect at runtime; `tests/run.sh` already rebuilds first,
  so the canonical suite covers this.
