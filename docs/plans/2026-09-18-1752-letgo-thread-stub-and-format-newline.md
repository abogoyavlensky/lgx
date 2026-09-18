# let-go PR: `Thread/currentThread` stub and `format` `%n`

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second small PR to `nooga/let-go` closing the two gaps `weavejester/ragtime`'s core module exposed: a `Thread/currentThread` static whose result answers `.isInterrupted` with `false`, and a `format` that understands Java's `%n`.

**Tech Stack:** Go (`pkg/rt/host_jvm_stubs.go`, `pkg/rt/lang.go`), the repo's `evalJVMStubs` test harness and `.lg` test suite, `make generate` / `make test` / `make check-generated`.

**Repo:** `~/Projects/let-go` (fork `abogoyavlensky/let-go`, `upstream` = `nooga/let-go`). Branch from `main` at `3bbde90` (synced with upstream), independent of the pending `fix/http-server-and-rest-destructure` branch so both PRs merge on their own. Gap report with repros: lgx `docs/issues/ragtime-letgo-compat.md` (G1, G2).

---

## Design

### Motivation

`ragtime.core/migrate-all` polls `(.isInterrupted (Thread/currentThread))`
between migrations, so the namespace does not compile under let-go
(`Can't resolve Thread/currentThread`). Nine of ragtime's own test
assertions build expected output with `(format "...%n")`, which let-go
renders as `%!n(MISSING)`. Both are general Clojure-compat gaps; ragtime
is the motivating library. Its `core/test` suite is the yardstick: on
`main` plus a user-side `Thread` shim it is 80 pass / 10 fail / 1 error
(the `& rest` fix from the other branch applied); after this PR the nine
`%n` failures should turn green, leaving the one JVM-thread test.

### 1. `Thread/currentThread` — `pkg/rt/host_jvm_stubs.go`

A static member on the `Thread` host namespace
(`defStaticNS("Thread").Def("currentThread", ...)`) returning a
`currentThreadStub` value: its own `ValueType` (named
`java.lang.Thread`, modelled on `chainStub`/`hostDateStubType`), and an
`InvokeMethod` that answers

- `isInterrupted` → `vm.FALSE` - true under let-go, which has no thread
  interruption; not a fake success.
- `getName` → `vm.String("main")` - the one other zero-cost method
  libraries reach for when logging.
- anything else → error `java.lang.Thread .<name> is not supported under
  let-go`, so `.interrupt`/`.join`/`.start` fail loudly like the existing
  `Thread.` constructor stub.

`Thread.`/`->Thread` stay loud stubs. `InterruptedException.` already
resolves.

### 2. `format` and `%n` — `pkg/rt/lang.go`

Clojure's `format` is `java.util.Formatter`, where `%n` is the platform
line separator and consumes no argument. `CoreFormatf` scans the format
string to coerce arguments by verb and then calls `fmt.Sprintf`; Go's
`fmt` has no `%n`, and worse, the scan would treat `n` as an
argument-consuming verb, so `(format "%n%s" "x")` would bind `x` to the
wrong slot even if `Sprintf` were taught the verb.

Fix: a pure helper

```go
// javaFormatToGo rewrites the java.util.Formatter directives fmt has no
// equivalent for: %n becomes a newline. %% is copied through untouched so
// %%n stays a literal %n.
func javaFormatToGo(s string) string
```

applied once at the top of `CoreFormatf`; both the coercion scan and
`Sprintf` use the rewritten string. `"\n"` everywhere (not
`os.PathSeparator`-style platform logic): Go convention, and what
`println` emits.

### Tests

- `test/host_jvm_stubs_test.go`, new subtest in `TestJVMStubs`:
  `(.isInterrupted (Thread/currentThread))` is `false`,
  `(.getName (Thread/currentThread))` is `"main"`,
  `(.interrupt (Thread/currentThread))` errors.
- `test/builtins_test.lg` `format-test`: `"a\nb"` for `"a%nb"`, `"%n"`
  for `"%%n"`, `"x\n"` for `(format "%s%n" "x")`, `"\nx"` for
  `(format "%n%s" "x")` (the slot-misassignment case).
- `pkg/rt/lang_format_test.go` (new, Go): table test for `javaFormatToGo`
  covering `%n`, `%%n`, `%%%n`, a trailing lone `%`, and a string with no
  directives (identity).

### Artifacts, gates, PR

`pkg/rt/*.go` are generator inputs for `pkg/rt/generated.manifest` /
`generated.sums`, so the manifests go stale on any Go change here.
`make generate` (about 15 minutes; run it as a background job, one tool
call cannot hold it) after both code commits, then a `chore:` commit
with the two refreshed manifests. Gates: `make test`, and
`go test ./pkg/genmanifest/` as the quick freshness check
(`make check-generated` regenerates the lowered tree first and is as slow
as `make generate`).

