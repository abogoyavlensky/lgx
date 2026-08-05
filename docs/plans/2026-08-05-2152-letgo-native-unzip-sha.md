# Native os/unzip + hash/sha1/sha256 in let-go Implementation Plan

> **STATUS: COMPLETE** (2026-08-05) — both natives implemented, tested and
> committed locally. Branches are deliberately **unpushed** and **no PRs were
> opened**: the user took that over mid-run. See the summary at the end.

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

- [x] **Step 1: Branch off upstream main**
  Run: `cd /Users/andrew/Projects/let-go && git fetch upstream && git checkout -b feat-hash-sha upstream/main`

  > Deviation: `git fetch upstream` fails in this environment (SSH publickey
  > denied). Verified via `git ls-remote https://github.com/nooga/let-go.git`
  > that the local `upstream/main` (6f75229) is current, and branched off it.

- [x] **Step 2: Probe installer/ns load order**
  Temporarily register a dummy fn into the `hash` ns from a Go installer,
  build (`make` or the repo's dev build target), and eval
  `(hash/xxh3-64 "x")` + the dummy — both must resolve. Revert the probe.
  Expected: `.lg`-declared ns extends the Go-seeded one. If not, adopt
  the fallback from the Design section and adjust the remaining tasks.

  > Result: PASS. Temp installer registered `hash/probe-marker`; after
  > `make build`, `(println hash/probe-marker (hash/xxh3-64 "x"))` printed
  > `probe-ok -1517593895512126191` — the `.lg`-declared `(ns hash)`
  > extends the Go-seeded namespace. No fallback needed. Probe reverted.

### Task 2: hash/sha1 + hash/sha256

**Files:**
- Create: `pkg/rt/hash_sha.go`
- Modify: `pkg/rt/core/hash.lg`
- Test: `test/hash_sha_test.lg`

- [x] **Step 1: Write the failing test**
  `test/hash_sha_test.lg` in `os_test.lg` style
  (`(ns test.hash-sha-test (:require [test :refer :all]))`): the empty
  and `"abc"` vectors for both fns, non-string arg → throws, binary
  round-trip: spit a string with high bytes, slurp, digest, compare to
  digest of the literal.

- [x] **Step 2: Run test to verify it fails**
  Run the repo's targeted `.lg`-test invocation for the new file (check
  how `go test ./test/...` selects cases; fall back to `make test`).
  Preserve the command's exit status — no `| grep` pipelines.
  Expected: FAIL — `hash/sha1` unresolved.

  > Note: the targeted invocation is
  > `go test ./test/ -run 'TestRunner/hash_sha_test.lg' -short -count=1`
  > (`TestRunner` in `test/language_test.go` walks `test/*.lg` as subtests).
  > Failed as expected: `Can't resolve hash/sha1 in this context`.

- [x] **Step 3: Implement**
  `pkg/rt/hash_sha.go`: `RegisterInstaller(installHashShaNS)` defining
  `sha1` and `sha256` via `vm.NativeFnType.Wrap` — hash the String's
  bytes with `crypto/sha1`/`crypto/sha256`, return `hex.EncodeToString`.
  No build tags. Update the `hash.lg` header comment to mention the
  cryptographic digests. Follow the copyright header style of
  neighboring files.

- [x] **Step 4: Regenerate committed artifacts**
  The hash.lg edit touches `pkg/rt/core/` — run `make generate`, then
  `make check-generated`. Stage the regenerated files it produces
  (`generated.sums`, `core_compiled.lgb`, lowered-Go outputs).
  Expected: check-generated passes.

  > Deviation: the lowered-Go tree (`pkg/rt/core_go_lowered/`) is
  > **gitignored** — a build artifact, not committed (see `.gitignore` and
  > the `check-generated` comment). Only `core_compiled.lgb` and
  > `generated.sums` changed and were staged. `make check-generated`: OK on
  > all four gates.

- [x] **Step 5: Run tests to verify they pass**
  Run: `make test && go test ./... -count=1`
  Expected: PASS, including all pre-existing tests.

  > Both exit 0. `make lint` cannot install golangci-lint in this
  > environment, but the repo's pre-commit hook runs
  > `golangci-lint ./pkg/rt` and reported 0 issues.

