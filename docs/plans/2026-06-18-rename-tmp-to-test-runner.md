# Rename `$LGX_HOME/tmp` → `$LGX_HOME/test-runner` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `$LGX_HOME/tmp` directory to `$LGX_HOME/test-runner` so its name reflects its sole purpose — holding the generated test-runner harness.

**Tech Stack:** let-go (Clojure dialect, `.lg` files), bash e2e harness, Markdown docs.

---

## Design

### Background

`$LGX_HOME/tmp` holds exactly one kind of file: the one-shot test harness
`lgx-test-<version>.lg` that `lgx test` regenerates on every run. The
directory is defined in one place (`lgx/home.lg`, the `tmp-dir` fn) and
consumed in one place (`lgx/test_runner.lg`). The name `tmp` is vague, and
`task-runner` (an earlier suggestion) was rejected because lgx already has a
distinct **tasks** concept (`lgx/tasks.lg`, the `=> Running task <name>`
headers), so `task-runner` would collide with existing terminology.
`test-runner` matches both the directory's contents and the producing module
name (`test_runner.lg`).

### Approach

A literal rename (`"tmp"` → `"test-runner"`) plus a name/doc fan-out:

- Rename the fn `home/tmp-dir` → `home/test-runner-dir` (the directory is
  exclusively the test runner's scratch; a fn named `tmp-dir` pointing at
  `test-runner/` would mislead). Updates its one caller.
- Update unit tests, the e2e scenario that asserts the harness path, and the
  living docs (README, ARCHITECTURE).

### Non-goals (deliberate calls)

- **No migration / cleanup of an old `~/.lgx/tmp/`.** The directory is pure
  regenerated scratch — a stale `tmp/` left on a user's machine is harmless,
  and cleanup code is not worth it.
- **Leave historical plan docs untouched** (`docs/plans/2026-05-22-*.md` and
  others mention `$LGX_HOME/tmp`). They record what was true when written;
  editing them rewrites history. Only living docs change.

### Testing strategy

Existing coverage already pins the path in three places (a `home` unit test, a
`test_runner` unit test, and e2e scenario 44). Update those assertions to the
new name and run the full suite (`make test` → bundle, unit, e2e).

## File Structure

- `lgx/home.lg` — defines the directory; rename fn + literal + docstring.
- `lgx/test_runner.lg` — sole caller; update call site + docstring.
- `test/lgx/home_test.lg` — unit test for the fn; update name + assertion.
- `test/lgx/test_runner_test.lg` — unit test for harness path; update literal.
- `tests/e2e.sh` — scenario 44 asserts the harness path; update path + messages.
- `README.md` — `lgx test` details, env-var table, state-layout tree.
- `docs/ARCHITECTURE.md` — test-runner write-path, state-layout tree, prose.

---

### Task 1: Rename the directory in source + unit tests

**Files:**
- Modify: `lgx/home.lg`
- Modify: `lgx/test_runner.lg`
- Test: `test/lgx/home_test.lg`
- Test: `test/lgx/test_runner_test.lg`

- [ ] **Step 1: Update the unit test assertions (failing first)**
  In `test/lgx/home_test.lg`: rename `deftest tmp-dir-lives-under-lgx-home`
  → `test-runner-dir-lives-under-lgx-home`, change the call `(home/tmp-dir)`
  → `(home/test-runner-dir)`, and the expected path
  `(path/join "/tmp/lgx-home-test" "tmp")` → `… "test-runner")`.
  In `test/lgx/test_runner_test.lg` (`write-harness-uses-versioned-stable-path`,
  ~line 334): change `(path/join home "tmp" …)` → `(path/join home "test-runner" …)`.

- [ ] **Step 2: Run unit tests to verify they fail**
  Run: `make build >/dev/null && bin/lgx test`
  Expected: FAIL — `home/test-runner-dir` is unresolved and/or the path
  assertions mismatch (`test-runner` vs `tmp`).

- [ ] **Step 3: Rename the fn and the directory literal**
  In `lgx/home.lg`: rename `tmp-dir` → `test-runner-dir`, change
  `(path/join (root) "tmp")` → `(path/join (root) "test-runner")`, and update
  the docstring (e.g. "Return the directory for the generated test-runner
  harness.").
  In `lgx/test_runner.lg`: update the `temp-path` call site
  `(home/tmp-dir)` → `(home/test-runner-dir)` and the `write-harness!`
  docstring "under LGX_HOME/tmp" → "under LGX_HOME/test-runner".

- [ ] **Step 4: Run unit tests to verify they pass**
  Run: `make build >/dev/null && bin/lgx test`
  Expected: PASS (all unit tests green).

- [ ] **Step 5: Commit**
  `git commit -am "Rename LGX_HOME/tmp to LGX_HOME/test-runner"`

### Task 2: Update the e2e harness-path assertion

**Files:**
- Modify: `tests/e2e.sh` (scenario 44, ~lines 939–944)

- [ ] **Step 1: Update the path and assertion messages**
  Change `harness="$home_t6/tmp/lgx-test-$version.lg"`
  → `harness="$home_t6/test-runner/lgx-test-$version.lg"`. Update the two
  human-readable strings that say `LGX_HOME/tmp` →
  `LGX_HOME/test-runner` (the `assert_contains` label and the `pass` message).
  Leave the `$harness` variable-based assertions as-is — they follow the path.

- [ ] **Step 2: Run e2e to verify scenario 44 passes**
  Run: `make build >/dev/null && bash tests/e2e.sh`
  Expected: PASS — scenario 44 writes the harness under `test-runner/` and the
  path assertion matches.

- [ ] **Step 3: Commit**
  `git commit -am "Update e2e harness-path assertion for test-runner rename"`

### Task 3: Update living docs

**Files:**
- Modify: `README.md` (lines ~188, ~538, ~551)
- Modify: `docs/ARCHITECTURE.md` (lines ~295, ~517, ~523)

Use /writing-clearly for the prose edits.

- [ ] **Step 1: Update README**
  - `lgx test` details (~188): "a one-shot harness under `$LGX_HOME/tmp/`"
    → `$LGX_HOME/test-runner/`.
  - Env-var table `LGX_HOME` row (~538): "the test harness tmp dir"
    → "the test-runner harness dir".
  - State-layout tree (~551): `tmp/lgx-test-<version>.lg`
    → `test-runner/lgx-test-<version>.lg`.

- [ ] **Step 2: Update ARCHITECTURE**
  - Write-path prose (~295): `$LGX_HOME/tmp/lgx-test-<version>.lg`
    → `$LGX_HOME/test-runner/lgx-test-<version>.lg`.
  - State-layout tree (~517): `tmp/lgx-test-<version>.lg`
    → `test-runner/lgx-test-<version>.lg`.
  - Prose (~523): "The `tmp` directory holds generated lgx…"
    → "The `test-runner` directory holds generated lgx…".

- [ ] **Step 3: Verify no stale references remain in living files**
  Run: `grep -rn 'LGX_HOME/tmp\|(root) "tmp"\|home "tmp"\|/tmp/lgx-test-\|tmp-dir' lgx/ test/ tests/ README.md docs/ARCHITECTURE.md`
  Expected: no matches. (Hits inside `docs/plans/` and unrelated system
  `/tmp/...` scratch paths are out of scope and stay.)

- [ ] **Step 4: Run the full suite as a final check**
  Run: `make test`
  Expected: "All tests passed."

- [ ] **Step 5: Commit**
  `git commit -am "Update docs for LGX_HOME/test-runner rename"`
