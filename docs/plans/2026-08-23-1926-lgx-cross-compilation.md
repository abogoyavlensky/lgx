# lgx Cross-Compilation and Cache Management Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `lgx build` produce binaries for other platforms from one machine, give the runtime cache an explicit cleanup command, and fix three correctness gaps in the Go-deps pipeline that ship alongside it.

**Tech Stack:** let-go (`.lg` — lgx is written in it), the Go toolchain as a subprocess, `lgx/gobuild.lg`'s existing runtime-build machinery.

---

## Design

### Why cross-compilation is nearly free

`lg -b` bundles a script by copying a base binary and appending bytecode, so a bundle for another platform needs a *target-platform* `lg` as its base. That is the whole problem, and lgx already has the machinery to solve it: `lgx/gobuild.lg` generates a Go module and builds an `lg` from it. Cross-compiling is that same build with `GOOS` and `GOARCH` set.

This was verified before planning. The generated module renders a valid stock `lg` when the coord set is empty, and building it with the two env vars produced a Mach-O arm64 binary and a statically linked x86-64 ELF from a Linux arm64 host. The same held with the sqlite driver linked in, because `modernc.org/sqlite` is pure Go. So both the no-Go-deps case and the Go-deps case are covered by one code path.

Measured cost on that host: a fully cold stock build (empty module *and* build cache) took 10.8s; warm-module/cold-build-cache 9.3s; a no-op rebuild 0.5s; a cache hit 0ms. With the sqlite driver, a cold build cache took 15.3s.

### Two runtimes, not one

The most important consequence of how `lg -b` works, and the easiest thing to get wrong.

Bundling **executes** on the host: `lg -b` compiles the script, and compilation runs top-level forms, so a veneer's `(:require)` has to resolve its native namespaces at build time (let-go's `docs/guide/custom-lg.md` says exactly this). Meanwhile `-bundle-base` must point at a *target-platform* binary, which cannot execute on the host at all.

So cross-building a project **with** Go deps needs two runtimes:

| Role | Platform | Why |
|---|---|---|
| the `lg` lgx invokes | host | must run, and must resolve the project's Go namespaces at compile time |
| `-bundle-base` | target | becomes the shipped binary's base |

Both come from the same `ensure-runtime!`, differing only in target — so a four-platform release of a Go-deps project builds five runtimes: one host plus four targets. Native builds need only the one.

For a project **without** Go deps the host side is just the `lg` on `PATH`, which needs no build; only the target base is generated.

`LGX_LG` interacts with this: an explicit `LGX_LG` overrides the *host* runtime (with the existing warning), but it can say nothing about the target base, which must still be built. Cross-building with `LGX_LG` set and Go deps declared is therefore contradictory — the host lg will not resolve the project's namespaces. Detect it and fail with a message saying so, rather than producing a binary that cannot run.

### Runtime selection stays deterministic

The rule must be derivable from committed config plus the command typed, never from what happens to be installed — otherwise two developers on one repo get different runtimes with no signal.

- **Go deps declared** → build a runtime. Determined by `lgx.edn`.
- **No Go deps, native build** → the `lg` on `PATH`, and a `:lg-version` mismatch stays the error it is today. Determined by `lgx.edn`.
- **`--target` or `--all`** → build a runtime, because a target-platform `lg` cannot come from `PATH`. Determined by the command line.

So `go` becomes a requirement for cross-builds only. A native build of a project without Go deps never invokes it, which keeps first-contact onboarding unchanged for the common case — a CLI tool with no Go deps.

One consequence for preflight: `gobuild/preflight!` currently requires `:lg-version` only when Go coords exist. A cross-build of a project with **no** Go deps still generates a runtime, and that runtime needs a let-go version to build from — so `:lg-version` becomes required for any cross-build, Go deps or not. Without it there is no defensible default, and silently picking the PATH `lg`'s version would reintroduce exactly the ambient-state dependence this design rejects.

### Configuration

