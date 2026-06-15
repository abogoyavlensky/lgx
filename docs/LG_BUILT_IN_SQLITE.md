# Built-in in-process SQLite for let-go

Status: working prototype · Last updated: 2026-06-15
Lives in: [nooga/let-go](https://github.com/nooga/let-go) branch `sqlite`,
commit `2f3e014` — `pkg/rt/sqlite.go`

This documents the **in-process SQLite** approach (Option 2 in
[`GO_LIBS_INTEROP_OPTIONS.md`](./GO_LIBS_INTEROP_OPTIONS.md)) that we
implemented and measured: a native `sqlite` namespace compiled into `lg`,
backed by the **pure-Go `modernc.org/sqlite`** driver, gated behind a
build tag so the default binary is unchanged.

---

## TL;DR

- A native `sqlite` namespace (`open` / `execute!` / `query` / `close`)
  is compiled into `lg` only with **`-tags sqlite`**.
- Backed by **`modernc.org/sqlite` v1.52.0** — pure Go, no cgo, so it
  keeps let-go's static-binary / cross-compile / `CGO_ENABLED=0`
  identity.
- **Cost to opt in: +3.75 MiB (+31%). Cost when off: zero** — without the
  tag, the file and the modernc dependency are excluded from the build,
  and the binary is byte-for-byte the same as today.
- Real queries work in-process: parameterized `?` binding, keywordized
  columns, typed values (INTEGER→int, REAL→float, TEXT→string).

---

## 1. Why in-process (vs the pod)

The Babashka go-sqlite3 pod already works from let-go, but it is
out-of-process: every call serializes args over stdio, and its surface
is minimal (`execute!`/`query` over a db **path**). Persistent
connections, `:memory:` databases that survive across calls, custom SQL
functions, and multi-call transactions are awkward or impossible across
a process boundary.

In-process gives real embedded SQLite: a live `*sql.DB` handle held as a
let-go value, no IPC, and a path to `:memory:`, prepared-statement reuse,
transactions, and custom functions. The price is that the driver must be
**compiled into the runtime binary** (Go links statically — see the
companion doc), which is what the build tag + size measurement below are
about.

---

## 2. Design

### 2.1 Build-tag gating

`pkg/rt/sqlite.go` starts with:

```go
//go:build sqlite
```

- **Without** `-tags sqlite`: the file is excluded, nothing imports
  `modernc.org/sqlite`, so it is **not linked**. The default `lg` is
  unchanged. (modernc remains in `go.mod` as an `// indirect` require —
  harmless; an unused require is not linked.)
- **With** `-tags sqlite`: the file compiles, modernc is linked, the
  `sqlite` namespace registers.

This is the same pattern let-go already uses for platform-specific files
(e.g. `pods.go` is `//go:build !js`).

### 2.2 Registration via the installer pattern

The ns registers through let-go's standard mechanism (no edits to any
central list):

```go
func init() { RegisterInstaller(installSqliteNS) }

func installSqliteNS() {
    ns := vm.NewNamespace("sqlite")
    ns.Def("open", open)
    ns.Def("execute!", execute)
    ns.Def("query", query)
    ns.Def("close", closeDB)
    RegisterNS(ns)
}
```

`RegisterInstaller` queues the installer; `zz_run_installers.go`'s
`init()` (sorts last) runs all installers after every other `rt/*.go`
`init()` has registered. Each native fn is built with
`vm.NativeFnType.Wrap(func(vs []vm.Value) (vm.Value, error) { … })` —
identical to `json.go` / `http.go`.

### 2.3 modernc (pure Go) over cgo

`modernc.org/sqlite` registers a `database/sql` driver named `sqlite`
and is **pure Go**. This matters: `lg` builds with `CGO_ENABLED=0`, and
choosing modernc (not `mattn/go-sqlite3`, which is cgo) preserves the
single-static-binary, easy-cross-compile property that defines let-go.
The cost is binary size (§4) and somewhat slower-than-C performance.

