# Resilient `lgx test` Harness Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lgx test` survive a test namespace that fails to load: report each load failure by name, run every other namespace normally, and still exit non-zero.

**Tech Stack:** let-go (`.lg`), the bundled lgx CLI, the harness generator in `lgx/test_runner.lg`.

**Status: completed** (2026-09-09) — see the summary at the end.

---

## Design

### Today: all or nothing

`lgx test` generates a single harness file whose `ns` form requires **every** test namespace, then runs them in one `lg` process (`lgx/test_runner.lg`, `harness-header` and `harness-source`). One namespace that will not compile means the harness itself will not compile, so nothing runs and the user sees no results at all.

The motivating case is honeysql under let-go: ten of its twelve test namespaces pass, but `honey.cache-test` and `honey.sql-alphanumeric-test` cannot load (their dependencies need JVM interop let-go lacks). `lgx test` therefore reports nothing, and the only way to see the suite is a hand-written per-file loop.

This is not an error-handling oversight. `cmd-test` (`lgx.lg`) deliberately treats a load failure as fatal, via `harness-ready?` and `load-error-before-harness?`, because a swallowed load failure means "CI passes, hidden tests rot" — the failure mode documented at length in `docs/issues/load-failure-silent.md`. The change below keeps that guarantee. It converts "one bad file hides everything" into "one bad file is one reported failure", which is strictly more informative and equally strict about the exit code.

### The change: a load phase inside the harness

Move the test-namespace requires out of the harness `ns` form and into a load phase in the harness **body**, wrapping each in `try`/`catch`. Keep the ready marker at the **end** of that load phase.

```clojure
(ns lgx.test-harness (:require [test ...] [string :as str] [os :as os]))  ; harness deps only

(def test-plan [["test/foo_test.lg" 'foo-test] ...])

(def load-failures                        ; [[display-file ns-sym message] ...]
  (reduce (fn [acc entry]
            (try (require (second entry)) acc
                 (catch e (conj acc [(first entry) (second entry) (ex-message e)]))))
          []
          test-plan))

(write! *err* "<<<lgx-test-harness-ready>>>")   ; still the load/run boundary

;; helpers, then run phase over the namespaces that loaded, then summary
```

### Why the marker stays at the load/run boundary

This is the load-bearing decision. The marker's contract is "everything on stderr before this line is a load diagnostic; everything after is test output". Emitting it at the end of the load phase preserves that contract exactly, so `harness-ready?` and `load-error-before-harness?` in `cmd-test` keep working unchanged.

That matters because those two functions encode hard-won handling of a let-go behaviour split (`docs/issues/load-failure-silent.md`):

| failure shape | lg 1.11.x | lg 1.12.x |
|---|---|---|
| compile error | swallowed; `error: failed to load …` on stderr; exit 0 | throws |
| reader error mid-file | swallowed; diagnostic on stderr | throws or prints, depending on shape |
| reader error running to EOF | silent, exit 0 | silent, exit 0 |

The only semantic shift is that `harness-ready?` now means "the load phase ran to completion" rather than "every require succeeded". The harness itself reports the individual failures.

### Verified runtime behaviour

Measured against the locally built `lg` (let-go `main`, `dc310b6`), because the design depends on each of these:

| probe | result |
|---|---|
| `(try (require 'broken) (catch e …))` on a compile error | **throws, catchable**; `ex-message` carries lg's diagnostic |
| same, on a load-time runtime error (`(def x (/ 1 0))`) | **throws, catchable** (`"divide by zero"`) |
| `(the-ns 'broken)` after a failed load | **throws** `no namespace: broken found` |
| `*registered-tests*` for a failed namespace | unreachable — `the-ns` throws first |
| `(require ns-sym)` with a runtime symbol local | works |
| unterminated form running to EOF | `require` returns **normally**; namespace exists with partially registered tests; **no stderr at all** |

Two consequences:

1. **There is no partial-registration hazard for throwing failures.** When a namespace fails to load, let-go does not publish it, so its partially registered tests are not reachable and cannot be run by accident. Skipping a failed namespace is therefore about avoiding a crash, not about avoiding stale state.
2. **`the-ns` must be guarded.** Today's run phase calls `(the-ns ns-sym)` unguarded. Left as is, it would throw on the first failed namespace and take the run down — reintroducing the very problem being fixed.

### Reporting and exit code

- Load failures are counted **separately from assertions**. A namespace that would not load is not a failed assertion, and folding the two together would print a misleading `173 tests, 769 assertions, 2 failures`.
- Each failure is printed once up front (right after the marker, in red) and the count is repeated in the summary line, so it is not lost above a long run.
- The exit code is non-zero when there is any assertion failure, any test error, **or** any load failure.