```clojure
:targets {:bin {:out "dist/app_{{os}}_{{arch}}"
                :platforms [{:os "linux" :arch "amd64"}
                            {:os "darwin" :arch "arm64"}]}}
```

Maps rather than `"linux/amd64"` strings: it matches how everything else in `lgx.edn` reads, it validates far better (`:targets :bin :platforms [1] :os — must be one of: ...` instead of a complaint about a slash), and it leaves room for per-platform keys later without re-parsing a string.

`:out` becomes template-aware with `{{os}}` and `{{arch}}` placeholders, both optional. An existing `:out "bin/app"` has neither and keeps producing `bin/app`, so this is backward compatible. Declaring more than one platform with a placeholder-free `:out` is a validation error — the artifacts would overwrite each other, and catching that at load time beats discovering it after four builds.

The CLI keeps slash form, which is what anyone cross-compiling already types:

```
lgx build                        native, unchanged
lgx build --all                  every platform in :platforms
lgx build --target linux/arm64   ad-hoc; no :platforms needed
```

`cmd-build` currently forwards everything after the subcommand straight to `lg` — that is why `lgx build --verbose` fails today with `flag provided but not defined`. So build needs its own flag parsing before forwarding, following the existing `cli/parse-nrepl-args` precedent.

The target joins the runtime hash, so `$LGX_HOME/runtimes/<hash>/` holds one binary per (coord set × let-go version × platform), and platforms never collide.

### `lgx clean`

Explicit only, never automatic. Surprising deletions are worse than disk usage, and it matches how lgx treats every other cache today.

```
lgx clean (--runtimes | --gitlibs | --templates | --all)... [--dry-run]
```

Reports what would be or was removed and the bytes reclaimed. Cross-compilation is what makes this necessary rather than nice: a four-platform release is four 25MB binaries, and every `:lg-version` or driver bump orphans the previous set.

### Three folded fixes

Small, independent, and all touching the same files — so they ship here rather than as their own plans.

**1. `:lg-version` should pass through to `go get`.** `render-go-mod` hardcodes `require github.com/nooga/let-go v<lg-version>`, gluing on the `v`. That makes let-go the only Go module in the build whose version lgx hand-writes instead of letting `go get` resolve — inconsistent with how every other coord is handled, and it blocks targeting a branch or a sha. Verified: `go list -m github.com/nooga/let-go@main` resolves to a pseudo-version, so passing the ref through makes "track upstream main" work with no new configuration. Useful permanently, and specifically useful while `pkg/cli` lives only on an unmerged branch.

A mutable ref needs care in the cache. `"main"` resolves to a different commit over time, but the hash sees the literal string — so the first build would be reused forever, and two machines could cache different commits under one hash. Resolve the ref to its pseudo-version (`go list -m github.com/nooga/let-go@<ref>`) and hash *that*, so the identity in the cache key is the commit rather than the name pointing at it. A semver pin skips the resolution, since it is already immutable.

Note this is why no `:lg-git-url` key is being added: Go rejects version strings containing `/`, so a branch named `integration/go-interop` can never be a module ref, and `LGX_LETGO_REPLACE` (a local checkout) is strictly more capable — it works for private forks, unpushed branches, slash-named branches, and uncommitted changes.

**2. The generated runtime should report its real version.** `render-main-go` emits `cli.Main("dev", "none")`, so every built runtime answers `lg -v` with `lg dev`. Acceptable for a local dev runtime; wrong for a cross-compiled release artifact, and it means a bundled binary cannot report which let-go it contains.

`cli.Main(ver, com)` takes a version and a commit, so both slots get filled from what `go get` actually selected — the resolved pseudo-version from the mutable-ref handling above, split into its version and commit parts. Concretely: `:lg-version "1.11.1"` gives `("1.11.1", "")`; `"main"` resolving to `v1.12.3-0.20260820193935-a6657612002b` gives `("1.12.3-0.20260820193935-a6657612002b", "a6657612002b")`. Under `LGX_LETGO_REPLACE` there is no released version to name, so the pair becomes `("dev", "replace")` — honest about being unreleased, and distinguishable from today's `("dev", "none")`.

