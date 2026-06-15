# Using native Go libraries from let-go / lgx

Status: research + decision notes · Last updated: 2026-06-15

This document captures everything we found about getting **native Go
library functionality** (the motivating case is SQLite) into a let-go
program, and what each path means for **lgx** as the project/runtime
manager. A companion doc, [`LG_BUILT_IN_SQLITE.md`](./LG_BUILT_IN_SQLITE.md),
describes the concrete in-process SQLite implementation we built and
measured.

---

## TL;DR

- **SQLite is embedded, not a server.** There is no wire protocol to
  speak to, so a "pure-let-go driver like pg2" is impossible for local
  use. You must reach native code; the only question is *where the
  native boundary sits*.
- **Go links statically.** There is no runtime loading of arbitrary Go
  packages (no classpath equivalent). To call native code **in-process**
  there are exactly **two doors**: (1) compile it into the runtime
  binary, or (2) load it at runtime via **WASM** (Go plugins are the
  fragile third that everyone avoids).
- let-go **already has excellent Go interop** — but it serves the person
  *compiling the binary* (an embedder), not a pure-`.lg` app developer.
  The clunk you feel is the *distribution/linking* story, not interop
  quality.
- The realistic options: **Babashka pod** (out-of-process, shipped
  today), **in-process native namespace** (compile-in; what we
  prototyped), **WASM host** (runtime-loadable; in-process "pods"), and
  **network client** to a server that fronts SQLite. Plus a clear
  *impossibility*: you cannot have {arbitrary Go lib + in-process + zero
  build anywhere + zero upstream changes} all at once.
- For lgx, the lever is **where the compile happens**: the user's machine
  (needs Go), CI/release (prebuilt per platform), a build server
  (Caddy-style), or *nowhere* (WASM).

---

## 1. The two hard constraints

### 1.1 SQLite is embedded

| | Postgres | SQLite |
|---|---|---|
| Architecture | server process | in-process C library |
| Wire protocol | yes (documented TCP) | **none** |
| Pure-client possible? | yes (e.g. `pg2`, `next.jdbc`→JDBC) | **no** — nothing to talk to |

`pg2` (pure-Clojure Postgres) works because Postgres is a *server*: a
pure-Clojure client just speaks bytes over a socket. SQLite has no
server and no wire protocol — the engine *is* the linked library. So:

- Reimplementing the SQLite engine in let-go bytecode → absurd
  (~150 kloc of C, decades of edge cases, slow on a stack VM).
- The only way to get **embedded** SQLite is to reach C/Go-native code.

### 1.2 Go links statically

let-go programs run on the `lg` interpreter — a single pre-compiled Go
binary. A let-go *library* distributed via lgx is `.lg`/`.cljc`/`.lgb`
(**pure let-go**). `.lgb` is compiled let-go **bytecode**; it can only
*reference* native namespaces, never *contain* them.

Go has no usable runtime-plugin story (`plugin` is OS-limited and
demands byte-identical toolchain + dependency versions — which is
exactly why let-go uses **pods** instead). Therefore:

> **To call native Go code in-process, that code must be compiled into
> the runtime binary. There is no "drop-in bytecode dependency" for Go
> code.** The only alternative to compiling-in is runtime-loading a
> **WASM** module.

This is the root cause of every trade-off below.

---

## 2. What let-go already provides (verified in source)

The interop mechanism is mature and tested. It comes in three layers:

| Layer | What it does | Where |
|---|---|---|
| **Manual native ns** | `vm.NewNamespace` → `ns.Def(name, NativeFnType.Wrap(fn))` → `RegisterNS`, wired via `RegisterInstaller(installFooNS)` in an `init()`. How all stdlib native namespaces are built. | `pkg/rt/http.go`, `json.go`, `os.go`, `pods.go`, `installers.go` |
| **Reflection `Def`** | `c.Def("name", anyGoFunc)` auto-wraps *any* Go function via reflection. Converts scalars, slices (auto-realizes lazy seqs → `[]T`), channels (both directions), structs (`RegisterStruct[T]` → Record with keyword access + round-trip). `error` as last return → let-go exception. | `pkg/api/api.go`, `pkg/api/interop_test.go` |
| **`vm.Boxed`** | Holds *any opaque Go value* (e.g. `*sql.DB`) as a let-go value. Reflection-discovers the type's methods and exposes them via `(.Method obj …)` (dispatch wired at `pkg/rt/lang.go:3270` through the `Receiver`/`InvokeMethod` interface). Struct fields readable by name. Passes back into other Go fns unchanged. | `pkg/vm/boxed.go` |