### `cmd-test` is expected to need no change

- **lg 1.12:** our `catch` swallows the error, so lg prints no `error: failed to load` line. `harness-ready?` is true, `load-error-before-harness?` is false, the harness exits 1 on its own, and `cmd-test` passes that exit through. Note the consequence: on this path `cmd-test` no longer prints `"a test file failed to load"`, because the harness reports the failure itself. That is what breaks e2e scenario 68, which Task 3 reconciles.
- **lg 1.11:** `require` does not throw, so our `catch` never fires and the namespace loads partially. But lg prints its diagnostic to stderr before the marker, so `load-error-before-harness?` is true and `cmd-test` forces exit 1 with "a test file failed to load" — identical to today.

Task 3 verifies this rather than assuming it.

### Known limitation, preserved not introduced

The reader-EOF hole stays open: `require` returns normally, the namespace exists with partially registered tests, and lg emits nothing on stderr. It is undetectable from inside the harness and from outside the process, before and after this change. The plan documents it; it does not pretend to close it.

### Self-hosting risk

lgx runs its own unit tests through this harness (`tests/run.sh` calls `bin/lgx test`). A bug in the generated harness breaks lgx's own test run, which can look like a test failure rather than a harness failure. Task 1 therefore rebuilds and runs the unit suite before anything else depends on it.

### Out of scope

An exclude/skip knob (`:test {:exclude [...]}` or `--exclude`). This plan makes the run *informative*, not *silent*. For honeysql the result is `173 tests, 769 assertions, 0 failures` plus 2 named load failures and exit 1, which is the full suite result where today there is none. Turning that green needs either upstream let-go support for the two namespaces or a separate exclude feature, both decided against for now.

## File Structure

| File | Change |
|---|---|
| `lgx/test_runner.lg` | `harness-header` drops the per-entry requires; `harness-body` gains a load phase before the marker and guards the run phase; `harness-source` no longer builds require lines; the load-error comment block and `harness-ready?` docstring are updated to match |
| `test/lgx/test_runner_test.lg` | update the assertions that pin requires to the `ns` form; add coverage for the load phase and the run-phase guard |
| `tests/e2e.sh` | scenario 68: update the moved message assertion, and assert the passing file still runs |
| `docs/issues/load-failure-silent.md` | update the "lgx-side status" section to describe the new behaviour |

`lgx.lg` (`cmd-test`) is expected to be unchanged; Task 3 confirms.

---

### Task 0: Preflight

**Files:** none

- [x] **Step 1: Confirm a green baseline**
  Run: `cd /home/agent/Projects/lgx && make test`
  Expected: unit tests and e2e both pass, ending in `All tests passed.`
  If anything already fails, stop and report — this plan assumes a green tree.

- [x] **Step 2: Reproduce today's all-or-nothing behaviour**
  Create a throwaway project with one passing and one broken test file:
  ```
  /tmp/lgx-resilient/lgx.edn          {}
  /tmp/lgx-resilient/test/ok_test.lg       (ns ok-test …) one passing deftest
  /tmp/lgx-resilient/test/broken_test.lg   (ns broken-test …) references an undefined symbol at top level
  ```
  Run `bin/lgx test` in it.
  Expected: **no results at all** for `ok-test`, and a non-zero exit. Keep this project; Task 2 reuses it to show the difference.

- [x] **Step 3: Record the honeysql baseline**
  Run: `cd ~/Projects/honeysql && LGX_LG=/home/agent/Projects/let-go/bin/lg lgx test 2>&1 | tail -20`
  Expected: aborts on `honey/cache_test.clj` with `unable to load namespace clojure.core.cache.wrapped`, no test results.
  Note: the `lgx` shim has no mise version set outside the lgx repo; use an explicit path such as `~/.local/share/mise/installs/lgx/0.1.0-rc2/lgx`, or the freshly built `bin/lgx`.

---

### Task 1: Move requires into a load phase

**Files:**
- Modify: `lgx/test_runner.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Update the unit tests that pin requires to the `ns` form**
  `harness-source-includes-each-ns` currently asserts the generated source contains `[lgx.config-test]` — the require-line form. That disappears with this change. Rewrite it to assert what the new harness guarantees: the namespace symbol appears in the test plan (`'lgx.config-test`), the display file appears, and the source does **not** put test namespaces in the `ns` form.
  Add a test asserting the load phase exists and is ordered before the marker: the source contains a `try`/`catch` around `require`, and the index of the load-phase form is lower than the index of the marker write.

