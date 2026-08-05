# Native os/unzip + hash/sha1/sha256 in let-go Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two native capabilities to upstream let-go — `(os/unzip zip-path dest-dir)` and `(hash/sha1 s)` / `(hash/sha256 s)` — as two independent branches/PRs, so lgx's Maven host can later drop its `unzip`/`sha1sum` shell-outs.

**Tech Stack:** let-go (Go VM + `.lg` stdlib in `/Users/andrew/Projects/let-go`; fork `origin` = abogoyavlensky/let-go, PRs to `upstream` = nooga/let-go), branches `feat-os-unzip` and `feat-hash-sha`.

---

## Design

### Context and motivation

lgx's Maven dependency resolution (see
`docs/plans/2026-08-05-0228-mvn-deps.md`) supplies grenadine with a host
effect map whose `:extract-jar!` and `:digest` functions shell out to
`unzip` and `sha1sum`/`sha256sum` (`shasum` fallback on macOS) — the only
host-binary requirements the feature has, and a portability wart. Native
equivalents in let-go remove both. They are generally useful stdlib
additions regardless.

Swapping lgx's shell-outs for these natives is a separate lgx follow-up
once an lg release ships them — explicitly out of scope here.

### The two natives

**`(os/unzip zip-path dest-dir)`** — extract a zip archive.

- Lives in `pkg/rt/os.go` inside `installOsNS` (same
  `vm.NativeFnType.Wrap` + `ns.Def` style as `os/sh`), inheriting the
  file's `//go:build !tinygo` gate — consistent with the rest of the os
  namespace, and archive extraction needs a real filesystem anyway.
- Implementation: Go stdlib `archive/zip`. For each entry: resolve the
  target as `filepath.Join(dest, entry.Name)` and require the cleaned
  result to stay under `dest` (**zip-slip guard** — error out on
  escapes, mirroring grenadine's JVM host); create parent directories;
  directories from dir entries; skip symlink entries (mode bit check) —
  safety over fidelity; write files with the entry's mode when sane,
  else 0644 (dirs 0755); overwrite existing files.
- The lexical guard alone does not stop escapes through a *pre-existing*
  symlink directory under `dest` (entry `link/x` where `dest/link` →
  outside). After the lexical check, resolve the target's parent with
  `filepath.EvalSymlinks` and re-verify it is under the resolved `dest`;
  error out otherwise. (Symlink *entries* are already skipped, so such
  links can only pre-exist in dest.)
- Returns `dest-dir` (String). Failures return Go errors, surfacing as
  let-go exceptions.
- Arity/type errors follow the existing message style
  (`"os/unzip expects 2 args"`, `"os/unzip expected String path"`).

**`(hash/sha1 s)` and `(hash/sha256 s)`** — lowercase hex digest of the
input string's bytes.

- let-go strings are raw Go byte strings, so these hash binary content
  correctly (e.g. a jar slurped from disk) — that is the point.
- New file `pkg/rt/hash_sha.go` with **no build tags**: `crypto/sha1`
  and `crypto/sha256` are pure Go, so tinygo/wasm builds get them too
  (unlike xxh3, which needs the murmur3 fallback machinery).
- Registers the fns into the `hash` namespace via a `RegisterInstaller`
  init, the same pattern as `installOsNS`/`installHttpNS`.
- `pkg/rt/core/hash.lg` declares `(ns hash)` and currently documents the
  namespace as "non-cryptographic hash utilities" — update the
  docstring comment to cover the cryptographic digests.
- Accept a single String arg; non-String → clear error. Return
  lowercase hex (String), matching `sha1sum`/`sha256sum` output.

### Load-order verification (do this first)

Installers run at Go init; core `.lg` files (including `hash.lg`) load
afterwards. The `(ns hash)` form in `hash.lg` must *extend* the
Go-registered namespace, not clobber it. `pkg/rt/ions.go` pre-seeding
`spit` into a namespace later extended from `.lg` suggests this is the
normal, supported pattern — but verify with a 2-minute probe (register a
dummy def, eval `(hash/sha1 "")` after full boot) before building on it.
If clobbering does occur, the fallback is registering a distinct Go-side
ns (e.g. `sha`) and having `hash.lg` alias the fns — decide only if the
probe fails.

### Branch and PR strategy

Two branches off `upstream/main`, two PRs — independent concerns,
independent review and merge fates:

- `feat-os-unzip` → PR "feat(rt): add os/unzip"
- `feat-hash-sha` → PR "feat(rt): add sha1/sha256 to hash ns"

Commit messages follow the repo's conventional style seen in the log
(`feat(rt): …`). Each PR is self-contained: implementation + tests +
any doc listing the namespace's fns (check README/docs for os and hash
fn listings; update if present).

