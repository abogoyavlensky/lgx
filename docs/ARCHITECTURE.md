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
lgx/config.lg       find lgx.edn (walks up), parse and validate :deps
lgx/cache.lg        gitlibs cache layout, fetch via git
lgx/path.lg         portable filesystem path helpers (join, parent)
lgx/runner.lg       locate lg, exec with -source-paths
```

`lgx.main` holds the entry point; the other namespaces are stateless helper
namespaces it requires.

## Data flow

### `lgx install`

1. Find the project root by walking up from the current directory until
   a directory contains `lgx.edn`.
2. Read `lgx.edn`, validate the schema
   (`{:paths [<rel-path> ...] :deps {<lib> {:git/url … :git/sha or :git/tag … :deps/root <opt>}}}`
   or `{<lib> {:local/root … :deps/root <opt>}}`),
   and return the coord vector.
3. For each coord, call `cache/ensure-lib!`. Git coords resolve
   `:git/tag` to a sha via `git ls-remote` if no `:git/sha` is given.
   If the cache directory for `(url, sha)` already exists, return its
   path. Otherwise clone the repo into a temp dir, check out the sha,
   drop `.git/`, and rename atomically to the final cache path. Local
   coords resolve from disk and never clone. `ensure-lib!` reports
   whether this call did the clone.
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

5. Compute the `-source-paths` argument by joining the cached paths
   with the OS path-list separator.
6. Exec `lg -source-paths <paths> [args...]`. Forwarded args reach `lg`
   verbatim.

The exec call currently uses `os/sh`, which buffers stdout/stderr until
the child exits. Streaming output and stdin (so `lgx run -r` can drive
`lg`'s REPL) require an inherited-stdio runner — tracked in
[`issues/inherit-stdio-runner.md`](issues/inherit-stdio-runner.md).

## Cache layout

```
$LGX_HOME/gitlibs/<host>/<owner>/<repo>/<sha>/
```

`LGX_HOME` defaults to `~/.lgx`. The path is a pure function of the git
URL and the resolved sha, mirroring `tools.gitlibs`. Each leaf is a
read-only worktree.

By default, `cache/ensure-lib!` returns `<sha>/src/` if that
subdirectory exists, otherwise `<sha>/`. This matches the `tools.deps`
default of `:paths ["src"]` and works for most Clojure-style libraries
without per-coord configuration.

A coord may set `:deps/root <relative-path>` to override the default
probe. lgx then uses `<sha>/<deps/root>` verbatim as the source path —
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

- **`git`** on `PATH` — clone, ls-remote, checkout. lgx never bundles
  git.
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
