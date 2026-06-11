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
shells out to — usually whatever sits on `PATH`, or whatever `LGX_LG`
points to. This separates lgx's release cadence from let-go's:
upgrading let-go does not require rebuilding lgx, and vice versa.

For git operations, lgx shells out to the system `git` rather than
vendoring a git library. Every package manager that started with an
embedded git library ended up shelling out for edge cases anyway.

## Components

```
lgx.lg              ns lgx.main — entry, subcommand dispatch, basis/overlay wiring
lgx/cli.lg          pure argv parsing: program-prefix strip, leading --verbose/--with, nrepl --port
lgx/config.lg       find lgx.edn (walks up), load + validate + normalize it once per invocation; the format lives here as one schema value; pure accessors over the loaded map
lgx/spec.lg         minimal schema-as-data validation engine: validate -> [{:path :msg} ...] (collects all errors, never throws), error->line rendering
lgx/cache.lg        gitlibs cache layout, fetch via git
lgx/path.lg         portable filesystem path helpers (join, parent)
lgx/runner.lg       locate lg, invoke with -source-paths / -resource-paths
lgx/tasks.lg        execute project tasks declared in lgx.edn :tasks
lgx/new.lg          scaffold a new project from the default template
lgx/style.lg        colored status headers (green built-ins, purple tasks), LGX_NO_COLOR gate
```

Leading global options (`--verbose`, `--with a,b`) are parsed by `lgx/cli.lg`
before the subcommand and removed from the argv `lgx.main` dispatches on.
`--with` names contexts (see [Contexts](#contexts)) and applies to
`run`/`nrepl`/`build`/`test`/`install`/tasks.

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
   `:tasks :lint :do [0] — unknown key :shh (allowed: :sh, :run)`) — then
   exits 1, with no stack trace. The config is loaded once per invocation;
   every basis command (`install`/`run`/`nrepl`/`build`/`test`/tasks) and the
   task-name fallback in dispatch go through `load-config!`.
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
4. After a dep resolves, read that dep's own `lgx.edn` if present and
   append only its `:deps` entries to the queue. Other top-level keys in
   a dep's config are ignored by consumers (open-map leniency in
   `config/coords-at`); an invalid `:deps` there reports
   `lgx: invalid lgx.edn in <dir> (N errors)` and exits 1. Duplicate lib
   names are first-wins: a later differing coord is skipped with a
   warning. The seen set also terminates cycles.
5. If any dep was newly cloned, print `installing N dep(s)...`, one
   `<lib> -> <path>` line per **new** dep, and `done`. If every dep was
   already cached, print `all deps up to date`. Empty `:deps` prints
   `no deps in lgx.edn`.

### `lgx run [args...]`

Steps 1–4 match `install` — deps are auto-installed if missing. Then:

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

If `lgx.edn` sets top-level `:main`, lgx may substitute it as the
script argument. Four rules apply to `cmd-run`; first match wins:

1. **No forwarded args + `:main` set** → inject `:main` *and* append
   a trailing `--`. Output: `lg <lg-flags> <main> --`. The trailing
   `--` is what makes the script's `os/args` parsing idiom universal
   across dev mode and a built binary (where `--` is naturally absent).
2. **`--` present + pre-`--` slice contains a script** (suffix `.lg`,
   `.cljc`, or `.clj`) → no inject; pass forward-args through verbatim
   so the user's explicit script reaches `lg`. Output:
   `lg <lg-flags> <pre> -- <post>`.
3. **`--` present + pre-`--` slice contains no script** → inject
   `:main` between the pre slice and the `--`. Output:
   `lg <lg-flags> <pre> <main> -- <post>`. With `:main` unset, lgx
   exits with `lgx: -- requires :main to be set in lgx.edn`.
4. **Anything else** → strict; pass forward-args through verbatim.
   (`lgx run foo.lg`, `lgx run -e '(...)'`, `lgx run -r` all
   pass through unchanged.)