- [x] **Step 6: Commit** (push deferred — user will push)
  `git add pkg/rt/hash_sha.go pkg/rt/core/hash.lg test/hash_sha_test.lg`
  plus the regenerated artifacts, then
  `git commit -m "feat(rt): add sha1/sha256 to hash ns"` and
  `git push -u origin feat-hash-sha`.

  > Deviation: user asked mid-run not to push branches or open PRs.
  > Committed locally as `87b3afa`; `feat-hash-sha` is left unpushed.

### Task 3: os/unzip

**Files:**
- Modify: `pkg/rt/os.go`
- Test: `pkg/rt/os_unzip_test.go`, `test/os_unzip_test.lg`, fixture zip

- [x] **Step 1: Branch**
  Run: `git checkout -b feat-os-unzip upstream/main`
  (independent of feat-hash-sha).

- [x] **Step 2: Write the failing Go test**
  `pkg/rt/os_unzip_test.go` (`//go:build !tinygo`): helper builds a zip
  with `archive/zip` in `t.TempDir()`. Cases per the Design testing
  section (flat, nested, dir entries, overwrite, zip-slip `../evil.txt`
  errors AND leaves no file behind, returns dest). Call through the rt
  eval helper pattern used by existing pkg/rt tests where practical.

  > Deviation: pkg/rt cannot import pkg/compiler (import cycle), so no
  > `.lg`-eval helper exists in-package — `evalInterop` and friends live in
  > `test/`. Used the pkg/rt-native pattern instead (`async_test.go`):
  > resolve `NS("os").Lookup(vm.Symbol("unzip"))` and `Invoke` it, which
  > still exercises the registered native end to end.
  >
  > Added beyond the plan's case list: extraction into a missing
  > destination; entry-mode handling; a pre-existing symlink AT the target
  > path (the ancestor guard structurally cannot see that one); a missing
  > archive; and the full arity/type matrix.

- [x] **Step 3: Run test to verify it fails**
  Run: `go test ./pkg/rt/ -run TestOsUnzip -count=1`
  Expected: FAIL — fn not defined.

  > Failed as expected: every case reported `os/unzip not found`.

- [x] **Step 4: Implement os/unzip**
  In `installOsNS` (`pkg/rt/os.go`), following the `os/sh` wrap style
  and the error-message conventions. Zip-slip guard: clean the joined
  path and require `strings.HasPrefix(target, dest+separator)` (or
  `filepath.Rel` without `..`). Skip symlink entries. `ns.Def("unzip", …)`
  alongside the existing defs.

  > Two additions the plan didn't anticipate, both inside its stated
  > safety intent:
  > 1. A pre-existing symlink AT the target path is dropped before writing.
  >    Its parent is legitimately inside dest, so the ancestor check cannot
  >    catch it, and `O_CREATE` would otherwise write straight through it.
  > 2. Entry permissions come from the recorded unix mode
  >    (`ExternalAttrs >> 16`), not `f.Mode()`. `archive/zip` synthesizes
  >    0666 for DOS/FAT-written entries, so the plan's "else 0644" fallback
  >    would never have fired and files would land world-writable under a
  >    permissive umask.

- [x] **Step 5: Run Go tests to verify they pass**
  Run: `go test ./pkg/rt/ -run TestOsUnzip -count=1`
  Expected: PASS.

  > PASS. Also re-run under `umask 077` — the mode assertions check the
  > meaningful bits rather than an exact mode, so they hold either way.

- [x] **Step 6: Add the .lg smoke test**
  Create the tiny fixture zip (one nested text file; generate once with
  any zip tool, keep < 200 bytes) in the location `test/` conventions
  suggest, and `test/os_unzip_test.lg` asserting extraction into a temp
  dir + `slurp` content match.

  > Deviation: no binary fixture is checked in. `test/` is otherwise
  > entirely text (no committed binaries anywhere under it), and
  > `(io/decode :base64 …)` returns a raw byte string that `spit` writes
  > verbatim — so the 319-byte fixture is embedded as base64 in the test
  > and materialised at run time. Same coverage, no binary blob.

- [x] **Step 7: Full suite**
  Run: `make test && go test ./... -count=1`
  Expected: PASS. (No `pkg/rt/core/` `.lg` changed on this branch, so
  no regeneration is needed.)

  > Both `make test` and `go test ./... -count=1` exit 0. Confirmed no
  > regeneration needed — nothing under `pkg/rt/core/` changed.

