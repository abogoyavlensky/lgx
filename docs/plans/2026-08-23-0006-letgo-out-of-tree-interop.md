# let-go Out-of-Tree Go Interop Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the upstream let-go changes that let a third-party Go module generate interop bindings for arbitrary Go packages and build a full-featured custom `lg` binary — the prerequisite for lgx's `:go/version` deps pipeline.

**Tech Stack:** Go (let-go `pkg/vm`, `pkg/rt`, `pkg/api`, `cmd/lginterop`), let-go codegen script (`scripts/lginterop.lg` / gogen), `go test` + `make test`.

---

## Design

### Context

lgx will support Go package deps (`:deps {github.com/mattn/go-sqlite3 {:go/version "v1.14.22"}}`) by generating a small Go module that imports let-go plus the user's Go packages plus lginterop-generated binding packages, building a custom `lg`, and using it as both `LGX_LG` (run/repl/test) and `-bundle-base` (build). Design must stay compatible with the go-aot-backend lowering direction (`docs/design/go-aot-backend.md` in let-go): everything here targets the `pkg/vm`/`pkg/rt` surface that design explicitly preserves.

Three things block that today, all upstream in let-go:

1. **lginterop is in-tree only.** It finds a let-go checkout by walking to `go.mod` (`cmd/lginterop/main.go:131`), `go build`s a fresh `lg` there (`main.go:146`), shells out to it with `-source-paths <root>/scripts` (`main.go:348`), and the codegen script hardcodes `package rt` output with unqualified `RegisterInstaller`/`RegisterNS` calls (`scripts/lginterop.lg:312`, `:267`, `:280-282`).
2. **`RegisterInstaller` cannot work out-of-tree.** The installer queue drains during rt's own package init (`pkg/rt/zz_run_installers.go:19`), which Go runs *before* any importing package's init. An out-of-tree generated file calling `RegisterInstaller` from its `init()` would enqueue after the drain and silently never run. Out-of-tree files must call their install function directly from `init()` — safe because rt is fully initialized by then, `RegisterNS` is mutex-guarded (`pkg/rt/lang.go:534`), and timing relative to `LoadCore` is identical to in-tree installers (both run before it).
3. **`lg` is unimportable.** The full CLI lives in `package main` at the module root (`lg.go`), so a third-party module can only build an `lg-runtime`-style bytecode host — no repl, no resolver, no `-b`. The lgx pipeline needs the custom binary to *be* `lg`: it serves as `LGX_LG` for run/repl/test and as the compiling side of `lg -b`, and compilation itself needs the natives linked (top-level forms execute at AOT time; veneer `(:require)`s must resolve the native namespace).

### The three PRs

**PR 1 — self-contained lginterop + `-out-pkg` emission.**

- Move `scripts/lginterop.lg` to `cmd/lginterop/lginterop.lg` and `//go:embed` it (go:embed cannot reach outside the package directory). Evaluate the generated codegen script **in-process** via `pkg/api` (`api.NewLetGo(...).Run(src)`) instead of building and shelling out to `lg`. The `gogen` namespace is available in any binary importing rt — it registers via installer (`pkg/rt/gogen.go:2352`). This removes the repo-root walk, the `ensureLgBinary` build, and the emitter-drift problem the current code fights (stale-`./lg` comment at `main.go:146-152`; the test-cache blind spot documented in `test/e2e/lginterop_regen_test.go` shrinks). Net result: `go run github.com/nooga/let-go/cmd/lginterop@<version> -packages ... -out-pkg ...` works from anywhere — exactly how lgx will invoke it.
- New `-out-pkg <name>` flag. Absent → today's exact output (`package rt`, unqualified calls, `RegisterInstaller`), so golden tests and in-tree files are untouched. Present → emit `package <name>`; import `pkg/vm` *and* `pkg/rt`; `rt.RegisterNS(ns)`; and `func init() { install<Alias>NS() }` (direct call, per point 2 above). The generated-by header records `-out-pkg` so regeneration round-trips.
- Scanning caveat: the `go/types` source importer resolves packages from the working directory's module context. Out-of-tree scanning of `github.com/mattn/go-sqlite3` requires running inside a module that requires it (lgx runs lginterop inside the generated module, so this is fine). Document it and fail with a clear error when an import fails.

