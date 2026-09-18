# Explicit `:lg-runtime` Mode Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the choice between the installed `lg` and a Go-built `lg` an explicit `:lg-runtime` key in `lgx.edn`, turn today's dep-graph inference into validation with clear errors, and add `lgx info` to print the resulting decision.

**Tech Stack:** let-go (`.lg`), the existing `lgx.spec` schema validator, bash e2e harness (`tests/e2e.sh`), Go toolchain (manual verification only).

---

## Design

### The problem

`:lg-version` means two different things today, decided by the transitive
dep graph rather than by the user:

- With no `:go/*` coord anywhere in the tree, it is an *assertion* checked
  against `lg -v` on PATH (`check-lg-version!`, `lgx.lg:403`). A sha or
  branch pin can never match a released binary, so `build`/`test` fail late
  with a "mismatch" that reads like the user's fault.
- With any `:go/*` coord, even one declared two deps down, it is a *build
  spec* handed to `go get`; PATH `lg` is ignored and the version check is
  skipped (`apply-runtime!`, `lgx.lg:415-446`). Nothing in the user's own
  `lgx.edn` says this happened.

`LGX_LG` flips meaning the same way: an override in the first world, a
"disable the runtime, Go namespaces will not resolve" warning in the second
(`gobuild/runtime-action`), and an error for cross-builds. A cross-build of a
project *without* Go deps is a third, mixed shape: PATH `lg` compiles the
bundle while a Go-built target runtime ships as its base.

### The model

One config key, two disjoint modes. lgx *validates* the mode against what the
project needs; it never *switches* mode on its own.

| `:lg-runtime` | Go toolchain | `lg` that runs every command | `:lg-version` accepted |
|---|---|---|---|
| `:installed` (default when absent) | never invoked | PATH or `LGX_LG`, checked against `lg -v` | released semver only, or absent |
| `:built` | always | `$LGX_HOME/runtimes/<hash>/lg`, host and cross target from the same pin | required: semver, full sha, or branch |

Rules, in the order they fire:

**At config load** (`lgx/config.lg`, pure, unit-tested):

1. `:lg-runtime` must be `:installed` or `:built` when present.
2. `:built` without `:lg-version` is an error. This holds even under
   `LGX_LETGO_REPLACE`: a pin is inert there (the cache key is the checkout
   path and `go get` is skipped), so requiring it keeps validation free of
   environment reads.
3. `:installed` (explicit or default) with a non-semver `:lg-version` is an
   error that points at `:built`.

**At command time** (`apply-runtime!` in `lgx.lg`, after the basis resolves,
because only then are the transitive Go coords known):

- `:installed` with any Go coord in the tree: hard error naming each coord
  and the dep that introduced it, then the one-line fix. Otherwise
  `check-lg-version!` runs exactly as today. Go is never invoked.
