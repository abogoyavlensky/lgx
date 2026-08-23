# lgx Go Deps Pipeline Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let lgx projects declare Go package dependencies in `lgx.edn`, build a cached custom `lg` runtime that links them, wire it through every command transparently, and prove it end-to-end with a thin sqlite wrapper in the `letgo-packages` monorepo.

**Tech Stack:** let-go (`.lg` — lgx is written in it), the Go toolchain (invoked as a subprocess), let-go's `pkg/cli` + `cmd/lginterop` from the upstream plan (`docs/plans/2026-08-23-0006-letgo-out-of-tree-interop.md`).

---

## Design

### Context and dependency on the upstream plan

This is the lgx half of the go-interop work. It assumes the let-go upstream half exists at least on the local `integration/go-interop` branch (built per the upstream plan): `cmd/lginterop -out-pkg` emitting self-contained interop packages, importable `pkg/cli`, and the multi-return reflect proxy. Tasks 1–3 (config + pure functions) have no dependency on it and are implementable immediately; Tasks 4+ need the integration branch for verification.

End-user contract when this lands: `go` on PATH (preflight error suggests `mise use -g go@latest`), one wrapper dep line in `lgx.edn`, and a `:lg-version` pin. First `lgx install` (or first run) builds the custom runtime once; everything after is cached and `run`/`repl`/`test`/`build` behave exactly as before, including single-binary `lgx build` output.

### The `:go/*` coord family

Go deps live in the existing `:deps` map (and `:extra-deps` everywhere it appears) as a third coord family alongside `:local/root` and `:git/*`. The dep symbol IS the Go package path. Two orthogonal capabilities:

- **Link-only** (`:go/version`): the module is required in `go.mod` and blank-imported in the generated `main.go` — for drivers and self-registering native packages (shims).
- **Bindings** (`:go/interop "<alias>"`): lginterop generates a namespace for the package.

```clojure
{:deps {database/sql                              {:go/interop "sql"}
        modernc.org/sqlite                        {:go/version "v1.38.0"}
        github.com/you/letgo-packages/sqlite/shim {:go/version "v0.1.0"}}}
```

Rules (enforced in the coord schema):

- Family marker: any `:go/*` key. Mixing `:go/*` with `:git/*` or `:local/root` is an error.
- External module (first path segment of the symbol contains a `.`): `:go/version` required (any non-blank string Go accepts — tag, sha, branch), OR `:go/local "<path>"` instead for a dev-time `replace` directive (mirrors `:local/root`). A relative `:go/local` resolves against the *declaring* file's directory — the project root for top-level deps, the dep's own directory for transitive ones — and must be normalized to absolute at collection time, while that base is still known (same rule `coord-id` applies to `:local/root`, `lgx.lg:52`).
- Stdlib package (first segment has no `.`, e.g. `database/sql`): `:go/interop` required; `:go/version`/`:go/local` forbidden (stdlib has no module requirement).
- `:go/interop` is optional on external modules (module that both links and gets bindings). MVP limitation: the alias value must equal lginterop's default alias (the last path segment) — `cmd/lginterop -packages` has no per-package alias flag yet; validate and error on mismatch with a message saying so.
- Version conflicts across the transitive tree are left to Go MVS: lgx dedups go coords by lib symbol (first-wins with a warning on differing coords, same as git deps) and writes what it has into `go.mod`; `go mod tidy` settles final versions.

Transitive collection: `ensure-all!` already walks each dep's own `lgx.edn` `:deps`. Go coords are partitioned out of that same walk — they produce no source path and no gitlibs clone; they accumulate into a deduped list returned alongside the install results. A wrapper's go deps thus flow up to the consumer invisibly.

### Custom runtime build (`lgx/gobuild.lg`)

When the resolved coord set contains go coords:

1. **Preflight**: `go` resolvable on PATH (`command -v`), else exit 1 with the mise hint. `:lg-version` required in `lgx.edn` (it pins the `github.com/nooga/let-go` require), unless `LGX_LETGO_REPLACE` is set (see below).
2. **Cache key**: hash of (let-go ref — the `:lg-version`, or `replace:<abs-path>` — × the sorted, canonical go-coord lines `lib|version|interop|local`). Use let-go's bundled hash namespace (`pkg/rt/core/hash.lg` — xxh3; executor confirms the exact fn name) rendered as hex. Runtime lives at `$LGX_HOME/runtimes/<hash>/` with `src/` (the generated module) and `lg` (the built binary).
3. **Module generation** in `src/`. Key subtlety: a coord symbol is a Go *package* path, which is not always a *module* path (`golang.org/x/crypto/ssh` lives in module `golang.org/x/crypto`). So lgx never hand-writes `require` lines for external coords — `go get <pkg>@<version>` resolves the owning module itself. Files written:
   - `go.mod`: module `lgx.local/runtime`; `require github.com/nooga/let-go v<lg-version>` (or `v0.0.0` + `replace` under `LGX_LETGO_REPLACE`); for each `:go/local` coord a `require <module> v0.0.0` + `replace <module> => <abs-path>`, where `<module>` is read from the `module` line of the target's own `go.mod` (a `:go/local` target must be a Go module).
   - `main.go`: imports `os` and `github.com/nooga/let-go/pkg/cli`; one blank import per link-only coord (the coord symbol — a coord with `:go/interop` needs none, its generated binding package imports it); blank import of `lgx.local/runtime/interop` when any interop coords exist; `func main() { os.Exit(cli.Main("dev", "none")) }`.
   - `interop/doc.go` (`package interop` only) when interop coords exist — a placeholder so the module resolves *before* lginterop runs (chicken-and-egg: `main.go` imports the interop package, but lginterop can only scan once the module's deps are fetched).
4. **Build steps** (cwd = `src/`, each failure surfaces the subprocess output and exits 1): `go get <sym>@<version>` per `:go/version` coord → `go mod tidy` → when interop coords exist, `go run github.com/nooga/let-go/cmd/lginterop -packages <p1,p2,...> -out-pkg interop -out interop` (overwriting alongside the placeholder) → `go build -o ../lg .`.
5. **Cache policy**: if `$LGX_HOME/runtimes/<hash>/lg` exists, use it, skipping all of the above — EXCEPT when any `:go/local` coord or `LGX_LETGO_REPLACE` is in play: then always re-run the build steps (the replace target's content isn't in the hash; `go build` is incremental so this is cheap). Module dir is reused across rebuilds.

`LGX_LETGO_REPLACE=<path-to-let-go-checkout>` is the dev/verification lever: it emits `replace github.com/nooga/let-go => <path>` (with `require github.com/nooga/let-go v0.0.0` as the placeholder the replace overrides) so the runtime builds against a local branch — this is how the whole pipeline is verified against `integration/go-interop` before any let-go release exists.

### Wiring

- **Runtime selection**: `runner/lg-binary` already reads `LGX_LG`. After the basis resolves and the runtime is ensured, set it: when the user has NOT set `LGX_LG`, `(os/setenv "LGX_LG" <runtime-path>)`; when they HAVE, their value wins and lgx prints a one-line stderr warning that go deps are declared but an explicit LGX_LG overrides the custom runtime. Zero changes to `runner.lg`.
- **Version check**: skip `check-lg-version!` when the custom runtime is active — it is built from the pinned version by construction, and the check would otherwise probe the wrong binary at the wrong time.
- **`lgx install`**: ensures the runtime too (after deps fetch, alongside `install-letgo-source!`), so install = fully warmed, CI-friendly.
- **`lgx build`**: inject `["-bundle-base" <runtime-path>]` into the lg argv before `-b` — unless the user's forwarded args already contain `-bundle-base` (their cross-compile override wins).
- All basis commands (run/repl/nrepl/test/build/tasks) go through one shared helper so the ensure+setenv logic lives in one place.

### The sqlite wrapper (`/Users/andrew/Projects/letgo-packages/sqlite/`)

Monorepo layout, consumed via `:deps/root "sqlite"`. Four pieces:

- `sqlite/lgx.edn` — `:paths ["src"]` + the three go coords shown above (shim via `:go/local "shim"` during development; `:go/version` once tagged).
- `sqlite/src/sqlite/core.lg` — the veneer, per the sketch in let-go's `docs/guide/go-interop.md` (§ database/sql): `(open path)` → boxed `*sql.DB` via `sql/Open "sqlite" path`; `(close! db)`; `(query db ["select ... where x = ?" v])` → realized vector of keyword-keyed maps (`.Query` → `.Columns` → loop `.Next`/`shim/ScanRow` → `zipmap`, `doall`ed before `.Close` in a `finally`); `(execute! db ["insert ..."])` → `{:rows-affected n}` via `.Exec`/`.RowsAffected`.
- `sqlite/shim/` — a tiny Go module (`go.mod` + `shim.go`): `ScanRow(rows *sql.Rows) ([]any, error)` exactly as written in the guide, and `func init()` registering it (`vm.NewNamespace("sqlite.shim")`, `ns.Def("ScanRow", vm.MustBox(ScanRow))`, `rt.RegisterNS(ns)`) — the same shape lginterop `-out-pkg` emits. Module path from the repo's git remote (fallback `github.com/abogoyavlensky/letgo-packages/sqlite/shim`); its let-go require can be a placeholder version while `LGX_LETGO_REPLACE`/root-module replace governs, but must be pinned to a real release before the wrapper is tagged.
- `sqlite/example/` — a consuming app (`lgx.edn` with the wrapper via `:local/root "../"` + `:deps/root` semantics — use `:local/root ".."` and `:paths` as needed — plus `:main`, `:lg-version`, `:targets {:bin {:out "bin/app"}}`; `main.lg` creates a table, inserts, queries, prints rows). This is the end-to-end verification vehicle.

**Driver choice: `modernc.org/sqlite` (pure Go), not `mattn/go-sqlite3`** — no cgo means no C compiler requirement for end users and clean `-bundle-base` cross-builds. Driver name in `sql/Open` is `"sqlite"`.

### Testing strategy

- Unit tests (`test/lgx/*_test.lg`, run via `lgx test` in the lgx repo): coord-family validation cases; partition + transitive union; cache-key canonicalization; `go.mod`/`main.go` rendering; bundle-base injection decision; LGX_LG-override decision. All pure functions — design them as such.
- The subprocess pipeline (`go mod tidy`/lginterop/`go build`) and the wrapper are verified by the scripted end-to-end task (Task 8) against the integration branch — not unit-tested. It requires `go` on PATH and the let-go worktree; the task states the prereqs and is skipped cleanly if absent.
- Docs same-PR (AGENTS.md rule): README coord-family + requirements section, `docs/ARCHITECTURE.md` data-flow update, new `docs/knowledge-base/lgx-go-runtimes.md` (cache layout, LGX_LETGO_REPLACE, rebuild policy) with a `Verify against:` footer.

## File Structure

lgx repo (`/Users/andrew/Projects/lgx`):

- Modify: `lgx/config.lg` — go-coord validation inside `coord-errors`; `go-coord?` predicate; alias-default helper.
- Modify: `lgx.lg` — `ensure-all!` partition + new return shape; shared `ensure-runtime!` helper; call-site updates (`basis`, `cmd-install`, `cmd-build` injection, version-check skip).
- Create: `lgx/gobuild.lg` — cache key, `go.mod`/`main.go` rendering (pure), preflight, module write + subprocess build (side-effecting).
- Create: `test/lgx/gobuild_test.lg`; Modify: `test/lgx/config_test.lg` (or nearest existing config/coord test file — check `test/lgx/` first).
- Modify: `README.md`, `docs/ARCHITECTURE.md`; Create: `docs/knowledge-base/lgx-go-runtimes.md`.

letgo-packages repo (`/Users/andrew/Projects/letgo-packages`):

- Create: `sqlite/lgx.edn`, `sqlite/src/sqlite/core.lg`, `sqlite/shim/go.mod`, `sqlite/shim/shim.go`, `sqlite/example/lgx.edn`, `sqlite/example/main.lg`, and fill `sqlite/README.md`.

---

### Task 1: `:go/*` coord family in config validation

**Files:**
- Modify: `lgx/config.lg`
- Test: the existing config test file under `test/lgx/` (locate it first; create `test/lgx/config_test.lg` if none covers coords)

- [ ] **Step 1: Write failing tests**
  Cases: valid external link-only (`:go/version`); valid external with `:go/local`; valid stdlib (`:go/interop` only); valid external with both `:go/version` and `:go/interop`; error on stdlib with `:go/version`; error on external with neither `:go/version` nor `:go/local`; error mixing `:go/version` with `:git/url`; error on `:go/interop` alias not equal to the default (last path segment); go coords accepted in `:extra-deps` (contexts/tasks) and by the lenient dep-config schema.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lgx test test/lgx/<file>` in `/Users/andrew/Projects/lgx`.
  Expected: FAIL on the new cases.

- [ ] **Step 3: Implement**
  In `coord-errors` (`lgx/config.lg:64`): detect the `:go/*` family (any key with namespace `"go"`), branch before the git/local logic, apply the rules from the Design. Add public helpers: `(go-coord? c)` and `(go-default-alias lib-sym)` (last `/` segment) — `lgx.lg` and `gobuild` share them. Stdlib detection: first `/`-segment of the symbol string contains no `.`.

- [ ] **Step 4: Run tests to verify pass**
  Run: `lgx test`
  Expected: PASS, full suite green.

- [ ] **Step 5: Commit**
  `git commit -m "feat(config): :go/* coord family for Go package deps"`

### Task 2: Partition go coords through resolution

**Files:**
- Modify: `lgx.lg` (`ensure-all!`, `basis`, `cmd-install`)
- Test: `test/lgx/gobuild_test.lg` (start it here) or the existing resolution test file

- [ ] **Step 1: Write failing tests**
  `ensure-all!` is currently private and side-effecting; extract the partition/dedup decision into a pure helper (e.g. `split-go-coords` taking `[lib coord base]` entries → `{:src-pairs [...] :go-pairs [...]}`) and test that: go coords split out; first-wins dedup with warning on a differing duplicate go coord; git/local pairs untouched; a relative `:go/local` is rewritten to absolute against the entry's `base` (transitive case: a dep declaring `{:go/local "shim"}` yields `<dep-dir>/shim`).

- [ ] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [ ] **Step 3: Implement**
  In `ensure-all!` (`lgx.lg:71`): partition each queue level with the helper; go coords never reach `cache/ensure-lib!` but ARE collected across the transitive walk (a dep's `lgx.edn` go coords flow up via the same `coords-at!` read). Return shape changes to `{:installs [...] :go-coords [[lib coord] ...]}`; update `basis` (thread `:go-coords` into its return map) and `cmd-install`/`print-installs!` call sites.

- [ ] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [ ] **Step 5: Commit**
  `git commit -m "feat: collect :go/* coords through transitive resolution"`

### Task 3: gobuild pure functions — cache key and file rendering

**Files:**
- Create: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [ ] **Step 1: Write failing tests**
  - Cache key: stable across coord order; changes with any of lib/version/interop/local and with the let-go ref; `LGX_LETGO_REPLACE` ref renders as `replace:<abs-path>`.
  - `render-go-mod`: module line `lgx.local/runtime`; let-go require with pinned version; `v0.0.0` + replace when a replace path is given; one `require ... v0.0.0` + `replace` pair per `:go/local` coord using a caller-supplied module path (the fn takes `[coord module-path]` pairs — reading the target's `go.mod` is the side-effecting caller's job); NO require lines for `:go/version` coords (they're added via `go get` — see Design); stdlib coords absent.
  - `render-main-go`: `pkg/cli` import + `cli.Main` call; blank imports only for link-only external coords; `lgx.local/runtime/interop` blank import iff any interop coords; no interop import otherwise.
  - `interop-packages`: ordered list of package paths for the `-packages` flag.
  - `go-get-args`: `["get" "<sym>@<version>"]` per `:go/version` coord, deterministic order.

- [ ] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [ ] **Step 3: Implement**
  Pure string-rendering fns in `lgx.gobuild`; hash via let-go's bundled hash ns (confirm the fn in `pkg/rt/core/hash.lg` of the pinned let-go — e.g. xxh3 — and render hex). Canonical coord line: `lib|version|interop|local` with empty slots for absent keys, sorted.

- [ ] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [ ] **Step 5: Commit**
  `git commit -m "feat(gobuild): cache key and runtime module rendering"`

### Task 4: gobuild side-effecting pipeline

**Files:**
- Modify: `lgx/gobuild.lg`

No unit tests (subprocess orchestration; covered by Task 8 e2e). Follow the existing subprocess conventions in `lgx/cache.lg` (`git!`-style error wrapping) and `lgx/runner.lg`.

- [ ] **Step 1: Implement preflight**
  `go-available?` via `command -v` (the `sh -c "command -v -- \"$1\""` pattern from `runner/lg-resolved-path`, `lgx/runner.lg:37`). On missing: stderr error naming the fix (`mise use -g go@latest` or https://go.dev/dl) and exit 1. On go coords present with no `:lg-version` and no `LGX_LETGO_REPLACE`: error explaining `:lg-version` pins the runtime's let-go.

- [ ] **Step 2: Implement `ensure-runtime!`**
  Signature: `(ensure-runtime! go-pairs lg-version verbose?)` → absolute path of the built `lg`. Logic per Design: hash → `$LGX_HOME/runtimes/<hash>/`; cache hit returns immediately unless a local replace is active; else: read the `module` line from each `:go/local` target's `go.mod` (error if the target isn't a module), write `src/go.mod` + `src/main.go` + placeholder `src/interop/doc.go` (when interop coords), then with cwd `src/`: `go get <sym>@<version>` per `:go/version` coord → `go mod tidy` → (when interop coords) `go run github.com/nooga/let-go/cmd/lginterop -packages <csv> -out-pkg interop -out interop` → `go build -o ../lg .` — each failure printing the captured output and exiting 1. `--verbose` traces each subprocess command (match the `+ ...` trace style in `runner.lg`). Print a one-line `Building custom lg runtime...` header (via `lgx.style`) on cold builds so the first-run pause is explained.

- [ ] **Step 3: Manual smoke (no commit gate)**
  With `LGX_LETGO_REPLACE` pointed at the integration worktree and a scratch project declaring `{database/sql {:go/interop "sql"}}`, confirm a binary appears under `$LGX_HOME/runtimes/` and `<runtime>/lg -v` runs. (Full verification is Task 8.)

- [ ] **Step 4: Commit**
  `git commit -m "feat(gobuild): build and cache the custom lg runtime"`

### Task 5: Wire the runtime into commands

**Files:**
- Modify: `lgx.lg`
- Test: `test/lgx/gobuild_test.lg`

- [ ] **Step 1: Write failing tests for the pure decisions**
  - LGX_LG override: helper deciding `{:setenv path}` vs `{:warn ...}` given (user-LGX_LG-set?, go-coords-present?).
  - Bundle-base injection: given forward-args and a runtime path, argv gains `["-bundle-base" path]` before `-b` only when the user's args don't already contain `"-bundle-base"`.

- [ ] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [ ] **Step 3: Implement**
  A shared helper in `lgx.lg` called right after each command's basis: when `:go-coords` non-empty → preflight, `ensure-runtime!`, then setenv-or-warn per the helper. Skip `check-lg-version!` when the custom runtime is active (call sites at `lgx.lg:305,330,357,374,422` — restructure so the check runs only in the no-go-deps path). `cmd-install` calls the same helper after `print-installs!`. `cmd-build` uses the injection helper for its argv (`lgx.lg:388`).

- [ ] **Step 4: Verify pass** — `lgx test`, expected PASS (existing suite must stay green — no-go-deps projects take the unchanged path).

- [ ] **Step 5: Commit**
  `git commit -m "feat: custom runtime wired through run/repl/test/build/install"`

### Task 6: Docs

**Files:**
- Modify: `README.md` (coord family reference, end-user requirements: go on PATH via mise, `:lg-version`), `docs/ARCHITECTURE.md` (resolution data flow + runtimes cache in the `$LGX_HOME` layout section)
- Create: `docs/knowledge-base/lgx-go-runtimes.md` (cache layout, hash inputs, `LGX_LETGO_REPLACE`, rebuild policy, troubleshooting `go` failures) with a `Verify against: lgx/gobuild.lg, lgx.lg` footer

- [ ] **Step 1: Write the docs** (use /writing-clearly)
- [ ] **Step 2: Commit** — `git commit -m "docs: Go deps pipeline"`

### Task 7: sqlite wrapper in letgo-packages

**Files (repo `/Users/andrew/Projects/letgo-packages`):**
- Create: `sqlite/lgx.edn`, `sqlite/src/sqlite/core.lg`, `sqlite/shim/go.mod`, `sqlite/shim/shim.go`, `sqlite/example/lgx.edn`, `sqlite/example/main.lg`; fill `sqlite/README.md`

- [ ] **Step 1: Shim module**
  Module path: from `git -C /Users/andrew/Projects/letgo-packages remote get-url origin` (fallback `github.com/abogoyavlensky/letgo-packages`) + `/sqlite/shim`. `shim.go`: the `ScanRow` implementation from let-go's `docs/guide/go-interop.md` verbatim, plus the init registering `sqlite.shim/ScanRow` (`vm.NewNamespace` + `vm.MustBox` + `rt.RegisterNS`). `go.mod` requires let-go at a placeholder (root-module replace governs during dev; note in README it must pin a real release before tagging). Sanity: `go vet ./...` inside `shim/` with a temporary replace, or defer compile-checking to Task 8's pipeline build.

- [ ] **Step 2: Wrapper `lgx.edn` + veneer**
  `lgx.edn`: `:paths ["src"]`; deps `database/sql {:go/interop "sql"}`, `modernc.org/sqlite {:go/version "<current release — check pkg.go.dev>"}`, shim via `{:go/local "shim"}` for now. `src/sqlite/core.lg`: `open` / `close!` / `query` / `execute!` per the Design (realize with `doall` before closing rows; keywordize columns).

- [ ] **Step 3: Example app**
  `example/lgx.edn`: dep on the wrapper `{:local/root ".."}`, `:main "main.lg"`, `:lg-version` matching the integration branch's version token, `:targets {:bin {:out "bin/app"}}`. `main.lg`: open a file db in a temp path, `create table`, two inserts (parameterized), `query` and print the row maps, print `:rows-affected` — output deterministic enough to eyeball.

- [ ] **Step 4: Commit (letgo-packages repo)**
  `git -C /Users/andrew/Projects/letgo-packages add -A && git -C /Users/andrew/Projects/letgo-packages commit -m "Add sqlite wrapper: shim, veneer, example"`

### Task 8: End-to-end verification

Prereqs: `go` on PATH; the let-go worktree `/Users/andrew/Projects/let-go-interop` on `integration/go-interop` (built per the upstream plan, Task 8 there). If absent, stop and report — do not fake the verification.

- [ ] **Step 1: Run path**
  In `sqlite/example/`: `LGX_LETGO_REPLACE=/Users/andrew/Projects/let-go-interop lgx run` (lgx itself per the dev-workflow doc — `docs/knowledge-base/lgx-dev-workflow.md`).
  Expected: cold build header, then the example's printed rows. Re-run: because the shim is `:go/local` (and `LGX_LETGO_REPLACE` is set), the second run takes the incremental-rebuild path, NOT the cache-hit skip — verify it re-runs `go build` and stays fast (a few seconds). The pure cache-hit skip only applies to fully pinned coord sets.

- [ ] **Step 2: Build path**
  Same env: `lgx build`, then run `bin/app` directly.
  Expected: identical output from the standalone binary; confirm with `lgx build --verbose` that `-bundle-base` pointed at the runtimes-cache binary.

- [ ] **Step 3: Regression**
  In `/Users/andrew/Projects/lgx`: `lgx test` — full suite green (no-go-deps path unchanged).

- [ ] **Step 4: Record findings**
  Append gotchas discovered (registration timing, tidy/network behavior, alias issues) to `docs/knowledge-base/lgx-go-runtimes.md`; commit in the owning repo(s).
