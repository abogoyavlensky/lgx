# letgo-packages: pin the sql sibling by tag and stop shadowing core names

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A consumer that depends on any two of sqlite, postgres, duckdb and ragtime gets one `letgo-sql` and no `already resolved` warning, and requiring `sqlite.core` or `postgres.core` prints no `already refers to` warning.

**Tech Stack:** let-go 1.13.0, lgx (master, built from `~/Projects/lgx`), the letgo-packages monorepo at `~/Projects/letgo-packages`.

**Repo:** `~/Projects/letgo-packages`. Every path below is relative to it. lgx here means `~/Projects/lgx/bin/lgx`; the released lgx 0.1.2 on PATH does not know `:lg-runtime`. Go must be on PATH: `export PATH=$HOME/.local/share/mise/installs/go/1.27.1/bin:$PATH`.

Part of a four-plan set whose end goal is `lgx run` on `examples/web-app` printing zero warnings. Siblings: `2026-09-25-1617-letgo-warn-on-reflection-per-load.md`, `2026-09-25-1617-honeysql-exclude-upper-case-under-lg.md`, `2026-09-25-1617-lgx-dedupe-normalized-git-url-and-web-app-bump.md`. This plan is independent of the other three.

---

## Design

### The two warnings this plan removes

Running the web-app example prints, among other things:

```
warning: abogoyavlensky/letgo-sql already resolved as local:.../ragtime-v0.1.0/sql; ignoring local:.../sqlite-v0.1.0/sql
WARNING: open already refers to: #'clojure.core/open in namespace: sqlite.core, being replaced by: #'sqlite.core/open
WARNING: close! already refers to: #'clojure.core/close! in namespace: sqlite.core, being replaced by: #'sqlite.core/close!
```

**The dedupe warning.** sqlite and ragtime both declare `abogoyavlensky/letgo-sql {:local/root "../sql"}`. lgx resolves a dep's `:local/root` against that dep's own checkout, so the two coords become two different directories (`sqlite-v0.1.0/sql` and `ragtime-v0.1.0/sql`) holding the same `src/`. lgx's first-wins dedupe compares coord identity, not content, so it keeps one and warns. The identity of a `:git/tag` coord is the coord map itself: two packages declaring the byte-identical `{:git/url ... :git/tag "sql-v0.2.0" :deps/root "sql"}` resolve to one entry, one checkout, and no warning (verified against lgx master with a throwaway project).

So the fix is a publishing rule, the same one the README already applies to Go shims: a released package names its `.lg` sibling by tag, and the local path is a development-only override.

**The shadow warnings.** let-go's `clojure.core` carries names JVM Clojure's does not, among them `open`, `close!` and `upper-case`. Defining one of them in a namespace that refers clojure.core warns, as it would on the JVM for a real core name. `sqlite.core` and `postgres.core` both define `open` and `close!`. The Clojure-idiomatic fix is `(:refer-clojure :exclude [open close!])`, which let-go's `ns` macro honours (verified on the 1.13.0 runtime).

### Decisions

- **Pin `sql-v0.2.0`.** It is the current sql tag and equals master's `sql/` tree. All four packages name the same tag in the same release round; if they ever diverge, the dedupe warning returns for a true reason and a consumer settles it with a top-level `letgo-sql` pin.
- **The local override lives in the `:test` context, not `:dev`.** lgx applies `[:test]` for `lgx test` and `[:dev]` only for `lgx run`; the packages' own workflow is `lgx test`. A project-defined context replaces the shipped default wholesale, so the `:test` entry must restate `:extra-paths ["test"]`. Context `:extra-deps` replace a same-named project coord in place (`lgx/config.lg` `merge-coords`), so the override is silent.
- **Only the three driver packages override sql locally; ragtime does not.** ragtime's tests pull sqlite from `../sqlite`, and sqlite now names sql by tag. If ragtime's `:test` also overrode sql to `../sql`, the root coord (local) and sqlite's transitive coord (tag) would differ and `lgx test` in ragtime would print the very warning this plan removes. So ragtime tests against the sql tag it pins, which is what its consumers get. Working-tree sql changes are covered by sqlite's own tests through its override, and an sql API change means a new sql tag and a ragtime bump anyway.
- **Byte-identical coord text in all four files.** lgx compares the coord map structurally today (the lgx sibling plan normalizes `:git/url`, but this plan must not depend on it). Same URL spelling, same key order is not required but keep it anyway for greppability.
- **CI keeps testing the working-tree sql.** `.github/workflows/test.yml` already seds `{:go/version ...}` shim coords to `{:go/local "shim"}` before `lgx test`. The `:test` overlay makes the same thing true for `sql/` without a sed, because `lgx test` applies it. Verify this in CI terms rather than adding another sed.
- **The examples do not change.** `sqlite/example` depends on `..`, which now brings sql by tag; `ragtime/example` depends on `..` and `../../sqlite`, both of which bring the same tag. No dup, no warning.
- **duckdb gets the pin too** even though the web-app does not use it, so the rule is uniform and a consumer mixing duckdb with ragtime is clean.

