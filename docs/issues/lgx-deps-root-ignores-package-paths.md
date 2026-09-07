# Issue: `:deps/root` ignored the package's own `:paths`

**Repo:** this one (lgx)

**Status: fixed** on `go-deps` (`lgx/cache.lg`, `lgx/config.lg`).

## Summary

`resolve-source-path` used `:deps/root` verbatim as the source path, so a
monorepo package laid out as `<repo>/<pkg>/src` was unloadable through a
git coord: lgx put `<checkout>/<pkg>` on `-source-paths`, and every
namespace under `<pkg>/src` failed to resolve.

This was the missed half of `197ca49` ("read a dep's lgx.edn from
`:deps/root` when it lives there"). That commit taught lgx to read a
monorepo package's *config* from `<pkg>/lgx.edn` so its `:deps` reach the
consumer. It left the *source path* alone, so lgx read the package's
`:paths ["src"]` and then ignored it.

## Impact

Every package in
[letgo-packages](https://github.com/abogoyavlensky/letgo-packages) — all
of which are `<pkg>/lgx.edn` beside `<pkg>/src` — was unusable by the
consumption pattern its own README documents:

```clojure
{:deps {abogoyavlensky/letgo-sqlite
        {:git/url "https://github.com/abogoyavlensky/letgo-packages"
         :git/tag "sqlite-v0.1.0"
         :deps/root "sqlite"}}}
```

It went unnoticed because nothing is tagged yet and every `example/` in
that repo uses `:local/root ".."`, which takes the default `src/` probe
and lands on the right directory by accident.

The failure is also a poor diagnostic — `unable to load namespace
wails.core`, pointing at the consumer's `(ns ...)` form, with nothing
naming the dep or the path.

## The fix

`resolve-source-paths` (renamed, now plural) checks whether the
`:deps/root` directory holds its own `lgx.edn` and, if it declares
`:paths`, resolves them against that directory. A `:deps/root` that only
points at sources — `org.clojure/tools.cli` with
`:deps/root "src/main/clojure"` — carries no `lgx.edn`, declares no
`:paths`, and keeps using the directory verbatim, so the change is
backward compatible.

This mirrors `config/dep-config-dir`, which already relocates the config
read only when the `:deps/root` directory has an `lgx.edn` — the same
condition, now used for both halves.

`ensure-lib!` returns `:paths` (a vector) instead of `:path`, since a
package may declare more than one. `:paths` was added to
`dep-config-schema`, which validated only `:deps` before: the key is now
load-bearing, and silently ignoring a malformed one would resurface as
the same unhelpful "unable to load namespace".

## Verification

Three unit tests in `test/lgx/cache_test.lg` cover the package layout, a
package declaring multiple paths, and the tools.cli-shaped `:deps/root`
with no config. The end-to-end check is `examples/wails-desktop`, which
consumes the letgo-packages `wails` package by git sha and could not run
before the fix.
