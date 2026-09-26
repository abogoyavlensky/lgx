# HoneySQL: exclude `upper-case` from clojure.core under `:lg`

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Requiring `honey.sql` under let-go prints no `WARNING: upper-case already refers to: #'clojure.core/upper-case` line.

**Tech Stack:** HoneySQL `develop` at `~/Projects/honeysql` (v2.7.1479 plus four commits), Clojure CLI, let-go 1.13.0, lgx built from `~/Projects/lgx`.

**Repo:** `~/Projects/honeysql`, cloned from `seancorfield/honeysql`. The fork `abogoyavlensky/honeysql` exists on GitHub; add it as `origin` for pushing and keep upstream as `upstream` (Task 1 does this). HoneySQL's `develop` already supports let-go and runs `lgx test` in CI (`.github/workflows/let-go.yml`), and the maintainer merged the previous let-go PR (#615) from this author.

Part of a four-plan set whose end goal is `lgx run` on `examples/web-app` printing zero warnings. Siblings: `2026-09-25-1617-letgo-packages-pin-sql-and-exclude-core-names.md`, `2026-09-25-1617-letgo-warn-on-reflection-per-load.md`, `2026-09-25-1617-lgx-dedupe-normalized-git-url-and-web-app-bump.md`. This plan is independent of the other three.

---

## Design

let-go's `clojure.core` defines `upper-case` (JVM Clojure keeps it in `clojure.string`). `honey.sql` defines its own `upper-case` on every platform, so under let-go the definition shadows a referred core name and let-go warns, as JVM Clojure would for a real core name. The namespace already excludes `format` and `str` for the same reason on the JVM.

The fix is the idiomatic one: add `upper-case` to `:refer-clojure :exclude`, but only under `:lg`, since the name does not exist in JVM or ClojureScript core and an unconditional exclude of a non-existent name is harmless on the JVM but confusing to readers. The `ns` form already uses `#?@(:lg () :clj [or-fn])` in its `:refer` vector, so a spliced conditional inside `:exclude` is established style here:

```clojure
(:refer-clojure :exclude [format str #?@(:lg [upper-case])])
```

No behaviour changes on any platform. Nothing else in `src/` defines a let-go core name: a grep of the run's output shows `upper-case` as the only shadow warning from HoneySQL.

**Not in this plan:** HoneySQL's five `#?(:clj (set! *warn-on-reflection* true))` lines. They are correct JVM hygiene. The 33 reflection warnings they trigger under let-go are a let-go limitation (hint-blind check, flag leaks across files) addressed in the let-go sibling plan. Only if upstream let-go declines the hint-aware change should a follow-up PR here guard those lines with `#?(:lg nil :clj (set! ...))`; do not bundle it into this PR.

## File Structure

- Modify: `src/honey/sql.cljc` — the `ns` form's `:exclude` vector.
- Modify: `CHANGELOG.md` — one bullet under `2.7.next in progress`.

## Tasks

### Task 1: Remotes and branch

- [x] **Step 1: Wire the fork**
  ```
  cd ~/Projects/honeysql
  git remote rename origin upstream
  git remote add origin https://github.com/abogoyavlensky/honeysql.git
  git fetch origin
  git checkout -b lg/exclude-upper-case upstream/develop
  ```
  Expected: `git remote -v` shows `origin` as the fork and `upstream` as seancorfield.

### Task 2: The change

**Files:**
- Modify: `src/honey/sql.cljc`
- Modify: `CHANGELOG.md`

