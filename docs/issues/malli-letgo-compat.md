# Issue: run metosin/malli under let-go

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** implemented on the local `with-malli` branch

## Summary

Making [`metosin/malli`](https://github.com/metosin/malli) 0.20.1 load and run
under let-go (via lgx) surfaced a set of JVM/Clojure-compat gaps across three
areas: core validation, the sequence/regex schema engine, and string coercion.
malli is a large, JVM-heavy library; the load chain is

```
malli.impl.util -> malli.impl.regex -> malli.registry -> borkdude.dynaload
-> malli.sci -> malli.core -> {malli.util, malli.error, malli.transform}
```

Every gap was found by running malli under a locally-built `lg`, reading the
first error, fixing, and re-running until all four namespaces load **and** a
functional smoke (validate/explain/humanize/`:cat`/decode) passes — `require`
swallows load failures, so namespace presence never proves anything. Each fix is
additive, general (framed as a let-go improvement, malli as motivation), and
ships with a test; `make test` stays green.

Worked repro lives in lgx:

```
LGX_LG=/path/to/let-go/lg lgx run examples/clojure-libs/with-malli/main.lg
```

Deps: `metosin/malli 0.20.1` + `borkdude/dynaload v0.3.5` (edamame is a malli dep
but only `malli.edn` uses it — not needed here). lgx has no transitive resolution
for plain Clojure libs, so the example lists both directly.

## Tier A — core: validate / explain / humanize / malli.util

- **A2 — mutable `java.util.HashMap` (critical path).** `malli.registry/fast-registry`
  builds `(doto (HashMap. 1024 0.25) (.putAll m))` and reads it via `(.get fm type)`;
  `default-registry` builds it at load and **every schema-type lookup** goes through
  `.get`, so nothing validates without it.
  **Fix (`pkg/rt/host_hashmap.go`):** a real mutable Receiver type with a dedicated
  `java.util.HashMap` ValueType, `.putAll`/`.get`, and the `(HashMap. …)` ctor forms.

- **A5 — JVM collection-interface interop.** `.valAt` (ILookup, map validator),
  `.iterator`/`.hasNext`/`.next` (Iterable, `malli.impl.util/-vmap`), `.assoc`/
  `.cons`/`.nth`/`.count`, and `.hashCode`/`.longValue` (regex cache keys) on let-go
  collections raised `method-invoke expected Receiver`.
  **Fix (`pkg/rt/host_iterator.go` + `invokeMethodFallback` in `lang.go`):** a
  generic handler dispatched on the value's let-go interface (`Lookup`/`Sequable`/
  `Associative`/`Collection`/`Indexed`/`Counted`), plus a `seqIterator` Receiver for
  `.iterator`. Placed after registered host-methods (so those win) and before the
  name→fn fallbacks (so `.cons` = append, not core `cons` = prepend). General, not
  malli-specific.

- **A1/A3/A4 — vector/map builder statics.** `LazilyPersistentVector/createOwning`,
  `System/arraycopy`, `PersistentArrayMap/createWithCheck` are used in
  `-eager-entry-parser` (map-schema construction) and `-vmap`.
  **Fix:** `createOwning` = `vec`; `arraycopy` = real element copy
  (`pkg/rt/system.go`); `createWithCheck` folds a flat object array into a map,
  throwing on a duplicate key (malli catches it → `::duplicate-keys`).

- **A6 — `clojure.lang.IDeref`/`IFn` in `deftype`.** `borkdude.dynaload`'s `LazyVar`
  deftype implements them; the deftype macro's `register-type-parent!`/`extend-type*`
  need real `*vm.Protocol` values.
  **Fix:** register fresh Go Protocols. `LazyVar` compiles; it is only built on the
  (unused) sci-eval path and fails loudly if ever deref'd/called.

- **A7/A8 — missing fns.** `monitor-enter`/`monitor-exit` (dynaload `locking2`) →
  no-ops; `indexed?` (→ `vm.Indexed` check), `class` (→ alias of `type`), `uri?`
  (→ always false; let-go has no `java.net.URI`).

- **A9 — host-class markers** for `(instance? Class x)`: `java.util.Map`→`vm.MapType`
  (what map literals evaluate to), `CharSequence`→`vm.StringType`, bare `Pattern`→
  `vm.RegexType`, `java.util.AbstractList`/`Vector` → markers.

## Tier B — sequence / regex schemas (`:cat` `:*` `:+` `:?` `:repeat`)

The `malli.impl.regex` CPS engine uses a mutable backtracking stack and a custom
open-addressing hash cache.

- **B1 — mutable `java.util.ArrayDeque`.** `make-stack` + the drivers' backtracking
  stack use `.push`/`.pop`/`.peek`/`.isEmpty`.
  **Fix (`pkg/rt/host_arraydeque.go`):** a real LIFO Receiver type + ctor.

- **B2 — regex cache statics.** `Array/newInstance` → object-array; `Util/hash` +
  `Murmur3/hashLong` → let-go `hash`; `Util/hashCombine` → the standard combine.
  A weak hash is still correct here — the cache also compares candidate keys with
  `=`, so collisions only cost time. (`.hashCode`/`.longValue` handled in A5.)

## Tier C — string coercion (`m/decode` via `malli.transform`)

- **C1/C2 — parse statics.** `Long/parseLong`, `Integer/parseInt`, `Float/parseFloat`,
  `Double/parseDouble` (real, via Go `strconv`); bare `UUID/fromString` (reuses
  `vm.ParseUUID`).

- **C3 — java.time load-time construction.** `malli.transform` builds
  `DateTimeFormatter`s at **load time** by method chaining
  (`(-> (DateTimeFormatterBuilder.) (.appendPattern …) … (.toFormatter))`).
  **Fix:** a chainable stub whose builder methods return self (so the chain threads)
  but whose `.parse`/`.format` throw; `ChronoField/*` as markers. malli's own
  try/catch turns runtime date coercion into a pass-through.

## Degraded by design (loud stubs / pass-through)

- Date / decimal / URI coercion (`BigDecimal.`/`URI.`/java.time `.parse`/`.format`):
  loud stubs; malli's try/catch returns the input unchanged.
- The `malli.impl.util/-run` bounded-execution timeout helper (`FutureTask.`/
  `Thread.`/`TimeUnit/MILLISECONDS`): load-only loud stubs — only the rare timeout
  path hits them.
- `borkdude.dynaload` `LazyVar` deref/invoke (sci-eval): the example doesn't use
  string-form schema eval.

## Non-obvious details

- Static-holder namespaces (`Util`, `Long`, …) are created **without** an auto-refer
  to `clojure.core` (`defStaticNS`), so defining `Util/hash` does not print a
  `WARNING: hash already refers to clojure.core/hash` at every `lg` startup.
- `System/arraycopy` lives in `pkg/rt/system.go` beside `System/getProperty`
  (`System` is its own namespace, not part of `installClojureCompatAliases`).

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go), `with-malli`):**
> [`pkg/rt/host_hashmap.go`](https://github.com/nooga/let-go), `host_arraydeque.go`,
> `host_iterator.go`, `host_malli_compat.go`,
> [`pkg/rt/lang.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/lang.go)
> (`invokeMethodFallback`, `installClojureCompatAliases`),
> [`pkg/rt/system.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/system.go)
> (`System/arraycopy`), and `test/malli_compat_test.go`.
