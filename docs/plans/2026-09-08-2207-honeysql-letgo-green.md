# HoneySQL Fully Green Under let-go Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make [seancorfield/honeysql](https://github.com/seancorfield/honeysql) pass its own test suite under let-go with zero failures, by fixing the two remaining gaps in its existing `:lg` support.

**Tech Stack:** Clojure (`.cljc`), let-go, lgx. Work happens in the **honeysql fork** (`~/Projects/honeysql`, `abogoyavlensky/honeysql`), branching from `develop`. This plan document lives in lgx.

---

## Design

### Where things stand

HoneySQL already ships `:lg` reader conditionals upstream — let-go support landed in an earlier round. Two gaps remain. Measured against let-go `main` (`dc310b6`) across **all twelve** test namespaces:

| | Tests | Pass | Fail | Error |
|---|---|---|---|---|
| baseline | 156 | 663 | 0 | 0 |
| target | **173** | **769** | 0 | 0 |

The baseline is misleading twice over: `honey.sql-test` — most of the suite — does not load, so its assertions are absent rather than failing; and its eight genuine failures never get the chance to run.

Both figures were measured, not derived. Do not expect `706`/`714`: those come from a six-namespace runner used in an earlier round, which is not the full suite.

**Two namespaces are excluded, and adding git coords will not recover them.** The blocker is JVM host interop inside the dependencies themselves, not dependency resolution — verified by putting the libraries' source directly on `-source-paths` and watching them fail to compile:

| namespace | needs | fails on |
|---|---|---|
| `honey.cache-test` | `clojure.core.cache.wrapped` → `data.priority-map` | `(.. sc comparator (compare (. sc entryKey e) key))` — `java.util.SortedMap` / `Map.Entry` interop |
| `honey.sql-alphanumeric-test` | `clojure.test.check.generators` → `test.check.random` | `JavaUtilSplittableRandom.` — a deftype over `java.util.SplittableRandom` |

`honey.sql-alphanumeric-test` additionally needs `com.gfredericks/test.chuck`. Both fail identically before and after this change, so they are noise rather than signal here. Porting either library is its own project, well outside this plan. Every other namespace runs, `honey.unhashable-test` included.

### Gap 1: `issue-495-formatv` is not gated for `:lg`

`src/honey/sql.cljc:2576` defines `formatv` only for `:clj`:

```clojure
#?(:lg () :clj (defmacro formatv ...))
```

But `test/honey/sql_test.cljc:1412` gates the test on `:clj` alone:

```clojure
#?(:clj (deftest issue-495-formatv ... (sut/formatv ...)))
```