- [x] **Step 8: Commit** (push deferred — user will push)
  `git add pkg/rt/os.go pkg/rt/os_unzip_test.go test/os_unzip_test.lg`
  plus the fixture zip, then
  `git commit -m "feat(rt): add os/unzip"` and
  `git push -u origin feat-os-unzip`.

  > Deviation: user asked mid-run not to push branches or open PRs.
  > Committed locally as `5fb02b6`; `feat-os-unzip` is left unpushed. No
  > fixture zip to add (see Step 6).

- [x] **Step 9 (added): address the codex review** — fixup `8789fca`
  The review found the hand-rolled containment guard wrong in three ways
  and unfixable in a fourth. All four were real; verified the first by
  reproducing it before changing anything. Replaced the guard with
  `os.Root` (go1.24; go.mod already requires go 1.26), which opens each
  path component under dest and refuses any that escapes.

  1. **Relative dest was broken.** `EvalSymlinks(".")` returns `"."`, not
     an absolute path, so once a nested dir existed its resolved parent
     (`sub`) failed the prefix check — `(os/unzip z ".")` died partway
     through on an ordinary archive. Filesystem roots had the same
     separator bug. No path arithmetic remains to get wrong.
  2. **Overwrite ignored the entry mode.** `O_CREATE` applies perm only on
     creation, so an executable entry overwriting a non-executable file
     stayed non-executable. Target is now removed first — which also
     subsumes the pre-existing-symlink-at-target case.
  3. **Directory entries were pinned at 0755**, widening a recorded 0700.
     Recorded modes are honoured now, with owner rwx forced on so a
     read-only dir entry listed before its contents can't make the rest
     of the archive unextractable.
  4. **Check-then-write race.** The old guard resolved a path then wrote
     to it; a process sharing dest could swap a validated directory for a
     symlink in between. `os.Root` enforces containment during traversal,
     so there is no window — this one the old approach could not fix.

  > Deliberate behaviour change: an absolute entry name is now refused
  > outright rather than silently re-rooted inside dest by `filepath.Join`.

  Regression tests added for each. Net effect is also less code: the
  lexical guard, `nearestExistingPath`, and `pathWithin` all went away.

- [x] **Step 10 (added): second review round** — fixup `d179410`
  Round 2 found two more, both cases where a *failed* extraction was
  worse than no extraction. Both confirmed to fail against `8789fca`
  before fixing — the second with the destination file actually gone.

  1. **Dir entry colliding with an existing file was swallowed.**
     `root.Mkdir` returns `EEXIST` and `EEXIST` was treated as benign, so
     extraction reported success while `foo` stayed a file. Now accepted
     only after confirming the target really is a directory.
  2. **A file entry was destroyed before we knew it could be replaced.**
     `f.Open` fails on an unsupported compression method, but the
     destination had already been removed — a recoverable "can't read
     this archive" became irreversible data loss. Entry is opened first.

### Task 4: Open the PRs — **NOT DONE (user took this over)**

> Mid-run instruction: "do not open PRs on your own, stop before pushing
> branches - I will do it myself." Step 1 was still worth doing and was
> done; Steps 2-3 are the user's.

**Files:**
- None

- [x] **Step 1: Check for fn-listing docs**
  Grep let-go's README/docs for os/hash namespace fn listings; if the
  new fns belong there, check out the respective branch, add the doc
  entry there, and amend/commit on that branch (never mix the two).

  > Result: there are none. let-go's docs have no exhaustive per-namespace
  > fn listing for `os` or `hash` — `docs/guide/go-interop.md` mentions
  > `hash/xxh3-*` only as a worked interop *example*, not a reference list.
  > Nothing to update, so nothing was added to either branch.

- [ ] **Step 2: Open both PRs against nooga/let-go** — USER'S
  Run: `gh pr create --repo nooga/let-go --head abogoyavlensky:feat-hash-sha …`
  and likewise for `feat-os-unzip`. Each PR body: what the fn does, the
  zip-slip guard / hex-return contract, test coverage note, and the
  motivating use case (dependency tooling built on let-go needing
  archive extraction + digests without host binaries). If `gh` lacks
  permissions, fall back to the /github-issue-link-style manual URL or
  ask the user to push/PR.

