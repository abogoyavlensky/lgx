# lgx: normalize git URLs in the dedupe, record the let-go issues, and bring the web-app example to zero warnings

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `lgx run` in `examples/web-app` prints nothing on stderr before `Listening on ...`, and lgx no longer reports a spurious `already resolved` conflict for the same git repo and tag spelled two ways.

**Tech Stack:** let-go, lgx (this repo), `lgx test` for unit tests, `tests/e2e.sh` for end-to-end scenarios.

**Repo:** `~/Projects/lgx`. This is the umbrella plan: Tasks 1 and 2 are independent and can start now; Task 3 has steps blocked on releases from the three sibling plans and says so per step.

Siblings: `2026-09-25-1617-letgo-packages-pin-sql-and-exclude-core-names.md`, `2026-09-25-1617-letgo-warn-on-reflection-per-load.md`, `2026-09-25-1617-honeysql-exclude-upper-case-under-lg.md`.

---

## Design

### Where the 51 warning lines come from

| Lines | Cause | Fixed by |
|---|---|---|
| 1 | `letgo-sql` reached through two `../sql` checkouts | letgo-packages plan |
| 2 | `sqlite.core` defines `open`, `close!`, which let-go's core also has | letgo-packages plan |
| 1 | `honey.sql` defines `upper-case`, which let-go's core also has | honeysql plan |
| 14 | HoneySQL's `set! *warn-on-reflection*` leaks into ragtime, sql, sqlite | let-go plan, task 1 |
| 33 | HoneySQL's hinted interop sites, which let-go's check ignores | let-go plan, task 2 |

