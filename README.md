# lgx

A project manager for [let-go](https://github.com/nooga/let-go). 
Manage dependencies, run, build, test your app, and extend with custom tasks.

## Status

Pre-alpha. Breaking changes are possible.

## Installation

Prebuilt binaries for `linux_amd64`, `linux_arm64`, `darwin_amd64`, and
`darwin_arm64` are attached to each GitHub Release.

### Requirements

- [`lg`](https://github.com/nooga/let-go) on `PATH`, or pointed to by
  `LGX_LG`. `lgx run` shells out to it; `lgx install` does not need it.
- `git` on `PATH`. lgx uses it to clone, fetch, and check out
  dependencies.

### Install script

One-liner - installs the latest release to `~/.local/bin/lgx`:

```sh
curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
```

### With [mise](https://mise.jdx.dev)

Ad hoc: `mise use github:abogoyavlensky/lgx@0.1.0-alpha1`

or add to your project:

*.mise.toml*
```toml
[tools]
lg = "latest"
lgx = "latest"

[tool_alias]
lg = "github:nooga/let-go"
lgx = "github:abogoyavlensky/lgx"

```

Then install with:

```bash
mise install
```

> [!TIP]
> If you hit github auth problem with mise then you can pin specific version of the tools in `.mise.toml`,
> or set `export GITHUB_TOKEN="$(gh auth token)"` in your shell config.

## `lgx.edn`

```edn
{:paths   ["src" "resources"]
 :main    "main.lg"
 :targets {:bin {:out "bin/myapp"}}
 :deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}
  org.clojure/tools.cli {:git/url "https://github.com/clojure/tools.cli"
                         :git/sha "0123456789abcdef0123456789abcdef01234567"
                         :deps/root "src/main/clojure"}
  my/lib {:local/root "../my-lib"}}}
```

Each git coord must specify `:git/url` plus one of `:git/sha` or
`:git/tag`. Tag-pinned coords cache under the tag name itself.

Top-level `:paths` lists project source paths relative to the project root.
`lgx run` prepends them to dependency paths in `-source-paths`, so project
namespaces shadow lib namespaces. Missing entries print a warning and still
pass through to `lg`.

Top-level `:main` names a default entrypoint script relative to the project
root. `lgx run` substitutes it as the script when:

- `lgx run` is called with no arguments → `lg <X> main.lg`.
- `lgx run [lg-flags...] -- [app-args...]` is called *without* an
  explicit script in the pre-`--` slice → lgx inserts `:main` between
  the lg flags and the `--`. Examples: `lgx run -- list` becomes
  `lg <X> main.lg -- list`; `lgx run -r -- foo` becomes
  `lg <X> -r main.lg -- foo`.

When the pre-`--` args already contain an explicit script (suffix
`.lg`, `.cljc`, or `.clj`), lgx skips injection and passes everything
through, so `lgx run foo.lg -- bar` runs `lg <X> foo.lg -- bar`. Bare
`lgx run -e '(...)'` and `lgx run foo.lg` (no `--`) likewise pass
through unchanged.

The `--` is preserved in the outgoing command line so it lands in
`os/args` as a stable marker. lgx also appends a trailing `--` to
the inject paths even when there are no user args (so bare `lgx run`
produces `lg <X> main.lg --`), so the same parsing idiom works for
both dev and built binary:

```clojure
(defn- cli-argv [argv]
  "Return args after the `--` while developing, or CLI args in bundled mode."
  (if (some #(= % "--") argv)
    (rest (drop-while #(not (= % "--")) argv)) ; lgx run -- <args>
    (rest argv)))  ; ./bin/myapp <args>
```

`-source-paths` and other lg flags live before `--`; a POSIX CLI
parser (tiny-cli, babashka/cli, tools.cli) sees only `app-args` and
nothing leaks. For the strict pass-through case (`lgx run foo.lg bar`,
without `--`), you must add `--` yourself to use the same idiom —
`lgx run foo.lg -- bar`.

`lgx run -- foo` without `:main` set is an error
(`lgx: -- requires :main to be set in lgx.edn`). If `:main` points at
a file that does not exist on disk, `lgx run` exits with
`lgx: :main script not found: <path>`.

Top-level `:targets` declares how `lgx build` produces artifacts. Step 1
supports the `:bin` target only, with a single required `:out` field giving
the output path relative to the project root. `lgx build` is sugar for
`lg -source-paths <resolved> -b <out> <main>`; the parent of `:out` is
auto-created if missing. Extra args go before `-b`, so cross-OS bundling
works as `lgx build -bundle-base /path/to/lg`. Both `:main` and
`:targets/:bin` are required for `lgx build` — a missing one prints a
clear error.

For each lib, the path added to `-source-paths` is `<ref>/src` if that dir
exists, else the repo root. This matches the tools.deps default of
`:paths ["src"]` and works out of the box for most Clojure-style libraries.
Set `:deps/root` on a coord to override that default. For example,
`org.clojure/tools.cli` uses `:deps/root "src/main/clojure"`.

Use `:local/root` instead of `:git/url` to point at a directory on disk
when iterating on a library beside the project. The path may be relative
to the project root (`../sibling`, `./libs/x`) or absolute
(`/abs/path`). `:deps/root` still applies, so
`{:local/root "../mylib" :deps/root "src/main/clojure"}` works the same
as with a git coord. Local deps bypass the gitlibs cache and do not
appear in install output. A coord uses either `:local/root` or `:git/*`;
mixing them is an error.

Current limitations: HTTPS URLs only (no SSH), no transitive deps.

## Deps cache layout

```
$LGX_HOME/gitlibs/<host>/<owner>/<repo>/<ref>/
```

Default `LGX_HOME` is `~/.lgx`.
`<ref>` is the sha for `:git/sha` coords, or the tag with `/` replaced
by `_` for `:git/tag` coords.

## Commands

- `lgx install` - read `lgx.edn`, fetch missing deps. Idempotent.
- `lgx run [script] [args...]` - find the nearest `lgx.edn` walking up
  from the current directory, install missing deps, then exec
  `lg -source-paths <resolved> [script] [args...]`. If `script` is
  omitted and `:main` is set in `lgx.edn`, it is used as the script. All
  args reach `lg` verbatim. Global option `--verbose` prints the
  resolved `lg` command first.
- `lgx build [args...]` - bundle `:main` into `:targets/:bin/:out` via
  `lg -b`. Reads `:main`, `:paths`, `:deps`, and `:targets/:bin/:out`
  from `lgx.edn`. Extra args are forwarded to `lg` before `-b` (for
  example, `-bundle-base /path/to/lg` for cross-OS builds). Both
  `:main` and `:targets/:bin` are required; either being absent prints
  a clear error.
- `lgx help` - print usage.
- `lgx version` - print version.

## Development

```
make build       # produces bin/lgx - bundled standalone binary
make dev-install # runs `lg lgx.lg install` from the lgx project root
make dev-run     # runs examples/hello/main.lg through dev `lg lgx.lg ...`
make test        # runs all tests through dev `lg lgx.lg ...`
make clean       # remove bin/lgx and all build artifacts
```

For dev iteration, run from the lgx project root so the resolver finds
`lgx/*.lg`. Once built, the bundled `bin/lgx` works from any directory.

To run lgx against a non-default `lg` binary (testing an unreleased PR,
debugging a custom build), set `LGX_LG`:

```
LGX_LG=/path/to/lg bin/lgx run script.lg
```

## Roadmap (draft)

Things that are currently missing or incomplete, in no particular order:

- [x] `:paths` source paths.
- [x] Per-coord `:deps/root`. Override the `<ref>/src` default per dependency, matching tools.deps' `:deps/root`.
- [x] Per-coord `:local/root`. Point a dep at a local directory instead of a git URL, matching tools.deps' `:local/root`.
- [x] `:tasks` - named command shortcuts. (WIP)
- [x] `lgx build` - build project binary.
- [ ] `lgx test` - test runner.
- [ ] `lgx new` - project scaffolding.
- [ ] `lgx repl` - run repl.
- [ ] `lgx init` - create a default `lgx.edn` in the current directory.
- [ ] **Transitive dependencies.** Follow `lgx.edn` files inside fetched libs and resolve the union, with first-wins on conflicts.
- [ ] `lgx deps` - print dependency tree.
- [ ] `lgx fmt` / `lgx lint`
- [ ] `lgx outdate` - check for outdated deps.
- [ ] `lgx clean` - clean build artifacts from `:targets`.
- [ ] `:contexts` - set environment-specific patha and deps configurations.
- [ ] Non-source resources (let-go-side). `lg`'s resolver finds `.lg`
  and `.cljc` only; libs that ship templates, JSON, or other assets
  have no resolution story. Likely needs an upstream change.

## Examples

- [`examples/hello/`](./examples/hello) - no-deps script.
- [`examples/with-lib/`](./examples/with-lib) - real fetch-and-require flow
  using let-go's own repo as the dep (until a real let-go library ecosystem
  exists).
- [`examples/local-dep/`](./examples/local-dep) - project plus sibling
  local library using `:local/root`.
- [`examples/clojure-libs/`](./examples/clojure-libs) - survey of real
  Clojure libraries (medley, babashka/cli, ruuter) and the let-go-side gaps
  that currently block them.

## License
MIT License
Copyright (c) 2026 Andrey Bogoyavlenskiy
