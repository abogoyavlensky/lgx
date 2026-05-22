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
lgx.lg              ns lgx.main — entry, argv parsing, subcommand dispatch
lgx/config.lg       find lgx.edn (walks up), parse and validate :deps/:paths/:tasks
lgx/cache.lg        gitlibs cache layout, fetch via git
lgx/path.lg         portable filesystem path helpers (join, parent)
lgx/runner.lg       locate lg, invoke with -source-paths
lgx/tasks.lg        execute project tasks declared in lgx.edn :tasks
```

`lgx.main` holds the entry point; the other namespaces are stateless helper
namespaces it requires.

## Data flow

### `lgx install`

1. Find the project root by walking up from the current directory until
   a directory contains `lgx.edn`.
2. Read `lgx.edn`, validate the schema
   (`{:paths [<rel-path> ...] :main <rel-path> :targets {:bin {:out <rel-path>}} :deps {<lib> {:git/url … :git/sha or :git/tag … :deps/root <opt>}}}`
   or `{<lib> {:local/root … :deps/root <opt>}}`),
   and return the coord vector.
3. For each coord, call `cache/ensure-lib!`. Git coords compute a cache
   ref first: the sha for `:git/sha`, or the tag with `/` replaced by
   `_` for `:git/tag`. If the cache directory for `(url, ref)` already
   exists, return its path without invoking `git`. Otherwise clone the
   repo into a temp dir, check out the sha for `:git/sha` coords or use
   `git clone --branch <tag> --depth 1` for `:git/tag` coords, drop
   `.git/`, and rename atomically to the final cache path. Local coords
   resolve from disk and never clone. `ensure-lib!` reports whether
   this call did the clone.
4. If any dep was newly cloned, print `installing N dep(s)...`, one
   `<lib> -> <path>` line per **new** dep, and `done`. If every dep was
   already cached, print `all deps up to date`. Empty `:deps` prints
   `no deps in lgx.edn`.

### `lgx run [args...]`

Steps 1–3 match `install` — deps are auto-installed if missing. Then:

4. If any dep was newly cloned during step 3, print the same install
   block as `lgx install` (header + per-new-dep lines + `done`).
   Otherwise stay silent — no `all deps up to date` chatter before the
   script.

If `lgx.edn` sets top-level `:paths`, lgx resolves those
project-root-relative paths to absolute paths and prepends them to the
cached lib paths before the join. Missing entries log a warning to
stderr, but lgx still passes the resolved path through to `lg`.

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
   with the OS path-list separator.
6. Exec `lg -source-paths <paths> [args...]`. Forwarded args reach `lg`
   verbatim.

The exec call currently uses `os/sh`, which buffers stdout/stderr until
the child exits. Streaming output and stdin (so `lgx run -r` can drive
`lg`'s REPL) require an inherited-stdio runner — tracked in
[`issues/inherit-stdio-runner.md`](issues/inherit-stdio-runner.md).

### `lgx build [args...]`

Steps 1–3 match `install`. Then:

4. Read `:main` and `:targets/:bin` from the validated config. Either
   being absent exits 1 with a clear error (`lgx: :main is required for
   build` / `lgx: :targets/:bin is required for build`).
5. Verify the `:main` script exists on disk (resolved against the
   project root). Missing → `lgx: :main script not found: <path>` and
   exit 1.
6. Resolve `:targets/:bin/:out` to an absolute path under the project
   root and `mkdir` its parent (recursive, idempotent).
7. Exec `lg [forwarded-args...] -source-paths <X> -b <abs-out> <abs-main>`.
   Forwarded args come first so they extend `lg`'s flag list before
   `-b` (real example: `-bundle-base /path/to/lg` for cross-OS builds).
   Both `-b` target and main script are absolute paths so `lgx build`
   produces the same artifact regardless of which subdirectory of the
   project the user invoked it from.

`lgx build` shares `resolve-main-script!` and the project-basis
resolution with `lgx run`; the only structural difference is the
argument shape and the required-config / mkdir steps.

### `lgx test`

Steps 1–3 match `install`. Then:

4. Resolve `<project-root>/test`. If it does not exist (or is not a
   directory), exit 1 with `lgx: no test/ directory in project` on
   stderr.
5. Walk `test/` recursively for `*_test.lg` and `*_test.cljc` files.
   `.clj` is not matched — let-go's resolver doesn't load that
   extension. If the walk returns no files, print
   `No tests found in test/` and exit 0.
6. Map each absolute path to a namespace symbol: strip `test/` prefix
   and the extension, split on `/`, hyphenate `_` per segment, join
   with `.` (e.g. `test/lgx/config_test.lg` → `lgx.config-test`).
   This is the reverse of let-go's resolver rule
   ([`docs/knowledge-base/let-go-resolver.md`](knowledge-base/let-go-resolver.md)).
7. Generate a one-shot harness `.lg` source string that `:require`s
   every discovered ns plus `test`/`string`/`os`, embeds the discovered
   `[file ns]` test plan, and iterates each file's entries in
   `*registered-tests*`. Each `deftest` runs under `with-out-str` so
   passing `PASS <form>` assertion chatter is suppressed while counters
   still update. The harness prints the test file, a `✓`/`✗` line per
   `deftest`, any `testing` context strings, and failure/error details
   only for failing tests. It ends with a
   `N tests, M assertions, K failures` summary and
   `(os/exit (if (zero? failures) 0 1))`. Write it to
   `os/temp-dir`/`lgx-test-<rand>.lg`.
8. Compute `-source-paths` as project paths + dep paths + the
   absolute `test/` path (so test namespaces can `require` each other
   and the harness can `require` them).
9. `exec lg -source-paths <X> <harness-path>`. The harness owns the
   `os/exit`, so the exit code reaches the shell unchanged.

`lgx test` accepts no positional args in v1; passing any prints
`lgx: test takes no arguments in this version` and exits 1. Under
`--verbose`, the trace also includes the harness path on stderr so
the user can inspect the generated file.

### `lgx <task>`

After built-in dispatch, lgx looks up `<task>` (as a keyword) in the
project's `:tasks` map. If present, lgx resolves the project basis the
same way `lgx run` does (steps 1–4 above) and walks the task's `:do`
vector. Each step is one of:

- `{:sh <string-or-vector>}` — joined with spaces and run via
  `sh -c <cmd>`. Captured stdout/stderr is replayed after the child
  exits.
- `{:run <string-or-vector>}` — invoked through the same internal path
  as `lgx run`, with the project's resolved `-source-paths`. String
  forms are whitespace-split into argv.

Steps run sequentially. The first non-zero exit code stops the chain
and becomes the task's exit code; lgx exits 0 only when every step
returns 0.

Task names that collide with built-in commands
(`run`, `install`, `build`, `test`, `add`, `update`, `tasks`, `help`,
`version`) are rejected at validation time — overriding built-ins is
reserved for later via an `:lgx/<name>` form.

## Cache layout

```
$LGX_HOME/gitlibs/<host>/<owner>/<repo>/<ref>/
```

`LGX_HOME` defaults to `~/.lgx`. The path is a pure function of the git
URL and ref. For `:git/sha` coords, `<ref>` is the sha. For `:git/tag`
coords, `<ref>` is the tag with `/` replaced by `_`. Each leaf is a
read-only worktree.

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

A coord may use `:local/root <path>` instead of `:git/url`. The path may
be absolute or relative to the project root. Local coords bypass the
gitlibs cache, never clone, and never appear in install output.

Local deps use the same source path rule as git deps: `:deps/root`
overrides the default probe; otherwise lgx uses `<local>/src/` when it
exists and `<local>/` when it does not. lgx does not read the local
lib's own `lgx.edn`, so local deps do not make dependency resolution
transitive.

## External dependencies

- **`git`** on `PATH` — clone and checkout. lgx never bundles git.
- **`lg`** — either on `PATH` or pointed to by `LGX_LG`. `lgx run` fails
  loudly if `lg` is missing; `lgx install` does not need it.
- Two let-go-side changes lgx depends on, both tracked in
  [`issues/`](issues/):
  - `-source-paths` flag and `LG_SOURCE_PATHS` env var (PR open).
  - `os/run` with inherited stdio so `lgx run -r` REPL works (draft).

## What lgx is not

- **Not a compiler or runtime.** lgx never compiles or executes user
  Clojure code. That's `lg`'s job.
- **Not a let-go version manager.** A future `:lg/version` field in
  `lgx.edn` is plausible, but V1 uses whatever `lg` is on `PATH` or
  `LGX_LG`.
- **Not transitive.** lgx reads only the project's `lgx.edn`; it does
  not follow `lgx.edn` files inside fetched libs. Transitive resolution
  is a V2 concern.
- **Not a lockfile system.** `lgx.edn` itself is the lock when coords
  use `:git/sha`. Tag-pinned coords re-resolve on each `install`.
