# Test Harness on let-go's clojure.test Port Implementation Plan

**Status: completed 2026-09-20.**

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lgx test` work on let-go at or after `cffc09e` (nooga/let-go#863, the clojure.test port) while it keeps working on the PATH `lg` 1.12.2, with the user-visible output unchanged.

**Tech Stack:** let-go (`lgx/test_runner.lg`, the generated harness), bash e2e suite (`tests/e2e.sh`), let-go's `test` namespace on both sides of #863.

**Branch:** `test-harness-clojure-test` off `master`. Verification target on the new let-go: `examples/web-app` on branch `web-app-ragtime`, which pins `045d9fb` and has three suites (`routes`, `system`, `migrations`).

---

## Design

### Why

let-go #863 replaced the `test` namespace with a faithful clojure.test port. lgx's generated harness (`lgx/test_runner.lg`, `harness-header`/`harness-body`) is written against the old internals: it `:refer`s `*registered-tests*`, `*test-result*` and `*each-fixtures*`, runs each var itself, and **parses the printed `Testing: `/`PASS `/`FAIL ` lines** to learn what happened. On the new let-go the harness fails to compile (`Can't resolve *registered-tests*`), so `lgx test` is broken for every project pinning a recent let-go. No tagged let-go carries #863 yet and the repo's own suite runs under `lg` 1.12.2, so both shapes must keep working.

### What the two let-gos offer (probed 2026-09-19)

| | old (`lg` 1.12.2) | new (main `045d9fb`) |
|---|---|---|
| test vars | `*registered-tests*`: ns → vector of vars, definition order | `:test` metadata on vars; `(ns-interns ns)` — returns name order, vars carry no `:line` |
| assertion result | printed `PASS <form>` / `FAIL <form> - <msg>`, `Testing: a > b` on entering `testing` | `report` (a `^:dynamic` multimethod) receives `{:type :pass/:fail/:error :expected :actual :message :file :line}`; `test/*testing-contexts*` is bound innermost-first during the call; `test/testing-contexts-str` renders `"a > b"` |
| running one var | `((deref tv))` | `(test/test-var v)` — emits `:begin-test-var`/`:end-test-var`, catches any throw as an `:error` event, increments `:test` on `*report-counters*` (a `ref`; must be bound, `nil` at root) |
| fixtures | `*each-fixtures*` (global) | ns metadata `:test/each-fixtures`, `:test/once-fixtures`; `test/join-fixtures` |
| counters | `*report-counters*` map, `set!` | increments happen inside the default `report` methods — **rebinding `report` bypasses them**, so counts must come from the collected events |
| `resolve` of a missing var | `nil` | `nil` |
| `ns-interns` | does not exist — **a compile error even in a dead branch** | exists |

The last row shapes the design: one harness file cannot hold both paths, because let-go compiles every top-level form and the old lg rejects any symbol it does not know. Runtime `require` is the seam: `(if (resolve 'test/test-ns) (require 'lgx.test-harness.report) (require 'lgx.test-harness.legacy))` works on both (verified).

### Shape

`write-harness!` writes a **directory** instead of one file, `$LGX_HOME/test-runner/lgx-test-<version>/`, and `cmd-test` adds that directory to `-source-paths` (after `test/`), so the variants are ordinary namespaces:

```
lgx-test-<version>/
├── harness.lg                    entry script: ns lgx.test-harness; test plan; load phase;
│                                 ready marker; dispatch; summary + exit  (was the whole harness)
└── lgx/test_harness/
    ├── ui.lg                     ns lgx.test-harness.ui: color/green/red, nonblank-lines,
    │                             var-name, print-file, print-mark, print-context, print-detail
    ├── legacy.lg                 ns lgx.test-harness.legacy: (run! plan) — today's run loop, moved
    └── report.lg                 ns lgx.test-harness.report: (run! plan) — the clojure.test path
```

Contract shared by both variants, so the entry never cares which ran:

```clojure
(defn run!
  "Run every entry of `plan` ([display-file ns-sym] pairs whose ns loaded),
   printing the file header, one ✓/✗ line per test, contexts and failure
   detail. Returns {:test n :pass n :fail n :error n}."
  [plan] ...)
```

The entry calls it as `((var-get (resolve 'lgx.test-harness.<variant>/run!)) runnable-plan)` — the symbol must not be resolved at compile time, since the other variant is never loaded.