### Release

Four package tags on one commit, all naming `sql-v0.2.0`: `sqlite-v0.2.0`, `postgres-v0.2.0`, `duckdb-v0.2.0`, `ragtime-v0.2.0`. No shim changed, so no Go module tags. The lgx sibling plan bumps `examples/web-app` to these tags.

## File Structure

- Modify: `sqlite/lgx.edn`, `postgres/lgx.edn`, `duckdb/lgx.edn`, `ragtime/lgx.edn` — sql coord by tag, `:test` overlay.
- Modify: `sqlite/src/sqlite/core.lg`, `postgres/src/postgres/core.lg` — `:refer-clojure :exclude`.
- Modify: `README.md` — the "Releasing" section gains the sibling-by-tag rule.
- Modify: `.github/workflows/test.yml` — only if verification in Task 3 shows CI would test the tagged sql instead of the working tree.

## Tasks

### Task 1: Pin `letgo-sql` by tag in the four packages

**Files:**
- Modify: `sqlite/lgx.edn`, `postgres/lgx.edn`, `duckdb/lgx.edn`, `ragtime/lgx.edn`

- [x] **Step 1: Confirm the tag to pin**
  Run: `git tag --list 'sql-v*' | sort -V | tail -1 && git diff --stat sql-v0.2.0 HEAD -- sql`
  Expected: `sql-v0.2.0` and an empty diff. If the diff is not empty, stop: sql needs its own release first, and this plan then pins that new tag instead.

