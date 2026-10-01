# `:target :wasm` build output Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `lgx build` produce a browser WASM web directory via `lg -w` when `:targets :bin` sets `:target :wasm`, for projects without Go deps. Record the Go-deps and resources gaps in the backlog and draft the two upstream let-go asks.

**Tech Stack:** let-go (`.lg`), `lg -w`, the Go toolchain (`lg -w` shells out to `go build` for `js/wasm`), lgx's schema validator (`lgx/spec.lg`), the lgx unit suite (`bin/lgx test`) and `tests/e2e.sh`.

**Origin:** GitHub issue #61 (Norman Nunley). This plan is the thin first phase, modelled on the `:lgb` target (`docs/plans/2026-09-30-2116-lgb-build-target.md`, PR #62). Project Go deps and runtime resources in the WASM artifact need let-go changes and are out of scope.

---

## Design

### What changes for users

`:targets :bin :target` accepts a second value, `:wasm`, with an optional `:wasm` options map:

```clojure
{:main "main.lg"
 :targets {:bin {:target :wasm
                 :out "dist/web"
                 :wasm {:shell :none          ; :xterm (lg's default), :none, or "path/to/shell.html"
                        :payload :external    ; :inline (lg's default) or :external
                        :host-eval true}}}}   ; default false
```

`lgx build` then runs `lg [wasm flags] [forwarded args] -w <abs :out> <abs :main>`. `:out` is a directory. `lg` writes `index.html` and `coi-serviceworker.js` into it, plus `main.wasm` under `:payload :external`. Serve the directory over HTTP to run the app.

Without `:target`, and with `:target :lgb`, nothing changes. Their argv and messages stay byte-identical.

### Verified facts this design rests on

Checked on 2026-10-01 with lg 1.13.0 (the repo pin) and let-go main `4e769212`:

- `lg -source-paths src -w web main.lg` builds in about 23 s and writes `web/index.html` (8.3 MB) and `web/coi-serviceworker.js`. It prints `output: web/index.html (…)`.
- `lg -w` runs top-level forms on the host with `*compiling-aot*` true, as `-b` and `-c` do.
- `lg -w` needs `go` on PATH. It builds a throwaway Go module (`pkg/cli/wasm.go`, `buildWasm`) whose `go.mod` requires only let-go and whose `main.go` imports only let-go runtime packages. It embeds `program.lgb` and no resource archive. So project Go deps and resources cannot reach the artifact.
- lg 1.13.0 has `-w-shell`, `-w-wasm` and `-w-host-eval`.
- A context cannot override `:targets`: `context-schema` (`lgx/config.lg`) is a closed map of `:extra-deps`, `:extra-paths` and `:extra-resource-paths`. So a project declares one artifact kind per `lgx.edn`.
- Today `lgx build --target js/wasm` under `:lg-runtime :built` exits 0 and writes a bare WebAssembly module with the bytecode appended (`file` reports "WebAssembly (wasm) binary module"). There is no HTML, no `wasm_exec.js`, and no launcher.

Not verified: no browser run was performed. That the page boots is checked by hand in Task 7.

### Decisions

1. **`:target` accepts `:lgb` or `:wasm`.** The value error becomes `must be :lgb or :wasm (omit :target for a standalone executable), got …`.
2. **Packaging options live in a nested `:wasm` map**, not flat under `:bin`. It keeps the `:bin` key space small and makes "this option is irrelevant here" one rule: `:wasm` without `:target :wasm` is a config error. The keys map one-to-one to `lg` flags:

   | Key | Values | lg flag |
   |---|---|---|
   | `:shell` | `:xterm`, `:none`, or a project-relative path to an HTML template | `-w-shell xterm` / `none` / `<abs path>` |
   | `:payload` | `:inline`, `:external` | `-w-wasm inline` / `external` |
   | `:host-eval` | boolean | `-w-host-eval` when true |

   An absent key emits no flag, so `lg`'s defaults apply. The config flags go before the forwarded args, so `lgx build -w-shell none` on the command line overrides the config (Go's `flag` keeps the last value).