### Testing strategy

- **unzip, Go test** (`pkg/rt/os_unzip_test.go`, `!tinygo` tag): build
  zips programmatically with `archive/zip` into `t.TempDir()` — no
  fixture files. Cases: flat files; nested dirs; explicit dir entries;
  overwrite of an existing file; a `../evil.txt` entry → must error and
  must not create the file outside dest; a pre-existing symlink dir in
  dest pointing outside + an entry writing through it → must error and
  leave the link target untouched; return value is dest.
  Exercise the native through the rt eval path used by existing
  `pkg/rt` tests (see `http_test.go` / `language_test.go` helpers)
  where practical, else test the extracted Go helper directly and keep
  a thin `.lg`-level smoke.
- **unzip, .lg test** (`test/os_unzip_test.lg`, `os_test.lg` style):
  happy-path only — but constructing a zip needs the Go side, so ship a
  tiny checked-in fixture zip under `test/` (one nested text file,
  < 200 bytes) and assert extraction + content via `slurp`.
- **sha, .lg test** (`test/hash_sha_test.lg`): known vectors —
  `(hash/sha1 "")` = `da39a3ee5e6b4b0d3255bfef95601890afd80709`,
  `(hash/sha256 "")` =
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
  plus `"abc"` vectors and a spit/slurp round-trip of a small binary
  string to prove byte-safety.
- Full gate per branch: `make test` plus `go test ./... -count=1`; when
  a `.lg` under `pkg/rt/core/` changed (the hash.lg docstring counts),
  also `make generate` — commit the regenerated artifacts
  (`generated.sums`, `core_compiled.lgb`, lowered-Go files) — and
  `make check-generated`. The Makefile (comment near line 74) is
  explicit that core `.lg` edits without regeneration fail CI.

### Out of scope

- Swapping lgx's host shell-outs (lgx follow-up after a release)
- Updating lgx's `docs/knowledge-base/let-go-stdlib-quick-ref.md`
  (belongs with the lg-pin bump in lgx)
- Streaming/bytes-returning digest variants; zip *creation*; tar/gzip
- tinygo os support (os ns is already `!tinygo`)

---

## File Structure

All paths relative to `/Users/andrew/Projects/let-go`.

Branch `feat-os-unzip`:
- **Modify** `pkg/rt/os.go` — add the `os/unzip` native to `installOsNS`.
- **Create** `pkg/rt/os_unzip_test.go` — Go tests incl. zip-slip.
- **Create** `test/os_unzip_test.lg` — `.lg` smoke test.
- **Create** `test/fixtures-unzip/sample.zip` (or the repo's preferred
  fixture location — follow existing `test/` conventions) — tiny fixture.

Branch `feat-hash-sha`:
- **Create** `pkg/rt/hash_sha.go` — installer with sha1/sha256.
- **Modify** `pkg/rt/core/hash.lg` — docstring update.
- **Create** `test/hash_sha_test.lg` — vector tests.

---

### Task 1: Branch + load-order probe (feat-hash-sha)

**Files:**
- None yet (probe only)

- [ ] **Step 1: Branch off upstream main**
  Run: `cd /Users/andrew/Projects/let-go && git fetch upstream && git checkout -b feat-hash-sha upstream/main`

- [ ] **Step 2: Probe installer/ns load order**
  Temporarily register a dummy fn into the `hash` ns from a Go installer,
  build (`make` or the repo's dev build target), and eval
  `(hash/xxh3-64 "x")` + the dummy — both must resolve. Revert the probe.
  Expected: `.lg`-declared ns extends the Go-seeded one. If not, adopt
  the fallback from the Design section and adjust the remaining tasks.

### Task 2: hash/sha1 + hash/sha256

**Files:**
- Create: `pkg/rt/hash_sha.go`
- Modify: `pkg/rt/core/hash.lg`
- Test: `test/hash_sha_test.lg`

- [ ] **Step 1: Write the failing test**
  `test/hash_sha_test.lg` in `os_test.lg` style
  (`(ns test.hash-sha-test (:require [test :refer :all]))`): the empty
  and `"abc"` vectors for both fns, non-string arg → throws, binary
  round-trip: spit a string with high bytes, slurp, digest, compare to
  digest of the literal.

- [ ] **Step 2: Run test to verify it fails**
  Run the repo's targeted `.lg`-test invocation for the new file (check
  how `go test ./test/...` selects cases; fall back to `make test`).
  Preserve the command's exit status — no `| grep` pipelines.
  Expected: FAIL — `hash/sha1` unresolved.

