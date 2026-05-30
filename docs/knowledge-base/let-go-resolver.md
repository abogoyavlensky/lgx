# let-go's namespace resolver

What `(:require [foo.bar])` actually does, and why lib layout matters.

## Search algorithm

`pkg/resolver/resolver.go::Load(name)`:

1. Try embedded namespaces first (`core`, `string`, `set`, `walk`,
   `test`, `pprint`, `edn`, `io`, `async`, `zip`, `data`, `term`).
2. Build candidate paths from the namespace name. For `foo.bar`:
   - `foo/bar.lg`
   - `foo_bar.lg` (hyphen → underscore variant)
   - `foo/bar.cljc`
   - `foo_bar.cljc`
   - `foo/bar.clj` (added by [`letgo-clj-support.md`](../issues/letgo-clj-support.md))
   - `foo_bar.clj`
3. Try each candidate under each entry of the resolver's path list
   (`["."]` by default; `-source-paths` appends more).
4. Return `nil` if nothing matches — silently. `(require 'missing)`
   does not raise; later use of an undefined symbol does.

## Extensions searched

`.lg`, `.cljc`, and `.clj`. The `.lg` candidates are tried first, then
`.cljc`, then `.clj`. A library that ships both `foo.cljc` (let-go-safe)
and `foo.clj` (JVM-flavored) loads the `.cljc` variant.

`.clj` support landed via [`letgo-clj-support.md`](../issues/letgo-clj-support.md);
it requires let-go ≥ vN.N (TODO: pin the released version once upstream
tags). lgx exports `LG_READ_CLJ=1` for every `lg` spawn so reader
conditionals match `:clj` branches as well.

## Reader conditional priority

When more than one branch could match (e.g. `#?(:lg X :clj Y :default Z)`),
the priority is `:lg > :clj > :default`, regardless of source order.
So `#?(:clj Y :lg X)` resolves to `X` the same as `#?(:lg X :clj Y)`. This
matches `letgo-clj-support.md`'s third diff and lets `.cljc` libraries
target multiple runtimes without having to remember source-order rules.

## Hyphen / underscore handling

`foo-bar.baz` tries both `foo-bar/baz.lg` and `foo_bar/baz.lg`. Match
the convention used by other libs you load.

## Compile-time and runtime hooks

The compiler hooks `(ns …)` and `(in-ns …)` to call `rt.NS(name)`
immediately, which triggers `nsLoader.Load(name)` on the registered
resolver. `(require …)` does the same at runtime. Both compile-time and
runtime require calls go through the same loader.

## Implications for lgx

- A script's `(ns name)` triggers a self re-load if `name` resolves to
  the script's own file under any path on the search list. Use a
  namespace name that doesn't collide. We renamed `lgx.lg`'s namespace
  from `lgx` to `lgx.main` for this reason.
- The resolver doesn't read manifests inside fetched libs — namespaces
  are discovered by file path alone. Lib layout matters: lgx adds
  `<sha>/src/` (or `<sha>/`) to the path; namespaces inside the lib
  must lay their files out to match (`foo/bar.lg` for `foo.bar`).
- Silent-nil load failures make missing requires hard to debug. The
  first symptom is usually a downstream `Can't resolve` error, not the
  failed require itself. Worth checking the candidate paths the
  resolver tried when a lib seems missing.

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/main/pkg/resolver/resolver.go)
> (`Load`, `loadEmbedded`, candidate construction),
> [`pkg/compiler/compiler.go`](https://github.com/nooga/let-go/blob/main/pkg/compiler/compiler.go)
> (compile-time `ns` / `in-ns` / `require` hooks),
> [`pkg/rt/lang.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/lang.go)
> (`rt.NS`, `LookupOrRegisterNS`).
