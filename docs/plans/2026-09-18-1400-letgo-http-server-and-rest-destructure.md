# let-go PR: stoppable http server, `:headers {}` fix, `& rest` destructuring fix

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR to `nooga/let-go` that (1) makes `[x & more]` destructuring bind `nil` instead of `()`, (2) stops the http server panicking on a `:headers {}` response, and (3) adds `http/start`, `http/stop` and `http/wait` so a server can be stopped, with `http/serve` rebuilt on them.

**Tech Stack:** Go (`pkg/rt/http.go`, `net/http`, `httptest`), let-go core (`pkg/rt/core/core.lg`), the repo's `make generate` / `make test` gates, the lgx `examples/web-app` project for the end-to-end check.

**Repo:** `~/Projects/let-go` (fork `abogoyavlensky/let-go`, remote `upstream` = `nooga/let-go`). Local `main` is synced to upstream `3bbde90`. All work happens there; this plan lives in lgx because the issues and the end-to-end example do.

---

## Design

### Why these three together

The lgx `examples/web-app` project (a JSON API over sqlite with integrant)
surfaced all three in one afternoon, and each is shaped by the others:
the server cannot be a proper integrant component without a stop, the
component chain hangs because of the destructuring bug, and the 204
response had to drop its `:headers` map. The issue notes are
`docs/issues/destructure-rest-empty-seq.md` and
`docs/issues/http-empty-headers-panic.md` in lgx.

### 1. `[x & more]` binds `nil`

`pkg/rt/core/core.lg` `destructure-vector` (line 754 at `3bbde90`) expands
the rest binding to `(drop i n)`. `drop` returns an empty lazy seq, which is
truthy, so `(if-let [[x & xs] s] ...)` loops never terminate.
`weavejester/dependency`'s `reachable?` is one such loop, and it runs on
every `dep/depend` whose target already has an edge, so integrant hangs on
any three-component chain (subject to map iteration order). Plain fn rest
args are unaffected: the compiler handles those and already yields `nil`.

Fix: `(list 'seq (list 'drop i n))`. `seq` of an exhausted `drop` is `nil`,
which is what Clojure's `nthnext` gives. `nthnext` itself is defined about
2000 lines later in `core.lg`, and the expansion has to resolve while the
bootstrap compiles earlier `let` forms, so `seq` + `drop` is the smallest
change that works.

Editing `core.lg` requires `make generate`: it rewrites
`pkg/rt/core_compiled.lgb` and `pkg/rt/generated.sums` (committed) and
the lowered Go tree `pkg/rt/core_go_lowered/` (gitignored, regenerated
by the CI gate). `pkg/genmanifest`'s freshness test fails otherwise. The
two committed artifacts go in the same commit as the source change, as
upstream does (`30a793b`).

### 2. `ServeHTTP` skips a nil header entry

`pkg/rt/http.go` `ServeHTTP` iterates `:headers` with
`for s := sq.Seq(); s != nil; s = s.Next()`. An empty map's seq yields one
`vm.NIL` entry; `vm.NIL` satisfies `Sequable`, its `Seq()` is nil, and
`es.Next().First()` dereferences it. The connection dies with
`http: panic serving ...` and the client gets no reply.