Supporting tooling:

- **`cmd/lginterop`** — an automatic binding generator. Reads a
  `:gointerop` list of Go packages from `deps.edn`, introspects them
  with `go/types`, and emits let-go bindings (`-smart` = typed wrappers,
  `-skeleton` = hand-editable stubs).
- **`gogen`** (`pkg/rt/gogen.go`, `examples/go-gen/`) — Clojure-spec →
  Go-source code generator. This is *codegen*, **not** runtime interop;
  don't confuse it with the above.
- **Embedding API** (`pkg/api`) — `api.NewLetGo`, `c.Def`, `c.Run`,
  `vm.Iter`, `vm.SeqToSlice`. See `examples/go_interop_lazy/`.

**The key nuance:** all of this helps *whoever compiles the binary*. A
pure-`.lg` app developer running stock `lg` cannot reach it — there is
no `(import "modernc.org/sqlite")` at runtime. Good interop ≠ easy
library distribution.

---

## 3. Build & bundle facts that shape distribution (verified)

- Stock `lg` builds with **`CGO_ENABLED=0`**, `go build .` at the repo
  root (`package main`, `func main()` at `lg.go:715`; **no exported
  `Main`/`Run`**).
- Generated artifacts (`pkg/rt/core_compiled.lgb`, `*_generated.go`) are
  **committed** and embedded via `go:embed`, so a clean `go build .`
  works **without** `go generate`/`make`. (goreleaser's `go generate`
  hook is a freshness check, not a build prerequisite.)
- **`lg -b script.lg out`** produces a standalone binary by **appending
  the program's `.lgb` bytecode as a trailer** to a *copy of the `lg`
  binary* (`bundleMagic` `LGBX`/`LGB2` in `lg.go`). **It does not run
  `go build`.** Cross-OS bundling swaps the base via
  `-bundle-base <target-os-lg>`.
- Consequence: **lgx's current pipeline never compiles Go** — it is
  git-fetch + interpret, or bytecode-append. A `.lgb` referencing
  `sqlite/query` requires the **base `lg` binary to already contain the
  `sqlite` native ns.**

---

## 4. The options

### Overview

| # | Option | Boundary | Native code in runtime? | Embedded? | Toolchain for app dev? | Composable w/o build? | Status |
|---|---|---|---|---|---|---|---|
| 1 | **Babashka pod** | separate process (stdio + bencode) | no | yes (per-call) | no | **yes** | **shipped** |
| 2 | **In-process native ns** | in-process Go call | yes (compiled in) | yes (fully) | yes, unless prebuilt | no | prototyped ([`LG_BUILT_IN_SQLITE.md`](./LG_BUILT_IN_SQLITE.md)) |
| 3 | **WASM host (wazero)** | in-process WASM call | host once; libs are `.wasm` | yes | **no** | **yes** | not built (upstream project) |
| 4 | **Network client** | network (HTTP/WS) | no | no (needs server) | no | yes | feasible in pure `.lg` |
| — | ~~Go plugins~~ | in-process `.so` | yes | yes | — | — | **rejected** |

### 4.1 Babashka pod (out-of-process) — *shipped today*

let-go already loads Babashka pods (`pkg/rt/pods.go`): bencode over
stdio, `describe`/`invoke`, client-side code eval, json/edn/transit
formats, sync + async. It shares `~/.babashka/pods/` with `bb`. The
README documents SQLite via this path:

```clojure
(pods/load-pod 'org.babashka/go-sqlite3 "0.3.13")
(pod.babashka.go-sqlite3/execute! "app.db" ["create table users (id integer primary key, name text)"])
(pod.babashka.go-sqlite3/query   "app.db" ["select * from users"])
```

- **Pros:** zero work, keeps `lg` cgo-free and tiny, composable (each
  pod is its own process), no Go toolchain, battle-tested.
- **Cons:** out-of-process IPC + serialization per call; the
  go-sqlite3 pod's surface is intentionally minimal (`execute!`/`query`
  over a db **path**), so persistent connections, `:memory:` databases
  that survive across calls, custom SQL functions, and multi-call
  transactions are awkward or unavailable (each call crosses a process
  boundary). Requires the pod binary installed.