**3. `:deps/root` should relocate where a dep's own `lgx.edn` is read.** Currently a dep's `lgx.edn` comes from the *checkout root* (`ensure-lib!` returns `:dir` as the repo root and `ensure-all!` reads `<dir>/lgx.edn`), so a monorepo package consumed with `:deps/root "sqlite"` has its `lgx.edn` silently ignored. Proven both ways: with the config at `<repo>/pkg/lgx.edn` the consumer got nothing; moving the same file to `<repo>/lgx.edn` triggered the expected runtime build.

This predates the Go-deps work and affects any transitive `:deps`, but Go deps make it silent and fatal — the app fails at require time with `unable to load namespace sql` instead of building a runtime.

Both layouts are legitimate. `org.clojure/tools.cli` with `:deps/root "src/main/clojure"` genuinely keeps its metadata at the repo root, which is the case the current behavior was built for. So the fix is to look in `<dir>/<deps-root>/` first and fall back to `<dir>/` when no `lgx.edn` is there — correct for both, and backward compatible.

The fallback covers a *missing config*, never a missing directory: `cache/resolve-source-path` (`lgx/cache.lg:146`) already throws when the `:deps/root` directory does not exist, long before this decision is reached. So this change touches only where the config is read, and leaves source-path semantics alone.

This one gates external consumption of the `letgo-packages` monorepo, so it must land before anything there is tagged.

### Testing

Pure functions get unit tests in `test/lgx/`: platform validation, `:out` templating, the multi-platform-without-placeholder error, target in the hash, build-arg parsing, and `:deps/root` config resolution. Subprocess orchestration and actual cross-builds are verified by scripted end-to-end tasks, which state their prereqs and stop rather than fake a pass.

## File Structure

lgx repo (`/Users/andrew/Projects/lgx`):

