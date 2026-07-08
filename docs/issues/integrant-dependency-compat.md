# Issue: run weavejester/dependency + integrant under let-go

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** implemented on the local `integrant-compat` branch

## Summary

Making [`weavejester/dependency`](https://github.com/weavejester/dependency) 1.0.1
and [`weavejester/integrant`](https://github.com/weavejester/integrant) 1.0.1 load
and run under let-go (via lgx) surfaced six gaps. Both libraries are single
`.cljc` files that let-go can already *reach* (`.clj`/`.cljc` resolution +
`LG_READ_CLJ` matching `:clj` reader-conditional branches); the gaps below are the
runtime/compiler features they exercise. Each fix is additive and ships with a
test; the full `make test` suite stays green.

Worked repros live in lgx:

```
LGX_LG=/path/to/let-go/lg lgx run examples/clojure-libs/with-dependency/main.lg
LGX_LG=/path/to/let-go/lg lgx run examples/clojure-libs/with-integrant/main.lg
```

## G1 — `defrecord` doesn't scope record fields in protocol-method bodies

`deftype` rewrites bare field references in inline method bodies (its
`-dt-rewrite*` family turns a field symbol into `(.field recv)`), but `defrecord`
handed method bodies **verbatim** to `extend-type`. So `dependency`'s
`MapDependencyGraph`, whose methods read their `dependencies`/`dependents` fields
by bare name, failed to compile:

```
CompileError: Can't resolve dependencies in this context
```

**Fix (`pkg/rt/core/core.lg`):** generalize the field-rewrite family to take a
field-read emitter; `deftype` keeps `.field`, `defrecord` emits keyword access
`(:field recv)` (records are map-backed — canonical, nil-safe). Also `case`
test-constants that share a field name are left literal (only field *reads* are
rewritten), since `case` quotes its constants. Tests:
`test/defrecord_field_scope_test.lg`.

## G2 — `clojure.lang.PersistentQueue` was a load-only stub

`dependency`'s headline `(topo-sort g)` (no-comparator path) seeds a FIFO
worklist with `(into clojure.lang.PersistentQueue/EMPTY leaves)` and drives it
with `conj`/`peek`/`pop`. `EMPTY` was a marker symbol that failed loudly when
conj'd.

**Fix (`pkg/vm/persistent_queue.go`, `pkg/rt/lang.go`, `pkg/rt/hierarchy.go`):**
a real immutable FIFO queue (front seq + rear slice) implementing
`Collection`+`Sequable`+`Counted`, so `conj`/`into`/`seq`/`count`/`empty?` work
through the existing interfaces; `peek`/`pop` cases added; `PersistentQueue/EMPTY`
bound to the real empty queue; `clojure.lang.PersistentQueue` bound to `QueueType`
so `(type q)` / `instance?` resolve through it; queue registered in
`isSequentialType` so it takes the cross-type sequential-`=` path like vectors.
This also un-degrades medley's `queue`/`queue?`. Tests:
`test/persistent_queue_test.lg`, `pkg/vm/persistent_queue_test.go`, and the
flipped assertions in `test/medley_compat_test.go`.

## G3 — `find-var` missing

integrant's default `init-key` resolves a component fn from a qualified keyword:
`(some-> (find-var (symbol (namespace k) (name k))) var-get)`.

**Fix (`pkg/rt/lang.go`):** a real `find-var` — a namespace-qualified symbol maps
to the interned var (via the namespace registry), or `nil` if the namespace or
name is absent.

## G4 — `enumeration-seq` + `clojure.lang.RT/baseLoader` unresolved

integrant's JVM-only classpath scanners (`resources`/`load-hierarchy`/
`load-annotations`) reference these on their `:clj` branch. They must resolve for
the namespace to load, but are never usefully callable under let-go.

**Fix (`pkg/rt/lang.go`):** compile-only stubs — an `enumeration-seq` fn and a
`clojure.lang.RT` bare-ns with a `baseLoader` marker — matching the existing
medley `java.util.ArrayList` load-only-stub precedent (they throw / return a
marker if actually invoked).

## G5 — `get-method` missing

integrant's top-level `(defn- can-expand-key? [k] (get-method expand-key …))`
references `get-method`, so an unresolved `get-method` blocked the **whole**
`integrant.core` namespace from loading — even though `get-method` is only used
by `expand`.

**Fix (`pkg/rt/lang.go`, `pkg/vm/multifn.go`):** a real `get-method` backed by a
new `MultiFn.GetMethod` — exact-value match, else the default method, else `nil`
(mirroring let-go's multimethod dispatch, which is exact + default, not isa?
hierarchy — sufficient for integrant).

## G6 — an empty catch body with a qualified class did not compile

integrant's `try-require` uses `(catch java.io.FileNotFoundException _)` — a catch
with **no body**. let-go's catch parser disambiguated the Clojure form
`(catch Class binding body…)` from the bare form `(catch binding body…)` by token
count (Clojure "always" has a body, so 3+ tokens), which misparsed the class as
the binding and left the binding as the body:

```
CompileError: Can't resolve _ in this context
```

**Fix (`pkg/compiler/compiler.go`):** a binding is always a simple unqualified
symbol, so a qualified/dotted first token is unambiguously the class name — key on
that so an empty catch body parses. Tests: `test/catch_class_test.lg`.

## What lgx does

- Both examples list `dependency` **and** `integrant` coords directly in
  `lgx.edn` — lgx does not yet resolve transitive deps of a plain Clojure lib.
- lgx exports `LG_READ_CLJ=1` on every spawn, so the `:clj` branches match.

## Verify against (in [nooga/let-go](https://github.com/nooga/let-go))

- `pkg/rt/core/core.lg` — `defrecord`, `-dt-rewrite*`, `-dt-rewrite-case` (G1)
- `pkg/vm/persistent_queue.go`, `pkg/rt/lang.go`, `pkg/rt/hierarchy.go` (G2)
- `pkg/rt/lang.go` — `find-var`, `enumeration-seq`, `clojure.lang.RT/baseLoader`,
  `get-method` (G3/G4/G5); `pkg/vm/multifn.go` — `MultiFn.GetMethod` (G5)
- `pkg/compiler/compiler.go` — `tryCompiler` catch parsing (G6)
