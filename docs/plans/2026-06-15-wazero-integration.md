# Wazero Integration Implementation Plan

> **For agentic workers:** Use /executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Work the phases in order (A → B → C); later phases depend on artifacts from earlier ones.

**Goal:** Let a let-go program load WASM libraries at runtime through the stock `lg` binary — proven end-to-end by an embedded-SQLite wrapper installable via lgx — with no per-user Go toolchain and no runtime rebuild.

**Tech Stack:** Go + [wazero](https://github.com/tetratelabs/wazero) (pure-Go WASM runtime, no cgo); WASI (`wasi_snapshot_preview1`); SQLite compiled to `wasm32-wasi` via wasi-sdk; let-go (Clojure dialect); lgx (let-go package manager).

---

## Design

### Context & constraints

This delivers the **WASM path** from `docs/DYNAMIC_NATIVE_LOADING.md`: a one-time, generic WASM host added to let-go so native libraries ship as portable `.wasm` artifacts, load in-process via wazero, and run on the **stock `lg`** binary. Constraints that shape every decision:

- **cgo-free** — wazero is pure Go, so `CGO_ENABLED=0`, cross-compilation, and the single-static-binary identity are preserved.
- **Fast startup preserved** — measured (`experiments/wasmbench/`): wazero compiles SQLite-wasm in ~1–4 ms, within let-go's single-digit-ms cold start.
- **No per-user toolchain, no runtime rebuild** — users run a wasm-capable `lg`; libraries are data (`.lg` + `.wasm`) fetched by lgx.

### Why one umbrella plan (scope rationale)

This spans three repos but is **one cohesive feature**: a runtime capability (Part A), its first real consumer that validates the capability (Part B), and the package-manager glue that makes it usable (Part C). They share two contracts (below) and only make sense together, so they are planned as one document and executed in dependency-ordered phases.

### Architecture

```
wasm-capable lg  ──runs──▶  user app  ──(require 'sqlite)──▶  sqlite-lg glue (.lg)
                                                                   │ calls
                                                                   ▼
                                                     let-go  wasm/*  host (wazero + WASI)
                                                                   │ loads + calls
                                                                   ▼
                                                     sqlite3.wasm  (wasm32-wasi build)
```

lgx installs the dep (git fetch brings the `.lg` **and** the committed `.wasm`), puts its source on `-source-paths`, its opted-in resources on `-resource-paths`, and checks the active `lg` meets the dep's minimum version.

### Contract A↔B — the `wasm` host namespace

Part A exposes, Part B consumes. Minimal and generic (≈5 functions):

- `(wasm/instantiate src & opts)` → instance handle (a `vm.Boxed`). `src` is a **resource name** (resolved via let-go's resource provider, so it works from FS roots *and* from `lg -b` bundles) or raw bytes. `opts` is a map; `{:dir "."}` mounts a directory for WASI file I/O. Enables `wasi_snapshot_preview1`.
- `(wasm/call inst "fname" & args)` → calls an export; numeric args (i32/i64/f32/f64, encoded as `uint64` by wazero); returns the result(s) as `vm.Int` (or a vector if multiple). Allocation is just `(wasm/call inst "malloc" n)` — no special host fn.
- `(wasm/read inst ptr len)` → bytes from linear memory.
- `(wasm/write inst ptr bytes)` → write bytes into linear memory.
- `(wasm/close inst)` → close the instance.

**String/blob marshaling lives in the consumer (Part B), not the host** — this keeps the host generic. No let-go-defined host functions in v1 (WASI covers SQLite's I/O).

### Contract B↔C — lgx.edn keys a library declares

A library is a normal git dep that also carries its `.wasm`. Two new lgx.edn keys (decided in design):

```clojure
;; sqlite-lg/lgx.edn
:paths          ["src"]
:resource-paths ["resources"]        ; the lib's OWN dev/test resource roots
:lgx/lib            {:resources true} ; opt-in: expose :resource-paths to consumers
:lgx/min-lg-version "1.11.0"          ; runtime floor, checked by lgx at install/run/build
```

- `:lgx/lib {:resources true}` — lgx adds this dep's `:resource-paths` to the consumer's `-resource-paths` **only when present**. Libraries that don't opt in stay source-only (no auto-inclusion of every dep's resources). `:lgx/lib` is an extensible bag for future install-time metadata.
- `:lgx/min-lg-version` — a version floor. lgx compares it to the active `lg`'s version and errors clearly if too old. This avoids leaking internal capability names (no `:wasm true`) and generalizes to any future runtime feature. It is a **sound proxy for "has wasm" only because the wasm host is unconditionally present from that version on** (always-on, not a build tag — see Part A).

### Version-floor handling (the one subtlety)

The wasm host first exists only on the let-go `wazero` branch, unreleased. So:
- The floor is **`1.11.0`** — the intended first release with wasm support (current released `lg` is `1.10.0`). Adjust in one place if it lands in a different release.
- lgx's check is **permissive on unparseable/dev versions**: if `lg` reports a non-semver/dev version (typical for a locally-built branch), lgx proceeds (it cannot prove the floor is unmet, and blocking would break development). The floor is enforced only against parseable release versions below it.
- For end-to-end testing of the *enforcement* path, build the wazero `lg` with an explicit version ldflag (`-X main.version=1.11.0`).

### File I/O strategy & caveat

SQLite is built for `wasm32-wasi`; file I/O rides standard WASI, which wazero implements; the host mounts a directory via `opts {:dir …}`. `:memory:` needs no fs. **Caveat:** WASI has no `fcntl` file locking, so file databases are **single-writer/single-process safe only** — documented, acceptable for v1 (typical CLI/app use). Heavy concurrent writers are out of scope.

### Milestones

- **B1 — `:memory:`**: first end-to-end proof (needs Part A + the SQLite wasm). No fs.
- **B2 — file DB**: adds the WASI dir mount.
- **C**: makes it installable and runnable via lgx (run/repl/build/bundle).

### YAGNI guards (explicitly out of scope for v1)

Let-go-defined host functions; module/compile caching; float-arg helpers; SQLite transactions, prepared-statement reuse, BLOB-as-bytes, pragmas, a next-jdbc-shaped API; lgx release-asset/`:wasm` artifact fetcher (git carries the blob); lgx managing/building a custom `lg`. All are clean later additions.

### Testing strategy

- **Part A:** Go unit tests in `pkg/rt/wasm_test.go` using a tiny hand-built `add.wasm` (no SQLite); a resource-loading test following the existing `resources_e2e_test.go` pattern.
- **Part B:** `test/sqlite_test.lg` run with the Phase-A `lg` directly (no lgx) — `:memory:` and file-DB round-trips, param binding, typed columns, an error case.
- **Part C:** lgx unit test for opt-in resource folding and the version check; an end-to-end test using a sample project that depends on `sqlite-lg` via `:local/root` and asserts `lgx run` and `lgx build` work.

---

## File Structure

### Part A — let-go (`/Users/andrew/Projects/let-go`, branch `wazero`)
- **Create** `pkg/rt/wasm.go` — the `wasm` namespace: wazero runtime singleton + WASI, `instantiate`/`call`/`read`/`write`/`close`, resource-based module loading. Build-tagged `//go:build !js`. One focused file (~250 lines).
- **Create** `pkg/rt/wasm_test.go` — Go unit tests with an embedded `add.wasm`.
- **Create** `pkg/rt/testdata/add.wasm` — ~40-byte test module (`add(i32,i32)->i32`, exported memory).
- **Modify** `go.mod` / `go.sum` — add `github.com/tetratelabs/wazero`.

### Part B — sqlite-lg (`/Users/andrew/Projects/sqlite-lg`, branch `master`)
- **Create** `wasm/Makefile` — reproducible wasi-sdk build of `sqlite3.wasm`.
- **Create** `resources/sqlite3.wasm` — committed build artifact.
- **Create** `src/sqlite.lg` — the `sqlite` namespace: marshaling glue + `open`/`execute!`/`query`/`close`.
- **Create** `lgx.edn` — `:paths`, `:resource-paths`, `:lgx/lib`, `:lgx/min-lg-version`.
- **Create** `test/sqlite_test.lg` — round-trip tests.
- **Modify** `README.md` — usage, build recipe, locking caveat.

### Part C — lgx (`/Users/andrew/Projects/lgx`, branch `wazero`)
- **Modify** `lgx.lg` — `ensure-all!`: propagate each dep's `:dir` and surfaced config keys into result maps; `basis`/`overlay-basis`: fold opted-in dep `:resource-paths`, collect `:lgx/min-lg-version`, invoke the version check, and update the stale "deps never contribute resource roots" comments.
- **Create** `lgx/wasm.lg` (or extend `lgx/runner.lg`) — `lg` version detection (`lg -v`) + `min-lg-version` comparison helper.
- **Modify** `lgx/config.lg` — add `:lgx/lib` and `:lgx/min-lg-version` (optional) to the closed `lgx-schema`; extend the lenient dep reader (`dep-config-schema`/`coords-at`) to surface a dep's `:resource-paths`/`:lgx/lib`/`:lgx/min-lg-version`.
- **Create** `tests/wasm_deps_test.lg` (+ a sample-project fixture) — unit + end-to-end tests.
- **Modify** `docs/` — short "using wasm libraries" note linking the existing docs set.

---

## Tasks

> **Prerequisites:** Part A needs Go (resolves in the let-go repo). Part B needs wasi-sdk and the Phase-A `lg`. Part C needs the Phase-A `lg` (point `LGX_LG` at it) and the Phase-B `sqlite-lg` checkout. /clojure-repl is useful for interactive `.lg` development.

### Phase A — let-go wasm host

#### Task A1: Add wazero dependency

**Files:** Modify `go.mod`, `go.sum` (in `/Users/andrew/Projects/let-go`).

- [ ] **Step 1: Add the dependency**
  Run: `go get github.com/tetratelabs/wazero@latest`
- [ ] **Step 2: Verify cgo-free build still works**
  Run: `CGO_ENABLED=0 go build -o /tmp/lg-wazero .`
  Expected: builds with no error.
- [ ] **Step 3: Record the binary-size delta**
  Build a baseline from a clean tree (or reuse a stock `lg`) and compare `ls -l`. Note the delta in the commit message (expected low-single-digit MiB). This is the always-on cost.
- [ ] **Step 4: Commit**
  `git commit -am "build: add wazero dependency"`

#### Task A2: `wasm` namespace — instantiate / call / close

**Files:** Create `pkg/rt/wasm.go`, `pkg/rt/wasm_test.go`, `pkg/rt/testdata/add.wasm`.

- [ ] **Step 1: Add the test module**
  Create `pkg/rt/testdata/add.wasm`: a minimal module exporting `add(i32,i32)->i32` and its `memory`. Generate from WAT (`wat2wasm`) or embed the known ~43-byte byte sequence; document its source in a comment in the test.
- [ ] **Step 2: Write the failing test**
  In `wasm_test.go`: load `testdata/add.wasm` bytes, `wasm/instantiate` them, `wasm/call` `add` with 2 and 3, assert 5; then `wasm/close`. Follow the `json.go`/`pods.go` native-namespace test conventions.
- [ ] **Step 3: Run test to verify it fails**
  Run: `go test ./pkg/rt/ -run TestWasm -tags '' -v`
  Expected: FAIL (namespace/functions absent).
- [ ] **Step 4: Implement the host (instantiate/call/close)**
  Create `pkg/rt/wasm.go`, `//go:build !js`. Add a lazily-initialized package-level `wazero.Runtime` with `wasi_snapshot_preview1` instantiated once (guarded by `sync.Once`). `installWasmNS` registers via `RegisterInstaller`/`vm.NewNamespace`/`ns.Def`/`vm.NativeFnType.Wrap`/`RegisterNS` (mirror `json.go`). `instantiate` compiles + instantiates the module and returns `vm.NewBoxed(instance)`; `call` looks up the export and calls with `uint64`-encoded args, returning `vm.Int`; `close` closes the module. Use `context.Background()`.
- [ ] **Step 5: Run test to verify it passes**
  Run: `go test ./pkg/rt/ -run TestWasm -v`
  Expected: PASS.
- [ ] **Step 6: Commit**
  `git commit -am "feat(wasm): wazero-backed wasm namespace (instantiate/call/close)"`

#### Task A3: Linear-memory read / write

**Files:** Modify `pkg/rt/wasm.go`, `pkg/rt/wasm_test.go`.

- [ ] **Step 1: Write the failing test**
  Write bytes into the test module's memory at an offset with `wasm/write`, read them back with `wasm/read`, assert equality. (Use the exported `memory` from `add.wasm`.)
- [ ] **Step 2: Run test to verify it fails**
  Run: `go test ./pkg/rt/ -run TestWasmMemory -v`
  Expected: FAIL.
- [ ] **Step 3: Implement read/write**
  Add `wasm/read` (`module.Memory().Read`) returning let-go bytes, and `wasm/write` (`module.Memory().Write`) accepting let-go bytes/string. Decide the byte representation consistent with let-go conventions (byte array; text decodes to string in consumers).
- [ ] **Step 4: Run test to verify it passes**
  Run: `go test ./pkg/rt/ -run TestWasmMemory -v` → PASS.
- [ ] **Step 5: Commit**
  `git commit -am "feat(wasm): linear-memory read/write"`

#### Task A4: Resource-based loading + WASI dir mount

**Files:** Modify `pkg/rt/wasm.go`; add an e2e test following `resources_e2e_test.go`.

- [ ] **Step 1: Write the failing test**
  Following the `resources_e2e_test.go` pattern, set an `FSResourceProvider` rooted at `testdata`, run an `lg` form that `(wasm/instantiate "add.wasm")` (by resource name) and calls `add`, assert the result. Add a second case asserting `{:dir …}` is accepted (WASI mount) using a module/op that touches the mounted fs, or assert instantiate succeeds with the option.
- [ ] **Step 2: Run test to verify it fails**
  Run: `go test ./... -run TestWasmResource -v` → FAIL.
- [ ] **Step 3: Implement resource loading + dir mount**
  In `instantiate`: when `src` is a `vm.String`, resolve via `GetResourceProvider().Open(name)` and read all bytes; when bytes, use directly. Apply `opts {:dir path}` via `ModuleConfig.WithFSConfig` mounting the dir for WASI.
- [ ] **Step 4: Run test to verify it passes**
  Run: `go test ./... -run TestWasmResource -v` → PASS.
- [ ] **Step 5: Run the full package suite**
  Run: `go test ./pkg/rt/ -v` → PASS.
- [ ] **Step 6: Commit**
  `git commit -am "feat(wasm): resource-name loading and WASI dir mount"`

#### Task A5: Build the wasm-capable `lg` artifact

**Files:** none (build + sanity).

- [ ] **Step 1: Build a versioned `lg`**
  Run: `CGO_ENABLED=0 go build -ldflags="-s -w -X main.version=1.11.0" -o /tmp/lg-wazero .`
- [ ] **Step 2: Smoke-test the capability**
  Run: `/tmp/lg-wazero -e "(println (some? (find-ns 'wasm)))"`
  Expected: `true`.
- [ ] **Step 3: Record the artifact path**
  Note `/tmp/lg-wazero` (or install it somewhere stable) — Phases B and C point `LGX_LG`/their `lg` invocation at it.

---

### Phase B — sqlite-lg wrapper

#### Task B1: Build `sqlite3.wasm` (wasi-sdk)

**Files:** Create `wasm/Makefile`, `resources/sqlite3.wasm` (in `/Users/andrew/Projects/sqlite-lg`).

- [ ] **Step 1: Write the build recipe**
  `wasm/Makefile`: download the SQLite amalgamation, compile `sqlite3.c` with wasi-sdk clang for `wasm32-wasi`, reactor model (`-mexec-model=reactor`), `SQLITE_THREADSAFE=0`, exporting the C-API symbols the wrapper uses (`sqlite3_open_v2`, `prepare_v2`, `bind_text`/`int64`/`double`/`null`, `step`, `column_count`/`name`/`type`/`int64`/`double`/`text`/`bytes`, `finalize`, `exec`, `changes`, `last_insert_rowid`, `errmsg`, `close`) plus `malloc`/`free`. Output `resources/sqlite3.wasm`.
- [ ] **Step 2: Build it**
  Run: `make -C wasm`
  Expected: `resources/sqlite3.wasm` produced.
- [ ] **Step 3: Sanity-check the module loads**
  Run: `LG=/tmp/lg-wazero; $LG -resource-paths resources -e "(println (some? (wasm/instantiate \"sqlite3.wasm\")))"`
  Expected: `true`. (If wasi-sdk is unavailable or the build fights, see the design's fallback: a `:memory:`-only first cut needs the same module but no fs — the build is still required; the locking caveat affects only file DBs.)
- [ ] **Step 4: Commit (including the .wasm)**
  `git commit -am "build: sqlite3.wasm via wasi-sdk + build recipe"`

#### Task B2: `sqlite` namespace — `:memory:` (Milestone B1)

**Files:** Create `src/sqlite.lg`, `lgx.edn`, `test/sqlite_test.lg`.

- [ ] **Step 1: Write the failing test**
  `test/sqlite_test.lg`: open `:memory:`, create a table, insert two rows with params, query with a `?`-param filter, assert keywordized typed rows (INTEGER→int, REAL→float, TEXT→string), assert an error case throws. Use the project's test idiom (mirror let-go's `test` ns usage).
- [ ] **Step 2: Run test to verify it fails**
  Run: `/tmp/lg-wazero -source-paths src -resource-paths resources test/sqlite_test.lg`
  Expected: FAIL (namespace absent).
- [ ] **Step 3: Implement the wrapper**
  `src/sqlite.lg` (ns `sqlite`): a shared wasm instance held in an atom (lazily `wasm/instantiate "sqlite3.wasm"`); private marshaling helpers (`cstr`/`read-cstr` via `malloc`+`write`/`read`, column readers by `column_type`, error helper reading `errmsg` → `throw (ex-info …)`); public `open` (returns `{:db <ptr>}`), `execute!` (prepare→bind→step→finalize → `{:rows-affected :last-insert-id}`), `query` (prepare→bind→step-loop→columns → vector of keywordized maps), `close`.
- [ ] **Step 4: Run test to verify it passes**
  Run: `/tmp/lg-wazero -source-paths src -resource-paths resources test/sqlite_test.lg` → PASS.
- [ ] **Step 5: Add lgx.edn**
  Create `lgx.edn` with `:paths ["src"]`, `:resource-paths ["resources"]`, `:lgx/lib {:resources true}`, `:lgx/min-lg-version "1.11.0"`.
- [ ] **Step 6: Commit**
  `git commit -am "feat: sqlite namespace over wasm (:memory:)"`

#### Task B3: File databases via WASI (Milestone B2)

**Files:** Modify `src/sqlite.lg`, `test/sqlite_test.lg`.

- [ ] **Step 1: Write the failing test**
  Open a file DB in a temp dir, create+insert, `close`, reopen, read back — assert persistence.
- [ ] **Step 2: Run test to verify it fails**
  Run: `/tmp/lg-wazero -source-paths src -resource-paths resources test/sqlite_test.lg` → FAIL on the new case.
- [ ] **Step 3: Implement file support**
  In `open`, when `path` is not `:memory:`, instantiate (or re-use an instance configured) with `{:dir <dir-of-path>}` so WASI exposes the directory; pass the in-wasm path accordingly.
- [ ] **Step 4: Run test to verify it passes**
  Run the test → PASS.
- [ ] **Step 5: Commit**
  `git commit -am "feat: file-backed databases via WASI dir mount"`

#### Task B4: README

**Files:** Modify `README.md`.

- [ ] **Step 1: Document** usage (`require` + the four fns), the `wasm/Makefile` build recipe, `:lgx/min-lg-version`, and the **single-writer locking caveat**. Apply /writing-clearly.
- [ ] **Step 2: Commit**
  `git commit -am "docs: sqlite-lg README"`

---

### Phase C — lgx wasm-lib support

#### Task C1: Fold opted-in dep resources into the basis

**Files:** Modify `lgx.lg` (`basis`/`ensure-all!`), `lgx/config.lg` (schema); create `tests/wasm_deps_test.lg` (+ fixtures).

- [ ] **Step 1: Extend the schema**
  In `lgx/config.lg`, add optional `:lgx/lib` (`[:map {:optional true} [:resources {:optional true} :boolean]]`) and `:lgx/min-lg-version` (optional string) to the **closed** project schema `lgx-schema` (config.lg:341, `{:closed true}`). A library declares these in its *own* lgx.edn, which is validated by that closed schema, so the keys must be added there or validation rejects them. (The separate dep-side `dep-config-schema` is already lenient/open — see Step 4.)
- [ ] **Step 2: Write the failing test**
  `tests/wasm_deps_test.lg` with a fixture dep dir containing `lgx.edn` (`:resource-paths ["resources"] :lgx/lib {:resources true}`) and a `resources/` file. Assert the basis/path-assembly includes that resource dir; assert a dep **without** `:lgx/lib {:resources true}` does **not** contribute resources.
- [ ] **Step 3: Run test to verify it fails**
  Run the repo's test command (e.g., `lgx test` / `make test`) → FAIL.
- [ ] **Step 4: Surface dep resource metadata**
  `ensure-all!` (lgx.lg:68) already reads each fetched dep's lgx.edn transitively via `coords-at!` (config.lg), but that path returns only `:deps` (other keys discarded) and the result maps are `{:lib :path :installed?}` — **no `:dir`**. Do NOT use `config/load-config` on a dep dir: it validates against the closed `lgx-schema` and targets the project's own file, whereas deps are read leniently on purpose (a newer dep may carry unknown top-level keys). Instead: (a) extend the lenient dep reader (`dep-config-schema` + `coords-at`, or add a sibling reader) to also surface the dep's `:resource-paths`, `:lgx/lib`, and `:lgx/min-lg-version`; (b) propagate the dep's `:dir` (available at lgx.lg:97 from `cache/ensure-lib!`) into the `ensure-all!` result maps.
- [ ] **Step 5: Fold opted-in resources into the basis**
  In `basis`/`overlay-basis` (lgx.lg:163, 200): for each resolved dep whose lgx.edn declares `:lgx/lib {:resources true}`, resolve its `:resource-paths` under the dep's `:dir` and append to the basis `:resource-paths` (dedup, order-preserving). Leave source-path resolution unchanged. Update the now-stale comments on `basis` (lgx.lg:170-171) and `overlay-basis` (lgx.lg:201-202) that assert deps never contribute resource roots (AGENTS.md mandates same-PR doc sync).
- [ ] **Step 6: Run test to verify it passes** → PASS.
- [ ] **Step 7: Commit**
  `git commit -am "feat: opt-in dep resource-paths via :lgx/lib"`

#### Task C2: `lg` version detection + `min-lg-version` check

**Files:** Create `lgx/wasm.lg` (version helper); modify `lgx.lg` (call the check); modify tests.

- [ ] **Step 1: Write the failing test**
  Assert: a dep `:lgx/min-lg-version` above the active `lg` version produces a clear error; below/equal passes; an unparseable/dev `lg` version passes (permissive). Stub the detected version for determinism.
- [ ] **Step 2: Run test to verify it fails** → FAIL.
- [ ] **Step 3: Implement detection + comparison**
  In `lgx/wasm.lg`: detect the active `lg` version via `lg -v` (prints `lg <version>`; `main.version` defaults to `"dev"`, which feeds the permissive rule), parse semver, and compare. A `check-min-lg-version!` fn takes the max of resolved deps' `:lgx/min-lg-version` and the detected version; throws an `ex-info` with an actionable message (which dep, required vs. found, how to get a newer `lg`) when unmet; no-ops on unparseable/dev versions. Call it from `cmd-install` (early) and from `basis` (covers run/nrepl/build/test/task).
- [ ] **Step 4: Run test to verify it passes** → PASS.
- [ ] **Step 5: Commit**
  `git commit -am "feat: enforce :lgx/min-lg-version against active lg"`

#### Task C3: End-to-end integration (sample project)

**Files:** Create a sample-project fixture under `tests/`; add an e2e test.

- [ ] **Step 1: Write the failing test**
  Sample project with `lgx.edn` `{:deps {sqlite {:local/root "../../sqlite-lg"}} :main "main.lg"}` and a `main.lg` doing a `:memory:` + file round-trip via `(require 'sqlite)`. Drive `lgx run` with `LGX_LG=/tmp/lg-wazero`; assert expected stdout. Then `lgx build` the project; run the produced binary with `lg`/`go` off `PATH`; assert the same output (proves self-contained bundle embeds `sqlite3.wasm`).
- [ ] **Step 2: Run test to verify it fails** → FAIL (resources/version wiring not yet exercised end to end).
- [ ] **Step 3: Make it pass**
  Resolve any wiring gaps surfaced (resource-path ordering, bundle inclusion). No new mechanism expected — `lg -b` already embeds `-resource-paths` files.
- [ ] **Step 4: Run test to verify it passes** → PASS.
- [ ] **Step 5: Commit**
  `git commit -am "test: end-to-end wasm sqlite dep via lgx run + build"`

#### Task C4: Docs

**Files:** Modify `docs/` (lgx).

- [ ] **Step 1: Add** a short "Using WASM libraries" section: declaring a wasm dep, `:lgx/min-lg-version`, the wasm-capable `lg` requirement, and links to `docs/DYNAMIC_NATIVE_LOADING.md` and `docs/GO_LIBS_INTEROP_OPTIONS.md`. Apply /writing-clearly.
- [ ] **Step 2: Commit**
  `git commit -am "docs: using wasm libraries with lgx"`

---

## Done criteria

- A wasm-capable `lg` builds cgo-free; `(find-ns 'wasm)` is true; the binary-size delta is recorded.
- `sqlite-lg` runs `:memory:` and file round-trips via the wasm host using only `lg` (no lgx).
- A sample project declaring `sqlite-lg` as a dep runs via `lgx run` and produces a self-contained binary via `lgx build`, both exercising real SQLite queries.
- The `min-lg-version` check errors clearly against an old `lg` and is permissive on dev versions.
