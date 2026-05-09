# lgx

A package manager for [let-go](https://github.com/nooga/let-go), modeled on
[`tools.deps`](https://clojure.org/reference/deps_and_cli) and
[`tools.gitlibs`](https://github.com/clojure/tools.gitlibs).

V1 supports git-based dependencies declared in an `lgx.edn` file at the project
root. lgx fetches them into a per-user cache and invokes `lg` with
`--source-paths` set so the libraries' namespaces resolve normally.

## Status

Pre-alpha scaffold. Two upstream changes in let-go are required before lgx is
fully functional:

1. **`--source-paths` CLI flag** on `lg`. Resolver already accepts a `[]string`;
   only CLI initialization needs to expose it. Without it, lgx has no way to
   tell `lg` where the cached libs live.
2. **Inherited-stdio runner** (`os/run` or similar). `os/sh` captures all output
   into a string, which means script output won't stream and stdin is dead
   (so `lgx run -r` for the REPL won't work). lgx currently shells out via
   `os/sh` and replays the captured buffers - usable for non-interactive
   scripts, broken for interactive ones.

Both are tiny PRs and tracked separately.

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

V1 limitations: HTTPS URLs only (no SSH), no transitive deps, no lockfile, no
per-lib `:paths` (the repo root of each lib is added to `--source-paths`).

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

## Layout

```
lgx.lg              entry, command dispatch
lgx/config.lg       find & parse lgx.edn
lgx/cache.lg        gitlibs path layout, fetch
lgx/runner.lg       locate `lg`, exec with --source-paths
examples/hello/     example project
```