Branch `fix/ragtime-jvm-compat`. Three commits (`feat(rt)`, `fix(core)`
per the repo's `type(scope)` style, `chore`), pushed to the fork; the PR
is opened through a prefilled compare link since `gh` lacks rights on
`nooga/let-go`. No attribution lines anywhere.

### Verification

1. ragtime's suite on `build/lg` with the lgx example's `src/Thread.lg`
   *removed* from the source path: expect 89 pass / 1 fail / 1 error or
   better (only the `Thread.`-spawning test left).
2. lgx `examples/web-app` under `LGX_LETGO_REPLACE=$HOME/Projects/let-go`
   with `src/Thread.lg` deleted and its `require` dropped, in a temp copy:
   `lgx test` 4 tests / 22 assertions, `lgx run` serves.

### Out of scope

The `& rest` fix (other branch); switching the example's strategy to
`raise-error` (needs the pin to move); deleting `src/Thread.lg` from the
committed example (same).

## File Structure

In `~/Projects/let-go`:

- Modify `pkg/rt/host_jvm_stubs.go`: `currentThreadStub` type and value
  type, `Thread/currentThread` registration in `installJVMStubs`.
- Modify `test/host_jvm_stubs_test.go`: one subtest.
- Modify `pkg/rt/lang.go`: `javaFormatToGo`, two-line change in
  `CoreFormatf`.
- Create `pkg/rt/lang_format_test.go`: table test (standard MIT header
  attributed to `let-go contributors`, as recent files do).
- Modify `test/builtins_test.lg`: four assertions in `format-test`.
- Regenerate `pkg/rt/generated.manifest`, `pkg/rt/generated.sums`.

Commands run from `~/Projects/let-go`. Quick loops:
`go test ./test/ -run 'TestJVMStubs' -count=1`,
`go test ./test/ -run 'TestRunner/builtins_test' -count=1`,
`go test ./pkg/rt/ -run Format -count=1`. `make build` once at the start
so `build/lg` exists for the `.lg` suite and the verification.

---

### Task 1: Branch and `Thread/currentThread`

**Files:**
- Modify: `pkg/rt/host_jvm_stubs.go`
- Test: `test/host_jvm_stubs_test.go`

- [ ] **Step 1: Branch**
  `git checkout main && git status --short` (clean, at `3bbde90`), then
  `git checkout -b fix/ragtime-jvm-compat` and `make build`.

- [ ] **Step 2: Write the failing test**
  In `TestJVMStubs`, add subtest `"Thread/currentThread answers not
  interrupted"`: `evalJVMStubs` of
  `[(.isInterrupted (Thread/currentThread)) (.getName (Thread/currentThread))]`
  is `"[false \"main\"]"` (check `v.String()` quoting against the
  neighbouring subtests), and `(.interrupt (Thread/currentThread))`
  returns an error.

- [ ] **Step 3: Run the test to verify it fails**
  Run: `go test ./test/ -run 'TestJVMStubs' -count=1`
  Expected: FAIL, `Can't resolve Thread/currentThread`.

- [ ] **Step 4: Implement**
  In `host_jvm_stubs.go`: a `theHostThreadStubType` (copy of
  `theHostDateStubType` with `Name()` `java.lang.Thread`), a
  `currentThreadStub` struct with `Type`/`Unbox`/`String`
  (`#<java.lang.Thread main>`) and `InvokeMethod` per the Design; in
  `installJVMStubs`, next to the `Thread.` stub,
  `defStaticNS("Thread").Def("currentThread", mustWrap(...))` returning a
  fresh `&currentThreadStub{}`. Keep the existing `Thread.`/`->Thread`
  lines. `gofmt`.

- [ ] **Step 5: Run the tests to verify they pass**
  Run: `go test ./test/ -run 'TestJVMStubs' -count=1 && go vet ./pkg/rt/`
  Expected: PASS.

- [ ] **Step 6: Commit**
  `git add pkg/rt/host_jvm_stubs.go test/host_jvm_stubs_test.go && git commit -m "feat(rt): Thread/currentThread static; .isInterrupted answers false"`
  Body: the ragtime `migrate-all` poll, why `false` is honest, which
  methods fail loudly. Note the manifests are refreshed in a later commit.

### Task 2: `format` understands `%n`

**Files:**
- Modify: `pkg/rt/lang.go`
- Create: `pkg/rt/lang_format_test.go`
- Modify: `test/builtins_test.lg`

- [ ] **Step 1: Write the failing tests**
  `pkg/rt/lang_format_test.go` (package `rt`, MIT header attributed to
  `let-go contributors`, 2026): `TestJavaFormatToGo` table -
  `"a%nb"`→`"a\nb"`, `"%%n"`→`"%%n"`, `"%%%n"`→`"%%\n"`, `"100%"`→`"100%"`,
  `"plain"`→`"plain"`, `"%n"`→`"\n"`. Plus `TestCoreFormatfNewline`
  calling `CoreFormatf(vm.String("%n%s"), vm.String("x"))` expecting
  `"\nx"`.
  In `test/builtins_test.lg` `format-test`, add the four assertions from
  the Design.

- [ ] **Step 2: Run the tests to verify they fail**
  Run: `go test ./pkg/rt/ -run 'Format' -count=1`
  Expected: compile error (`javaFormatToGo` undefined).

- [ ] **Step 3: Implement**
  `javaFormatToGo` in `lang.go` directly above `CoreFormatf`: single
  pass with a `strings.Builder`; on `%` look at the next byte - `%`
  copies both and skips, `n` writes `\n` and skips, anything else (or end
  of string) copies the `%` alone. In `CoreFormatf`, set
  `fmts := javaFormatToGo(string(fmtStr))` and pass `fmts` (not
  `string(fmtStr)`) to `fmt.Sprintf`. `gofmt`.

- [ ] **Step 4: Run the tests to verify they pass**
  Run: `go test ./pkg/rt/ -run 'Format' -count=1 && go test ./test/ -run 'TestRunner/builtins_test' -count=1`
  Expected: PASS both; the `.lg` run prints the four new `PASS (= ...)`
  lines.

- [ ] **Step 5: Commit**
  `git add pkg/rt/lang.go pkg/rt/lang_format_test.go test/builtins_test.lg && git commit -m "fix(core): format understands %n as a newline, like java.util.Formatter"`
  Body: the `%!n(MISSING)` output, the argument-slot hazard, `%%n`
  preserved.

### Task 3: Regenerate manifests, full gates

**Files:**
- Regenerate: `pkg/rt/generated.manifest`, `pkg/rt/generated.sums`

- [ ] **Step 1: Regenerate (background)**
  Run as a background job: `make generate > .tmp/generate.log 2>&1; echo "rc=$?" >> .tmp/generate.log`.
  Wait for completion (about 15 minutes). Expected: `rc=0`,
  `git status` shows only the two manifests modified (no `.lg` changed,
  so the bundle is byte-identical).

- [ ] **Step 2: Freshness and the suite**
  Run: `go test ./pkg/genmanifest/ -count=1` - Expected: `ok`.
  Run as a background job: `make test > .tmp/test.log 2>&1; echo "rc=$?" >> .tmp/test.log` - Expected: `rc=0`.

- [ ] **Step 3: Commit**
  `git add pkg/rt/generated.manifest pkg/rt/generated.sums && git commit -m "chore: refresh generated manifests after the rt changes"`

### Task 4: Verify against ragtime and the lgx example, then the PR

**Files:** none committed in let-go.

- [ ] **Step 1: ragtime's suite without the shim**
  `make build`. With `/tmp/ragtime` (clone of `weavejester/ragtime` at
  `0.12.1`; re-clone if gone: `git clone -q --branch 0.12.1 --depth 1 https://github.com/weavejester/ragtime /tmp/ragtime`)
  and the runner `/tmp/ragtime-suite.lg` (requires `test`, the four
  `ragtime.*-test` namespaces, `(test/run-tests)`; drop its
  `(require 'Thread)` line):
  `LG_READ_CLJ=1 ./build/lg -source-paths /tmp/ragtime/core/src:/tmp/ragtime/core/test /tmp/ragtime-suite.lg 2>&1 | grep -E "Finished|^FAIL|ERROR in"`
  Expected: the `Finished` line reads `Tests: 19 Pass: 89 Fail: 1 Error: 1`
  or better; the only remaining failure/error is the `Thread.`-spawning
  `migrate-all-interrupted` test (note this branch lacks the `& rest`
  fix, so the strategy tests that need it may still fail - record the
  actual numbers; the `%n` lines must no longer appear among the
  failures).

- [ ] **Step 2: The lgx example without its shim**
  `cp -r ~/Projects/lgx/examples/web-app /tmp/web-app-rt && cd /tmp/web-app-rt && rm -rf bin src/Thread.lg`;
  in `src/app/migrations.lg` delete the `(require 'Thread)` line.
  Run: `LGX_LETGO_REPLACE=$HOME/Projects/let-go ~/Projects/lgx/bin/lgx test`
  Expected: `4 tests, 22 assertions, 0 failures`.
  Run `lgx run` on a free port and `curl` `POST /todos` then
  `GET /todos`; expected 201 and 200. Stop it with `kill`.
  `rm -rf /tmp/web-app-rt`.

- [ ] **Step 3: Push and open the PR**
  `git push -u origin fix/ragtime-jvm-compat`. Write the PR body to
  `.tmp/pr-body-ragtime.md` (the two changes with their one-line repros,
  the ragtime numbers before/after, the gates run), then build the
  compare link
  `https://github.com/nooga/let-go/compare/main...abogoyavlensky:let-go:fix/ragtime-jvm-compat?expand=1&title=...&body=...`
  (URL-encoded) into `.tmp/pr-link-ragtime.txt` for the user to open.
  Title: `rt: Thread/currentThread stub; core: format understands %n`.

- [ ] **Step 4: Record**
  Append the verification numbers and the PR link status to this plan's
  completion summary. Follow-up (lgx, after merge): bump the example's
  pin, delete `src/Thread.lg` and its `require`, and once the other PR is
  in too, switch the strategy to `raise-error`; mark
  `docs/issues/ragtime-letgo-compat.md` resolved.