- [x] **Step 2: Run the unit tests to see them fail**
  Run: `cd /home/agent/Projects/lgx && make build LG="$(mise which lg)" && ./bin/lgx test test/lgx/test_runner_test.lg`
  Expected: FAIL on the new and rewritten assertions.

- [x] **Step 3: Restructure the generated harness**
  In `lgx/test_runner.lg`:
  - `harness-header`: unchanged content, but it is now closed directly — no per-entry require lines are appended.
  - `harness-source`: drop the `extra` require-line construction and the now-unused `require-line`; it becomes header + `"))"` + body, with `__TEST_ENTRIES__` substituted as today.
  - `harness-body`: move `(def test-plan [...])` to the **top** of the body, add the load phase immediately after it, and keep the marker write directly after the load phase. The load phase collects `[display-file ns-sym message]` triples:
    ```clojure
    (def load-failures
      (reduce (fn [acc entry]
                (try (require (second entry)) acc
                     (catch e (conj acc [(first entry) (second entry) (ex-message e)]))))
              []
              test-plan))
    ```
    Everything else (helpers, run phase, summary) stays after the marker for now; Task 2 adjusts it.
  Remember the body is a Clojure **string**: inner quotes need `\"` escaping, matching the surrounding style.

- [x] **Step 4: Run the unit tests**
  Run: `cd /home/agent/Projects/lgx && make build LG="$(mise which lg)" && ./bin/lgx test test/lgx/test_runner_test.lg`
  Expected: PASS.

- [x] **Step 5: Run the whole unit suite through the new harness**
  Run: `cd /home/agent/Projects/lgx && ./bin/lgx test`
  Expected: PASS. This is the self-hosting check — the harness must still be able to run lgx's own tests.

- [x] **Step 6: Commit**
  `git commit -m "Load test namespaces in the harness body, not the ns form"`

> Deviation: the `harness-ready-marker` comment (which said the marker fires
> "after the (ns ... :require ...) form has loaded every test namespace") went
> stale in this task, not Task 2, so it was updated here per AGENTS.md's
> same-commit rule. The two items Task 2 Step 4 names are untouched so far.

---

### Task 2: Skip failed namespaces and report them

