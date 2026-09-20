# let-go PR: `Thread/currentThread` over scopes, `format` honors `%n`

> **Status: completed 2026-09-18.** Branch pushed; PR link in `.tmp/pr2-link.txt` (see the summary at the end).

**Goal:** A second PR to `nooga/let-go` that (1) makes `Thread/currentThread`, `.isInterrupted` and `.interrupt` resolve and mean scope cancellation, so `ragtime.core` loads unpatched and gets cooperative cancellation, and (2) makes `format` translate Java's `%n` into a newline.

**Tech Stack:** Go (`pkg/rt/host_thread.go`, `pkg/rt/lang.go`), let-go `.lg` tests under `test/`, the repo's `make test` / `make generate` / `make check-generated` gates, `weavejester/ragtime` 0.11.0 `core/` as the end-to-end probe.

**Repo:** `~/Projects/let-go` (fork `abogoyavlensky/let-go`, remote `upstream` = `nooga/let-go`). Branch `feat/thread-interrupt-and-format-newline` off `main` `3bbde90` (upstream `main` has nothing newer). Independent of the open `fix/http-server-and-rest-destructure` PR: no shared source files; both refresh the generated manifests, which merge trivially by regenerating.

---

## Design

### Motivation

Spiking `weavejester/ragtime` (core module) as the migration layer of lgx's
`examples/web-app` found two let-go gaps (`docs/plans/2026-09-18-1400-...`
records the third, the `& rest` destructuring bug, already in the open PR):

1. `ragtime.core` does not load: `migrate-all` checks
   `(.isInterrupted (Thread/currentThread))` and throws
   `(InterruptedException. ...)`. `Thread/currentThread` is unresolved, so
   the whole namespace fails to compile.
2. `format` passes `%n` straight to Go's `Sprintf`, which has no such
   verb: `(format "Applying %s%n" "x")` is `"Applying x%!n(MISSING)"`. Only
   ragtime's tests hit it, but it is a general Java-`format` divergence.

With a scratch copy of ragtime that drops the interrupt check, the whole
library works under let-go (strategies, migrate, rollback, conflict
detection, its own suite at 80/90 assertions with every failure being `%n`).

### 1. `Thread/currentThread` is the current scope

let-go already has every piece but the object: `InterruptedException` is a
registered exception class (`pkg/vm/exception_class.go`; constructor and
`catch` work), `Thread.` is a loud stub in `pkg/rt/host_jvm_stubs.go`,
`scope-cancelled?` reads a scope's context, and `Scope.Cancel()` exists.

New file `pkg/rt/host_thread.go` (MIT header attributed to
`let-go contributors`, year 2026):

```go
// hostThread is what Thread/currentThread returns: the calling scope,
// dressed as a java.lang.Thread. Interruption is scope cancellation.
type hostThread struct{ scope *vm.Scope }
```

with a `theHostThreadType` value type named `java.lang.Thread` (the
`host_stringbuilder.go` shape) and `InvokeMethod`:

| Method | Behaviour |
|---|---|
| `isInterrupted` | `scope.Context().Err() != nil` - the same test `scope-cancelled?` makes |
| `interrupt` | `scope.Cancel()`; returns `nil` |
| anything else | the `host_jvm_stubs.go` wording: `java.lang.Thread .<name> is not supported under let-go` |

`Thread/currentThread` is a `vm.NewCtxNativeFn` on `defStaticNS("Thread")`
returning `&hostThread{ec.Scope()}`. Registered from `installJVMStubs`
(next to the existing `Thread.` stub, which stays a loud stub: only
ragtime's test wants a real constructor). No `Thread/sleep` (`os/sleep`
exists).

**The one decision worth a second look:** `.interrupt` really cancels the
current scope. Inside `with-scope` that is precise. At the root scope it
cancels every tracked goroutine's context for the rest of the process
(`Cancel` does not reinstall a generation; `CancelAll` does, but then
`isInterrupted` would read false again at once, which matches no Java
semantics). That is what interrupting the main thread means in effect, and
the docs say so rather than soften it. The approved alternative, if this
proves controversial in review, is a loud stub for `.interrupt` only.

`String()` renders `#<java.lang.Thread scope=N>` using the scope's live
count, so a REPL user sees what it is.

### 2. `format` honors `%n`