**PR 2 — extract `pkg/cli` for full-featured custom mains.**

Mechanically move `lg.go`'s package functions (`runMain`, `initCompiler`, `bundleBinary`, `buildSearchPaths`, flag setup, …) into a new importable `pkg/cli` with entrypoint `cli.Main(version, commit string) int`. Root `lg.go` becomes a thin wrapper that keeps the goreleaser ldflags contract (`version`/`commit` vars stay in `package main`). A custom binary is then:

```go
package main

import (
    "os"

    "github.com/nooga/let-go/pkg/cli"
    _ "example.com/custom/interop" // lginterop -out-pkg output
    _ "github.com/mattn/go-sqlite3" // user go-deps needing blank import
)

func main() { os.Exit(cli.Main("dev", "none")) }
```

Plus `docs/guide/custom-lg.md` documenting the pattern end-to-end, and a hermetic e2e proving it (temp module + `replace` directive to local let-go + stdlib scan target, no network).

**PR 3 — reflect proxy multi-return (required).**

`pkg/vm/native_func_reflect.go` assumes ≤2 return values and silently drops extras. That drop happens on the Go side, before values are boxed — so a pure-`.lg` veneer can never recover them, and wrapper libs have no Go code of their own to shim with. Since `(a, b, ok/err)` is a common modern Go idiom (`strings.Cut` returns three values), this is required for the general wrapper story: `(a, b, error)` → vector `[a b]` + error-as-throw; `(a, b)` → `[a b]`; generalize to n. Not needed for `database/sql`/sqlite specifically, so it can land in parallel with lgx-side work rather than before it. Touches only `pkg/vm` — independent of PRs 1–2.

(A kebab-case generator flag was considered and dropped: veneers own idiomatic naming, and keeping generated bindings byte-identical to the Go names makes the raw layer easier to cross-reference against Go docs.)

**Integration branch (convenience, not a PR).** `integration/go-interop` in let-go merges the PR branches (mirroring the existing `integration/honeysql-fixes` pattern) so lgx-side work can build one `lg` binary and develop against it via `LGX_LG`.

### Working arrangement

The let-go checkout at `/Users/andrew/Projects/let-go` is on `aero/g3-parse-boolean` with uncommitted changes. Do not touch it: work in a fresh git worktree off local `main` at `/Users/andrew/Projects/let-go-interop`. Branch names: `interop/p1-out-of-tree-lginterop`, `interop/p2-pkg-cli`, `interop/p3-reflect-multireturn`, and `integration/go-interop`. p1 and p3 start from `main`; p2 merges p1 (its e2e needs `-out-pkg`).

### Testing strategy

- PR 1: existing regen/round-trip e2e stays green unchanged (default mode is byte-identical); new e2e generates with `-out-pkg` for a stdlib package into a temp module and asserts `go build` succeeds there.
- PR 2: `make test` green after extraction (pure refactor); new hermetic e2e builds a custom main via `pkg/cli` + generated interop for a stdlib package, runs a `.lg` script calling the generated namespace, and exercises `-b` bundling with the custom binary as its own bundle base.
- PR 3: table-driven unit tests in `pkg/vm` for multi-return.
- Integration: build `lg` from `integration/go-interop`, point `LGX_LG` at it, run lgx's own test suite as a no-regression smoke.

## File Structure

In the let-go worktree (`/Users/andrew/Projects/let-go-interop`):