3. **Options that do not apply to `:wasm` are rejected when lgx.edn loads:** `:platforms`, and `{{os}}`/`{{arch}}` in `:out`. A browser app is built for `js/wasm` only.
4. **CLI flags that do not apply are rejected before any work:** `--target`, `--all`, and a forwarded `-bundle-base`.
5. **Go deps are a hard error.** Any `:go/*` coord in the resolved basis, direct or transitive, stdlib or external, fails the build before a runtime is built. The host could compile the program, but the WASM module would not link the Go packages, and the app would fail in the browser. The check runs before `apply-runtime!`, so `:installed` projects hear the WASM reason and not "add `:lg-runtime :built`".
6. **`go` on PATH is checked up front.** Under `:installed` lgx normally never needs Go, but `lg -w` does. lgx checks `gobuild/go-available?` and fails with its own message. Under `:built`, `apply-runtime!` already preflights.
7. **Runtime rules are otherwise those of `:lgb`.** `apply-runtime! … :fail` runs, so the `:lg-version` check and the `:built` runtime apply unchanged. Under `:built` with no Go coords the host is a stock module built from the pin, and `lg -w` reproduces that build's let-go source in the WASM module.
8. **Resources warn and do not fail.** `-resource-paths` is still passed, so compile-time reads work. With a non-empty resource path list, the build prints one warning that the browser app will not find them.
9. **lgx does not clean `:out`.** `lg -w` overwrites its own files and leaves others. Switching from `:external` to `:inline` leaves a stale `main.wasm`. The README says so. Deleting a user directory is not worth the risk.
10. **`js/wasm` is rejected as an executable platform, with a pointer to `:target :wasm`.** The artifact it produces today is not runnable and the success message is misleading. The check is one pure rule in `gobuild/resolve-build-targets`, so it covers `--target js/wasm` and `--all` with `js/wasm` in `:platforms`. `wasip1/wasm` is left alone: WASI is a separate contract and was not examined.
11. **Deferred, recorded in the backlog (Task 1):** project Go deps and interop bindings in the WASM module, embedded resources, application lowering for WASM, and cache keys for the WASM output. The two upstream asks are drafted in `docs/issues/` and not filed; filing is the maintainer's call.

### Shared shapes

Tests and implementation must agree on these exact strings. Config errors use `{:path [...] :msg "..."}` relative to the config root.

**Config (`lgx/config.lg`)**