- `:built`: a user-set `LGX_LG` is an error (today's warning goes away).
  Then the Go-on-PATH preflight, `ensure-runtime!` with the project's Go
  coords (an empty set when there are none, which renders a stock module at
  the pin), `select-runtime!`. This is the path for run, repl, nrepl, test,
  build, install and tasks alike.
- `lgx build --target`/`--all` under `:installed` without a user-supplied
  `-bundle-base` is an error naming the fix. A user `-bundle-base` replaces
  only the *target* runtime, so its meaning differs by mode: under
  `:installed` it makes a cross-build possible with no Go at all (the
  installed `lg` compiles, the user's base ships); under `:built` the host
  side is still the built runtime, so Go is still required. The
  cross-plus-`LGX_LG` special case in `cmd-build` and
  `gobuild/cross-preflight!` both disappear, subsumed by the `:built` rules.

**Provenance.** `ensure-all!` already knows which dep's `lgx.edn` each Go
coord came from (the `lib` in scope when a dep's children are split). It
returns a `:go-origins` map, coord lib to declaring dep lib, `nil` for coords
in the project's own `lgx.edn`. The basis carries it; the error formatter and
`lgx info` read it.

### Exact messages

Pure formatters in `lgx/gobuild.lg` so each is unit-tested byte for byte.
`explicit?` is whether `lgx.edn` sets the key; the default reads
`:installed (the default)`, the explicit form reads `lgx.edn sets :lg-runtime :installed`.

`installed-go-deps-error [go-pairs go-origins explicit?]`, coords sorted by lib:

```
error: this project needs an lg built with the Go toolchain, but :lg-runtime is :installed (the default)
  Go deps: database/sql (via abogoyavlensky/letgo-sql), modernc.org/sqlite (via abogoyavlensky/letgo-sqlite)
  add :lg-runtime :built to lgx.edn (needs `go` on PATH), or drop the dep.
```

A coord declared by the project itself has no `(via ...)` suffix.

`installed-cross-error [explicit?]`:

```
error: cross-compiling builds a target-platform lg with the Go toolchain, but :lg-runtime is :installed (the default)
  add :lg-runtime :built to lgx.edn (needs `go` on PATH), or pass -bundle-base <lg> yourself.
```

`built-lg-override-error [lg]`:

```
error: LGX_LG is set to /x/lg, but lgx.edn sets :lg-runtime :built - the built runtime is the lg for this project.
  unset LGX_LG (use LGX_LETGO_REPLACE to build against a let-go checkout).
```

Config-load errors, in the existing `{:path :msg}` shape:

- `{:path [:lg-runtime] :msg ":built needs :lg-version - the built lg links let-go itself, so the version has to be pinned"}`
- `{:path [:lg-version] :msg "\"main\" is not a released version, and the installed lg is checked with `lg -v`; pin a semver, or set :lg-runtime :built to build let-go at this ref"}` (the quoted value is the actual pin)
- the enum error the spec ns already produces: `must be one of: :installed, :built, got :foo`

### `lgx info`

A read-only status command. It resolves the basis like `lgx install` (so a
cold cache fetches git deps and prints the install block) but never builds a
runtime. Output goes to stdout as aligned `key  value` lines, one per line,
no color, in this order:

```
project       /abs/project/root
lg-runtime    installed (default)          | installed | built
lg-version    1.12.2                       | (none)
lg            1.12.2 (/path/to/lg)         ; the lg the next command would run
version       ok | mismatch: lg 1.12.2 does not match :lg-version 1.11.1 | skipped (no :lg-version) | skipped (LGX_SKIP_VERSION_CHECK) | skipped (lg not found or a dev build)
go-deps       (none)
```

Under `:built` the `version` line is replaced by `go` and the `lg` line
reports the cache:

```
lg            1.12.3-0.20260907055650-f26eb4972997 (/home/u/.lgx/runtimes/4da83e1444a08f27/lg)
              | not built yet (/home/u/.lgx/runtimes/4da83e1444a08f27/lg)
go            go1.26.7 (/home/u/.local/bin/go)   | not on PATH
let-go        replace /path/to/checkout          ; only when LGX_LETGO_REPLACE is set
LGX_LG        /x/lg (conflicts with :lg-runtime :built)   ; only when the user set it
go-deps       database/sql interop "sql" (via abogoyavlensky/letgo-sql)
              modernc.org/sqlite v1.57.0 (via abogoyavlensky/letgo-sqlite)
```

The `lg` line under `:built` needs the cache path. For a semver or full-sha
pin that is pure. For a mutable pin (branch or tag) the path depends on a
`go list -m` network call, and `go!` exits the process on failure, so `info`
does not resolve it at all and prints
`lg            unresolved (:lg-version "main" is a branch, resolved at build time; run lgx install)`.
`lgx info` never exits non-zero for a state it can describe; only an invalid
`lgx.edn` or a failed dep fetch does. It honors `--with` like
`install`. `--verbose` stays the per-invocation trace; `info` complements it.

### Out of scope

- Pinning a Go version. Go's `toolchain` directive already upgrades a too-old
  local Go; a project that wants a fixed Go pins it in `.mise.toml`.
- `lgx new` templates. They are external repos pinned by sha; `:installed`
  is the default, so they keep working.
- letgo-packages examples and READMEs (separate repo).
- The "Building custom lg runtime..." header printed on every `:go/local`
  rebuild.

### Testing strategy

Unit tests cover the schema, the two cross-key rules, and the three error
formatters. E2E scenarios cover every validation path that needs no Go:
each fires before any Go invocation, and the harness already exports
`LGX_LG`, which is exactly the `:built` override error. The real `:built`
path (runtime build, `lgx info` on a cache hit, `lgx build`) is verified
manually against the sqlite example in letgo-packages, as the Go pipeline is
today.

## File Structure

- Modify `lgx/config.lg`: `:lg-runtime` in the schema, `semver-version?`
  (moved here from gobuild, since config cannot require gobuild), the
  cross-key rule `lg-runtime-errors`, accessor `lg-runtime`.
- Modify `lgx/gobuild.lg`: drop `semver-version?` (use `config/`), drop
  `runtime-action` and `cross-preflight!`, add the three error formatters,
  narrow `preflight!` to the Go-on-PATH check, add `go-path`/`go-version`
  probes, and factor the cache-path computation out of `ensure-runtime!`
  into `runtime-paths` so `info` can locate the binary without building.
- Modify `lgx.lg`: `:go-origins` through `ensure-all!` and `basis`,
  rewrite `apply-runtime!`, simplify `cmd-build`'s cross checks, add
  `cmd-info`, dispatch, help row.
- Modify `lgx/completion.lg`: add `info` to `builtin-commands`.
- Modify `test/lgx/config_test.lg`, `test/lgx/gobuild_test.lg`,
  `test/lgx/completion_test.lg`.
- Modify `tests/e2e.sh`: scenarios 120-126.
- Modify `README.md`, `docs/ARCHITECTURE.md`,
  `docs/knowledge-base/lgx-go-runtimes.md`,
  `docs/knowledge-base/lgx-dev-workflow.md`,
  `docs/knowledge-base/lgx-go-wrappers.md`,
  `examples/wails-desktop/lgx.edn`.

Run unit tests from the repo root with `bin/lgx test` after `make build`,
or a single file with `bin/lgx test test/lgx/config_test.lg`. Run the full
suite with `make test`.

---

### Task 1: `:lg-runtime` in the config schema

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests**
  In `config_test.lg` add:
  - `load-accepts-lg-runtime-installed` and `load-accepts-lg-runtime-built`
    (the latter with `:lg-version "1.12.2"`): `load-cfg` round-trips the map.
  - `load-rejects-unknown-lg-runtime`: `{:lg-runtime :foo}` yields
    `[{:path [:lg-runtime] :msg "must be one of: :installed, :built, got :foo"}]`.
  - `load-rejects-built-without-lg-version`: `{:lg-runtime :built}` yields the
    `:built needs :lg-version` error from the Design section.
  - `load-rejects-non-semver-pin-when-installed`: `{:lg-version "main"}` (key
    absent) and `{:lg-runtime :installed :lg-version "f26eb497299760e93ce430302f13ab3a954eab64"}`
    both yield the `is not a released version` error, quoting the pin.
  - `load-accepts-non-semver-pin-when-built`: `{:lg-runtime :built :lg-version "main"}` round-trips.
  - `lg-runtime-accessor`: `(config/lg-runtime {})` is `:installed`,
    `(config/lg-runtime {:lg-runtime :built})` is `:built`.
  - `semver-version?` moved: `(config/semver-version? "1.11.1")` true,
    `"main"` and a 40-char sha false, `"1.11.1-rc1"` true (matches the
    existing regex).
  - Update `load-rejects-unknown-top-level-key`: the allowed-keys list gains
    `:lg-runtime` after `:lg-version`.

- [x] **Step 2: Run the tests to verify they fail**
  Run: `make build && bin/lgx test test/lgx/config_test.lg`
  Expected: FAIL on the new tests (unknown key `:lg-runtime`, missing `config/lg-runtime`).

- [x] **Step 3: Implement**
  In `config.lg`:
  - Move `semver-version?` from `gobuild.lg` verbatim (public, same
    docstring) next to the other pure helpers.
  - Add `[:lg-runtime {:optional true} [:enum :installed :built]]` to
    `lgx-schema` right after `:lg-version`.
  - Add `lg-runtime-errors`, a root-level `[:fn ...]` alongside
    `with-refs-errors`, returning a vector of the two cross-key errors from
    the Design section. Structural checks have already passed when it runs,
    so `:lg-version` is a non-blank string or absent.
  - Add `lg-runtime`: `(or (:lg-runtime cfg) :installed)`.
  In `gobuild.lg`: delete `semver-version?` and point `letgo-module-ref`,
  `mutable-letgo-ref?` and `commit-sha?`'s neighbours at
  `config/semver-version?`. In `lgx.lg`, `install-letgo-source!` uses
  `config/semver-version?`.

- [x] **Step 4: Run the tests to verify they pass**
  Run: `make build && bin/lgx test`
  Expected: PASS, including the untouched gobuild tests.

- [x] **Step 5: Commit**
  `git commit -am "feat(config): :lg-runtime key with cross-key validation"`

### Task 2: Error formatters and probes in gobuild

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write the failing tests**
  In `gobuild_test.lg` add a section "mode errors":
  - `installed-go-deps-error-names-origins`: two coords, one with origin
    `'abogoyavlensky/letgo-sql`, one project-declared (`nil`), `explicit?`
    false. Assert the exact three-line string from the Design section, coords
    sorted by lib, no `(via ...)` on the project-declared one, trailing
    newline.
  - `installed-go-deps-error-explicit-wording`: with `explicit?` true the
    first line ends `but lgx.edn sets :lg-runtime :installed`.
  - `installed-cross-error-default-and-explicit`: both wordings.
  - `built-lg-override-error-quotes-the-path`: exact string.
  - Delete the tests for `runtime-action` if any exist (grep first; none are
    listed today).

- [x] **Step 2: Run the tests to verify they fail**
  Run: `bin/lgx test test/lgx/gobuild_test.lg`
  Expected: FAIL, functions undefined.

- [x] **Step 3: Implement**
  In `gobuild.lg`, in the "Wiring the runtime into the commands" section:
  - Add the three pure formatters with the signatures and strings from the
    Design section. Share one helper for the mode phrase
    (`:installed (the default)` vs `lgx.edn sets :lg-runtime :installed`).
  - Leave `runtime-action`, `cross-preflight!` and `preflight!` untouched in
    this task so `make build` still bundles `lgx.lg`, which calls them; Task 3
    deletes the first two and narrows the third when it rewrites the callers.
  - Add `go-path`: the resolved `go` binary path via the same `command -v`
    shape as `go-available?`, or nil; make `go-available?` call it.
  - Add `go-version`: the second token of `go version` (`go1.26.7`), or nil.
  - Factor the path computation out of `ensure-runtime!` into
    `runtime-paths [go-pairs lg-version target verbose?]` returning
    `{:dir :src :out :live? :lg-version}` (resolving a mutable ref exactly as
    `ensure-runtime!` does today). `ensure-runtime!` calls it and keeps its
    behaviour and signature. `info` calls it and checks `(file-exists? out)`.

- [x] **Step 4: Run the tests to verify they pass**
  Run: `make build && bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -am "feat(gobuild): mode error formatters, go probes, runtime-paths"`

### Task 3: Mode-driven `apply-runtime!` and `cmd-build`

**Files:**
- Modify: `lgx.lg`

- [x] **Step 1: Thread `:go-origins` through resolution**
  In `ensure-all!`, add a `go-origins` loop binding, seeded with every
  top-level Go coord lib mapped to `nil`, and extended with
  `[coord-lib lib]` for each pair in a dep's `(:go-pairs split)`. Return it
  as `:go-origins`. In `basis`, carry it into the returned map. `cmd-install`
  passes `{:go-coords go-coords :go-origins go-origins}` to `apply-runtime!`,
  and calls it *outside* the `(if (empty? coords) ...)` branch: a `:built`
  project with no deps must still have `lgx install` warm its runtime and
  reject `LGX_LG`. With no coords the basis is
  `{:go-coords [] :go-origins {}}`.

- [x] **Step 2: Rewrite `apply-runtime!`**
  Keep the signature `[cfg basis severity verbose?]` and the docstring's
  role ("the single place the runtime enters a command"), rewritten for the
  two modes. Body per the Design section: `case` on `(config/lg-runtime cfg)`
  with `explicit?` as `(contains? cfg :lg-runtime)`. `:installed` errors on
  `(seq go-pairs)` via `installed-go-deps-error`, then `check-lg-version!`,
  returns nil. `:built` errors on `(gobuild/user-set-lg?)` via
  `built-lg-override-error` (before the Go preflight, so the check needs no
  Go), then `preflight!`, `ensure-runtime!`, `select-runtime!`, the existing
  verbose line, returns the path.
  In `gobuild.lg`, now that the callers are rewritten: delete
  `runtime-action` and `cross-preflight!`, and narrow `preflight!` to `[]`
  with only the Go-on-PATH check and its existing message (the pin is
  guaranteed by config load).

- [x] **Step 3: Simplify `cmd-build`**
  Replace the `cross-preflight!` call with: when `cross?` and not
  `user-base?` and the mode is `:installed`, write
  `installed-cross-error` and exit 1. Delete the `cross? + go-pairs +
  user-set-lg?` block (the `:built` branch of `apply-runtime!` now rejects
  `LGX_LG` for every command). The per-target `base` cond is unchanged.
  Update the comments that mention "with Go deps" to say "under `:built`".

- [x] **Step 4: Smoke-test by hand**
  Run from the repo root: `make build && cd examples/hello && ../../bin/lgx run`
  Expected: unchanged behaviour, the hello output.
  Run: `cd examples/wails-desktop && ../../bin/lgx run 2>&1 | head -3`
  Expected: exit 1 and the `installed-go-deps-error` text naming
  `abogoyavlensky/letgo-wails` as the origin (the example has no
  `:lg-runtime` yet; Task 6 adds it).
  > Deviation: the wails example pins a *sha*, so under the plan's own
  > config-load rule 3 it now fails earlier with the `is not a released
  > version` error, not the go-deps error. The go-deps error (with
  > `(via abogoyavlensky/letgo-wails)`) was verified against a temp copy of
  > the example pinned to `1.12.2` instead.
  > Deviation: the two `runtime-action` tests the plan assumed absent
  > existed in `gobuild_test.lg`; deleted here with the function.

- [x] **Step 5: Run the existing suite**
  Run: `make test`
  Expected: all unit and e2e tests pass (scenario 4b still uses a semver pin).

- [x] **Step 6: Commit**
  `git commit -am "feat: :lg-runtime decides the lg; inference becomes validation"`

### Task 4: E2E scenarios for the validation paths

**Files:**
- Modify: `tests/e2e.sh` (append after scenario 119, before the closing `fi`
  of the `supports_source_paths` block if that is where 119 lives; check)

None of these invoke Go. Each scenario uses a fresh `mktemp -d` project and
`LGX_HOME`, and `main.lg` is `(println :ran)` where a run is attempted.

> Deviation: scenario 121 needs `make_declaring_repo`, which is defined inside
> the `supports_source_paths` block, so it sits there right after 119; the
> Go-free scenarios 120 and 122-125 follow the block's closing `fi` so they
> run on every lg.

- [x] **Step 1: Scenario 120, a top-level Go coord under the default mode**
  `lgx.edn`: `{:paths ["."] :main "main.lg" :lg-version "1.12.2" :deps {modernc.org/sqlite {:go/version "v1.57.0"}}}`.
  `lgx run` exits non-zero; output contains
  `needs an lg built with the Go toolchain, but :lg-runtime is :installed (the default)`,
  `Go deps: modernc.org/sqlite` with no `(via`, and `add :lg-runtime :built to lgx.edn`.
  `lgx install` exits non-zero with the same first line.

- [x] **Step 2: Scenario 121, a Go coord introduced by a dep**
  Seed a dep with `make_declaring_repo "$fix/lib-a.git" liba 'lgx.edn={:paths ["src"] :deps {modernc.org/sqlite {:go/version "v1.57.0"}}}'`.
  Project depends on it by sha, `:lg-version "1.12.2"`. `lgx run` exits
  non-zero; output contains `modernc.org/sqlite (via test/lib-a)`.

- [x] **Step 3: Scenario 122, `:built` without a pin is a config error**
  `lgx.edn`: `{:lg-runtime :built}`. `lgx run` exits non-zero; output contains
  `invalid lgx.edn` and `:built needs :lg-version`.

- [x] **Step 4: Scenario 123, a sha pin under the default mode is a config error**
  `lgx.edn`: `{:lg-version "f26eb497299760e93ce430302f13ab3a954eab64"}`.
  Output contains `is not a released version` and `set :lg-runtime :built`.

- [x] **Step 5: Scenario 124, cross-build under `:installed`**
  `lgx.edn`: `{:paths ["."] :main "main.lg" :lg-version "1.12.2" :targets {:bin {:out "bin/app"}}}`.
  `lgx build --target linux/arm64` exits non-zero; output contains
  `cross-compiling builds a target-platform lg` and `add :lg-runtime :built`.
  Assert `bin/` was not created.

- [x] **Step 6: Scenario 125, `LGX_LG` under `:built` is an error**
  `lgx.edn`: `{:paths ["."] :main "main.lg" :lg-runtime :built :lg-version "1.12.2"}`.
  The harness exports `LGX_LG`, so `lgx run` exits non-zero with
  `LGX_LG is set to` and `sets :lg-runtime :built`. Assert the output does
  not contain `Building custom lg runtime` (the check fires before any
  build) and that `$home/runtimes` does not exist. Then `lgx install` on the
  same project (it has no deps) exits non-zero with the same error: this
  proves `cmd-install` reaches `apply-runtime!` without any coords.

- [x] **Step 7: Run the e2e suite**
  Run: `make test`
  Expected: all scenarios pass, the count printed at the end grows by the
  new assertions.

- [x] **Step 8: Commit**
  `git commit -am "test(e2e): :lg-runtime validation scenarios"`

### Task 5: `lgx info`

**Files:**
- Modify: `lgx.lg`, `lgx/completion.lg`
- Test: `test/lgx/completion_test.lg`, `tests/e2e.sh`

- [x] **Step 1: Write the failing tests**
  - `completion_test.lg`: the expected `builtin-commands` vector gains
    `"info"` (alphabetical, after `"help"`).
  - `tests/e2e.sh` scenario 126: project `{:paths ["."] :lg-version "1.12.2"}`
    with the harness `LGX_LG`. `lgx info` exits 0; output contains
    `lg-runtime    installed (default)`, `lg-version    1.12.2`, a `lg  `
    line containing `(` and the `LGX_LG` path, a `version  ` line (the harness
    lg is whatever mise resolved, so assert only the label), and
    `go-deps       (none)`. Then with `{:lg-runtime :installed}` added assert
    `lg-runtime    installed` without `(default)`. Then with
    `{:paths ["."] :lg-runtime :built :lg-version "1.12.2"}` assert exit 0,
    `lg-runtime    built`, a `lg  ` line containing `not built yet` and
    `/runtimes/`, and `LGX_LG  ` with `conflicts with :lg-runtime :built`.
    Then with `:lg-version "main"` assert exit 0 and a `lg  ` line containing
    `unresolved` and `is a branch` (no Go call is made, so this passes on a
    host without Go).

- [x] **Step 2: Run the tests to verify they fail**
  Run: `bin/lgx test test/lgx/completion_test.lg`
  Expected: FAIL on the command list.

- [x] **Step 3: Implement `cmd-info`**
  In `lgx.lg`:
  - `cmd-info [verbose? with]`: `find-project!`, `load-config!`,
    `overlay-basis` with the `--with` names (no auto contexts, like
    install), `print-installs!`, then print the lines from the Design
    section. Label column padded to 14 with `pad-right`. Build the lines in a
    pure `info-lines [cfg basis env]` helper that takes a map of the probed
    values (`lg-version`, `lg-path`, `go-version`, `go-path`, `runtime-out`,
    `runtime-built?`, `replace-path`, `user-lg`, `skip-check?`) so the
    rendering is testable without subprocesses; do the probing in `cmd-info`.
  - The `version` line reuses `version/check` with the same `:ok`/`:skip`/
    `:mismatch` outcomes; `LGX_SKIP_VERSION_CHECK` set prints
    `skipped (LGX_SKIP_VERSION_CHECK)`.
  - Under `:built` with an immutable pin (`config/semver-version?` or a
    40-hex sha) and no `LGX_LETGO_REPLACE`, `gobuild/runtime-paths` gives
    `:out`; the `lg` line is `<version from lg -v on :out> (<out>)` when the
    file exists, else `not built yet (<out>)`. With a mutable pin, skip
    `runtime-paths` and print the `unresolved` line from the Design section.
    Under `LGX_LETGO_REPLACE` the path is pure (the key is the checkout
    path), so `runtime-paths` is safe. Never call `ensure-runtime!`, and
    never invoke `go` from `info` beyond the `go version` probe.
  - `go-deps`: one line per pair, sorted by lib: `lib`, then `vX` for
    `:go/version`, `local <dir>` for `:go/local`, `interop "<alias>"` when
    present, then `(via <origin>)` when the origin is non-nil. Continuation
    lines are indented to the value column.
  - Dispatch `"info"` and add the help row
    `  lgx info                     Show which lg runs this project and why (:lg-runtime, :lg-version, Go deps)`.
  - `completion.lg`: add `"info"` to `builtin-commands`.
  > Deviation: `runner/lg-version` gained a `[bin]` arity so `info` can probe
  > the cached runtime binary under `:built` (the no-arg form honors `LGX_LG`,
  > which is exactly the wrong lg in that mode).

- [x] **Step 4: Run the tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -am "feat: lgx info prints the runtime decision"`

### Task 6: Docs and the wails example

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`,
  `docs/knowledge-base/lgx-go-runtimes.md`,
  `docs/knowledge-base/lgx-dev-workflow.md`,
  `docs/knowledge-base/lgx-go-wrappers.md`,
  `examples/wails-desktop/lgx.edn`

Use /writing-clearly. Each doc ends with a `Verify against:` footer; keep it
accurate.

- [ ] **Step 1: `examples/wails-desktop/lgx.edn`**
  Add `:lg-runtime :built` after `:lg-version`. Verify with
  `cd examples/wails-desktop && ../../bin/lgx info` (exit 0, `lg-runtime built`;
  the runtime need not be built).

- [ ] **Step 2: README**
  - Requirements: Go is needed "only if `lgx.edn` sets `:lg-runtime :built`",
    drop the "declares Go deps" phrasing.
  - Command table and the annotated `lgx.edn` reference: add `lgx info` and
    `:lg-runtime`.
  - New `### :lg-runtime` section before `### :lg-version`: the mode table
    from the Design section, the three validation errors in one sentence
    each, and that a user `-bundle-base` needs neither.
  - `### :lg-version`: split into the two modes; under `:installed` only a
    released semver; under `:built` any ref Go accepts.
  - `#### Go deps`: replace "Declaring one makes lgx build a custom lg" with
    "Go deps need `:lg-runtime :built`; lgx refuses to run otherwise and names
    the dep". Add `:lg-runtime :built` to the example config.
  - Cross-compilation rules: "Cross-builds need `:lg-runtime :built`"
    replaces "need the Go toolchain and `:lg-version`"; the `LGX_LG`
    sentence becomes "`LGX_LG` is rejected under `:built`".
  - Env table, `LGX_LG` row: "Ignored with an error when `:lg-runtime` is
    `:built`."

- [ ] **Step 3: `docs/ARCHITECTURE.md`**
  - Runtime model: the mode key decides which of the two `lg`s runs user
    code.
  - Components list: `cmd-info` in `lgx.lg`.
  - `lgx build` step 4 and the decision table: rows become
    `:installed native`, `:installed + user -bundle-base`, `:built native`,
    `:built cross`; the `:installed cross` row is an error.
  - `apply-runtime!` bullets: rewrite for the two modes and the
    `:go-origins` map.

- [ ] **Step 4: Knowledge base**
  - `lgx-go-runtimes.md`: intro sentence ("When a project sets
    `:lg-runtime :built`..."), the Rebuild policy `LGX_LG` bullet (now an
    error), the Troubleshooting rows for `declares Go deps but no :lg-version`
    (now the config-load error) and the `LGX_LG` cross-build row.
  - `lgx-dev-workflow.md`: the `LGX_LG` paragraph, "for a `:built` project
    `LGX_LG` is rejected; use `LGX_LETGO_REPLACE`".
  - `lgx-go-wrappers.md`: both pin snippets gain `:lg-runtime :built`; the
    consumer snippet under "Where wrappers live" too.

- [ ] **Step 5: Check for stale claims**
  Run: `grep -rn "declares Go deps\|Go deps, native\|runtime-action\|cross-preflight" README.md docs/`
  Expected: no hits that describe inference as current behaviour.

- [ ] **Step 6: Commit**
  `git commit -am "docs: :lg-runtime mode, lgx info, wails example"`

### Task 7: Manual verification of the `:built` path

**Files:** none in this repo. Uses `~/Projects/letgo-packages/sqlite/example`
(separate repo; the edit there is not committed by this plan).

- [ ] **Step 1: The error without the key**
  `cd ~/Projects/letgo-packages/sqlite/example && ~/Projects/lgx/bin/lgx run`
  Expected: exit 1, `Go deps: database/sql (via abogoyavlensky/letgo-sql), github.com/abogoyavlensky/letgo-packages/sql/shim (via abogoyavlensky/letgo-sql), modernc.org/sqlite (via abogoyavlensky/letgo-sqlite)`.

- [ ] **Step 2: The built path**
  Add `:lg-runtime :built` to that example's `lgx.edn`. Then:
  `~/Projects/lgx/bin/lgx info` prints `lg-runtime    built`, the `go` line,
  three `go-deps` lines, and the `lg` line with the cache path (built from
  the earlier smoke test, else `not built yet`).
  `~/Projects/lgx/bin/lgx run` prints `all checks passed`.
  `~/Projects/lgx/bin/lgx build && ./bin/app | tail -1` prints
  `all checks passed`; then `rm -rf bin`.
  `LGX_LG=/usr/bin/true ~/Projects/lgx/bin/lgx run` exits 1 with the
  `LGX_LG is set to` error and builds nothing.

- [ ] **Step 3: Cross-build under `:built` with no Go deps**
  In a temp dir: `{:paths ["."] :main "main.lg" :lg-runtime :built :lg-version "f26eb497299760e93ce430302f13ab3a954eab64" :targets {:bin {:out "bin/app_{{os}}_{{arch}}"}}}`
  with `main.lg` printing `:ok`. `~/Projects/lgx/bin/lgx build --target linux/arm64`
  exits 0 and `file bin/app_linux_arm64` reports an ARM aarch64 binary.
  (A sha pin is required here: the released 1.12.2 predates `pkg/cli`.)

- [ ] **Step 4: Record the outcome**
  Append a short "Verification" note at the end of this plan with the
  commands run and their results, then
  `git commit -am "docs(plan): record :lg-runtime verification"`.
