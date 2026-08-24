# lgx

A package and project manager for [let-go](https://github.com/nooga/let-go): git-based
dependency manager, runner, build tool, test runner, scaffolder, and task
runner, in one binary.

```sh
lgx new myapp        # scaffold a project
cd myapp
lgx install          # install deps from lgx.edn
lgx run              # fetch deps, run :main
lgx nrepl            # run nrepl
lgx build            # bundle a standalone binary
lgx test             # run tests under test/
lgx <task>           # run a custom task from lgx.edn
```

## Requirements

- [`lg`](https://github.com/nooga/let-go) >= `1.11.0` on `PATH` (or pointed to by
  `LGX_LG`). Install it with `brew install nooga/tap/let-go`.
- `git` on `PATH`. (lgx uses it to clone, fetch, and check out deps)
- The Go toolchain on `PATH`, **only if** your project declares Go deps
  (`:go/*` coords - see [`:deps`](#deps)). Install it with
  `mise use -g go@latest` or from <https://go.dev/dl>. Projects without Go
  deps never invoke `go`.

## Installation

Prebuilt binaries for `linux_amd64`, `linux_arm64`, `darwin_amd64`, and
`darwin_arm64` are attached to each [GitHub Release](https://github.com/abogoyavlensky/lgx/releases).
There are a few ways to install `lgx`.

### Homebrew

Works on macOS and Linux:

```sh
brew install abogoyavlensky/tap/lgx
```

This installs lgx only. Install let-go (`lg`) separately with
`brew install nooga/tap/let-go`.

### With [mise](https://mise.jdx.dev)

```sh
mise use -g github:abogoyavlensky/lgx@latest
```

Or pin per project in `.mise.toml`:

```toml
[tools]
"github:nooga/let-go" = "latest"
"github:abogoyavlensky/lgx" = "latest"
```

### Install script

Installs the latest release to `~/.local/bin/lgx`:

```sh
curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
```

See the [script's README](./scripts/README.md) for options.

## Quickstart

Create a new project and run it:

```sh
lgx new hello
cd hello
lgx run
```

`lgx new` scaffolds from the [base template](https://github.com/abogoyavlensky/lgx-template-base);
`-t/--template` selects another (see [`lgx new` templates](#lgx-new-templates)).
`lgx run` resolves `:main` from `lgx.edn`, fetches any deps under
`$LGX_HOME/gitlibs/`, then execs `lg`.

## Commands

| Command | What it does |
| --- | --- |
| `lgx new <name> [-t <tpl>]` | Scaffold a new let-go project into `./<name>` from a built-in template (`base`, `cli`, `lib`) or a git URL. |
| `lgx install` | Fetch deps from `:deps` into the gitlibs cache. Idempotent. Useful for editor navigation. |
| `lgx run [args...]` | Run `:main` through `lg` with deps on the source path. Put a script or `lg` flags before `--` to drive `lg` yourself; program args go after `--`. With no `:main` and no script, errors (use `lgx repl` for a REPL). |
| `lgx repl` | Start `lg`'s built-in REPL with the project's deps on the source path. Auto-applies the `:dev` and `:test` contexts when defined. |
| `lgx nrepl [--port N]` | Start a REPL with an nREPL server on a free OS-assigned port (or `N`). Writes `.nrepl-port`. Auto-applies the `:dev` and `:test` contexts when defined. |
| `lgx build [args...]` | Bundle `:main` into `:targets/:bin/:out` in `lgx.edn` via `lg -b`. `--target <os>/<arch>[,...]` or `--all` cross-compiles (see below). |
| `lgx test [file]` | Run `*_test.lg` / `*_test.cljc` / `*_test.clj` files under `test/`. With `<file>`, run just that file. |
| `lgx clean <--cache...>` | Remove caches under `$LGX_HOME`: `--runtimes`, `--gitlibs`, `--templates`, or `--all`; `--dry-run` only reports. Prints bytes reclaimed. Never automatic. |
| `lgx <task> [args...]` | Run a custom task defined under `:tasks` in `lgx.edn`, binding any declared positional `:args`. |
| `lgx` or `lgx help` | Show usage, including project tasks if an `lgx.edn` is found. |
| `lgx version` | Print version. |

Options:

- `--with <a,b,...>` applies one or more named [contexts](#contexts) to the
  command. Works with `run`, `repl`, `nrepl`, `build`, `test`, `install`, and
  user tasks; on a task it unions with the task's own `:with`.
- `--verbose` prints the resolved `lg` invocation before running (applies to
  `run`, `repl`, `nrepl`, `build`, `test`, and user tasks). It first prints a
  `+ lg <version> (<path>)` line naming the `lg` it resolved - the version from
  `lg -v` and the full binary path, which reflects an `LGX_LG` override. It also
  prints a `+ env …` line listing the env vars lgx sets.

Both options go before the subcommand: `lgx --with dev,test run`.

`lgx run`, `repl`, `nrepl`, `build`, `test`, and tasks find the nearest
`lgx.edn` by walking up from the current directory.

### `lgx new` templates

`lgx new` takes `-t`/`--template` with a built-in template name or a git URL:

```sh
lgx new myapp                # base template (the default)
lgx new myapp -t cli         # built-in template by name
lgx new myapp -t https://github.com/user/my-template
```

Built-in templates are pinned to a latest revision:

| Name | Repo | Purpose |
| --- | --- | --- |
| `base` | [lgx-template-base](https://github.com/abogoyavlensky/lgx-template-base) | Minimal let-go app. |
| `cli` | [lgx-template-cli](https://github.com/abogoyavlensky/lgx-template-cli) | Command-line app skeleton. |
| `lib` | [lgx-template-lib](https://github.com/abogoyavlensky/lgx-template-lib) | Library project skeleton. |

A URL template uses the repo's latest default-branch HEAD and caches the checkout by sha under
`$LGX_HOME/templates/`.

Template URLs must be `https://host/owner/repo` (or `file:///path/to/repo`
for local development); SSH forms like `git@host:owner/repo` are not
supported. To make a repo a template, put the literal token `projectname`
in paths and file contents wherever the project name belongs; `lgx new`
replaces it with the underscored name (`my_app`) in paths and the
hyphenated name (`my-app`) in contents.

### `lgx run` details

`lgx run` runs `:main`. Put a script or `lg` flags before `--` and you drive
`lg` yourself (`:main` isn't added); your program's args go after `--` and
arrive in `*command-line-args*` (requires `lg` >= 1.11.0). With no `:main` and
no script it errors: set `:main`, name a script, or start
[`lgx repl`](#lgx-repl-details).

It also sets `LGX_RUN=1` in the spawned process, so a tool can tell it runs
under `lgx run` (dev) vs. as a bundled binary. The spawned `lg` inherits lgx's
stdio, so live output and interactive programs (REPL, prompts) work.

<details>
<summary>Argument forms</summary>

- `lgx run` -> `lg <paths> <main>` (`*command-line-args*` is `nil`).
- `lgx run -- foo bar` -> `lg <paths> <main> foo bar` -> `*command-line-args*` is `("foo" "bar")`.
- `lgx run other.lg` -> `lg <paths> other.lg` (explicit script, no `:main`).
- `lgx run other.lg -- bar` -> `lg <paths> other.lg bar` -> `*command-line-args*` is `("bar")`.
- `lgx run -e '(...)'` -> `lg <paths> -e '(...)'` (no `:main`).
- `lgx run -- a -- b` -> `*command-line-args*` is `("a" "--" "b")` (only the first `--` is the separator).

</details>

### `lgx repl` details

`lgx repl` opens `lg`'s built-in REPL with the project's deps and `:paths` on
the source path, no script and no `:main`. It auto-applies the `:dev` and
`:test` contexts, exactly like `lgx nrepl`; the difference is that `repl` binds
no port and writes no `.nrepl-port`, so it is the zero-footprint choice for a
quick session. Reach for `lgx nrepl` when an editor needs to connect.

It takes no arguments of its own (`--with`/`--verbose` are the usual leading
options). For a scratch script or `lg` flags with your deps on the path, use
`lgx run <script>` or `lgx run -e '(...)'`.

### `lgx build` details

`lgx build` is shortcut for `lg <paths> [extra-args...] -b <:out> <:main>`.
Both `:main` and `:targets/:bin` are required. Args other than lgx's own
`--target`/`--all` are forwarded to `lg` before `-b`.

#### Cross-compilation

`lgx build` can produce binaries for other platforms from one machine:

```sh
lgx build                        # native, unchanged
lgx build --target linux/arm64   # one ad-hoc platform; no config needed
lgx build --all                  # every platform declared in :platforms
```

Declare a release matrix in `lgx.edn`, with `{{os}}` and `{{arch}}`
placeholders in `:out` so the artifacts land on distinct paths:

```clojure
:targets {:bin {:out "dist/app_{{os}}_{{arch}}"
                :platforms [{:os "linux" :arch "amd64"}
                            {:os "darwin" :arch "arm64"}]}}
```

A plain `:out "bin/app"` keeps working for native builds; declaring more
than one platform without a distinguishing placeholder is a config error.
`:os`/`:arch` values are validated against Go's `go tool dist list`.

For each target lgx builds a target-platform `lg` runtime (cached under
`$LGX_HOME/runtimes/`, one entry per platform) and passes it to `lg -b`
as `-bundle-base`. A hand-rolled `lgx build -bundle-base /path/to/lg`
still wins over the generated one, for a single target only.

Rules that follow from the mechanics:

- **Cross-builds need the Go toolchain and `:lg-version`** - the target
  runtime is generated with Go even when the project has no Go deps. A
  native build of a project without Go deps never invokes Go.
- **Go deps must be pure Go.** Cross-builds run with `CGO_ENABLED=0`,
  because a cgo dependency cannot cross-compile without a target C
  toolchain. Pure-Go drivers (e.g. `modernc.org/sqlite`) work everywhere.
- **A cross-build of a Go-deps project uses two runtimes**: a host one
  that executes `lg -b` (bundling compiles the script, so the Go
  namespaces must resolve on the host), and the target one shipped as
  the binary's base. Setting `LGX_LG` contradicts this and fails.
- `windows/*` targets fail until let-go itself builds for Windows (see
  `docs/issues/windows-build-unix-only-term.md`).

### `lgx test` details

`lgx test` walks `test/` for `*_test.lg` / `*_test.cljc` / `*_test.clj` files, generates
a one-shot harness under `$LGX_HOME/test-runner/`, and runs every `deftest`
against the project's resolved `-source-paths`. Prints summary results.

## Configuration: `lgx.edn`

`lgx.edn` lives at the project root. The smallest valid file:

```edn
{}
```

Every key is optional. The annotated reference below shows all of them
with their possible values; the sections that follow spell out each
key's rules in detail.

```edn
{; Source dirs, relative to the project root. Prepended to dependency paths.
 :paths ["src"]

 ; Resource roots for (io/resource "..."): on the path for run/test,
 ; embedded into the binary by build.
 :resource-paths ["resources"]

 ; Default entrypoint: `lgx run` runs it, `lgx build` bundles it. Does not have to be in the `:paths`
 :main "main.lg"

 ; The let-go version this project targets. When set, run/build/test check it
 ; against the lg on PATH and warn. lgx does not install lg itself.
 ; If `LGX_FETCH_LET_GO_SOURCE=1` env var set, `lgx install` fetches 
 ; the matching let-go source for editor navigation.
 :lg-version "1.11.0"

 ; Git or local deps. A dep's own :deps are resolved too (first-wins).
 :deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}      ; pin by tag...
  org.clojure/tools.cli  {:git/url  "https://github.com/clojure/tools.cli"
                          :git/sha  "0123456789abcdef0123456789abcdef01234567" ; ...or by sha
                          :deps/root "src/main/clojure"} ; source subdir (default "src")
  my/lib                 {:local/root "../my-lib"}}      ; local dir, no gitlibs cache

 ; Build output for `lgx build`. :bin is the only target; :out is relative to
 ; the project root (lgx creates the parent dir if missing). Optional
 ; :platforms lists cross-compile targets for `lgx build --all`; {{os}} and
 ; {{arch}} in :out keep their artifacts on distinct paths.
 :targets {:bin {:out "bin/myapp"}}

 ; Named overlays of extra paths/deps. Apply with `lgx --with dev,test <cmd>`
 ; or a task's :with; :dev auto-applies to run/nrepl, :test to nrepl and
 ; `lgx test`.
 :contexts
 {:dev  {:extra-paths          ["dev"]            ; appended after :paths
         :extra-resource-paths ["dev-resources"]  ; appended after :resource-paths
         :extra-deps           {nrepl {:git/url "https://github.com/x/nrepl"
                                       :git/tag "v1"}}} ; same grammar as :deps
  :test {:extra-paths ["test-support"]}}

 ; Custom commands: `lgx <task> [args...]`. A step is {:sh ...} (shell)
 ; or {:run ...} (like `lgx run ...`); a string value splits on whitespace.
 :tasks
 {fmt   {:doc "Lint the project"                   ; :doc shows up in `lgx help`
         :do  {:sh "cljfmt fix"}}                  ; single step: bare map

  ci     {:doc "Lint, then test"                   ; multi-step: vector,
          :do  [{:sh  "cljfmt check"}              ; stops at first failure
                {:run "scripts/check.lg"}]}

  greet  {:doc "Run main with a fixed arg"
          :do  [{:run ["main.lg" "--" "world"]}]}  ; vector form: explicit argv

  deploy {:doc  "Deploy the app"
          :args [{:name :env                       ; typed positional CLI args
                  :type [:enum "prod" "staging"]}  ; :string (default), :int, [:enum ...]
                 {:name    :version
                  :type    :string
                  :default "latest"}]              ; :default makes an arg optional
          :do   [{:sh  ["./deploy.sh" :arg/env :arg/version]} ; :arg/<name> fills
                 {:run ["notify.lg" :arg/env]}     ; in declared args
                 {:sh  "echo deploying v{{version}}"}]} ; {{name}} expands in strings

  console {:doc                  "Custom REPL entrypoint with dev tooling"
           :with                 [:dev]             ; always apply these contexts
           :extra-paths          ["repl"]           ; task-private extras:
           :extra-resource-paths ["repl-resources"] ; same shape as a context,
           :extra-deps           {seme-extra-dep {:git/url "https://github.com/some-extra/dep"
                                                  :git/tag "v1"}}
           :do                   [{:run "dev/repl.lg"}]}}}
```

### `:paths`, `:main`, `:resource-paths`

- `:paths` prepends project source dirs to dependency paths, so project
  namespaces shadow lib namespaces of the same name.
- `:main` is substituted by `lgx run` when no script is given, and bundled by
  `lgx build`. It need not live under `:paths`.
- `:resource-paths` are passed to `lg` as `-resource-paths` for run/test and
  **embedded into the binary** by `lgx build`, so `(io/resource "…")` keeps
  working with no files beside the executable. Unlike source paths, resource
  roots come only from your project, never from dependencies.
- Missing `:paths`/`:resource-paths` entries print a warning.

### `:lg-version`

lgx never installs or manages `lg` (use mise/brew for that), but when
`:lg-version` is set it checks the `lg` on `PATH`: a mismatch **warns** on
`run`/`nrepl` and **fails** on `build`/`test`, where a wrong-runtime artifact or
test verdict matters. A dev or unparseable installed version is skipped, and
`LGX_SKIP_VERSION_CHECK` bypasses the check. With `LGX_FETCH_LET_GO_SOURCE` set,
`lgx install` also fetches the matching let-go _source_ (not the binary) into
`$LGX_HOME/let-go/source/<version>/` for editor navigation.

### `:deps`

Each coord is a git source (`:git/url` plus one of `:git/sha`/`:git/tag`,
HTTPS only), a `:local/root` dir, or a Go package (`:go/*`) - never a mix.
Local deps bypass the gitlibs cache. `:deps/root` names the source subdir
inside the dep (defaults to `src` if present, else the repo root; matches
tools.deps). When that subdir holds its own `lgx.edn` - a monorepo package -
lgx reads the dep's config from there instead of the checkout root, so the
package's `:deps` (Go deps included) reach the consumer.

#### Go deps (`:go/*`)

A `:go/*` coord names a Go package rather than a let-go source tree. The dep
symbol **is** the Go package path. Declaring one makes lgx build a custom `lg`
that links that package, cached under `$LGX_HOME/runtimes/`; `run`, `repl`,
`test`, and `build` then use it with no further configuration, single-binary
output included.

```clojure
{:lg-version "1.11.1"
 :deps {database/sql        {:go/interop "sql"}       ; stdlib, bindings only
        modernc.org/sqlite  {:go/version "v1.57.0"}   ; linked, no bindings
        github.com/you/shim {:go/local "shim"}}}      ; a module on disk
```

Two capabilities, orthogonal:

- `:go/interop "<alias>"` generates a let-go namespace for the package. The
  alias must be the package path's last segment - that is the name
  [`cmd/lginterop`](https://github.com/nooga/let-go) derives, and it takes no
  override.
- `:go/version "<version>"` / `:go/local "<dir>"` name where the module comes
  from. Without `:go/interop` the package is linked but generates nothing,
  which is what a self-registering driver needs.

The rules:

| | |
|---|---|
| Standard-library package (first path segment has no dot) | `:go/interop` only |
| External module | `:go/version` or `:go/local`, plus optional `:go/interop` |
| `:go/version` | anything Go accepts - a tag, a sha, a branch |
| `:go/local` | relative to the file that declares it; a `replace` directive, for development |

`:lg-version` is required: it pins the let-go the custom runtime is built
from. Version conflicts across the tree are left to Go's own MVS - lgx writes
what it resolved and `go mod tidy` settles the rest.

A dep's own Go coords flow up to you invisibly, so depending on a wrapper
library is a single line. The first build takes a minute; every build after
that is a cache hit.

**Transitive deps.** After fetching a dep, lgx resolves what that dep
declares: its own `lgx.edn` `:deps` if it has one, otherwise the `deps.edn` or
`project.clj` it ships for other tools. Git coords there are already pinned and
resolve directly; well-known Maven coordinates resolve through a curated
registry of verified repo+tag mappings. Anything lgx cannot pin gets one
warning naming the declaration, so you know exactly what to add:

```
warning: integrant/integrant declares weavejester/dependency {:mvn/version "0.2.1"} - not resolved by lgx; add a :git coord to lgx.edn :deps or exclude it (see examples/clojure-libs/)
```

`lgx install` always shows these; `run`/`build`/`test` only mention deps
freshly installed in that run, so a warm cache stays quiet. Silence one for
good with `:exclusions [lib-sym ...]` on the coord that pulls it in. A failure
while acting on a dep's metadata is always a warning, never an aborted command.

Resolution is breadth-first and **first-wins**: the first coord seen for a lib
name is kept, and a later differing coord is skipped with a warning. Top-level
coords are resolved before anything transitive, so a coord you list directly
always overrides the same lib pulled in by a dep.

`:mvn/version` is not a coord lgx accepts - let-go runs libraries from source,
so coords are git or local. Writing one tells you what to use instead.

### `:tasks`

Tasks replace ad-hoc Makefile/Taskfile recipes. A task is a step or a vector of
steps; each step is `:sh` (shell) or `:run` (an explicit argv to `lg` with the
project basis). A `:run` step names its own script - it never substitutes
`:main` - but, like `lgx run`, drops the first `--`. The first non-zero exit
stops the chain; output is buffered and replayed after each step. A single-step
`:do` may be a step map instead of a vector.

Run a task with `lgx <name>`; `lgx help` lists the project's tasks. Names are
symbols (context names stay keywords) and can't shadow built-ins (`install`,
`run`, `nrepl`, `build`, `test`, `new`, `help`, `version`, plus reserved `add`,
`update`, `tasks`). A task accepts only `:doc`, `:args`, `:do`, `:with`,
`:extra-paths`, `:extra-resource-paths`, and `:extra-deps`; any other key is
rejected (so a typo like `:extra-dep` fails loudly).

#### Positional args (`:args`)

A task may declare typed positional args and reference them in steps, like the
`deploy` task above. Each arg is a map:

- `:name` - required, an unqualified keyword; the placeholder is `:arg/<name>`.
- `:type` - `:string` (default), `:int`, or `[:enum "v1" "v2" ...]`.
- `:default` - optional; must match the type. Args without a default are
  required and come first; once one arg has a default, every later arg needs
  one too (CLI values fill positions left to right).

Arity is strict: a missing required arg, a wrong type, or a surplus arg prints a
usage line and exits 1. Reference args two ways: as **`:arg/<name>` keyword
items** in vector-form steps (single-quoted in `:sh` so shell-safe, verbatim in
`:run`), or as **`{{name}}` templates** in any step string (spliced raw - quote
it yourself when it may contain spaces). Unknown tokens are left untouched, and a
bound value is never re-expanded.

#### Per-task `:extra-paths`, `:extra-resource-paths`, `:extra-deps`

A task may carry its own extras (same rules and grammar as the top-level
`:paths`/`:resource-paths`/`:deps`), appended after the project's and applied to
that task's `:run` steps only - `:sh` steps are plain shell and unaffected, like
the `console` task above. An `:extra-deps` coord that names a project dep wins
for that task only. These are the anonymous form of a [context](#contexts); use
named `:contexts` + `:with` when an overlay is shared across tasks.

### `:contexts`

A **context** is a named, reusable overlay of `:extra-paths`,
`:extra-resource-paths`, and `:extra-deps` - the per-task extras lifted to the
project top level so any command or task can apply them (the `:dev`/`:test`
contexts applied by the `console` task's `:with` above). Apply two ways:

- **`lgx --with dev,test <command>`** - a global flag applied to `run`, `build`,
  `test`, `install`, or a task (`install` pre-fetches the contexts' deps).
- **`:with [:dev]`** on a task - always applied; a global `--with` unions on top.

**Default contexts.** By convention `:dev` auto-applies to `lgx run`, `:test` to
`lgx test`, and `lgx nrepl` applies **both** - no `--with` needed. `build` and
`install` never auto-apply, so dev/test deps stay out of binaries; task `:run`
steps don't inherit them either (use the task's `:with`). On a lib-name
collision the more specific layer wins. Referencing an undefined context fails
loudly (a `:with` at load time, an unknown `--with` at runtime).

**Layering.** When a lib name appears in more than one layer, the most specific
wins (lowest to highest):

```
project :deps / :paths / :resource-paths
  → auto context (:dev for run, :test for test, both for nrepl)
  → task :with contexts (in order)
  → CLI --with contexts (in order)
  → task inline :extra-deps / :extra-paths / :extra-resource-paths  (highest)
```

Source and resource paths concatenate project-first (so project namespaces still
shadow libs) and de-duplicate; resource paths never pick up dependency dirs.

## Shell completions

`lgx completion <shell>` prints a completion script for bash, zsh, or
fish. TAB then completes the built-in commands and the current
project's tasks from `lgx.edn`. For a task arg typed as `[:enum ...]`,
TAB at that argument completes the declared values (those made of shell-safe
characters; a value containing spaces or shell metacharacters is skipped, but
still works when typed by hand).

Bash (add to `~/.bashrc`):

```sh
source <(lgx completion bash)
```

Zsh, either sourced (add to `~/.zshrc`):

```sh
source <(lgx completion zsh)
```

or saved on your `fpath` (run once; assumes `~/.zfunc` is on `fpath`):

```sh
lgx completion zsh > ~/.zfunc/_lgx
```

Fish (run once):

```sh
lgx completion fish > ~/.config/fish/completions/lgx.fish
```

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `LGX_LG` | `lg` on `PATH` | Path to the `lg` binary lgx invokes. Useful when testing an unreleased build. Setting it in a project with Go deps overrides the custom runtime, and lgx warns that the Go namespaces will not resolve. |
| `LGX_RUN` | _(set by lgx)_ | Set to `1` in the process spawned by `lgx run`. Read it to detect dev (`lgx run`) vs. bundled-binary mode - e.g. to enable dev-only behavior. Not needed for argument parsing; read `*command-line-args*` for that (see [`lgx run` details](#lgx-run-details)). |
| `LGX_HOME` | `~/.lgx` | State root for the gitlibs cache, the let-go source cache, the template cache, and the test-runner harness dir. |
| `LGX_SKIP_VERSION_CHECK` | _(unset)_ | Set to any non-empty value to bypass the `:lg-version` compatibility check on `run`/`nrepl`/`build`/`test`. |
| `LGX_FETCH_LET_GO_SOURCE` | _(unset)_ | Set to any non-empty value to make `lgx install` fetch the let-go source matching `:lg-version` into `$LGX_HOME/let-go/source/<version>/`. The source feeds editor diagnostics - an LSP server navigating into let-go's `core`/stdlib. Off by default, since most users don't run such tooling and wouldn't expect the extra clone. |
| `LGX_NO_COLOR` | _(unset)_ | Set to any non-empty value to disable colored status headers. lgx prints a green `=>` header before `install`/`build`/`test`/`new` and a purple `=> Running task <name>...` header before custom tasks, on stderr. `lgx run` prints no header, so it mirrors the built binary. |
| `LGX_LETGO_REPLACE` | _(unset)_ | Path to a let-go checkout to build the custom runtime against, instead of the released `:lg-version`. For testing an unreleased let-go; the runtime is rebuilt on every command, since the checkout's contents are not part of the cache key. |
| `LGX_TEMPLATE_BASE_URL` | template repo URL | Override the source repo of the built-in `base` template. |
| `LGX_TEMPLATE_BASE_SHA` | pinned sha | Override the revision of the built-in `base` template. |

## State layout

```
$LGX_HOME/
  gitlibs/<host>/<owner>/<repo>/<ref>/
  let-go/source/<version>/
  templates/<host>/<owner>/<repo>/<sha>/
  test-runner/lgx-test-<version>.lg
  runtimes/<hash>/{src/,lg}
```

`<ref>` is the sha for `:git/sha` coords, or the tag with `/` replaced
by `_` for `:git/tag` coords. `runtimes/<hash>/` holds one custom `lg`
and the generated Go module it was built from; `<hash>` covers the
let-go version, every Go coord, and - for cross-builds - the target
platform, so projects declaring the same set share one build and each
platform gets its own entry. `lgx clean --runtimes` reclaims them (see
[`docs/knowledge-base/lgx-go-runtimes.md`](docs/knowledge-base/lgx-go-runtimes.md)). `lgx test` rewrites the version-stamped
harness on each run. `lgx new` reuses the template cache after the first
clone.

## Examples

- [`examples/hello/`](./examples/hello) - no-deps script.
- [`examples/server/`](./examples/server) - simple HTTP server with a ruuter lib.
- [`examples/local-dep/`](./examples/local-dep) - project plus sibling
  library using `:local/root`.
- [`examples/clojure-libs/`](./examples/clojure-libs) - survey of real
  Clojure libraries on let-go.

## Projects using lgx

- [tiny-cli](https://github.com/abogoyavlensky/tiny-cli) - a CLI parser
  library for let-go, distributed as a git dep.
- [tiny-tui](https://github.com/abogoyavlensky/tiny-tui) - a minimal TUI lib for let-go
- [wtr](https://github.com/abogoyavlensky/wtr) - a git worktree CLI
  built with let-go and lgx, using tiny-cli for argument parsing
- [skl](https://github.com/abogoyavlensky/skl) - a minimal interactive agent skills installer
- [rite](https://github.com/abogoyavlensky/rite) - a project task runner with built-in let-go
- [frame](https://github.com/abogoyavlensky/frame) - a declarative project templater

## Supported libraries

- [tiny-cli](https://github.com/abogoyavlensky/tiny-cli) - cli parsing
- [tiny-tui](https://github.com/abogoyavlensky/tiny-cli) - TUI widgets
- [ruuter](https://git.nmm.ee/asko/ruuter) - simple router
- [medley](https://github.com/weavejester/medley) - various useful helpers
- [bond](https://github.com/circleci/bond) - spying/stubbing for tests
- [integrant](https://github.com/weavejester/integrant) - micro-framework for data-driven architecture
- [dev.weavejester/dependency](https://github.com/weavejester/dependency) - A data structure for graphs
- [org.clojure/tools.cli](https://github.com/clojure/tools.cli) - cli parsing
- [metosin/malli](https://github.com/metosin/malli) - data-driven schema validation and coercion

## Roadmap (draft)

Shipped so far: source paths, per-coord `:deps/root`/`:local/root`, `:tasks`,
`lgx build`/`test`/`new`, transitive deps, `lgx repl`/`nrepl`, `:contexts` with
`--with`/`:with`, and let-go-side resources. Next:

- [ ] Install transitive dependencies from Clojure libs that use `deps.edn` or `project.clj`
- [ ] `lgx install --all` - fetch deps from all contexts and tasks in lgx.edn.
- [ ] `lgx deps` - print the dependency tree.
- [ ] `lgx update` / `lgx update --check` - check and update outdated deps.

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