- [ ] **Step 3: Report PR URLs** — USER'S
  Surface both URLs to the user; done.

---

## Completion summary

### What was implemented

**`feat-hash-sha`** (1 commit, `87b3afa`, off `upstream/main` 6f75229)
- `pkg/rt/hash_sha.go` — untagged installer seeding `hash/sha1` and
  `hash/sha256`; lowercase hex of the string's bytes.
- `pkg/rt/core/hash.lg` — docstring extended to cover the digests.
- `test/hash_sha_test.lg` — 13 assertions: empty and `"abc"` vectors for
  both, a multibyte literal pinned to real `sha1sum`/`sha256sum` output
  (proving byte- not rune-semantics), a spit/slurp round-trip, and
  arity/type rejection.
- Regenerated `core_compiled.lgb` + `generated.sums`.

**`feat-os-unzip`** (1 commit, `5cf0553`, off the same base — squashed from
`5fb02b6` + 2 review fixups at the user's request; tree verified identical
to the pre-squash tip)
- `pkg/rt/os.go` — `os/unzip`, extraction confined by `os.Root`.
- `pkg/rt/os_unzip_test.go` — 17 Go tests, archives built programmatically.
- `test/os_unzip_test.lg` — 6-assertion smoke test, fixture embedded as
  base64.

### Verification

- `make test` and `go test ./... -count=1` green on both branches at their
  final commits; `make check-generated` OK on all four gates.
- `os/unzip` Go tests re-run under umask 022, 077 and 000.
- End-to-end through a real built `lg`:
  - extracted a `zip(1)`-produced archive — nested dirs, executable bit
    preserved, 5000-byte random binary byte-identical (`diff -r` clean);
  - a python-built zip-slip archive was refused with a clear error, nothing
    escaped, and the legitimate entry still extracted;
  - `hash/sha1` and `hash/sha256` over a slurped 13.6 MB binary matched
    `sha1sum` / `sha256sum` exactly.
- Three codex review rounds on the unzip branch (one on hash, clean).

### Deviations (all recorded inline above)

1. `git fetch upstream` unavailable (SSH publickey denied); verified
   `upstream/main` current via `git ls-remote` over https instead.
2. Lowered-Go artifacts are gitignored, not committed — only
   `core_compiled.lgb` and `generated.sums` were staged.
3. pkg/rt cannot import pkg/compiler, so the Go tests drive the native via
   `NS("os").Lookup(...).Invoke(...)` rather than an `.lg`-eval helper.
4. No binary fixture zip checked in — embedded as base64, since `test/` is
   otherwise entirely text.
5. Entry permissions derive from the recorded unix attrs, not `f.Mode()`
   (the plan's "else 0644" fallback could never fire).
6. Absolute entry names are refused rather than silently re-rooted.
7. Containment via `os.Root` instead of the plan's hand-rolled lexical +
   `EvalSymlinks` guard — see Step 9.
8. Branches unpushed, no PRs (user's mid-run instruction).

### Issues encountered

The hand-rolled containment guard the plan specified was wrong in **four**
ways, all caught by review, none by my own tests: it broke ordinary
extraction into a relative destination, ignored entry modes on overwrite,
pinned directory modes at 0755, and left a check-then-write race it could
not close. A second round found two more data-loss bugs in the rewrite.
Every finding was verified by reproduction before being fixed. The lesson
is narrow and concrete: **hand-rolled path containment is the wrong default
when `os.Root` exists** — the stdlib primitive was safer *and* less code.

### What the plan could have specified better

The plan specified an *implementation technique* for the security-critical
part ("clean the joined path and require `strings.HasPrefix(target,
dest+separator)`, or `filepath.Rel` without `..`") rather than the
*property* to guarantee. That framing steered the work straight into a
hand-rolled guard and away from `os.Root`, which the repo's own `go 1.26`
directive had made available all along. For anything where the stdlib has a
purpose-built primitive, a plan should state the invariant and require a
survey of stdlib support before pinning the mechanism.

Two smaller specification gaps: the plan asserted the lowered-Go artifacts
were committed when they are gitignored, and it assumed a `pkg/rt`-level
`.lg`-eval helper exists when the import cycle forbids one. Both are the
kind of claim a fast staleness check catches — worth pinning to a file:line
in the plan so verification is mechanical.