### 4.2 In-process native namespace (compile-in) — *what we prototyped*

Add a Go file that registers a native namespace (the `http.go` pattern)
backed by a Go SQLite library, gated behind a build tag. let-go values
↔ Go values directly, no serialization.

**Which Go SQLite lib:**

| Lib | cgo? | Notes |
|---|---|---|
| `modernc.org/sqlite` | **no (pure Go)** | SQLite transpiled to Go. Mature, big (~+3.75 MiB linked — see companion doc). **Preserves let-go's static-binary / cross-compile / `CGO_ENABLED=0` identity.** |
| `ncruces/go-sqlite3` | no (pure Go) | Runs SQLite-as-WASM via wazero. Also cgo-free; relevant to Option 3. |
| `mattn/go-sqlite3` | **yes (cgo)** | Fastest, smallest added Go, but needs a C toolchain and forfeits static-binary + easy cross-compile + WASM. **Against let-go's grain.** |
| `zombiezen.com/go/sqlite` | wraps modernc | Lower-level API than `database/sql`; maps to a shim more cleanly. |

- **Pros:** real embedded SQLite — no IPC; `:memory:`, prepared-stmt
  reuse, connection/transaction objects as let-go values, custom SQL
  functions in let-go, streamed results. Best ergonomics and speed.
- **Cons:** the native code must be **compiled into the runtime
  binary**. lgx alone can't do this (it shells to `lg`; pods exist
  *instead of* Go plugins). Adds binary size; gate behind a build tag so
  default/WASM builds stay lean. Not composable without a (re)build.

**Distribution sub-models** (see §5):

- **A. Upstream + build tag** — add the ns to let-go behind `-tags
  sqlite`; ship a "fat" prebuilt. Best UX, needs maintainer buy-in.
- **B. Fork / custom `lg`** — you maintain an `lg` with the ns compiled
  in.
- **C. Embed via `pkg/api`** — a small Go `main` that imports let-go +
  the lib (no fork). Cleanest as a *library*, but a `pkg/api` embedding
  main lacks `lg`'s REPL/`-b` bundler unless you rebuild the full `lg`
  (see the xcaddy pattern in §6).

### 4.3 WASM host (wazero) — *in-process "pods", runtime-loadable*

Embed a **pure-Go WASM runtime (wazero)** into `lg` once; distribute
native libs as portable `.wasm` files; load them at runtime.

**How it works in a nutshell:**

1. `lg` embeds wazero (pure Go → keeps static-binary identity).
2. lgx fetches a `.wasm` artifact (like a pod binary, but loaded
   in-process — no separate process, no stdio IPC).
3. let-go calls into the module's exported functions.

**The hard part — the ABI.** WASM only speaks **numbers** (i32/i64/
f32/f64) plus one **linear memory** (a flat `[]byte`). Every call is:
allocate space in the module's memory → copy bytes in → pass
pointer+length as ints → let it write results back → read them out →
free. That marshaling layer (let-go Value ⇆ WASM memory) is the work.
Two ways: hand-written per-lib glue, or the **WASM Component Model +
WIT** (typed interface → auto-generated bindings; cleaner future, more
moving parts).

**SQLite wrinkle.** The WASM sandbox can't touch disk, so the host must
supply **callback functions the module imports** (read/write/lock) —
SQLite's pluggable VFS is built for exactly this. Data flows both ways:
let-go → wasm (queries), wasm → host (file I/O).

- **Pros:** no Go toolchain for anyone; **composable** (load many libs
  into one process, no combined build); in-process (no IPC); portable +
  sandboxed single artifact; pure-Go host.
- **Cons:** the ABI/marshaling glue is real work; **slower than native**
  (so modernc would beat SQLite-in-wasm for CPU-heavy queries); wazero
  adds size; it's an upstream **project**, not a patch.
- **Proof it works:** `ncruces/go-sqlite3` already drives the SQLite
  WASM blob through wazero with a VFS wired via host functions — exactly
  this pattern, Go-side.

### 4.4 Network client (pure `.lg`) — *the only place pg2's lesson applies*

Write a pure-let-go client (like `pg2`) against a server that *fronts*
SQLite over a network: libSQL/Turso `sqld` (Hrana, JSON over HTTP/WS) or
rqlite (HTTP + JSON). Reuses let-go's `http`/`json`/`transit` natives —
**zero changes to `lg`**.