`CoreFormatf` (`pkg/rt/lang.go:6734`) scans the format string to type the
arguments, then calls `fmt.Sprintf`. Add a rewrite pass before that scan:
walk the string once, copying to a builder; `%%` is copied as-is (two
bytes, so `%%n` stays a literal `%n`); `%n` becomes `\n`; everything else
is copied verbatim. The rewritten string is what both the scan and
`Sprintf` see (the final call becomes `fmt.Sprintf(fmts, args...)`, not
`string(fmtStr)`), so `%n` never consumes an argument. Java's `%n` is the
platform line separator; let-go emits `\n` on every platform, same as
`println`.

### Tests

- `test/host_thread_test.lg` (ns `test.host-thread-test`,
  `(:require [test :refer :all])`):
  - `.isInterrupted` is `false` on a fresh program.
  - inside `(with-scope [s] ...)`: after `(.interrupt (Thread/currentThread))`,
    `.isInterrupted` is `true` and `(scope-cancelled? s)` agrees.
  - the ragtime shape, **inside `with-scope`** so it never cancels the test
    runner's root scope: a `doseq` over three ids that throws
    `(InterruptedException. (str "before " id))` when interrupted, where the
    second step interrupts; caught with `(catch InterruptedException e ...)`,
    the message names the third id, only two steps ran, and after the
    `with-scope` form `(.isInterrupted (Thread/currentThread))` is `false`
    again (the parent scope was untouched).
  - `(.getName (Thread/currentThread))` throws, message contains
    `not supported under let-go`.
  - `Thread.` still throws (unchanged).
- `test/host_jvm_stubs_test.go`: one resolution probe for
  `(Thread/currentThread)` next to the existing `Thread.` case.
- `test/builtins_test.lg` `format-test`: `(format "a%nb")` = `"a\nb"`,
  `(format "%d%%%n" 100)` = `"100%\n"`, `(format "%%n")` = `"%n"`,
  `(format "%s%n%s" "a" "b")` = `"a\nb"`.
- Gates: `make test`; `make generate` (a Go change under `pkg/rt` moves the
  generator-input digest, so `generated.manifest`/`generated.sums` must be
  refreshed and committed); `make check-generated`.
- End to end: unpatched ragtime 0.11.0 `core/` under the branch build:
  `ragtime.core` loads, the spike's smoke script runs, and ragtime's core
  suite (minus the two tests that construct a `Thread.`) is 90/90.

### Docs

`docs/guide/clojure-compatibility.md`, "Behavioral differences", two bullets:

