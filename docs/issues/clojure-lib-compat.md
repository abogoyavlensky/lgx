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

**Repro:** [weavejester/hiccup](https://github.com/weavejester/hiccup) - all
source files end in `.clj`, none in `.cljc`.

**Notes:** [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go#L79-L84)
currently tries `.lg` and `.cljc` only. Adding `.clj` is a one-line change
and would unblock libs that didn't migrate to `.cljc`. Risk: `.clj` files
typically have heavier JVM coupling than `.cljc` files, so they'd still
fail at later stages - but at least the resolver wouldn't be the blocker.

## Reproducing

Each lib has a working repro in `lgx`:

```
git clone https://github.com/abogoyavlensky/lgx
cd lgx
make build
LGX_LG=/path/to/lg ./bin/lgx run examples/clojure-libs/<lib>/main.lg
```

(Replace `<lib>` with `medley` or `hiccup`.)