| Where | Path | Message |
|---|---|---|
| bad `:target` value | `[:targets :bin :target]` | `must be :lgb or :wasm (omit :target for a standalone executable), got :native` (value `pr-str`'d) |
| `:wasm` + `:platforms` | `[:targets :bin :platforms]` | `does not apply to :target :wasm - a browser WASM app is built for js/wasm only; remove :platforms` |
| `:wasm` + placeholder in `:out` | `[:targets :bin :out]` | `has an {{os}} or {{arch}} placeholder, but :target :wasm builds one web directory - use a plain path such as "dist/web"` |
| `:wasm` map without `:target :wasm` | `[:targets :bin :wasm]` | `applies only to :target :wasm` |
| bad `:shell` | `[:targets :bin :wasm :shell]` | `must be :xterm, :none, or a relative path to an HTML template, got …` (value `pr-str`'d) |
| bad `:payload` | `[:targets :bin :wasm :payload]` | whatever `[:enum :inline :external]` reports in `lgx/spec.lg`; read it and assert the real text |
| bad `:host-eval` | `[:targets :bin :wasm :host-eval]` | `must be true or false, got …` (value `pr-str`'d) |

The existing `:lgb` messages for `:platforms` and `:out` stay byte-identical. A string `:shell` is validated with the same rule as `rel-path-schema` (relative, inside the project); reuse that helper and report its message when the path is absolute or escapes.

Accessor: `(config/bin-wasm cfg)` returns the `:wasm` map or `{}`. `config/bin-target` now returns `:lgb`, `:wasm` or nil; update its docstring.

**CLI checks (`lgx/gobuild.lg`)**

```clojure
(defn wasm-build-arg-error
  "Pure. Why this `lgx build` invocation cannot build a :target :wasm app,
   or nil when it can."
  [cli-targets all? forward-args] ...)
```

Checked in this order:
- `"--target and --all do not apply to :target :wasm - a browser WASM app is built for js/wasm only"`
- `"-bundle-base does not apply to :target :wasm - it names the base binary of a standalone executable"`

`lgb-build-arg-error` keeps its signature and messages. Sharing a private helper between the two is fine if it keeps both outputs exact.

The `-bundle-base` check must catch every spelling Go's `flag` package accepts: `-bundle-base`, `--bundle-base`, and either with `=<value>` attached. Put that in one private predicate and use it from both arg-error fns; `:lgb` gains the stricter match with its message unchanged.

```clojure
(defn wasm-flag-args
  "Pure. The lg flags for the :wasm options map. `project` absolutizes a
   template path. Absent keys emit nothing."
  [project wasm-opts] ...)
```

Order of the output is `:shell`, `:payload`, `:host-eval`. Examples:
- `{}` → `[]`
- `{:shell :none :payload :external :host-eval true}` → `["-w-shell" "none" "-w-wasm" "external" "-w-host-eval"]`
- `{:shell "web/shell.html"}` with project `/p` → `["-w-shell" "/p/web/shell.html"]`
- `{:host-eval false}` → `[]`

```clojure
(defn wasm-go-deps-error
  "Pure. The error for Go coords in a :target :wasm build."
  [go-pairs go-origins] ...)
```

Output, with labels rendered exactly as `installed-go-deps-error` renders them (extract the label rendering into a shared private fn):

```
error: :target :wasm cannot link Go deps - `lg -w` builds a Go module that carries only let-go
  Go deps: <lib> (via <origin>), <lib>
  drop the dep, or build an executable instead (tracked in lgx issue #61).
```

Go missing, as a def or pure fn `wasm-go-missing-error`:

```
error: :target :wasm needs the Go toolchain (`lg -w` compiles the app for js/wasm), but `go` is not on PATH.
  install it with `mise use -g go@latest`, or from https://go.dev/dl
```

`resolve-build-targets`, when any resolved target is `{:os "js" :arch "wasm"}`, returns:

`{:error "js/wasm is not an executable platform - set :target :wasm under :targets :bin to build a browser app"}`

**`lgx.lg`**

- Missing template, before the basis resolves: `lgx: :wasm :shell template not found: <rel path>` and exit 1.
- Resource warning on stderr: `warning: :resource-paths are not embedded in a browser WASM app - io/resource will not find them in the browser`
- Header: `Building <out>...`. Success line: `built <abs-out>`.

### Build flow for `:wasm`

`cmd-build` dispatches on `(config/bin-target cfg)` right after the config loads, as it does for `:lgb`, into a new `build-wasm!` that always exits:

1. Require `:main` (shared `build-main-required`) and `resolve-main-script!`.
2. `gobuild/wasm-build-arg-error`. On a message: print with the `lgx: ` prefix, exit 1.
3. When `:shell` is a string, check the file exists under the project. If not, print the template message, exit 1.
4. `overlay-basis`, then `print-installs!`.
5. When `(:go-coords basis)` is non-empty: print `gobuild/wasm-go-deps-error`, exit 1.
6. When `go` is not available: print the Go-missing message, exit 1.
7. `apply-runtime! cfg basis :fail verbose?`.
8. Warn when `resource-paths` is non-empty.
9. `ensure-out-dir!` (creates the parent; `lg` creates the directory itself). Print the header. Invoke `runner/invoke-lg!` with `(vec (concat (gobuild/wasm-flag-args project wasm-opts) forward ["-w" abs-out abs-main]))`.
10. Exit 0 with `built <abs-out>`, or exit with lg's code.

`build-lgb!` and `build-wasm!` share steps 1 and 9-10 in shape. Extract a helper only if it keeps the `:lgb` path's behaviour and output identical; duplication of a dozen lines is acceptable.

### Testing

- **Unit, `test/lgx/config_test.lg`:** `:target :wasm` accepted, with and without each `:wasm` key; every row of the config table above; `:wasm` map rejected under `:target :lgb` and under no `:target`; `bin-wasm` and `bin-target` accessors; the two existing tests that assert the old `must be :lgb (…)` and `allowed: :out, :platforms, :target` messages are updated.
- **Unit, `test/lgx/gobuild_test.lg`:** every branch of `wasm-build-arg-error`, `wasm-flag-args` and `wasm-go-deps-error`; `resolve-build-targets` rejects `js/wasm` from `--target` and from `--all`, and still accepts `wasip1/wasm` and `linux/amd64`; the existing `lgb-build-arg-error` tests pass untouched.
- **E2E, `tests/e2e.sh`:** one real build (about 25 s, needs `go`; skip with a message when `go` is missing) and five fast failure scenarios. Details in Task 5.
- **By hand:** serve the output and load it in a browser (Task 7).

## File Structure

| File | Change |
|---|---|
| `docs/backlog/wasm-go-deps-and-resources.md` | Create: what `:target :wasm` cannot carry yet and why. |
| `docs/issues/letgo-wasm-extra-go-imports.md` | Create: upstream ask draft, extra Go requires/imports for `lg -w`. |
| `docs/issues/letgo-wasm-embed-resources.md` | Create: upstream ask draft, resource embedding in the WASM build. |
| `docs/issues/README.md` | Two rows in the upstream table. |
| `lgx/config.lg` | `:wasm` value and options map in `targets-schema`, cross-key rules, `bin-wasm` accessor. |
| `lgx/gobuild.lg` | `wasm-build-arg-error`, `wasm-flag-args`, `wasm-go-deps-error`, Go-missing message, `js/wasm` rejection in `resolve-build-targets`. |
| `lgx.lg` | `build-wasm!`, dispatch in `cmd-build`, help row. |
| `test/lgx/config_test.lg`, `test/lgx/gobuild_test.lg` | Unit tests. |
| `tests/e2e.sh` | `:wasm` scenarios. |
| `README.md`, `docs/ARCHITECTURE.md`, `docs/knowledge-base/let-go-bundling.md` | Docs. |

---

### Task 1: Backlog entry and upstream drafts

**Files:**
- Create: `docs/backlog/wasm-go-deps-and-resources.md`
- Create: `docs/issues/letgo-wasm-extra-go-imports.md`, `docs/issues/letgo-wasm-embed-resources.md`
- Modify: `docs/issues/README.md`

- [ ] **Step 1: Write the backlog entry.** Follow `docs/backlog/native-build-target.md` for shape (`# title`, `**Status: open**`, `## Problem`, further sections). Title: "`:target :wasm` cannot carry project Go deps or resources". Content, from "Verified facts" and Decision 11:
  - The request (lgx #61) and the thin phase this plan ships.
  - Go deps: `buildWasm` (let-go `pkg/cli/wasm.go`) writes a temp module that requires only let-go and a `main.go` that imports only runtime packages; lgx's generated module and lginterop bindings have no way in. Note that few Go deps compile for `js/wasm` anyway (anything with cgo is out), so the need may be narrow.
  - Resources: the WASM builder embeds `program.lgb` only.
  - Also deferred: application lowering for WASM (ties to `native-build-target.md`), cache keys for the WASM output, a browser smoke test in CI, and a `wasip1` target.
  - One artifact kind per `lgx.edn`, because a context cannot override `:targets`.
  - Links to the two drafts in `docs/issues/`.

- [ ] **Step 2: Commit the backlog entry on its own.**
  `git add docs/backlog/wasm-go-deps-and-resources.md && git commit -m "Backlog: Go deps and resources in :target :wasm"`

- [ ] **Step 3: Write the two upstream drafts.** Read two existing files in `docs/issues/` first and match their shape. Each states the observed behaviour with the source location, why lgx needs the change, and a proposed interface held loosely:
  - **Extra Go imports:** let `lg -w` accept additional module requires/replaces and blank imports, or an existing module directory to build in, so a host can link registered Go packages into the WASM artifact. Mention that the same question was put to let-go PR #977 (`lg compile`) in lgx #60, so one mechanism could serve both.
  - **Resources:** have `lg -w` collect `-resource-paths` into the artifact and install a resource provider in the generated main, as `-b` does for executables.

  Mark both `draft` and add a row for each to the upstream table in `docs/issues/README.md`. Do not file them on GitHub.

- [ ] **Step 4: Commit.**
  `git add docs/issues && git commit -m "Issues: draft let-go asks for WASM Go imports and resources"`

### Task 2: `:wasm` in the config schema

**Files:**
- Modify: `lgx/config.lg` (`bin-target-value-errors`, `bin-target-errors`, `targets-schema` around lines 785-826; `bin-target` around line 1424)
- Test: `test/lgx/config_test.lg` (the `:targets :bin :target` section around line 510)

- [ ] **Step 1: Write the failing tests** next to the `:lgb` ones, using `load-cfg`:
  - accepts `{:targets {:bin {:target :wasm :out "dist/web"}}}`;
  - accepts a full `:wasm` map, and one with `:shell "web/shell.html"`;
  - each row of the config table in "Shared shapes", including `:wasm {}` under `:target :lgb` and under no `:target`;
  - `:shell` rejections: `:fancy`, `42`, an absolute path, a `../` path;
  - an unknown key inside `:wasm` reports the closed-map message with the allowed keys (check the order the validator lists);
  - `bin-wasm` returns the map, and `{}` when absent; `bin-target` returns `:wasm`.

  Update `load-rejects-an-unsupported-target` to the new value message, and `load-rejects-unknown-bin-key` to include `:wasm` in the allowed list.

- [ ] **Step 2: Run to verify they fail.**
  Run: `bin/lgx test test/lgx/config_test.lg`
  Expected: FAIL on the new and updated tests.

- [ ] **Step 3: Implement.**
  - `bin-target-value-errors` accepts `:lgb` and `:wasm`; update its docstring.
  - Add the `:wasm` optional key to the `:bin` map: a closed map with `:shell` (`[:fn …]`), `:payload` (`[:enum :inline :external]`), `:host-eval` (`[:fn …]`, since `lgx/spec.lg` has no boolean form).
  - Extend `bin-target-errors` to cover `:wasm` with its own phrases, keeping the `:lgb` strings exact. Add the `:wasm`-map-without-`:target :wasm` rule there. Order: `:platforms`, then `:out` placeholder, then the stray `:wasm` map.
  - Add `bin-wasm` beside `bin-target`.

- [ ] **Step 4: Run to verify they pass.**
  Run: `bin/lgx test test/lgx/config_test.lg`
  Expected: PASS, whole file.

- [ ] **Step 5: Commit.**
  `git commit -am "config: :target :wasm and its :wasm options under :targets :bin"`

### Task 3: Pure build helpers

**Files:**
- Modify: `lgx/gobuild.lg` (after `lgb-build-arg-error`, around line 850; `installed-go-deps-error` around line 885)
- Test: `test/lgx/gobuild_test.lg`

- [ ] **Step 1: Write the failing tests** for `wasm-build-arg-error`, `wasm-flag-args` and `wasm-go-deps-error`, covering the examples and messages in "Shared shapes". For the arg error, cover `--bundle-base` and `-bundle-base=/x/lg`, and add the same two cases to the `lgb-build-arg-error` tests. For the deps error, include one coord with an origin and one without, and assert the sort order matches `installed-go-deps-error`.

- [ ] **Step 2: Run to verify they fail.**
  Run: `bin/lgx test test/lgx/gobuild_test.lg`
  Expected: FAIL, unresolved symbols.

- [ ] **Step 3: Implement** the three fns and the Go-missing message. Extract the coord-label rendering from `installed-go-deps-error` into a private fn and use it in both; the existing `installed-go-deps-error` tests must pass unchanged.

- [ ] **Step 4: Run to verify they pass.**
  Run: `bin/lgx test test/lgx/gobuild_test.lg`
  Expected: PASS.

- [ ] **Step 5: Commit.**
  `git commit -am "gobuild: arg checks, flags and Go-deps error for :wasm builds"`

### Task 4: Reject `js/wasm` as an executable platform

**Files:**
- Modify: `lgx/gobuild.lg` (`resolve-build-targets`, around line 815)
- Test: `test/lgx/gobuild_test.lg`

- [ ] **Step 1: Write the failing tests.** `resolve-build-targets` returns the `js/wasm` error from "Shared shapes" for `[{:os "js" :arch "wasm"}] false []`, for a CLI list that mixes it with `linux/amd64`, and for `[] true [{:os "js" :arch "wasm"}]`. It still returns targets for `wasip1/wasm`.

- [ ] **Step 2: Run to verify they fail.**
  Run: `bin/lgx test test/lgx/gobuild_test.lg`
  Expected: FAIL on the new tests.

- [ ] **Step 3: Implement** the check on the resolved list, after the existing branches pick it. Update the docstring.

- [ ] **Step 4: Run the whole unit suite.** An existing test may use `js/wasm` as an example platform; if so, switch it to another pair.
  Run: `bin/lgx test`
  Expected: PASS.

- [ ] **Step 5: Commit.**
  `git commit -am "gobuild: js/wasm is not an executable platform"`

### Task 5: The `:wasm` build path

**Files:**
- Modify: `lgx.lg` (`build-lgb!` and `cmd-build` around lines 798-850; help rows around line 38)
- Test: `tests/e2e.sh` (append at the end)

- [ ] **Step 1: Find the next scenario number.**
  Run: `grep -o 'Scenario [0-9]*' tests/e2e.sh | sort -k2 -n | tail -1`
  Expected: `Scenario 165`, so the new ones start at 166. The script runs under `set -eu`: wrap every expected-failure capture in `set +e` / `set -e`, as Scenario 164 does.

- [ ] **Step 2: Write the failing e2e scenarios**, modelled on Scenarios 163-165.
  - **166, happy path (real build).** Skip with `skip "wasm build requires go on PATH"` when `command -v go` fails. Project: `:paths ["src"]`, a `main.lg` requiring a second namespace, `:resource-paths ["resources"]` with one file, and `:targets {:bin {:target :wasm :out "dist/web" :wasm {:shell :none :payload :external}}}`. Assert: exit 0; `dist/web/index.html`, `dist/web/coi-serviceworker.js` and `dist/web/main.wasm` exist; output contains `built $proj/dist/web`; output contains the resource warning. `main.wasm` existing proves the `:payload` flag reached `lg`.
  - **167, platform flags rejected.** `lgx build --target linux/amd64` on a `:wasm` project exits non-zero with `--target and --all do not apply to :target :wasm`, and `dist/` does not exist.
  - **168, Go deps rejected.** A `:wasm` project with one `:go/*` dep (copy a small coord from an existing scenario, such as the Go stdlib interop ones near Scenario 160) exits non-zero with `:target :wasm cannot link Go deps`, names the coord, writes no `dist/`, and creates no runtime under `$LGX_HOME/runtimes`.
  - **169, missing shell template.** `:wasm {:shell "web/shell.html"}` without the file exits non-zero with `:wasm :shell template not found: web/shell.html`.
  - **171, Go missing.** A `:wasm` project with no Go deps under the default `:installed` runtime, run with `LGX_LG` set to the absolute lg path and `PATH` pointing at an empty directory (the pattern of the no-git scenario near line 302). It exits non-zero with `:target :wasm needs the Go toolchain` and writes no `dist/`. If lgx needs another PATH tool before this check, add only that tool to the directory.
  - **170, `js/wasm` executable target.** On a plain executable project, `lgx build --target js/wasm` exits non-zero with `js/wasm is not an executable platform` and writes nothing.

- [ ] **Step 3: Run to verify they fail.**
  Run: `bash tests/run.sh`
  Expected: FAIL at Scenario 166. Before the implementation `cmd-build` takes the executable path for `:target :wasm` and writes a file at `dist/web`, so the directory assertions fail.

- [ ] **Step 4: Implement** `build-wasm!` following "Build flow for `:wasm`", and dispatch to it from `cmd-build` beside the `:lgb` dispatch. The executable and `:lgb` paths must behave exactly as before. Update the `lgx build` help row to mention `:target :wasm` (`lg -w`), keeping the two-line row format.

- [ ] **Step 5: Run to verify they pass.**
  Run: `bash tests/run.sh`
  Expected: `All tests passed.`, with Scenarios 25-30, 81 and 163-165 unchanged.

- [ ] **Step 6: Commit.**
  `git commit -am "build: :target :wasm writes a browser app via lg -w"`

### Task 6: Docs

**Files:**
- Modify: `README.md` (command table row, "`lgx build` details", annotated lgx.edn)
- Modify: `docs/ARCHITECTURE.md` (the `lgx build` section, after the `:target :lgb` paragraph)
- Modify: `docs/knowledge-base/let-go-bundling.md`

- [ ] **Step 1: README.**
  - The command table row mentions `:target :wasm`.
  - A subsection "Browser WASM output (`:target :wasm`)" after the `:lgb` one: the config example with the `:wasm` map and its three keys; what lands in `:out`; that the directory must be served over HTTP (one example command, `python3 -m http.server -d dist/web`); Go must be on PATH; no `:platforms` / `--target` / `--all` / `-bundle-base`; forwarded `lg` flags override the config; Go deps are an error and resources are not embedded (link #61); `:out` is not cleaned; one artifact kind per `lgx.edn`.
  - The `:lgb` subsection's last bullet, "`:lgb` is the only value for now", becomes accurate.
  - The annotated lgx.edn comment lists `:wasm` beside `:lgb`.
  - The cross-compilation rules mention that `js/wasm` is rejected and points at `:target :wasm`.

- [ ] **Step 2: ARCHITECTURE.** Add a `:target :wasm` paragraph mirroring the `:lgb` one: the dispatch to `build-wasm!`, the order of checks (args, template, Go coords, Go toolchain, runtime), the argv, the resource warning, and the config-load rules. Note the `js/wasm` rule in `resolve-build-targets`.

- [ ] **Step 3: let-go-bundling knowledge base.** Add a short "`-w` builds a browser app" section: the temp module that requires only let-go, the embedded `program.lgb` with no resource archive, the three `-w-*` flags, `*compiling-aot*` true during the build (all verified on lg 1.13.0 and let-go main `4e769212`). Add `pkg/cli/wasm.go` (`buildWasm`) and `pkg/rt/wasm/` to the "Verify against" footer.

- [ ] **Step 4: Check the docs against the code.** Re-read each changed paragraph against `lgx.lg`, `lgx/config.lg` and `lgx/gobuild.lg`. Every flag, key, message and path named must match.

- [ ] **Step 5: Commit.**
  `git commit -am "docs: :target :wasm build output"`

### Task 7: Final verification

- [ ] **Step 1: Full suite.**
  Run: `bash tests/run.sh`
  Expected: `All tests passed.`

- [ ] **Step 2: Lint and format**, if the tools are installed.
  Run: `make lint` and `make fmt-check`
  Expected: no new findings in touched files.

- [ ] **Step 3: Check the argv by hand** in a scratch `:wasm` project:
  - `bin/lgx --verbose build` shows the `-w-*` flags, then `-w <abs out> <abs main>`, and no `-b`, `-c` or `-bundle-base`;
  - `bin/lgx --verbose build -w-shell none` shows the forwarded flag after the config flags;
  - an executable project and an `:lgb` project show the same argv as before.

- [ ] **Step 4: Smoke-build under `:built`.** In the scratch project add `:lg-runtime :built :lg-version "1.13.0"` (no Go deps) and run `bin/lgx build`. Expected: exit 0 and `dist/web/index.html` written. This checks Decision 7, which rests on reading `wasmLetgoSource` and was not run during planning. If it fails, stop and report; do not work around it.

- [ ] **Step 5: Load the app in a browser.** Build the scratch project with the default shell, serve it (`python3 -m http.server -d dist/web 8765`), open `http://localhost:8765`, and confirm the program's output appears in the terminal shell. Use the preview tools if the session has them. If no browser is available, say so in the completion summary; do not claim the app was run.

- [ ] **Step 6: Reply on issue #61 only if the maintainer asks.** The plan does not post to GitHub.
