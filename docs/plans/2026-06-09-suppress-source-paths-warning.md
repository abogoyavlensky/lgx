# Suppress source-paths warning Implementation Plan

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

- [ ] **Step 1: Write the focused unit test**
  In `test/lgx/runner_test.lg`, add a `deftest` (e.g.
  `env-trace-line-includes-suppress-warning`) asserting:
  `(runner/env-trace-line {"LG_READ_CLJ" "1" "LG_SUPPRESS_SOURCE_PATHS_WARNING" "1" "LGX_RUN" "1"})`
  → `"+ env LG_READ_CLJ=1 LG_SUPPRESS_SOURCE_PATHS_WARNING=1 LGX_RUN=1\n"`.
  This pins the insertion position (between `LG_READ_CLJ` and `LGX_RUN`).

- [ ] **Step 2: Run the focused test (expect red)**
  Run: `lgx test`
  Expected: the new assertion fails because the var is not yet in
  `lgx-set-env-names`; existing assertions still pass.

- [ ] **Step 3: Implement the change**
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

- [ ] **Step 4: Run verification**
  Run: `lgx test`
  Expected: all unit tests pass, including the new ordering assertion.

### Task 2: End-to-end coverage

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Add Scenario 88**
  Mirror Scenario 60's structure, guarded by `supports_source_paths`:
  - **Child sees the var.** `lgx run -e '(println (os/getenv
    "LG_SUPPRESS_SOURCE_PATHS_WARNING"))'` with stdout captured (stderr
    discarded); first line must equal `1`.
  - **No warning on stderr.** Run a plain `lgx run` (e.g.
    `-e '(println 1)'`) in a minimal project, capture **stderr**, and assert
    it does **not** contain `WARNING` (use the existing negative-assertion
    helper / `grep -qv` idiom already used in the suite).
  Add a `skip` branch for the non-`supports_source_paths` case.

- [ ] **Step 2: Run the e2e suite**
  Run: `bash tests/e2e.sh`
  Expected: Scenario 88 passes; full suite green (assertion count rises).

### Task 3: Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update README**
  In the `--verbose` `+ env` bullet, note that lgx also exports
  `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` (silences lg's source-paths transition
  notice, since lgx always passes an explicit `-source-paths`).

- [ ] **Step 2: Update ARCHITECTURE**
  In the External-dependencies `lg` note, add the second exported var
  alongside the `LG_READ_CLJ=1` sentence.

- [ ] **Step 3: Verify docs render**
  Run: `grep -n "LG_SUPPRESS_SOURCE_PATHS_WARNING" README.md docs/ARCHITECTURE.md`
  Expected: each file names the var exactly once in the relevant note.
