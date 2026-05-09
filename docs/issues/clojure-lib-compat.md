# Issue: compatibility gaps blocking real Clojure libraries from loading

**Repo:** [nooga/let-go](https://github.com/nooga/let-go) (file once
`-source-paths` PR is merged)

**Status:** draft

## Summary

While building `lgx` (a small package manager for let-go), I tried loading
several real Clojure libraries through the new `-source-paths` flag. Four
distinct let-go-side gaps came up. Probably worth separate tickets — filing
together for triage.

## 1. Reader: `^ClassName` metadata shorthand on params/return

**Repro:** [babashka/cli@v0.8.67](https://github.com/babashka/cli/blob/v0.8.67/src/babashka/cli.cljc#L57)

```clojure
(defn- first-char ^Character [^String arg] ...)
```

**Error:**

```
Syntax error reading source ... unsupported meta form
```

**Notes:** `^Sym` is shorthand for `^{:tag Sym}`. The tag is informational
in Clojure (a hint, not a binding requirement). Simplest fix: parse as
opaque metadata and ignore the tag value.

## 2. Reader/compiler: `def` with docstring

**Repro:** [asko/ruuter@31209771](https://git.nmm.ee/asko/ruuter/src/commit/31209771dafba33e36e8f72bbf31de95555ca511/src/ruuter/core.cljc#L252)

```clojure
(def ^:private compile-routes*
  "Memoized version of compile-routes for implicit compilation."
  (memoize compile-routes))
```

**Error:**

```
CompileError: def: wrong number of forms (3), need 1 or 2
```

**Notes:** Clojure's `def` supports `(def symbol doc-string? init?)`.
let-go currently rejects the 3-form arity. Common pattern in real code.

## 3. Runtime: `:default` reader-conditional referring to JVM classes

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
JVM-only body. Hardest of the four — possible directions:

- Add a let-go-specific reader-conditional tag (e.g. `:lg`) so libs can
  branch on it and skip JVM bits;
- Stub common `clojure.lang.*` classes as no-op markers;
- Treat unresolved JVM class refs as opaque at compile time so the form
  loads, even if calling it fails.

## 4. Resolver: `.clj` extension not searched

**Repro:** [weavejester/hiccup](https://github.com/weavejester/hiccup) — all
source files end in `.clj`, none in `.cljc`.

**Notes:** [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go#L79-L84)
currently tries `.lg` and `.cljc` only. Adding `.clj` is a one-line change
and would unblock libs that didn't migrate to `.cljc`. Risk: `.clj` files
typically have heavier JVM coupling than `.cljc` files, so they'd still
fail at later stages — but at least the resolver wouldn't be the blocker.

## Reproducing

Each lib has a working repro in `lgx`:

```
git clone https://github.com/abogoyavlensky/lgx
cd lgx
make build
LGX_LG=/path/to/lg-with-source-paths-pr ./bin/lgx run examples/clojure-libs/<lib>/main.lg
```

(Replace `<lib>` with `medley`, `babashka-cli`, or `ruuter`.)