Nothing in this table is fixed in lgx. What lgx owns is: a small hardening of the dedupe so it does not add a false positive of its own, the `docs/issues/` record of the two let-go findings (the repo's convention for upstream work), and the example's pins.

### The dedupe hardening

`ensure-all!` (`lgx.lg`) keeps a `seen` map from lib symbol to coord identity and warns when a lib reappears with a different identity. `coord-id` absolutizes `:local/root` and otherwise returns the coord map as-is, so two git coords compare structurally. Verified: the same lib and tag with `:git/url` ending in `.git` on one side warns. `config.lg` already has `normalize-git-url` (strips a trailing slash and `.git`), used by `unresolved-declared` for the same purpose. `coord-id` applies it to `:git/url` when present, so the identity, and therefore the `seen` key and the warning label, is spelling-independent. The coord handed to `cache/ensure-lib!` is the original, so the cache layout does not change. `normalize-git-url` becomes public so `lgx.lg` and the unit test can reach it.

### The issue records

`docs/issues/` holds one file per upstream finding (see `docs/issues/README.md` and `letgo-push-thread-bindings.md` for the shape: repo, status, summary, how it was found, reproduction, workaround, upstream link). Two new entries: the per-load binding leak and the hint-blind target check. They link the let-go plan and get their status and PR links updated as the sibling plan progresses.

### The example bump and the definition of done

`examples/web-app/lgx.edn` pins `sqlite-v0.1.0`, `ragtime-v0.1.0`, HoneySQL `v2.7.1437` and let-go `1.13.0`. It moves to: the `-v0.2.0` package tags (after the letgo-packages release), HoneySQL `v2.7.1479` now and the next tag once the exclude lands, and the first let-go release carrying the per-load fix. Done means the run below prints `0`:

```
cd examples/web-app
PORT=18080 DB_PATH=/tmp/t.db timeout 90 ../../bin/lgx run > /tmp/webapp.out 2>&1
grep -q '^Listening' /tmp/webapp.out && echo started
sed '/^Listening/,$d' /tmp/webapp.out | wc -l
```

Both lines matter: `started` proves the app reached the server, and the count is the number of lines printed before it. A count of `0` without `started` is a failed run, not a quiet one. Every verification step in Task 3 uses this same capture.

If upstream declines the hint-aware change, the fallback is the `:lg` guard on HoneySQL's `set!` lines (see the honeysql plan). The final step is written to work either way.

## File Structure

- Modify: `lgx/config.lg` — `normalize-git-url` public.
- Modify: `lgx.lg` — `coord-id` normalizes `:git/url`.
- Test: `test/lgx/config_test.lg` — `normalize-git-url` cases.
- Modify: `tests/e2e.sh` — a new scenario at the end of the file (numbers run to 155 today, so 156): same tag, URL spelled two ways, no warning.
- Create: `docs/issues/letgo-warn-on-reflection-leaks-across-loads.md`, `docs/issues/letgo-reflection-warning-ignores-type-hints.md`.
- Modify: `docs/issues/README.md` — two rows in the "Upstream (nooga/let-go)" table.
- Modify: `examples/web-app/lgx.edn`, `examples/web-app/README.md` — pins and the paragraph naming the pinned versions.
- Check: `docs/knowledge-base/*.md` `Verify against:` footers that name `examples/web-app` or `ensure-all!`; update any stale claim in the same commit.

## Tasks

### Task 1: Normalize `:git/url` in the dedupe identity

**Files:**
- Modify: `lgx/config.lg`, `lgx.lg`
- Test: `test/lgx/config_test.lg`, `tests/e2e.sh`

- [ ] **Step 1: Write the failing unit test**
  In `test/lgx/config_test.lg`, next to the `unresolved-declared` tests, add `deftest normalize-git-url-strips-suffix-and-slash` asserting that `https://h/o/r`, `https://h/o/r.git`, `https://h/o/r/` and `https://h/o/r.git/` all normalize to `https://h/o/r`, and that surrounding whitespace is trimmed. It calls `config/normalize-git-url`, which is private today.

- [ ] **Step 2: Run to verify it fails**
  Run: `lg lgx.lg test` from the repo root (dev mode, per `docs/knowledge-base/lgx-dev-workflow.md`), or `make build && bin/lgx test`.
  Expected: FAIL, unresolved var `config/normalize-git-url`.

- [ ] **Step 3: Make it public and use it in `coord-id`**
  Change `defn-` to `defn` for `normalize-git-url` in `lgx/config.lg`. In `lgx.lg` `coord-id`, when the coord has a string `:git/url`, return it with that key normalized; keep the `:local/root` branch as is. Extend the docstring: the id is what the first-wins dedupe compares, so it must be spelling-independent, and `ensure-lib!` still receives the original coord.

- [ ] **Step 4: Run unit tests**
  Run: `bin/lgx test` (after `make build`).
  Expected: PASS.

- [ ] **Step 5: Add the e2e scenario**
  In `tests/e2e.sh`, append a scenario after the last one (the next unused number; 156 at the time of writing): two local libs `libP` and `libQ` each depending on `test/lib` at the same sha from the file:// bare repo the harness seeds (see the `make_project` helper and Scenario 63 for the local-lib shape), with `libQ` spelling the URL with a trailing `.git`; the project depends on both. Assert the run prints the expected output and that stderr does not contain `already resolved as`. Reuse the existing `assert_contains`/`pass`/`fail` helpers and the `LGX_HOME` isolation the neighbours use.

- [ ] **Step 6: Run e2e**
  Run: `make test`
  Expected: all scenarios pass, including 63 (differing coords still warn) and the new one.

- [ ] **Step 7: Commit**
  `git commit -am "deps: compare git coords by normalized URL in the first-wins dedupe"`

### Task 2: Record the two let-go findings in `docs/issues/`

**Files:**
- Create: `docs/issues/letgo-warn-on-reflection-leaks-across-loads.md`
- Create: `docs/issues/letgo-reflection-warning-ignores-type-hints.md`
- Modify: `docs/issues/README.md`

- [ ] **Step 1: Write the two entries**
  Follow the shape of `docs/issues/letgo-push-thread-bindings.md`. Each has: repo `nooga/let-go`, status `draft` (updated to the PR link by whoever opens it), a summary in two or three sentences, "How it was found" naming the web-app example and HoneySQL's `set!`, a minimal reproduction (the two-file `lib.setter`/`lib.later` project for the leak; `(fn [^String s] (.length s))` with the flag on for the hint one), the Clojure behaviour it diverges from, and a pointer to `docs/plans/2026-09-25-1617-letgo-warn-on-reflection-per-load.md`. Use /writing-clearly.

- [ ] **Step 2: Index and commit**
  Add a row for each entry to the "Upstream (nooga/let-go)" table in `docs/issues/README.md`, status `draft`. Stage the new files explicitly, since `-a` only picks up tracked ones: `git add docs/issues/letgo-warn-on-reflection-leaks-across-loads.md docs/issues/letgo-reflection-warning-ignores-type-hints.md docs/issues/README.md && git commit -m "docs/issues: let-go reflection warning leaks across loads and ignores type hints"`

### Task 3: Bring `examples/web-app` to zero warnings

**Files:**
- Modify: `examples/web-app/lgx.edn`, `examples/web-app/README.md`

- [ ] **Step 1: Bump HoneySQL to v2.7.1479 (unblocked)**
  Change the honeysql coord's `:git/tag` to `"v2.7.1479"`, the first release with let-go support in CI. Run the capture from Design ("definition of done") from `examples/web-app` with Go on PATH, then `../../bin/lgx test`.
  Expected: `started`; tests pass; the line count is unchanged or lower than 51 (record it in the commit message).
  `git commit -am "examples/web-app: honeysql v2.7.1479"`

- [ ] **Step 2: Bump the letgo-packages tags (blocked until `sqlite-v0.2.0` and `ragtime-v0.2.0` exist)**
  Change `sqlite-v0.1.0` to `sqlite-v0.2.0` and `ragtime-v0.1.0` to `ragtime-v0.2.0`. Run the same capture and `lgx test`.
  Expected: `started`; tests pass; `grep -c 'already resolved' /tmp/webapp.out` is `0`; `grep 'already refers' /tmp/webapp.out` shows only the HoneySQL `upper-case` line, which Step 4 removes. The sqlite `open` and `close!` lines must be gone.
  `git commit -am "examples/web-app: letgo-packages v0.2.0 tags"`

- [ ] **Step 3: Bump let-go (blocked until a release contains the per-load binding fix)**
  Set `:lg-version` to that release. Update the comment above it in `lgx.edn` and the paragraph in `README.md` (around line 81) that explains why the pin is what it is: add that this release scopes `*warn-on-reflection*` per file. Run the same capture and `lgx test`.
  Expected: `started`; tests pass; `grep 'reflection warning' /tmp/webapp.out` shows only `honeysql` paths, or nothing if the hint-aware change shipped in the same release.
  `git commit -am "examples/web-app: let-go <version>"`
  If the hint-aware change is accepted upstream but ships in a later release than the per-load fix, repeat this step for that release; the HoneySQL lines are gone only then. If it is declined, skip to the fallback in Step 5.

- [ ] **Step 4: Bump HoneySQL again (blocked until a tag contains the `upper-case` exclude)**
  Set the honeysql tag. Run the same capture and `lgx test`.
  Expected: `started`; tests pass; `grep -c 'already refers' /tmp/webapp.out` is `0`.
  `git commit -am "examples/web-app: honeysql <tag>"`

- [ ] **Step 5: Definition of done**
  Run the capture from Design.
  Expected: `started` and `0`. If HoneySQL reflection lines remain because upstream let-go declined the hint-aware change, open the follow-up HoneySQL PR described in the honeysql plan's "Not in this plan" note, bump the example to the tag that carries it, and repeat this step.

- [ ] **Step 6: Docs sync**
  Grep `docs/knowledge-base/` for `web-app`, `ensure-all!` and `coord-id`; fix any claim this work made stale, in the same commit as the last bump. Then `git commit`.
