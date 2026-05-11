# lgx

A project manager for [let-go](https://github.com/nooga/let-go). Reads
git-pinned dependencies from `lgx.edn`, fetches them into a per-user
cache, and runs `lg` with the cached paths added to its namespace
search path.

## Status

Pre-alpha. Expect breakage.

## Installation

Prebuilt binaries for `linux_amd64`, `linux_arm64`, `darwin_amd64`, and
`darwin_arm64` are attached to each GitHub Release.

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

Or ad hoc: `mise use github:abogoyavlensky/lgx@latest`. The
`github` backend needs no asdf plugin.

> [!TIP]
> If you hit github auth problem with mise then you can pin specific version of the tools in `.mise.toml`,
> or set `export GITHUB_TOKEN="$(gh auth token)"` in your shell config.

### Manual download

```sh
VERSION=0.1.0
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o lgx.tar.gz \
  "https://github.com/abogoyavlensky/lgx/releases/download/v${VERSION}/lgx_${VERSION}_${OS}_${ARCH}.tar.gz"
tar -xzf lgx.tar.gz
sudo mv lgx /usr/local/bin/
```

`checksums.txt` next to the archives lets you verify the download.

## Requirements

- [`lg`](https://github.com/nooga/let-go) on `PATH`, or pointed to by
  `LGX_LG`. `lgx run` shells out to it; `lgx install` does not need it.
- `git` on `PATH`. lgx uses it to clone, fetch, and check out
  dependencies.

## `lgx.edn`

```edn
{:deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}
  some-org/util      {:git/url "https://github.com/some-org/util"
                      :git/sha "0123456789abcdef0123456789abcdef01234567"}}}
```

Each coord must specify `:git/url` plus one of `:git/sha` or `:git/tag`. Tags
are resolved to a sha at install time via `git ls-remote`. Sha-pinned coords
are fully reproducible; tag-pinned coords re-resolve on each `lgx install`.

For each lib, the path added to `-source-paths` is `<sha>/src` if that dir
exists, else the repo root. This matches the tools.deps default of
`:paths ["src"]` and works out of the box for most Clojure-style libraries.

Current limitations: HTTPS URLs only (no SSH), no transitive deps, no per-coord `:paths` override.

## Cache layout

```
$LGX_HOME/gitlibs/<host>/<owner>/<repo>/<sha>/
```

Default `LGX_HOME` is `~/.lgx`.

## Commands

- `lgx install` - read `lgx.edn`, fetch missing deps. Idempotent.
- `lgx run [args...]` - find the nearest `lgx.edn` walking up from the
  current directory, install missing deps, then exec
  `lg -source-paths <resolved> [args...]`. All args reach `lg` verbatim.

## Development

```
make build       # produces bin/lgx - bundled standalone binary
make dev-install # runs `lg lgx.lg install` from the lgx project root
make dev-run     # runs examples/hello/main.lg through dev `lg lgx.lg ...`
```

For dev iteration, run from the lgx project root so the resolver finds
`lgx/*.lg`. Once built, the bundled `bin/lgx` works from any directory.

To run lgx against a non-default `lg` binary (testing an unreleased PR,
debugging a custom build), set `LGX_LG`:

```
LGX_LG=/path/to/lg bin/lgx run script.lg
```

## Roadmap (draft)

Concrete things on the table, not commitments. Order is
priority-agnostic.

- [ ] **Transitive dependencies.** Follow `lgx.edn` files inside fetched
  libs and resolve the union, with first-wins on conflicts. Today lgx
  reads only the project's own `lgx.edn`.
- [ ] `:paths` override.
- [ ] **Per-coord `:deps/root`.** Override the `<sha>/src` default per
  dependency, matching tools.deps' `:deps/root`.
- [ ] **Aliases.** Per-environment dep sets in `lgx.edn`
  (e.g. `:test`, `:dev`) selectable from the CLI.
- [ ] **Tasks.** Named command shortcuts.
- [ ] **`lgx paths` command.** Print the fully-resolved source-path list
  lgx would hand to `lg`.
- [ ] **Non-source resources** (let-go-side). `lg`'s resolver finds `.lg`
  and `.cljc` only; libs that ship templates, JSON, or other assets
  have no resolution story. Likely needs an upstream change.
- [ ] `lgx test` - test runner.
- [ ] `lgx new` - project scaffolding.
- [ ] [OPTIONAL] **`lgx fmt` / `lgx lint`** *(maybe)*. Thin wrappers if the let-go
  ecosystem grows tooling worth fronting.

## Examples

- [`examples/hello/`](./examples/hello) - no-deps script.
- [`examples/with-lib/`](./examples/with-lib) - real fetch-and-require flow
  using let-go's own repo as the dep (until a real let-go library ecosystem
  exists).
- [`examples/clojure-libs/`](./examples/clojure-libs) - survey of real
  Clojure libraries (medley, babashka/cli, ruuter) and the let-go-side gaps
  that currently block them.

## License
MIT License
Copyright (c) 2026 Andrey Bogoyavlenskiy
