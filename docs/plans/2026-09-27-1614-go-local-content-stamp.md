# `:go/local` content stamp Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop rebuilding the custom `lg` runtime on every command when a `:go/local` coord is in play; rebuild only when the local module's files actually changed. Then pilot the payoff in letgo-packages: the `livekit` package ships its shim in-tree with a single package tag, no nested Go module tag and no CI coord flip.

**Tech Stack:** let-go (`.lg`), `hash/xxh3-64-str`, `os/ls` + `os/stat`, the lgx unit suite and `tests/e2e.sh`; letgo-packages `livekit/`.

**Repos:** part 1 is this repo. Part 2 is `/home/agent/Projects/letgo-packages`. Part 2 runs against `bin/lgx` built from part 1 and needs no lgx release to be correct: an older lgx just keeps rebuilding on every command, as today.

---

## Design

### The problem

`runtime-paths` (`lgx/gobuild.lg`) marks a runtime `:live?` whenever any `:go/local` coord is in the tree, and `ensure-runtime!` then re-runs every build step on every command. The hash names the local *path*, not its contents, so lgx cannot tell whether the directory changed and rebuilds defensively. That was acceptable for an author's inner loop (about 1s, Go's build cache absorbs it) but it hits every consumer too: a wrapper package that keeps `{:go/local "shim"}` in its `lgx.edn` makes each downstream `lgx run` pay it, even though the gitlibs checkout it points at never changes.

letgo-packages worked around this in `docs/plans/2026-09-19-2129-letgo-packages-shim-release.md` by publishing every shim as a nested Go module (`<pkg>/shim/vX.Y.Z`) and pinning it with `:go/version`. The cost is a two-tag release in a strict order with a flip commit between, a "do not commit the flip-back" rule for authors, and a `sed` in CI that rewrites the coord so a changed shim is tested from the working tree. That plan named the real fix as a later lgx change. This is it.

### The fix: a content stamp per runtime

lgx hashes the files of every `:go/local` directory and keeps the result as a *stamp* next to the cached runtime. A runtime with local coords is reused when its stamp matches, and rebuilt when it does not.