- [x] **Step 1: Baseline and reproduce**
  On the clean branch, before editing, run the suite once as CI does and note the pass and fail counts for Step 3: `~/Projects/lgx/bin/lgx test --exclude honey.cache-test,honey.sql-alphanumeric-test 2>&1 | tail -3`.
  Then reproduce the warning. lgx has no `-e` flag, so use a one-line script. Run, from the repo root with Go on PATH:
  ```
  printf "(require 'honey.sql)\n" > /tmp/hs.lg
  ~/Projects/lgx/bin/lgx run /tmp/hs.lg 2>&1 | grep -c 'upper-case already refers'
  ```
  Expected: `1`.

  > Deviation: `lg` on PATH was mise's `github-nooga-let-go` 1.12.2, which cannot load HoneySQL (`method-invoke expected Receiver` in `util.cljc`, and the lgx 0.3.2 test harness fails on `ns-interns`). Prepended mise's `lg/1.13.0` to PATH (plus mise's Go) for all let-go runs. Baseline: 175 tests, 845 assertions, 0 failures.

- [x] **Step 2: Edit the ns form**
  In `src/honey/sql.cljc`, change `(:refer-clojure :exclude [format str])` to `(:refer-clojure :exclude [format str #?@(:lg [upper-case])])`. Add a one-line comment above the `upper-case` definition block (near line 260) saying let-go's core has an `upper-case`, hence the `:lg` exclusion in the ns form.

- [x] **Step 3: Verify under let-go**
  Run the Step 1 command again. Expected: `0`.
  Then run the suite as CI does: `~/Projects/lgx/bin/lgx test --exclude honey.cache-test,honey.sql-alphanumeric-test 2>&1 | tail -3`
  Expected: the same pass and fail counts as the Step 1 baseline; the point is no change, not a specific number.

- [x] **Step 4: Verify on the JVM**
  Run: `clojure -X:test`
  Expected: PASS, same as before. Under the JVM the `:lg` conditional splices nothing.

- [x] **Step 5: CHANGELOG**
  Under `* 2.7.next in progress`, add a bullet: exclude `upper-case` from `clojure.core` under let-go, where core defines that name, so requiring `honey.sql` no longer warns. Keep the existing bullet style with a PR link placeholder that Step 7 fills in.

- [x] **Step 6: Commit**
  `git commit -am "Exclude upper-case from clojure.core under :lg"`

  > Done as `0110365`. Results: repro count 0; let-go suite 175 tests, 845 assertions, 0 failures (same as baseline); JVM `clojure -X:test` 179 tests, 2867 assertions, 0 failures. Codex review: no actionable defects. CHANGELOG bullet uses `#NNN` as the PR number placeholder.

- [ ] **Step 7: Open the PR**
  `git push -u origin lg/exclude-upper-case`
  `gh pr create -R seancorfield/honeysql --base develop --fill`, with a body of three sentences: what let-go's core defines, what the warning looks like, and that the change is a no-op on the JVM and ClojureScript. Then edit the CHANGELOG bullet with the PR number, amend, and force-push the branch.

  > Partial: branch pushed to `origin/lg/exclude-upper-case`. The PR is not opened yet; the author chose to push only. Still to do: `gh pr create`, replace `#NNN` in CHANGELOG, amend, force-push.

### Task 3: After merge

- [ ] **Step 1: Note the release**
  When a release tag containing this lands (v2.7.next), record it in the lgx sibling plan's bump step. The web-app example moves to v2.7.1479 immediately for the existing let-go fixes and to the new tag once it exists.

## Status (2026-09-25)

In progress. Tasks 1 and 2 (Steps 1–6) are done, and the branch is pushed. The PR (Step 7, second half) and Task 3 are still open.

- Implemented: `#?@(:lg [upper-case])` in the `:refer-clojure :exclude` of `honey.sql`, a one-line comment above `upper-case`, and a CHANGELOG bullet with a `#NNN` placeholder. Commit `0110365`.
- Verified: requiring `honey.sql` under lg 1.13.0 gives no `upper-case` warning. The let-go suite is unchanged at 175/845/0 and the JVM suite passes at 179/2867/0. Codex review found nothing.
- Deviations: let-go runs used mise's `lg/1.13.0` because the `lg` on PATH was 1.12.2, which can't load HoneySQL.
- What the plan could have specified better: it should pin the `lg` binary path or say to check `lg --version` ≥ 1.13.0 first, because the default PATH resolved to 1.12.2.
