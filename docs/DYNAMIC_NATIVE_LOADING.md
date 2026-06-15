# Loading native libraries into stock `lg` at runtime (no rebuild)

Status: research + decision notes · Last updated: 2026-06-15

The question: can we load Go-lib wrappers **dynamically** so that native
functionality (e.g. SQLite) runs on the **stock `lg` binary** — *without*
rebuilding let-go per lib-set on the user's machine (the lgx-orchestrated
custom-runtime model)?

Short answer: **yes, but not by loading Go.** You load **C** (via
`purego`) or **WASM** (via `wazero`). Each is a *one-time, generic*
addition to `lg` upstream; after that, libraries ship as data / `.lg` /
`.wasm`, distribute through lgx, and run on stock `lg` with no per-lib
rebuild and no user toolchain.

Companion docs:
[`GO_LIBS_INTEROP_OPTIONS.md`](./GO_LIBS_INTEROP_OPTIONS.md) (the full
option matrix) and [`LG_BUILT_IN_SQLITE.md`](./LG_BUILT_IN_SQLITE.md)
(the compile-in approach we built and measured).

---

## 1. The misconception: "dynamic Go" mostly isn't

Projects that *look* like they dynamically link Go code almost never do.
They fall into three buckets, none of which loads new compiled code:

| Project(s) | What it actually does | Dynamic linking? |
|---|---|---|
| **air** (air-verse/air), CompileDaemon, gin, fresh, realize | watch files → **`go build` → kill & restart** the process | **No.** Fast rebuild + restart. This is exactly the "rebuild every time" we're trying to avoid, just automated. |
| gore, gomacro (compile mode) | accumulate REPL input → recompile / `go run` | No — recompile-based |
| **yaegi** (Traefik), gomacro (interp mode) | a Go **interpreter**: interprets Go *source*, or bridges to symbols **already linked** into the host (via `yaegi extract` bindings) | No — cannot pull in *new compiled* packages |

So `air` is the anti-pattern here, not the solution.

**Why interpreters (yaegi) don't rescue us for heavy libs:** to use
`modernc.org/sqlite` through yaegi you would either compile modernc into
the host anyway (defeating the point) or interpret modernc's *source* —
a huge transpiled-C-in-Go blob that uses `unsafe`. Non-starter on both
performance and language-feature grounds. Interpreters only cleanly call
into packages that are *already linked* into the host.

---

## 2. The hard truth: you cannot dynamically load *Go*

Go has no stable ABI, and the team has repeatedly declined to add one.
The only mechanism is the **`plugin`** package (`.so` via `-buildmode=
plugin`), and it is unusable for a distributed ecosystem:

- plugin and host must be built with the **exact** same Go toolchain
  version **and** byte-identical versions of every shared dependency —
  **every `lg` release invalidates every plugin**;
- requires **cgo** (breaks `CGO_ENABLED=0`);
- Linux/macOS only (no Windows / WASM / Plan9), cannot be unloaded.

This is precisely why let-go uses **pods** instead. Conclusion: **stop
trying to load Go libraries dynamically — that door is bricked.**

---

## 3. The reframe: load C, or load WASM — not Go

There are exactly two viable runtime-load mechanisms. Each is added
**once** upstream as a generic host; afterwards stock `lg` loads
libraries at runtime.

| | **purego** | **wazero** |
|---|---|---|
| Loads | C shared libs (`.so`/`.dylib`/`.dll`) | `.wasm` modules |
| cgo? | **no** (asm trampolines) — *Linux caveat below* | **no**, every platform |
| Sandboxed? | no (raw C — a bad signature segfaults) | yes |
| Portability | per-platform `.so` + lib must be present | one `.wasm` everywhere |
| Speed | native C | wasm (slower than native) |
| Platforms | linux/mac/win/bsd, amd64/arm64 | broad |
| SQLite via | system/bundled `libsqlite3` | `sqlite.wasm` (+ VFS host fns) |

---

## 4. purego — dynamic C libraries, cgo-free

[`purego`](https://github.com/ebitengine/purego) (from the Ebitengine
project) `dlopen`s a C library and calls into it from a Go binary,
performing symbol lookup and calling-convention marshaling in pure Go
(per-platform assembly trampolines). It is the mechanism that matches the
"dynamic native code, stock binary, no rebuild" goal — for **C**
libraries. SQLite *is* C, so it fits.

Primitives:

- `purego.Dlopen(path, flag)` → library handle
- `purego.RegisterLibFunc(&goFnVar, lib, "symbol")` — bind a Go func var
  to a C symbol (compile-time-typed)
- `purego.SyscallN(fnptr, args…)` — low-level call by pointer; the
  primitive for a **data-driven** FFI where signatures come from runtime
  data
- `purego.NewCallback(goFn)` — pass Go funcs as C callbacks
  (count-limited on some platforms)

### 4.1 The generic upstream mechanism for let-go

Add `purego` to `lg` once and expose a generic, **data-driven `ffi`
namespace**. Libraries are then described in `.lg` (distributable via lgx
like any source dep) — **no Go compiled per lib, runs on stock `lg`**:

```clojure
(def lib (ffi/dlopen "libsqlite3"))                       ; dlopen at runtime
(ffi/defcfn lib "sqlite3_open"  [:string :ptr]    :int)   ; declare C signatures
(ffi/defcfn lib "sqlite3_exec"  [:ptr :string ...] :int)  ; as data
;; ... ~15-20 sqlite3_* functions → a reusable `.lg` binding package
```

