# Native Builds: Project-Only Lowering, Embedded Resources, Build Tags Implementation Plan

**Status: completed** (2026-10-24, branch `native-project-lowering-and-resources`)

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lgx build` with `:target :native` produce a working desktop app such as Quel: lower only the project's own namespaces by default, embed `:resource-paths` in the binary, and accept `:go/build-tags` under `:targets :bin`.

**Tech Stack:** let-go (`.lg`), `lg compile -module`/`-import` (let-go `main` after 1.13.0), Go `embed`, lgx's runtime builder (`lgx/gobuild.lg`), the lgx unit suite (`bin/lgx test`), `tests/e2e.sh`.

**Origin:** Quel's signed macOS release (`../quel/docs/plans/2026-10-24-1428-macos-homebrew-release.md`, Task 1). `lg -b` appends its payload after the Mach-O image, so `codesign` rejects it. A native build embeds the bytecode with `go:embed` and signs cleanly, but Quel could only build natively with three manual workarounds, which this plan moves into lgx. Backlog: `docs/backlog/native-resources.md`.

---

## Design

### What changes for users

```clojure
{:main "src/quel/app.lg"
 :resource-paths ["resources"]
 :lg-runtime :built
 :lg-version "18df3ad5c033cbf8f214c7d2a09e97f78a642510"
 :targets {:bin {:target :native
                 :out "bin/quel"
                 :go/build-tags ["production"]   ; new: allowed for :native
                 :native {:lower :project}}}}    ; new; :project is the default
```

1. **Lowering scope.** By default `lgx build` lowers `:main` plus the reachable `.lg` files under the project's own source paths. Dependency namespaces run as bytecode inside the same binary. `:native {:lower :all}` restores today's behavior of lowering every reachable namespace.
2. **Resources.** The files under `:resource-paths` are embedded in the native binary, and `io/resource` reads them at run time as it does in an `lg -b` bundle. The "not embedded" warning goes away.
3. **Build tags.** `:go/build-tags` under `:targets :bin` is accepted with `:target :native` and reaches only the shipped binary, as it does for the default executable. `:lgb` and `:wasm` still reject it.

Unchanged: the default executable (`lg -b`), `:lgb`, `:wasm`, `lgx run`/`dev`/`test`/`repl` (they keep reading resources from disk), and the runtime cache.

### Why each change

- **Project-only lowering.** Lowering dependencies hits nooga/let-go#1098: when a syntax-quoted macro's own namespace is lowered too, the caller's expansion cannot resolve that namespace's vars. `sql.core/with-transaction` (letgo-packages) fails this way, so Quel cannot build natively today. Dependency macros are common, so the safe default is the project's own code. Projects that want dependencies lowered, and whose dependencies lower cleanly, opt in. This also makes builds faster.
- **Resources.** `lg compile` embeds only `program.lgb` and installs no resource provider (nooga/let-go#1099). A Go package passed with `-import` runs its `init()` before the program starts. If that package embeds the files and installs `rt.NewEmbeddedResourceProvider`, `io/resource` works. This was verified by hand on Quel, on Linux and on macOS. It is a bridge: when #1099 lands, lgx can switch to the upstream mechanism.
- **Build tags.** Quel needs `production` in the shipped binary only (it drops Wails' devtools and dev-server proxy), not in `lgx run`. Today the native target rejects bin-level tags and passes only the top-level tags through `GOFLAGS`.

### Verified facts this design rests on

Checked 2026-10-24 on let-go `main` `18df3ad5` and lgx 0.5.1 (`4d5579a`):

- Minimal #1098 repro: `m/core.lg` with `(defn begin [x] ...)` and a macro expanding to `` `(let [~s (begin ~v)] ...) ``, called from `app.lg`. `lg compile app.lg` builds and runs. `lg compile app.lg m/core.lg` fails with `Can't resolve begin in this context`, in any file order.
- Quel built with lgx's exact `lg compile -module ... -import ...` command, with the file list cut down to Quel's own 17 namespaces: 232 functions lowered, and the bridge smoke test passed against the binary run from an unrelated directory.
- A package at `lgx.local/runtime/lgres` in the staged module, with `//go:embed all:resources` and an `init()` that builds a `map[string][]byte` and calls `rt.SetResourceProvider(rt.NewEmbeddedResourceProvider(files))`, passed as `-import lgx.local/runtime/lgres`: the binary served the embedded files over Wails' asset handler. On macOS the same build signed with `codesign --force --sign - --options runtime`, passed `codesign --verify --strict`, and rendered Quel's real UI.
- The native entry frame (`pkg/rt/core/ir/passes/entry_frame.lg`) never touches the resource provider, so an `init()`-installed provider survives to run time.
- `-b` collects resources with `bundle.CollectResources` (`pkg/bundle/bundle.go`): roots in order, first root wins per relative path, symlinks followed only when they resolve inside the root, symlink cycles skipped, non-regular files skipped, the bundle's own output file excluded. Keys are slash-separated paths relative to the root (`public/index.html`).
- lgx runs on lg 1.13.0, which has `os/canonical-path` (EvalSymlinks + Abs), `os/stat` (follows symlinks; `:dir?`, `:size`, no file mode) and `os/ls`.

