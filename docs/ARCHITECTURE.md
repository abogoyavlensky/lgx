# Architecture

lgx is a project manager for [let-go](https://github.com/nooga/let-go),
modeled on [`tools.deps`](https://clojure.org/reference/deps_and_cli) and
[`tools.gitlibs`](https://github.com/clojure/tools.gitlibs). It reads a
project's `lgx.edn`, fetches git-pinned dependencies into a per-user
cache, resolves local dependencies from disk, and invokes `lg` with the
resolved paths on the namespace search path.

## Runtime model

lgx is written in let-go and ships as a single bundled executable
(`lg -b lgx.lg bin/lgx`). The bundle embeds let-go's VM and lgx's own
bytecode in one ~10 MB binary; users install only `lgx`.

Two `lg` runtimes coexist. The one embedded in the lgx bundle runs
lgx's own logic. User scripts run under a separate `lg` binary that lgx
shells out to. Which one is `lgx.edn`'s `:lg-runtime` decision:
`:installed` (the default) is whatever sits on `PATH`, or whatever
`LGX_LG` points to; `:built` is an `lg` lgx builds from `:lg-version`
with the Go toolchain, cached under `$LGX_HOME/runtimes/`, which is how
Go deps get linked in. This separates lgx's release cadence from
let-go's: upgrading let-go does not require rebuilding lgx, and vice
versa.

For git operations, lgx shells out to the system `git` rather than
vendoring a git library. Every package manager that started with an
embedded git library ended up shelling out for edge cases anyway.

## Components

```
lgx.lg              ns lgx.main — entry, subcommand dispatch, basis/overlay wiring, apply-runtime! (the :lg-runtime decision), cmd-info
lgx/cli.lg          pure argv parsing: program-prefix strip, leading --verbose/--with, nrepl --port, build --target/--all; self-invocation + child argv for :task steps
lgx/config.lg       find lgx.edn (walks up), load + validate + normalize it once per invocation; the format lives here as one schema value; pure accessors over the loaded map; the shipped default contexts and the per-command auto-contexts table
lgx/spec.lg         minimal schema-as-data validation engine: validate -> [{:path :msg} ...] (accumulates sibling errors; never throws on invalid values — a malformed schema does throw; :and short-circuits), error->line rendering
lgx/args.lg         pure task-arg helpers: bind CLI values against a task's :args, render the usage line/signature, shell-quote, substitute :arg/<name> placeholders into step vectors, expand {{name}} templates in step strings
lgx/cache.lg        gitlibs cache layout, fetch via git
lgx/gobuild.lg      everything :go/* — partitioning go coords out of resolution, the runtime cache key, rendering the generated Go module, and driving go get / go mod tidy / lginterop / go build
lgx/path.lg         portable filesystem path helpers (join, parent)
lgx/runner.lg       locate lg, invoke with -source-paths / -resource-paths; exec a child with inherited stdio
lgx/tasks.lg        execute project tasks declared in lgx.edn :tasks; the cycle guard's stack encoding
lgx/new.lg          scaffold a new project from a built-in or URL template
lgx/clean.lg        explicit cache cleanup: flag parsing, sizing via du, guarded removal under $LGX_HOME
lgx/home.lg         $LGX_HOME root and the cache-root accessors every cache-owning module shares
lgx/completion.lg   shell TAB completion: pure candidate logic, bundled bash/zsh/fish scripts, the `completion`/`__complete` handlers
lgx/style.lg        colored status headers (green built-ins, purple tasks), LGX_NO_COLOR gate
```

Leading global options (`--verbose`, `--with a,b`) are parsed by `lgx/cli.lg`
before the subcommand and removed from the argv `lgx.main` dispatches on.
`--with` names contexts (see [Contexts](#contexts)) and applies to
`run`/`repl`/`nrepl`/`build`/`test`/`install`/tasks.

`lgx.main` holds the entry point; the other namespaces are stateless helper
namespaces it requires.

## Output styling

Before running a command, lgx prints a one-line status header to **stderr**, so
stdout stays clean for the program's real output (`lgx run | jq` sees only the
script's stdout). `install`/`build`/`test`/`new` use a green `=> ...` header; a
custom task uses a purple `=> Running task <name>...` header followed by an
indented `$ <cmd>` line per step (a `:run` step is shown as `lgx run <args>`).

`run` intentionally prints **no** header: it is the dev-time stand-in for the
built binary, which prints none, so keeping it header-free makes dev output
mirror the shipped artifact. (A cold-cache `run` still prints the install block
when deps are actually fetched.) `nrepl` prints no lgx header either — lg's own
motd and nREPL banner take its place. `version` and `help` likewise print no header —
they emit data the user asked for. The existing stdout lines (the install block,
`built <out>`, `Created <name> at <abs>`, and the test report) are unchanged and
stay on stdout.

Headers are color only (no bold): they fire on every command, so a lighter
weight reads calmer for everyday use.

`lgx/style.lg` builds these strings. Color is gated by `LGX_NO_COLOR` (disabled
when present and non-empty); let-go has no TTY detection, so this env var is the
only switch. The generated test harness keeps its own inline color helpers
because it runs under the user's `lg` and cannot require `lgx.style`.

`lgx help` is plain text — color is a runtime-only signal, so help reads the
same everywhere. After a `Usage: lgx [options] <command> [args...]`
synopsis it lists built-in commands under a `Built-in commands:` title and
project tasks under a `Project tasks:` title, both as `lgx <name>` rows aligned
to one shared description column, with `Options:` last. Help stays usable when
`lgx.edn` is invalid: the tasks section is replaced by a one-line warning
(`(omitted — lgx.edn is invalid; run \`lgx install\` to see errors)`) instead
of failing or silently dropping tasks.

## Data flow

### `lgx install`

1. Find the project root by walking up from the current directory until
   a directory contains `lgx.edn`.
2. Read `lgx.edn`, validate the schema
   (`{:paths [<rel-path> ...] :resource-paths [<rel-path> ...] :main <rel-path> :targets {:bin {:out <rel-path>}} :deps {<lib> {:git/url … :git/sha or :git/tag … :deps/root <opt>}}}`
   or `{<lib> {:local/root … :deps/root <opt>}}`),
   and return the coord vector. Validation (`config/load-config`, schema
   interpreted by `lgx/spec.lg`) collects **all** errors and reports them in
   one pass to stderr — `lgx: invalid lgx.edn (N errors)` followed by one
   path-prefixed line per error (e.g.
   `:tasks lint :do [0] — unknown key :shh (allowed: :sh, :run)`) — then
   exits 1, with no stack trace. The config is loaded once per invocation;
   every basis command (`install`/`info`/`run`/`repl`/`nrepl`/`build`/`test`/tasks)
   and the task-name fallback in dispatch go through `load-config!`.
3. Resolve coords breadth-first. For each unseen lib name, call
   `cache/ensure-lib!`. Git coords compute a cache ref first: the sha
   for `:git/sha`, or the tag with `/` replaced by `_` for `:git/tag`.
   If the cache directory for `(url, ref)` already exists, return its
   path without invoking `git`. Otherwise clone the repo into a temp
   dir, check out the sha for `:git/sha` coords or use
   `git clone --branch <tag> --depth 1` for `:git/tag` coords, drop
   `.git/`, and rename atomically to the final cache path. Local coords
   resolve from disk and never clone. `ensure-lib!` reports whether
   this call did the clone.
4. After a dep resolves, read the deps it declares and append them to
   the queue — from its own `lgx.edn` if it has one, otherwise from the
   `deps.edn` or `project.clj` it ships for other tools (see
   [Transitive resolution](#transitive-resolution)). Other top-level keys
   in a dep's `lgx.edn` are ignored by consumers (open-map leniency in
   `config/coords-at`); an invalid `:deps` there reports
   `lgx: invalid lgx.edn in <dir> (N errors)` and exits 1. Duplicate lib
   names are first-wins: a later differing coord is skipped with a
   warning. Coords are compared after `coord-id` absolutizes a relative
   `:local/root` and strips a trailing `/` or `.git` from a `:git/url`, so
   one repo spelled two ways is not a conflict. The seen set also
   terminates cycles.
5. If any dep was newly cloned, print `installing N dep(s)...`, one
   `<lib> -> <path>` line per **new** dep, and `done`. If every dep was
   already cached, print `all deps up to date`. Empty `:deps` prints
   `no deps in lgx.edn`.
6. `apply-runtime!` (see [Go deps](#go-deps)), with or without deps: under
   `:built` this is what warms the runtime so the first `run` has nothing
   left to build, and a deps-less project still needs that.

### `lgx info`

Read-only: the runtime decision, spelled out. Resolves the basis like
`install` (same `--with` handling, no auto contexts; a cold cache fetches
deps and prints the install block) but never calls `apply-runtime!`, so
nothing is built and no branch pin is resolved. `cmd-info` probes the
environment (`lg -v`, `command -v go`, `go version`, the cache path from
`gobuild/runtime-paths`, `LGX_LG`, `LGX_LETGO_REPLACE`) and hands the
values to the pure `info-lines`, which renders aligned `label  value`
lines on stdout: `project`, `lgx` (lgx's own version), `lg-runtime`,
`lg-version`, `lg`, then `version` (the outcome of `check-lg-version!`)
under `:installed` or `go`/`let-go`/`LGX_LG` under `:built`, `go-deps`
with each coord's origin from `:go-origins`, then two blocks read from
`lgx.config` so they cannot drift from behaviour: `contexts` (the
effective contexts, `:dev` and `:test` first, then the project's sorted by
name, each `pr-str`'d, with `(default)` on a shipped one) and `applies`
(each auto-applying command and its context names). A branch pin under `:built` prints
`unresolved`, since its cache path needs `go list -m` (network; exits on
failure). Exit 1 only for an invalid `lgx.edn` or a failed dep fetch.

### `lgx run [args...]`

Steps 1–4 match `install` — deps are auto-installed if missing — except
that the `:dev` context is prepended to the CLI `--with` list first
(`config/auto-context-names` via `auto-with!` in `lgx.lg`; silent unless
`--verbose`, which prints `+ auto context :dev`).
Then:

5. If any dep was newly cloned during dependency resolution, print the same install
   block as `lgx install` (header + per-new-dep lines + `done`).
   Otherwise stay silent — no `all deps up to date` chatter before the
   script.

If `lgx.edn` sets top-level `:paths`, lgx resolves those
project-root-relative paths to absolute paths and prepends them to the
cached lib paths before the join. Missing entries log a warning to
stderr, but lgx still passes the resolved path through to `lg`.

If `lgx.edn` sets top-level `:resource-paths`, lgx resolves those
project-root-relative dirs to absolute paths and passes them to `lg` as
`-resource-paths` (resource roots for `io/resource`). Unlike source paths
these are project-only — dep dirs are never added. Missing entries warn but
are still passed through.

The pure `runner/plan-run-args` decides the argv. It is **structural, not
suffix-based**: split `forward-args` at the first `--` into `pre` (before) and
`post` (after; empty when there is no `--`), then, first match wins:

1. **`pre` non-empty** → the user is driving `lg`; pass `pre ++ post` through
   verbatim, never inject `:main`. Output: `lg <lg-flags> <pre> <post>`.
   (`lgx run other.lg`, `lgx run -e '(...)'`, `lgx run -r -- foo` all take this
   branch — a lone flag or explicit script before `--` suppresses `:main`.)
2. **`pre` empty + `:main` set** → inject `:main`, then `post`. Output:
   `lg <lg-flags> <main> <post>`. `*command-line-args*` is `nil` when `post` is
   empty.
3. **`pre` empty + no `:main` + `post` non-empty** → `{:error :needs-main}`;
   `cmd-run` exits with `lgx run: -- forwards args to :main, but no :main is
   set …`.
4. **`pre` empty + no `:main` + `post` empty** (bare `lgx run`) →
   `{:error :no-target}`; `cmd-run` exits with `lgx run: nothing to run …`,
   naming `:main`, an explicit script, or `lgx repl`.

lgx never emits a `--` of its own — the app reads its arguments from let-go's
`*command-line-args*` (the positionals after the script), identical under
`lgx run` and in a bundled binary. `lg` stops flag-parsing at the first
positional (`<main>` or the explicit script), so every arg after it is shielded
from `lg` and becomes the app's `*command-line-args*`. Only the *first* `--` is
the lgx/app separator; later `--` tokens survive inside `post` as literal args
(standard getopt convention). `*command-line-args*` is the reason lgx requires
`lg` >= 1.11.0. This decision drops the old `.lg`/`.cljc`/`.clj` extension
heuristic (`has-script?`) entirely.

When `:main` is being injected and the file does not exist on disk,
lgx exits non-zero with `lgx: :main script not found: <path>` before
exec.

5. Compute the `-source-paths` argument by joining the cached paths
   with the OS path-list separator, and the `-resource-paths` argument by
   joining the resolved resource roots. Either flag is omitted when its list
   is empty.
6. Exec `lg -source-paths <paths> -resource-paths <roots> [args...]`.
   Forwarded args reach `lg` verbatim.

The exec call uses `runner/exec-lg-interactive!`, built on let-go's
`os/exec*` (lg >= 1.10.0): the child inherits lgx's stdin/stdout/stderr,
so output streams live and interactive children work — `lgx repl` lands in
`lg`'s REPL, and `lgx run -r <script>` can drive it. On let-go >= 1.13.0
`os/exec*` by itself only inherits stdin; stdout/stderr follow `*out*` /
`*err*`, whose root handles are no longer raw files, so the child would get
a pipe and lose the tty. The runner therefore rebinds each of `*out*` /
`*err*` that is currently a terminal to a `/dev/stdout` / `/dev/stderr`
file handle around the call (pipes and files are left alone so shell
redirections keep a shared offset); see
[`issues/exec-star-std-stream-pipes.md`](issues/exec-star-std-stream-pipes.md).
(Bare `lgx run` without
`:main` now errors and points at `lgx repl`, rather than opening a REPL
itself.) `lgx test`, `lgx build`, and task `:run` steps still use the
captured `os/sh` path (`runner/run-lg!`/`invoke-lg!`): `test` must
inspect lg's output to strip its harness marker, and the others keep
buffered-and-replayed output. (History: the inherited-stdio runner was
tracked in [`issues/inherit-stdio-runner.md`](issues/inherit-stdio-runner.md),
resolved upstream by `os/exec*`.)

### `lgx repl`

`cmd-repl` opens lg's plain built-in REPL — `nrepl` minus the socket. Steps 1–4
match `install` (deps auto-installed, `--with` contexts apply) and
`:paths`/`:resource-paths` resolve as in `lgx run`; like `nrepl`, it
auto-applies **both** `:dev` and `:test` (`auto-with!` with `[:dev :test]`).
It takes no args of its own — a positional exits 1 with
`lgx: repl does not take arguments`; `lg` flags and scratch scripts are
`lgx run`'s job. Then it execs `lg <paths>` via `runner/exec-lg-interactive!`
with an **empty** forward-arg list: with no script, no `-e`, and no `-n`, lg
drops into its terminal REPL. No port and no `.nrepl-port` are involved, and —
like `cmd-nrepl` — no `LGX_RUN` is set. `repl` is an overridable
command (`config/overridable-commands`): a project task named `repl` runs
instead, and `lgx lgx:repl` reaches this one.

### `lgx nrepl [--port N]`

Steps 1–4 match `install` (deps auto-installed, `--with` contexts apply), and
`:paths`/`:resource-paths` resolve exactly as in `lgx run`. Unlike `run`, which
auto-applies only `:dev`, `nrepl` auto-applies **both** `:dev` and `:test`
(`auto-with!` with `[:dev :test]`) — a REPL is where you iterate on tests, so
it gets the test helpers too. Then:

5. Parse the command's own args with `cli/parse-nrepl-args`: `--port N`
   must be an integer in 1–65535; anything else exits 1 with a clear
   error. No flag → lgx asks its own runtime (let-go ≥ 1.11.0) for a
   free port via `os/free-port` and passes it as the literal `-p` value,
   which lg writes to `.nrepl-port`. The OS vets the port as free, so it
   is almost never taken.
6. Exec `lg <lg-flags> -n -p <port>` via `runner/exec-lg-interactive!`.
   With no script argument, lg starts the nREPL server (printing
   `nREPL server started on port N ...` and writing `.nrepl-port` in the
   cwd) and opens its terminal REPL in the same process.

`os/free-port` is check-then-use, so a rare race can still leave the
port taken before lg binds it: lg then prints `failed to run nREPL
server on port N` and still opens the terminal REPL; rerunning picks a
fresh free port.
Unlike `cmd-run`, `cmd-nrepl` does not set `LGX_RUN` — that var
advertises script-arg handling to a spawned program, which doesn't
apply to a REPL session. `nrepl` is an overridable
command (`config/overridable-commands`): a project task named `nrepl` runs
instead, and `lgx lgx:nrepl` reaches this one.

### `lgx build [args...]`

`cli/parse-build-args` first splits lgx's own flags (`--target
<os>/<arch>[,...]`, repeatable, and `--all`) from the args forwarded to
`lg`. `gobuild/resolve-build-targets` turns that plus `:platforms` into
the target list: an explicit `--target` list wins, `--all` takes every
declared platform (an error when none are), and neither means one
native build (nil target). Then, before anything expensive:

1. Read `:main` and `:targets/:bin` from the validated config. Either
   being absent exits 1 with a clear error (`lgx: :main is required for
   build` / `lgx: :targets/:bin is required for build`).
2. Verify the `:main` script exists on disk (resolved against the
   project root). Missing → `lgx: :main script not found: <path>` and
   exit 1.
3. Reject a target list whose rendered `:out` paths collide
   (`gobuild/duplicate-target-out` - the load-time `:platforms` check
   only covers config, not an ad-hoc `--target` list), and a forwarded
   `-bundle-base` combined with more than one target (one base binary
   cannot serve two platforms).
4. A cross-build under `:installed` without a user-forwarded
   `-bundle-base` is an error (`gobuild/installed-cross-error`): the
   target runtime is generated with Go, Go deps or not, which only
   `:built` does.

Then steps matching `install` resolve the basis, and per target:

5. Expand `:out` through `config/expand-out` (`{{os}}`/`{{arch}}`;
   native keeps `:out` byte-for-byte), resolve it to an absolute path
   under the project root, and `mkdir` its parent.
6. Resolve the bundle base: a cross target gets a target-platform
   runtime from `gobuild/ensure-runtime!`; native uses the host runtime
   (`:built`) or none (`:installed`; `lg` copies itself); a user-forwarded
   `-bundle-base` wins and skips generation.
7. Exec `lg -source-paths <X> -resource-paths <R> [forwarded-args...]
   [-bundle-base <base>] -b <abs-out> <abs-main>`. With `-b`, `lg`
   embeds the resources under `<R>` into the binary, so a bundled app
   resolves `io/resource` with no files alongside it. Both `-b` target
   and main script are absolute paths so `lgx build` produces the same
   artifact regardless of which subdirectory of the project the user
   invoked it from.

Which `lg` runs, and which is shipped, is decided per the two-runtimes
rule - bundling *executes* the script on the host (compilation runs
top-level forms), while `-bundle-base` becomes the shipped binary:

| Mode / build | `lg` that runs `-b` (host) | `-bundle-base` (shipped) |
|---|---|---|
| `:installed`, native | PATH `lg` | none (base = itself) |
| `:installed`, cross | error, unless the user forwards `-bundle-base` | the user's |
| `:built`, native | host runtime | same host runtime |
| `:built`, cross | host runtime | generated target runtime |

So a four-platform release under `:built` builds five runtimes: one
host plus four targets. A user `-bundle-base` replaces only the target
runtime, so under `:built` the host side still needs Go. `LGX_LG` under
`:built` fails for every command, build included - the override would
leave the host side unable to resolve the project's Go namespaces at
compile time.

`lgx build` shares `resolve-main-script!` and the project-basis
resolution with `lgx run`; the structural differences are the argument
shape, the per-target loop, and the required-config / mkdir steps.

### `lgx test`

Steps 1–2 (project root, config load) match `install`. Then:

3. Parse the command's args (`cli/parse-test-args`): `--exclude <ns,...>`
   (repeatable, accumulating; a missing or blank value →
   `lgx: --exclude requires a comma-separated list of test namespaces`
   + exit 1) and positionals. Two or more positionals →
   `lgx: test takes at most one argument` + exit 1; one positional plus
   `--exclude` → `lgx: --exclude cannot be combined with a test file` +
   exit 1. Then read the test dirs: the effective `:test` context's
   `:extra-paths` (`config/contexts`, so `["test"]` unless the project
   replaces `:test`), in declared order. No `:extra-paths` at all →
   `lgx: the :test context defines no :extra-paths, so lgx test has
   nowhere to look` + exit 1. Each entry is joined onto the project root
   and normalized; the ones that exist as directories are the test dirs.
   None exists → `lgx: no test directory in project (looked for: test/)`
   (every declared entry, `<p>/`, comma-joined) + exit 1. A missing entry
   while another exists is skipped here; the basis still warns about it
   if the project declared it (see [Contexts](#contexts)). These checks,
   and the file selection in step 5, all run **before** the basis is
   built, so a bad invocation (or an empty plan) never fetches deps.
4. Build the basis as in `install` steps 3–4, with `:test` prepended to
   the CLI `--with` list (`auto-with!`, as `run` does with `:dev` and
   `repl`/`nrepl` with both `:dev` and `:test`). In code this step follows
   step 5: selection depends only on the project root and the test dirs,
   and finishing it first keeps every cheap failure ahead of the dep
   fetch.
5. Select the test files. If a positional `<file>` arg is provided,
   resolve it to an absolute path (project-root-relative inputs are
   joined against the project root), then `path/normalize` away any
   `.`/`..` segments and validate it against three rules:
   - file exists on disk →
     `lgx: test file not found: <path>` on stderr + exit 1 if not.
   - extension is `.lg`, `.cljc`, or `.clj` →
     `lgx: not a test file (expected .lg, .cljc, or .clj): <path>` + exit 1
     if not.
   - normalized absolute path starts with `<abs test-dir>/` for one of
     the test dirs (the first match wins and maps the namespace) →
     `lgx: test file must be under a test path (test/): <path>` (the
     existing dirs) + exit 1 if not.
   On success, the test plan is a one-entry vector with that file.
   With no arg, walk each test dir recursively, in order, for `*_test.lg`,
   `*_test.cljc`, and `*_test.clj` files, map each to its
   `[display-file ns-symbol]` entry (step 6; a file reached through two
   nested declared dirs keeps its first entry), then apply `--exclude`
   (`test-runner/exclude-entries`): drop entries whose ns symbol is
   named. Any name matching no entry →
   `lgx: --exclude names no test namespace: <ns>` (one line per name, in
   the order given) + exit 1. This is checked **before** either
   empty-plan exit, so a typo in an empty `test/` still fails rather
   than printing `No tests found`. Then: the walk returned no files →
   print `No tests found in test/` (the existing dirs) + exit 0; every
   discovered entry was excluded → print `All test files excluded` +
   exit 0. Finally, a planned namespace that more than one discovered file
   maps to (`unit/foo_test.lg` and `integration/foo_test.lg`;
   `test-runner/ns-collisions`) → `lgx: test namespace <ns> is defined by
   more than one file (<files>)` + exit 1, since only the first on the
   source path would load and the other's tests would silently not run.
   In single-file mode only the chosen file's namespace is checked.
6. Map each absolute path to a namespace symbol: strip the test dir it
   was found under and the extension, split on `/`, hyphenate `_` per
   segment, join with `.` (e.g. `test/lgx/config_test.lg` →
   `lgx.config-test`). The display file is the path relative to the
   project root, so a custom dir shows as `tests/foo_test.lg`.
   This is the reverse of let-go's resolver rule
   ([`docs/knowledge-base/let-go-resolver.md`](knowledge-base/let-go-resolver.md)).
7. Generate the harness: a directory
   `$LGX_HOME/test-runner/lgx-test-<version>/` (overwriting the previous
   one for the same lgx version) holding an entry script `harness.lg` and
   two namespaces under `lgx/test_harness/` — `ui` (printing helpers) and
   `report` (the run phase). The entry embeds the discovered `[file ns]`
   test plan, `require`s each test ns one at a time inside a `try` (a file
   that fails to load costs one reported failure, not the run), writes a
   `harness-ready` marker to stderr once the load phase is over (this
   splits lg's captured stderr into pre-harness load diagnostics and
   test-emitted output — see step 10), then calls
   `(report/run-plan! plan)` → `{:test :pass :fail :error}`. `report`
   runs over let-go's clojure.test port (nooga/let-go#863, in lg >= 1.13.0,
   lgx's minimum): each `:test`-tagged var (name order — the port keeps no
   definition order) goes through `test/test-var` under `binding
   [test/report …]`, collecting `:pass`/`:fail`/`:error` events instead of
   parsing output; `:once`/`:each` fixtures come from the namespace
   metadata, `:each` inside the per-var capture, `:once` around the
   namespace; an assertion outside any var (a `:once` fixture) is reported
   as a `fixtures` row and counted; a namespace defining `test-ns-hook`
   runs the hook as one row instead of its vars, as `test/test-ns` would.
   It prints the test file, a `✓`/`✗` line per `deftest`, any `testing`
   context strings, and failure/error details (with an `actual:` line)
   only for failing tests; the entry prints the `N tests, M assertions, K
   failures` summary and `(os/exit (if failed? 1 0))`. The opening
   `Running tests in <header>...` banner is printed by lgx itself (green,
   on stderr — see [Output styling](#output-styling)), not the harness;
   walk-mode passes the existing test dirs (`test/, integration/`),
   single-file mode the entry's display path (e.g. `test/foo_test.lg`).
8. Compute `-source-paths` as the basis paths + the harness directory,
   last (so nothing in a project shadows the harness's own namespaces).
   The test dirs are already in the basis paths through the `:test`
   overlay, with the project's own paths and ahead of dep dirs, so test
   namespaces can `require` each other, the harness can `require` them,
   and a test dir's namespace shadows a dep's of the same name. Compute
   `-resource-paths` as the project's resolved resource roots
   (project-only; test dirs are *not* added as resource roots).
9. Run `lg -source-paths <X> -resource-paths <R> <harness-dir>/harness.lg` and capture
   its output.
   Normally the harness owns the `os/exit` and that exit code is passed
   through. But let-go's `require` swallows a test file's load failure —
   it prints `error: failed to load <path>: <ErrorType> ...` to stderr
   yet does not throw or fail, so the harness would report 0 failures and
   exit 0. To catch that, lgx scans the stderr *before* the harness-ready
   marker for lg's diagnostic line shape — `error: failed to load <src>:
   ...`, naming a `.lg`/`.cljc`/`.clj` file, which covers compile, runtime,
   and syntax load failures. If found on an otherwise-zero exit, it prints
   `lgx: a test file failed to load (see errors above)` and exits 1. lg's
   stdout and stderr are replayed to the user with the internal marker
   stripped out.

   This stderr heuristic is necessary because let-go has no userspace
   load-status API: `require` swallows a source file's compile error
   (printing the diagnostic to stderr but not throwing, and `find-ns`
   still returns the registered namespace), so the harness cannot tell a
   failed load from an empty one. Known limitation: a test that writes a
   line matching lg's exact loader diagnostic shape from a *top-level*
   form (during load, before the marker) would be misread as a failure.
   That is adversarial and fails loud — a spurious failure, never a silent
   pass — so it is accepted rather than chased with a stricter match.

`lgx test` accepts 0 or 1 positional arg plus `--exclude <ns,...>`
anywhere after `test`. The value is a comma-separated list of exact test
namespace symbols (trimmed, blanks dropped; no globs or prefixes), and
the flag repeats and accumulates like `--with`. Its three errors, all
exit 1 on stderr: `lgx: --exclude requires a comma-separated list of
test namespaces` (missing/blank value), `lgx: --exclude cannot be
combined with a test file` (given with a positional `<file>`), and
`lgx: --exclude names no test namespace: <ns>` (a name that matched
nothing). Passing 2 or more positionals prints `lgx: test takes at most
one argument` and exits 1. Under `--verbose`, the trace also includes
the harness path on stderr so the user can inspect the generated file,
and, when anything was excluded, a `+ excluded: a.b-test, c.d-test`
line beside it.

### `lgx <task>`

#### Dispatch order

`dispatch` in `lgx.lg` resolves a command word in this order; first match wins.

1. No command → usage, exit 1.
2. **Fixed commands**: `help`/`-h`/`--help`, `version`/`-v`/`--version`, `new`,
   `completion`, `__complete` (`config/fixed-commands`). They run without a
   project, so a project can never sit in front of them.
3. **`lgx:<name>`** (`cli/strip-lgx-prefix`) → the built-in behind the prefix,
   or `lgx: 'lgx:<x>' is not a built-in command (built-ins: …)` and exit 1.
4. **A project task** of that name, when a project is found and its `lgx.edn`
   loads cleanly. An invalid config is skipped silently here: the built-ins
   that need it keep reporting the errors themselves.
5. **An overridable built-in**: `run repl nrepl build test install info clean`
   (`config/overridable-commands`).
6. Unknown → with a project, the validation report (an invalid `lgx.edn` might
   have defined the task); otherwise `'<cmd>' is not a lgx command`.

So a project task shadows a built-in of the same name, and `lgx:<name>` is the
escape that always reaches the original — the form a wrapper uses to call the
command it wraps. `lgx help` marks an overriding task in its row.

#### Binding and execution

Having found the task, lgx first binds the remaining CLI
args against the task's `:args` declarations (`args/bind-args`) —
before the basis is built, so a bad invocation never fetches deps.
Arity is strict unless a step forwards `:args/rest`: missing/surplus args or a
value failing its `:type`
print each error plus a usage line derived from the declarations
(`usage: lgx deploy <env> [version]`) and exit 1; a task without
`:args` rejects any CLI args the same way, with a hint naming
`:args/rest`. Then lgx resolves the
project basis the same way `lgx run` does (steps 1–4 above) and walks
the task's `:do` vector. Config validation accepts `:do` as either a
single step map or a vector of steps, then normalizes the single-map
form to a one-item vector before execution walks it. Each step is one
of:

- `{:sh <string-or-vector>}` — joined with spaces and run via
  `sh -c <cmd>`. Captured stdout/stderr is replayed after the child
  exits.
- `{:run <string-or-vector>}` — forwards an explicit argv to `lg` with
  the project's resolved `-source-paths` and `-resource-paths`. String
  forms are whitespace-split into argv. Unlike `cmd-run` it never
  substitutes `:main` (a `:run` step names its own script), but it does
  apply `runner/drop-arg-separator` so the first `--` — the app-level
  separator — is stripped before `lg` sees it, matching `lgx run`. A
  second `--` survives as a literal arg.
- `{:task <symbol-or-vector>}` — invokes another task, or a built-in when the
  callee is `lgx:<name>`. The step **re-invokes lgx itself as a child
  process**: every built-in either exits on its own paths or hands the process
  to `lg`, and `repl`/`nrepl` are interactive, so an in-process call could
  never return to continue the chain. Spawning lgx reuses dispatch, arity
  checks, basis layering and headers unchanged, and a wrapped `lgx:nrepl` owns
  the terminal like a direct call would.

  The child is the same binary the parent runs, never a `PATH` lookup of
  whatever `lgx` happens to be: `cli/self-invocation` splits `os/args` into the
  program and (in dev) the `lgx.lg` script prefix, and `cli/resolve-self-bin`
  turns a bare argv[0] into a real path — through `command -v`, because
  `os/stat` reports no mode bits and the shell skips a non-executable file that
  a stat-based PATH walk would pick. `cli/child-args` then renders the child's
  argv: `--verbose` when the parent is verbose, `--with` carrying the parent's
  *effective* contexts (task `:with` ++ CLI `--with`) so the child's own
  layering unions them, then the callee and its args. Stdio is inherited via
  `runner/exec-interactive!`, so output streams live.

Step values may reference the bound args two ways, applied just before
the step runs. Vector-form values may carry `:arg/<name>` placeholder
keywords, replaced whole (`args/substitute`): shell-quoted for `:sh`
(each value arrives as one uninterpreted shell word), verbatim for
`:run` (each vector item is already one argv entry). Any step string —
a whole-string value or a vector item — may embed `{{<name>}}` templates
(`args/expand`), spliced in raw with no quoting added; tokens that don't
name a declared arg pass through untouched, and a string-form `:run`
value is expanded before its whitespace split. Config validation checks
every keyword placeholder names a declared arg, so an unbound keyword at
execution time is a programmer error (throws); `{{name}}` tokens are not
validated. The echoed `$ <cmd>` step line shows the substituted command,
and `lgx help` renders each task's signature after its name.

A task may augment the project basis with context overlays (its `:with`
list and the CLI `--with`) and its own inline
`:extra-paths`/`:extra-resource-paths`/`:extra-deps`.
All of run/build/test/install/tasks resolve their basis through one
`overlay-basis` helper (built on the shared `basis`); see
[Contexts](#contexts) for the full layering. A task extra-dep overrides a
same-named project coord *in place* and silently (`config/merge-coords`
dedupes before `ensure-all!`, so its first-wins warning never fires for the
override). The augmented `-source-paths`/`-resource-paths` applies only to the
task's `:run` steps; `:sh` steps ignore the basis.

Steps run sequentially. The first non-zero exit code stops the chain
and becomes the task's exit code; lgx exits 0 only when every step
returns 0.

#### `:args/rest`

`:args/rest` is a placeholder for the CLI args left over after the declared
positionals bind (all of them when a task declares no `:args`). Allowed in
vector-form values only — there is no `{{rest}}` string form, since a joined
splice would lose quoting. Its presence anywhere in a task's steps
(`args/uses-rest?`) is what relaxes that task's arity check; it binds in the
same map as the `:arg/` entries, under `:args/rest` but as a *vector* of
strings, and `args/substitute` splices it into that many items (shell-quoted
per item for `:sh`, verbatim for `:run` and `:task`). `args/signature` and
`args/usage-line` append `[args...]` for a task that uses it. The namespace
differs from `:arg/` so it can never collide with an arg declared as `rest`;
an unknown `:arg/rest` placeholder gets a hint pointing here.

#### Cycle guard

Because every hop between tasks is a child process, the chain of running tasks
travels in the environment rather than on a call stack — which is what lets one
mechanism cover direct `:task` recursion, an indirect cycle, and the
`{:sh "lgx test"}` mistake inside an override of `test`. `cmd-task` reads the
chain, refuses to run a task already on it, and otherwise pushes itself before
running steps:

```
lgx: task 'test' is already running (ci > test); to call the built-in from a task, use lgx:test
```

An entry is a **(task name, project root) pair**, so a monorepo root task that
shells into a child project with a same-named task is not mistaken for
recursion, while a chain that leaves a project and re-enters the same task
still is. The pair travels as two parallel vars: `LGX_TASK_STACK` is the
documented, readable `a,b` name chain (and the one `runner/lgx-set-env-names`
shows in the `--verbose` `+ env` trace), `LGX_TASK_ROOTS` its newline-joined
roots — newlines because a directory name may legitimately contain a comma. The
parsing, comparison and rendering are pure fns in `lgx/tasks.lg`
(`stack-entries`, `stack-cycle?`, `stack-chain`, `stack-values`), unit-tested
in `test/lgx/tasks_test.lg`; a length mismatch between the two vars reads as an
empty chain, so a hand-set value fails open rather than blocking a legitimate
task.

#### Task-name rules

A task name is a symbol. Names matching a **fixed** command are rejected at
validation time (`conflicts with built-in command "new", which cannot be
overridden`), as are names starting with `lgx:` (reserved for addressing
built-ins) or `-`. Every overridable built-in's name is accepted. Only a bare
name can shadow a built-in — a namespaced `foo/run` dispatches as `foo/run`.

`:task` callees are cross-checked at load time too (`task-targets-errors`, a
root-level rule beside `with-refs-errors`): an `lgx:<x>` callee must name an
overridable built-in, any other callee must be a defined task, and a task may
not call itself (`calls itself; use lgx:<name> to call the built-in`).

### Contexts

A `:contexts` entry is a named overlay carrying only `:extra-deps`/
`:extra-paths`/`:extra-resource-paths` — the per-task extras, lifted to the top
level for reuse. They are applied by the CLI `--with a,b` flag (any command),
a task's `:with` vector, and the auto-contexts: `run` applies `:dev`, `test`
applies `:test`, and `repl`/`nrepl` apply **both**. That table is one value,
`config/auto-contexts`, read through `config/auto-context-names`; `auto-with!`
in `lgx.lg` prepends the names to the CLI `--with` list and prints `+ auto
context <name>` per name under `--verbose`. The table is fixed: what a context
contains is the customization point, and `lgx info` prints both.

`:dev` and `:test` always exist. `config/default-contexts` ships
`{:dev {} :test {:extra-paths ["test"]}}`, and `config/contexts` returns
`(merge default-contexts (:contexts cfg))`, so a project entry replaces the
shipped one of the same name wholesale (deps.edn alias semantics). The merge
happens at the accessor, not in `load-config`: the loaded map stays the
user's file verbatim (config tests assert exact equality, and the raw file
and the effective view are different things), while every reader
(`with->overlay!`, `overlay-basis`, `cmd-test`, `info-lines`) goes through
`config/contexts`. `with-refs-errors` validates a task's `:with` against the
same union, so `:with [:dev]` loads in a project with no `:contexts`.

A shipped default's paths are optional. `overlay-basis` passes
`basis`/`resolve-project-paths` the set of `:extra-paths` contributed by
applied contexts for which `config/default-context?` holds (shipped, not
redefined by the project), minus any path the project declared itself (in
`:paths`, one of its own applied contexts, or the task). Those resolve
without the `warning: :paths entry not found` line, so `lgx repl` in a
project without `test/` stays quiet; a path the project wrote still warns.
A `:task` step forwards the caller's *effective* contexts (its `:with` plus the
CLI `--with`) to the child as `--with`, so the callee layers them after its own
`:with` — the child's existing layering does the union, with no new precedence
rule.
Auto-contexts touch only those four built-in commands — never `build`/`install`,
never a task's `:run` steps — so dev/test deps cannot leak into artifacts. `config/context-overlay` resolves an ordered name
list to a single `{:deps-pairs :paths :resource-paths}` overlay, folding
overlap among the named contexts last-wins via `config/merge-coords` (and
throwing on an unknown name; a task's `:with` is additionally validated against
the effective contexts when `lgx.edn` loads). A reference to an unknown context
fails loudly - at config-load for `:with`, at runtime for `--with`; the auto
names always exist, so they can't trigger that error.

`overlay-basis` in `lgx.lg` composes the final basis from these layers,
lowest → highest precedence: project `:deps`/`:paths`/`:resource-paths` → auto
context (built-in commands only) → task `:with` contexts (in order) → CLI
`--with` contexts (in order) → the task's inline
`:extra-deps`/`:extra-paths`/`:extra-resource-paths` (highest). Deps fold
last-wins through `merge-coords`; source and resource paths concatenate in the
same order (project first, so project namespaces still shadow libs) and are
de-duplicated keep-first. Note the path asymmetry: precedence is a *deps*
notion (a later layer's coord replaces an earlier one's), while namespace
resolution is first-match-wins along the path order — an earlier layer's dir
shadows a later one's for a same-named namespace, exactly as project paths
shadow everything. Resource paths layer identically but never pick up dep
dirs (project-only). For the built-in commands there is no task, so the
layers are: project + auto-context + CLI `--with` for `run`/`repl`/`nrepl`/`test`,
and project + CLI `--with` only for `build`/`install` (no auto layer —
`cmd-build`/`cmd-install` never call `auto-with!`). `install` resolves the
same overlay so it pre-fetches a context's deps (auto names included only
via an explicit `--with dev,test`).

### `lgx new <name> [-t <tpl>]`

Scaffolds a new project directory from a template: a built-in name from
the registry in `lgx/new.lg` (`base`, `cli`, `lib`; sha-pinned) or a custom git
URL. The command never touches an existing project's `lgx.edn`.

1. Parse rest-args with `cli/parse-new-args` (pure): `-t`/`--template
   <value>` at any position plus exactly one positional, the project
   name. A missing/repeated template value or a positional count other
   than one → the parse error on stderr (messages carry their own
   `lgx: ` prefix), exit 1.
2. Validate `<name>` against `^[a-z][a-z0-9-]*$`. Bad input →
   `lgx: invalid project name: <input>` plus the rule description on
   the next line, exit 1.
3. Resolve the target dir as `<cwd>/<name>`. If it exists as
   a regular file or as a non-empty directory, exit 1 with
   `lgx: target exists and is not a directory: <path>` or
   `lgx: target directory already exists and is not empty: <path>`.
   An empty pre-existing directory is allowed; the render lays files
   into it.
4. Resolve the template coord (`new/resolve-template-coord`, 1-arity):
   - No `-t`, or `-t base` → the registry's `base` entry, with either
     field overridable by the env vars `LGX_TEMPLATE_BASE_URL` and
     `LGX_TEMPLATE_BASE_SHA`; blank or unset envs fall back to the
     registry. The overrides are scoped to `base` — other templates
     ignore them.
   - A value containing `://` → custom template URL. Its default-branch
     HEAD is resolved to a sha by `cache/resolve-head-sha!`
     (`git ls-remote <url> HEAD`), so a URL template always tracks the
     latest HEAD at the cost of one `ls-remote` round-trip per run.
     Failure → `lgx: failed to resolve template <url>: <stderr>`, exit 1.
   - Any other value → registry lookup. Unknown name →
     `lgx: unknown template: <value> (built-in: base, cli, lib)`, exit 1.
5. Ensure the template is cached under
   `$LGX_HOME/templates/<host>/<owner>/<repo>/<sha>/`. If the leaf
   exists, reuse it. Otherwise clone via `cache/clone-sha!` (same
   atomic clone-into-tmp → checkout → drop-`.git/` → mv pattern used
   for `:deps`). Clone failures replay `git`'s stderr after a
   `lgx: failed to fetch template:` prefix, exit 1.
6. Walk the cached template recursively. For each source file, compute
   a destination relative to the target by replacing every
   `projectname` path segment with the underscored form of the project
   name (`my-app` → `my_app`). Then `mkdir` the destination's parent,
   `slurp` the source, replace every `projectname` in the contents
   with the hyphenated form of the project name (verbatim user input,
   `-` preserved), and `spit` to the destination.
7. Print `Created <name> at <abs>` followed by a two-line next-steps
   block: `cd <name>`, then a command chosen from the rendered project's
   `lgx.edn` — `lgx run` when it declares a `:main`, else `lgx test` (a
   library scaffold has no `:main`, so its first payoff is a passing test).

The unified `projectname` token splits along the natural axis: path
segments need `_` per let-go's resolver, while file contents (ns
forms, README display name, binary name in `lgx.edn`) want `-`. The
template repo holds one form of the token; the substitution rule
encodes the per-site form.

No git init or initial commit in the new project — the user owns the
choice of VCS.

### `lgx completion <shell>` and `lgx __complete` (hidden)

Shell TAB completion lives in `lgx/completion.lg`. Both commands are
dispatch branches in `lgx.lg`, both are absent from `lgx help`, and both are
fixed commands (`config/fixed-commands`) — they run without a project, so a
project task can never shadow them.
`completion` is documented in the README's install instructions only.

At the command position a bare TAB offers the built-ins, the project's tasks,
and an `lgx:<name>` form only for the built-ins the project actually overrides
— the escape is surfaced exactly where it is needed, and a bare prompt does not
gain eight entries nobody asked for. Once the typed word starts with `lgx:`,
every overridable built-in is offered.

`lgx completion <shell>` prints the bash, zsh, or fish completion
script to stdout. The scripts are string constants, not resources:
lgx runs as plain `lg lgx.lg` in dev and bundles with plain `lg -b`,
so neither mode has a resource root. Each script invokes the binary by
the name it was called as and asks `lgx __complete <words…> <cur>` for
candidates on TAB. An unknown or missing shell argument errors to
stderr and exits 1.

The bash script does one extra thing: bash treats `:` as a word-break character
by default, so `lgx lgx:te<TAB>` arrives as the three words `lgx` `:` `te`. The
adapter rejoins exactly that shape — a literal `lgx` followed by a `:` token —
and trims the prefix bash will not replace from each candidate. Words after the
command pass through untouched, because once bash has split them it can no
longer tell `foo:bar` from `foo: bar`. A consequence lgx does not currently fix
(and did not before either): an *argument* containing `:` or `=` is split into
several words, which inflates the argument count and can silence enum
completion for later positions. e2e Scenario 134 covers the rejoin against the
real script.

`lgx __complete` prints one candidate per line: the built-in command
names (a def in `lgx/completion.lg`, kept in sync with `dispatch` by
hand; `completion` and `__complete` stay hidden) plus the enclosing
project's task names, prefix-filtered and sorted. Candidates appear
only at the command position; after a command, or when the cursor is
on a flag or a `--with` value, it prints nothing and the shell falls
back to file completion (which suits `lgx run <script>` and
`lgx test <file>`). The handler reads the config through the
non-throwing path (`config/find-project`, `config/load-config`),
swallows every error, and always exits 0: a broken `lgx.edn` drops the
task names but never breaks the user's shell.

## State layout

```
$LGX_HOME/
  gitlibs/<host>/<owner>/<repo>/<ref>/
  templates/<host>/<owner>/<repo>/<sha>/
  test-runner/lgx-test-<version>.lg
  runtimes/<hash>/{src/,lg}
```

`LGX_HOME` defaults to `~/.lgx`. Gitlib cache paths are pure functions
of the git URL and ref. For `:git/sha` coords, `<ref>` is the sha. For
`:git/tag` coords, `<ref>` is the tag with `/` replaced by `_`. Each
leaf is a read-only worktree. The `test-runner` directory holds the
generated test harness. The `templates/` tree parallels
gitlibs but uses sha-only keying — populated by `lgx new` on first use
and reused on subsequent runs. `runtimes/` holds the `lg` binaries
built for `:lg-runtime :built` projects and their cross-build bases,
keyed by a hash of the let-go version, the whole Go coord set, and -
when cross-compiling - the target platform, so each platform gets its
own entry while native builds keep their pre-target hashes (see
[Go deps](#go-deps) and
[`knowledge-base/lgx-go-runtimes.md`](knowledge-base/lgx-go-runtimes.md)).
`lgx clean` removes these caches on request (`--runtimes`, `--gitlibs`,
`--templates`, `--all`; `--dry-run` only reports) - never automatically,
never outside `$LGX_HOME`, and never through a symlinked cache root.

By default, `cache/ensure-lib!` returns `<ref>/src/` if that
subdirectory exists, otherwise `<ref>/`. This matches the `tools.deps`
default of `:paths ["src"]` and works for most Clojure-style libraries
without per-coord configuration.

A coord may set `:deps/root <relative-path>` to override the default
probe. lgx then uses `<ref>/<deps/root>` verbatim as the source path —
no further probing. The value must be a relative path with no `..`
segments; if the directory does not exist after clone, `ensure-lib!`
throws. This handles libs that ship sources under non-standard
locations, e.g. `org.clojure/tools.cli` with `:deps/root "src/main/clojure"`.

`:deps/root` also relocates where the dep's own `lgx.edn` is read
(`config/dep-config-dir`): when `<ref>/<deps/root>/lgx.edn` exists — a
monorepo package — that file is authoritative and its children resolve
their relative `:local/root`/`:go/local` against the package directory.
When it does not — the tools.cli layout, metadata at the repo root —
lgx falls back to the checkout root, which keeps the old behavior. The
`deps.edn`/`project.clj` ladder always reads from the checkout root:
those files belong to other tools with their own conventions.

### Local deps

A coord may use `:local/root <path>` instead of `:git/url`. For top-level
coords, a relative path is resolved against the project root. For
transitive coords, a relative path is resolved against the dependency
root that declared it. Local coords bypass the gitlibs cache, never
clone, and never appear in install output.

Local deps use the same source path rule as git deps: `:deps/root`
overrides the default probe; otherwise lgx uses `<local>/src/` when it
exists and `<local>/` when it does not. lgx reads a local lib's own
`lgx.edn` for transitive `:deps`, just as it does for git deps.

### Go deps

A third coord family, `:go/*`, names a Go package rather than a let-go
source tree. It is validated in `config/coord-errors` (per-coord shape)
and `config/go-deps-errors` (the rules needing the lib symbol: standard
library vs. external, and `cmd/lginterop`'s alias, which is always the
package path's last segment).

Go coords never reach `cache/ensure-lib!`. `gobuild/split-go-coords`
partitions each queue level of `ensure-all!` before it is walked, so a
Go coord produces no source path and no clone but is still collected -
including from a dependency's own `lgx.edn`, which is how a wrapper
library's Go deps flow up to its consumer. `ensure-all!` therefore
returns `{:installs [...] :go-coords [[lib coord] ...] :go-origins {...}}`,
where `:go-origins` maps each Go coord lib to the dep lib whose `lgx.edn`
declared it (nil for the project's own), and `basis` threads both into
its result. The origin is what the `:installed` error and `lgx info` use
to say which dep pulled a Go package in.

Dedup mirrors the source-coord rule: breadth-first, first-wins, with a
warning when a later coord for the same lib differs. Splitting a level
at a time (rather than the whole entry list at once) is what preserves
that ordering. A relative `:go/local` is made absolute against the
declaring file's directory at collection time, while that base is still
known - the same rule `coord-id` applies to `:local/root`.

`apply-runtime!` is the single place the runtime enters a command. It
runs right after the basis, because only then are the transitive Go
coords known, and it validates `:lg-runtime` against them rather than
inferring a mode:

- `:installed` (the default): any Go coord is an error
  (`gobuild/installed-go-deps-error`, naming each coord and its origin);
  otherwise run `check-lg-version!` as before and return nil. Go is
  never invoked.
- `:built`: a user-set `LGX_LG` is an error
  (`gobuild/built-lg-override-error`), checked before the Go preflight
  and before any build; then `gobuild/preflight!` (Go on `PATH`),
  `gobuild/ensure-runtime!` with the project's Go coords (an empty set
  renders a stock module at the pin), and `LGX_LG` pointed at the built
  binary so `runner.lg` picks it up unchanged. Returns the path.

Config load already guarantees the pin shape per mode
(`config/lg-runtime-errors`): `:built` requires `:lg-version`, and
`:installed` accepts only a released semver, since a sha or branch can
never match `lg -v`. `check-lg-version!` does not run under `:built` -
the runtime is built from the pin by construction, and the check would
only be probing whichever `lg` happens to be on `PATH`. lgx stamps
`LGX_LG_AUTO` alongside `LGX_LG` so a nested `lgx` can tell its parent's
runtime from a genuine user override.

`lgx build` additionally injects `-bundle-base <runtime>` into the argv
before `-b`, unless the user passed their own. `lg -b` copies the
running binary as its base, and a stock `lg` base would produce an app
whose Go namespaces do not resolve. For a cross-build the injected base
is a *target-platform* runtime (`ensure-runtime!` with a `{:os :arch}`
target, which joins the cache hash and sets `GOOS`/`GOARCH`/
`CGO_ENABLED=0` on the final `go build`) — see the runtime decision
table under [`lgx build`](#lgx-build-args).

## Transitive resolution

Most Clojure libraries have never heard of lgx. They declare their
dependencies in a `deps.edn` or a `project.clj`, in Maven coordinates lgx
cannot fetch. The gap this closes is **discovery**: without it, a missing
transitive dep surfaces as a confusing require-time failure somewhere
inside the library, and the fix — finding the right repo and tag by hand —
is guesswork the tool can often do or at least explain.

Gitlibs remains the only resolution mechanism. `:mvn/version` is not a
coord lgx accepts; writing one in `lgx.edn` is a validation error that
names the substitution.

### Source ladder

Coords for a fetched dep come from the first source it has:

1. its own **`lgx.edn`** — resolved exactly as the project's own, and
   `deps.edn`/`project.clj` go unread;
2. else its **`deps.edn`** — top-level `:deps` only; `:aliases` describe
   how to develop that library, not what consuming it requires;
3. else its **`project.clj`** — the top-level `:dependencies` vector of a
   `(defproject …)` form, with `[lib "1.2.3"]` read as
   `{:mvn/version "1.2.3"}`. Profiles are out of scope.

Selection is by **file existence, not by result**. A `deps.edn` that
declares nothing is authoritative: `{}` legitimately means zero deps, and
a stale `project.clj` beside it must not resurrect old ones.

Both readers (`config/declared-deps-at`, `config/project-clj-deps-at`) are
total. A missing file, a parse failure, an unexpected shape — each yields
`[]`. These files belong to third parties and were written for another
tool; failing a user's build over one is never the right trade.

### Classifying one declared dep

After dropping anything the consuming coord `:exclusions` and the built-in
skip list (`org.clojure/clojure`, `org.clojure/spec.alpha`,
`org.clojure/core.specs.alpha`, which let-go supplies),
`config/classify-declared` decides what each declaration means:

| Declared shape | Action |
|---|---|
| `:git/url` + `:git/sha`/`:sha`/`:git/tag` | resolve as-is — already pinned |
| `io.github.X/Y` or `com.github.X/Y` with a ref, no `:git/url` | resolve against `https://github.com/X/Y` — these groups name their owner, so the URL is a fact |
| `:mvn/version`, lib in the registry | resolve via `lgx/registry.lg`: its `:git/url` plus `:tag-format` applied to the declared version |
| `:mvn/version`, lib name is a URL-certain group | probe `git ls-remote` for tags `<version>` then `v<version>`; resolve on a hit |
| `:mvn/version`, unknown | warn |
| `:local/root` (non-blank) | resolve relative to the declaring dep's own directory |
| anything else | warn |

Auto-resolved children recurse in the same walk and carry provenance, which
`print-installs!` appends:
`weavejester/dependency -> …  (via integrant/integrant deps.edn)`.
First-wins dedup is unchanged, and every top-level coord is queued before
any child, so a coord you list yourself always overrides what a dep
declares — that is the escape hatch when the ladder cannot pin something.

### The registry

`lgx/registry.lg` maps Maven coordinates to git repositories. It exists
because the mapping is rarely guessable: the coordinate group usually is
not the GitHub owner (`integrant/integrant` lives at
`weavejester/integrant`, `aero/aero` at `juxt/aero`, `org.clojure/*` at
`clojure/*`), and tag naming is per-project (`1.0.1` here, `v1.4.256`
there).

Every row is verified fact — URL and tag format checked against the live
repo, group name against Clojars — not inference. Entries are seeded from
`examples/clojure-libs/`, the set already known to run under let-go, plus
the deps those libraries declare. A miss is never an error; it falls to a
warning.

`:tag-format` is one string per repository, so it describes how that
project tags *now*. A version predating a scheme change resolves to a tag
that does not exist, which surfaces as a warning rather than a wrong
checkout.

### Error containment

Anything that goes wrong while acting on third-party metadata degrades to
a warning and the walk continues: a registry tag that moved, an inferred
URL that 404s, a clone that fails, a coord malformed enough that
normalizing it throws. The status quo without this feature is "not
resolved at all", so failing soft is strictly better than failing the
command. Coords from the user's own `lgx.edn` keep their hard errors.

### Warnings

Emitted **after the walk completes**, so a dep resolved later in
breadth-first order never falsely warns. One line per miss, quoting the
declaration verbatim — including when the coord lgx synthesized from it is
what actually failed, since the declared version is what the reader needs:

```
warning: integrant/integrant declares weavejester/dependency {:mvn/version "0.2.1"} - not resolved by lgx; add a :git coord to lgx.edn :deps or exclude it (see examples/clojure-libs/)
```

Two filters apply. First, a declaration that matches something already
resolved is silent — by normalized URL when it carries one, else by lib
symbol, else by artifact segment, so a dep asking for
`weavejester/dependency` stays quiet when you pinned
`dev.weavejester/dependency`. This is a heuristic and only ever silences a
warning; it never decides what gets resolved.

Second, gating by command. **`lgx install` shows every pending warning**:
it is the deliberate dependency-management moment, and doubles as the way
to re-read them. `run`/`build`/`test` warn only about deps whose declaring
lib was freshly installed in that walk, so a warm cache stays quiet in the
day-to-day loop and a deliberately partial setup is not nagged.

### `:exclusions`

Any coord may carry `:exclusions [lib-sym …]` — tools.deps vocabulary,
scoped to the consuming dep. The listed symbols, matched exactly as that
dep writes them in its own `deps.edn`/`project.clj`, are skipped entirely:
no resolution, no warning. This is the permanent silence for a transitive
dep you know you do not need.

It differs from tools.deps in applying to a dep's direct declarations
rather than a whole subtree — observably the same for the shallow trees
this ecosystem has, and documented rather than hidden. When a Maven
declaration carrying `:exclusions` is resolved through the registry or a
probe, the exclusions ride along onto the synthesized coord.

### Coord ordering

Coord pairs come out of a map, and let-go's map iteration order follows the
bundle's intern layout: it is neither insertion order nor stable across
unrelated edits. That order is observable — it decides which of two
conflicting sibling coords first-wins keeps, and the precedence of dep
source paths when two deps ship the same namespace — so every coord map
reaches the resolver through `config/dep-pairs`, ordered by lib name.
Resolution does not depend on lgx.edn declaration order, which the EDN
reader discards anyway.

### Out of scope

`:mvn/version` as an lgx.edn coord, deps.edn `:aliases`/`:paths`,
project.clj profiles, and version mediation beyond first-wins. A
Maven-resolution subsystem was designed and deliberately parked; see
[`plans/2026-08-05-0228-mvn-deps.md`](plans/2026-08-05-0228-mvn-deps.md).

## External dependencies

- **`git`** on `PATH` — clone and checkout. lgx never bundles git.
- **`lg`** — either on `PATH` or pointed to by `LGX_LG`. `lgx run` fails
  loudly if `lg` is missing; `lgx install` does not need it. lgx exports
  `LG_READ_CLJ=1` before every spawn so `.clj` library files are
  resolvable and `:clj` reader-conditional branches match; `.clj` library
  support requires let-go ≥ vN.N (**TODO before merge:** fill in once
  upstream tags a release).
- **Default template repo** — `lgx new` pulls from
  `https://github.com/abogoyavlensky/lgx-template-base` at a sha pinned
  in lgx source. Override with `LGX_TEMPLATE_BASE_URL` and
  `LGX_TEMPLATE_BASE_SHA`; both blank or unset → defaults.
- let-go-side changes lgx depends on, tracked in [`issues/`](issues/):
  - `-source-paths` flag and `LG_SOURCE_PATHS` env var (PR open).
  - `-resource-paths` flag (resource roots for `io/resource`, embedded by
    `-b`), used by `:resource-paths`/`:extra-resource-paths`. Available in
    recent `lg` builds, not yet in a tagged release.
  - `os/run` with inherited stdio so `lgx run -r` REPL works (draft).

## What lgx is not

- **Not a compiler or runtime.** lgx never compiles or executes user
  Clojure code. That's `lg`'s job.
- **Not a let-go version manager.** A future `:lg/version` field in
  `lgx.edn` is plausible, but V1 uses whatever `lg` is on `PATH` or
  `LGX_LG`.
- **Not a lockfile system.** `lgx.edn` itself is the lock when coords
  use `:git/sha`. Tag-pinned coords re-resolve on each `install`.
