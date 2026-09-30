# `:target :lgb` build output Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `lgx build` produce a portable `.lgb` bytecode artifact when `:targets :bin` sets `:target :lgb`. Record native compilation (`:target :native`) in the backlog, blocked on upstream let-go work.

**Tech Stack:** let-go (`.lg`), `lg -c`, lgx's schema validator (`lgx/spec.lg`), the lgx unit suite (`bin/lgx test`) and `tests/e2e.sh`.

**Origin:** GitHub issue #60 (Norman Nunley). The phased scope was agreed in the reply at <https://github.com/abogoyavlensky/lgx/issues/60#issuecomment-5919346951>. This plan is phase 1. `:wasm` is issue #61 and is out of scope.

---

## Design

### What changes for users

`:targets :bin` gains an optional `:target` key:

```clojure
{:main "main.lg"
 :targets {:bin {:target :lgb
                 :out "dist/app.lgb"}}}
```

- **Without `:target`**, `lgx build` behaves as it does today and bundles a standalone executable with `lg -b`. Nothing about that path changes, and its argv stays byte-identical.
- **With `:target :lgb`**, `lgx build` runs `lg -c` instead. The output is one platform-independent bytecode file with `:main` and every namespace it loads. `lg dist/app.lgb` runs it from any directory, and `lgx run dist/app.lgb` runs it with the project's runtime. This was verified against let-go main `a141e406`: `lg -c` then `lg app.lgb`, run from an empty directory, executes the program and its required namespaces.

### Decisions

1. **`:lgb` is the only accepted value.** Any other value gets a targeted message instead of a generic enum error, because readers of #60 will try `:native`. The message is in "Shared shapes" below.
2. **Options that do not apply to `:lgb` are rejected when lgx.edn loads:**
   - `:platforms`, because a `.lgb` is platform-independent.
   - `{{os}}` or `{{arch}}` in `:out`. Nothing would expand them, so they would end up as literal file names.
3. **CLI flags that do not apply to `:lgb` are rejected before any work.** `--target` and `--all` select platforms. A forwarded `-bundle-base` names an executable's base binary. Other forwarded args (for example `-z` to compress) pass through to `lg`.
4. **Same runtime rules as the executable build.** `lg -c` runs top-level forms on the host (behind `*compiling-aot*`, exactly like `-b`) and has to resolve the project's Go namespaces. So the `:lgb` path calls `apply-runtime! … :fail` just as the executable path does:
   - Under `:built`, `lg -c` runs on the custom runtime.
   - Under `:installed`, Go deps hit the existing error.

   There is no cross-build branch.
