# Issue: compatibility gaps blocking real Clojure libraries from loading

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

While building `lgx` (a small project manager for let-go), I tried loading
several real Clojure libraries through `-source-paths`. Two distinct
let-go-side gaps remain after the fixes in
[`af894a3`](https://github.com/nooga/let-go/commit/af894a3). Probably
worth separate tickets - filing together for triage.

Other gaps from the same investigation now have dedicated tickets:

- `^ClassName` metadata shorthand and `def` with docstring: fixed on
  master in [`af894a3`](https://github.com/nooga/let-go/commit/af894a3).
  See [def-docstring.md](./def-docstring.md) for the latter.

## 1. Runtime: `:default` reader-conditional referring to JVM classes

> **Resolved for medley (2026-05-31).** With `LG_READ_CLJ=1`, medley 1.10.0's
> `medley.core` now loads cleanly under let-go and the pure data/map/seq fns
> plus several interop fns work. Fixed by additive Clojure-compat aliases in
> let-go's `installClojureCompatAliases` (`pkg/rt/lang.go`) plus type-ancestry
> wiring (`pkg/rt/hierarchy.go`) — the "stub common `clojure.lang.*` classes as
> markers" direction below. Specifics (see let-go branch `medley-compat-minimal`
> / `docs/plans/2026-05-31-medley-compat.md`):
> - `clojure.lang.IEditableCollection` marker + ancestry on editable colls;
>   `clojure.lang.MapEntry.` constructor sugar.
> - `clojure.lang.PersistentQueue` marker + load-only `EMPTY` stub (fails loudly
>   if conj'd, rather than returning a wrong reversed list).
> - `java.util.ArrayList` load-only constructor stub.
> - `Throwable` made **real**: `ExInfoType` reports it as an ancestor and
>   `ExInfo` implements `Receiver` (`getMessage`/`getCause`) + `IMeta`, so
>   `m/ex-message`/`m/ex-cause` work on ex-info (incl. the `^Throwable` type-hint
>   path) and return nil for everything else.
> - `java.util.UUID/fromString` + `/randomUUID` (real) and
>   `java.util.regex.Pattern` → `RegexType` (real): `m/uuid`, `m/random-uuid`,
>   `m/regexp?` all work.
> - `compare-and-set!` added as a real Atom primitive (was missing) — unblocks
>   `m/deref-swap!`/`m/deref-reset!`.
>
> Remaining degraded (load-only, by design): `queue`/`queue?` and
> `partition-between`/`sliding`.

**Repro:** [weavejester/medley@1.10.0](https://github.com/weavejester/medley/blob/1.10.0/src/medley/core.cljc#L41-L43)

```clojure
(defn- editable? [coll]
  #?(:cljs    (satisfies? cljs.core/IEditableCollection coll)
     :default (instance? clojure.lang.IEditableCollection coll)))
```

**Error:**

```
CompileError: Can't resolve clojure.lang.IEditableCollection in this context
```

**Notes:** let-go currently matches `:default`, then tries to compile the
JVM-only body. Hardest of the four - possible directions:

- Add a let-go-specific reader-conditional tag (e.g. `:lg`) so libs can
  branch on it and skip JVM bits;
- Stub common `clojure.lang.*` classes as no-op markers;
- Treat unresolved JVM class refs as opaque at compile time so the form
  loads, even if calling it fails.

## 2. Resolver: `.clj` extension not searched

> **Superseded by** [`letgo-clj-support.md`](./letgo-clj-support.md), which
> covers the resolver change plus the `LG_READ_CLJ` env-var wiring and the
> reader-conditional priority fix needed to make `.clj` libraries actually
> usable end-to-end. The note below is kept for history.

**Repro:** [weavejester/hiccup](https://github.com/weavejester/hiccup) - all
source files end in `.clj`, none in `.cljc`.

**Notes:** [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go#L79-L84)
currently tries `.lg` and `.cljc` only. Adding `.clj` is a one-line change
and would unblock libs that didn't migrate to `.cljc`. Risk: `.clj` files
typically have heavier JVM coupling than `.cljc` files, so they'd still
fail at later stages - but at least the resolver wouldn't be the blocker.

## 3. Runtime: functions carry no metadata; `ns-publics` missing

> **Resolved for bond (2026-07-03).** With both fixes below, circleci/bond
> 0.6.0's `bond.james` loads under let-go and its core spying API — `spy`,
> `calls`, `with-spy`, `with-stub` — works. See
> [`examples/clojure-libs/with-bond/`](../../examples/clojure-libs/with-bond).

**Repro:** [circleci/bond@0.6.0](https://github.com/circleci/bond/blob/0.6.0/src/bond/james.clj)

Two independent let-go gaps, both surfaced by the same tiny library:

- **`ns-publics` unresolved.** `bond.james` defines a top-level
  `ns->fn-symbols` (used only by `with-spy-ns`/`with-stub-ns`) built on
  `ns-publics`, which let-go lacked. One unresolved symbol in a top-level
  form fails the *whole* namespace compile, so even `with-spy` became
  unresolvable:

  ```
  CompileError: Can't resolve ns-publics in this context
  ```

  Fixed by adding a `ns-publics` core fn (`pkg/rt/lang.go`) backed by a new
  `Namespace.PublicVars()` accessor (`pkg/vm/namespace.go`): returns a
  `symbol -> var` map of the namespace's non-private interned vars, accepting
  either a namespace or a symbol naming one.

- **Functions dropped metadata.** Bond's `spy` returns
  `(with-meta (fn [& args] ...) {::calls <atom>})` and `calls` reads that
  `::calls` atom back via `(meta f)`. let-go's function types did not
  implement `IMeta`, so `with-meta` passed the fn through unchanged (the
  load-bearing scalar-hint fallback) and `(meta f)` returned `nil` — every
  `calls` fell into bond's "not a spied function" throw. Fixed by making
  `*Func`, `*Closure`, and `*MultiArityFn` implement `IMeta`
  (`pkg/vm/func.go`) with copy-on-write `WithMeta` — a capture-free fn is a
  shared `OP_LOAD_CONST` constant, so mutating in place would leak metadata
  into every evaluation of the fn literal.

**Still degraded (by design, out of scope for the demo):**
`with-spy-ns`/`with-stub-ns`. `ns->fn-symbols` rebuilds each fn's symbol from
`(:ns (meta v))` / `(:name (meta v))`, but let-go vars do not auto-populate
`:ns`/`:name` metadata (a plain `(defn f …)` has `(meta (var f))` => `nil`),
so the namespace-wide helpers resolve to bogus symbols and spy nothing. The
per-var API (`with-spy`/`with-stub`) is unaffected and is what the example
demonstrates.

## Reproducing

Each lib has a working repro in `lgx`:

```
git clone https://github.com/abogoyavlensky/lgx
cd lgx
make build
LGX_LG=/path/to/lg ./bin/lgx run examples/clojure-libs/<lib>/main.lg
```

(Replace `<lib>` with `medley` or `bond`. `hiccup` and `aero` still fail to
load — they document open gaps 1 and 2 above.)