### Approach

**Lowering scope.** `native/reachable-lg-files` keeps walking the whole graph, because a project file can be reached through a dependency. A new pure filter then keeps `:main` plus the project's files. The project roots are the basis's source paths that came from the project: `:paths` plus the `:extra-paths` of applied contexts, absolutized exactly as the basis's `:paths` are, so a string prefix test (`root` + `/`) matches the walker's output. Every other basis source path is a dependency root. `overlay-basis` gains a `:project-paths` key for this. A file belongs to the most specific root that contains it, meaning the longest matching root. So a `:local/root "vendor/lib"` dependency stays a dependency even under `:paths ["."]`. On an exact tie (the same directory is both a project and a dependency path), the project wins, since the project declared it. Skipped-file notes (`:entry`, `:main-segment`, `:unreadable`) print only for files that would have been lowered. One note counts the dependency namespaces left on bytecode, with a hint to set `:native {:lower :all}`. With `:lower :all` the file list is today's.

**Resources.** A pure collector mirrors `CollectResources` against injected file-system functions. The impure stager copies each collected file byte-for-byte into `<module>/lgxresources/files/<rel>`, and writes `<module>/lgxresources/resources.go`. `build-native!` adds `-import lgx.local/runtime/lgxresources` to the `lg compile` argv. The staged module is a per-build temp copy (`stage-runtime-module!`), so neither the runtime cache nor any other command sees the package. With no resources, nothing is generated and the argv is unchanged. Each target's `:out` (canonicalized) is excluded, as `-b` excludes its output. Files are copied rather than linked because `go:embed` does not follow symlinks.

The generated Go file (fixed text; lgx writes it verbatim):

```go
// Code generated by lgx. DO NOT EDIT.

// Package lgxresources installs the project's :resource-paths as let-go's
// io/resource provider before the program runs.
package lgxresources

import (
	"embed"
	"io/fs"
	"strings"

	"github.com/nooga/let-go/pkg/rt"
)

//go:embed all:files
var embedded embed.FS

func init() {
	files := map[string][]byte{}
	err := fs.WalkDir(embedded, "files", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := embedded.ReadFile(p)
		if err != nil {
			return err
		}
		files[strings.TrimPrefix(p, "files/")] = b
		return nil
	})
	if err != nil {
		panic("lgxresources: " + err.Error())
	}
	rt.SetResourceProvider(rt.NewEmbeddedResourceProvider(files))
}
```