let-go's reader matches `:lg`, `:clj` and `:default`, so it reads a test for a macro `:lg` deliberately leaves undefined. The whole namespace then fails to compile with `Can't resolve sut/formatv`, taking ~17 tests and ~98 assertions with it.

Fix: add the `:lg` branch, in the style the source already uses.

```clojure
#?(:lg () :clj (deftest issue-495-formatv ...))
```

Verified: `()` works as a top-level `:lg` branch, and `honey.sql-test` then loads.

### Gap 2: `inline-str` doubles already-escaped quotes under `:lg`

`src/honey/sql.cljc:526-529`:

```clojure
(defn- inline-str [s]
  (if (or (mysql?) (not (:standard-conforming-strings *options*)))
    (str \' (str/replace s #?(:lg "'" :default #"(?<!\\)'") "''") \')
    (str \' (str/replace s "'" "''") \')))
```

Under MySQL and `{:standard-conforming-strings false}`, backslash escapes, so `\'` is *already* an escaped quote and must not be doubled. `:default` expresses that with a lookbehind. Go's re2 has no lookbehind, so `:lg` substitutes a plain `"'"` and doubles everything — the 8 failures, all in those two dialects.

Fix: an alternation that consumes `\'` as a unit, so only bare quotes reach the replacement. No lookbehind, so re2 accepts it.

```clojure
(str/replace s #"\\'|'" (fn [m] (if (= m "'") "''" m)))
```

Left-to-right alternation prefers `\'`, so an escaped quote is matched whole and returned unchanged.

**The `:default` branch stays exactly as it is.** The alternation is verified equivalent (below), so unifying them would be safe — but it would change code every HoneySQL user runs, for no behavioural gain. Keeping the conditional confines the diff to the branch that is actually wrong, which is also the easier ask of the maintainer.

Because the two branches now need different *replacements* as well as different patterns, the conditional moves up to wrap the whole `str/replace` call rather than just the pattern:

```clojure
(str \' #?(:lg (str/replace s #"\\'|'" (fn [m] (if (= m "'") "''" m)))
           :default (str/replace s #"(?<!\\)'" "''"))
     \')
```

### Why the alternation is equivalent

Not asserted — measured. Both implementations were run on JVM Clojure over the same inputs:

| input | lookbehind | alternation |
|---|---|---|
| `' OR 1=1#` | `'' OR 1=1#` | same |
| `b\'` | `b\'` | same |
| `b OR \' = \' OR 1=1#` | unchanged | same |
| `a'b` | `a''b` | same |
| `\\'` | `\\'` | same |
| `''` | `''''` | same |
| `'''` | `''''''` | same |
| `\'`, `plain`, `a\\'b`, `""` | — | same |

All 11 agree, including the cases where the two could plausibly diverge: `\\'` (escaped backslash then quote — both leave it alone, because the lookbehind only inspects one character) and runs of consecutive quotes.

That equivalence is the point of the change: it makes `:lg` behave like `:clj` rather than merely "better than before". Task 1 re-derives the table so the claim is checked rather than inherited.

### Scope

Two commits on a local branch in the fork: the test gate, then `inline-str`. They are intended as one PR against `seancorfield/honeysql` — both are "make the existing `:lg` support correct" — but **this plan does not push or open it**. It ends with a verified branch and a drafted description; the user takes it from there.

No new tests. The 8 assertions that currently fail already cover this precisely; adding more would be noise.

## File Structure

In the **honeysql fork** (`~/Projects/honeysql`):

| File | Change |
|---|---|
| `test/honey/sql_test.cljc` | gate `issue-495-formatv` with `:lg` (1 line) |
| `src/honey/sql.cljc` | `inline-str`: alternation for the `:lg` branch (~4 lines) |

In **lgx**, after the work is verified:

| File | Change |
|---|---|
| `docs/issues/honeysql-letgo-compat.md` | record both gaps as fixed upstream, with the final suite numbers |

Nothing in `examples/clojure-libs/with-honeysql/` changes — it is a consumer, and Task 5 runs it as a regression check.

---

### Task 0: Preflight

**Files:** none

- [ ] **Step 1: Branch the fork**
  Run: `cd ~/Projects/honeysql && git checkout develop && git pull && git checkout -b lg/inline-str-and-formatv-gate`
  Expected: a clean branch off `develop`.

- [ ] **Step 2: Confirm the toolchain**
  Run: `cd /home/agent/Projects/let-go && git log --oneline -1 && ./bin/lg -v | head -1`
  Expected: `main`, and an `lg` built from it. If `bin/lg` is missing or stale, `make build SMOKE-BOOT-BUDGET-MS=40`.
  A JVM Clojure is also required for Tasks 1 and 4: `mise exec -- clojure --version`.

- [ ] **Step 3: Record the let-go baseline**
  Use the runner from Task 3 against the unmodified fork.
  Expected: three `LOAD FAIL` lines (`honey.sql-test`, plus the two JVM-interop-blocked ones) and `Tests: 156 Pass: 663 Fail: 0 Error: 0`.

- [ ] **Step 4: Record the JVM baseline — before any edit**
  Run: `cd ~/Projects/honeysql && mise exec -- clojure -X:test 2>&1 | tail -5` and save the output to `/tmp/hsq/jvm-baseline.txt`.
  This must happen now. Once Tasks 2 and 3 have committed, `git stash` cannot recover the pristine tree — the changes are in commits, not the working tree — so Task 4 would otherwise have nothing to compare against.

---

### Task 1: Confirm the alternation matches the lookbehind

Done first and separately: if the two disagree on any input, the whole approach changes, and that must surface before any file is edited.

**Files:**
- Create: `/tmp/hsq-equiv.clj` (scratch, not committed)

- [ ] **Step 1: Write the comparison**
  A script defining both implementations over the same inputs and printing `SAME`/`DIFFERS` per case:
  ```clojure
  (defn lookbehind [s] (str/replace s #"(?<!\\)'" "''"))
  (defn alternation [s] (str/replace s #"\\'|'" (fn [m] (if (= m "'") "''" m))))
  ```
  Cover at least: `"' OR 1=1#"`, `"b\\'"`, `"b OR \\' = \\' OR 1=1#"`, `"plain"`, `"a'b"`, `"\\\\'"`, `"''"`, `"'''"`, `""`, `"\\'"`, `"a\\\\'b"`.
  Do not name a function `new` — it is a Clojure special form and fails to compile.

- [ ] **Step 2: Run on the JVM**
  Run: `mise exec -- clojure -M /tmp/hsq-equiv.clj`
  Expected: `SAME` on every line. A `DIFFERS` line stops the plan — report it rather than proceeding.

- [ ] **Step 3: Run the alternation under let-go**
  Evaluate the same inputs through `./bin/lg -e` with `string/replace`.
  Expected: identical output to the JVM alternation column, which is what makes `:lg` and `:clj` agree.

---

### Task 2: Gate `issue-495-formatv` for `:lg`

**Files:**
- Modify: `~/Projects/honeysql/test/honey/sql_test.cljc`

- [ ] **Step 1: Confirm the failure and its cause**
  Run: `cd /home/agent/Projects/let-go && LG_READ_CLJ=1 ./bin/lg -source-paths "$HOME/Projects/honeysql/src:$HOME/Projects/honeysql/test" -e "(require 'honey.sql-test)"`
  Expected: FAIL, ending in `Can't resolve sut/formatv` at `sql_test.cljc:1417`.

- [ ] **Step 2: Add the gate**
  Change `#?(:clj` to `#?(:lg () :clj` on the `issue-495-formatv` reader conditional (around line 1412). Match the source's existing style at `src/honey/sql.cljc:2576`; do not use `nil`.

- [ ] **Step 3: Confirm the namespace loads**
  Re-run Step 1's command.
  Expected: no error. Re-running the full runner at this point should give `Tests: 173 Pass: 761 Fail: 8 Error: 0` — the namespace now loads, exposing its eight genuine failures, which Task 3 fixes.

- [ ] **Step 4: Commit**
  `git commit -m "Gate issue-495-formatv for :lg, matching formatv's own gate"`

---

### Task 3: Fix `inline-str` for `:lg`

**Files:**
- Modify: `~/Projects/honeysql/src/honey/sql.cljc`

- [ ] **Step 1: See the 8 failures**
  Create the suite runner at `/tmp/hsq/suite.lg`. The `try`/`catch` around each `require` is load-bearing: a namespace that fails to compile otherwise takes the whole run down, and `require` failures are quiet enough to miss.
  ```clojure
  (require 'test)
  (doseq [n '[honey.sql-test honey.sql.helpers-test honey.sql.pg-ops-test
              honey.sql.postgres-test honey.sql.xtdb-test honey.bigquery-test
              honey.ops-test honey.union-test honey.util-test
              honey.cache-test honey.sql-alphanumeric-test honey.unhashable-test]]
    (try (require n)
         (catch Throwable e (println "LOAD FAIL" n (ex-message e)))))
  (test/run-tests)
  ```
  All twelve namespaces are listed. `honey.cache-test` and `honey.sql-alphanumeric-test` will report `LOAD FAIL` both before and after, because their dependencies use JVM host interop let-go does not support (see Design). Leave them in the list so the exclusion stays visible rather than silently assumed.
  Run: `cd /home/agent/Projects/let-go && LG_READ_CLJ=1 ./bin/lg -source-paths "$HOME/Projects/honeysql/src:$HOME/Projects/honeysql/test" /tmp/hsq/suite.lg 2>&1 | grep -v 'reflection warning'`
  `LG_READ_CLJ=1` is mandatory when invoking `lg` directly: it makes `.clj`/`.cljc` resolve and `:clj` conditionals match. lgx sets it for you.
  Expected: `Tests: 173 Pass: 761 Fail: 8 Error: 0`, with all 8 under `{:dialect :mysql}` or `{:standard-conforming-strings false}`, plus the two JVM-interop `LOAD FAIL` lines.
  Judge from the printed summary, not the exit code. If the failure count is not exactly 8, stop and report — the two changes are meant to be additive, and anything else means something outside this plan moved.

- [ ] **Step 2: Apply the fix**
  In `inline-str`, move the reader conditional to wrap the whole `str/replace` call so each branch can carry its own replacement, leaving `:default` byte-identical:
  ```clojure
  (str \' #?(:lg (str/replace s #"\\'|'" (fn [m] (if (= m "'") "''" m)))
             :default (str/replace s #"(?<!\\)'" "''"))
       \')
  ```
  Keep the existing `; per #607` comment, and add a short one saying why `:lg` differs: re2 has no lookbehind, so the alternation consumes `\'` as a unit instead.

- [ ] **Step 3: Confirm zero failures**
  Re-run Step 1's command.
  Expected: `Tests: 173 Pass: 769 Fail: 0 Error: 0`, and only the two JVM-interop `LOAD FAIL` lines.

- [ ] **Step 4: Commit**
  `git commit -m "Fix inline-str under :lg: match \\' as a unit instead of doubling it"`

---

### Task 4: Confirm the JVM is unaffected

`:default` is untouched, so this should be a formality — which is exactly why it is worth running rather than assuming.

**Files:** none

- [ ] **Step 1: Run HoneySQL's own suite on the JVM**
  Run: `cd ~/Projects/honeysql && mise exec -- clojure -X:test`
  Expected: green, with the same counts as on `develop` before the change. If the runner needs a different alias, check `deps.edn` `:aliases` (`:test` uses cognitect test-runner; `:runner` is the `-M` form).

- [ ] **Step 2: Compare against the baseline captured in Task 0**
  Diff against `/tmp/hsq/jvm-baseline.txt`. If the counts differ, re-run on pristine source in a separate checkout (`git worktree add /tmp/hsq-pristine develop`) rather than stashing — the changes are committed, so a stash would compare the modified tree with itself.

---

### Task 5: Verify the lgx example still works

The example is the downstream consumer; it exercises `sql/format` through lgx rather than through the raw `lg` binary.

**Files:** none (read-only check of `examples/clojure-libs/with-honeysql/`)

- [ ] **Step 1: Point the example at the fork**
  The example pins a released tag:
  ```clojure
  :deps {com.github.seancorfield/honeysql
         {:git/url "https://github.com/seancorfield/honeysql" :git/tag "v2.7.1437"}}
  ```
  For verification only, temporarily switch `:git/url` to the fork and `:git/tag` to a `:git/sha` on the branch, or use a `:local/root` pointing at `~/Projects/honeysql`. **Revert this before committing** — the example must keep pinning the upstream tag until the change is released.

- [ ] **Step 2: Run it**
  Run: `cd examples/clojure-libs/with-honeysql && LGX_LETGO_REPLACE=/home/agent/Projects/let-go lgx run`
  Expected: every demo prints a `[sql-string & params]` vector, no errors. The `mysql-dialect` and `inline-values` demos are the ones touching the changed path.

- [ ] **Step 3: Revert the example**
  Run: `git checkout -- examples/clojure-libs/with-honeysql/lgx.edn`
  Expected: a clean diff. Confirm with `git status --short`.

---

### Task 6: Leave the branch ready, do not push

The PR is the user's to open. This task stops at a clean local branch.

- [ ] **Step 1: Confirm the two commits**
  Run: `cd ~/Projects/honeysql && git log --oneline develop..HEAD && git status --short`
  Expected: exactly two commits (the gate, then `inline-str`), a clean tree, and no other files touched. `git diff develop..HEAD --stat` should show only `src/honey/sql.cljc` and `test/honey/sql_test.cljc`.

- [ ] **Step 2: Do not push and do not open a PR**
  Leave `lg/inline-str-and-formatv-gate` local. Report the branch name and the two commit subjects so the user can push and open the PR themselves.

- [ ] **Step 3: Draft the PR description for them**
  Write it to `/tmp/hsq/pr-body.md` (not committed) so it can be pasted. It should state: both changes are confined to the existing `:lg` branches and `:default` is untouched; the alternation is equivalent to the lookbehind, with the table from Task 1 as evidence; and the result across all twelve test namespaces is `173 tests / 769 assertions / 0 failures`, where the baseline was `156 / 663` with `honey.sql-test` failing to load.
  Mention that two namespaces remain unloadable under let-go for reasons outside HoneySQL — `core.cache` and `test.check` use JVM host interop — so the maintainer is not left wondering why the count is not all twelve.

---

### Task 7: Update the lgx issue doc

**Files:**
- Modify: `docs/issues/honeysql-letgo-compat.md`

- [ ] **Step 1: Record the outcome**
  Add both gaps and their fixes, with the before/after numbers and a link to the PR. The doc's existing "two related upstream items" note predicted exactly these two; mark them addressed rather than leaving the prediction dangling.
  Word the status as **implemented on a local branch in the fork** — not "fixed upstream", and not "PR submitted". This plan deliberately stops short of pushing; the user opens the PR. This repo's issue docs already make that distinction (see `interop-slice-boxing.md`, which says "implemented on `<branch>`"). Update the status again when the PR opens, and again when it merges.

- [ ] **Step 2: Check formatting and commit**
  Run: `cd /home/agent/Projects/lgx && mise exec -- cljfmt check`
  Expected: `All source files formatted correctly`.
  Commit on the current `honeysql-compat` branch.
