# lgx

A package manager for [let-go](https://github.com/nooga/let-go), modeled on
[`tools.deps`](https://clojure.org/reference/deps_and_cli) and
[`tools.gitlibs`](https://github.com/clojure/tools.gitlibs).

V1 supports git-based dependencies declared in an `lgx.edn` file at the project
root. lgx fetches them into a per-user cache and invokes `lg` with
`--source-paths` set so the libraries' namespaces resolve normally.

## Status

Pre-alpha scaffold. Several upstream changes in let-go are tracked under
[`issues/`](./issues):

1. **`-source-paths` CLI flag** on `lg` (PR open).
2. **Inherited-stdio runner** (`os/run` or similar) so `lgx run -r` REPL works
   ([issues/inherit-stdio-runner.md](./issues/inherit-stdio-runner.md)).
3. **Reader/compiler/resolver gaps** blocking real Clojure libraries
   ([issues/clojure-lib-compat.md](./issues/clojure-lib-compat.md)).

## `lgx.edn`

```edn
{:deps
 {nooga/let-go-async {:git/url "https://github.com/nooga/let-go-async"
                      :git/tag "v0.2.0"}
  some-org/util      {:git/url "https://github.com/some-org/util"
                      :git/sha "0123456789abcdef0123456789abcdef01234567"}}}
```

Each coord must specify `:git/url` plus one of `:git/sha` or `:git/tag`. Tags
are resolved to a sha at install time via `git ls-remote`. Sha-pinned coords
are fully reproducible; tag-pinned coords re-resolve on each `lgx install`.

For each lib, the path added to `--source-paths` is `<sha>/src` if that dir
exists, else the repo root. This matches the tools.deps default of
`:paths ["src"]` and works out of the box for most Clojure-style libraries.

V1 limitations: HTTPS URLs only (no SSH), no transitive deps, no lockfile, no
per-coord `:paths` override.

## Cache layout

```
$LGX_HOME/gitlibs/<host>/<owner>/<repo>/<sha>/
```

Default `LGX_HOME` is `~/.lgx`.

## Commands

- `lgx install` - read `lgx.edn`, fetch missing deps. Idempotent.
- `lgx run [args...]` - find the nearest `lgx.edn` walking up from CWD, ensure
  deps are installed, then exec `lg --source-paths <resolved> [args...]`. All
  args are forwarded to `lg` verbatim.

## Build

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

## Examples

- [`examples/hello/`](./examples/hello) - no-deps script.
- [`examples/with-lib/`](./examples/with-lib) - real fetch-and-require flow
  using let-go's own repo as the dep (until a real let-go library ecosystem
  exists).
- [`examples/clojure-libs/`](./examples/clojure-libs) - survey of real
  Clojure libraries (medley, babashka/cli, ruuter) and the let-go-side gaps
  that currently block them.

## Layout

```
lgx.lg              entry, command dispatch
lgx/config.lg       find & parse lgx.edn
lgx/cache.lg        gitlibs path layout, fetch
lgx/runner.lg       locate `lg`, exec with -source-paths
examples/           see above
issues/             drafts of upstream let-go issues
docs/plans/         design docs
```
