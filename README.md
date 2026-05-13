# lgx

A project manager for [let-go](https://github.com/nooga/let-go). Reads
git-pinned dependencies from `lgx.edn`, fetches them into a per-user
cache, and runs `lg` with the cached paths added to its namespace
search path.

## Status

Pre-alpha.

## Installation

Prebuilt binaries for `linux_amd64`, `linux_arm64`, `darwin_amd64`, and
`darwin_arm64` are attached to each GitHub Release.

### Requirements

- [`lg`](https://github.com/nooga/let-go) on `PATH`, or pointed to by
  `LGX_LG`. `lgx exec` shells out to it; `lgx deps` does not need it.
- `git` on `PATH`. lgx uses it to clone, fetch, and check out
  dependencies.


### With [mise](https://mise.jdx.dev)

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

### Install script

One-liner - installs the latest release to `~/.local/bin/lgx`:

```sh
curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
```
#### Options

Pin a version or change the install directory with env vars:

```sh
LGX_VERSION=0.1.0-alpha1 LGX_INSTALL_DIR=~/bin \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh)"
```

Re-run the same command to upgrade in place. The script verifies each
archive against `checksums.txt`; read [`scripts/install.sh`](./scripts/install.sh)
before piping if you'd rather see what runs.

`lgx exec` also needs `lg` on `PATH`. Install it via
[mise](https://mise.jdx.dev) (`mise use github:nooga/let-go`), Homebrew
(`brew tap nooga/let-go https://github.com/nooga/let-go && brew install let-go`),
or grab a binary from
[let-go releases](https://github.com/nooga/let-go/releases).

### Or manually download latest release

If you'd rather skip the script entirely:

```sh
VERSION=0.1.0-alpha1
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o lgx.tar.gz \
  "https://github.com/abogoyavlensky/lgx/releases/download/v${VERSION}/lgx_${VERSION}_${OS}_${ARCH}.tar.gz"
tar -xzf lgx.tar.gz
install -m 0755 lgx ~/.local/bin/
```

## `lgx.edn`

```edn
{:paths ["src" "resources"]
 :deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}
  org.clojure/tools.cli {:git/url "https://github.com/clojure/tools.cli"
                         :git/sha "0123456789abcdef0123456789abcdef01234567"
                         :deps/root "src/main/clojure"}
  my/lib {:local/root "../my-lib"}}}
```

Each git coord must specify `:git/url` plus one of `:git/sha` or
`:git/tag`. Tag-pinned coords cache under the tag name itself - no
`git ls-remote` call when the lib is already cached, and no network use
at all on cache hits. Sha-pinned coords cache under the sha. If a
maintainer force-updates a tag upstream, `lgx deps` will not pick up
the new commit automatically; delete the cache directory
(`rm -rf ~/.lgx/gitlibs/<host>/<owner>/<repo>/<sanitized-tag>`) to
refresh.

Top-level `:paths` lists project source paths relative to the project root.
`lgx exec` prepends them to dependency paths in `-source-paths`, so project
namespaces shadow lib namespaces. Missing entries print a warning and still
pass through to `lg`.

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

## Cache layout

```
$LGX_HOME/gitlibs/<host>/<owner>/<repo>/<ref>/
```

Default `LGX_HOME` is `~/.lgx`.
`<ref>` is the sha for `:git/sha` coords, or the tag with `/` replaced
by `_` for `:git/tag` coords.

## Commands

- `lgx deps` - read `lgx.edn`, fetch missing deps. Idempotent.
- `lgx exec [args...]` - find the nearest `lgx.edn` walking up from the
  current directory, install missing deps, then exec
  `lg -source-paths <resolved> [args...]`. All args reach `lg` verbatim.
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
- [x] **Per-coord `:deps/root`.** Override the `<ref>/src` default per
  dependency, matching tools.deps' `:deps/root`.
- [x] **Per-coord `:local/root`.** Point a dep at a local directory
  instead of a git URL, matching tools.deps' `:local/root`.
- [ ] **`lgx paths` command.** Print the fully-resolved source-path list
  lgx would hand to `lg`.
- [ ] **Transitive dependencies.** Follow `lgx.edn` files inside fetched
  libs and resolve the union, with first-wins on conflicts.
- [ ] **Aliases.** Per-environment dep sets in `lgx.edn`
  (e.g. `:migrate`, `:dev`) selectable from the CLI.
- [ ] **Tasks.** Named command shortcuts.
- [ ] **Non-source resources** (let-go-side). `lg`'s resolver finds `.lg`
  and `.cljc` only; libs that ship templates, JSON, or other assets
  have no resolution story. Likely needs an upstream change.
- [ ] `:test-paths` override.
- [ ] `lgx build` - build project binary.
- [ ] `lgx repl` - run repl.
- [ ] `lgx test` - test runner.
- [ ] `lgx new` - project scaffolding.
- [ ] [OPTIONAL] **`lgx fmt` / `lgx lint`** *(maybe)*. Thin wrappers if the let-go
  ecosystem grows tooling worth fronting.

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