### 2.4 The db handle is an opaque `vm.Boxed`

`sqlite/open` returns the live `*sql.DB` wrapped with `vm.NewBoxed(db)`.
The handle is opaque to let-go code (you pass it back into
`execute!`/`query`/`close`); `unboxDB` recovers it via `.Unbox()`. This
is exactly the `vm.Boxed` "opaque Go handle" facility described in the
companion doc.

---

## 3. Namespace surface

```clojure
(sqlite/open path)            ; -> db handle (boxed *sql.DB); Ping()s to validate
(sqlite/execute! db sql & ps) ; -> {:rows-affected n :last-insert-id m}
(sqlite/query db sql & ps)    ; -> [{:col val ...} ...]  (keywordized columns)
(sqlite/close db)             ; -> nil
```

Worked example (exactly what we ran to verify):

```clojure
(let [db (sqlite/open "/tmp/spike.db")]
  (sqlite/execute! db "create table if not exists users (id integer primary key, name text, score real)")
  (sqlite/execute! db "delete from users")
  (sqlite/execute! db "insert into users (name, score) values (?, ?)" "Alice" 9.5)
  (sqlite/execute! db "insert into users (name, score) values (?, ?)" "Bob"   7.0)
  (sqlite/query db "select * from users where score > ?" 8)  ; => [{:score 9.5, :name "Alice", :id 1}]
  (sqlite/query db "select count(*) as n from users")        ; => [{:n 2}]
  (sqlite/close db))
```

### Value mapping

| Direction | let-go ↔ Go |
|---|---|
| **Params** (`& ps`) | each arg via `.Unbox()` → bound through `database/sql` (`vm.Int`→int, `vm.Float`→float64, `vm.String`→string, `vm.NIL`→nil) |
| **Result `nil`** | `vm.NIL` |
| **INTEGER** (`int64`) | `vm.Int` |
| **REAL** (`float64`) | `vm.Float` |
| **bool** | `vm.Boolean` |
| **TEXT** (`string`) | `vm.String` |
| **BLOB** (`[]byte`) | `vm.String` *(stringified for now — see §6)* |
| rows | `vm.NewArrayVector` of `vm.PersistentMap` (keys = `vm.Keyword` column names) |

---

## 4. Results

### 4.1 Binary size

Built `linux/arm64`, `CGO_ENABLED=0 -ldflags="-s -w"` (the flags
goreleaser ships with):

| Build | Size (bytes) | Size (MiB) |
|---|---:|---:|
| baseline (`go build .`) | 12,648,610 | 12.06 |
| **+sqlite** (`go build -tags sqlite .`) | 16,580,770 | 15.81 |
| **delta** | **+3,932,160** | **+3.75 (+31%)** |

Sanity check: the baseline (12,648,610 B) matches the **committed** `lg`
binary (12,648,713 B) to within the commit-hash ldflag difference,
confirming the baseline is the real shipping binary and the +3.75 MiB is
purely modernc + its deps.

### 4.2 Build / first-install time

| Step | Time | Notes |
|---|---:|---|
| `go get modernc.org/sqlite` | 7.3 s | one-time; then in the Go module cache |
| baseline build | 5.8 s | warm cache |
| first `-tags sqlite` build | 10.7 s | includes first compile of modernc (~+5 s marginal) |
| subsequent `-tags sqlite` builds | cached → near-instant | |

So a cold "build the sqlite-enabled runtime" is **~15–20 s once** on this
machine (download + first compile), then effectively free. This is the
number behind doing the build at `lgx install` and caching it.

### 4.3 Behavior verification

```
;; -tags sqlite build:
select * from users where score > 8  =>  [{:score 9.5, :name Alice, :id 1}]   ; only Alice ✓
select count(*) as n                 =>  [{:n 2}]                              ; ✓
;; parameterized binding, keywordized columns, typed values all correct.

;; baseline build:
(require 'sqlite)  =>  error: namespace not found    ; ns absent without the tag ✓
```