`legacy.lg` is the current loop lifted out unchanged except that it no longer `set!`s `*test-result*` (dead: the exit code is computed from the counters) and reads `*each-fixtures*`/`*registered-tests*` through `:refer` in its own ns form — which only that file compiles.

### The new path (`report.lg`)

For each `[file ns-sym]` in the plan:

1. Print the file header. `(in-ns ns-sym)` for the duration (let-go resolves some forms against the live `*ns*`; `test/test-ns` does the same switch), restoring the previous ns in `finally`.
2. `vars` = the interned vars with `:test` metadata, sorted by name — `(sort-by (comp str :name meta) (filter (comp :test meta) (vals (ns-interns ns))))`. Definition order is not recoverable on this side (no `:line` meta); name order is deterministic and matches what `(vals (ns-interns ns))` returns today anyway.
3. Fixtures from `(meta (the-ns ns-sym))`: `once = (test/join-fixtures (:test/once-fixtures m))`, `each = (test/join-fixtures (:test/each-fixtures m))`. Run `(once (fn [] (doseq [v vars] (run-var v each))))`. The `:once` fixture wraps the whole namespace **outside** any capture, so whatever it prints passes straight through (as it does under clojure.test's own runner); the `:each` fixture runs **inside** the per-var capture and reporter binding (next step), so its output lands in the test's captured stdout and an `is` inside it counts for that test — the legacy loop wrapped `*each-fixtures*` the same way.
4. `run-var [v each]`: with `events` an atom, `(binding [test/report collect! test/*report-counters* (ref test/*initial-report-counters*)] (with-out-str (each (fn [] (test/test-var v)))))`; `collect!` conjes `(assoc m :contexts (str/join " > " (reverse test/*testing-contexts*)))` for `:pass`/`:fail`/`:error` and ignores the rest. (Not `test/testing-contexts-str`: at `045d9fb` it joins with a plain space, and the legacy output is `a > b`.) Then render, in this order, matching the legacy output line for line:
   - `  ✓ name` / `  ✗ name` (failed = any `:fail` or `:error` event);
   - every distinct non-empty `:contexts` string in event order, as `    <ctx>` (legacy printed the `Testing: ` line on entering a `testing`; here a `testing` with no assertion inside prints nothing — accepted);
   - when failed: each `:fail` as `    FAIL <expected>` plus ` - <message>` when present (`FAIL` red — the e2e pins `\e[38;5;1mFAIL\e[0m (= 1 2)`), followed by `      actual: <pr-str actual>` (new; the legacy `is` never had the actual value); each `:error` as `    ERROR: <actual>` (legacy printed `ERROR: <e>` for a throw); then the test's captured stdout lines, non-blank, indented (legacy printed them too, only on failure).
   - Counters: `:test` = vars run, `:pass`/`:fail`/`:error` = event counts. Assertions = pass + fail, failures = fail + error, exactly as the entry computes today.

Not honored, same as today: `test-ns-hook`. Not needed: `*test-out*` (nothing is printed by let-go while `report` is rebound to the collector).

### Feature detection

`(resolve 'test/test-ns)` picks the new path; anything else takes legacy. `test-ns` is the runner entry point of the clojure.test port and did not exist before it. When a tagged let-go carries #863 and lgx's minimum `lg` moves past it, `legacy.lg` and the dispatch are deleted — note this at the dispatch site.

### Verification

- Old shape: the existing e2e scenarios 39–49e, 57–59, 69–70 under `LGX_LG` (lg 1.12.2) pin the output; they must pass unchanged. `bin/lgx test` (lgx's own unit tests) runs under the same lg.
- New shape: `tests/e2e.sh` gains a section that reruns the happy path, the failure path (testing context + red `FAIL (= 1 2)`), an uncaught throw (`✗`, `ERROR:` line, exit 1), `:each` + `:once` fixtures (order of side effects), and the load-failure case, all under `$LGX_LG_NEW` — set by the caller to an lg that resolves `test/test-ns`; the section is skipped with a visible `skip` line when it is unset or old-shaped. Locally: `cd ~/Projects/let-go && go build -o bin/lg .` (main at `045d9fb`), then `LGX_LG_NEW=~/Projects/let-go/bin/lg make test`.
- Integration: `examples/web-app` on `web-app-ragtime` — `lgx test` runs all three suites on the `045d9fb` runtime, exit 0.

## File Structure

- Modify `lgx/test_runner.lg` — replace `harness-header`/`harness-body`/`harness-source`/`temp-path`/`write-harness!` with: `harness-sources` (pure: entries → `{relative-path source}` for the four files), `harness-dir` (the per-version directory path), `write-harness!` (writes the map, returns `{:dir :entry}`); the ready-marker/load-error helpers stay.
- Modify `lgx.lg` (`cmd-test`) — use `{:dir :entry}`: `source-paths` = project paths + `test/` + `:dir`; run `:entry`; the `+ test runner:` verbose line prints the entry path.
- Modify `test/lgx/test_runner_test.lg` — unit tests for `harness-sources` (four keys; entry contains the marker, the dispatch on `test/test-ns`, and the plan; `legacy` refers `*registered-tests*`; `report` binds `test/report`; neither variant's symbols appear in the entry).
- Modify `tests/e2e.sh` — `supports_clojure_test` helper; the new `LGX_LG_NEW` section.
- Modify `tests/run.sh` — pass `LGX_LG_NEW` through; print a one-line note when unset.
- Modify `docs/ARCHITECTURE.md` — `lgx test` step 7 (directory, dispatch, both variants) and step 8 (harness dir on the source path).
- Modify `docs/knowledge-base/let-go-gotchas.md` — one entry: a dead branch still compiles, so version-dependent code splits into namespaces loaded by runtime `require`.

---

### Task 1: Split the harness into entry + ui + legacy, no behavior change

**Files:**
- Modify: `lgx/test_runner.lg`
- Modify: `lgx.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Write the failing unit tests**
  `test/lgx/test_runner_test.lg` already has four `harness-source-*` tests (from line 134) that call `tr/harness-source` and inspect one string. Migrate them to `tr/harness-sources`: bind `src` to `(get (tr/harness-sources entries) "harness.lg")`; keep the parses?/ordering assertions; replace the `[test :refer` assertion (the entry no longer refers `test`) with `(resolve 'test/test-ns)`. Then add: the map has exactly the four keys `"harness.lg"`, `"lgx/test_harness/ui.lg"`, `"lgx/test_harness/legacy.lg"`, `"lgx/test_harness/report.lg"`; every source `parses?`; the entry does **not** contain `*registered-tests*`; the legacy source contains `*registered-tests*` and `(defn run!`; the report source contains `(defn run!` (the `test/report` assertion is added in Task 2, when the stub becomes real); `harness-dir` ends with `lgx-test-<version>`.

- [x] **Step 2: Run to verify they fail**
  Run: `cd ~/Projects/lgx && make build >/dev/null && bin/lgx test test/lgx/test_runner_test.lg; echo "exit $?"`
  Expected: exit 1 — the new fns do not exist (a load failure or `Can't resolve harness-sources`).

- [x] **Step 3: Restructure `lgx/test_runner.lg`**
  Keep `harness-prefix`/`harness-suffix` semantics for the directory name (`lgx-test-<version>`, no `.lg`). Build four source strings:
  - `ui.lg`: ns `lgx.test-harness.ui` requiring `[string :as str]`; move `color`, `green`, `red`, `nonblank-lines`, `var-name` here, plus `print-file` (prints the display file), `print-mark` (`"  " mark " " name`), `print-context` (`"    " ctx`), `print-detail` (`"    " line`), all public.
  - `legacy.lg`: ns `lgx.test-harness.legacy` with `(:require [test :refer [*registered-tests* *report-counters* *each-fixtures*]] [lgx.test-harness.ui :as ui] [string :as str])`. Move the current per-entry loop into `(defn run! [plan] ...)` returning `*report-counters*` at the end (the `:test` counter is incremented here as today). Keep the `testing-line?`/`pass-line?`/`color-fail-token`/`print-testing-line`/`print-detail-line` helpers here — they parse the legacy output and belong to this variant. Drop the `set! *test-result*` (dead).
  - `report.lg`: for this task a stub — ns `lgx.test-harness.report` with `(defn run! [plan] (throw (ex-info "clojure.test path not implemented" {})))`. Task 2 fills it in.
  - `harness.lg`: the entry — ns `lgx.test-harness` requiring `[string :as str] [os :as os]` (no `test` refer); the plan, the load phase, the marker write, `failed-namespaces`/`runnable-plan`, the load-failure report, then the dispatch:
    ```clojure
    ;; Two harness variants, chosen at run time: let-go #863 replaced the
    ;; test internals the legacy loop reads, and a dead branch still has to
    ;; compile, so each variant is its own namespace and only one is loaded.
    ;; Delete legacy + this dispatch once lgx's minimum lg carries #863.
    (def run-var
      (if (resolve 'test/test-ns)
        (do (require 'lgx.test-harness.report) 'lgx.test-harness.report/run!)
        (do (require 'lgx.test-harness.legacy) 'lgx.test-harness.legacy/run!)))
    (def counters ((var-get (resolve run-var)) runnable-plan))
    ```
    then the existing summary/exit block reading `counters` instead of `*report-counters*`.
  `harness-sources` returns `{"harness.lg" ... "lgx/test_harness/ui.lg" ... "lgx/test_harness/legacy.lg" ... "lgx/test_harness/report.lg" ...}`. `harness-dir [version]` = `(path/join (home/test-runner-dir) (str harness-prefix version))`. `write-harness! [entries version]` mkdirs `<dir>/lgx/test_harness`, spits each file, returns `{:dir dir :entry (path/join dir "harness.lg")}`. Update the docstrings that describe "a single .lg file".

- [x] **Step 4: Wire `cmd-test`**
  In `lgx.lg` `cmd-test`: `{:keys [dir entry]} (test-runner/write-harness! entries version)`; `source-paths (vec (concat paths [test-dir dir]))`; run `[entry]`; the verbose line prints `entry`.

- [x] **Step 5: Unit tests pass; the old-shape suite is unchanged**
  Run: `cd ~/Projects/lgx && make test; echo "exit $?"`
  Expected: exit 0; `All 380 e2e assertions passed.` (or more, never fewer) and `All tests passed.`. This exercises the legacy variant through every existing `lgx test` scenario under lg 1.12.2.

- [x] **Step 6: Commit**
  `git add -A lgx lgx.lg test && git commit -m "test runner: split the harness into an entry and per-let-go variants"`

> Deviation (Task 1): the e2e verbose-path assertion (`tests/e2e.sh:1016`) pinned the old single-file harness path; updated to `lgx-test-<version>/harness.lg`. Codex caught that the test-file rewrite had dropped every section after the harness tests (validate-single-test-file!, marker/load-error helpers, write-harness); restored in fixup `17f0d4c`, with `write-harness-uses-versioned-stable-path` migrated to the `{:dir :entry}` return.

### Task 2: The clojure.test path

**Files:**
- Modify: `lgx/test_runner.lg` (the `report.lg` source)

- [x] **Step 1: Build a new-shape lg for local runs**
  Run: `cd ~/Projects/let-go && git log --oneline -1 && go build -o bin/lg . && bin/lg -e "(println (some? (resolve 'test/test-ns)))"`
  Expected: HEAD is `045d9fb` (or newer on main); prints `true`.

- [x] **Step 2: Reproduce the failure on a scratch project**
  Run `cd ~/Projects/lgx && make build >/dev/null` first — `bin/lgx` is a bundle and does not see source edits until rebuilt; repeat this before every `bin/lgx` run in this task. Create `/tmp/ct-proj` with `lgx.edn` `{}` and `test/foo_test.lg` containing: `pass-1` with a `testing "first assertion passes"` around `(is (= 1 1))`; `fail-1` with `testing "failing assertion is explained"` around `(is (= 1 2) "with msg")`; `boom` that throws `(ex-info "kaboom" {})`; and `(use-fixtures :each (fn [f] (println "each") (f)))`, `(use-fixtures :once (fn [f] (println "once") (f)))`.
  Run: `cd /tmp/ct-proj && LGX_HOME=$(mktemp -d) LGX_LG=~/Projects/let-go/bin/lg ~/Projects/lgx/bin/lgx test; echo "exit $?"`
  Expected: exit 1 with the stub's `clojure.test path not implemented` error (Task 1 dispatch chose `report`).

- [x] **Step 3: Implement `report.lg`**
  Per the Design section "The new path": ns `lgx.test-harness.report` requiring `[test] [lgx.test-harness.ui :as ui] [string :as str]`. Functions: `test-vars-of [ns-sym]` (sorted, `:test` meta only), `fixtures-of [ns-sym]` → `{:once f :each f}` via `test/join-fixtures` over `:test/once-fixtures` / `:test/each-fixtures` of the ns meta, `collect! [events m]` (records `:pass`/`:fail`/`:error` with `:contexts (test/testing-contexts-str)`), `run-var! [v]` → `{:events [...] :out "..."}` under `(binding [test/report ... test/*report-counters* (ref test/*initial-report-counters*)] (with-out-str (test/test-var v)))`, `render! [v {:keys [events out]}]` printing the mark, the distinct contexts, and — on failure — the `FAIL`/`ERROR` lines, `actual:`, and the captured stdout, then `run! [plan]` doing `in-ns`/restore per entry and summing counters. The `FAIL` token goes through `ui/red` exactly as legacy's `color-fail-token` does: `(str (ui/red "FAIL") " " (pr-str expected) (when message (str " - " message)))`.

- [x] **Step 4: Verify on the scratch project**
  Run: `cd ~/Projects/lgx && make build >/dev/null`, then the Step 2 `lgx test` command again. Add to the unit tests that the report source contains `test/report`, and confirm `bin/lgx test test/lgx/test_runner_test.lg` passes.
  Expected: exit 1; output shows `once` once (uncaptured, before the rows), `test/foo_test.lg`, `✓ pass-1` with `    first assertion passes` under it, `✗ fail-1` with `    failing assertion is explained`, a red `FAIL (= 1 2) - with msg` line and `      actual: (not (= 1 2))`, `✗ boom` with `    ERROR: ` naming `kaboom`; `each` appears exactly twice — once in each failing test's captured-stdout detail, never under `pass-1`; and the red summary `3 tests, 2 assertions, 2 failures` then `FAIL`.
  Then remove `boom` and `fail-1` and rerun: exit 0, green `1 tests, 1 assertions, 0 failures`, `OK`.

- [x] **Step 5: Verify the legacy path is untouched**
  Run: `cd /tmp/ct-proj && LGX_HOME=$(mktemp -d) ~/Projects/lgx/bin/lgx test; echo "exit $?"` (PATH/mise lg 1.12.2)
  Expected: exit 0, same rows and summary as Step 4's second run (no `actual:` line — legacy has none).

- [x] **Step 6: Integration on web-app**
  Run: `cd ~/Projects/lgx && git stash list >/dev/null; git worktree add -f /tmp/wa-ragtime web-app-ragtime >/dev/null 2>&1 || true; cd /tmp/wa-ragtime/examples/web-app && ~/Projects/lgx/bin/lgx test > /tmp/wa-ct.log 2>&1; echo "exit $?"; grep -v "^WARNING\|^reflection" /tmp/wa-ct.log | tail -12`
  Expected: exit 0; three file headers (`test/app/migrations_test.lg`, `routes_test.lg`, `system_test.lg`), all ✓, a green summary with 0 failures, `OK`. (The worktree is read-only use; remove it after: `git -C ~/Projects/lgx worktree remove --force /tmp/wa-ragtime`.)

- [x] **Step 7: Commit**
  `git add -A lgx && git commit -m "test runner: run tests through let-go's clojure.test contract when present"`

> Deviation (Task 2): the variants' entry point is `run-plan!`, not `run!` — on the new let-go a `defn run!` prints `WARNING: run! already refers to: #'clojure.core/run!` to the user's stderr on every `lgx test`. Contract otherwise as designed. Integration: web-app on `web-app-ragtime` → 7 tests, 36 assertions, 0 failures on `045d9fb`.

> Deviation (Task 2, post-review): Codex found that an `is` inside a `:once` fixture ran outside any collector and never counted (P1), and asked for `test-ns-hook` (P2, which the plan had scoped out). Fixup `46958b9`: an ns-level collector spans the whole namespace run (per-var collectors shadow it); stray fail/error events print as a `✗ fixtures` row and count; a namespace with `test-ns-hook` runs the hook as one `test-ns-hook` row instead of the vars, matching `test/test-ns`. The design's "Not honored: test-ns-hook" no longer applies.

### Task 3: e2e coverage for the new path

**Files:**
- Modify: `tests/e2e.sh`
- Modify: `tests/run.sh`

- [x] **Step 1: Helper and gate**
  In `tests/e2e.sh` next to `supports_source_paths`, add `supports_clojure_test` that returns 0 when `LGX_LG_NEW` is set, executable, and `"$LGX_LG_NEW" -e "(println (some? (resolve 'test/test-ns)))"` prints `true`. In `tests/run.sh`, after the `LGX_LG` block: `export LGX_LG_NEW="${LGX_LG_NEW:-}"` and, when empty, `echo "note: LGX_LG_NEW unset - clojure.test-path scenarios will be skipped"`.

- [x] **Step 2: Scenarios**
  Append a section `# Scenarios 127-131: lgx test on let-go's clojure.test port (LGX_LG_NEW)` (126 is the current last), each guarded by `if supports_clojure_test; then ... else skip "..."; fi` and running lgx with `LGX_LG="$LGX_LG_NEW"`:
  - 127 happy path: the same project and assertions as scenario 39 (header, rows, context line, `PASS (= 1 1)` absent, green `2 tests, 2 assertions, 0 failures`, ≥2 ✓).
  - 128 failure path: as scenario 40 (exit 1, context line, red `FAIL (= 1 2)`, red `2 tests, 2 assertions, 1 failures`, a ✗) plus `assert_contains "$out" "actual: (not (= 1 2))"`.
  - 129 uncaught throw: a deftest that throws `(ex-info "kaboom" {})`; exit 1, ✗, `ERROR:` line containing `kaboom`, summary `1 tests, 0 assertions, 1 failures`.
  - 130 fixtures and their order: `:once` and `:each` fixtures that append `once-before`/`each-before` … `each-after`/`once-after` lines to a file (`$proj/order.log`, path passed via an env var read with `os/getenv`), two passing deftests and one failing that prints nothing itself; exit 1; `once` appears once in the file, the file's line sequence is `once-before each-before each-after each-before each-after each-before each-after once-after` (compare with `paste -sd' '`), and the failing test's detail contains no `each` line (the fixture printed nothing to stdout).
  - 131 load failure: the scenario 68 project (an `ok_test.lg` and a `broken_test.lg` referencing `totally-undefined-symbol`), asserting exactly what 68 asserts — non-zero exit, `broken_test.lg` and `totally-undefined-symbol` in the output, `failed to load`, and `pass-1` still ran. (The `lgx: a test file failed to load` line is the pre-marker case only; from lg 1.12 the harness catches the throw itself.)

- [x] **Step 3: Run both shapes**
  Run: `cd ~/Projects/lgx && LGX_LG_NEW=~/Projects/let-go/bin/lg make test; echo "exit $?"`
  Expected: exit 0; the e2e assertion count rose by the new scenarios' assertions; no `skip` for scenarios 127–131. Then `make test` without `LGX_LG_NEW`: exit 0 and five `skip` lines for 127–131.

- [x] **Step 4: Commit**
  `git add tests && git commit -m "e2e: cover lgx test on let-go's clojure.test port under LGX_LG_NEW"`

> Deviation (Task 3): seven scenarios (127–133) instead of five — the two post-review cases from Task 2 (a failing assertion inside a `:once` fixture; `test-ns-hook`) are pinned too. `supports_clojure_test` reads the first line of `lg -e` output (`-e` also prints the form's value). The order-log fixture accumulates in an atom and writes from the once-teardown: let-go's `spit` has no `:append`. Two ✗-row greps use `-F` because the ANSI `[0m` reads as a bracket expression. With `LGX_LG_NEW`: 419 e2e assertions; without: 380 and seven skips.

### Task 4: Docs

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/knowledge-base/let-go-gotchas.md`

- [x] **Step 1: ARCHITECTURE `lgx test` steps 7–8**
  Rewrite step 7: the harness is a directory `$LGX_HOME/test-runner/lgx-test-<version>/` with an entry script and `lgx/test_harness/{ui,legacy,report}.lg`; the entry loads the plan, writes the ready marker, then requires one variant at run time — `report` when `test/test-ns` resolves (let-go ≥ #863: `test/test-var` per var under `binding [test/report ...]`, fixtures from ns metadata, counts from events, vars in name order), else `legacy` (`*registered-tests*`, parsed `PASS`/`FAIL` lines) — and prints the summary from the `{:test :pass :fail :error}` map `run!` returns. Step 8: the harness directory is appended to `-source-paths` after `test/`. Keep the marker/load-failure text as is.

- [x] **Step 2: let-go gotcha**
  Add an entry: let-go compiles every top-level form, so a branch that is never taken still fails on a symbol the running let-go lacks (`ns-interns` on 1.12.2); version-dependent code goes in separate namespaces chosen with `(resolve 'the/marker)` and loaded by runtime `require`, called through `(var-get (resolve 'ns/fn))`. Point at `lgx/test_runner.lg`.

- [x] **Step 3: Commit**
  `git add docs && git commit -m "docs: describe the two-variant test harness and the dead-branch gotcha"`

### Task 5: Full verification and hand-back

- [x] **Step 1: Full suite, both shapes**
  Run: `cd ~/Projects/lgx && LGX_LG_NEW=~/Projects/let-go/bin/lg make test; echo "exit $?"` — Expected: exit 0.
  Run: `bin/lgx --verbose test 2>&1 | grep "test runner:"` — Expected: the entry path ends in `lgx-test-<version>/harness.lg`.

- [x] **Step 2: Merge into `web-app-ragtime` and verify there**
  Run: `git checkout web-app-ragtime && git merge --no-edit test-harness-clojure-test && cd examples/web-app && ~/Projects/lgx/bin/lgx test > /tmp/wa-final.log 2>&1; echo "exit $?"; grep -v "^WARNING\|^reflection" /tmp/wa-final.log | tail -6`
  Expected: clean merge (the two branches touch disjoint files); exit 0; `OK`. Note: `bin/lgx` must be rebuilt from the merged tree first if `make test` did not just do it (`make build`).

- [x] **Step 3: Report**
  Summarize: the harness layout, what changed for users (nothing on old lg; `actual:` lines and name-ordered tests on new lg), how to run the new-path e2e locally (`LGX_LG_NEW`), and the deletion trigger for `legacy.lg`. Leave the PR of `test-harness-clojure-test` to the user.

---

## Completion summary

**Implemented** on `test-harness-clojure-test` (off `master`): the generated harness is now a directory `$LGX_HOME/test-runner/lgx-test-<version>/` — `harness.lg` (plan, load phase, ready marker, run-time dispatch, summary) plus `lgx/test_harness/{ui,legacy,report}.lg`. `legacy` is the old loop over `*registered-tests*`; `report` runs `:test` vars through `test/test-var` under a rebound `test/report`, with fixtures from namespace metadata, an ns-level collector for assertions outside any var, and `test-ns-hook` support. `cmd-test` puts the harness directory last on `-source-paths`. Commits: `606026c`, `17f0d4c`, `067a055`, `46958b9`, `042802e`, `caffa8f`, `ddf084e`, plus plan bookkeeping. Merged into `web-app-ragtime` as `b22fe1d`.

**Results.** `make test` under lg 1.12.2: 380 e2e assertions, unchanged output. With `LGX_LG_NEW=<lg built from let-go 045d9fb>`: 419 (seven new scenarios, 127–133). `examples/web-app` on `web-app-ragtime`, pinned to `045d9fb`: `lgx test` → 7 tests, 36 assertions, 0 failures (it failed to compile the harness before); `lgx run` serves and migrates as before. Four Codex rounds across the tasks; every must-fix was folded in before the next task.

**Deviations** (also inline under each task):
- Task 1: the e2e verbose-path assertion updated to `lgx-test-<version>/harness.lg`; the test-file rewrite had dropped later sections — restored (`17f0d4c`).
- Task 2: `run!` → `run-plan!` (a `defn run!` shadows `clojure.core/run!` and warns on the new lg). Post-review: assertions inside a `:once` fixture now count (`✗ fixtures` row); `test-ns-hook` is honored as one row — the plan had scoped it out; per-var counts accumulate in an atom because a `:once` fixture need not return `(f)`'s value.
- Task 3: seven scenarios, not five; `lg -e` prints the form's value so detection reads the first line; let-go's `spit` has no `:append`; `grep -F` for ANSI-bearing needles.
- Task 5: the merge into `web-app-ragtime` conflicted in `let-go-gotchas.md` (both branches appended an entry); kept both, reworded the ragtime entry's `Thread.lg` example, which that branch had since deleted.

**Open.** `legacy.lg` and the dispatch are deleted once lgx's minimum `lg` carries #863. The `report` variant orders tests by name (no `:line` on vars — a let-go gap worth an issue if definition order matters). `LGX_LG_NEW` is a local-only knob until CI has a let-go with #863.

**What the plan could have specified better:** it should have said what happens to counts and assertions *outside* a test var (`:once` fixtures, hooks) — both Codex P1s were there; and that `bin/lgx` is a bundle, so every verification needs a rebuild first (one step said so, the others did not).