5. **Resources are not embedded.** `lg -c -resource-paths R` does not embed `R` (verified: `io/resource` returns nil when the `.lgb` runs from a clean directory). `-b` does embed them. So when the basis has resource paths, an `:lgb` build prints one warning line and still succeeds.
6. **A `.lgb` that uses Go deps needs a runtime that links them.** The README says so. lgx adds no launcher.
7. **`:native` is deferred.** Experiments on let-go main `a141e406` found two routes, and both are blocked upstream:
   - **Entry frame** (what `lg compile`, let-go PR #977, uses). Compiled library code works, but a compiled `-main` panics on `eval` (nil `clojure.core/eval` Var, let-go #992) and on an inline `fn` (let-go #783).
   - **Custom runtime + `lg -b`.** This fits lgx best, and eval, the REPL and dynamic loading keep working. But in a bundle built on a runtime that links the compiled packages, compiled functions are not installed: the vars hold bytecode fns, so the binary silently runs bytecode. The cause is unknown. `rt.RunExecUnit` does drain `ApplyGoOverrides` after each namespace chunk, the unit's `NSOrder` lists the namespace, and the namespace loads only once. Filed as let-go #991.

   Redefinition semantics (let-go #990) and fallback reporting and strict mode (let-go #660) are open upstream too. Task 1 records all of this as a backlog entry.

### Shared shapes

Tests and implementation must agree on these exact messages. Every error path is relative to the config root, and the validator reports them in `{:path [...] :msg "..."}` form.

| Where | Path | Message |
|---|---|---|
| bad `:target` value | `[:targets :bin :target]` | `must be :lgb (omit :target for a standalone executable), got :native` (the value is `pr-str`'d) |
| `:lgb` + `:platforms` | `[:targets :bin :platforms]` | `does not apply to :target :lgb - a .lgb artifact is platform-independent; remove :platforms` |
| `:lgb` + placeholder in `:out` | `[:targets :bin :out]` | `has an {{os}} or {{arch}} placeholder, but :target :lgb builds one platform-independent artifact - use a plain path such as "dist/app.lgb"` |

The CLI checks come from a pure function in `lgx/gobuild.lg`:

```clojure
(defn lgb-build-arg-error
  "Pure. Why this `lgx build` invocation cannot build a :target :lgb artifact,
   or nil when it can."
  [cli-targets all? forward-args] ...)
```

It returns (checked in this order):
- `"--target and --all do not apply to :target :lgb - a .lgb artifact is platform-independent"` when `cli-targets` is non-empty or `all?` is true.
- `"-bundle-base does not apply to :target :lgb - it names the base binary of a standalone executable"` when `forward-args` contains `"-bundle-base"`.
- nil otherwise.

`cmd-build` prints the returned message with the usual `lgx: ` prefix and exits 1.

The resource warning, on stderr, is: `warning: :resource-paths are not embedded in a .lgb artifact - pass -resource-paths to lg when running it`

The accessor is `(config/bin-target cfg)`, which returns `:lgb` or nil. It sits beside `config/platforms`.

### Build flow for `:lgb`

The code lives in `cmd-build` (`lgx.lg`). The first part of today's flow is shared: parse the args, find the project, load the config, check that `:main` and `:bin` are present, and resolve the main script. The `:lgb` branch then goes:

1. Run `gobuild/lgb-build-arg-error` on the parsed `targets`, `all?` and `forward`. On a message: print it, exit 1.
2. Skip `resolve-build-targets`, the duplicate-out check, the `-bundle-base` count check, and the `:installed` cross check. None of them apply to a single platform-independent artifact.
3. Resolve the basis with `overlay-basis`, run `print-installs!`, and call `apply-runtime! cfg basis :fail verbose?`.
4. Warn (as above) when `resource-paths` is non-empty.
5. Create the parent directory with `ensure-out-dir!` (`:out` used verbatim). Print the header `Building <out>...`. Invoke `runner/invoke-lg!` with `(vec (concat forward ["-c" abs-out abs-main]))`.
6. On exit 0, print `built <abs-out>` and exit 0. Otherwise exit with lg's code.

A small private fn such as `build-lgb!` keeps this out of the executable path. Choose whatever keeps `cmd-build` readable. The executable path must behave exactly as before.

### Testing

- **Unit, `test/lgx/config_test.lg`:**
  - Accepts `:target :lgb`.
  - Rejects `:native` and a string `"lgb"` with the targeted message.
  - Rejects `:lgb` with `:platforms`, and `:lgb` with `{{os}}` or `{{arch}}` in `:out`.
  - Still accepts placeholders without `:target`.
  - `bin-target` returns `:lgb` or nil.
  - The existing `unknown key :foo (allowed: :out, :platforms)` test changes to include `:target` in the allowed list.
- **Unit, `test/lgx/gobuild_test.lg`:** every branch of `lgb-build-arg-error`.
- **E2E, `tests/e2e.sh`:** new scenarios after 159:
  - An `:lgb` build writes the file and prints `built <abs>`. `lg <file>` runs it from a clean directory and prints the expected output.
  - `lgx build --target linux/amd64` on an `:lgb` project exits non-zero with the message and writes nothing.
  - An `:lgb` build with `:resource-paths` prints the warning and still succeeds.
  - The existing build scenarios (25-30, 81) keep passing unchanged. That proves the executable path is untouched.

## File Structure

| File | Change |
|---|---|
| `docs/backlog/native-build-target.md` | Create: the deferred `:native` entry and its upstream blockers. |
| `lgx/config.lg` | `:target` in `targets-schema`, value validator, `:lgb` cross-key checks, `bin-target` accessor. |
| `lgx/gobuild.lg` | `lgb-build-arg-error`, next to `resolve-build-targets`. |
| `lgx.lg` | `:lgb` branch in `cmd-build`; `lgx build` help rows. |
| `test/lgx/config_test.lg` | Schema tests. |
| `test/lgx/gobuild_test.lg` | CLI-check tests. |
| `tests/e2e.sh` | `:lgb` scenarios. |
| `README.md` | `lgx build` row and details, annotated lgx.edn. |
| `docs/ARCHITECTURE.md` | `lgx build` section: the `:lgb` branch. |
| `docs/knowledge-base/let-go-bundling.md` | Note that `lg -c` artifacts do not carry resources. |

---

### Task 1: Backlog the deferred `:native` target

**Files:**
- Create: `docs/backlog/native-build-target.md`

- [ ] **Step 1: Write the entry.** Follow `docs/backlog/built-runtime-not-stripped.md` for shape: a `# title` line, `**Status: open**`, then `## Problem` and whatever sections help. Title: "`lgx build` cannot compile application Lisp to native Go (`:target :native`)". Content, from Decision 7:
  - The request (lgx #60, the `:native` part) and the phase-1 scope that shipped `:lgb` instead.
  - The two routes and exactly what blocks each on let-go main `a141e406`:
    - entry frame: `eval` nil Var panic in a compiled `-main` (#992), and inline `fn` panic (#783);
    - runtime + `lg -b`: compiled functions are not installed in the bundled binary, even though `rt.RunExecUnit` drains `ApplyGoOverrides` per namespace chunk (`pkg/rt/run.go`). The cause is unknown (#991).
  - The related open upstream issues: #660 (report and strict mode), #990 (lowered callers ignore redefinition), and PR #977 (`lg compile` scaffolds a module that requires only let-go, so it cannot carry `:go/*` deps).
  - The preferred route once unblocked: runtime + `lg -b`. It reuses lgx's generated module, and `eval`, the REPL and dynamic loading keep working.
  - An acceptance test: an execution test must prove compiled functions run (the var holds a `<native-fn>`), not just produce correct output.

- [ ] **Step 2: Commit, on its own.**
  `git add docs/backlog/native-build-target.md && git commit -m "Backlog: native build target (:target :native)"`

### Task 2: `:target` in the config schema

**Files:**
- Modify: `lgx/config.lg` (`targets-schema` around line 785, and the helpers above it; the accessor near `platforms`, around line 1386)
- Test: `test/lgx/config_test.lg` (the `:targets` sections, around lines 336-420)

- [ ] **Step 1: Write the failing tests.** Next to the existing `:targets` tests, and using `load-cfg`, add:
  - `load-accepts-target-lgb`, for `{:targets {:bin {:target :lgb :out "dist/app.lgb"}}}`.
  - Rejections of `:target :native` and `:target "lgb"`, each with the exact message from "Shared shapes".
  - Rejection of `:lgb` with a one-entry `:platforms`.
  - Rejection of `:lgb` with `:out "dist/app_{{os}}.lgb"`, and again with `{{arch}}`.
  - `bin-target` returns `:lgb` for the first config and nil for `{:targets {:bin {:out "bin/app"}}}` and for `{}`.

  Update the existing unknown-key test's expected message to `unknown key :foo (allowed: :out, :platforms, :target)`. First check the order the validator actually lists keys in, and match it.

- [ ] **Step 2: Run to verify they fail.**
  Run: `bin/lgx test test/lgx/config_test.lg`
  Expected: FAIL on the new tests (and the updated unknown-key test).

- [ ] **Step 3: Implement.**
  - Add `[:target {:optional true} [:fn bin-target-value-errors]]` to the `:bin` map. The fn returns nil for `:lgb` and the targeted message otherwise.
  - Add a `[:fn bin-target-errors]` to the `:bin` `:and`, **before** `bin-out-collision-errors`, so an `:lgb` config with platforms reports the `:platforms` message rather than a collision. When `(= :lgb (:target bin))`:
    - return `{:path [:platforms] :msg ...}` if `:platforms` is present;
    - otherwise return `{:path [:out] :msg ...}` if `:out` contains `{{os}}` or `{{arch}}`;
    - otherwise nil.
  - Add `bin-target` beside `platforms`, with a docstring matching its neighbours.

- [ ] **Step 4: Run to verify they pass.**
  Run: `bin/lgx test test/lgx/config_test.lg`
  Expected: PASS, whole file.

- [ ] **Step 5: Commit.**
  `git commit -am "config: :target :lgb under :targets :bin"`

### Task 3: CLI check for `:lgb` builds

**Files:**
- Modify: `lgx/gobuild.lg` (after `resolve-build-targets`, around line 832)
- Test: `test/lgx/gobuild_test.lg`

- [ ] **Step 1: Write the failing tests** for `lgb-build-arg-error`:
  - nil for `[] false []` and for `[] false ["-z"]`;
  - the `--target/--all` message for `[{:os "linux" :arch "amd64"}] false []` and for `[] true []`;
  - the `-bundle-base` message for `[] false ["-bundle-base" "/x/lg"]`;
  - the `--target/--all` message when both problems are present (it is checked first).

- [ ] **Step 2: Run to verify they fail.**
  Run: `bin/lgx test test/lgx/gobuild_test.lg`
  Expected: FAIL, unresolved `lgb-build-arg-error`.

- [ ] **Step 3: Implement** `lgb-build-arg-error`: pure, with the signature and messages from "Shared shapes".

- [ ] **Step 4: Run to verify they pass.**
  Run: `bin/lgx test test/lgx/gobuild_test.lg`
  Expected: PASS.

- [ ] **Step 5: Commit.**
  `git commit -am "gobuild: reject platform and base flags for :lgb builds"`

### Task 4: The `:lgb` build path

**Files:**
- Modify: `lgx.lg` (`cmd-build` around line 798; help rows around line 38)
- Test: `tests/e2e.sh` (append after Scenario 159)

- [ ] **Step 1: Write the failing e2e scenarios.** Model them on Scenario 25 (build happy path) and 81 (resources), with the same `mktemp` / `LGX_HOME` / cleanup pattern. Number them 160 onward.
  - **160, `:lgb` happy path.**
    - lgx.edn: `{:main "main.lg" :targets {:bin {:target :lgb :out "dist/app.lgb"}}}`.
    - `main.lg`: a namespace that requires a second project namespace under `:paths ["src"]`, and prints a value from it inside `(when-not *compiling-aot* …)`.
    - Assert that `dist/app.lgb` exists and the output contains `built $proj/dist/app.lgb`.
    - Copy the file to a fresh temp dir and run `"$LGX_LG" app.lgb` there. Assert the expected output, which proves the required namespace is inside the artifact.
    - Run `lgx run dist/app.lgb` in the project and assert the same output. The README documents this form, and it passes lgx's `-source-paths`/`-resource-paths` flags ahead of the `.lgb`.
  - **161, flags rejected.** On the same kind of project, `lgx build --target linux/amd64` exits non-zero, contains `--target and --all do not apply to :target :lgb`, and `dist/` does not exist.
  - **162, resources warn.** Guard it with `supports_resource_paths`, as Scenario 81 does. With `:resource-paths ["resources"]` and `:target :lgb`, the build succeeds and its output contains `warning: :resource-paths are not embedded in a .lgb artifact`.

- [ ] **Step 2: Run to verify they fail.**
  Run: `bash tests/run.sh`
  Expected: FAIL at Scenario 160. Today's `cmd-build` passes `-b`, so `dist/app.lgb` is an executable and no `.lgb` artifact is written. The first failing assertion should say so.

- [ ] **Step 3: Implement** the flow from "Build flow for `:lgb`":
  - Branch on `(config/bin-target cfg)` after the shared checks (`:main`, `:bin`, `resolve-main-script!`).
  - In the `:lgb` branch, do not call `resolve-build-targets`. Its `--all` error would pre-empt the clearer `:lgb` message.
  - The executable branch stays as it is.
  - Update the help row to say `lgx build` bundles an executable via `lg -b`, or writes a `.lgb` via `lg -c` when `:target :lgb`. Keep the two-line row format.

- [ ] **Step 4: Run to verify they pass.**
  Run: `bash tests/run.sh`
  Expected: `All tests passed.`, with the new scenarios passing and Scenarios 25-30 and 81 unchanged.

- [ ] **Step 5: Commit.**
  `git commit -am "build: :target :lgb writes a .lgb artifact via lg -c"`

### Task 5: Docs

**Files:**
- Modify: `README.md` (command table around line 95, "`lgx build` details" around line 183, annotated lgx.edn around line 283)
- Modify: `docs/ARCHITECTURE.md` (`### lgx build [args...]` around line 309)
- Modify: `docs/knowledge-base/let-go-bundling.md`

- [ ] **Step 1: README.**
  - The command table row mentions `:target :lgb`.
  - "`lgx build` details" gets a short subsection: the config example, what goes into the artifact, how to run it (`lg app.lgb`, or `lgx run dist/app.lgb` for projects with Go deps), no `:platforms` / `--target` / `--all` / `-bundle-base`, and resources not embedded.
  - The annotated lgx.edn shows `:target` as a commented option under `:bin`: *"omit for a standalone executable; :lgb writes a portable bytecode file"*.

- [ ] **Step 2: ARCHITECTURE.** Add the `:lgb` branch to the `lgx build` section: after the shared steps 1-2 it runs `gobuild/lgb-build-arg-error`, skips steps 3-4 and 6, and execs `lg … [forwarded] -c <abs-out> <abs-main>` on the host runtime. Mention the resource warning. Add a row to the runtime table if that reads more clearly than prose.

- [ ] **Step 3: let-go-bundling knowledge base.** Add one line near the `-c` mention: `-c` writes bytecode only, and does not embed `-resource-paths` the way `-b` does (verified on let-go main `a141e406`). Leave the "Verify against" footer as is unless the claim needs another source file.

- [ ] **Step 4: Check the docs against the code.** Re-read each changed paragraph against `lgx.lg`, `lgx/config.lg` and `lgx/gobuild.lg`. Every flag, message and path named must match.

- [ ] **Step 5: Commit.**
  `git commit -am "docs: :target :lgb build output"`

### Task 6: Final verification

- [ ] **Step 1: Full suite.**
  Run: `bash tests/run.sh`
  Expected: `All tests passed.`

- [ ] **Step 2: Lint and format**, if the tools are installed.
  Run: `make lint` and `make fmt-check`
  Expected: no new findings in touched files.

- [ ] **Step 3: Sanity-check by hand** in a scratch project with an `:lgb` target:
  - `bin/lgx build` then `lg dist/app.lgb` works;
  - `bin/lgx --verbose build` shows `-c` and no `-b` or `-bundle-base`;
  - an executable project still shows `-b` exactly as before.
