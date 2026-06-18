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

- [`lg`](https://github.com/nooga/let-go) => `1.10.0` on `PATH` (or pointed to by
  `LGX_LG`).
  Install with `brew tap nooga/let-go https://github.com/nooga/let-go && brew install let-go`.
- `git` on `PATH`. lgx uses it to clone, fetch, and check out deps.

## Installation

Prebuilt binaries for `linux_amd64`, `linux_arm64`, `darwin_amd64`, and
`darwin_arm64` are attached to each [GitHub Release](https://github.com/abogoyavlensky/lgx/releases).
There are few options to install `lgx`.

### Homebrew

Works on macOS and Linux:

```sh
brew install abogoyavlensky/tap/lgx
```

This installs lgx only; `lg` still needs to be on `PATH` (see
[Requirements](#requirements)).

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
| `lgx new <name> [-t <tpl>]` | Scaffold a new let-go project into `./<name>` from a built-in template (`base`, `cli`) or a git URL. |
| `lgx install` | Fetch deps from `:deps`, plus the let-go source for `:lg-version` (when set). Idempotent. |
| `lgx run [args...]` | Run `:main` (or an explicit script) through `lg` with deps on the source path. Without a script and `:main`, opens `lg`'s REPL. |
| `lgx nrepl [--port N]` | Start a REPL with an nREPL server on a random port (or `N`). Writes `.nrepl-port`. |
| `lgx build [args...]` | Bundle `:main` into `:targets/:bin/:out` in `lgx.edn` via `lg -b`. |
| `lgx test [file]` | Run `*_test.lg` / `*_test.cljc` / `*_test.clj` files under `test/`. With `<file>`, run just that file. |
| `lgx <task> [args...]` | Run a custom task defined under `:tasks` in `lgx.edn`, binding any declared positional `:args`. |
| `lgx help` | Show usage, including project tasks if an `lgx.edn` is found. |
| `lgx version` | Print version. |

Options:

- `--with <a,b,...>` applies one or more named [contexts](#contexts)
  (reusable `:extra-deps`/`:extra-paths` overlays) to the command. Applies to
  `run`, `nrepl`, `build`, `test`, `install`, and user tasks; on a task it
  unions with the task's own `:with`.
- `--verbose` prints the resolved `lg` invocation before running (applies to
  `run`, `nrepl`, `build`, `test`, and user tasks). It also prints a `+ env …` line
  listing the env vars lgx sets: `LG_READ_CLJ=1` and
  `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` for every `lg` invocation (the latter
  silences lg's source-paths transition notice, since lgx always passes an
  explicit `-source-paths`), plus `LGX_RUN=1` on `run` paths.

Both options go before the subcommand: `lgx --with dev,test run`.

`lgx run`, `nrepl`, `build`, `test`, and tasks find the nearest `lgx.edn`
by walking up from the current directory.

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

A URL template uses the repo's latest default-branch HEAD and caches the checkout by sha under
`$LGX_HOME/templates/`.

Template URLs must be `https://host/owner/repo` (or `file:///path/to/repo`
for local development); SSH forms like `git@host:owner/repo` are not
supported. To make a repo a template, put the literal token `projectname`
in paths and file contents wherever the project name belongs; `lgx new`
replaces it with the underscored name (`my_app`) in paths and the
hyphenated name (`my-app`) in contents.

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
- `lgx run` with no `:main` -> `lg <paths>`: lg's interactive REPL with
  the project's deps on the source path.

The spawned `lg` inherits lgx's stdin/stdout/stderr, so output streams
live and interactive programs (REPL, prompts) work.

### `lgx build` details

`lgx build` is shortcut for `lg <paths> [extra-args...] -b <:out> <:main>`.
Extra args go before `-b`, so cross-OS bundling works as:

```sh
lgx build -bundle-base /path/to/lg
```

Both `:main` and `:targets/:bin` are required.

### `lgx test` details

`lgx test` walks `test/` for `*_test.lg` / `*_test.cljc` / `*_test.clj` files, generates
a one-shot harness under `$LGX_HOME/test-runner/`, and runs every `deftest`
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

Every key is optional. The annotated reference below shows all of them
with their possible values; the sections that follow spell out each
key's rules in detail.

```edn
{;; Source dirs, relative to the project root. Prepended to dependency
 ;; paths, so project namespaces shadow lib namespaces.
 :paths ["src"]

 ;; Resource roots for (io/resource "..."): on the path for run/test,
 ;; embedded into the binary by build.
 :resource-paths ["resources"]

 ;; Default entrypoint: `lgx run` runs it, `lgx build` bundles it. Does not have to be in the `:paths`
 :main "main.lg"

 ;; The let-go version this project targets. When set, `lgx install` fetches the
 ;; matching let-go source for editor navigation, and run/build/test check it
 ;; against the lg on PATH. lgx does not install lg itself.
 :lg-version "1.10.0"

 ;; Git or local deps. A dep's own :deps are resolved too (first-wins).
 :deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}      ; pin by tag...
  org.clojure/tools.cli  {:git/url  "https://github.com/clojure/tools.cli"
                          :git/sha  "0123456789abcdef0123456789abcdef01234567" ; ...or by sha
                          :deps/root "src/main/clojure"} ; source subdir (default "src")
  my/lib                 {:local/root "../my-lib"}}      ; local dir, no gitlibs cache

 ;; Build output for `lgx build`. :bin is the only target; :out is
 ;; relative to the project root.
 :targets {:bin {:out "bin/myapp"}}

 ;; Named overlays of extra paths/deps. Apply with `lgx --with dev,test <cmd>`
 ;; or a task's :with; :dev auto-applies to run/nrepl, :test to `lgx test`.
 :contexts
 {:dev  {:extra-paths          ["dev"]            ; appended after :paths
         :extra-resource-paths ["dev-resources"]  ; appended after :resource-paths
         :extra-deps           {nrepl {:git/url "https://github.com/x/nrepl"
                                       :git/tag "v1"}}} ; same grammar as :deps
  :test {:extra-paths ["test-support"]}}

 ;; Custom commands: `lgx <task> [args...]`. A step is {:sh ...} (shell)
 ;; or {:run ...} (like `lgx run ...`); a string value splits on whitespace.
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

  repl   {:doc                  "REPL with dev tooling"
          :with                 [:dev]             ; always apply these contexts
          :extra-paths          ["repl"]           ; task-private extras:
          :extra-resource-paths ["repl-resources"] ; same shape as a context,
          :extra-deps           {seme-extra-dep {:git/url "https://github.com/some-extra/dep"
                                                 :git/tag "v1"}}
          :do                   [{:run "dev/repl.lg"}]}}}
```

### `:paths` and `:main`

- `:paths` lists project source paths relative to the project root.
  `lgx run` prepends them to dependency paths so project namespaces
  shadow lib namespaces. Missing entries print a warning.
- `:main` names the default entrypoint script. `lgx run` substitutes it
  when no script is given; `lgx build` bundles it.

### `:lg-version`

Optional. The let-go version this project targets (a published let-go release,
e.g. `"1.10.0"`). lgx does **not** install or manage the `lg` binary — you get
that from mise/brew/etc. — but when `:lg-version` is set lgx does two things:

- **`lgx install` fetches the matching let-go _source_** (not the binary) into
  `$LGX_HOME/let-go/source/<version>/`, so editor tooling (e.g. an LSP) can
  navigate into let-go's `core`/stdlib. The fetch is idempotent and a network
  failure is a warning, not a hard error.
- **`run`/`nrepl`/`build`/`test` check it** against the `lg` on `PATH`: a
  mismatch **warns** on `run`/`nrepl` (so iteration isn't blocked) and **fails**
  on `build`/`test` (where a wrong-runtime artifact or test verdict matters).
  A dev/unparseable installed version is skipped, not warned. Set
  `LGX_SKIP_VERSION_CHECK` to a non-empty value to bypass the check.

### `:resource-paths`

- `:resource-paths` lists project-relative directories that hold resources
  (templates, data files, static assets) reachable from `(io/resource "…")`.
  lgx passes them to `lg` as `-resource-paths`.
- `lgx run` and `lgx test` make the resources resolvable at runtime; `lgx
  build` **embeds** every resource under these roots into the bundled binary,
  so `io/resource` keeps working with no files alongside the executable.
- Missing entries print a warning, same as `:paths`. Unlike source paths,
  resource roots come only from your project (its top level plus any applied
  contexts/tasks) - dependencies never contribute resource roots.

### `:deps`

Each coord uses either a git source or `:local/root`, never both.

- **Git coord.** `:git/url` plus one of `:git/sha` or `:git/tag`.
  Tag-pinned coords cache under the tag name itself. HTTPS URLs only
  (no SSH).
- **Local coord.** `:local/root` points at a directory on disk, relative
  to the project root or absolute. Local deps bypass the gitlibs cache.
- **`:deps/root`** (optional). The subdirectory inside the dep that holds
  the source. Defaults to `src` if that directory exists, else the repo
  root. Matches tools.deps' `:deps/root`.

**Transitive dependencies.** lgx follows transitive deps: after
fetching a dep, it reads that dep's own
`lgx.edn` (if it ships one) and resolves its `:deps` too, recursively. Only
a dep's `:deps` is consulted - its `:paths`, `:main`, `:tasks`, and
`:targets` describe how to build *that* project, not how to consume it.

Resolution is breadth-first from your project, and conflicts are
**first-wins**: the first coord seen for a given lib name is kept, and a
later, differing coord for the same lib is skipped with a warning on
stderr. A coord you list directly therefore overrides the same lib pulled
in transitively.

### `:targets`

Currently, supports the `:bin` target only. `:out` is the output path
relative to the project root; lgx creates the parent directory if
missing.

### `:tasks`

Tasks replace ad-hoc Makefile or Taskfile recipes for let-go projects.
A task is a sequence of steps; each step is either `:sh` (shell command)
or `:run` (invoked like `lgx run ...` with the project basis). The first
non-zero exit code stops the chain. The `lint`, `ci`, and `greet` tasks
in the reference above show the common forms.

Run a task with `lgx <name>` (for example, `lgx ci`). `lgx help` lists
tasks defined in the current project. Task names are symbols, matching
how they are typed on the command line (context names stay keywords -
see [Contexts](#contexts)); they cannot shadow built-in
commands (`install`, `run`, `nrepl`, `build`, `test`, `new`, `help`,
`version`, plus reserved `add`, `update`, `tasks`).

When a task has a single step, `:do` may be written as a step map
instead of a vector. Multi-step tasks use a vector. Step values may be
a string (split on whitespace) or a vector of strings and
`:arg/<name>` placeholders (see [Positional args](#positional-args-args)).
Output is buffered and replayed after each step completes.

A task may contain only `:doc`, `:args`, `:do`, `:extra-paths`,
`:extra-resource-paths`, `:extra-deps`, and `:with`; any other key is
rejected (so a typo like `:extra-dep` fails loudly).

#### Positional args (`:args`)

A task may declare typed positional CLI args and reference them in
vector-form step values as `:arg/<name>` keywords or embed them in step
strings as `{{<name>}}` templates, like the `deploy` task in the
reference above. `lgx deploy prod` runs `./deploy.sh 'prod' 'latest'`,
then `lgx run notify.lg prod`, then `echo deploying vlatest`.

Each arg is a map:

- `:name` - required; an unqualified keyword. The placeholder is the
  matching `:arg/<name>` keyword.
- `:type` - optional, defaults to `:string`. One of `:int`, `:string`,
  or `[:enum "v1" "v2" ...]` (at least two distinct non-blank strings;
  CLI values arrive as strings, so enums are string-only).
- `:default` - optional; its value must match the type. Args without
  `:default` are required and must come first; once an arg has
  `:default`, every later arg needs one too (CLI values fill positions
  left to right, so only trailing args can be omitted).

Arity is strict: a missing required arg, a value that fails its type,
or a surplus arg prints the error plus a usage line
(`usage: lgx deploy <env> [version]`) and exits 1. A task that declares
no `:args` rejects any CLI args the same way. `lgx help` shows each
task's signature after its name.

Args can be referenced two ways:

- **`:arg/<name>` keyword items** in vector-form step values. Each must
  name a declared arg (checked when `lgx.edn` loads). In `:sh` steps the
  substituted value is single-quoted, so it always reaches the shell as
  one word and is never interpreted (`lgx greet 'a; echo pwned'` echoes
  the literal text). In `:run` steps each vector item is already one
  argument, so values pass through verbatim.
- **`{{<name>}}` templates** inside any step string - a whole-string
  command or a string item in a vector. The value is spliced in raw with
  no quoting added; quote it yourself when it may contain spaces or
  shell syntax (`{:sh "git tag 'v{{version}}'"}`). A token that does not
  name a declared arg is left untouched (which also lets a command carry
  literal `{{...}}` text), and a bound value is never re-expanded. A
  string-form `:run` value is expanded first and then whitespace-split,
  so a value with spaces becomes several arguments - use the vector form
  (`{:run ["notify.lg" "{{env}}"]}`) when it must stay one.

#### Per-task `:extra-paths`, `:extra-resource-paths`, and `:extra-deps`

A task may declare extra source paths, resource roots, and dependencies
that apply to *that task's* `:run` steps only, like the `repl` task in
the reference above:

- `:extra-paths` - extra project-root-relative source dirs, same rules as
  top-level `:paths`. Appended after the project's `:paths`.
- `:extra-resource-paths` - extra project-root-relative resource roots, same
  rules as top-level `:resource-paths`. Appended after the project's
  `:resource-paths`.
- `:extra-deps` - extra coords, same grammar as top-level `:deps` (git,
  `:local/root`, `:deps/root`). Fetched on first run like any dep.

These augment the `-source-paths` and `-resource-paths` for the task's `:run`
steps. `:sh` steps are plain shell and are unaffected. When an `:extra-deps`
coord names a lib already in the project's top-level `:deps`, the extra coord
wins for that task only (a silent override) - other commands still use the
project coord.

These per-task extras are the task-private, anonymous form of a
[context](#contexts): use them for one-off extras, and named
`:contexts` + `:with` when an overlay is shared across tasks or commands.

### `:contexts`

A **context** is a named, reusable overlay of `:extra-paths`,
`:extra-resource-paths`, and `:extra-deps` - the same shape as per-task extras,
lifted to the project top level so it can be applied to any command or shared
across tasks (the `:dev` and `:test` contexts in the reference above,
applied by the `repl` task's `:with`).

A context map may contain only `:extra-paths`, `:extra-resource-paths`, and
`:extra-deps`, validated by the same rules as the top-level
`:paths`/`:resource-paths`/`:deps`. Apply contexts two ways:

- **`lgx --with dev,test <command>`** - a global, comma-separated flag that
  applies the named contexts to `run`, `build`, `test`, `install`, or a task.
  `install` pre-fetches the contexts' deps.
- **`:with [:dev]`** on a task - that task always runs with the named contexts.
  A global `--with` on the same invocation is **unioned** on top.

**Default contexts.** Two context names are conventions: when defined, `:dev`
auto-applies to `lgx run` and `lgx nrepl`, and `:test` auto-applies to
`lgx test` - no `--with` needed. That is the natural home for nREPL tooling
and dev-only source dirs (`:dev`) and test helpers (`:test`), as in the
reference above. `build` and `install` never auto-apply contexts, so dev and
test deps stay out of built binaries; task `:run` steps don't inherit them
either (use the task's `:with`). An explicit `--with` layers on top, and
`--verbose` prints the applied name (`+ auto context :dev`).

Referencing a context that isn't defined fails loudly: a task's `:with` is
checked when `lgx.edn` loads; an unknown `--with` name errors at runtime,
listing the defined contexts.

**Layering.** When the same lib name appears in more than one place, the more
specific layer wins (last-wins). Lowest → highest precedence:

```
project :deps / :paths / :resource-paths
  → auto context (:dev for run/nrepl, :test for test; built-in commands only)
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
| `LGX_LG` | `lg` on `PATH` | Path to the `lg` binary lgx invokes. Useful when testing an unreleased build. |
| `LGX_RUN` | _(set by lgx)_ | Set to `1` in the process spawned by `lgx run`. Read it to detect dev-vs-bundled mode (see [`lgx run` details](#lgx-run-details)). |
| `LGX_HOME` | `~/.lgx` | State root for the gitlibs cache, the let-go source cache, the template cache, and the test-runner harness dir. |
| `LGX_SKIP_VERSION_CHECK` | _(unset)_ | Set to any non-empty value to bypass the `:lg-version` compatibility check on `run`/`nrepl`/`build`/`test`. |
| `LGX_NO_COLOR` | _(unset)_ | Set to any non-empty value to disable colored status headers. lgx prints a green `=>` header before `install`/`build`/`test`/`new` and a purple `=> Running task <name>...` header before custom tasks, on stderr. `lgx run` prints no header, so it mirrors the built binary. |
| `LGX_TEMPLATE_BASE_URL` | template repo URL | Override the source repo of the built-in `base` template. |
| `LGX_TEMPLATE_BASE_SHA` | pinned sha | Override the revision of the built-in `base` template. |

## State layout

```
$LGX_HOME/
  gitlibs/<host>/<owner>/<repo>/<ref>/
  let-go/source/<version>/
  templates/<host>/<owner>/<repo>/<sha>/
  test-runner/lgx-test-<version>.lg
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
- [x] REPL: bare `lgx run` opens `lg`'s REPL; `lgx nrepl` adds an nREPL
  server on a random or `--port`-chosen port.
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
