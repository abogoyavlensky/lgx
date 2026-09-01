# lgx development workflow

How to iterate on lgx itself without re-bundling on every change.

## Dev mode (no bundle)

Run lgx via the system `lg` against the source files:

```
lg lgx.lg <subcommand> [args...]
```

Run from the lgx project root so the resolver finds `lgx/*.lg` under
`.` (the default search path). From a subdirectory the resolver can't
find `lgx.config`, `lgx.cache`, etc., and lgx fails with
`Can't resolve cache/ensure-lib! in this context`.

## Build the bundle

```
make build      # produces bin/lgx
```

The bundle works from any directory because all lgx namespaces are
embedded.

## Pointing at a custom `lg`

`LGX_LG` overrides the `lg` binary lgx shells out to for user scripts:

```
LGX_LG=/path/to/let-go/lg bin/lgx run examples/with-lib/main.lg
```

Useful for testing an unreleased let-go PR or an experimental local
build. The bundle's embedded let-go runtime stays the same; only the
user-script invocation changes.

## Smoke testing examples

```
cd examples/clojure-libs/with-malli
/path/to/lgx/bin/lgx run
```

`examples/clojure-libs/` holds one project per Clojure library running
under let-go; each proves the fetch-and-require flow end-to-end.
`examples/local-dep/` covers `:local/root`.

For a project with `:go/*` deps, `LGX_LG` is the wrong lever - it
overrides the custom runtime entirely. Use `LGX_LETGO_REPLACE` to point
the runtime build at a let-go checkout instead:

```
LGX_LETGO_REPLACE=/path/to/let-go lgx run
```

See [`lgx-go-runtimes.md`](lgx-go-runtimes.md).

## Cache management

The cache lives at `~/.lgx/gitlibs/<host>/<owner>/<repo>/<sha>/`. To
force a re-fetch, delete the leaf:

```
rm -rf ~/.lgx/gitlibs/github.com/nooga/let-go/<sha>/
```

Set `LGX_HOME=/tmp/test-cache` to use a throwaway cache root for
tests. Useful when probing a new dep or verifying install flow without
touching the real cache.

Deps declared with `:local/root` bypass this cache. lgx resolves their
paths from the project root on each invocation.

## Git operations lgx uses

For reference when debugging:

- `git clone <url> <tmpdir>` — initial fetch.
- `git -C <tmpdir> checkout <sha>` — pin to the resolved sha.
- `git ls-remote <url> refs/tags/<tag>` — resolve tag → sha when only
  `:git/tag` is given.

After clone + checkout, the `.git/` directory is removed and the
worktree renamed atomically to the cache path.

## Running tests

```
make test        # build bundle, run unit + e2e
```

Unit tests live under `test/` as `*_test.lg` / `*_test.cljc` files and
use let-go's embedded `test` namespace. E2E tests live in `tests/e2e.sh`
and drive the built
`bin/lgx` against a file:// bare repo seeded under a throwaway
`LGX_HOME` — hermetic, no network. Both are invoked by `tests/run.sh`.

---

> **Verify against (in this repo):**
> [`Makefile`](../../Makefile),
> [`lgx.lg`](../../lgx.lg) (subcommand dispatch),
> [`lgx/runner.lg`](../../lgx/runner.lg) (`lg-binary`, `exec-lg-interactive!`),
> [`lgx/cache.lg`](../../lgx/cache.lg) (`ensure-lib!`,
> `clone-and-checkout!`, `coord-dir`),
> [`tests/run.sh`](../../tests/run.sh),
> [`tests/e2e.sh`](../../tests/e2e.sh).