Fix: the guard upstream added to the three client sites in `30a793b`
(#849), `if entry == vm.NIL { continue }`, applied to the server loop. No
refactor of the four copies into a helper: the diff stays a mirror of the
client fix and reviewable in isolation.

### 3. A stoppable server

Today `http/serve` is `http.ListenAndServe` on the calling goroutine: no
handle, no stop, and a bind failure is the only way it returns. New API in
the `http` namespace:

| Form | Behaviour |
|---|---|
| `(http/start handler addr)` | Binds now (`net.Listen`; a bad address throws from `start`), serves on a goroutine tracked by the caller's scope, returns an `http/Server` record. |
| `(http/stop server)` / `(http/stop server timeout-ms)` | Graceful `Shutdown`; after `timeout-ms` (default 5000) falls back to `Close`. Idempotent. Returns `nil`. Accepts the record or its `:server` value. |
| `(http/wait server)` | Blocks until the server has stopped. `nil` after a clean stop (`http.ErrServerClosed`), otherwise the error `Serve` returned. |
| `(http/serve handler addr)` | Unchanged contract (blocks), now `start` + `wait`. |

The record, registered as `http/Server` next to `http/Request` and
`http/Response` in `pkg/rt/types.go`:

```go
type HTTPServer struct {
    Addr   string   `letgo:"addr"`   // "127.0.0.1:8080", from the listener
    Port   int      `letgo:"port"`   // resolved port, so ":0" is usable
    Server vm.Value `letgo:"server"` // boxed *lgServer
}
```

`lgServer` (private to `http.go`) holds the `*http.Server`, the listener,
a `done` channel, the resulting error, and a `sync.Once` for stop.
`done` means "fully stopped", not "`Serve` returned": Go's `Shutdown`
makes `Serve` return `ErrServerClosed` at once, before in-flight
requests drain, so `done` is closed by the stop path after `Shutdown`
(or the `Close` fallback) returns, and by the serving goroutine only
when `Serve` fails with some other error (the listener died). `wait`
blocks on `done`. `stop` and `wait` unbox the server from the record's
`:server` or accept the boxed value directly.

Scope cancellation, matching what #848 did for the clients: `start` and
`serve` are `vm.NewCtxNativeFn`s, the serving goroutine is spawned with
`ec.Scope().Go`, and a helper goroutine selects on the scope context and
calls the same stop path when it is cancelled. Both vars carry the
`scope-cancellation` meta the client fns have. Nothing in the CLI drains
the root scope at exit today, so a running server does not delay process
exit.

### Docs

No guide covers the `http` namespace at all. Add `docs/guide/http.md`
with the repo's frontmatter (`status: active`, `last-verified`, empty
`human-verified`) covering: the handler contract (request map keys,
response map: `:status` default 200, `:headers`, body kinds incl. the
streaming ones from #851), `serve`, `start`/`stop`/`wait` with a
`":0"` example, and the one-line client summary pointing at the fns.
`known-divergences.md` gets no entry: fix 1 removes a divergence.

### Testing

- Fix 1: `.lg` tests in `test/destructure_comprehensive_test.lg` (the
  suite `go test ./test/...` compiles every `test/*.lg`). Assert `nil` for
  `[1]`, `nil`, a `loop`, and that the `reachable?` shape from
  `dependency` terminates.
- Fix 2: Go test with `httptest.NewRecorder` and `vm.EmptyPersistentMap`
  as `:headers`, in the existing `pkg/rt/http_test.go` style.
- Feature 3: Go tests in a new `pkg/rt/http_server_test.go` (start on
  `:0`, GET, stop, refused; bad address; double stop; scope cancel), and
  one `.lg` test `test/http_server_test.lg` driving `start`, `:port`,
  `http/get`, `stop`, `wait` from the language.
- Gates: `make generate`, `make check-generated`, `make test`,
  `go test ./pkg/rt/`.
- End to end: the lgx `examples/web-app` under `LGX_LETGO_REPLACE`, with
  the handler restored as a third integrant component, the 204 carrying
  `:headers {}`, and the server component using `start`/`stop`. That copy
  is not committed to lgx until a `nooga/let-go` sha carries the fixes;
  the follow-up is noted at the end.

### Commits and PR

Branch `fix/http-server-and-rest-destructure` from `main`. Three commits,
one per change, in the repo's `type(scope): summary` style, then a PR to
`nooga/let-go` whose body lists the three items and the two lgx issue
notes. Commit messages carry no attribution lines.

## File Structure

In `~/Projects/let-go`:

- Modify `pkg/rt/core/core.lg`: `destructure-vector`, one form.
- Regenerate `pkg/rt/core_compiled.lgb` and `pkg/rt/generated.sums` (via
  `make generate`; the lowered tree it also rewrites is gitignored).
- Modify `test/destructure_comprehensive_test.lg`: rest-binding tests.
- Modify `pkg/rt/http.go`: the nil-entry guard in `ServeHTTP`; `lgServer`,
  `startServer`, `stopServer`, `waitServer`; `start`/`stop`/`wait`/`serve`
  natives and their registration.
- Modify `pkg/rt/types.go`: `HTTPServer` struct and `httpServerMapping`.
- Modify `pkg/rt/http_test.go`: empty-headers test.
- Create `pkg/rt/http_server_test.go`: start/stop/wait tests.
- Create `test/http_server_test.lg`: language-level start/stop test.
- Create `docs/guide/http.md`.

In `~/Projects/lgx` (verification only, nothing committed there by this
plan except the plan document itself): a temp copy of
`examples/web-app`.

Commands run from `~/Projects/let-go` unless stated. `make test` takes
about two minutes; `go test ./pkg/rt/ -run 'Http|Handler'` is the quick
loop for the Go side. `go test ./test/ -run TestRunner -count=1` runs
the `.lg` suite (`TestRunner` in `test/language_test.go`); narrow it with
`-run 'TestRunner/<file>'` if the subtest names allow.

---

### Task 1: Branch, and the destructuring fix

**Files:**
- Modify: `pkg/rt/core/core.lg`
- Modify: `test/destructure_comprehensive_test.lg`
- Regenerate: `pkg/rt/core_compiled.lgb`, `pkg/rt/generated.sums`

- [x] **Step 1: Branch**
  `git checkout main && git status --short` (clean) then
  `git checkout -b fix/http-server-and-rest-destructure`.
  `make build` once so `build/lg` exists (the `.lg` test runner and
  `make generate` need it).

- [x] **Step 2: Write the failing tests**
  In `test/destructure_comprehensive_test.lg`, next to
  `rest-in-destructuring`, add `rest-binding-is-nil-when-exhausted`:
  - `(let [[a & more] [1]] more)` is `nil`
  - `(let [[a & more] nil] more)` is `nil`
  - `(loop [[x & xs] [1 2]] (if x (recur xs) xs))` is `nil`
  - the `dependency` shape terminates: a copy of `reachable?` (the
    `if-let [[node & more] unexpanded]` loop from
    `weavejester/dependency`, with `neighbors` a map) returns `false` for
    `{:b #{:a}}`, from `:b` to `:c`. Guard it against a hang: wrap in a
    `future` and `deref` with a timeout if `deref` supports one, else
    accept that a regression hangs this test (note that in a comment).
  - `[a b & rest]` on `[1 2 3 4 5]` still gives `(3 4 5)` (already covered
    by `rest-in-destructuring`; leave it).

- [x] **Step 3: Run the tests to verify they fail**
  Run: `go test ./test/ -run TestRunner -count=1 2>&1 | grep -A3 "rest-binding-is-nil"`
  Expected: FAIL, `more` is `()`.

- [x] **Step 4: Implement**
  In `destructure-vector`, change `(list 'drop i n)` to
  `(list 'seq (list 'drop i n))`. Nothing else in the fn changes.

- [x] **Step 5: Regenerate and verify**
  Run: `make generate && make check-generated`
  Expected: both succeed; `git status` shows `core_compiled.lgb` and
  `generated.sums` modified (the lowered tree is gitignored and will not
  appear).
  Run: `make test`
  Expected: PASS, including the new test and the rest of the
  destructuring suite (a `&` binding that is now `nil` where a test
  expected `()` would show up here; fix the test only if `()` was never
  the Clojure answer).

> Deviation: `make generate` also rewrites `pkg/rt/generated.manifest`
> (committed, content hashes); included in the commit alongside the
> `.lgb` and `generated.sums`.
> Deviation (codex review): the expansion emits `clojure.core/seq`, not
> bare `seq`, so a local named `seq` cannot capture it (regression test
> added); fixup commit `7973696`. `make generate` takes ~15 min here and
> has to run in the background: a single tool call is capped at 10 min.

- [x] **Step 6: Commit**
  `git add -A && git commit -m "fix(core): [x & more] destructuring binds nil, not (), when exhausted"`
  Body: what `drop` did, why `seq`+`drop` over `nthnext`, the
  `dependency`/integrant symptom, and "make generate after this change".

### Task 2: `ServeHTTP` accepts `:headers {}`

**Files:**
- Modify: `pkg/rt/http.go`
- Test: `pkg/rt/http_test.go`

- [x] **Step 1: Write the failing test**
  `TestHandlerResponseAcceptsEmptyHeaders` in `pkg/rt/http_test.go`,
  modelled on `TestHandlerResponseHeadersUseRawStrings`: the handler
  returns `{:status 204 :headers {} :body ""}` with
  `vm.EmptyPersistentMap` as the headers value; assert `rec.Code == 204`.

- [x] **Step 2: Run the test to verify it fails**
  Run: `go test ./pkg/rt/ -run TestHandlerResponseAcceptsEmptyHeaders -count=1`
  Expected: FAIL with a nil-pointer panic from `ServeHTTP`.

- [x] **Step 3: Implement**
  In `ServeHTTP`'s header loop, after `entry := s.First()`, add
  `if entry == vm.NIL { continue }`, exactly as the three client loops
  have it.

- [x] **Step 4: Run the tests to verify they pass**
  Run: `go test ./pkg/rt/ -run 'Handler' -count=1`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -am "fix(http): http/serve accepts an empty :headers map"`
  Body: the panic line, the client-side precedent (#849).

### Task 3: `http/start`, `http/stop`, `http/wait`; `serve` on top

**Files:**
- Modify: `pkg/rt/http.go`, `pkg/rt/types.go`
- Create: `pkg/rt/http_server_test.go`, `test/http_server_test.lg`

- [x] **Step 1: Write the failing Go tests**
  `pkg/rt/http_server_test.go` (build tag `!tinygo && !lg_no_http` like
  its siblings). Helper: a handler `vm.Fn` answering 200 `"ok"`. Tests call
  the unexported Go helpers directly (`startServer`, `stopServer`,
  `waitServer`; signatures in Step 3), not through the VM:
  - `TestServerStartServesAndStops`: start on `"127.0.0.1:0"`, `http.Get`
    the record's `:addr` returns 200/`ok`, `stop`, a second `Get` fails
    with a connection error, `wait` returns nil.
  - `TestServerStartRejectsBadAddress`: `"127.0.0.1:99999"` (or a port
    already held by a test listener) returns an error from `start`.
  - `TestServerStopIsIdempotent`: `stop` twice, no panic, `wait` nil.
  - `TestServerStopsOnScopeCancel`: start under `vm.Goroutines.Child()`,
    cancel the child scope, `wait` returns within a second.
  - `TestServerStopDrainsActiveRequest`: a handler that blocks on a gate
    channel; issue a GET on a goroutine, call `stop` with a generous
    timeout, assert `wait` has *not* returned while the gate is closed,
    open the gate, assert the GET completes with 200 and then `wait`
    returns nil (this is the `done`-after-`Shutdown` contract).
  - `TestServerStopForcesCloseAfterTimeout`: same gated handler, `stop`
    with a 50 ms timeout, never open the gate; `wait` returns within a
    second and the GET fails.

- [x] **Step 2: Run the tests to verify they fail**
  Run: `go test ./pkg/rt/ -run TestServer -count=1`
  Expected: compile error, helpers undefined.

- [x] **Step 3: Implement the Go side**
  In `pkg/rt/types.go`: `HTTPServer` struct (shape in Design) and
  `httpServerMapping = vm.RegisterStruct[HTTPServer]("http/Server")` in
  `initTypeMappings`.
  In `pkg/rt/http.go`:
  - `type lgServer struct { srv *http.Server; ln net.Listener; done chan struct{}; err error; stopOnce sync.Once }`
  - `startServer(scope *vm.Scope, ctx context.Context, handler vm.Fn, addr string) (*lgServer, error)`:
    `net.Listen("tcp", addr)`; on error return it. Build `http.Server`
    with `&Handler{fn: handler}`. `scope.Go` a goroutine that runs
    `srv.Serve(ln)`; if the error is anything but `http.ErrServerClosed`,
    store it and close `done` (via a `doneOnce`). On `ErrServerClosed` it
    does nothing: the stop path owns `done`. A second `scope.Go`
    goroutine selects on `ctx.Done()` (then `stopServer` with the default
    timeout) and `done`.
  - `stopServer(s *lgServer, timeout time.Duration)`: under `stopOnce`,
    `Shutdown` with a `context.WithTimeout`; if that returns the
    deadline error, `Close`; then close `done` (same `doneOnce`). A
    caller that races `stopOnce` and loses returns immediately; `wait`
    is how it observes completion.
  - `waitServer(s *lgServer) error`: `<-done`, return `err`.
  - `serverRecord(s *lgServer) vm.Value`: `httpServerMapping.StructToRecord`
    with `Addr` = `ln.Addr().String()`, `Port` from `ln.Addr().(*net.TCPAddr)`,
    `Server` = `vm.NewBoxed(s)`.
  - `unboxServer(v vm.Value) (*lgServer, error)`: the boxed value, or a
    record/`vm.Lookup` whose `:server` is one; else an execution error
    naming what was passed.
  Natives, all `vm.NewCtxNativeFn`:
  - `http/start [handler addr]` → `startServer(ec.Scope(), ec.Context(), ...)`,
    returns the record; a listen error becomes the fn's error.
  - `http/stop [server & timeout-ms]` → `stopServer`, returns `vm.NIL`.
    `timeout-ms` must be an `vm.Int`; default 5000.
  - `http/wait [server]` → `waitServer`; error propagates.
  - `http/serve [handler addr]` → `startServer` then `waitServer` (the
    scope-cancel goroutine from `startServer` gives it cancellation for
    free). Same arity and error messages as today.
  Registration: `ns.Def` for the three new fns; `serve` and `start` get
  the `scope-cancellation` meta the clients carry.

- [x] **Step 4: Run the Go tests**
  Run: `go test ./pkg/rt/ -run 'TestServer|Handler' -count=1 -race`
  Expected: PASS, no race reports.

- [x] **Step 5: Write the language-level test**
  `test/http_server_test.lg` (ns `test.http-server-test`, `(:require [test :refer :all])`):
  `(http/start handler "127.0.0.1:0")`, assert `(pos? (:port srv))`,
  `(http/get (str "http://" (:addr srv) "/"))` returns status 200 and the
  body, `(http/stop srv)` is `nil`, `(http/wait srv)` is `nil`, and a
  second `http/get` throws (wrap in `try`). Check `test/language_test.go`
  for any skip rule on network tests before relying on it in CI.
  Run: `go test ./test/ -run TestLanguage -count=1 2>&1 | grep -B2 -A6 "http-server"`
  Expected: PASS.

- [x] **Step 6: Full gates**
  Run: `make check-generated && make test`
  Expected: PASS (no `.lg` in `pkg/rt/core` changed in this task, so
  nothing to regenerate).

> Deviation: `unboxServer` checks for the boxed handle before probing a
> `Lookup`: `*vm.Boxed` is itself a `Lookup` (by reflection) and panics on
> `ValueAt`. Added `TestServerRecordExposesAddrAndPort` and
> `TestServerWaitReportsServeError` beyond the plan's list.
> Deviation: the docs guide was also added to the `docs/README.md` index
> (`docs_status.py` reports unindexed guides).

- [x] **Step 7: Commit**
  `git add -A && git commit -m "feat(http): http/start, http/stop and http/wait; serve is start + wait"`
  Body: the record shape, the default stop timeout, scope cancellation
  parity with the clients (#848), and that `serve`'s contract is
  unchanged.

### Task 4: `docs/guide/http.md`

**Files:**
- Create: `docs/guide/http.md`

Use /writing-clearly.

- [x] **Step 1: Write the guide**
  Frontmatter as in `docs/guide/os.md` (`status: active`,
  `last-verified: 2026-09-18`, `human-verified:` empty). Sections:
  "Serving" (handler contract: request map keys as `HTTPRequest`
  declares them, `:request-method` keyword; response `:status` default
  200, `:headers` map or nil, body: string, reader, channel or lazy seq
  streamed per #851), "Starting and stopping" (`start`/`stop`/`wait`,
  the record, `":0"`, default timeout, scope cancellation), "Client"
  (`get`/`post`/`request` in three lines; `:as :stream`). Keep it under
  ~120 lines; examples runnable.

- [x] **Step 2: Check the frontmatter hook**
  Run: `python3 scripts/docs_status.py 2>&1 | grep -i http` (and whatever
  `docs/frontmatter-hook.md` names as the check script).
  Expected: the new page listed without a frontmatter complaint.

- [x] **Step 3: Commit**
  `git add docs/guide/http.md && git commit -m "docs(guide): http namespace - serving, start/stop/wait, clients"`

### Task 5: End-to-end against the lgx example, then the PR

**Files:** none committed in let-go; a temp copy of
`~/Projects/lgx/examples/web-app`.

- [x] **Step 1: Build the branch's `lg`**
  Run: `make build` in `~/Projects/let-go`. Note `build/lg` and `bin/lg`.

- [x] **Step 2: Restore the three-component shape in a temp copy**
  `cp -r ~/Projects/lgx/examples/web-app /tmp/web-app-e2e && cd /tmp/web-app-e2e`.
  Edit the copy: `app.routes` gets back an `::handler` component
  (`ig/init-key` taking `{:keys [db]}` and returning `(handler db)`);
  `app.server/http` takes `{:keys [port handler]}` and uses
  `(http/start handler addr)` in `init-key`, `(http/stop server)` in
  `halt-key!`, storing the record; `app.system/config` wires
  `db -> handler -> http` with `ig/ref`; the `::http` component's value
  is the `http/Server` record itself; `main.lg` calls
  `(http/wait (:app.server/http system))` (synchronous, returns `nil`
  when stopped; no `deref`) instead of dereferencing a future; the 204
  response gets `:headers {}` back. The test file inits `db` + `handler`
  and pulls the handler out of the system.

- [x] **Step 3: Run it under the branch**
  Run: `LGX_LETGO_REPLACE=$HOME/Projects/let-go ~/Projects/lgx/bin/lgx test`
  Expected: 2 tests, 11 assertions, 0 failures (this is the
  three-component `ig/init` that hung before).
  Run: `LGX_LETGO_REPLACE=$HOME/Projects/let-go PORT=8093 DB_PATH=/tmp/e2e.db ~/Projects/lgx/bin/lgx run`
  in the background, then `/tmp/drive.sh 8093` (the curl script from the
  earlier session; recreate it if gone: POST twice, GET list, POST
  complete, GET one, DELETE, GET deleted, POST `{}`, GET `/nope`).
  Expected: 201, 201, 200, 200, 200, **204**, 404, 400, 404; no
  `panic serving` in the log. Stop with `kill`, not `pkill -f main.lg`.
  Run a halt check: an `-e` script that `ig/init`s the config, `ig/halt!`s
  it, and then `http/get`s the port expecting a connection error.

- [x] **Step 4: Open the PR**
  `git push -u origin fix/http-server-and-rest-destructure`, then
  `gh pr create --repo nooga/let-go` with title
  `http: stoppable server, empty :headers fix; core: & rest binds nil`
  and a body listing the three changes, the regenerated artifacts, the
  gates run, and links to the two lgx issue notes. No attribution lines.
  Record the PR URL in this plan.
  > Deviation: the `gh` token cannot create PRs on `nooga/let-go`
  > (`Resource not accessible by personal access token`). The branch is
  > pushed to the fork; a prefilled compare link (title + body) is in
  > `~/Projects/let-go/.tmp/pr-link.txt` for the user to open. The PR
  > body's links to the lgx issue notes were dropped: that lgx branch is
  > not pushed yet, and the repros are inline.

- [x] **Step 5: Clean up and note the follow-up**
  `rm -rf /tmp/web-app-e2e`. Append to this plan under "Follow-up":
  once the PR merges, in lgx move `examples/web-app`'s `:lg-version` to
  the merged sha, restore the three-component chain and `:headers {}`
  (the edits from Step 2), switch the server component to
  `start`/`stop`, and mark `docs/issues/destructure-rest-empty-seq.md`
  and `docs/issues/http-empty-headers-panic.md` resolved.

## Follow-up (lgx, after the PR merges)

- Move `examples/web-app`'s `:lg-version` to the merged `nooga/let-go` sha.
- Restore the three-component chain (`::handler` component, `db -> handler -> http`),
  put `:headers {}` back on the 204, switch `app.server` to `http/start`/`http/stop`
  with `halt-key!` stopping it, and `main.lg` to `(http/wait ...)`. The exact
  edits were exercised on the temp copy in Task 5 Step 2.
- Mark `docs/issues/destructure-rest-empty-seq.md` and
  `docs/issues/http-empty-headers-panic.md` resolved (PR number).

## Completion summary

**Status: completed** (PR creation pending the user: see Task 5 deviation).

Branch `fix/http-server-and-rest-destructure` on `abogoyavlensky/let-go`,
seven commits on upstream `main` `3bbde90`:

| Commit | Change |
|---|---|
| `7be4c40` | `fix(core)`: rest binding is `(seq (drop i n))`; regenerated `core_compiled.lgb`, `generated.sums`, `generated.manifest`; tests |
| `343c7c3` | `fix(http)`: nil-entry guard in `ServeHTTP`'s header loop; test |
| `7973696` | `fix(core)`: emit `clojure.core/seq` (codex: a local named `seq` captured it); test |
| `df202f3` | `feat(http)`: `lgServer`, `http/start`/`stop`/`wait`, `serve` = start + wait, `http/Server` record, scope cancellation; 8 Go tests + `test/http_server_test.lg` |
| `24d846a` | `docs(guide)`: `docs/guide/http.md`, indexed in `docs/README.md` |
| `e86d8c1` | `fix(http)`: `stop` waits for the Serve goroutine to exit (port release when stop lands before Serve runs); a failed Serve closes accepted connections (codex round 1); 2 tests |
| `dfda850` | `chore`: refreshed `generated.manifest`/`generated.sums` - the generator input digest covers `pkg/rt/*.go`, so the `http.go` changes moved it and CI's `TestGeneratedArtifactsAreFresh` would have failed |

Gates: `make generate`, `make check-generated`, `make test` (unit + e2e)
green; `go test ./pkg/rt/ -race -count=3` green. End to end (Task 5): the
three-component integrant chain inits under the branch, all nine routes
answer (204 with `:headers {}`, no panic), `ig/halt!` closes the port and
the process exits; `PORT=0` resolves to a real port.

Codex reviews: Task 1 caught the `seq` capture (fixed); Task 2 clean;
Task 3 caught the two lifecycle races (fixed, round 2 clean); Task 4 clean.

Deviations, gathered: `generated.manifest` is a third committed artifact;
`clojure.core/seq` in the expansion; `unboxServer` checks the boxed handle
before the `Lookup` probe (`*vm.Boxed` is a reflective `Lookup` that
panics); two extra Go tests beyond the plan's list; the guide indexed in
`docs/README.md`; `make generate` (~15 min) and `make check-generated`
(regenerates the lowered tree) must run as background jobs because a tool
call is capped at 10 min; PR opened via compare link, not `gh`.

**What the plan could have specified better:** that the generated
manifests hash `pkg/rt/*.go` as generator inputs, so *any* Go change under
`pkg/rt` needs `make generate` before the branch is CI-clean, not only
`.lg` edits; that `make generate` and `make check-generated` each take
10-15 minutes here and cannot share a tool call with anything else; that Go's `Shutdown` before `Serve` has run
leaves the listener bound until the Serve goroutine exits (the plan's
`done` contract covered drain but not this); and that `gh` may lack PR
rights on the upstream repo, so the fallback is a compare link.
