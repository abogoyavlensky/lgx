# `:target :native` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `lgx build` with `:targets {:bin {:target :native ...}}` lower the application's let-go code, and the let-go code of its dependencies, to Go and link a native executable through let-go's `lg compile -module`.

**Tech Stack:** let-go (`.lg`), `lg compile` with `-module`/`-import` (let-go #1016, #1037; on `main` after v1.13.0, unreleased), the Go toolchain, lgx's runtime builder (`lgx/gobuild.lg`), the lgx unit suite (`bin/lgx test`), `tests/e2e.sh`.

**Origin:** lgx issue #60 and `docs/backlog/native-build-target.md`. The two upstream blockers that entry recorded for the entry-frame route are closed: eval from a lowered `-main` (#992, fixed by #1008) and the nil lambda-lifted var (#783). This plan ships the build path. Strict fallback reporting (#660), the lowered core (#1067), redefinition visibility (#990) and resources stay out of scope.

---

## Design

### What changes for users

```clojure
{:main "main.lg"
 :lg-runtime :built
 :lg-version "d0108ba6"            ; a let-go main that has `lg compile -module`
 :deps {mydep/mydep {:local/root "../mydep"}
        hash/crc32 {:go/interop "crc32"}}
 :targets {:bin {:target :native
                 :out "dist/app_{{os}}_{{arch}}"
                 :platforms [{:os "linux" :arch "amd64"}
                             {:os "darwin" :arch "arm64"}]}}}
```

`lgx build` writes the host executable; `lgx build --all` (or `--target os/arch`) writes one per platform, exactly as for the default executable target. Every `.lg` namespace reachable from `:main` through `ns` `:require`/`:use` (the app's own and its let-go deps') is lowered to Go. Code that does not lower stays on the bytecode VM inside the same binary, so the build still succeeds. Go deps link in the same way they do for a bundled executable.

Constraints the user sees:
- `:target :native` needs `:lg-runtime :built`. The generated Go must compile against exactly the let-go that produced it, so the compiler and the module come from the same pin. A config-load error says so.
- The pinned let-go must have `lg compile -module`/`-import`. A probe of the host runtime fails early with a clear message when it does not (lg 1.13.0 and older).
- `:main` must start with an `ns` form, and that namespace's last segment must not be `main`. Both checks run before anything builds and point at the upstream issue. (See "Verified facts".)
- `:main` must call its entry as `(-main ...)`, optionally inside `(when-not *compiling-aot* ...)` or `do`. `(apply -main *command-line-args*)` runs `-main` twice in the native binary. This goes in the README; lgx does not try to detect it.
- No args are forwarded to `lg` (there is nothing in `lg compile` to forward to). `-bundle-base` and any other forwarded token is an error.
- `:resource-paths` are not embedded; a warning says so, as for `:lgb`.

Unchanged: the default executable (bundle) path, `:lgb`, `:wasm`, and every error they produce.

### Verified facts this design rests on

Checked 2026-10-15 on let-go `main` `d0108ba6`, in scratch projects under `/tmp/lgperf`:

- A Go module shaped like lgx's `:built` runtime (`module lgx.local/runtime`, a `cli.Main` `main.go`, tidied) builds an app with `<runtime lg> compile -module <dir> -o <out> main.lg <ns files...>`, with `LG_SOURCE_PATHS` set to the source roots. lg writes `<dir>/lgprogram/` and builds with `-mod=readonly`. No go.mod/go.sum changes were needed.
- The binary runs from a clean directory without `LG_SOURCE_PATHS`: the required namespaces are embedded as bytecode in `program.lgb`. `(str app-fn)` and `(str dep-fn)` print `<native-fn ...>`. `fib 27` took 5 ms native against 98 ms on bytecode. Command-line args reach `-main`.
- `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 <lg> compile -module ...` cross-builds; `go version -m` shows `GOARCH=arm64`.
- `lg compile` only lowers the files it is given. Namespaces left off the list still run, from bytecode.
- `lg compile` dispatches on `os.Args[1] == "compile"` before flag parsing. So `-source-paths`/`-resource-paths` cannot be prepended (`runner/lg-args` would break it), and search paths come only from `LG_SOURCE_PATHS`.
- Entry handling (let-go `pkg/compiler/compiler.go:342`, `omitTopLevelEntryCall`):
  - `ns` file + `(-main)` or `(when-not *compiling-aot* (-main))`: `-main` runs once.
  - File without an `ns` form + `(-main)`: `-main` runs **twice**.
  - `(apply -main *command-line-args*)`: runs **twice**.
- Any lowered namespace whose last segment is `main` (`main`, `myapp.main`, `task.main`) becomes Go `package main` and fails the build: `import ".../lgprogram/myapp/main" is a program, not an importable package`.
- The `lg -b` route (lowered packages linked into the runtime, then bundled) does install overrides now (#991 closed), but only for fixed-arity functions with all-`vm.Value` params (`override-entries`, let-go `pipeline.lg:1284`). A typed `fib` and a variadic `-main` stayed bytecode there (36 ms). The entry-frame route calls `-main` natively and links lowered callers directly, so it is the one that makes code fast.

### Approach

`build-native!` joins `build-lgb!` and `build-wasm!` as a third arm of the `:target` dispatch in `cmd-build`.

1. **Cheap checks first:** `:main` set and present, no forwarded args, `go` on PATH.
2. **Resolve the basis** (`overlay-basis`) and **read `:main`'s `ns` form.** Reject a missing `ns` and a `main` last segment.
3. **Walk the namespace graph** from `:main` over `(:paths basis)` to get the `.lg` files to lower. This is pure, apart from injected file readers.
4. **Host runtime:** `apply-runtime!` (`:built`, so it builds or reuses the pinned runtime). Probe `<runtime> compile -h` for `-module` and `-import`.
5. **Per target:** `ensure-runtime!` for the target (the host runtime for a host build), stage a copy of its `src/` into a temp dir, then run `env LG_READ_CLJ=1 LG_SOURCE_PATHS=<roots> [GOOS= GOARCH= CGO_ENABLED=0] <host lg> compile -module <stage> -import <pkgs...> -o <out> <main> <files...>`. Relay its output. Delete the stage in a `finally`.

### Key decisions

- **Entry-frame route (`lg compile`), not `lg -b` with a lowered runtime.** Measured above: the bundle route leaves `-main` and every typed or variadic function on bytecode. The cost: the native binary's runtime `require` searches only `LG_SOURCE_PATHS` (not `deps.edn` or `.`). That is fine for a shipped app.
- **Lower the whole reachable `.lg` closure, deps included,** as #60 asks. `.cljc`/`.clj` libs and embedded namespaces are not lowered; they run as bytecode. A dep namespace ending in `main` is skipped (with a note), not fatal. There is no option to lower only the app yet (YAGNI). If upstream lowering produces Go that does not compile, the error suggests dropping `:target :native`.
- **Require `:lg-runtime :built`** at config load. It guarantees the compiler and module share one let-go, and `lg compile` is unreleased anyway. Relaxing this for a future release under `:installed` is a separate change.
- **lgx walks the namespace graph itself.** Neither `lg compile` nor `lg.compiler` follows requires (only the census script does, for one root). The walk reads only each file's first form with `read-string`, so it never evaluates user code. It follows `ns` `:require`/`:use` (libspec vectors, bare symbols, prefix lists).
  - **Resolution mirrors let-go's resolver** (`pkg/resolver/resolver.go:211-222`): roots in order, and within each root the candidates `a/b-c.lg`, `a/b_c.lg`, `a/b-c.cljc`, `a/b_c.cljc`, `a/b-c.clj`, `a/b_c.clj` (hyphen spelling, then underscore spelling, for each extension). The first existing file wins.
  - **Traverse everything, lower only `.lg`.** A resolved `.cljc`/`.clj` namespace is walked for its own requires, so `app.lg -> bridge.cljc -> dep.lg` still lowers `dep.lg`. It is not lowered itself. A file whose first form cannot be read stops the walk there (with a note).
  - Unresolved libs (embedded namespaces, typos) are skipped. A top-level `(require ...)` outside `ns` is not followed; those namespaces run as bytecode, which is correct, just slower.
  - Known limits, documented rather than handled:
    - The resolver tries embedded namespaces before roots, and lgx cannot list them. A project file that shadows one (say `walk.lg`) would be lowered although it never loads.
    - lgx's own reader ignores `LG_READ_CLJ` set at runtime, so reader conditionals in a `.cljc` `ns` form are read with `:lg`/`:default` branches, while the build reads `:clj` first. At worst, a namespace is lowered that is not loaded, or the reverse.
- **Reuse the `:wasm` staging.** Generalize `stage-wasm-module!` into `stage-runtime-module! runtime-bin prefix`, and generalize `wasm-import-args` into `module-import-args` (the same list the runtime's `main.go` blank-imports). A per-build temp copy keeps `lgprogram/` out of the shared cache.
- **Cross-build like the bundle path does:** `ensure-runtime!` per target (bindings generated under the target's `GOOS`/`GOARCH`, `CGO_ENABLED=0`), host `lg` compiling with the target env. That costs one extra cached `go build` per target, which the bundle path already pays.
- **No caching of the app build.** `lg compile` lowers in seconds for small apps, and Go's build cache covers let-go. An app-level cache key would have to cover sources, compiler and options (#60). Defer.
- **No fail-on-fallback.** `lg compile` prints `WARNING: not lowered ...` lines and an `N fns lowered` summary, and lgx relays them. A strict mode needs #660's machine-readable report: backlog it.

### Error and output shapes

Exact strings that tests and code share:

| Where | Message |
|---|---|
| config, `[:targets :bin :target]` | `must be :lgb, :wasm or :native (omit :target for a standalone executable), got <v>` |
| config, `[:lg-runtime]` | `:target :native needs :lg-runtime :built - the Go module that links the lowered code must use the same let-go as the compiler` |
| build, forwarded args | `lgx build with :target :native takes no lg args (got <args>)` |
| build, no `ns` in `:main` | `:target :native needs <main> to start with an ns form - without one, the native binary runs -main twice` |
| build, `main` segment | `:target :native cannot build namespace <ns>: a last segment of main becomes Go package main - rename it` |
| build, probe | `:target :native needs an lg with \`lg compile -module\` and \`-import\` (let-go main after 1.13.0, nooga/let-go#1037) - set :lg-version to a let-go main sha that has it` |
| header | `Building <out> (<os>/<arch>, native)...` |

The upstream issue for the last two rows (Task 9) is referenced from the README and `docs/issues/`, not from the messages, so no code waits on its number.

### Testing

- Unit (`test/lgx/native_test.lg`, new): the walker over an in-memory file map (requires, `:use`, prefix lists, first-root-wins, unresolved libs, cycles, dep `main` skip), `ns`-form checks, the `compile` argv builder (host and cross), and the probe predicate.
- Unit (`test/lgx/config_test.lg`): `:native` accepted under `:built`, rejected under `:installed`. `load-rejects-an-unsupported-target` switches to `:jar`.
- Unit (`test/lgx/gobuild_test.lg`): `module-import-args` keeps `wasm-import-args`'s cases.
- E2E, hermetic: `:installed` rejection, forwarded args, missing `ns`, `main` segment. None of them builds Go.
- E2E, gated on `LGX_NATIVE_E2E=1` with `go` on PATH: a real build of an app with a `:local/root` let-go dep and a `hash/crc32` `:go/interop` coord. It runs the binary from an empty directory and asserts the output and `<native-fn` for one app fn and one dep fn. Correct output alone proves nothing, because a bytecode fallback gives the same output. It also cross-builds one other platform and checks `go version -m` for its `GOARCH`, and checks that no `lgprogram` is left in `$LGX_HOME/runtimes/*/src` and no `lgx-native-*` dirs remain. The pin comes from `LGX_NATIVE_E2E_LG_VERSION`, defaulting to `d0108ba6`.

## File Structure

- Create `lgx/native.lg` (`lgx.native`): the pure parts. `ns-form-libs`, `lib-candidates`, `reachable-lg-files`, `main-ns-error`, `native-compile-argv`, `compile-module-supported?`, and the error strings.
- Create `test/lgx/native_test.lg`.
- Modify `lgx/gobuild.lg`: `stage-runtime-module!` (from `stage-wasm-module!`), `module-import-args` (from `wasm-import-args`), `compile-module-supported!?` (probe).
- Modify `lgx/config.lg`: `bin-target-value-errors` accepts `:native`; a root rule for `:native` + `:installed`.
- Modify `lgx.lg`: `build-native!` and the dispatch arm.
- Modify `test/lgx/config_test.lg`, `test/lgx/gobuild_test.lg`, `tests/e2e.sh`.
- Docs: `README.md`, `docs/ARCHITECTURE.md`, `docs/knowledge-base/lgx-go-runtimes.md`, `docs/backlog/native-build-target.md`, new backlog entries, a new `docs/issues/letgo-compile-entry-handling.md`.

## Tasks

### Task 1: Config accepts `:native` under `:built`

**Files:**
- Modify: `lgx/config.lg` (`bin-target-value-errors` ~785, root rules near `lg-runtime-errors` ~941)
- Test: `test/lgx/config_test.lg`

- [ ] **Step 1: Write failing tests.**
  - `{:main "m.lg" :lg-runtime :built :lg-version "abc123" :targets {:bin {:target :native :out "dist/app"}}}` loads.
  - The same with `:platforms` and `{{os}}`/`{{arch}}` in `:out` loads (`:native` stays out of `single-artifact-phrases`).
  - `:target :native` without `:lg-runtime` (so `:installed`) gives the `[:lg-runtime]` error from the table.
  - Change `load-rejects-an-unsupported-target` to use `:jar`, with the new "must be :lgb, :wasm or :native ..." message.
- [ ] **Step 2: Run** `bin/lgx test test/lgx/config_test.lg`. Expected: the new tests fail.
- [ ] **Step 3: Implement.** Add `:native` to the set and the message. Add a root `[:fn ...]` rule in the style of `lg-runtime-errors`, with the exact message.
- [ ] **Step 4: Run** `bin/lgx test test/lgx/config_test.lg`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "config: accept :target :native under :lg-runtime :built"`

### Task 2: Namespace walker

**Files:**
- Create: `lgx/native.lg`
- Test: `test/lgx/native_test.lg`

Shared shapes:

```clojure
(ns-form-libs form)   ;=> [lib-sym ...] from (ns ...) :require/:use, in order; [] for non-ns
(lib-candidates 'a.b-c) ;=> ["a/b-c.lg" "a/b_c.lg" "a/b-c.cljc" "a/b_c.cljc" "a/b-c.clj" "a/b_c.clj"]
(reachable-lg-files {:roots [abs-dir ...] :main abs-path
                     :read-first-form (fn [path] form-or-nil)
                     :file? (fn [path] bool)})
;=> {:files [abs-path ...]           ; .lg only: main first, then BFS order, deduped
;    :skipped [{:ns sym :path abs-path :reason :main-segment|:unreadable}]}
```

- [ ] **Step 1: Write failing tests** with an in-memory map of path → form:
  - `ns-form-libs`: `[c.d :as d]`, a bare `h.i`, a prefix list `(e f [g :as gg])` → `e.f`, `e.g`, the same prefix list as a vector `[e f [g :as gg]]`, and `(:use j.k)`. A docstring and an attr map in the `ns` form are ignored. `:require-macros` and `:import` are ignored. A non-`ns` form gives `[]`.
  - `reachable-lg-files`:
    - follows app → dep across two roots;
    - the first root wins for a namespace present in both, even when the earlier root has only `.cljc` and the later one `.lg` (the `.cljc` wins and is not lowered);
    - within one root, `a/b-c.lg` beats `a/b_c.lg`, and `.lg` beats `.cljc`;
    - `app.lg → bridge.cljc → dep.lg` lowers `app.lg` and `dep.lg`, not `bridge.cljc`;
    - a file whose `:read-first-form` returns nil lands in `:skipped` as `:unreadable`;
    - an unresolved lib (`clojure.string`) is skipped silently;
    - a cycle terminates;
    - a dep namespace `x.main` is left out of `:files` and appears in `:skipped`, but its own requires are still followed (a `.lg` it requires is lowered);
    - `:main` comes first.
  - The prefix-list rule: a vector or list whose second element is a keyword, or which has no second element, is a libspec. Otherwise the first symbol is a prefix and each later element (symbol, or libspec vector) is joined to it.
- [ ] **Step 2: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: fail (no namespace).
- [ ] **Step 3: Implement** `lgx.native` with these pure fns. `lib-candidates` follows the resolver's order exactly (see Key decisions); `reachable-lg-files` tries roots in order and candidates in order within each root.
- [ ] **Step 4: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "native: walk the .lg namespace graph from :main"`

### Task 3: Entry checks, argv builder, probe predicate

**Files:**
- Modify: `lgx/native.lg`
- Test: `test/lgx/native_test.lg`

```clojure
(main-ns-error main-rel form) ;=> error string or nil
(native-compile-argv {:lg lg-path :module dir :out abs-out :files [main ...]
                      :imports ["-import" pkg ...] :source-paths [dir ...]
                      :target nil-or-{:os :arch}})
;=> ["env" "LG_READ_CLJ=1" "LG_SOURCE_PATHS=<joined with os/path-separator>"
;    ("GOOS=.." "GOARCH=.." "CGO_ENABLED=0" when target)
;    lg "compile" "-module" dir ~@imports "-o" abs-out ~@files]
(compile-module-supported? help-text) ;=> true iff it contains both "-module" and "-import"
```

- [ ] **Step 1: Write failing tests.**
  - `main-ns-error`: nil for `(ns myapp.app ...)`. The no-`ns` message for a non-`ns` or nil form. The `main`-segment message for `(ns main)` and `(ns myapp.main)`. Both messages as in the table.
  - `native-compile-argv`: host and cross cases, and empty imports. All flags come before the files.
  - `compile-module-supported?`: true for a trimmed `lg compile -h` usage text from `d0108ba6` (the `-module <dir>` and `-import <pkg>` lines; the source is let-go `pkg/rt/core/lg/commands/compile.lg`), false for text without them.
  - `native-build-arg-error`: nil for `[]`, the table message for `["-bundle-base" "x"]`.
- [ ] **Step 2: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: fail.
- [ ] **Step 3: Implement.** Reuse `gobuild/target-env-args`' values for the GOOS/GOARCH part if it fits; otherwise inline them. Keep `env` as the first element so `os/sh` takes the whole vector.
- [ ] **Step 4: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "native: entry checks, lg compile argv, -module probe"`

### Task 4: Generalize staging and import args

**Files:**
- Modify: `lgx/gobuild.lg` (`stage-wasm-module!` ~768, `wasm-import-args` ~429, `w-module-supported!?` ~962)
- Modify: `lgx.lg` (`build-wasm!` call sites)
- Test: `test/lgx/gobuild_test.lg`

- [ ] **Step 1: Rename with a parameter.**
  - `stage-wasm-module! runtime-bin` becomes `stage-runtime-module! runtime-bin prefix`, with the temp dir `lgx-<prefix>-<rand>`. `build-wasm!` passes `"wasm"`, so its behaviour is unchanged.
  - `wasm-import-args` becomes `module-import-args`, and its tests are renamed to match.
- [ ] **Step 2: Add** `(compile-module-supported!? lg-path)`: `os/sh lg-path "compile" "-h"`, feeding `(str out err)` to `native/compile-module-supported?`. Check whether `lgx.native` can require `lgx.gobuild` without a cycle. If it cannot, put the probe in `lgx.lg`.
- [ ] **Step 3: Run** `bin/lgx test`. Expected: all pass.
- [ ] **Step 4: Run** `bash tests/e2e.sh` (or only the `:wasm` scenarios, if the script supports filtering). Expected: the wasm scenarios are unchanged.
- [ ] **Step 5: Commit** `git commit -m "gobuild: generalize module staging and import args for native builds"`

### Task 5: `build-native!`

**Files:**
- Modify: `lgx.lg` (dispatch ~931, a new fn next to `build-wasm!` ~837)

- [ ] **Step 1: Implement** `build-native!` with `build-wasm!`'s signature, in this order:
  1. `:main` required, `native-build-arg-error forward`, `resolve-main-script!`, `go-available?` (reuse the wasm missing-go error style).
  2. `basis = overlay-basis project cfg with nil`, then `print-installs!`.
  3. `form = read-string (slurp abs-main)` inside `try`. A read error becomes the no-`ns` message's sibling, `:main could not be read: <msg>`. Then `main-ns-error`.
  4. `reachable-lg-files` with `:roots (:paths basis)`, and `:read-first-form` reading the first form with `read-string` in a `try` that returns nil. Print one note per `:skipped` entry: `note: not lowering <ns> (last segment main)` or `note: could not read the ns form of <path>; its requires are not followed`.
  5. Warn about `:resource-paths` (copy the `:lgb` warning, saying "native executable").
  6. `host = apply-runtime! cfg basis :fail verbose?`, then `compile-module-supported!? host`, failing with the probe message.
  7. `resolve-build-targets` (the same as the bundle path), then `duplicate-target-out`.
  8. Per target:
     - `runtime = (if target (ensure-runtime! go-pairs ver target verbose?) host)`;
     - `stage = stage-runtime-module! runtime "native"`;
     - `out = ensure-out-dir! (gobuild/target-out (:out bin) target)`;
     - print the header;
     - build the argv with `module-import-args`;
     - `apply os/sh`, replay the output, and capture the exit code;
     - in a `finally`, `rm-rf` the stage;
     - stop at the first non-zero exit.
  9. `os/exit` with the code.
  - With `--verbose`, trace the argv the way `lg-invocation!` does.
  - On a non-zero `lg compile` exit, after the output, print: `hint: lg compile failed; the default executable target (omit :target) bundles the same program without lowering`.
- [ ] **Step 2: Add the dispatch arm** `:native (build-native! ...)`.
- [ ] **Step 3: Manual smoke test.** Recreate the scratch app from "Verified facts" (an app ns plus a `:local/root` dep). Use `:lg-runtime :built :lg-version "d0108ba6"`, build with `bin/lgx build`, and run `dist/app` from `/tmp`. Expected: `<native-fn` for the app and dep fns.
- [ ] **Step 4: Run** `bin/lgx test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "build: :target :native lowers the app and its deps through lg compile"`

### Task 6: Hermetic e2e scenarios

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Find the next number:** `grep -o 'Scenario [0-9]*' tests/e2e.sh | sort -n | tail -1` (173 at the time of writing).
- [ ] **Step 2: Add scenarios** (expected failures wrapped in `set +e`/`set -e`):
  - `:target :native` with no `:lg-runtime` fails at config load with the `:built` message.
  - A forwarded `-bundle-base x` is rejected.
  - A `:main` without an `ns` form is rejected, with the message, before any runtime build (assert that no `$home/runtimes` directory exists).
  - `(ns app.main ...)` is rejected the same way.
  Use `:lg-runtime :built :lg-version "d0108ba6"` and `env -u LGX_LG` for the `:built` cases. The checks run before `apply-runtime!`, so no Go build happens.
- [ ] **Step 3: Run** `bash tests/e2e.sh`. Expected: PASS.
- [ ] **Step 4: Commit** `git commit -m "e2e: :target :native config and entry checks"`

### Task 7: Gated real-build e2e scenario

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Add one scenario,** skipped unless `LGX_NATIVE_E2E=1` and `go` is on PATH (copy scenario 173's gating and `env -u LGX_LG`). Fixture:
  - `dep/lgx.edn` and `dep/src/mydep/core.lg`, with `(defn shout [s] ...)`;
  - `proj/lgx.edn` with `:paths ["src"]`, the dep via `:local/root`, `hash/crc32 {:go/interop "crc32"}`, `:lg-version "${LGX_NATIVE_E2E_LG_VERSION:-d0108ba6}"`, `:out "dist/app_{{os}}_{{arch}}"`, and `:platforms` with the host plus one other (`linux/arm64`, or `linux/amd64` when the host is arm64);
  - `proj/src/myapp/util.lg` with `greet` calling `mydep.core/shout`;
  - `proj/main.lg` with `(ns myapp.app ...)`, a `-main` printing the greeting, `(str u/greet)`, `(str d/shout)`, a crc32 checksum and `*command-line-args*`, and a top-level `(-main)`.
- [ ] **Step 2: Assert:**
  - `lgx build --all` exits 0 (a plain `lgx build` makes only the host binary);
  - the host binary, run from a fresh `mktemp -d` with an arg, prints the greeting once (count the lines), `<native-fn greet`, `<native-fn shout`, the checksum and the arg;
  - `go version -m` on the other binary shows its `GOARCH`;
  - no `lgprogram` is under `$home/runtimes/*/src`;
  - no `lgx-native-*` dirs are left in `${TMPDIR:-/tmp}`;
  - a second build whose `-main` calls an unresolvable symbol exits non-zero, prints the `hint:` line, and also leaves no `lgx-native-*` dir behind.
- [ ] **Step 3: Run** `LGX_NATIVE_E2E=1 bash tests/e2e.sh`. Expected: PASS. Also run without the variable, and confirm the scenario reports itself skipped.
- [ ] **Step 4: Commit** `git commit -m "e2e: gated :target :native real build"`

### Task 8: Docs

**Files:**
- Modify: `README.md` (the build targets section, next to `:lgb`/`:wasm`)
- Modify: `docs/ARCHITECTURE.md` (the build pipeline: a third target)
- Modify: `docs/knowledge-base/lgx-go-runtimes.md` (native staging, `LG_SOURCE_PATHS`, the per-target runtime; update its `Verify against:` footer)

- [ ] **Step 1: README.** Cover:
  - the config example and requirements (`:built`, the pin, `go` on PATH);
  - what lowers (reachable `.lg` namespaces), and what does not (`.cljc`/`.clj`, embedded namespaces, top-level `require`), which still run;
  - the entry rules (`ns` form, `(-main ...)` not `apply`, no `main` last segment);
  - caveats with their issues:
    - lowered callers do not see `with-redefs`/`alter-var-root` on lowered callees unless they are `^:redef`/`^:dynamic` (#990);
    - core functions still run as bytecode (#1067);
    - no fail-on-fallback (#660);
    - resources are not embedded;
    - runtime `require` searches only `LG_SOURCE_PATHS`.
- [ ] **Step 2: ARCHITECTURE and knowledge base,** in the same words as the code.
- [ ] **Step 3: Commit** `git commit -m "docs: :target :native"`

### Task 9: Upstream issue and backlog

**Files:**
- Create: `docs/issues/letgo-compile-entry-handling.md`; modify `docs/issues/README.md`
- Modify: `docs/backlog/native-build-target.md`
- Create: `docs/backlog/native-strict-fallbacks.md`, `docs/backlog/native-resources.md`, `docs/backlog/native-lowered-core.md`

- [ ] **Step 1: Draft the upstream issue** for nooga/let-go, with the three repros from "Verified facts":
  - a file without `ns` runs `-main` twice;
  - `(apply -main *command-line-args*)` runs it twice;
  - a namespace with last segment `main` becomes `package main`.
  
  Build a prefilled link with /github-issue-link and record the draft in `docs/issues/`. When the user has filed it, put the number in the issue file, `docs/issues/README.md` and the README's `:target :native` caveats. Nothing else depends on it.
- [ ] **Step 2: Commit** `git commit -m "Issues: lg compile entry handling"`
- [ ] **Step 3: Backlog,** in its own commit:
  - mark `native-build-target.md` done, saying where it landed;
  - add the three new entries (`**Status: open**`):
    - fail on unapproved fallbacks once #660 gives a report;
    - embed `:resource-paths` in native builds;
    - link the lowered core once #1067/#940 land.
  
  `git commit -m "Backlog: :target :native shipped; strict fallbacks, resources, lowered core open"`

## Completion summary

(Filled in after execution.)