Under the hood a generic dispatcher uses `purego.SyscallN` plus
marshaling driven by the declared signatures. This is the **"pull in a
lib via lgx, run on stock `lg`, no rebuild"** architecture. SQLite,
libcurl, libgit2, etc. all become `.lg` binding packages over a system
`.so`.

> Note: "upstream" here means a **single, generic** host added to `lg`
> once — *not* per-lib and *not* on the user's machine. After that,
> native libs are pure data/source, and the stock binary is enough.

### 4.2 Honest trade-offs

- **C ABI only** — not Go packages. (Fine for SQLite: you'd use the
  system `libsqlite3`, not modernc.)
- **The cgo caveat:** purego is fully cgo-free on **macOS/Windows**; on
  **Linux** the `dlopen` path has historically required cgo (verify
  against current purego). If so, the *prebuilt* `lg` needs cgo to build
  on Linux — but **users still need no toolchain** (they download the
  prebuilt and load `.so` at runtime). It only dents let-go's "builds
  with `CGO_ENABLED=0`" purity on Linux. (wazero has no such caveat.)
- **Unsafe** — a wrong signature segfaults the process (not a catchable
  panic).
- **Manual marshaling** — strings, pointers, structs, and **callbacks**
  (SQLite custom functions / `exec` callback → `purego.NewCallback`,
  count-limited on some platforms). Fiddly but bounded for a C API, and
  written once as `.lg`.
- **The lib must be present** — `libsqlite3` ships on macOS, is a package
  on Linux, a DLL on Windows; or bundle per-platform `.so` (small
  artifacts, still no `lg` rebuild).
- **Platform-gated** (no wasm/Plan9) — same boundary as pods.

---

## 5. wazero — dynamic WASM modules

Covered in detail in
[`GO_LIBS_INTEROP_OPTIONS.md` §4.3](./GO_LIBS_INTEROP_OPTIONS.md). In
brief: embed the pure-Go `wazero` runtime in `lg` once; distribute libs
as `.wasm`; load at runtime. The boundary is WASM's primitive ABI
(numbers + one linear memory → pointer/length marshaling), and SQLite
needs host callbacks for file I/O (its pluggable VFS). Pure Go on every
platform, sandboxed, but slower than native; the ABI/marshaling layer is
the work. `ncruces/go-sqlite3` proves the SQLite-via-wazero pattern.

---

## 6. Comparison: every "no-rebuild, stock-`lg`" door

| | rebuild `lg` per lib? | in-process? | cgo? | ships per lib | safety |
|---|---|---|---|---|---|
| Babashka pod | no | **no** (stdio IPC) | no | pod binary | safe (separate process) |
| **purego FFI** | **no** | **yes** | no\* | `.lg` binding (+ system `.so`) | unsafe (segfaults) |
| **wazero WASM** | **no** | **yes** | no | one `.wasm` | sandboxed |
| Go `plugin` | no, but per-`lg`-version | yes | yes | version-locked `.so` | fragile |
| compile-in (built) | **yes** | yes | no | nothing (baked in) | safe |

\* cgo-free on macOS/Windows; Linux `dlopen` may need cgo to *build* the
runtime (see §4.2).

---

## 7. Bottom line

The instinct that a stock-binary, no-rebuild, dynamic path exists is
**correct** — but:

- it is **not** `air` (recompile + restart), and
- it is **not** Go `plugin` (bricked for distribution).

It is **purego** (dynamic C libraries, cgo-free) or **wazero** (dynamic
WASM). Either is a **one-time generic upstream host** in `lg` — an `ffi`
or `wasm` namespace — after which native libs ship as data / `.lg` /
`.wasm`, distribute through lgx, and run on the **stock `lg`** with no
per-user rebuild and no lgx-orchestrated runtime compilation.

For SQLite specifically:

- **purego → `libsqlite3`** — fastest, in-process, but per-platform +
  unsafe + the Linux-cgo caveat.
- **wazero → `sqlite.wasm`** — one portable artifact, sandboxed, pure-Go
  everywhere, but slower.
- **compile-in (done)** — simplest and safe, but rebuilds the runtime
  (+3.75 MiB; see [`LG_BUILT_IN_SQLITE.md`](./LG_BUILT_IN_SQLITE.md)).

**Suggested next step:** spike the purego path — a throwaway,
`CGO_ENABLED=0` Go program that `dlopen`s the system `libsqlite3` and
runs `sqlite3_open`/`exec`/`step` — to prove the generic-FFI-on-stock-
`lg` mechanism and surface the real marshaling / callback / Linux-cgo
gotchas before anything goes upstream.

---

## Verify against

- purego: <https://github.com/ebitengine/purego> (Dlopen, RegisterLibFunc,
  SyscallN, NewCallback; platform/cgo notes).
- wazero: <https://github.com/tetratelabs/wazero>;
  `ncruces/go-sqlite3` for the SQLite-via-wazero VFS pattern.
- Go plugin limitations: `go doc plugin` (toolchain/dependency lockstep,
  cgo, platform support).
- let-go interop & build facts: see the "Verify against" footer in
  [`GO_LIBS_INTEROP_OPTIONS.md`](./GO_LIBS_INTEROP_OPTIONS.md).
- "no FFI today" confirmed: no `purego`/`wazero`/`plugin.Open`/`dlopen`
  in let-go `go.mod` or `pkg/` (only `syscall.*` for internal use).