- Move: `scripts/lginterop.lg` → `cmd/lginterop/lginterop.lg` — codegen script, now embedded; gains a target-package parameter.
- Modify: `cmd/lginterop/main.go` — drop `findRepoRoot`/`ensureLgBinary`/shell-out; add embed + in-process eval; add `-out-pkg` flag.
- Modify: `test/e2e/lginterop_regen_test.go` — retarget tracked input paths; add out-of-tree case.
- Create: `pkg/cli/cli.go` (+ siblings as the split falls out) — extracted CLI, `cli.Main(version, commit string) int`.
- Modify: `lg.go` — thin wrapper over `pkg/cli`. The root package also holds `lg_repl.go`/`lg_repl_stub.go`, `lg_ansi.go`/`lg_ansi_plan9.go`, `lg_profile.go`/`lg_profile_default.go`, `lg_gogen_ir.go`, and `wasm.go` — these move into `pkg/cli` with their build tags preserved (leave a file at root only if it is genuinely main-only, e.g. if `wasm.go` defines a `main`-shaped entrypoint; decide per file when extracting).
- Create: `test/e2e/custom_main_test.go` — hermetic custom-main e2e.
- Create: `docs/guide/custom-lg.md`; Modify: `docs/guide/go-interop.md` — out-of-tree section, module-context caveat.
- PR 3 — Modify: `pkg/vm/native_func_reflect.go`, `pkg/vm/native_func_reflect_test.go` (or nearest existing test file).

---

### Task 1: Worktree and baseline

**Files:** none (setup)

- [ ] **Step 1: Create the worktree**
  Run: `git -C /Users/andrew/Projects/let-go worktree add /Users/andrew/Projects/let-go-interop main`
  Then: `git -C /Users/andrew/Projects/let-go-interop switch -c interop/p1-out-of-tree-lginterop`

- [ ] **Step 2: Verify green baseline**
  Run in the worktree: `make build && go test ./test/e2e/ -run Lginterop -count=1` (fall back to `make test` if the target names differ — check the Makefile first).
  Expected: PASS. Record the `main` sha in the final commit message of each PR branch for traceability.

### Task 2: Embed the codegen script and run it in-process (PR 1)

**Files:**
- Move: `scripts/lginterop.lg` → `cmd/lginterop/lginterop.lg`
- Modify: `cmd/lginterop/main.go`
- Modify: `test/e2e/lginterop_regen_test.go` (tracked-input paths)

- [ ] **Step 1: Move the script and embed it**
  `git mv scripts/lginterop.lg cmd/lginterop/lginterop.lg`. In `main.go`, add `//go:embed lginterop.lg` into a `var macroLib string`. Grep the repo for other references to `scripts/lginterop.lg` (Makefile, docs, tests) and update them.

- [ ] **Step 2: Replace shell-out with in-process evaluation**
  In `writeGenScript`/`generatePackage`: build the same concatenated script string (embedded macro lib + `(def exports ...)` + `(lginterop/generate ...)`) but evaluate it via `pkg/api` (`api.NewLetGo` then `Run`) instead of `exec.Command(lgBin, ...)`. Delete `findRepoRoot` and `ensureLgBinary` and their call sites. Keep `LGINTEROP_KEEP_SCRIPT` debugging support by optionally dumping the script string to a temp file. Note: the script calls `spit` — if it isn't resolvable through the api boot path, thread the output through a host-provided fn (e.g. `Def` a `spit`-compatible writer) rather than reintroducing the subprocess.