- **Pros:** truly pure-let-go; works on WASM; scales to remote/replicated
  DBs (Turso, rqlite clustering).
- **Cons:** **not embedded** — needs a running server; latency; defeats
  SQLite's "tiny, no-infra" appeal for local use. Best as a *complement*
  for remote/hosted DBs, not a local driver.

### 4.5 Go plugins — *rejected*

`plugin.Open(".so")` would be runtime-loadable native code, but: Linux/
macOS only (no Windows/WASM/Plan9), requires the plugin and host built
with the **exact** same Go version and **exact** same versions of all
shared dependencies, can't unload, and breaks constantly. let-go's pods
doc explicitly exists "without relying on Go plugins." Dead end for a
distributable ecosystem.

---

## 5. Distribution: where does the compile happen? (the real lever)

For in-process native code (Option 2), *something* must compile Go. The
only question is **where**, and that determines who needs a toolchain:

| Where | App dev needs Go? | Trade-off | Analogy |
|---|---|---|---|
| **User's machine** (at `lgx install`) | **yes** | full flexibility; one-time, cacheable cost | — |
| **CI / lib release** (prebuilt per OS/arch) | no | curated set baked in; author maintains a matrix | **babashka** feature builds |
| **Build server on demand** | no | no curation; needs infra + trust | **Caddy** `caddyserver.com/download` |
| **Nowhere (WASM, Option 3)** | no | needs the wasm host + ABI built once upstream | — |

**The free-lunch killer:** you cannot have all of {arbitrary Go lib +
in-process + zero build anywhere + zero upstream work}. Something always
gives. "Convenient" = pick *where* the compile happens, or go WASM.

**Toolchain footprint of the "user's machine" path** (verified while
prototyping, see companion doc):