**Files:**
- Modify: `lgx/test_runner.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Write the failing tests**
  Add unit tests on `harness-source` asserting the run phase is guarded and the reporting exists:
  - the source references `load-failures` after the marker (reporting), not only before it (collection);
  - the run phase does not call `the-ns` unconditionally — it is reached only for namespaces absent from the failure set;
  - the summary line and the exit condition both account for load failures.
  Assert on the generated source rather than by executing it; the executable coverage is the e2e scenario in Task 4.
  `harness-source-summary-and-exit` currently pins two exact strings that this task changes — `"(println ((if (zero? failures) green red) summary))"` and `"(os/exit (if (zero? failures) 0 1))"`. Update both to the new expressions rather than deleting the assertions; they are what stops the summary and exit drifting apart.

- [x] **Step 2: Run to verify they fail**
  Run: `cd /home/agent/Projects/lgx && make build LG="$(mise which lg)" && ./bin/lgx test test/lgx/test_runner_test.lg`
  Expected: FAIL.

- [x] **Step 3: Guard the run phase and add reporting**
  In `harness-body`, after the marker and the existing colour helpers:
  - derive the failed-namespace set from `load-failures` and skip those entries in the run `doseq`, so `(the-ns ns-sym)` is never called for a namespace that did not load (verified: it throws);
  - print each load failure once, in red, naming the display file and carrying lg's message;
  - extend the summary line with a load-failure count when non-zero, kept **separate** from the assertion counters;
  - make the exit non-zero when `(or (pos? failures) (seq load-failures))`.
  **The summary colour and the final line must use the same condition as the exit.** A run with zero assertion failures but one load failure has to print a red summary and `FAIL`, not a green `OK` alongside exit 1. Derive all three from one expression so they cannot disagree.

- [x] **Step 4: Update the stale comments and docstrings in the same commit**
  `lgx/test_runner.lg` still describes the old design in prose: the "Swallowed load-error detection" comment block, and the `harness-ready?` docstring saying the marker proves "the `(ns … :require …)` above it loaded every test namespace". After this task it means "the load phase ran to completion".
  `AGENTS.md` requires the doc update to land in the same commit as the change it describes, so this is a step here rather than part of Task 5.

- [x] **Step 5: Run the unit tests**
  Run: `cd /home/agent/Projects/lgx && make build LG="$(mise which lg)" && ./bin/lgx test`
  Expected: PASS, whole unit suite.

- [x] **Step 6: Verify against the Task 0 repro**
  Run `bin/lgx test` in `/tmp/lgx-resilient`.
  Expected: `ok-test`'s passing test **is reported**, `broken_test.lg` is named as a load failure, and the exit is non-zero. This is the behaviour change the plan exists for.

- [x] **Step 7: Commit**
  `git commit -m "Skip and report test namespaces that fail to load"`

---

### Task 3: Reconcile `cmd-test` and scenario 68

**Files:** `tests/e2e.sh`; `lgx.lg` (expected unchanged)

Scenario 68 **will fail** after Task 2, deterministically and by design. Confirm the cause before changing anything.

- [x] **Step 1: Run the existing load-failure scenarios and see 68 fail**
  Run: `cd /home/agent/Projects/lgx && bash tests/e2e.sh 2>&1 | grep -E 'Scenario (68|69|70)' -A 8`
  Expected: 69 and 70 pass; **68 fails** on its `assert_contains "$out" "a test file failed to load"`.
  The reason: on lg 1.12 our `catch` swallows the error, so lg prints no `error: failed to load` line. `harness-ready?` is now true (the load phase completed) and the exit is non-zero, so neither branch in `cmd-test` that emits that message fires. The harness reports the failure itself instead.

- [x] **Step 2: Update scenario 68's assertion, not `cmd-test`**
  The message moved from lgx to the harness; the guarantee behind it did not. Replace the `"a test file failed to load"` assertion with one matching the harness's load-failure report, keeping the other three assertions (non-zero exit, the offending file is named, lg's diagnostic is surfaced) exactly as they are.
  Leave `harness-ready?` and `load-error-before-harness?` alone: on lg 1.11 `require` does not throw, lg prints its diagnostic before the marker, and `load-error-before-harness?` is still what forces exit 1. Both paths remain live.

- [x] **Step 3: Confirm `lgx.lg` needs no change**
  Run: `cd /home/agent/Projects/lgx && git diff --stat lgx.lg`
  Expected: empty. If a change to `cmd-test` looks necessary — in particular anything that weakens either detection function — **stop and ask**; they are the documented defence against silent CI passes.

- [x] **Step 4: Re-run the scenarios**
  Run: `cd /home/agent/Projects/lgx && bash tests/e2e.sh 2>&1 | grep -E 'Scenario (68|69|70)' -A 8`
  Expected: all three pass.

> Deviation: scenario **70** needed the same assertion change as 68, which the
> plan did not predict. On lg 1.12.2 a reader error inside a required file
> throws like a compile error, so the load phase catches it too and lgx never
> prints "a test file failed to load". Applied the identical fix — assert
> "failed to load", the phrase both lg versions carry — and left its other two
> assertions and `cmd-test` untouched.

---

### Task 4: Assert the passing file still runs

**Files:**
- Modify: `tests/e2e.sh`

Scenario 68 already sets up exactly the mixed case this change is about: `ok_test.lg` with a passing `deftest` alongside `broken_test.lg`. It just never asserted anything about the passing file, because until now nothing ran. Extend it rather than adding a near-duplicate scenario.

- [x] **Step 1: Add the new guarantee to scenario 68**
  Assert that `ok-test`'s result appears in the output — the passing file is no longer hidden by its broken neighbour. Match on the test's own name so the assertion cannot pass on incidental text.
  Update the scenario's `echo "==> Scenario 68: ..."` line to describe the current behaviour: a broken file is reported and fails the run while the other files still run.

- [x] **Step 2: Run the full suite**
  Run: `cd /home/agent/Projects/lgx && make test`
  Expected: `All tests passed.`

- [x] **Step 3: Commit**
  `git commit -m "Assert lgx test still runs the files that load"`

---

### Task 5: Update the issue doc

**Files:**
- Modify: `docs/issues/load-failure-silent.md`

- [x] **Step 1: Rewrite the "lgx-side status" section**
  Record that the harness now loads each namespace individually and reports failures rather than aborting, and that `harness-ready?` now means "the load phase completed" rather than "every require succeeded". Keep the description of both detection functions, since both still run.
  State plainly that the reader-EOF hole is unchanged and still undetectable, with the probe result as evidence: `require` returns normally, the namespace exists with partially registered tests, and lg emits no stderr.
  The in-file comments and docstrings were already updated in Task 2 Step 4, per `AGENTS.md`'s same-commit rule; this task covers the standalone issue doc, which describes the upstream let-go problem rather than lgx's code.

- [x] **Step 2: Check formatting and commit**
  Run: `cd /home/agent/Projects/lgx && make fmt-check && make lint`
  Expected: `All source files formatted correctly`, and a clean lint.
  `git commit -m "Record the resilient-harness behaviour in the load-failure issue doc"`

> Deviation: `make fmt-check` is clean, but `make lint` exits 123 on two
> warnings that pre-date this work and live in files this branch never touches
> (`lgx/clean.lg:121` unresolved `syscall` ns, `lgx/gobuild.lg:199` unused
> binding). Left them alone rather than widening scope; the change adds no new
> warnings.

---

### Task 6: Verify against honeysql

The real motivating case, and the one that exercises a namespace failing on a *transitive* dependency rather than its own source.

**Files:** none

- [x] **Step 1: Run the honeysql suite through the new lgx**
  Run: `cd ~/Projects/honeysql && LGX_LG=/home/agent/Projects/let-go/bin/lg /home/agent/Projects/lgx/bin/lgx test`
  Expected: **173 tests, 769 assertions, 0 failures**, plus two named load failures (`honey/cache_test.clj` and `honey/sql_alphanumeric_test.clj`), and a non-zero exit.
  Compare against the Task 0 Step 3 baseline, where nothing ran at all.
  If the totals differ from 173/769, stop and report — those numbers are measured on the `lg/inline-str-and-formatv-gate` branch of the fork and should be reproducible exactly.

- [x] **Step 2: Confirm nothing was left behind**
  Run: `cd /home/agent/Projects/lgx && git status --short`
  Expected: clean. Remove `/tmp/lgx-resilient` if still present.


---

## Completion summary

**Implemented.** `lgx test` no longer stops at the first test file that will
not load. The generated harness carries the test namespaces in a `test-plan`
at the top of its body and requires them one at a time inside a `try`,
collecting `[display-file ns-sym message]` triples; the ready marker still
sits at the end of that load phase, so the stderr phase boundary
`harness-ready?` and `load-error-before-harness?` depend on is unchanged. The
run phase runs only the entries that loaded (`the-ns` throws for a namespace
lg never published), the failures are reported once up front — file, ✗ mark,
lg's message — and counted separately from assertions in the summary. The
summary colour, the OK/FAIL line and the exit code all read one `failed?`
binding, so a green `OK` can never accompany exit 1.

Commits: `87879c3` (load phase), `174d02b` (skip + report), `5981856` (e2e),
`6b36780` (issue doc). `lgx.lg` is unchanged, as the plan expected.

**Verified.**

| check | result |
|---|---|
| `make test` | 684 unit tests / 1086 assertions, 315 e2e assertions, all pass |
| mixed repro (`/tmp/lgx-resilient`) | `ok-test` runs and passes, `broken_test.lg` reported, exit 1 |
| honeysql (`LGX_LG=…/let-go/bin/lg`) | **173 tests, 769 assertions, 0 failures, 2 load failures**, exit 1 — matching the plan exactly, where the baseline ran nothing |
| codex review, per task | one P1 on Task 1 (load failures collected but not consumed — exactly what Task 2 implements, closed there); no findings on Tasks 2, 4, 5 |

**Deviations** (each also noted inline under its task):

1. **Task 1** — the `harness-ready-marker` comment went stale in Task 1 rather
   than Task 2, so it was updated there per AGENTS.md's same-commit rule.
2. **Task 3** — scenario **70** needed the same assertion change as 68, which
   the plan did not predict: on lg 1.12.2 a reader error inside a required file
   throws like a compile error, so the load phase catches it and lgx never
   prints "a test file failed to load". Same fix, same guarantee; `cmd-test`
   and both detection functions untouched.
3. **Task 5** — `make lint` exits 123 on two warnings that pre-date this work
   in files this branch never touches (`lgx/clean.lg:121`,
   `lgx/gobuild.lg:199`). Left alone rather than widening scope; the change
   adds no new warnings. `make fmt-check` is clean.

**What the plan could have specified better.** It predicted scenario 68 would
break and told me exactly why, but asserted scenarios 69 and 70 would pass —
and 70 breaks for precisely the reason the plan itself gives for 68. Its own
probe table has the answer (a mid-file reader error *throws* on 1.12), so the
prediction contradicted the evidence a page earlier. Deriving "which e2e
assertions mention the moved message" mechanically — `grep -n "a test file
failed to load" tests/e2e.sh` — would have caught both scenarios up front
instead of one. Everything else held up, including the two exact strings Task 2
Step 1 flagged as needing updating and the honeysql numbers to the assertion.