The `--` is preserved in the outgoing argv when present in the user's
invocation, so it lands in the script's `os/args` as a stable marker.
A user script slices `(rest (drop-while #(not= "--" %) os/args))` to
find its own args; lg's own flags (e.g. `-source-paths`) live before
`--` and never reach a POSIX-style CLI parser. Only the *first* `--`
is treated as the separator; later `--` tokens are literal args
(standard getopt convention).

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
so output streams live and interactive children work — bare `lgx run`
without `:main` lands in `lg`'s REPL, and `lgx run -r <script>` can
drive it. `lgx test`, `lgx build`, and task `:run` steps still use the
captured `os/sh` path (`runner/run-lg!`/`invoke-lg!`): `test` must
inspect lg's output to strip its harness marker, and the others keep
buffered-and-replayed output. (History: the inherited-stdio runner was
tracked in [`issues/inherit-stdio-runner.md`](issues/inherit-stdio-runner.md),
resolved upstream by `os/exec*`.)

### `lgx nrepl [--port N]`

Steps 1–4 match `install` (deps auto-installed, `--with` contexts
apply), and `:paths`/`:resource-paths` resolve exactly as in `lgx run`.
Then:

5. Parse the command's own args with `cli/parse-nrepl-args`: `--port N`
   must be an integer in 1–65535; anything else exits 1 with a clear
   error. No flag → lgx picks a random port in the IANA ephemeral range
   (49152–65535). lg writes the literal `-p` value to `.nrepl-port`, so
   the random pick must happen in lgx — port 0 (OS-assigned) would
   record `0`.
6. Exec `lg <lg-flags> -n -p <port>` via `runner/exec-lg-interactive!`.
   With no script argument, lg starts the nREPL server (printing
   `nREPL server started on port N ...` and writing `.nrepl-port` in the
   cwd) and opens its terminal REPL in the same process.

On a port collision lg prints `failed to run nREPL server on port N`
and still opens the terminal REPL; rerunning picks a fresh random port.
Unlike `cmd-run`, `cmd-nrepl` does not set `LGX_RUN` — that var
advertises script-arg handling to a spawned program, which doesn't
apply to a REPL session. `nrepl` is a reserved task name
(`config/reserved-task-names`), so a project task can't shadow it.

### `lgx build [args...]`

Steps 1–4 match `install`. Then:

5. Read `:main` and `:targets/:bin` from the validated config. Either
   being absent exits 1 with a clear error (`lgx: :main is required for
   build` / `lgx: :targets/:bin is required for build`).
6. Verify the `:main` script exists on disk (resolved against the
   project root). Missing → `lgx: :main script not found: <path>` and
   exit 1.
7. Resolve `:targets/:bin/:out` to an absolute path under the project
   root and `mkdir` its parent (recursive, idempotent).
8. Exec `lg -source-paths <X> -resource-paths <R> [forwarded-args...] -b
   <abs-out> <abs-main>`. The source/resource flags come first, then the
   forwarded args extend `lg`'s flag list before `-b` (real example:
   `-bundle-base /path/to/lg` for cross-OS builds). With `-b`, `lg` embeds the
   resources under `<R>` into the binary, so a bundled app resolves
   `io/resource` with no files alongside it. Both `-b` target and main script
   are absolute paths so `lgx build` produces the same artifact regardless of
   which subdirectory of the project the user invoked it from.

`lgx build` shares `resolve-main-script!` and the project-basis
resolution with `lgx run`; the only structural difference is the
argument shape and the required-config / mkdir steps.

### `lgx test`

Steps 1–4 match `install`. Then:

5. Resolve `<project-root>/test`. If it does not exist (or is not a
   directory), exit 1 with `lgx: no test/ directory in project` on
   stderr.
6. Select the test files. If a positional `<file>` arg is provided,
   resolve it to an absolute path (project-root-relative inputs are
   joined against the project root), then `path/normalize` away any
   `.`/`..` segments and validate it against three rules:
   - file exists on disk →
     `lgx: test file not found: <path>` on stderr + exit 1 if not.
   - extension is `.lg`, `.cljc`, or `.clj` →
     `lgx: not a test file (expected .lg, .cljc, or .clj): <path>` + exit 1
     if not.
   - normalized absolute path starts with `<abs test-dir>/` →
     `lgx: test file must be under test/: <path>` + exit 1 if not.
   On success, the test plan is a one-entry vector with that file.
   With no arg, walk `test/` recursively for `*_test.lg`,
   `*_test.cljc`, and `*_test.clj` files. If the walk returns no files,
   print `No tests found in test/` and exit 0.