### 4.4 Dependencies pulled in (under the tag)

`modernc.org/sqlite v1.52.0` and its tree:
`modernc.org/libc v1.72.3`, `modernc.org/mathutil v1.7.1`,
`modernc.org/memory v1.11.0`, `github.com/dustin/go-humanize v1.0.1`,
`github.com/ncruces/go-strftime v1.0.0`, `github.com/google/uuid v1.6.0`
(upgraded from 1.3.0), `github.com/remyoudompheng/bigfft`,
`github.com/mattn/go-isatty v0.0.20`. All pure Go.

---

## 5. Trade-offs

**Pros**

- Real embedded, in-process SQLite — no IPC, no external pod binary.
- Pure Go: `CGO_ENABLED=0`, cross-compiles, no C toolchain.
- Zero impact on the default build (tag-gated).
- Tiny, idiomatic implementation (~190 lines, follows existing patterns).

**Cons**

- +3.75 MiB / +31% when enabled.
- Requires a **build** of the runtime with the tag — i.e. someone needs
  the Go toolchain (the user's machine, CI, or a build server; see the
  distribution section of the companion doc).
- Excluded from **browser-WASM** builds (modernc has no `GOOS=js`) — same
  boundary as `pods.go`. Irrelevant unless targeting the browser.
- Slower than cgo/C SQLite for CPU-heavy workloads (acceptable for
  typical app/CLI use).

---

## 6. Scope & future work

This is a working **proof of mechanism + size**, intentionally minimal.
Not yet implemented:

- **Transactions** — `begin`/`commit`/`rollback` + a `with-transaction`
  macro (needs a `*sql.Tx` handle, also held as `vm.Boxed`).
- **Prepared-statement reuse** — `prepare` → `*sql.Stmt` handle.
- **BLOBs as bytes** — currently stringified; should map to a byte type.
- **Pragmas / tuning** — WAL, `busy_timeout`, foreign keys; connection
  pool options for SQLite's single-writer model.
- **`:memory:` ergonomics** — works via `open`, but document lifetime.
- **Error mapping** — richer ex-data (SQLite error codes).
- **A next.jdbc-shaped `.lg` API layer** on top (`execute!`/
  `execute-one!`/`plan`, datasource/connection), so callers are
  decoupled from the transport (pod vs in-process).

---

## 7. How to build / try

From a checkout of let-go on the `sqlite` branch:

```sh
# default build — no sqlite, unchanged binary
CGO_ENABLED=0 go build -ldflags="-s -w" -o lg .

# sqlite-enabled build
CGO_ENABLED=0 go build -tags sqlite -ldflags="-s -w" -o lg-sqlite .

# try it
./lg-sqlite -e '(let [db (sqlite/open ":memory:")]
  (sqlite/execute! db "create table t (x int)")
  (sqlite/execute! db "insert into t values (?)" 42)
  (println (sqlite/query db "select * from t"))
  (sqlite/close db))'
```

For the standalone-binary path: build `lg-sqlite` once, then bundle apps
against it with `lg -b -bundle-base lg-sqlite app.lg out`. The bundle is
self-contained (no `go`, no `lg`, no network at runtime). See the lgx
integration section of [`GO_LIBS_INTEROP_OPTIONS.md`](./GO_LIBS_INTEROP_OPTIONS.md).

---

## Verify against

In [nooga/let-go](https://github.com/nooga/let-go), branch `sqlite`
(commit `2f3e014`):

- `pkg/rt/sqlite.go` — the namespace.
- `pkg/rt/installers.go`, `pkg/rt/zz_run_installers.go` — the installer
  mechanism.
- `pkg/rt/json.go` — the value-construction idioms reused here.
- `pkg/vm/boxed.go` — the opaque-handle facility.
- `go.mod` / `go.sum` — modernc requires.
- `.goreleaser.yml` — `CGO_ENABLED=0`, `-ldflags="-s -w"` (the build
  flags used for the size comparison).