Reusing `rt.NewEmbeddedResourceProvider` keeps name normalization identical to `-b`. The map copies the bytes once more at startup; for a frontend of a few MB that cost is acceptable and keeps the generated code small. Names that `go:embed` cannot carry (for example ones containing `"`, `*`, `<`, `>`, `?`, `` ` ``, `'`, `|`, `:` or `\`) fail the `go build`, and lgx relays that error. The README documents the limit; lgx does not pre-validate names.

**Build tags.** `bin-target-errors` stops rejecting `:go/build-tags` for `:native` (still rejects `:lgb` and `:wasm`). `build-native!` mirrors the executable path's `base` rule. When the target is a cross target or bin tags are present, the module to stage comes from `gobuild/ensure-runtime!` with top-level plus bin tags, so interop bindings are generated under the same tags the binary is built with. Otherwise it is the host runtime. `with-build-tags-in-goflags` receives top-level plus bin tags. The host runtime that runs `lg compile` keeps the project's top-level tags.

### Error handling

- `:native` under a `:bin` whose `:target` is not `:native`: config error `applies only to :target :native` (mirrors `:wasm`).
- `:native {:lower x}` with any other value: config error naming `:project` and `:all`. The map is closed.
- A resource root that is missing or not a directory is skipped silently, as `-b` does (the basis already warns about missing declared paths).
- A failed copy or write while staging resources throws. Staging runs inside the `try` whose `finally` removes the staged module (Task 5 widens that scope), so nothing is left behind.
- Non-regular files (FIFOs, devices, sockets) under a resource root are skipped, as `-b` skips them. `os/stat` has no file mode, so the collector takes a `:regular?` predicate. The real one is `test -f` through `os/sh`, which follows symlinks. This also keeps `cp` from blocking on a FIFO.

### Testing

- Unit (`bin/lgx test`): config accepts/rejects the new keys; the project filter; the resource collector against a fake file system (first root wins, in-root symlink followed, escaping symlink skipped, cycle terminates, missing root skipped, output excluded); the stager against a real temp dir with non-UTF-8 bytes; the argv gaining the import.
- Hermetic e2e (`tests/e2e.sh`): the new config errors.
- Gated real-build e2e (Scenario 178, `LGX_NATIVE_E2E=1`): by default the app fn is lowered and the dep fn is not; with `:native {:lower :all}` both are; an embedded text resource and a binary resource read correctly from a clean directory; a bin-level build tag selects a tag-gated file in a `:go/local` dep.
- Manual: Quel built with the new lgx (`lgx build` with `:target :native`) on Linux in server mode, with the bridge smoke run against the binary; the user repeats signing and launch on macOS.

## File Structure

- `lgx/config.lg`: `:native` options schema and accessor; bin-level `:go/build-tags` allowed for `:native`.
- `lgx/native.lg` (pure): project-file filter, dependency note, resource collector, generated Go source and import path.
- `lgx/gobuild.lg` (impure staging): `stage-native-resources!` beside `stage-runtime-module!`.
- `lgx.lg`: `overlay-basis` exposes `:project-paths`; `build-native!` wires scope, resources and tags.
- `test/lgx/config_test.lg`, `test/lgx/native_test.lg`, `test/lgx/gobuild_test.lg`: unit tests.
- `tests/e2e.sh`: hermetic config scenarios; Scenario 178 extended.
- `README.md`, `docs/ARCHITECTURE.md`: native section, build tags section, architecture notes.
- `docs/backlog/native-resources.md`: status updates. `docs/issues/letgo-compile-macro-lowered-ns.md`, `docs/issues/letgo-compile-embed-resources.md`: records of nooga/let-go#1098 and #1099.

## Tasks

### Task 1: Config accepts `:native` options and bin-level build tags for native

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`, `tests/e2e.sh`

- [x] **Step 1: Write the failing unit tests.** In `test/lgx/config_test.lg` (follow the existing `:wasm` option tests): `:target :native` with `:native {:lower :project}` and with `{:lower :all}` loads; `{:lower :deps}` fails naming `:project` and `:all`; an unknown key in `:native` fails (closed map); `:native` with `:target :lgb`, `:wasm` or no `:target` fails with `applies only to :target :native`; `:go/build-tags ["production"]` under `:bin` with `:target :native` loads; with `:lgb` and `:wasm` it still fails with the existing message; `(config/bin-native cfg)` returns the map or `{}`.
- [x] **Step 2: Run** `bin/lgx test test/lgx/config_test.lg`. Expected: the new tests fail.
- [x] **Step 3: Implement.** Add `native-opts-schema` (`[:map {:closed true} [:lower {:optional true} [:enum :project :all]]]`) to the `:bin` map, an `applies only to :target :native` rule in `bin-target-errors`, and `bin-native` beside `bin-wasm`. Narrow the `:go/build-tags` rule to `:lgb` and `:wasm`, and reword its message: say that only the standalone executable and `:target :native` build onto a runtime lgx builds. Check that `lg-runtime-errors` still requires `:built` for bin-level tags. Update the docstrings (`bin-target`, `bin-go-build-tags`) that list targets.
- [x] **Step 4: Run** `bin/lgx test test/lgx/config_test.lg`. Expected: PASS.
- [x] **Step 5: Hermetic e2e.** Find the existing scenario that rejects bin-level `:go/build-tags` for a target (`grep -n "does not apply to :target" tests/e2e.sh`). If it uses `:native`, switch it to `:lgb`. Add one scenario: `:native {:lower :all}` with `:target :lgb` is a config error and writes nothing. Number it after the last scenario. Run `bash tests/e2e.sh 2>&1 | tail -5`. Expected: no failures.
- [x] **Step 6: Commit.** `git commit -m "Accept :native options and bin build tags for :target :native"`

> Deviation: no existing e2e scenario rejected bin-level `:go/build-tags` for `:native`, so nothing was switched to `:lgb`; the new scenario is 180.
> Review: codex flagged that the new keys are accepted before `build-native!` uses them (P1 tags, P2 `:lower`). Advisory: Task 5 wires both.

### Task 2: Pure project-file filter

**Files:**
- Modify: `lgx/native.lg`
- Test: `test/lgx/native_test.lg`

- [x] **Step 1: Write the failing tests.** `native/project-files` takes `{:files [...] :main abs-main :project-roots [...] :dependency-roots [...]}` and returns `{:files kept :dependency-count n}`:
  - `:main` is kept even when it lies outside every root;
  - a file under `/p/src` is kept, a file under `/deps/x/src` is not;
  - `/p/src-extra/a.lg` is not under root `/p/src` (prefix plus separator, not a bare string prefix);
  - with project root `/p` and dependency root `/p/vendor/lib/src`, `/p/vendor/lib/src/l.lg` is dropped (the longest root wins) and `/p/a.lg` is kept;
  - a directory that is both a project and a dependency root counts as project;
  - order is preserved;
  - the count is the number dropped.

  `native/dependency-note` returns nil for 0, else a line like `note: 12 dependency namespaces run as bytecode (set :native {:lower :all} to lower them)` (singular for 1).
- [x] **Step 2: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: the new tests fail.
- [x] **Step 3: Implement** both as pure functions in `lgx/native.lg`, in a new "Lowering scope" section. Use `os/file-separator` for the boundary, as `lgx/new.lg`'s `relative-to` does.
- [x] **Step 4: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: PASS.
- [x] **Step 5: Commit.** `git commit -m "Add the native project-file filter"`

> Deviation: also exposed `native/project-file?` (the per-file predicate) so Task 5 can filter skipped notes with the same rule.
> Review: codex P2, a root of `/` doubled the separator; fixed in a fixup commit.

### Task 3: Pure resource collector and generated source

**Files:**
- Modify: `lgx/native.lg`
- Test: `test/lgx/native_test.lg`

- [x] **Step 1: Write the failing tests.** `native/collect-resources` takes `{:roots [...] :exclude #{canonical-paths} :ls f :stat f :canonical f :regular? f}` and returns `[{:rel "public/index.html" :src "/real/path"} ...]`. `:canonical` returns nil for a dangling path. Use a fake file system built from a map, with symlinks modeled as entries whose canonical path differs. Cases:
  - files in nested dirs get slash-separated rels;
  - two roots defining the same rel: the first wins;
  - a symlinked file and a symlinked dir inside the root are followed;
  - a symlink resolving outside the root is skipped;
  - a dir symlink back to an ancestor terminates (cycle guard on canonical dir paths currently being descended, so two distinct names aliasing one in-root dir are both kept, as in `bundle.collectResourceDir`);
  - a missing root and a root that is a file are skipped;
  - an excluded canonical path is skipped;
  - a dangling symlink is skipped;
  - a non-directory for which `:regular?` is false (a FIFO) is skipped.

  Also: `native/resource-import` is the literal `"lgx.local/runtime/lgxresources"`. `lgx.gobuild` requires `lgx.native`, so `native` cannot read `gobuild/runtime-module`; Task 4's test asserts the two agree. `native/resource-go-source` returns the fixed text from the Design section, and contains `//go:embed all:files` and `NewEmbeddedResourceProvider`.
- [x] **Step 2: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: the new tests fail.
- [x] **Step 3: Implement** in a new "Resources" section of `lgx/native.lg`. Walk each root's canonical path. For each entry, canonicalize it and keep it only if it is the canonical root or under it. Recurse into dirs, record non-directories for which `:regular?` holds, and skip the rest. Sort `ls` output for a deterministic order.
- [x] **Step 4: Run** `bin/lgx test test/lgx/native_test.lg`. Expected: PASS.
- [x] **Step 5: Commit.** `git commit -m "Collect native resources the way lg -b does"`

> Verified: the generated `resources.go` is gofmt-clean and `go vet`s against let-go `18df3ad5`. Review: codex found nothing.

### Task 4: Stage resources into the module

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write the failing test.** Create a temp root with `public/index.html`, a nested `public/assets/app.js`, and a binary file holding bytes `00 ff 80 0a`, plus an empty temp module dir. Call `(gobuild/stage-native-resources! module entries)` with `native/collect-resources` output over that root, using the real `os/ls`, `os/stat` and `os/canonical-path`. Assert that it returns true, that `lgxresources/resources.go` equals `native/resource-go-source`, and that each file under `lgxresources/files/` is byte-identical to its source (compare with `cmp` through `os/sh`). With an empty entries vector it returns false and creates nothing. Also assert `(= native/resource-import (str gobuild/runtime-module "/lgxresources"))`.
- [x] **Step 2: Run** `bin/lgx test test/lgx/gobuild_test.lg`. Expected: the new test fails.
- [x] **Step 3: Implement** `stage-native-resources!` beside `stage-runtime-module!`. `mkdir` each parent, then copy each file with `os/sh "cp" src dst`, which copies bytes exactly and follows a symlinked source. Throw `ex-info` with the file and cp's stderr on a non-zero exit. Write `resources.go` with `spit`. Do not use `slurp`/`spit` for the resource files: they are text APIs.
- [x] **Step 4: Run** `bin/lgx test test/lgx/gobuild_test.lg`. Expected: PASS.
- [x] **Step 5: Commit.** `git commit -m "Stage native resources as an embedded Go package"`

> Deviation: codex P2 found that a file `foo` in one root and `foo/bar.txt` in another (both valid `-b` keys) cannot share one embed tree. Added `native/resource-collision`; the stager throws naming both before copying anything (a fixup commit). A collision-safe layout would change the fixed Go source, so it was not adopted. A second review found nothing.

### Task 5: Wire scope, resources and tags into `build-native!`

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh` (Scenario 178)

- [x] **Step 1: Expose project paths.** In `overlay-basis`, return `:project-paths` alongside `:paths`: the `raw-paths` entries, absolutized exactly as `basis` absolutizes its source paths. Read `basis` first and reuse its absolutizing call rather than duplicating it. Run `bin/lgx test`. Expected: PASS (an added key changes nothing else).
- [x] **Step 2: Lowering scope.** In `build-native!`, after `reachable-lg-files`:
  - with `(:lower (config/bin-native cfg) :project)` equal to `:project`, pass the walker's files through `native/project-files`, with `:project-paths` as the project roots and the remaining basis `:paths` as the dependency roots;
  - print `native/dependency-note` when non-nil;
  - print `skipped-note`s only for skipped entries that `native/project-files` would keep, using the same longest-root rule (with `:all`, print them all, as today).
- [x] **Step 3: Tags and module.** Compute `bin-tags` (`config/bin-go-build-tags`). Pick the runtime whose module is staged:
  - `(gobuild/ensure-runtime! go-pairs (config/lg-version cfg) target (vec (concat (config/go-build-tags cfg) bin-tags)) verbose?)` when `(or target (seq bin-tags))`;
  - otherwise `host`.

  Pass the concatenated tags to `with-build-tags-in-goflags`.
- [x] **Step 4: Resources.** Before the target loop, run `native/collect-resources` over the basis `resource-paths` with the real fs functions (`:regular?` is `#(zero? (:exit (os/sh "test" "-f" %)))`). Exclude per target: filter out the canonical `abs-out` if it already exists. After `stage-runtime-module!`, call `stage-native-resources!` with the entries. When it returns true, add `"-import" native/resource-import` to the imports passed to `native-compile-argv`. Restructure the per-target body so that everything after `stage-runtime-module!` (resource staging, argv, compile) runs inside the `try` whose `finally` removes the module. A staging failure must not leave `lgx-native-*` behind. Exit on a non-zero compile only after the `finally`, as today. Delete the "not embedded" warning, and update the `build-native!` docstring (it says resource paths are not embedded).
- [x] **Step 5: Run** `bin/lgx test`. Expected: PASS.
- [x] **Step 6: Extend gated Scenario 178.**
  - The default build now prints `<native-fn greet` and a bytecode `shout` (assert `<fn shout` or the absence of `<native-fn shout`; check what `(str f)` prints for a bytecode fn first), plus the dependency note.
  - Add `:resource-paths ["resources"]` with `resources/greeting.txt` (`hello`) and `resources/blob.bin` (bytes `00 ff 80 0a`, written with `printf`). The app prints the greeting through `io/resource` and the blob's byte values as unsigned integers; assert `0 255 128 10`. Check how `io/resource` returns content in let-go before writing the assertion.
  - A second build with `:native {:lower :all}` prints `<native-fn shout`.
  - A bin-level tag: model on Scenario 179's tag-gated `:go/local` fixture, and assert the tagged variant runs in the native binary.
  - The staged-module and runtime-cache assertions stay.
  - A failed resource stage removes the module: make one resource file unreadable (`chmod 000`), build, and assert a non-zero exit with no new `lgx-native-*` dir. Restore the mode afterwards.

  Run `LGX_NATIVE_E2E=1 bash tests/e2e.sh 2>&1 | grep -E "Scenario 178|FAIL|ok" | head -40`. Expected: Scenario 178 passes with no FAIL.
- [x] **Step 7: Full suite.** Run `make test`. Expected: all unit and e2e tests pass, the gated ones skipped.
- [x] **Step 8: Commit.** `git commit -m "Lower only project namespaces and embed resources in native builds"`

> Deviation: `:project-paths` is added in `basis` (which does the absolutizing, `own-paths`) rather than in `overlay-basis`, which returns `basis`'s map as is.
> Deviation: a staging error is caught inside the `try` and printed as `lgx: <message>` with exit 1, after the `finally` removes the module. The compile hint is not printed for it.
> Deviation: the `:lower :all` rebuild in Scenario 178 uses `build --all`. A bare `lgx build` writes `:out` unexpanded (`gobuild/target-out` with a nil target, documented), so it would not replace `$host_bin`.
> Review: codex P2, the output was excluded after first-root-wins precedence, so a stale binary in an early root could hide a later root's file of the same name. Fixed in a fixup: resources are now collected per target with `:exclude #{out-real}`.
> Review: codex P2 (not adopted, design call), bin-level tags reach the staged module and `go build`, but not the host runtime that runs `lg compile`. A `:go/local` namespace that exists only under a bin tag would fail to resolve at compile time. This matches the plan ("the host runtime that runs `lg compile` keeps the project's top-level tags") and the executable path's `lg -b`; raised with the user.
> Verified after the fixup: the gated Scenario 178 passes (25 assertions), and `make test` passes.

### Task 6: Verify on Quel

**Files:** none in lgx (a scratch copy of Quel only).

- [x] **Step 1: Build.**
  1. `git archive HEAD` from `../quel` into a fresh temp dir.
  2. Set `:lg-version` to the let-go `main` sha used in Scenario 178.
  3. Set `:targets {:bin {:target :native :out "bin/quel" :go/build-tags ["server"]}}`; `server` stands in for `production` on Linux.
  4. Run `lgx fe-install && lgx fe-build`.
  5. Run `CGO_ENABLED=0 LGX_LG= bin/lgx lgx:build` using this repo's `bin/lgx`, after `make build` or however `bin/lgx` is produced (check the Makefile).

  Expected: the dependency note, `native entry: Main ✓`, `built .../bin/quel`, and no "not embedded" warning.
- [x] **Step 2: Smoke.** Start the binary from an unrelated temp dir with `WAILS_SERVER_PORT=<free port> QUEL_SECRETS=memory QUEL_DATA_DIR=<temp>`. `curl` `/` and the first `/assets/*.js` named in the served `index.html`. Expected: 200 with Quel's HTML, not Wails' "Page Not Found", and 200 for the script. Then call the bridge's `ping` and `open-db`/`run` the way `../quel/scripts/server-mode.sh` does. Expected: `"ok":true` and rows.
- [x] **Step 3: Record** the result in this plan's Verification section, and give the user the macOS repeat: the same build with `:go/build-tags ["production"]` on their Mac, then `codesign --force --sign - --options runtime`, `codesign --verify --strict --verbose=2`, and a launch. No commit for this task.

> Deviation: pinned Quel to `18df3ad5c033…` (the let-go `main` the design verified Quel on, and the one Quel's own plan uses), not Scenario 178's default `d0108ba6`.
> Deviation: the build ran with `CGO_ENABLED=0 GOFLAGS=-tags=server`, not just `CGO_ENABLED=0`. This Linux box has no GTK, and the host runtime that runs `lg compile` gets only top-level tags (the Task 5 codex P2 not adopted), so without `server` in GOFLAGS that runtime fails to compile Wails. `fe-install`/`fe-build` need the same env, since they also build the runtime. On macOS, the host builds with cgo and this does not arise.

### Task 7: Docs, backlog and upstream records

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/backlog/native-resources.md`
- Create: `docs/issues/letgo-compile-macro-lowered-ns.md`, `docs/issues/letgo-compile-embed-resources.md`

- [x] **Step 1: README.**
  - In "Native output", describe the lowering scope and `:native {:lower :all}`, embedded resources (and the `go:embed` name limit), and bin-level tags, and remove "Resources are not embedded".
  - Add nooga/let-go#1098 to the caveats as the reason dependency lowering is opt-in.
  - In the `:go/build-tags` section, say that bin-level tags apply to the executable and `:native` and are rejected for `:lgb` and `:wasm`.
  - Update the command table row if it needs to change.
- [x] **Step 2: ARCHITECTURE.** Update the `lgx/native.lg` line and the `lgx build` section: project-only lowering, the resources package in the staged module, and the module runtime for bin tags. Check its `Verify against:` footer, if any.
- [x] **Step 3: Issue records.** Follow `docs/issues/letgo-wasm-embed-resources.md`'s shape. Write one file per issue: `**Repo:**`, `**Status:** filed as [nooga/let-go#NNNN](...)`, how it was found (Quel, let-go `main` `18df3ad5`), the summary, the minimal repro (for #1098), and the lgx impact and workaround. Add both to `docs/issues/README.md` if it indexes them.
- [x] **Step 4: Backlog.** `docs/backlog/native-resources.md`: set `**Status: done**` with a line saying it landed through an `-import`ed `lgxresources` package (this plan), still tracking nooga/let-go#1099 for an upstream mechanism. Per AGENTS.md, never delete the entry.
- [x] **Step 5: Commit.** `git commit -m "Document native lowering scope, resources and bin build tags"`

> Verified: the #1098 repro in `docs/issues/letgo-compile-macro-lowered-ns.md` was re-run as written on an lg built from `18df3ad5`. `app.lg` alone builds and prints `1`; with `m/core.lg`, in either order, it fails with `Can't resolve begin in this context`. Review: codex found nothing.

## Out of scope

- Releasing lgx (version bump, tag). That is the user's call after review; Quel's plan pins the release.
- Changing `sql.core` in letgo-packages (not needed with project-only lowering).
- Linking the lowered core (`docs/backlog/native-lowered-core.md`, nooga/let-go#1067).
- Resources for `:target :wasm` (nooga/let-go#999).
- A per-namespace lowering allow-list. `:lower` has two values until a real need appears.

## Verification

Task 6, 2026-10-24, lgx at `58a7fc8`, Quel at `7c124c7` (a `git archive` copy), let-go `main` `18df3ad5`, Linux amd64, Go 1.27.1:

- `CGO_ENABLED=0 GOFLAGS=-tags=server lgx lgx:build` with `:targets {:bin {:target :native :out "bin/quel" :go/build-tags ["server"]}}` printed `note: 7 dependency namespaces run as bytecode ...`, `232 fns lowered; native entry: Main ✓` and `built .../bin/quel` (41 MB). There was no "not embedded" warning.
- The binary run from an unrelated empty dir with `WAILS_SERVER_PORT`, `QUEL_SECRETS=memory` and `QUEL_DATA_DIR`: `/` returned 200 with Quel's `index.html` (not Wails' "Page Not Found"), `/assets/index-qq6r3FSu.js` returned 200 (985430 bytes), `ping` answered `{"ok":true}`, and `open-db` plus `run "select 1 as a, 'x' as b"` returned `"rows":[[1,"x"]]`.

macOS repeat, for the user: in Quel, set `:lg-version` to the same sha and `:targets {:bin {:target :native :out "bin/quel" :go/build-tags ["production"]}}`, run `lgx build`, then `codesign --force --sign - --options runtime bin/quel`, `codesign --verify --strict --verbose=2 bin/quel`, and launch it.

## Summary

**Implemented.** `lgx build` with `:target :native` now does three new things:

- It lowers only `:main` and the project's own namespaces by default. A file belongs to the longest root that contains it, and the project wins a tie. Dependency namespaces run as bytecode, with a note, and `:native {:lower :all}` restores full lowering.
- It embeds `:resource-paths`. They are collected as `lg -b` collects them, copied into a generated `lgxresources` package in the staged module, and `-import`ed.
- It accepts bin-level `:go/build-tags`. They reach the staged module's runtime and the `go build`.

Config validation covers the new keys. README, ARCHITECTURE, two upstream issue records (#1098, #1099) and the backlog entry are updated. Quel builds natively with the new lgx: 232 fns lowered, and its frontend and bridge both work from an unrelated directory.

**Tests.** The unit suite passes (938 tests), `make test` passes, and the gated `LGX_NATIVE_E2E=1` Scenario 178 passes (25 assertions). `make lint` shows two warnings that are already on `master`. `cljfmt` is not installed, so `make fmt-check` did not run.

**Issues encountered.**

- The first `:lower :all` check in Scenario 178 passed vacuously wrong: a bare `lgx build` writes `:out` unexpanded, so the binary under test was never replaced. It now uses `--all`.
- Go is not on PATH by default here. Gated runs used mise's Go 1.27.1, and the copied Quel needed absolute tool paths because its `.mise.toml` is untrusted there.

**Deviations, in one place.**

- Task 1: no e2e scenario rejected `:native` bin tags, so nothing was switched. The new scenario is 180.
- Task 2: also exported `native/project-file?`. A root of `/` no longer doubles the separator (codex fixup).
- Task 4: a file `foo` in one resource root and `foo/bar.txt` in another fail staging with a clear error (`native/resource-collision`), rather than corrupting the embed tree (codex fixup).
- Task 5: `:project-paths` comes from `basis`, not `overlay-basis`. A staging error prints `lgx: ...` and exits 1 after the cleanup. Resources are collected per target, so the output exclusion happens before first-root-wins (codex fixup). Scenario 178's `:all` rebuild uses `--all`.
- Task 6: Quel was pinned to `18df3ad5`, not `d0108ba6`. The build needed `GOFLAGS=-tags=server`, not just `CGO_ENABLED=0`, because there is no GTK and the host runtime gets only top-level tags.
- Not adopted (a design call, for the user): bin-level tags do not reach the host runtime that runs `lg compile` (codex Task 5 P2). A `:go/local` namespace that exists only under a bin tag would fail to resolve, and on a Linux box without GTK, Wails' host runtime needs the tag through `GOFLAGS`. This matches the plan and the executable path's `lg -b`.

**What the plan could have specified better:** whether the host compiler runtime should get bin-level tags. The plan pinned "keeps top-level tags" by analogy with `lg -b`, but `lg compile` resolves the Go namespaces at compile time, so a tag-gated API or a GTK-less Linux host breaks it. It should also have noted that a bare `lgx build` with a templated `:out` does not write the platform-named file the e2e asserts on.
