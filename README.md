# lgx

A project manager for [let-go](https://github.com/nooga/let-go): git-based
dependency manager, runner, build tool, test runner, scaffolder, and task
runner, in one binary.

```sh
lgx new myapp        # scaffold a project
cd myapp
lgx run              # fetch deps, run :main
lgx build            # bundle a standalone binary
lgx test             # run tests under test/
lgx <task>           # run a custom task from lgx.edn
```

## Status

Pre-alpha. The CLI surface and `lgx.edn` schema may still change. lgx is
used in some projects today; see [Projects using lgx](#projects-using-lgx).

## Requirements

- [`lg`](https://github.com/nooga/let-go) on `PATH` (or pointed to by
  `LGX_LG`). lgx shells out to it.
  Install with `brew install nooga/let-go/let-go`.
- `git` on `PATH`. lgx uses it to clone, fetch, and check out deps.

## Installation

Prebuilt binaries for `linux_amd64`, `linux_arm64`, `darwin_amd64`, and
`darwin_arm64` are attached to each [GitHub Release](https://github.com/abogoyavlensky/lgx/releases).

### Install script

Installs the latest release to `~/.local/bin/lgx`:

```sh
curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
```

See the [script's README](./scripts/README.md) for options.

### With [mise](https://mise.jdx.dev)

Ad hoc:

```sh
mise use github:abogoyavlensky/lgx@latest
```

Or pin per project in `.mise.toml`:

```toml
[tools]
lg = "latest"
lgx = "latest"

[tool_alias]
lg = "github:nooga/let-go"
lgx = "github:abogoyavlensky/lgx"
```

Then run `mise install`.

> [!TIP]
> If mise hits a GitHub auth problem, pin specific versions in
> `.mise.toml` or set `export GITHUB_TOKEN="$(gh auth token)"` in your
> shell config.

## Quickstart

Create a new project and run it:

```sh
lgx new hello
cd hello
lgx run
```

`lgx new` scaffolds from the [default template](https://github.com/abogoyavlensky/lgx-template-base).
`lgx run` resolves `:main` from `lgx.edn`, fetches any deps under
`$LGX_HOME/gitlibs/`, then execs `lg`.

## Commands

| Command | What it does |
| --- | --- |
| `lgx new <name>` | Scaffold a new let-go project from the default template into `./<name>`. |
| `lgx install` | Fetch deps declared in `:deps` key of `lgx.edn`. Idempotent. |
| `lgx run [args...]` | Run `:main` (or an explicit script) through `lg` with deps on the source path. |
| `lgx build [args...]` | Bundle `:main` into `:targets/:bin/:out` in `lgx.edn` via `lg -b`. |
| `lgx test [file]` | Run `*_test.lg` / `*_test.cljc` / `*_test.clj` files under `test/`. With `<file>`, run just that file. |
| `lgx <task>` | Run a custom task defined under `:tasks` in `lgx.edn`. |
| `lgx help` | Show usage, including project tasks if an `lgx.edn` is found. |
| `lgx version` | Print version. |

Options:

- `--with <a,b,...>` applies one or more named [contexts](#contexts-contexts)
  (reusable `:extra-deps`/`:extra-paths` overlays) to the command. Applies to
  `run`, `build`, `test`, `install`, and user tasks; on a task it unions with
  the task's own `:with`.
- `--verbose` prints the resolved `lg` invocation before running (applies to
  `run`, `build`, `test`, and user tasks). It also prints a `+ env …` line
  listing the env vars lgx sets: `LG_READ_CLJ=1` and
  `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` for every `lg` invocation (the latter
  silences lg's source-paths transition notice, since lgx always passes an
  explicit `-source-paths`), plus `LGX_RUN=1` on `run` paths.

Both options go before the subcommand: `lgx --with dev,test run`.

`lgx run`, `build`, `test`, and tasks find the nearest `lgx.edn` by
walking up from the current directory.

### `lgx run` details

With no arguments, `lgx run` execs `lg <paths> :main --`, injecting a
trailing `--` marker so a script can find where its CLI args begin.
`lgx run` also sets **`LGX_RUN=1`** in the spawned process, so a tool can
tell it is running under `lgx run` (dev) vs. as a bundled binary.

Prefer keying off `LGX_RUN` rather than sniffing for `--`. The `--`-only
idiom is wrong for a bundled binary, where there is no injected marker and
a `--` may legitimately appear inside the user's command (e.g.
`myapp run wt git checkout -- file`):

```clojure
(defn- cli-argv [argv]
  "Application args, in both dev (lgx run) and bundled-binary modes."
  (if (str/blank? (os/getenv "LGX_RUN"))
    (rest argv)                                 ; ./bin/myapp <args>
    (rest (drop-while #(not= "--" %) argv))))   ; lgx run -- <args>
```

Forms:

- `lgx run` -> `lg <paths> :main --`.
- `lgx run -- foo bar` -> `lg <paths> :main -- foo bar` (requires `:main`).
- `lgx run -r -- foo` -> `lg <paths> -r :main -- foo` (lg flags before `--`).
- `lgx run foo.lg` -> `lg <paths> foo.lg` (explicit script, pass-through).
- `lgx run foo.lg -- bar` -> `lg <paths> foo.lg -- bar`.
- `lgx run -e '(...)'` -> pass-through.

### `lgx build` details

`lgx build` is shortcut for `lg <paths> [extra-args...] -b <:out> <:main>`.
Extra args go before `-b`, so cross-OS bundling works as:

```sh
lgx build -bundle-base /path/to/lg
```

Both `:main` and `:targets/:bin` are required.

### `lgx test` details

`lgx test` walks `test/` for `*_test.lg` / `*_test.cljc` / `*_test.clj` files, generates
a one-shot harness under `$LGX_HOME/tmp/`, and runs every `deftest`
against the project's resolved `-source-paths`. Prints summary results.

A test file may contain `deftest` forms, fixtures and some helpers.

```clojure
(ns myapp.list-test
  (:require [test :refer [deftest is testing]]
            [myapp.format :as fmt]))

(deftest render-list-empty
  (testing "empty list"
    (is (= "(empty)" (fmt/render-list [])))))
```

The path-to-namespace rule mirrors let-go's resolver:
`test/myapp/config_test.lg` resolves to `myapp.config-test`. Underscores
become hyphens; `/` becomes `.`.

## Configuration: `lgx.edn`

`lgx.edn` lives at the project root. The smallest valid file:

```edn
{}
```

Top-level keys: `:paths`, `:resource-paths`, `:deps`, `:main`, `:targets`,
`:tasks`, `:contexts`.

### Source paths and entrypoint

```edn
{:paths ["src"]
 :main  "main.lg"}
```

- `:paths` lists project source paths relative to the project root.
  `lgx run` prepends them to dependency paths so project namespaces
  shadow lib namespaces. Missing entries print a warning.
- `:main` names the default entrypoint script. `lgx run` substitutes it
  when no script is given; `lgx build` bundles it.

### Resource paths (`:resource-paths`)

```edn
{:resource-paths ["resources"]}
```

- `:resource-paths` lists project-relative directories that hold resources
  (templates, data files, static assets) reachable from `(io/resource "…")`.
  lgx passes them to `lg` as `-resource-paths`.
- `lgx run` and `lgx test` make the resources resolvable at runtime; `lgx
  build` **embeds** every resource under these roots into the bundled binary,
  so `io/resource` keeps working with no files alongside the executable.
- Missing entries print a warning, same as `:paths`. Unlike source paths,
  resource roots come only from your project (its top level plus any applied
  contexts/tasks) — dependencies never contribute resource roots.

### Dependencies (`:deps`)

```edn
{:deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}

  org.clojure/tools.cli  {:git/url "https://github.com/clojure/tools.cli"
                          :git/sha "0123456789abcdef0123456789abcdef01234567"
                          :deps/root "src/main/clojure"}

  my/lib                 {:local/root "../my-lib"}}}
```

Each coord uses either a git source or `:local/root`, never both.

- **Git coord.** `:git/url` plus one of `:git/sha` or `:git/tag`.
  Tag-pinned coords cache under the tag name itself. HTTPS URLs only
  (no SSH).
- **Local coord.** `:local/root` points at a directory on disk, relative
  to the project root or absolute. Local deps bypass the gitlibs cache.
- **`:deps/root`** (optional). The subdirectory inside the dep that holds
  the source. Defaults to `src` if that directory exists, else the repo
  root. Matches tools.deps' `:deps/root`.

### Transitive dependencies

lgx follows transitive deps: after fetching a dep, it reads that dep's own
`lgx.edn` (if it ships one) and resolves its `:deps` too, recursively. Only
a dep's `:deps` is consulted — its `:paths`, `:main`, `:tasks`, and
`:targets` describe how to build *that* project, not how to consume it.

Resolution is breadth-first from your project, and conflicts are
**first-wins**: the first coord seen for a given lib name is kept, and a
later, differing coord for the same lib is skipped with a warning on
stderr. A coord you list directly therefore overrides the same lib pulled
in transitively. (Git coords have no version ordering, so first-wins —
shallowest — is the resolution rule; pin the exact coord you want at the
top level to override a transitive one.)

> [!NOTE]
> This is a behavior change from earlier lgx, which resolved only the
> coords in your own `lgx.edn`. If you depend on a lib that ships its own
> `lgx.edn` with `:deps`, those deps are now fetched as well.

### Build target (`:targets`)

```edn
{:main    "main.lg"
 :targets {:bin {:out "bin/myapp"}}}
```

Currently, supports the `:bin` target only. `:out` is the output path
relative to the project root; lgx creates the parent directory if
missing.

### Tasks (`:tasks`)

Tasks replace ad-hoc Makefile or Taskfile recipes for let-go projects.
A task is a sequence of steps; each step is either `:sh` (shell command)
or `:run` (invoked like `lgx run ...` with the project basis). The first
non-zero exit code stops the chain.

```edn
{:tasks
 {:lint {:doc "Run clj-kondo against the project"
         :do  [{:sh "clj-kondo --lint src test"}]}

  :ci {:doc "Format check, lint, and tests"
       :do  [{:sh "cljfmt check"}
             {:sh "clj-kondo --lint src test"}
             {:run "test/myapp/smoke.lg"}]}

  :greet {:doc "Run main with a fixed arg"
          :do  [{:run ["main.lg" "--" "world"]}]}}}
```

Run a task with `lgx <name>` (for example, `lgx ci`). `lgx help` lists
tasks defined in the current project. Task names are keywords; they
cannot shadow built-in commands (`install`, `run`, `build`, `test`,
`new`, `help`, `version`, plus reserved `add`, `update`, `tasks`).

Step values may be a string (split on whitespace) or a vector of
strings. Output is buffered and replayed after each step completes.

A task may contain only `:doc`, `:do`, `:extra-paths`, `:extra-resource-paths`,
`:extra-deps`, and `:with`; any other key is rejected (so a typo like
`:extra-dep` fails loudly).

#### Per-task `:extra-paths`, `:extra-resource-paths`, and `:extra-deps`

A task may declare extra source paths, resource roots, and dependencies
that apply to *that task's* `:run` steps only:

```edn
{:tasks
 {:repl {:doc         "REPL with dev-only tooling"
         :extra-paths ["dev"]
         :extra-deps  {some/nrepl {:git/url "https://github.com/x/nrepl"
                                   :git/tag "v1"}}
         :do          [{:run "dev/repl.lg"}]}}}
```

- `:extra-paths` — extra project-root-relative source dirs, same rules as
  top-level `:paths`. Appended after the project's `:paths`.
- `:extra-resource-paths` — extra project-root-relative resource roots, same
  rules as top-level `:resource-paths`. Appended after the project's
  `:resource-paths`.
- `:extra-deps` — extra coords, same grammar as top-level `:deps` (git,
  `:local/root`, `:deps/root`). Fetched on first run like any dep.

These augment the `-source-paths` and `-resource-paths` for the task's `:run`
steps. `:sh` steps are plain shell and are unaffected. When an `:extra-deps`
coord names a lib already in the project's top-level `:deps`, the extra coord
wins for that task only (a silent override) — other commands still use the
project coord.

These per-task extras are the task-private, anonymous form of a
[context](#contexts-contexts): use them for one-off extras, and named
`:contexts` + `:with` when an overlay is shared across tasks or commands.

### Contexts (`:contexts`)

A **context** is a named, reusable overlay of `:extra-paths`,
`:extra-resource-paths`, and `:extra-deps` — the same shape as per-task extras,
lifted to the project top level so it can be applied to any command or shared
across tasks.

```edn
{:deps  {a {:git/url "…a" :git/tag "v1"}}
 :paths ["src"]

 :contexts
 {:dev  {:extra-paths ["dev"]
         :extra-deps  {nrepl {:git/url "…nrepl" :git/tag "v1"}}}
  :test {:extra-paths ["test-support"]}}

 :tasks
 {:repl {:doc  "REPL with dev tooling"
         :with [:dev]
         :do   [{:run "dev/repl.lg"}]}}}
```

A context map may contain only `:extra-paths`, `:extra-resource-paths`, and
`:extra-deps`, validated by the same rules as the top-level
`:paths`/`:resource-paths`/`:deps`. Apply contexts two ways:

- **`lgx --with dev,test <command>`** — a global, comma-separated flag that
  applies the named contexts to `run`, `build`, `test`, `install`, or a task.
  `install` pre-fetches the contexts' deps.
- **`:with [:dev]`** on a task — that task always runs with the named contexts.
  A global `--with` on the same invocation is **unioned** on top.

Referencing a context that isn't defined fails loudly: a task's `:with` is
checked when `lgx.edn` loads; an unknown `--with` name errors at runtime,
listing the defined contexts.

**Layering.** When the same lib name appears in more than one place, the more
specific layer wins (last-wins). Lowest → highest precedence:

```
project :deps / :paths / :resource-paths
  → task :with contexts (in order)
  → CLI --with contexts (in order)
  → task inline :extra-deps / :extra-paths / :extra-resource-paths  (highest)
```

Source and resource paths concatenate in the same order with the project's own
first (so project namespaces still shadow lib namespaces) and are
de-duplicated. Resource paths layer identically but, unlike source paths, never
pick up dependency dirs. Like per-task extras, contexts augment only the
`-source-paths`/`-resource-paths` for `:run` steps and the basis commands;
`:sh` steps are unaffected.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `LGX_LG` | `lg` on `PATH` | Path to the `lg` binary lgx invokes. Useful when testing an unreleased build. |
| `LGX_RUN` | _(set by lgx)_ | Set to `1` in the process spawned by `lgx run`. Read it to detect dev-vs-bundled mode (see [`lgx run` details](#lgx-run-details)). |
| `LGX_HOME` | `~/.lgx` | State root for the gitlibs cache, template cache, and test harness tmp dir. |
| `LGX_NO_COLOR` | _(unset)_ | Set to any non-empty value to disable colored status headers. lgx prints a green `=>` header before `install`/`build`/`test`/`new` and a purple `=> Running task <name>...` header before custom tasks, on stderr. `lgx run` prints no header, so it mirrors the built binary. |
| `LGX_TEMPLATE_BASE_URL` | template repo URL | Override the source repo for `lgx new`. |
| `LGX_TEMPLATE_BASE_SHA` | pinned sha | Override the template revision for `lgx new`. |

## State layout

```
$LGX_HOME/
  gitlibs/<host>/<owner>/<repo>/<ref>/
  templates/<host>/<owner>/<repo>/<sha>/
  tmp/lgx-test-<version>.lg
```

`<ref>` is the sha for `:git/sha` coords, or the tag with `/` replaced
by `_` for `:git/tag` coords. `lgx test` rewrites the version-stamped
harness on each run. `lgx new` reuses the template cache after the first
clone.

## Examples

- [`examples/hello/`](./examples/hello) - no-deps script.
- [`examples/with-lib/`](./examples/with-lib) - fetch-and-require flow
  using let-go's own repo as the dep.
- [`examples/local-dep/`](./examples/local-dep) - project plus sibling
  library using `:local/root`.
- [`examples/clojure-libs/`](./examples/clojure-libs) - survey of real
  Clojure libraries on let-go.

## Projects using lgx

- [tiny-cli](https://github.com/abogoyavlensky/tiny-cli) - a CLI parser
  library for let-go, distributed as a git dep.
- [wtr](https://github.com/abogoyavlensky/wtr) - a git worktree CLI
  built with let-go and lgx, using tiny-cli for argument parsing.

## Clojure libs compatible with let-go

- [ruuter](https://git.nmm.ee/asko/ruuter)
- [medley](https://github.com/weavejester/medley)

## Roadmap (draft)

In no particular order:

- [x] `:paths` source paths.
- [x] Per-coord `:deps/root`.
- [x] Per-coord `:local/root`.
- [x] `:tasks` - named command shortcuts.
- [x] `lgx build` - build project binary.
- [x] `lgx test` - test runner.
- [x] `lgx new` - project scaffolding.
- [x] **Transitive dependencies.** Follow `lgx.edn` files inside fetched
  libs and resolve the union, with first-wins on conflicts.
- [ ] `lgx repl` - run repl.
- [x] `:extra-deps`/`:extra-paths` - ad-hoc overrides for custom tasks. 
- [x] `:contexts` - environment-specific `:extra-paths` and `:extra-deps` configurations.
- [x] `--with`/`:with` - ability to extend tasks with contexts.
- [x] Non-source resources (let-go-side). `lg`'s resolver finds `.lg`
  and `.cljc` only; libs that ship templates, JSON, or other assets
  have no resolution story. Likely needs an upstream change.
- [ ] `lgx deps` - print dependency tree.
- [ ] `lgx update`/`lgx update --check` - check and update outdated deps.
- [ ] `lgx clean` - clean build artifacts from `:targets`.
- [ ] `lgx fmt` / `lgx lint`.

## Development

```
make build       # produces bin/lgx, a bundled standalone binary
make dev-install # runs `lg lgx.lg install` from the lgx project root
make dev-run     # runs examples/hello/main.lg through dev `lg lgx.lg ...`
make test        # runs all tests through dev `lg lgx.lg ...`
make clean       # remove bin/lgx and all build artifacts
```

Run from the lgx project root during dev so the resolver finds
`lgx/*.lg`. Once built, `bin/lgx` works from any directory. Point at a
non-default `lg` binary with `LGX_LG=/path/to/lg`.

## License

MIT License. Copyright (c) 2026 Andrey Bogoyavlenskiy.