- **`local-stamp`** (new, `gobuild.lg`): given an absolute directory, walk it depth-first with `os/ls` and `os/stat`, in sorted order, skipping any directory named `.git`. For every entry that is not a directory, take its path relative to the root and `(hash/xxh3-64-str (slurp file))`. The stamp is `hex64` of the xxh3 over the lines `<relative-path>|<content-hash>` joined with `\n`. Everything counts, `go.mod` and `go.sum` included: a dependency bump in the shim is a change. Reads only, never writes.

  **Symlinks and odd files.** let-go has no `lstat`: `os/stat` follows symlinks and reports only a directory flag, so the walk cannot tell a symlink from what it points at, nor a FIFO from a regular file. The policy: symlinks are followed (their target's content is what the build sees anyway), and a depth cap of 32 turns a symlink cycle into `die!` naming the directory, instead of an endless walk. FIFOs and devices are not handled; a Go module has no reason to contain one, and Go's own module packaging excludes symlinks and irregular files, so the docs state the rule rather than lgx defending against it.
- **`locals-stamp`** (new, pure over stamps): for the local coords in `go-pairs`, sorted by lib, `hex64` of the xxh3 over `<lib>|<local-stamp>` lines. One string covers any number of local modules.
- **`runtime-paths`** returns `:live?` true only under `LGX_LETGO_REPLACE` (a whole let-go checkout; stays always-live) and gains `:stamp`, the path `<hash>/local.stamp`.
- **`ensure-runtime!`** takes the cache hit when `out` exists, the runtime is not live, and either there are no local coords or the stamp file's content equals the freshly computed `locals-stamp`. Otherwise it deletes any old stamp, builds, and writes the stamp only after `build-runtime!` returned. A failed or interrupted build therefore leaves no stamp and the next command rebuilds.

The runtime **hash is unchanged**: it still folds in the absolute local path. Consumers at two gitlibs tags get two runtime directories (the tag is in the path), and an author's edits reuse one directory and rebuild it incrementally. The stamp decides *whether* to rebuild, never *where*.

### Why this and not "gitlibs is immutable"

Treating a `:go/local` under `$LGX_HOME/gitlibs` as immutable (option B in the discussion) is one condition and fixes consumers only. The stamp (B′) fixes consumers *and* the author's loop, which today rebuilds after every `.lg` edit, and it needs no special case for where a directory lives, so a vendored module in a monorepo gets the same treatment. The walk is the cost. A shim is a handful of files, milliseconds; a `:go/local` pointing at a large tree pays proportionally, and the docs say so. No cap: nothing today needs one.

### What changes for lgx users

- Consumers of a package with an in-tree shim get cache hits after the first build. The second `lgx run` prints no `Building custom lg runtime...`.
- Authors keep the live behaviour they rely on, triggered by content instead of unconditionally: edit `shim.go`, next command rebuilds; edit only `.lg` files, next command is a hit.
- `LGX_LETGO_REPLACE` is unchanged.
- `lgx info` is unchanged: it never reads or writes stamps and stays offline.

### Part 2: the livekit pilot in letgo-packages

`livekit/lgx.edn` currently pins `livekit/shim {:go/version "v0.1.0" :go/replace {...}}` and its README tells authors to flip to `:go/local` locally. The pilot makes `{:go/local "shim" :go/replace {...}}` the committed, permanent form:

- one tag per release, `livekit-vX.Y.Z`; the existing `livekit/shim/v0.1.0` tag stays as history and no new shim tags are cut;
- the in-repo `test/` and `example/` always build the working-tree shim, so the CI `sed` override is unnecessary for livekit (its pattern matches `:go/version` only, so it is already a no-op there; the comment must say livekit is exempt by design);
- the Releasing section of the root README gains a paragraph describing this model as the one new packages should follow, and marks livekit as the pilot. The other three shim packages keep their procedure until they are moved deliberately, one at a time, which is outside this plan.

On an lgx without the stamp, this configuration still works and merely rebuilds on each command, which is why the pilot can land before the lgx release. `.mise.toml` pins lgx for CI; bump it once the release exists.

## File Structure

**lgx (modify):**
- `lgx/gobuild.lg` — `local-stamp`, `locals-stamp`, `runtime-paths` (`:live?`, `:stamp`), `ensure-runtime!` hit test and stamp write.
- `test/lgx/gobuild_test.lg` — stamp tests over temp directories; `runtime-paths` live flag.
- `tests/e2e.sh` — one scenario proving `info` still prints nothing new and never builds (no Go invoked).
- `docs/knowledge-base/lgx-go-runtimes.md` — cache layout (`local.stamp`), rebuild policy, "what the hash does not cover".
- `docs/knowledge-base/lgx-go-wrappers.md` — "Tags come in two kinds" limit becomes the in-tree model.
- `README.md` — `:go/local` row: no longer "for development" only.
- `docs/ARCHITECTURE.md` — the `apply-runtime!`/`ensure-runtime!` paragraph.
- `docs/plans/2026-09-19-2129-letgo-packages-shim-release.md` — a status line pointing here for the deferred follow-up.

**letgo-packages (modify):** `livekit/lgx.edn`, `livekit/README.md`, `README.md` (Releasing), `.github/workflows/test.yml` (comment), `.mise.toml` (after the lgx release).

---

### Task 1: `local-stamp` and `locals-stamp`

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write the failing tests.** Build a temp module under `(os/temp-dir)` with `go.mod`, `shim.go`, a nested `internal/x.go`, and a `.git/HEAD` file. Assert: `local-stamp` is a 16-hex string; calling it twice gives the same value; changing one byte in `shim.go` changes it; adding a file changes it; renaming a file changes it (same contents, different path); writing into `.git/` does not change it; an empty directory stamps to a stable value; a directory symlink pointing at an ancestor (`ln -s .. loop` inside the temp module, via `os/sh`) makes it throw with the directory name in the message rather than hang. For `locals-stamp`: order of the local coords does not matter; a coord with no `:go/local` is ignored; the empty case returns nil.
- [x] **Step 2: Run them to see them fail.** Run: `make build && bin/lgx test`. Expected: the new tests FAIL, the rest pass.
- [x] **Step 3: Implement** both fns in the "The runtime cache key" section of `gobuild.lg`, reusing `hex64`. Use `os/ls` (names only) plus `path/join` and `os/stat`, whose record carries the directory flag (check `fileStatMapping` in let-go's `pkg/rt/os.go` for the field name). Sort entry names before recursing so the result is deterministic across filesystems.
- [x] **Step 4: Run tests.** Expected: PASS.
- [x] **Step 5: Commit.** `git commit -m "gobuild: content stamp for :go/local directories"`

> Deviation: `local-stamp` throws `ex-info` on the depth cap instead of calling `die!` (which `os/exit`s and would kill the test runner); `ensure-runtime!` turns the throw into `die!` in Task 2.

### Task 2: Stamp-gated cache hits

**Files:**
- Modify: `lgx/gobuild.lg` (`runtime-paths`, `ensure-runtime!`)
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write the failing test** for `runtime-paths`: with a `:go/local` coord and no `LGX_LETGO_REPLACE`, `:live?` is false and `:stamp` is `<dir>/local.stamp`; with `LGX_LETGO_REPLACE` set (the tests already have a pattern for env-dependent fns; follow it), `:live?` is true. Update any existing test that asserted the old live behaviour.
- [x] **Step 2: Run it to see it fail.**
- [x] **Step 3: Implement.** In `ensure-runtime!`, after the replace merge and `runtime-paths`: compute `want` as `(locals-stamp go-pairs)` (nil when no locals); `hit?` is `out` exists, not live, and `(or (nil? want) (= want (slurp stamp)))` guarded by `file-exists?`. On a miss, `delete-file` the stamp if present, build as today, then `spit` the stamp when `want` is non-nil. Update the docstring: the live case is now `LGX_LETGO_REPLACE` alone.
- [x] **Step 4: Prove it end to end.** Run `make build` first so `bin/lgx` carries the change, then use a throwaway cache against the livekit package working tree:
  ```
  cd /home/agent/Projects/letgo-packages/livekit/example
  sed -i 's#livekit/shim {:go/version "[^"]*"#livekit/shim {:go/local "shim"#' ../lgx.edn   # the pilot flip, kept in Task 5
  LGX_HOME=/tmp/lgx-stamp-home /home/agent/Projects/lgx/bin/lgx run 2>&1 | grep -c "Building custom lg runtime"
  LGX_HOME=/tmp/lgx-stamp-home /home/agent/Projects/lgx/bin/lgx run 2>&1 | grep -c "Building custom lg runtime"
  ```
  Expected: `1` then `0`, and the example's assertions pass both times. Then append a comment line to `../shim/shim.go` and run again: `1`. Revert the comment: `1` again (content differs from the last build), then `0`. Time the hit run with `time`; expect well under a second on top of the example itself.
- [x] **Step 5: A failed build leaves no stamp.** Three checks. Remove `/tmp/lgx-stamp-home/runtimes/*/lg` but keep the stamp; run once; expected: it rebuilds (the hit test requires `out`). Remove the stamp alone; expected: it rebuilds. Then, with a good build and a matching stamp in place, break `../shim/shim.go` with a syntax error and run; expected: `go build` fails, lgx exits non-zero, and `local.stamp` is gone from the runtime directory; fix the file and run; expected: a rebuild, then a hit.
- [x] **Step 6: Commit.** `git commit -m "gobuild: reuse a :go/local runtime while its stamp matches"`

> Result: fresh cache 1 build then 0 (hit run 0.69s total); shim edit 1, revert 1, then 0; missing binary, missing stamp and a broken shim all rebuild, and the broken build exits 1 with no `local.stamp` left.

> Deviation (codex review): `local.stamp` holds `runtime-stamp`, the `locals-stamp` plus `GOFLAGS=` and `CGO_ENABLED=` lines. An always-live `:go/local` runtime used to pick up `GOFLAGS=-tags=...` (the documented build-tag workaround) on every run; without these lines, switching tags would reuse a stale binary. Pinned runtimes are unchanged: they never saw `GOFLAGS` after the first build.

### Task 3: e2e and regression run

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Scenario.** Next to the existing `:go/replace` info scenarios (around line 3290): a `:built` project with `{:go/local "shim"}` pointing at a temp module dir containing a `go.mod`; `lgx info` exits zero, prints the coord's `local <abs path>` line, and prints no `Building custom lg runtime`. Make the two guarantees explicit: run it with a fresh `LGX_HOME` and assert afterwards that no `local.stamp` exists anywhere under `$LGX_HOME/runtimes` (`find` returns nothing), and run it with `PATH` stripped of the Go toolchain (the existing `:lg-runtime` scenarios show the pattern) and assert it still exits zero and reports `go` as not on PATH.
- [x] **Step 2: Run everything.** Run: `bash tests/run.sh`. Expected: unit tests PASS, e2e PASS including the new assertions.
- [x] **Step 3: Regression on consumers.** With `bin/lgx`: `cd examples/web-app && lgx run` twice (no local coords: unchanged, second run is a hit), and `cd /home/agent/Projects/letgo-packages/sqlite/example && lgx run` (the sql shim is pinned by `:go/version`, so this is a plain regression check on a no-locals runtime). Expected: PASS, no behaviour change.
- [x] **Step 4: Commit.** `git commit -m "e2e: :go/local under info stays offline"`

> Deviation: the no-Go `PATH` holds a single `sh` symlink, which `os/sh` needs to probe for `go`. No existing scenario strips Go from `PATH` to copy from.
> Note: `examples/web-app` fails on its local, git-ignored `todos.db` (the table exists but ragtime has no record of the migration), on master too. Against a fresh `DB_PATH`, both runs serve HTTP 200 with no rebuild. `sqlite/example`: two runs, no rebuild, all checks pass.

### Task 4: Documentation

**Files:**
- Modify: `docs/knowledge-base/lgx-go-runtimes.md`, `docs/knowledge-base/lgx-go-wrappers.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/plans/2026-09-19-2129-letgo-packages-shim-release.md`

- [x] **Step 1: lgx-go-runtimes.md.** Cache layout: add `local.stamp`. Rebuild policy: replace the `:go/local` bullet with the stamp rule and the "no stamp after a failed build" property; `LGX_LETGO_REPLACE` stays always-live. "What the hash does not cover": the contents are not in the *hash*, they are in the *stamp*, and why the split (one directory per declaration, rebuilt in place). Note the walk cost scales with the local tree, that `.git` is skipped, that symlinks are followed with a depth cap of 32, and that FIFOs or devices inside a `:go/local` directory are unsupported.
- [x] **Step 2: lgx-go-wrappers.md.** Rewrite the "Tags come in two kinds" bullet under Known limits: an in-tree shim with `{:go/local "shim"}` is now the recommended shape and costs one tag; the nested Go module tag is the older model that `sql`, `wails` and `duckdb` still use. Point at livekit as the worked case. Keep the `Verify against` footer accurate.
- [x] **Step 3: README.md.** The `:go/local` table row: drop "for development"; say a relative module dir, rebuilt when its files change.
- [x] **Step 4: ARCHITECTURE.md.** In the `:built` bullet of `apply-runtime!`, one sentence on the stamp.
- [x] **Step 5: 09-19 plan.** Under its status line add: the deferred lgx-side fix landed as `docs/plans/2026-09-27-1614-go-local-content-stamp.md`.
- [x] **Step 6: Commit.** `git commit -m "docs: :go/local content stamp"`

> Deviation: `lgx-go-runtimes.md` also documents the `GOFLAGS`/`CGO_ENABLED` lines in the stamp (from the Task 2 review), notes that `lgx info` can show a stale `:go/local` runtime as built, and says that deleting `local.stamp` forces a rebuild.

### Task 5: letgo-packages pilot, livekit ships its shim in-tree

**Files (letgo-packages):**
- Modify: `livekit/lgx.edn`, `livekit/README.md`, `README.md`, `.github/workflows/test.yml`

- [x] **Step 1: lgx.edn.** Make the coord `{:go/local "shim" :go/replace {...}}` permanently, and rewrite its comment: the shim ships inside the package tag; lgx 0.4.2 or newer reuses the built runtime until the shim's files change, older lgx rebuilds on each command; keep the `:go/replace` block rule. Drop the "keep on one line for CI" note.
- [x] **Step 2: livekit/README.md.** Requirements: "lgx 0.4.2 or newer for cached runs; earlier versions work but rebuild the runtime on every command". Replace the "The shim ships as the tagged Go module" paragraph with the one-tag model. Remove the local-flip instruction.
- [x] **Step 3: Root README, Releasing.** Add a short "In-tree shims" paragraph before the numbered procedure: livekit keeps its shim under `:go/local`, releases with the package tag alone, and new packages should do the same; the two-tag procedure below applies to `sql`, `wails` and `duckdb` until each is moved. Update the "Only `sql`, `wails`, `duckdb` and `livekit` have a shim" sentence accordingly.
- [x] **Step 4: CI comment.** In `test.yml`, amend the shim-override comment: packages with an in-tree shim (livekit) already test the working tree, and the `sed` pattern skips them because their coord has no `:go/version`. No behaviour change.
- [x] **Step 5: Verify.** `cd livekit && LGX_HOME=/tmp/lgx-stamp-home /home/agent/Projects/lgx/bin/lgx test` and `cd livekit/example && ... lgx run` twice (second run: no build header) and `lgx build && ./bin/app`. Expected: all PASS, exit 0.
- [x] **Step 6: Commit.** `git commit -m "livekit: ship the shim in-tree, one tag per release"`

> Result: `lgx test` (10 tests, 0 failures), `example` `lgx run` twice, `lgx build` and `./bin/app` all exit 0 with no runtime build, since the stamp from Task 2 still matches. Also reworded the root README's "Working on a shim" paragraph (it said lgx rebuilds on every command) and dropped livekit from step 3 of the two-tag procedure. The usage snippet in `livekit/README.md` still names `livekit-v0.1.0`; bump it with the Task 6 tag.

### Task 6: Release (user-triggered)

Do not run without the user's go-ahead: it tags and pushes public repos.

- [ ] **Step 1: lgx 0.4.2.** Bump `version` in `lgx.lg`, commit, tag `v0.4.2`, push, wait for the release workflow.
- [ ] **Step 2: letgo-packages.** Bump `lgx` in `.mise.toml` to `0.4.2` and commit. Tag `livekit-v0.1.1` on **that** commit (the one carrying the bump, not the Task 5 commit: CI checks out the tag and reads `.mise.toml` from it, so a tag on the earlier commit would run on 0.4.1) and push. Expected: CI runs livekit's tests on the new lgx; the runtime cache key in the workflow (`hashFiles('**/lgx.edn')`) still applies.