- [ ] **Step 3: Implement**
  `pkg/rt/hash_sha.go`: `RegisterInstaller(installHashShaNS)` defining
  `sha1` and `sha256` via `vm.NativeFnType.Wrap` — hash the String's
  bytes with `crypto/sha1`/`crypto/sha256`, return `hex.EncodeToString`.
  No build tags. Update the `hash.lg` header comment to mention the
  cryptographic digests. Follow the copyright header style of
  neighboring files.

- [ ] **Step 4: Regenerate committed artifacts**
  The hash.lg edit touches `pkg/rt/core/` — run `make generate`, then
  `make check-generated`. Stage the regenerated files it produces
  (`generated.sums`, `core_compiled.lgb`, lowered-Go outputs).
  Expected: check-generated passes.

- [ ] **Step 5: Run tests to verify they pass**
  Run: `make test && go test ./... -count=1`
  Expected: PASS, including all pre-existing tests.

- [ ] **Step 6: Commit and push**
  `git add pkg/rt/hash_sha.go pkg/rt/core/hash.lg test/hash_sha_test.lg`
  plus the regenerated artifacts, then
  `git commit -m "feat(rt): add sha1/sha256 to hash ns"` and
  `git push -u origin feat-hash-sha`.

### Task 3: os/unzip

**Files:**
- Modify: `pkg/rt/os.go`
- Test: `pkg/rt/os_unzip_test.go`, `test/os_unzip_test.lg`, fixture zip

- [ ] **Step 1: Branch**
  Run: `git checkout -b feat-os-unzip upstream/main`
  (independent of feat-hash-sha).

- [ ] **Step 2: Write the failing Go test**
  `pkg/rt/os_unzip_test.go` (`//go:build !tinygo`): helper builds a zip
  with `archive/zip` in `t.TempDir()`. Cases per the Design testing
  section (flat, nested, dir entries, overwrite, zip-slip `../evil.txt`
  errors AND leaves no file behind, returns dest). Call through the rt
  eval helper pattern used by existing pkg/rt tests where practical.

- [ ] **Step 3: Run test to verify it fails**
  Run: `go test ./pkg/rt/ -run TestOsUnzip -count=1`
  Expected: FAIL — fn not defined.

- [ ] **Step 4: Implement os/unzip**
  In `installOsNS` (`pkg/rt/os.go`), following the `os/sh` wrap style
  and the error-message conventions. Zip-slip guard: clean the joined
  path and require `strings.HasPrefix(target, dest+separator)` (or
  `filepath.Rel` without `..`). Skip symlink entries. `ns.Def("unzip", …)`
  alongside the existing defs.

- [ ] **Step 5: Run Go tests to verify they pass**
  Run: `go test ./pkg/rt/ -run TestOsUnzip -count=1`
  Expected: PASS.

- [ ] **Step 6: Add the .lg smoke test**
  Create the tiny fixture zip (one nested text file; generate once with
  any zip tool, keep < 200 bytes) in the location `test/` conventions
  suggest, and `test/os_unzip_test.lg` asserting extraction into a temp
  dir + `slurp` content match.

- [ ] **Step 7: Full suite**
  Run: `make test && go test ./... -count=1`
  Expected: PASS. (No `pkg/rt/core/` `.lg` changed on this branch, so
  no regeneration is needed.)

- [ ] **Step 8: Commit and push**
  `git add pkg/rt/os.go pkg/rt/os_unzip_test.go test/os_unzip_test.lg`
  plus the fixture zip, then
  `git commit -m "feat(rt): add os/unzip"` and
  `git push -u origin feat-os-unzip`.

### Task 4: Open the PRs

**Files:**
- None

- [ ] **Step 1: Check for fn-listing docs**
  Grep let-go's README/docs for os/hash namespace fn listings; if the
  new fns belong there, check out the respective branch, add the doc
  entry there, and amend/commit on that branch (never mix the two).

- [ ] **Step 2: Open both PRs against nooga/let-go**
  Run: `gh pr create --repo nooga/let-go --head abogoyavlensky:feat-hash-sha …`
  and likewise for `feat-os-unzip`. Each PR body: what the fn does, the
  zip-slip guard / hex-return contract, test coverage note, and the
  motivating use case (dependency tooling built on let-go needing
  archive extraction + digests without host binaries). If `gh` lacks
  permissions, fall back to the /github-issue-link-style manual URL or
  ask the user to push/PR.

- [ ] **Step 3: Report PR URLs**
  Surface both URLs to the user; done.