- [x] **Step 2: Replace the sql coord in all four files**
  In each `lgx.edn`, replace `abogoyavlensky/letgo-sql {:local/root "../sql"}` with exactly this coord, keeping the existing comment above it and extending it with one line saying the local path is the `:test` override below:
  ```clojure
  abogoyavlensky/letgo-sql
  {:git/url "https://github.com/abogoyavlensky/letgo-packages"
   :git/tag "sql-v0.2.0"
   :deps/root "sql"}
  ```
  Then add or extend `:contexts`. sqlite, postgres and duckdb have none today; add:
  ```clojure
  :contexts {:test {:extra-paths ["test"]
                    :extra-deps {abogoyavlensky/letgo-sql {:local/root "../sql"}}}}
  ```
  ragtime already has `:contexts {:test {:extra-deps {abogoyavlensky/letgo-sqlite {:local/root "../sqlite"}}}}`; add `:extra-paths ["test"]` to that map and nothing else. Do not add a `letgo-sql` override there (see Design: it would reintroduce the warning against sqlite's tagged sql). Say so in a comment.

- [x] **Step 3: Check the four coords are byte-identical**
  Run: `grep -h -A3 'abogoyavlensky/letgo-sql$' sqlite/lgx.edn postgres/lgx.edn duckdb/lgx.edn ragtime/lgx.edn | grep -v '^--' | sort | uniq -c`
  Expected: each of the three coord lines appears with count 4, and nothing else.

- [x] **Step 4: Verify the override applies under `lgx test`**
  Run, from `sqlite/`: `~/Projects/lgx/bin/lgx info 2>&1 | grep -i 'letgo-sql'`, then capture the whole test run: `out=$(~/Projects/lgx/bin/lgx test 2>&1); echo "$out" | tail -3; echo "$out" | grep -c 'already resolved'`
  Expected: `lgx info` (which applies no context) shows the git coord; the tests pass; the count is `0`. Repeat the capture in `ragtime/` with the same expectations. The first run builds a runtime and takes about a minute. postgres and duckdb tests need a database or a C toolchain; run `lgx info` there and confirm the coord only.

- [x] **Step 5: Verify the examples are clean**
  Run, from `ragtime/example/`: `~/Projects/lgx/bin/lgx run 2>&1 | grep -c 'already resolved'`
  Expected: `0`. The example reaches sql through both `..` and `../../sqlite`, and both now name the same tag.

- [x] **Step 6: Commit**
  `git commit -am "Pin letgo-sql by tag in the driver and ragtime packages; local path is the :test override"`

> Deviation: sqlite and postgres have no `test/` directory, so `lgx test` cannot run there. Their `:test` overlay was added anyway so the rule is uniform and applies if tests are added later. The sql override was exercised through duckdb's tests (27 passing, 0 `already resolved`) instead of sqlite's. The Design line "working-tree sql changes are covered by sqlite's own tests" does not hold: `sql/test` and `duckdb/test` cover them.

### Task 2: Exclude `open` and `close!` from clojure.core in the driver namespaces

**Files:**
- Modify: `sqlite/src/sqlite/core.lg`, `postgres/src/postgres/core.lg`

- [x] **Step 1: Reproduce**
  Run, from `sqlite/example/`: `~/Projects/lgx/bin/lgx run 2>&1 | grep -c 'already refers to'`
  Expected: `2`.

- [x] **Step 2: Add the exclusion**
  In both files, the `ns` form becomes:
  ```clojure
  (ns sqlite.core
    (:refer-clojure :exclude [open close!])
    (:require [sql]
              [sql.core]))
  ```
  Same shape for `postgres.core`. Add one comment line above it: let-go's clojure.core defines `open` and `close!`, which JVM Clojure's does not, so the exclusion keeps the require quiet.

- [x] **Step 3: Verify**
  Run, from `sqlite/example/`: `~/Projects/lgx/bin/lgx run 2>&1 | grep -c 'already refers to'`
  Expected: `0`. Also run `~/Projects/lgx/bin/lgx test` in `sqlite/` and `ragtime/`: PASS. For postgres, which needs a server to do anything, check only that the namespace loads cleanly: from `postgres/example/`, write `/tmp/pg.lg` containing `(require 'postgres.core)` and run `~/Projects/lgx/bin/lgx run /tmp/pg.lg 2>&1 | grep -c 'already refers to'`. Expected: `0` and no load error (lgx has no `-e` flag, hence the file).

- [x] **Step 4: Commit**
  `git commit -am "sqlite, postgres: exclude open and close! from clojure.core"`

> Deviation: `duckdb/src/duckdb/core.lg` also defines `open` and `close!` and warned the same way (visible in `lgx test` in duckdb), so it got the same exclusion. Commit message names all three drivers.

### Task 3: CI and README

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/test.yml` (only if needed)

- [x] **Step 1: Check CI still tests the working-tree sql**
  Read `.github/workflows/test.yml`. It runs `lgx test` per package after sed-flipping shim coords to `:go/local`. Because `lgx test` applies the `:test` context, the `letgo-sql` override already points at `../sql`. Confirm there is no step that runs `lgx run` or `lgx info` and expects the local sql; if there is, add a sed matching the shim one that flips the tag coord to `{:local/root "../sql"}`. Expected outcome: no change to the workflow.

- [x] **Step 2: Document the rule**
  In `README.md`, "Releasing": beside the sentence explaining that sqlite, postgres and ragtime inherit sql's shim through `:local/root "../sql"`, rewrite to say they depend on sql by package tag, that every package in a release round names the same `sql-vX.Y.Z`, and that the `:test` context is where the local path lives. Add a fourth row to the flow: when `sql/` changes, tag `sql-vX.Y.Z` first, then update the four coords, then tag the four packages on that commit. Keep it to one short paragraph plus the ordered list edit. Use /writing-clearly.

- [x] **Step 3: Commit**
  `git commit -am "README: released packages pin the sql sibling by tag"`

> Deviation: the sql release flow is a separate three-step list after the shim list, not a fourth row in it, because the shim list already has four steps and covers a different trigger. The layout trees in `sqlite/README.md` and `ragtime/README.md` also said `(:local/root)` for sql and now say `(git tag)`. CI runs lgx 0.3.1, not master: a temporary sentinel var in `sql/src`, asserted from a duckdb test, passed under both, so 0.3.1 applies the `:test` override too. The workflow is unchanged.

### Task 4: Release

- [x] **Step 1: Push and let CI run**
  `git push origin master` and wait for the `test.yml` run to go green.

- [x] **Step 2: Tag the four packages on the same commit**
  ```
  for p in sqlite postgres duckdb ragtime; do git tag "$p-v0.2.0"; done
  git push origin sqlite-v0.2.0 postgres-v0.2.0 duckdb-v0.2.0 ragtime-v0.2.0
  ```
  Push the four tags by name, not `--tags`, so a stray local tag never reaches the remote (a pushed tag can never be moved, per the README).

- [x] **Step 3: Consumer smoke test**
  In a throwaway directory, write an `lgx.edn` with `:lg-runtime :built`, `:lg-version "1.13.0"`, `:main "main.lg"`, and deps on `sqlite-v0.2.0` and `ragtime-v0.2.0` by `:git/tag` with `:deps/root`, plus a `main.lg` that requires `sqlite.core` and `ragtime.letgo` and prints `:ok`.
  Run: `out=$(~/Projects/lgx/bin/lgx run 2>&1); rc=$?; echo "$out"; echo "rc=$rc"; echo "$out" | grep -c -e 'already resolved' -e 'already refers'`
  Expected: the output contains `:ok`, `rc=0`, and the count is `0`. All three, so a failed run cannot pass as a quiet one. Then hand off to the lgx sibling plan, which bumps `examples/web-app`.

> Deviation: work landed on branch `pin-sql-and-exclude-core-names` as PR https://github.com/abogoyavlensky/letgo-packages/pull/4 instead of a direct push to master, as the user asked. CI is green on the PR (duckdb 27 tests, ragtime 9, OK). Steps 2-3 wait for the merge: the tags must sit on the merged master commit.

---

## Status

**Completed.** PR #4 was squash-merged as `d4ee791` and master CI passed. `sqlite-v0.2.0`, `postgres-v0.2.0`, `duckdb-v0.2.0` and `ragtime-v0.2.0` are pushed on that commit. The consumer smoke test (sqlite + ragtime by tag, fetched from GitHub) printed `:ok` with rc=0 and no `already resolved` or `already refers` lines. Next: the lgx sibling plan bumps `examples/web-app` to these tags.

## Summary

The sqlite, postgres, duckdb and ragtime `lgx.edn` files now name `letgo-sql` by the byte-identical `sql-v0.2.0` coord. Each driver's `:test` context points it at `../sql`; ragtime has no override. The three driver namespaces exclude `open` and `close!` from clojure.core. The root README documents the sql-by-tag rule and the release order when `sql/` changes. Verified with lgx master and lgx 0.3.1: sql (14), ragtime (9) and duckdb (27) tests pass with no warnings; `ragtime/example` and `sqlite/example` run clean; `postgres.core` loads clean. Codex reviewed each task commit and found nothing to fix.

Deviations, in one place:
- sqlite and postgres have no `test/`, so their `:test` overlay cannot be exercised yet. The sql override was proven through duckdb's tests, and the Design's claim that sqlite's tests cover working-tree sql was wrong.
- duckdb.core had the same `open`/`close!` shadowing and got the same exclusion.
- The README sql flow is a separate three-step list. The sqlite and ragtime README layout trees were also corrected.
- CI's lgx 0.3.1 was checked with a sentinel var to confirm it applies the `:test` override. No workflow change.
- PR (squash-merged) instead of a direct push to master. The tags sit on the merge commit.

**What the plan could have specified better:** check which packages have `test/` directories (sqlite and postgres have none) and grep every driver for `defn open`, which would have caught duckdb.core.