- [ ] **Step 3: Verify regen round-trip is byte-identical**
  Fix `trackInputs` patterns in `test/e2e/lginterop_regen_test.go` for the new script location (the subprocess-cache caveat comment can shrink — the emitter now lives in the test binary's own build inputs).
  Run: `go test ./test/e2e/ -run Lginterop -count=1` and regenerate `pkg/rt/interop_xxh3.go`; `git diff --exit-code pkg/rt/interop_xxh3.go`.
  Expected: PASS, no diff.

- [ ] **Step 4: Commit**
  `git commit -m "refactor(lginterop): embed codegen script, run in-process — no repo root or lg binary needed"`

### Task 3: `-out-pkg` emission mode (PR 1)

**Files:**
- Modify: `cmd/lginterop/main.go` (flag, plumb to script call)
- Modify: `cmd/lginterop/lginterop.lg` (`generate`, `build-file`, `build-init-fn`, header)
- Modify: `test/e2e/lginterop_regen_test.go` (new out-of-tree case)

- [ ] **Step 1: Write the failing test**
  New e2e case: run lginterop with `-packages hash/crc32 -out-pkg interop -out <tmp>/interop`, then scaffold a temp module (`go.mod` requiring let-go with a `replace` to the worktree, a `main.go` blank-importing the generated package plus `pkg/rt`) and assert `go build ./...` succeeds in it. Assert the generated file contains `package interop`, `rt.RegisterNS`, and a direct `install...NS()` call inside `init()` — and does **not** contain `RegisterInstaller`.

- [ ] **Step 2: Run test to verify it fails**
  Run: `go test ./test/e2e/ -run OutOfTree -count=1`
  Expected: FAIL (flag doesn't exist yet).

- [ ] **Step 3: Implement**
  `main.go`: add `-out-pkg` (empty default = legacy in-tree output; any non-empty value = out-of-tree mode; reject an explicit `-out-pkg rt` with an error to keep the modes unambiguous), pass it as a new final arg to `(lginterop/generate ...)`. `lginterop.lg`: `generate` and `build-file` take the target package (empty → exactly today's output); when out-of-tree: `gogen/file <out-pkg>`, add `github.com/nooga/let-go/pkg/rt` import, `build-install-fn` emits `rt.RegisterNS`, `build-init-fn` emits the direct install call. Record `-out-pkg` in the generated-by header. On importer failure, error with a hint that the scanned package must be resolvable from the current module (`go get <pkg>` first).

- [ ] **Step 4: Run tests to verify pass**
  Run: `go test ./test/e2e/ -run 'Lginterop|OutOfTree' -count=1`
  Expected: PASS (legacy goldens untouched).

- [ ] **Step 5: Update docs and commit**
  Add an "Out-of-tree generation" section to `docs/guide/go-interop.md` (flag, init-timing rationale, module-context caveat). Follow the repo's docs frontmatter conventions (`scripts/docs_frontmatter_hook.py` enforces them).
  `git commit -m "feat(lginterop): -out-pkg emits self-contained third-party interop packages"`

### Task 4: Open PR 1

- [ ] **Step 1: Push and open PR**
  Push `interop/p1-out-of-tree-lginterop`; open a PR against `main` with `gh pr create` summarizing Tasks 2–3. If push/auth fails in this environment, stop and ask the user to run the push (`! git push ...`).

### Task 5: Extract `pkg/cli` (PR 2)

**Files:**
- Create: `pkg/cli/cli.go` (split further only if a natural seam appears)
- Modify: `lg.go`

- [ ] **Step 1: Branch**
  From `main`: `git switch -c interop/p2-pkg-cli && git merge interop/p1-out-of-tree-lginterop` (p1 is needed for the e2e in Task 6).

- [ ] **Step 2: Mechanical extraction**
  Move everything except `main()` and the `version`/`commit` ldflags vars from `lg.go` into `pkg/cli`, exporting `func Main(version, commit string) int` (wrap current `runMain`). Keep flag registration behavior: flags currently register in `init()` — preserve semantics for a custom main by registering them inside `Main` (or a `sync.Once`) rather than package init, so importing `pkg/cli` has no side effects until called. Root `lg.go` shrinks to `main() { os.Exit(cli.Main(version, commit)) }` plus the vars. No logic changes.

- [ ] **Step 3: Verify pure refactor**
  Run: `make test` (or the repo's full suite target).
  Expected: PASS. Also smoke the promoted binary (`make build` produces `build/lg` and promotes `bin/lg` after its smoke gate — use `bin/lg`, never a stale root `./lg`): `bin/lg -v` and a quick eval matching pre-refactor output.

- [ ] **Step 4: Commit**
  `git commit -m "refactor: extract lg CLI into importable pkg/cli"`

### Task 6: Hermetic custom-main e2e (PR 2)

**Files:**
- Create: `test/e2e/custom_main_test.go`
- Create: `docs/guide/custom-lg.md`

- [ ] **Step 1: Write the failing test**
  In a temp dir: generate interop for `hash/crc32` with `-out-pkg interop`; write a module with `replace github.com/nooga/let-go => <worktree>` and the ~10-line custom `main.go` from the Design section (importing `pkg/cli` + the generated package); `go build -o customlg`. Then: (a) run a `.lg` script that requires the generated namespace and calls a function (e.g. `(crc32/ChecksumIEEE ...)` — verify the exact export name from the generated file), asserting correct output; (b) `./customlg -b out.bin script.lg` with the custom binary as its own bundle base, run `out.bin`, same assertion.

- [ ] **Step 2: Run test to verify it fails**
  Run: `go test ./test/e2e/ -run CustomMain -count=1`
  Expected: FAIL until wiring is right; iterate.

- [ ] **Step 3: Make it pass; write the guide**
  Fix whatever the e2e surfaces (likely candidates: flag double-registration, resolver paths, bundle-base discovery). Then write `docs/guide/custom-lg.md`: the module layout, blank-import pattern for drivers (sqlite example), `-out-pkg` invocation, init-timing note, and the `-bundle-base` distribution story. Frontmatter per repo convention.

- [ ] **Step 4: Run full suite and commit**
  Run: `make test`
  Expected: PASS.
  `git commit -m "feat: custom-main e2e and guide for third-party lg binaries"`

- [ ] **Step 5: Open PR 2**
  Push and `gh pr create` (note in the description it depends on PR 1).

### Task 7: Reflect proxy multi-return (PR 3)

Required for the general wrapper story (see Design), but independent of PRs 1–2 — can be done in parallel at any point.

**Files:**
- Modify: `pkg/vm/native_func_reflect.go`
- Test: nearest existing `pkg/vm` reflect/native test file (create `pkg/vm/native_func_reflect_test.go` if none)

- [ ] **Step 1: Branch** — from `main`: `git switch -c interop/p3-reflect-multireturn main`.
- [ ] **Step 2: Write failing table-driven tests** — `func() (int, string)` → `[1 "a"]`; `func() (int, string, error)` → `[1 "a"]` on nil error, throw on non-nil; existing 0/1/2-shape behavior unchanged.
- [ ] **Step 3: Implement** — generalize the result-marshaling in `boxReflectFunc`: trailing `error` peeled off as throw; remaining 0 → NIL, 1 → boxed value, n → `ArrayVector` of boxed values.
- [ ] **Step 4: Run** — `go test ./pkg/vm/ -count=1`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(vm): reflect proxy boxes multi-return funcs as vectors"`
- [ ] **Step 6: Open PR 3** — push and `gh pr create` (no dependencies on the other PRs).

### Task 8: Integration branch for lgx verification

**Files:** none (git only)

- [ ] **Step 1: Create and merge**
  From `main`: `git switch -c integration/go-interop && git merge interop/p1-out-of-tree-lginterop interop/p2-pkg-cli interop/p3-reflect-multireturn`. Resolve conflicts if any; `make test` must pass on the result.

- [ ] **Step 2: Build and smoke against lgx**
  `make build` in the worktree, then from `/Users/andrew/Projects/lgx`: `LGX_LG=/Users/andrew/Projects/let-go-interop/bin/lg lgx test` (`bin/lg` is the smoke-gated promoted binary; see `docs/knowledge-base/lgx-dev-workflow.md` for cache caveats).
  Expected: lgx's suite passes — no regression from the refactors.

- [ ] **Step 3: Note the branch**
  This branch is local convenience only — never PR'd. Rebuild it by re-merging when PR branches move.