- `Thread/currentThread` is the current scope: `.isInterrupted` is scope
  cancellation and `.interrupt` cancels the scope (inside `with-scope` it is
  bounded; at the root it cancels the whole program's tracked work).
  `Thread.` itself is not supported.
- `format` is Go `fmt` underneath; Java's `%n` is honored as `\n`.

### Commits and PR

Two commits in the repo's `type(scope): summary` style, no attribution
lines: `feat(host): Thread/currentThread over the scope tree` and
`fix(core): format honors %n`, with the manifest refresh in the second
(last `pkg/rt` touch). PR via the compare link (the `gh` token cannot open
PRs on `nooga/let-go`); body lists both changes with the ragtime
motivation.

## File Structure

In `~/Projects/let-go`:

- Create `pkg/rt/host_thread.go`: `theHostThreadType`, `hostThread`,
  `InvokeMethod`, `installHostThread(ns)` (called from `installJVMStubs`).
- Modify `pkg/rt/host_jvm_stubs.go`: call `installHostThread`; the
  `Thread.` stub comment notes that `Thread/currentThread` is real.
- Modify `pkg/rt/lang.go`: `formatNewlines` helper + its call in
  `CoreFormatf`.
- Create `test/host_thread_test.lg`.
- Modify `test/host_jvm_stubs_test.go`, `test/builtins_test.lg`.
- Modify `docs/guide/clojure-compatibility.md`.
- Regenerate `pkg/rt/generated.manifest`, `pkg/rt/generated.sums`.

Commands run from `~/Projects/let-go`. `go test ./test/ -run 'TestRunner/<file>' -count=1`
runs one `.lg` file. `make test` takes ~2 min; `make generate` ~15 min and
`make check-generated` ~10 min: each must be its own background job (a
tool call is capped at 10 min). Scratch ragtime material from the spike
lives in `/tmp` and may be gone; how to rebuild each:

- `/tmp/ragtime-src`: `git clone --branch 0.11.0 --depth 1 https://github.com/weavejester/ragtime /tmp/ragtime-src`.
- `/tmp/ragtime-test/ragtime`: copy `core/test/ragtime/*.clj` from that
  clone, then delete from `core_test.clj` the `interrupted-migration`
  helper and the `test-migrate-all-interrupted` deftest (both need a real
  `Thread.`).
- `/tmp/ragtime-suite.lg`: `(require 'test)`, `require` each of
  `ragtime.strategy-test`, `ragtime.reporter-test`, `ragtime.core-test`,
  `ragtime.repl-test`, then `(test/run-tests)`.
- `/tmp/ragtime-smoke.lg`: require `ragtime.core`/`protocols`/`strategy`/
  `repl`; a `MemStore` record (applied ids in an atom) implementing
  `p/DataStore`; a `FnMigration` record implementing `p/Migration` over
  up/down fns; three migrations; print `strategy/apply-new`, `raise-error`,
  `rebase` on `["001"]` vs `["001" "002"]`; `repl/migrate`, `repl/rollback`
  by count and by id; `core/migrate-all` on a store holding `["zzz"]`
  inside `try`, expecting the `Conflict!` message; end with
  `(println :smoke-done)`.

---

### Task 1: `Thread/currentThread`, `.isInterrupted`, `.interrupt`

**Files:**
- Create: `pkg/rt/host_thread.go`, `test/host_thread_test.lg`
- Modify: `pkg/rt/host_jvm_stubs.go`, `test/host_jvm_stubs_test.go`

- [x] **Step 1: Branch**
  `git checkout main && git status --short` (clean), then
  `git checkout -b feat/thread-interrupt-and-format-newline`. `make build`
  once so `build/lg` exists.

- [x] **Step 2: Write the failing tests**
  `test/host_thread_test.lg` with the five cases from Design/Tests. Add to
  `test/host_jvm_stubs_test.go` a case asserting `(Thread/currentThread)`
  compiles and evaluates without error (the file's `evalJVMStubs` helper).

- [x] **Step 3: Run the tests to verify they fail**
  Run: `go test ./test/ -run 'TestRunner/host_thread' -count=1 2>&1 | grep -E "Can't resolve|FAIL|^ok" | head -3`
  Expected: the file fails to load with `Can't resolve Thread/currentThread`.
  Run: `go test ./test/ -run TestJVMStubs -count=1 2>&1 | tail -3`
  Expected: FAIL on the new probe.

- [x] **Step 4: Implement**
  `pkg/rt/host_thread.go` per Design §1: the value type, the struct,
  `InvokeMethod` (`isInterrupted`, `interrupt`, else the not-supported
  error), `String()`, and `installHostThread(ns *vm.Namespace)` that does
  `defStaticNS("Thread").Def("currentThread", <NewCtxNativeFn>)` where the
  fn rejects arguments and returns `&hostThread{scope: ec.Scope()}`. Call
  it from `installJVMStubs` after the `Thread.` stub lines; update that
  stub's comment.

- [x] **Step 5: Run the tests to verify they pass**
  Run: `make build 2>&1 | tail -1 && go test ./test/ -run 'TestRunner/host_thread|TestJVMStubs' -count=1 2>&1 | grep -E "Finished|FAIL|^ok"`
  Expected: `Finished running tests. Tests: 5 Pass: N Fail: 0 Error: 0`, `ok`.
  Also `gofmt -l pkg/rt/ | grep -v core_go_lowered` prints nothing and
  `go vet ./pkg/rt/` is clean.

- [x] **Step 6: Probe ragtime unpatched**
  Run: `LG_READ_CLJ=1 ./build/lg -source-paths /tmp/ragtime-src/core/src /tmp/ragtime-smoke.lg 2>&1 | grep -v "reflection warning" | tail -4`
  Expected: `:smoke-done` after the conflict line (no `Can't resolve`).

- [x] **Step 7: Commit**
  `git add pkg/rt/host_thread.go pkg/rt/host_jvm_stubs.go test/host_thread_test.lg test/host_jvm_stubs_test.go && git commit -m "feat(host): Thread/currentThread over the scope tree"`
  Body: the mapping table, the root-scope caveat, ragtime as motivation.

> Deviation: `installHostThread()` takes no `ns` argument — it only touches
> `defStaticNS("Thread")`, so the core namespace is never needed.
> Deviation: the unpatched-ragtime probe (Step 6) cannot pass on this branch
> alone: ragtime's `strategy/unzip` uses `[[x & coll]]`, the `& rest` bug fixed
> in the open `fix/http-server-and-rest-destructure` PR. Ran it on a throwaway
> worktree (`/tmp/lg-merged`) merging both branches instead: `:smoke-done`.
> Commit `8f3079c`.

### Task 2: `format` honors `%n`

**Files:**
- Modify: `pkg/rt/lang.go`, `test/builtins_test.lg`

- [x] **Step 1: Write the failing tests**
  Extend `format-test` in `test/builtins_test.lg` with the four `%n`
  assertions from Design/Tests.

- [x] **Step 2: Run the tests to verify they fail**
  Run: `go test ./test/ -run 'TestRunner/builtins' -count=1 2>&1 | grep -E "FAIL \(|Finished" | head -6`
  Expected: 3 FAIL lines showing `%!n(MISSING)` (`(format "%%n")` already
  yields `"%n"` and keeps passing).

- [x] **Step 3: Implement**
  In `pkg/rt/lang.go`, above `CoreFormatf`, add `formatNewlines(s string) string`
  doing the single pass from Design §2, with a comment on why (`Sprintf` has
  no `%n`; `%%n` must stay literal). Call it on `fmts` at the top of
  `CoreFormatf` and change the final `fmt.Sprintf(string(fmtStr), args...)`
  to `fmt.Sprintf(fmts, args...)`, so both the argument scan and `Sprintf`
  use the rewritten string.

- [x] **Step 4: Run the tests to verify they pass**
  Run: `make build 2>&1 | tail -1 && go test ./test/ -run 'TestRunner/builtins' -count=1 2>&1 | grep -E "Finished|^ok|FAIL"`
  Expected: 0 failures.

- [x] **Step 5: Regenerate and gate**
  Run in the background (each is its own job): `make generate`, then
  `make check-generated`, then `make test`.
  Expected: all three succeed; `git status` shows `generated.manifest` and
  `generated.sums` modified (no `.lg` changed, so the bundle is byte-identical).

- [x] **Step 6: Commit**
  `git add pkg/rt/lang.go test/builtins_test.lg pkg/rt/generated.manifest pkg/rt/generated.sums && git commit -m "fix(core): format honors %n"`
  Body: the `%!n(MISSING)` symptom, `%%n` stays literal, "make generate
  after this change" for the manifests.

> Deviation: `formatNewlines` short-circuits when the string has no `%n`
> (`strings.Contains`), so the common case allocates nothing. Same single
> pass otherwise. Commit `41563df`.

### Task 3: Docs, ragtime suite, PR

**Files:**
- Modify: `docs/guide/clojure-compatibility.md`

Use /writing-clearly.

- [x] **Step 1: Docs**
  Add the two "Behavioral differences" bullets from Design/Docs. Bump the
  file's `last-verified` to today.
  Run: `python3 scripts/docs_frontmatter_hook.py docs/guide/clojure-compatibility.md`
  Expected: exit 0.
  `git add docs/guide/clojure-compatibility.md && git commit -m "docs(compat): Thread/currentThread is the scope; format honors %n"`

- [x] **Step 2: Ragtime's own suite, unpatched**
  Run: `LG_READ_CLJ=1 ./build/lg -source-paths /tmp/ragtime-src/core/src:/tmp/ragtime-test /tmp/ragtime-suite.lg 2>&1 | grep -E "^Finished|FAIL \("`
  Expected: `Tests: 18 Pass: 90 Fail: 0 Error: 0` (the spike baseline was
  80/90 with a patched copy; the 10 were `%n`). The two excluded tests
  (`interrupted-migration` helper and `test-migrate-all-interrupted`) need a
  real `Thread.` and stay out.

> Deviation: 89/90, not 90/90, on the branch merged with PR #898 (the
> `& rest` fix ragtime's `strategy/unzip` needs). The remaining failure is
> `(prn (type ds))` on a record: let-go prints `InMemoryDB`, JVM Clojure
> `ragtime.core_test.InMemoryDB`. The spike's 80/90 count masked it because
> that assertion also contains `%n`. Out of scope; noted in the PR body.

- [x] **Step 3: Push and PR**
  `git push -u origin feat/thread-interrupt-and-format-newline`. Write the
  PR body to `.tmp/pr2-body.md` (both changes, the mapping table with the
  root-scope caveat, the `%n` symptom, gates run, ragtime 0.11.0 core suite
  90/90 as the end-to-end), then build the prefilled compare link with
  title `host: Thread/currentThread over scopes; core: format honors %n`
  into `.tmp/pr2-link.txt` (the `gh` token cannot open PRs on
  `nooga/let-go`). Record the link in this plan.

  Pushed as `abogoyavlensky/let-go` `feat/thread-interrupt-and-format-newline`
  at `82482bf`. Body: `~/Projects/let-go/.tmp/pr2-body.md`; prefilled link:
  `~/Projects/let-go/.tmp/pr2-link.txt` (opens
  `nooga/let-go/compare/main...abogoyavlensky:let-go:feat/thread-interrupt-and-format-newline`).

- [x] **Step 4: Note the lgx follow-up**
  Append to this plan: once both let-go PRs merge, `examples/web-app` moves
  its pin to the merged sha and gains the ragtime migration layer from the
  spike (`/tmp/web-app-rt/src/app/migrations.lg`, `app.db` calling
  `migrations/migrate!`, ragtime `core/` as a git dep with
  `:deps/root "core"`).

---

## lgx follow-up

Once both let-go PRs (#898 and this one) merge, `examples/web-app` moves its
pin to the merged sha and gains the ragtime migration layer from the spike:
`/tmp/web-app-rt/src/app/migrations.lg` (may need rebuilding from the spike
notes), `app.db` calling `migrations/migrate!`, and ragtime `core/` as a git
dep with `:deps/root "core"`.

## Completion summary

**Implemented** (branch `feat/thread-interrupt-and-format-newline`, three
commits on `main` `3bbde90`, pushed to the fork):

- `8f3079c` feat(host): `pkg/rt/host_thread.go` - `Thread/currentThread`
  returns the calling scope as a `java.lang.Thread`; `.isInterrupted` reads
  scope cancellation, `.interrupt` calls `Scope.Cancel()`, other methods fail
  loudly. `Thread.` stays a stub. Tests: `test/host_thread_test.lg` (5 tests,
  13 assertions) and a resolution probe in `test/host_jvm_stubs_test.go`.
- `41563df` fix(core): `formatNewlines` in `pkg/rt/lang.go` rewrites `%n` to
  `\n` before the argument scan and `Sprintf`; `%%n` stays literal. Four
  assertions in `test/builtins_test.lg`. Manifests regenerated.
- `82482bf` docs(compat): two "Behavioral differences" bullets,
  `last-verified` bumped.

**Gates:** `make test`, `make generate`, `make check-generated` all green;
`gofmt` and `go vet ./pkg/rt/` clean. Codex reviewed each commit: no
findings on any of the three.

**End to end:** unpatched ragtime 0.11.0 `core/` loads; the smoke script
(strategies, migrate, rollback by count and id, conflict detection) reaches
`:smoke-done`; ragtime's core suite is 89/90.

**Issues encountered:** the end-to-end probes cannot pass on this branch
alone, because ragtime's `strategy/unzip` uses the `[[x & coll]]` shape fixed
in PR #898. Both probes ran on a throwaway worktree merging the two branches
(removed afterwards). No source conflicts; the manifests merged cleanly.

**Deviations, gathered:**
- `installHostThread()` takes no `ns` argument (only `defStaticNS("Thread")`
  is touched).
- `formatNewlines` short-circuits on strings without `%n`.
- Ragtime probes ran on a merged worktree, not this branch alone.
- Ragtime suite is 89/90, not 90/90: the `(prn (type ds))` record-naming
  divergence is out of scope and named in the PR body.
- `TaskCreate`/`TaskUpdate` were unavailable in the session; this document
  was the only tracking surface.

**What the plan could have specified better:** that the ragtime end-to-end
probe depends on PR #898's `& rest` fix and must run on a merged build, and
that the spike's "every failure is `%n`" count hid a second cause in one
assertion (the 90/90 target was one too high).