- Modify: `lgx/config.lg` — `:platforms` schema inside `:targets :bin`; `:out` placeholder validation; a `platforms` accessor
- Modify: `lgx/cli.lg` — `parse-build-args` for `--target` / `--all`
- Modify: `lgx/gobuild.lg` — target in `runtime-hash`; `GOOS`/`GOARCH` on the build; `:out` templating; `:lg-version` via `go get`; real version in `render-main-go`
- Modify: `lgx/home.lg` — cache-root accessors for the clean command
- Create: `lgx/clean.lg` — cache enumeration, sizing, and removal
- Modify: `lgx.lg` — `cmd-build` multi-target loop and arg parsing; `cmd-clean`; help text; `:deps/root` transitive lookup in `ensure-all!`
- Modify: `test/lgx/config_test.lg`, `test/lgx/cli_test.lg`, `test/lgx/gobuild_test.lg`; Create: `test/lgx/clean_test.lg`
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/knowledge-base/lgx-go-runtimes.md`

---

### Task 1: `:lg-version` passes through to `go get`

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write failing tests**
  `render-go-mod` no longer emits a `require github.com/nooga/let-go v<version>` line for the pinned case (the replace case keeps its `v0.0.0` placeholder plus `replace`, which a `go get` cannot express). `go-get-args`, or a sibling fn, yields `["get" "github.com/nooga/let-go@v1.11.1"]` for `"1.11.1"`, `["get" "github.com/nooga/let-go@main"]` for `"main"`, and the sha verbatim for a 40-character hex string. No let-go `go get` is emitted when `LGX_LETGO_REPLACE` is active.

- [x] **Step 2: Verify fail** — `lgx test test/lgx/gobuild_test.lg`, expected FAIL.

- [x] **Step 3: Implement**
  Prefix a bare semver with `v`; pass anything else through untouched. Order matters in `build-runtime!`: let-go's `go get` must run before `go mod tidy`, alongside the coord `go get`s.

- [x] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [x] **Step 5: Verify end to end**
  With a scratch project declaring a `:go/*` coord and `:lg-version "main"`, and `LGX_LETGO_REPLACE` unset, confirm a runtime builds against upstream main. This will fail until `pkg/cli` is merged upstream — if it does, confirm the failure is `does not contain package .../pkg/cli` (proving the ref resolved) rather than a version-parse error, and note that in the plan.
  > Verified 2026-08-24: `pkg/cli` is still unmerged upstream, and the failure was exactly `module github.com/nooga/let-go@latest found (v1.12.2), but does not contain package github.com/nooga/let-go/pkg/cli` at `go mod tidy`. The generated go.mod carried `require github.com/nooga/let-go v1.12.3-0.20260824031836-fc4bec425943` — `"main"` resolved to that day's commit pseudo-version, so the ref pass-through and the pre-hash resolution both work.
  > Deviation: `render-go-mod` dropped its `lg-version` parameter entirely (3 args now) — with no pinned require line the parameter was dead, and a dead parameter is worse than an arity change contained in the same file.

- [x] **Step 6: Commit**
  `git commit -m "feat(gobuild): resolve :lg-version through go get, so a sha or branch works"`
  > Codex review: two P2s. (1) The editor-source fetch built tag `v<version>` from any pin, so `"main"` → nonexistent `vmain` — fixed in 55391a0 by skipping the fetch (with a warning) for non-semver pins. (2) `lgx-go-runtimes.md` drift — deferred to Task 9, which updates that doc; same-PR rule holds at branch level.

### Task 2: The runtime reports its real version

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write failing tests**
  `render-main-go` takes the version and a build ref and emits them into the `cli.Main` call; the rendered output contains neither `"dev"` nor `"none"` when a real version is given. Keep a case covering what is emitted under `LGX_LETGO_REPLACE`, where there is no released version to name — decide what reads honestly there (a `dev` marker plus the replace path is reasonable) and pin it.
  > Pinned: replace emits `("dev", "replace")` via `letgo-version-parts`, exactly as the Design proposed.

- [x] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [x] **Step 3: Implement**
  Thread the version through `render-main-go` and its `ensure-runtime!` caller. Both arguments are Go string literals, so escape them rather than interpolating raw.
  > Deviation: a sha pin resolves to its pseudo-version at build time only (cache hits stay offline; the hash keeps the literal sha), so its report names a real version too. Also: the pseudo-version regex must accept `.` before the timestamp — the tagged form is `v1.2.3-0.<ts>-<sha>`, only the untagged `v0.0.0-<ts>-<sha>` uses `-`.

- [x] **Step 4: Verify pass and check the binary**
  `lgx test`, then build a runtime and run `<runtime>/lg -v`.
  Expected: the pinned version, not `lg dev`.
  > Verified 2026-08-24: suite green. The pinned case cannot build until `pkg/cli` merges upstream, so the binary check ran under `LGX_LETGO_REPLACE`: main.go embeds `cli.Main("dev", "replace")` and `lg -v` prints `lg dev` — let-go's cli shows the commit slot only when longer than 7 chars, and "replace" is exactly 7. The semver/pseudo-version cases are pinned by unit tests.

- [x] **Step 5: Commit**
  `git commit -m "feat(gobuild): the built runtime reports its real let-go version"`
  > Codex review round 1: two P2s. (1) Runtimes cached before this commit keep reporting `dev` — accepted as advisory: the plan pins today's hash inputs (Task 5), the go-deps pipeline is unreleased, and `lgx clean` (Task 8) is the remedy. (2) MVS could select a newer let-go than the pin, making the embedded version dishonest — fixed: after `go mod tidy`, main.go is re-rendered from `go list -m -f {{.Version}}` (offline), which also covers sha pins without the build-time network resolution the first cut used.

### Task 3: `:platforms` schema and `:out` templating

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write failing tests**
  Valid: `:bin` with `:out` and a `:platforms` vector of `{:os :arch}` maps; `:bin` with `:out` and no `:platforms` (unchanged today's shape). Errors: `:platforms` not a vector; an entry that is not a map; an entry missing `:os` or `:arch`; an unknown key in an entry (`:closed true`, matching the surrounding schemas); a non-string or blank `:os`/`:arch`; duplicate platform entries; and more than one platform with an `:out` carrying no `{{os}}`/`{{arch}}` placeholder. Also test the `platforms` accessor returns `[]` when absent.

- [x] **Step 2: Verify fail** — `lgx test test/lgx/config_test.lg`, expected FAIL.

- [x] **Step 3: Implement**
  Extend `targets-schema` in `lgx/config.lg`. The multi-platform/placeholder rule is a cross-key check over the `:bin` map, so it needs a `[:fn ...]` alongside the structural map in an `[:and ...]` — the same shape `coord-schema` and `task-schema` already use.
  Validate `:os` and `:arch` against Go's real list rather than a hand-kept set: capture `go tool dist list` output once and embed the platform pairs as a constant, with a comment naming the command and the Go version it came from so it can be refreshed.
  > Embedded `go tool dist list` from go1.26.6 (47 pairs). A valid os with a wrong arch (darwin/386) gets its own pair-level error, since both names pass their individual checks.

- [x] **Step 4: Verify pass** — `lgx test`, expected PASS with the existing suite green.

- [x] **Step 5: Commit**
  `git commit -m "feat(config): :platforms and templated :out under :targets/:bin"`
  > Codex review: one P1 — placeholder *presence* was the wrong rule (`dist/{{os}}/app` with linux/amd64 + linux/arm64 still collides). Fixed in a fixup: the check now renders `:out` for every platform and requires the rendered paths to be pairwise distinct, naming the colliding pair in the error.
  > Deviation: `expand-out` (the `{{os}}`/`{{arch}}` template expander) lives in `lgx/config.lg`, not `lgx/gobuild.lg` as Task 5 sketched — the collision validation needs it at load time, and one definition beats two. Task 5's expansion tests are already covered in `config_test.lg`.

### Task 4: Build-arg parsing

**Files:**
- Modify: `lgx/cli.lg`
- Test: `test/lgx/cli_test.lg`

- [x] **Step 1: Write failing tests**
  `parse-build-args` splits lgx's own build flags from the args forwarded to `lg`. Cover: no flags (everything forwards); `--target linux/arm64`; `--target` with a comma-separated list; a repeated `--target`; `--all`; `--target` combined with forwarded lg flags in any order; `--target` with no value (error); an unparseable target value (error naming the expected `os/arch` form); `--all` and `--target` together (error — they contradict).
  Mirror the shape `parse-nrepl-args` already uses, including how it reports errors.

- [x] **Step 2: Verify fail** — `lgx test test/lgx/cli_test.lg`, expected FAIL.

- [x] **Step 3: Implement**
  Return the parsed targets as `{:os :arch}` maps, matching the `lgx.edn` shape, so downstream code has one representation. Only the CLI surface uses slash form.

- [x] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat(cli): parse --target and --all before forwarding build args to lg"`

### Task 5: Target-aware runtime builds

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write failing tests**
  `runtime-hash` includes the target: two different targets with identical coords hash differently; the same target hashes stably; a nil/native target keeps today's hash inputs so existing caches are not invalidated for native builds. `ensure-runtime!` accepts a target. Test the `:out` template expansion separately: `{{os}}`/`{{arch}}` substitution, an unchanged path with no placeholders, and a placeholder appearing more than once.
  > The `:out` expansion tests landed in `config_test.lg` with `config/expand-out` (see Task 3's deviation). `target-env-args` (the env(1) prefix) is the additional pure surface tested here.

- [x] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [x] **Step 3: Implement**
  Thread an optional target through `ensure-runtime!` into the hash and into the build. Go's toolchain is invoked as `go -C <dir> ...` so no path passes through shell quoting; `GOOS`/`GOARCH` therefore need to reach the subprocess as environment variables — follow the `os/sh "env" "KEY=value" ...` pattern already used in `lgx/cache.lg`.
  Set `CGO_ENABLED=0` for cross-builds: a cgo dependency cannot cross-compile without a target C toolchain, and failing at the Go linker produces a far worse message than lgx explaining that a pure-Go driver is required.
  > Only the final `go build` gets the env prefix — go get / tidy / lginterop run host-side and their outputs are platform-independent.

- [x] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [x] **Step 5: Verify a real cross-build**
  Build a runtime for `darwin/arm64` from this host and confirm with `file` that the output is a Mach-O arm64 binary. Repeat for `linux/amd64`.
  > Verified 2026-08-24 (linux/arm64 host, `LGX_LETGO_REPLACE`, empty coord set): darwin/arm64 → `Mach-O 64-bit arm64 executable`; linux/amd64 → `ELF 64-bit LSB executable, x86-64, statically linked`. Two distinct runtime hashes, `env GOOS=... GOARCH=... CGO_ENABLED=0` visible on the build line.

- [x] **Step 6: Commit**
  `git commit -m "feat(gobuild): build runtimes for an explicit target platform"`
  > Codex review round 1: one P1 — `lginterop` via `go run` scans the *host* API, so a `:go/interop` package with platform-specific exports (e.g. `syscall`) would generate host-only bindings that fail on the target. Fixed in a fixup: the tool is now built for the host, then *run* under the target's `GOOS`/`GOARCH` — the go/types source importer reads them from the env at process start, verified empirically (darwin scan emits `Kqueue`, linux scan emits `EpollCreate`). Cross-built a `database/sql` interop runtime for darwin/arm64 to confirm the pipeline.
  > Codex review round 2: two P2s — the interop scan now also mirrors the final build's `CGO_ENABLED` (0 for cross, host default for native; verified with `CGO_ENABLED=1` inherited), and the stale "platform-independent" comment was corrected. Doc drift again deferred to Task 9.
  > Finding: `GOOS=windows` targets cannot build at all — let-go's `pkg/rt/term.go` uses `x/sys/unix` unguarded. Filed as `docs/issues/windows-build-unix-only-term.md`; unix-family targets are unaffected.

### Task 6: `cmd-build` builds every target

**Files:**
- Modify: `lgx.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write failing tests for the pure decisions**
  Both helpers go in `lgx/gobuild.lg`, not `lgx.lg` — `lgx.lg` runs `main` when loaded, so nothing in it is reachable from a test (`lgx/cli.lg` documents this, and it is why `split-go-coords` already lives in `gobuild`). `lgx.lg` keeps only the imperative loop.
  A helper resolving the target list from `(cli-targets, --all?, :platforms)`: explicit `--target` wins; `--all` uses `:platforms`; neither gives the native build (one entry, no target). `--all` with no `:platforms` declared is an error naming the config key. Another helper mapping a target to its output path via the `:out` template.
  > Added a third helper found necessary during e2e: `duplicate-target-out` — an ad-hoc `--target a,b` list bypasses the load-time `:platforms` collision check, so cmd-build re-checks rendered `:out` paths before building (observed both artifacts landing on `bin/app` before the guard).

- [x] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [x] **Step 3: Implement**
  Rework `cmd-build` to parse its own args, resolve the target list, and loop. For each target: ensure the runtime, expand `:out`, inject `-bundle-base`, invoke `lg -b`. Print one status line per target and a summary at the end.
  Per the Design's two-runtimes rule, a cross-build resolves *two* things: the host `lg` that executes `lg -b` (a host-target runtime when the project has Go deps, else `PATH` `lg`) and the target runtime used as `-bundle-base`. Building only the target produces a binary whose namespaces cannot resolve at compile time.
  A cross-build with no Go deps still needs a target runtime — the empty-coord-set path already renders a valid stock module, so route through the same `ensure-runtime!`. A native build with no Go deps must keep using `PATH` `lg` and must not invoke Go at all.
  Fail before building if `LGX_LG` is set on a cross-build of a Go-deps project, with the message from the Design.
  Preflight before any building: a cross-build without `go` on PATH exits 1 with the mise hint, the same message `gobuild/preflight!` already produces; and a cross-build without `:lg-version` exits 1 naming that key, whether or not Go deps are declared.

- [x] **Step 4: Verify pass** — `lgx test`, expected PASS, existing suite green.

- [x] **Step 5: Verify end to end**
  Against a scratch project with `:platforms` declared and no Go deps: `lgx build --all`, then `file` each artifact.
  Then repeat against `letgo-packages/sqlite/example` (Go deps present, `LGX_LETGO_REPLACE` set).
  Expected: correct binaries per platform in both cases; `lgx --verbose build --all` shows `-bundle-base` pointing at the matching per-target runtime while the `lg` being *invoked* is the host one — two different paths on the same line, which is the two-runtimes rule made visible.
  Then run each produced binary on a machine or container of its platform where possible; at minimum confirm the host-platform artifact runs and prints the expected output. A binary that builds but cannot resolve its namespaces is the exact failure the host runtime prevents, and only running it proves the absence.
  > Verified 2026-08-24. No-deps scratch, `--all` over linux/arm64+darwin/arm64+linux/amd64: three correct artifacts (`file` confirms ELF aarch64 / Mach-O arm64 / ELF x86-64), host one runs. sqlite example: verbose line shows host runtime `1a4c880…/lg` invoked with `-bundle-base …/9fac42b…/lg` (darwin/arm64) — the two-runtimes rule on one line. `--target linux/arm64` (host platform, explicit target) produced a binary that runs the example's full check suite: "all checks passed", proving namespace resolution and target-scanned interop bindings. Native build re-checked: no Go invocation, PATH lg, `:out` byte-for-byte.

- [x] **Step 6: Commit**
  `git commit -m "feat: lgx build --target and --all produce per-platform binaries"`
  > Codex review round 1: one P1, two P2s, all fixed in a fixup. (1) A user `-bundle-base` with multiple targets silently produced N copies of one platform — now rejected. (2) `cross-preflight!` no longer runs when the user supplies the base (nothing gets generated). (3) cmd-build now validates everything cheap — `:main`, `:bin`, `:out` collisions, base/target contradictions — before deps resolve or any runtime builds.

### Task 7: `:deps/root` relocates the dep's `lgx.edn`

**Files:**
- Modify: `lgx.lg`
- Test: `test/lgx/config_test.lg` or `test/lgx/gobuild_test.lg`, whichever suits the extracted helper

- [x] **Step 1: Write failing tests**
  Extract the "where does this dep's config live" decision into a pure helper taking the checkout dir and the coord, returning the directory to read `lgx.edn` from. Cover: no `:deps/root` gives the checkout root; `:deps/root` whose directory holds an `lgx.edn` gives that subdirectory; `:deps/root` whose directory has no `lgx.edn` falls back to the checkout root (the `tools.cli` layout).
  Do not test a missing `:deps/root` directory — `cache/resolve-source-path` throws on that first, so the case is unreachable here.
  The fallback is what keeps this backward compatible — make sure a test pins it.
  > Helper is `config/dep-config-dir`, tested in `config_test.lg`.

- [x] **Step 2: Verify fail** — `lgx test`, expected FAIL.

- [x] **Step 3: Implement**
  Use the helper at the `lgx-edn?` check in `ensure-all!`, and use the same directory as the `:base` for the children it yields, so a relative `:local/root` or `:go/local` in that config resolves against the package directory rather than the repo root. Getting the base wrong here would break monorepo sibling deps in a way tests on the read path alone would not catch — cover it.
  Leave `declared-children` (the `deps.edn`/`project.clj` ladder) on the checkout root: those files belong to other tools with their own conventions.

- [x] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [x] **Step 5: Verify end to end**
  Build a scratch monorepo: a root with no `lgx.edn`, a `pkg/` subdirectory whose `lgx.edn` declares `database/sql {:go/interop "sql"}`, and a consumer depending on it with `:local/root` plus `:deps/root "pkg"`.
  Expected: the consumer triggers a runtime build. Before this fix the same setup runs with no build and no warning, which is the bug.
  > Verified 2026-08-24: `lgx install` in the consumer prints `Building custom lg runtime...` — the package's Go coord is discovered through `:deps/root`.

- [x] **Step 6: Commit**
  `git commit -m "fix: read a dep's lgx.edn from :deps/root when it lives there"`

### Task 8: `lgx clean`

**Files:**
- Create: `lgx/clean.lg`
- Modify: `lgx.lg`, `lgx/home.lg`
- Test: `test/lgx/clean_test.lg`

- [ ] **Step 1: Write failing tests**
  Keep the pure parts separable: a helper turning flags into the list of cache roots to act on, and byte-size formatting.
  The flag contract, pinned: category flags are additive and may be combined (`--runtimes --templates` cleans both); `--all` means every category; **bare `lgx clean` is an error** listing the categories, because a no-argument command that deletes everything is the wrong default for a destructive operation. Test each of these. Directory walking and removal are side-effecting; cover them with a test that builds a throwaway tree under `LGX_HOME` and asserts what survives.

- [ ] **Step 2: Verify fail** — `lgx test test/lgx/clean_test.lg`, expected FAIL.

- [ ] **Step 3: Implement**
  Enumerate each cache root's leaves, size them, and remove them. `--dry-run` prints exactly what would be removed and changes nothing. Report reclaimed bytes per cache and a total.
  Never delete anything outside `$LGX_HOME` — resolve and check the prefix before removing, since a misconfigured `LGX_HOME` should fail loudly rather than delete a home directory.
  Add `clean` to `reserved-task-names` in `lgx/config.lg` so a project task cannot shadow it, and to the help text.

- [ ] **Step 4: Verify pass** — `lgx test`, expected PASS.

- [ ] **Step 5: Verify manually**
  With a populated `LGX_HOME`, run `lgx clean --runtimes --dry-run`, confirm nothing was removed, then run it for real and confirm the reported bytes match the reclaimed space.

- [ ] **Step 6: Commit**
  `git commit -m "feat: lgx clean for the runtimes, gitlibs, and template caches"`

### Task 9: Docs

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/knowledge-base/lgx-go-runtimes.md`

- [ ] **Step 1: Write the docs** (use /writing-clearly)
  `README.md`: `:platforms` and templated `:out` under `:targets`; `lgx build --target`/`--all`; `lgx clean` in the commands table; the requirement that cross-compiling needs `go` while native builds do not; the pure-Go-driver rule; `:deps/root` now relocating a dep's `lgx.edn`; the state-layout note that runtimes are keyed per platform.
  `docs/ARCHITECTURE.md`: the target dimension in the runtime hash, the build-time decision table for which runtime a command uses, and the `:deps/root` change in the transitive-resolution section.
  `docs/knowledge-base/lgx-go-runtimes.md`: cross-compilation mechanics, `CGO_ENABLED=0` and why cgo drivers break, the measured cold/warm build costs, cache growth under multiple targets, and `lgx clean`. Keep the `Verify against:` footer current.

- [ ] **Step 2: Commit**
  `git commit -m "docs: cross-compilation, lgx clean, and the :deps/root fix"`

### Task 10: Full verification

- [ ] **Step 1: Regression**
  In `/Users/andrew/Projects/lgx`: `lgx test`.
  Expected: full suite green.

- [ ] **Step 2: Native paths unchanged**
  Run `lgx run` in two examples that have no Go deps and confirm behavior is identical to before this plan, with no Go invocation. Compare against the released `lgx` binary for any example that already fails, so a pre-existing failure is not misread as a regression.

- [ ] **Step 3: The full cross-compilation story**
  In `letgo-packages/sqlite/example` with `LGX_LETGO_REPLACE` set: `lgx build --all` with `:platforms` covering the CI matrix. Confirm one correct binary per platform, and that re-running is fast because the runtimes are cached.

- [ ] **Step 4: Record findings**
  Append anything surprising to `docs/knowledge-base/lgx-go-runtimes.md` and commit.