7. Map each absolute path to a namespace symbol: strip `test/` prefix
   and the extension, split on `/`, hyphenate `_` per segment, join
   with `.` (e.g. `test/lgx/config_test.lg` → `lgx.config-test`).
   This is the reverse of let-go's resolver rule
   ([`docs/knowledge-base/let-go-resolver.md`](knowledge-base/let-go-resolver.md)).
8. Generate a one-shot harness `.lg` source string that `:require`s
   every discovered ns plus `test`/`string`/`os`, embeds the discovered
   `[file ns]` test plan, and iterates each file's entries in
   `*registered-tests*`. Each `deftest` runs under `with-out-str` so
   passing `PASS <form>` assertion chatter is suppressed while counters
   still update. The harness prints the test file, a `✓`/`✗` line per
   `deftest`, any `testing` context strings, and failure/error details
   only for failing tests. The opening `Running tests in <header>...`
   banner is printed by lgx itself (green, on stderr — see
   [Output styling](#output-styling)), not the harness; walk-mode passes
   `test/`, single-file mode the entry's display path (e.g.
   `test/foo_test.lg`). The harness ends with a `N tests, M assertions,
   K failures` summary and
   `(os/exit (if (zero? failures) 0 1))`. As its first body form (right
   after the `:require` loads every test ns) it writes a `harness-ready`
   marker to stderr; this splits lg's captured stderr into pre-harness
   load diagnostics and test-emitted output (see step 10). Write it to
   `$LGX_HOME/tmp/lgx-test-<version>.lg`, overwriting the previous
   harness for the same lgx version.
9. Compute `-source-paths` as project paths + dep paths + the
   absolute `test/` path (so test namespaces can `require` each other
   and the harness can `require` them). Compute `-resource-paths` as the
   project's resolved resource roots (project-only; the `test/` dir is *not*
   added as a resource root).
10. Run `lg -source-paths <X> -resource-paths <R> <harness-path>` and capture
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

`lgx test` accepts 0 or 1 positional arg. Passing 2 or more prints
`lgx: test takes at most one argument` on stderr and exits 1. Under
`--verbose`, the trace also includes the harness path on stderr so
the user can inspect the generated file.

### `lgx <task>`

After built-in dispatch, lgx looks up `<task>` (as a keyword) in the
project's `:tasks` map. If present, lgx resolves the project basis the
same way `lgx run` does (steps 1–4 above) and walks the task's `:do`
vector. Config validation accepts `:do` as either a single step map or a
vector of steps, then normalizes the single-map form to a one-item vector
before execution walks it. Each step is one of:

- `{:sh <string-or-vector>}` — joined with spaces and run via
  `sh -c <cmd>`. Captured stdout/stderr is replayed after the child
  exits.
- `{:run <string-or-vector>}` — invoked through the same internal path
  as `lgx run`, with the project's resolved `-source-paths` and
  `-resource-paths`. String forms are whitespace-split into argv.

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

Task names that collide with built-in commands
(`run`, `install`, `new`, `build`, `test`, `add`, `update`, `tasks`,
`help`, `version`) are rejected at validation time — overriding
built-ins is reserved for later via an `:lgx/<name>` form.

### Contexts

A `:contexts` entry is a named overlay carrying only `:extra-deps`/
`:extra-paths`/`:extra-resource-paths` — the per-task extras, lifted to the top
level for reuse. They are applied by the CLI `--with a,b` flag (any command)
and a task's `:with` vector. `config/context-overlay` resolves an ordered name
list to a single `{:deps-pairs :paths :resource-paths}` overlay, folding
overlap among the named contexts last-wins via `config/merge-coords` (and
throwing on an unknown name; a task's `:with` is additionally validated against
the defined contexts when `lgx.edn` loads). A reference to an undefined context
fails loudly — at config-load for `:with`, at runtime for `--with`.