- Only the **`go` binary** is needed — declarable in mise
  (`[tools] go = "1.26"`). Must be ≥ `go 1.26` (let-go's go.mod).
- **No C compiler** (`CGO_ENABLED=0` + modernc is pure Go).
- **No `go generate`/`make`** (generated artifacts are committed).
- **git** is already required by lgx.
- **Network** only on first build (then cached in the Go module cache).

---

## 6. What this means for lgx

If lgx builds a **full custom `lg`** (not a `pkg/api` embedding main) and
uses it as the runtime everywhere, then **`lgx run`, REPL, and `lgx
build` all work**:

| Command | Mechanism |
|---|---|
| `lgx run` | exec the cached custom `lg`; the `.lg` API layer resolves as a normal git dep, the native ns is compiled in |
| `lgx nrepl` | same binary — it's a *full* `lg`, so the complete nREPL is present plus the native ns |
| `lgx build` | bundle = custom runtime + app `.lgb` trailer (`lg -b -bundle-base <custom-lg>`); fully self-contained, runs with no `go`/`lg`/network |

**The xcaddy pattern** (how custom Caddy-with-plugins is built) makes the
custom build clean and needs **no upstream changes**:

1. Fetch let-go source at the pinned version.
2. Drop one file into the root `package main`:
   ```go
   package main
   import _ "your-org/lg-sqlite" // its init() calls rt.RegisterNS("sqlite")
   ```
3. `CGO_ENABLED=0 go build -tags sqlite -o lg-sqlite .`

Because the build happens **inside** the let-go module, the lib's own
`import ".../let-go/pkg/rt"` auto-resolves to that exact local source —
**no version skew, no `replace` needed.**

**`lgx install`** is the right place to run this once and cache the
binary (keyed by let-go version + native dep set + tags); `run`/`nrepl`/
`build` then use the cached binary **offline**.

**Optional small upstream change that helps:** if let-go exposed its CLI
as `pkg/cli.Main()`, a custom runtime would be a clean 4-line module
that imports let-go as a library (no source cloning):

```go
package main
import (_ "your-org/lg-sqlite"; "github.com/nooga/let-go/pkg/cli")
func main() { cli.Main() }
```

---

## 7. SQLite specifically

### 7.1 Reference projects, mapped

| Project | Relevance |
|---|---|
| [xerial/sqlite-jdbc](https://github.com/xerial/sqlite-jdbc) | reference for *semantics* (type affinity, param/result coercion, pragmas) — not something to wrap (JVM/JDBC). |
| [next.jdbc](https://github.com/seancorfield/next-jdbc) | the **API shape** to imitate (`get-datasource`/`get-connection`, `execute!`, `execute-one!`, reducible `plan`, map rows). **Cannot be ported** — it's a thin shim over `java.sql.*` (100% JVM interop). |
| [clojure.jdbc](https://github.com/funcool/clojure.jdbc) / java.jdbc | older API ideas, superseded by next.jdbc. |
| [jolt-lang/db](https://github.com/jolt-lang/db) | closest spiritual sibling — a Clojure-dialect-not-on-real-Clojure doing DB access. Read for minimal API structure. |
| [pg2](https://github.com/igrishaev/pg2) | template **only** for Option 4 (a Clojure-side protocol client) — and only because Postgres is a server. |
| [honeysql](https://github.com/seancorfield/honeysql) | the **bonus** — see §7.4. |

### 7.2 What each option means for SQLite

- **Pod (4.1):** works today; minimal surface; out-of-process.
- **In-process (4.2):** the real embedded driver. **We built and
  measured this** — see [`LG_BUILT_IN_SQLITE.md`](./LG_BUILT_IN_SQLITE.md).
  +3.75 MiB / +31% to opt in, zero cost when off.
- **WASM (4.3):** SQLite is the *ideal* first wasm target (official
  SQLite-WASM exists; ncruces already does it via wazero). The endgame
  for "require any native lib," but the most upstream work.
- **Network (4.4):** for **remote/hosted** SQLite (Turso/libSQL,
  rqlite) — complementary, not a local driver.

### 7.3 Recommendation for SQLite

1. **Now / proven:** the in-process build-tagged ns
   ([`LG_BUILT_IN_SQLITE.md`](./LG_BUILT_IN_SQLITE.md)) gives real
   embedded SQLite at +3.75 MiB.
2. **For no-toolchain users:** ship a prebuilt "sqlite" `lg` variant
   (Model 5-CI) or have lgx build+cache it at `lgx install` (Model
   user-machine). `lgx install` keeps the cost one-time and offline
   thereafter.
3. **API ergonomics:** layer a next.jdbc-shaped `.lg` API on top so
   callers never see whether the backend is the pod or the in-process ns
   — the transport stays swappable.
4. **Long term, if "arbitrary native libs" becomes core:** invest in the
   wazero WASM host.

### 7.4 HoneySQL bonus

HoneySQL is **pure data → SQL** with zero JDBC/JVM-DB dependency:
`(sql/format {:select :* :from :users :where [:= :id 1]})` →
`["SELECT * FROM users WHERE id = ?" 1]`. That string + params vector
feeds **any** transport above. So HoneySQL is a **compat-porting
problem, not a driver problem** — the same class of work as the medley
port (records/protocols, multimethods, reader conditionals with `:clj`
matching opt-in, some `clojure.string`). It is orthogonal to whichever
driver you pick.

---

## 8. Decision guide

- **Just need SQLite from a script, today, no fuss** → Babashka pod.
- **Want real embedded SQLite, willing to ship/own a runtime** →
  in-process native ns (proven; +3.75 MiB).
- **Want users to need no Go toolchain** → prebuilt fat runtime (CI) or
  a build server; or move the build into `lgx install` on machines that
  do have Go.
- **Want to `require` any native lib like a normal dep** → WASM host
  (biggest investment; the only door that removes the build entirely).
- **Remote / replicated DB** → pure-`.lg` libSQL/rqlite client.

---

## Verify against

In [nooga/let-go](https://github.com/nooga/let-go) (`sqlite` branch for the
prototype):

- Interop: `pkg/api/api.go`, `pkg/api/interop_test.go`, `pkg/vm/boxed.go`,
  `pkg/rt/lang.go` (`InvokeMethod` dispatch ~`:3270`).
- Native ns pattern: `pkg/rt/installers.go`, `pkg/rt/zz_run_installers.go`,
  `pkg/rt/http.go`, `pkg/rt/json.go`.
- Pods: `pkg/rt/pods.go`, `docs/pods.md`.
- Codegen / binding gen: `pkg/rt/gogen.go`, `examples/go-gen/`,
  `cmd/lginterop/main.go`.
- Build/bundle: `lg.go` (`func main` ~`:715`, `bundleBinary`,
  `checkBundledLGB`), `.goreleaser.yml` (`CGO_ENABLED=0`, `main: .`),
  `Makefile`.
- Prototype: `pkg/rt/sqlite.go`.