`overlay-basis` in `lgx.lg` composes the final basis from these layers,
lowest → highest precedence: project `:deps`/`:paths`/`:resource-paths` → task
`:with` contexts (in order) → CLI `--with` contexts (in order) → the task's
inline `:extra-deps`/`:extra-paths`/`:extra-resource-paths` (highest). Deps fold
last-wins through `merge-coords`; source and resource paths concatenate in the
same order (project first, so project namespaces still shadow libs) and are
de-duplicated keep-first. Resource paths layer identically but never pick up dep
dirs (project-only). For `run`/`build`/`test`/`install` there is no task, so
only the project and the CLI `--with` layers apply. `install` resolves the same
overlay so it pre-fetches a context's deps.

### `lgx new <project-name>`

Scaffolds a new project directory from a hardcoded default template.
The command never touches an existing project's `lgx.edn`.

1. Validate `<project-name>` against `^[a-z][a-z0-9-]*$`. Bad input →
   `lgx: invalid project name: <input>` plus the rule description on
   the next line, exit 1.
2. Resolve the target dir as `<cwd>/<project-name>`. If it exists as
   a regular file or as a non-empty directory, exit 1 with
   `lgx: target exists and is not a directory: <path>` or
   `lgx: target directory already exists and is not empty: <path>`.
   An empty pre-existing directory is allowed; the render lays files
   into it.
3. Resolve the template coord. Default is
   `{:git/url "https://github.com/abogoyavlensky/lgx-template-base"
   :git/sha "<pinned>"}`. Both fields may be overridden by the env
   vars `LGX_TEMPLATE_BASE_URL` and `LGX_TEMPLATE_BASE_SHA`; blank or
   unset envs fall back to the default. Sha-pin only — tag-pinned
   templates are deferred to the future `-t/--template <git-url>`
   flag.
4. Ensure the template is cached under
   `$LGX_HOME/templates/<host>/<owner>/<repo>/<sha>/`. If the leaf
   exists, reuse it. Otherwise clone via `cache/clone-sha!` (same
   atomic clone-into-tmp → checkout → drop-`.git/` → mv pattern used
   for `:deps`). Clone failures replay `git`'s stderr after a
   `lgx: failed to fetch template:` prefix, exit 1.
5. Walk the cached template recursively. For each source file, compute
   a destination relative to the target by replacing every
   `projectname` path segment with the underscored form of the project
   name (`my-app` → `my_app`). Then `mkdir` the destination's parent,
   `slurp` the source, replace every `projectname` in the contents
   with the hyphenated form of the project name (verbatim user input,
   `-` preserved), and `spit` to the destination.
6. Print `Created <name> at <abs>` followed by a two-line next-steps
   block (`cd <name>` / `lgx run`).

The unified `projectname` token splits along the natural axis: path
segments need `_` per let-go's resolver, while file contents (ns
forms, README display name, binary name in `lgx.edn`) want `-`. The
template repo holds one form of the token; the substitution rule
encodes the per-site form.

No git init or initial commit in the new project — the user owns the
choice of VCS.

## State layout

```
$LGX_HOME/
  gitlibs/<host>/<owner>/<repo>/<ref>/
  templates/<host>/<owner>/<repo>/<sha>/
  tmp/lgx-test-<version>.lg
```

`LGX_HOME` defaults to `~/.lgx`. Gitlib cache paths are pure functions
of the git URL and ref. For `:git/sha` coords, `<ref>` is the sha. For
`:git/tag` coords, `<ref>` is the tag with `/` replaced by `_`. Each
leaf is a read-only worktree. The `tmp` directory holds generated lgx
runtime files such as the test harness. The `templates/` tree parallels
gitlibs but uses sha-only keying — populated by `lgx new` on first use
and reused on subsequent runs.

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

## External dependencies

- **`git`** on `PATH` — clone and checkout. lgx never bundles git.
- **`lg`** — either on `PATH` or pointed to by `LGX_LG`. `lgx run` fails
  loudly if `lg` is missing; `lgx install` does not need it. lgx exports
  `LG_READ_CLJ=1` before every spawn so `.clj` library files are
  resolvable and `:clj` reader-conditional branches match; `.clj` library
  support requires let-go ≥ vN.N (**TODO before merge:** fill in once
  upstream tags a release). It also exports
  `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` before every spawn to silence lg's
  source-paths transition notice — lgx owns the search path and always
  passes an explicit `-source-paths` that omits `.`.
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
