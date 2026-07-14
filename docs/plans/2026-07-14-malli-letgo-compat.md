# malli let-go compatibility Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `metosin/malli` 0.20.1 load and run under let-go, driven through lgx — closing a set of JVM/Clojure-compat gaps in let-go upstream (core validation + sequence/regex schemas + string coercion) and adding a worked `with-malli` example.

**Tech Stack:** let-go (Go VM + `.lg` stdlib in `/Users/andrew/Projects/let-go`), lgx (this repo), Clojure `.cljc` libraries (`metosin/malli` 0.20.1, `borkdude/dynaload` v0.3.5).

---

## Design

### Context

malli is a large, JVM-heavy schema library. The example exercises four namespaces
and their transitive load chain:

```
malli.impl.util -> malli.impl.regex -> malli.registry -> borkdude.dynaload
-> malli.sci -> malli.core -> {malli.util, malli.error, malli.transform}
```

Deps to pin in the example: `metosin/malli 0.20.1` + `borkdude/dynaload v0.3.5`.
`borkdude/edamame` is a malli dep but is **not** needed — only `malli.edn` uses
it, which the example doesn't. lgx has no transitive resolution for plain Clojure
libs, so `lgx.edn` lists both deps directly.

Under `LG_READ_CLJ=1` (which lgx exports on every spawn) let-go already resolves
`.clj`/`.cljc` and matches `:clj` reader-conditional branches, so malli is
*reachable*. The whole surface below was found empirically by running malli under
a locally-built `lg`, reading the first error, fixing, and re-running until all
four namespaces load **and** a functional smoke (validate/explain/humanize/`:cat`/
`decode`) passes. A complete **working throwaway** proving every fix lives at
`pkg/rt/malli_throwaway.go` in the let-go tree (also copied to this repo's plan
context at `scratchpad/reference/malli_throwaway.go` during planning) plus two
hooks (`installClojureCompatAliases` call + `invokeMethodFallback` block in
`pkg/rt/lang.go`; `System/arraycopy` in `pkg/rt/system.go`). **This plan
productionizes the throwaway and deletes it.**

**Already present in let-go** (verified — do not re-add): `(Foo. …)`→`(->Foo …)`
desugar, `deftype`/`defrecord` with mutable fields + `set!` + protocol impls,
`reify`, `defprotocol`, `extend-type*`/`register-type-parent!`, `instance?` with
host-class markers via `RegisterHostClass`, the `.`-form host-method fallback
(`invokeMethodFallback` + `hostMethods`), `System/getProperty`, `Long/MAX_VALUE`,
`clojure.lang.MapEntry.`, `java.util.UUID/fromString` (fully-qualified only),
`java.util.regex.Pattern` (fully-qualified only), `object-array`/`aget`/`aset`,
`clojure.math`, `hash`, `seq`, `vec`, `type`.

### The gaps (grouped by what they unlock)

Static-method calls (`Class/method`) and constructors (`(Class. …)`→`->Class`)
must **resolve at compile time** or the namespace fails to compile; a `.method`
call on a value dispatches at runtime via `invokeMethodFallback`. `require`
**silently swallows** load failures, so "loaded" is never proof — every gap below
was confirmed by a functional smoke, not by namespace presence.

#### Tier A — core: validate / explain / humanize / `malli.util`

- **A1 — `clojure.lang.LazilyPersistentVector/createOwning` (static).**
  `impl/util.cljc:30`, `core.cljc:548` build a vector from an object array.
  **Fix:** register a `LazilyPersistentVector` ns (bare + `clojure.lang.`
  qualified) with `createOwning` = the `vec` builtin. Real.

- **A2 — `java.util.HashMap` ctor + `.putAll` + `.get`. CRITICAL PATH.**
  `registry.cljc:18` `fast-registry` does `(doto (HashMap. 1024 0.25) (.putAll m))`
  then `(.get fm type)`. `default-registry` builds this at load and **every
  schema-type lookup goes through `.get`** — nothing validates without it.
  **Fix:** a real, mutable HashMap value type (Receiver) with a dedicated
  `ValueType`. `(HashMap. n f)`→`->HashMap`; `.putAll m` stores the map; `.get k`
  = `ValueAt`.

- **A3 — `System/arraycopy(src sPos dst dPos len)`.** `core.cljc:558`
  `-eager-entry-parser` (map-schema construction). **Fix:** real element copy over
  `*vm.TypedArray`, added to `pkg/rt/system.go`.

- **A4 — `clojure.lang.PersistentArrayMap/createWithCheck(arr)`.** `core.cljc:552`
  `-eager-entry-parser` builds a map from a flat `[k v k v]` object array, throwing
  on duplicate keys (malli catches → `::duplicate-keys`). **Fix:** register a
  `PersistentArrayMap` ns (bare + qualified) `createWithCheck`: fold pairs into a
  PersistentMap, error on a dup key. Real.

- **A5 — JVM collection-interface interop on let-go collections.** `.valAt`
  (ILookup — `core.cljc:632,1285` map validator), `.iterator`+`.hasNext`+`.next`
  (Iterable/Iterator — `impl/util.cljc` `-vmap`, pervasive), `.assoc`, `.cons`,
  `.nth`, `.count` (collection transformers `core.cljc:634,644-647`), and
  `.hashCode`/`.longValue` (regex Cache keys — see B2). **Fix:** handle these
  generically in `invokeMethodFallback`, dispatching on `vm` interfaces
  (`Lookup`/`Sequable`/`Associative`/`Collection`/`Indexed`/`Counted`), not
  per-type registration. `.iterator` returns a dedicated `seqIterator` Receiver
  over the value's `seq`.

- **A6 — `clojure.lang.IDeref` / `clojure.lang.IFn` unresolved in `deftype`.**
  `borkdude/dynaload.cljc:76` `LazyVar` `deftype` implements them; the macro emits
  `register-type-parent!` + `extend-type*`, which need real `*vm.Protocol` values
  (`extend-type*` rejects non-Protocols; it does **not** validate method names).
  **Fix:** register two fresh Go Protocols named `clojure.lang.IDeref` /
  `clojure.lang.IFn`. LazyVar then compiles; it is only instantiated on the
  sci-eval path malli's headline never hits, and fails loudly (no `-deref`/
  `-invoke` registered) if ever used.

- **A7 — `monitor-enter` / `monitor-exit`.** `dynaload.cljc` `locking2` macro
  (expanded in `resolve*`, runtime-only, non-headline). **Fix:** no-op builtins
  (let-go has no monitors).

- **A8 — Missing stdlib fns: `indexed?`, `class`, `uri?`.** `core.cljc` predicate
  registry + `-safely-countable?`. **Fix:** `indexed?` → true iff the value
  implements `vm.Indexed` (real); `class` → alias of `type` (real); `uri?` →
  always `false` (let-go has no `java.net.URI` type). General stdlib additions.

- **A9 — Host-class markers for `(instance? Class x)`.** `core.cljc:1468`
  `-safely-countable?`, `core.cljc:2943` `class-schemas`. **Fix:**
  `RegisterHostClass`: `java.util.Map`→`vm.PersistentMapType`,
  `CharSequence`→`vm.StringType`, **bare** `Pattern`→`vm.RegexType`,
  `java.util.AbstractList`/`java.util.Vector`→symbol markers.

#### Tier B — sequence / regex schemas (`:cat` `:*` `:+` `:?` `:repeat`)

The `malli.impl.regex` CPS engine uses a mutable backtracking stack and a custom
open-addressing hash cache.

- **B1 — `java.util.ArrayDeque` ctor + `.push`/`.pop`/`.peek`/`.isEmpty`.**
  `impl/regex.cljc:462` `make-stack` + the drivers. **Fix:** a real, mutable LIFO
  deque value type (Receiver, slice-backed, dedicated `ValueType`).

- **B2 — Regex `Cache` statics.** `impl/regex.cljc:484,509`:
  `java.lang.reflect.Array/newInstance`→object-array (real);
  `clojure.lang.Util/hash` and `clojure.lang.Murmur3/hashLong`→ the `hash` builtin;
  `clojure.lang.Util/hashCombine`→ the standard Clojure combine; interop
  `.hashCode`→ `hash` (weak/constant is correct — the cache also compares keys with
  `=`, so collisions only cost time), `.longValue`→ identity on `Int` (both handled
  in the A5 fallback).

#### Tier C — string coercion (`m/decode` via `malli.transform`)

`malli.transform` builds `DateTimeFormatter`s at **load time** by method chaining,
so the java.time stubs must be chainable even though date coercion stays degraded.

- **C1 — `Long/parseLong`, `Float/parseFloat`, `Double/parseDouble`,
  `Integer/parseInt`.** `transform.cljc:62,76,88`. **Fix:** real, via Go `strconv`,
  added to the existing `Long`/`Float`/`Double`/`Integer` namespaces.

- **C2 — bare `UUID/fromString`.** `transform.cljc:121`. **Fix:** alias a bare
  `UUID` ns to a `fromString` reusing `vm.ParseUUID` (the fully-qualified
  `java.util.UUID/fromString` already exists). Real — string→uuid works.

- **C3 — java.time load-time construction.** `transform.cljc:138-190`:
  `DateTimeFormatterBuilder.` ctor, `DateTimeFormatter/ofPattern`, `ZoneId/of`,
  `ChronoField/{MICRO_OF_SECOND,HOUR_OF_DAY,OFFSET_SECONDS}`, and runtime
  `Date/from`/`Instant/from`/`Instant/ofEpochMilli`. **Fix:** a **chainable stub**
  whose builder methods return self (so the load-time `->` chain threads) but whose
  `.parse`/`.format` throw; `ChronoField/*` as markers. malli's own try/catch turns
  runtime date coercion into a pass-through (degraded by design).

- **C4 — `BigDecimal.`, `URI.` ctors.** `transform.cljc:130,164`. **Fix:**
  load-only loud stubs (decimal/URI coercion pass through via malli's try/catch).

### Approach & decisions (locked with user)

- **Scope = core + sequences + string coercion.** All schema kinds validate/
  explain/humanize, the full `:cat`/`:*`/`:+`/`:repeat` engine works, and
  `m/decode` string coercion works. Date/decimal/URI coercion and the
  `-run` timeout helper stay degraded (loud stubs; malli's try/catch or
  non-headline paths absorb them).
- **All fixes land in Go** (`pkg/rt`, `pkg/vm`, `pkg/rt/system.go`) — **no
  `pkg/rt/core/*.lg` changes, so no bundle regen.** `indexed?`/`class`/`uri?`/
  `monitor-enter`/`monitor-exit` are thin Go builtins.
- **HashMap & ArrayDeque are real mutable Receiver types with dedicated
  `ValueType`s, in the `pkg/rt` compat layer** (not `pkg/vm`). Unlike
  `PersistentQueue` (a genuine persistent Clojure value), these are mutable JVM
  shims malli uses internally; dedicated types (not `vm.AnyType`) keep `(type x)`
  and error messages honest and stop them satisfying `instance? Object`.
- **JVM collection-interface interop is generic, in `invokeMethodFallback`** (not
  the per-type `register-host-method!` seam): these are universal interfaces every
  let-go collection implements, so interface-dispatch is DRY and general (the
  fallback already handles `reduce` this way). Zero malli-specific references.
- **`clojure.lang.IDeref`/`IFn` = fresh Go Protocols** — accepted that LazyVar is
  compile-only/degraded (sci-eval path unused by the example).
- **Two-repo change.** Runtime fixes land in `/Users/andrew/Projects/let-go`;
  the example + knowledge-base/issues docs land in this repo. After any Go change,
  rebuild `lg` (`make build` in the let-go repo) before running examples.

### Testing strategy

- **let-go Go unit tests** (`go test ./...`): a focused test file per new
  primitive — HashMap put/get, ArrayDeque LIFO (push/pop/peek/isEmpty),
  `seqIterator`, `createWithCheck` (incl. the dup-key error), `arraycopy`, the
  parse fns — mirroring the style of `pkg/vm/persistent_queue_test.go` and
  `test/*_compat_test.go`.
- **let-go `.lg`-level tests** (`go test ./test/...` auto-discovers `test/*.lg`):
  smallest forms exercising the interop and stdlib fns — `.valAt`/`.iterator` on a
  vector and a map, `(indexed? [])`/`(indexed? 1)`, `(class 1)`, `(uri? "x")`,
  `(Long/parseLong "5")`, `(instance? java.util.Map {})`.
- **End-to-end** (this repo): the `with-malli` example is run two ways — directly
  (`LG_READ_CLJ=1 lg -source-paths <srcs> main.lg`) for a fast loop, and faithfully
  through lgx (`LGX_LG=<lg> lgx run main.lg`). Output must match and show the
  headline features actually working.
- **Full-load gate:** `LG_READ_CLJ=1 lg -source-paths "<malli>/src:<dynaload>/src"
  -e "(require '[malli.core] '[malli.error] '[malli.util] '[malli.transform])
  (println :ALL-LOADED)"` prints `:ALL-LOADED` with no `failed to load` on stderr.
- Keep `make test` green in both repos.

### Error handling

Degraded-by-design surfaces fail **loudly** (throw) rather than returning
plausible-but-wrong values: `FutureTask.`/`Thread.` (the `-run` timeout helper),
`BigDecimal.`/`URI.`, and the java.time formatter's `.parse`/`.format` all throw if
called; malli's own try/catch turns date/decimal/URI coercion into a pass-through.
`uri?` returns `false` (matching "no URI exists"). HashMap/ArrayDeque/parse fns/
`arraycopy`/`createWithCheck` are real, correct implementations.

## File Structure

**let-go repo (`/Users/andrew/Projects/let-go`):**

- Create `pkg/rt/host_hashmap.go` — the mutable `HashMap` compat value type +
  `ValueType` (A2).
- Create `pkg/rt/host_arraydeque.go` — the mutable `ArrayDeque` compat value type
  + `ValueType` (B1).
- Create `pkg/rt/host_iterator.go` — the `seqIterator` Receiver + the generic
  `mtwInterop`-equivalent helper for the `.`-fallback (A5/B2). (Or fold the helper
  into `lang.go` beside `invokeMethodFallback`; keep the iterator type here.)
- Modify `pkg/rt/lang.go` — (a) add the generic JVM-collection-interface block to
  `invokeMethodFallback` (A5/B2); (b) in `installClojureCompatAliases`, register
  the static methods, ctors, host-class markers, and java.time stubs
  (A1/A4/A6/A9/B2/C1–C4); (c) add `indexed?`/`class`/`uri?`/`monitor-enter`/
  `monitor-exit` builtins (A7/A8). Remove the throwaway hook call.
- Modify `pkg/rt/system.go` — `System/arraycopy` (A3).
- Delete `pkg/rt/malli_throwaway.go`.
- Create tests: `pkg/rt/host_hashmap_test.go`, `pkg/rt/host_arraydeque_test.go`,
  `pkg/rt/host_iterator_test.go`, and `test/malli_compat_test.lg` (interop +
  stdlib forms).

**lgx repo (this repo):**

- Create `examples/clojure-libs/with-malli/lgx.edn` — `:main`, `:targets`, both
  deps pinned.
- Create `examples/clojure-libs/with-malli/main.lg` — headline demo.
- Modify `docs/knowledge-base/let-go-stdlib-quick-ref.md` — new fns/behaviors.
- Create `docs/issues/malli-letgo-compat.md` — repro + fix + status note.
- Modify `README.md` — add malli to the supported-libs list (mirror the other
  `with-*` entries).

---

## Task 1: HashMap real value type (A2 — critical path)

**Files:**
- Create: `/Users/andrew/Projects/let-go/pkg/rt/host_hashmap.go`
- Test: `/Users/andrew/Projects/let-go/pkg/rt/host_hashmap_test.go`

- [ ] **Step 1: Write the failing test.** In `host_hashmap_test.go`, construct a
  HashMap value, `.putAll` a `vm.PersistentMap`, assert `.get` returns stored
  values and `vm.NIL` for absent keys, and assert `Type().Name()` is a distinct
  name (not `java.lang.Object`).
- [ ] **Step 2: Run to verify it fails.** Run: `cd /Users/andrew/Projects/let-go && go test ./pkg/rt/ -run HashMap`. Expected: FAIL (undefined type).
- [ ] **Step 3: Implement.** Port `hashMapCompat` from the throwaway into a proper
  type with a dedicated `theHashMapType` `ValueType` (Name `"java.util.HashMap"`),
  `Receiver` with `putAll`/`get` (and `size`/`containsKey` if trivial). Keep it in
  `pkg/rt`.
- [ ] **Step 4: Run to verify it passes.** Run: `go test ./pkg/rt/ -run HashMap`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add mutable HashMap host-compat type for let-go interop"`

## Task 2: ArrayDeque real value type (B1)

**Files:**
- Create: `/Users/andrew/Projects/let-go/pkg/rt/host_arraydeque.go`
- Test: `/Users/andrew/Projects/let-go/pkg/rt/host_arraydeque_test.go`

- [ ] **Step 1: Write the failing test.** Assert LIFO: push 1,2,3 → peek 3 →
  pop 3 → pop 2 → isEmpty false → pop 1 → isEmpty true; pop on empty errors.
- [ ] **Step 2: Run to verify it fails.** Run: `go test ./pkg/rt/ -run ArrayDeque`. Expected: FAIL.
- [ ] **Step 3: Implement.** Port `arrayDeque` from the throwaway into a proper
  type with a dedicated `theArrayDequeType` `ValueType` (Name `"java.util.ArrayDeque"`),
  `Receiver` with `push`/`pop`/`peek`/`isEmpty`/`size`.
- [ ] **Step 4: Run to verify it passes.** Run: `go test ./pkg/rt/ -run ArrayDeque`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add mutable ArrayDeque host-compat type for let-go interop"`

## Task 3: Generic JVM collection-interface interop (A5 + B2 interop)

**Files:**
- Create: `/Users/andrew/Projects/let-go/pkg/rt/host_iterator.go`
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go` (`invokeMethodFallback`)
- Test: `/Users/andrew/Projects/let-go/pkg/rt/host_iterator_test.go`, `/Users/andrew/Projects/let-go/test/malli_compat_test.lg`

- [ ] **Step 1: Write the failing tests.** Go test: `seqIterator` over a vector
  yields elements then `hasNext`→false. `.lg` test (`test/malli_compat_test.lg`):
  `(.valAt {:a 1} :a)`→1, `(.valAt {:a 1} :b :nf)`→`:nf`, `(.nth [10 20] 1)`→20,
  `(.count [1 2 3])`→3, and iterating `(.iterator [1 2])` via `.hasNext`/`.next`.
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./pkg/rt/ ./test/ -run 'Iterator|Malli'`. Expected: FAIL (`method-invoke expected Receiver`).
- [ ] **Step 3: Implement.** Add `seqIterator` (Receiver over a normalized seq;
  `hasNext`/`next`) in `host_iterator.go`, plus a helper `hostCollectionMethod(rec,
  name, args) (Value, bool, error)` mapping `valAt`→`Lookup.ValueAt/ValueAtOr`,
  `iterator`→`seqIterator`, `assoc`→`Associative.Assoc`, `cons`→`Collection.Conj`,
  `nth`→`Indexed.Nth`, `count`→`Counted.Count`, `hashCode`→`hash`,
  `longValue`→identity. Call it near the top of `invokeMethodFallback`, returning
  when handled. Normalize seqs to `NIL`-when-empty using the `seq` builtin.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./pkg/rt/ ./test/ -run 'Iterator|Malli'`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Support JVM collection-interface interop (.valAt/.iterator/.assoc/...) on let-go collections"`

## Task 4: Static methods — vector/map builders + regex hash (A1, A3, A4, B2 statics)

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go` (`installClojureCompatAliases`)
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/system.go` (`installSystemNS`)
- Test: `/Users/andrew/Projects/let-go/test/malli_compat_test.lg`

- [ ] **Step 1: Write the failing tests.** `.lg`: `(LazilyPersistentVector/createOwning
  (object-array 0))`→`[]`; `(clojure.lang.PersistentArrayMap/createWithCheck
  (object-array-of :a 1 :b 2))`→`{:a 1 :b 2}` and dup keys throw; a `System/arraycopy`
  round-trip; `(Array/newInstance Object 3)` returns a 3-element array;
  `(Util/hashCombine 1 2)` returns an int.
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./test/ -run Malli`. Expected: FAIL.
- [ ] **Step 3: Implement.** Port from the throwaway: `LazilyPersistentVector/createOwning`
  (=`vec`), `PersistentArrayMap/createWithCheck` (fold pairs → PersistentMap, error on
  dup), `Array/newInstance` (→`object-array`), `Util/hash`+`Murmur3/hashLong` (=`hash`),
  `Util/hashCombine` (standard combine). Add `System/arraycopy` to `system.go`. Register
  bare + `clojure.lang.` names where malli uses bare (imported).
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./test/ -run Malli`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add createOwning/createWithCheck/arraycopy/Array-newInstance/Util-hash statics"`

## Task 5: Missing stdlib fns + host-class markers + dynaload protocols (A6, A7, A8, A9)

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Test: `/Users/andrew/Projects/let-go/test/malli_compat_test.lg`

- [ ] **Step 1: Write the failing tests.** `.lg`: `(indexed? [1])`→true,
  `(indexed? {})`→false, `(class 1)` returns a type, `(uri? "x")`→false,
  `(instance? java.util.Map {})`→true, `(instance? CharSequence "s")`→true,
  `(instance? Pattern #"x")`→true, `(monitor-enter :x)`→nil.
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./test/ -run Malli`. Expected: FAIL.
- [ ] **Step 3: Implement.** Add `indexed?` (`vm.Indexed` check), `class`
  (alias of `type`), `uri?` (constant false), `monitor-enter`/`monitor-exit`
  (no-ops) as builtins. `RegisterHostClass` for `java.util.Map`→`PersistentMapType`,
  `CharSequence`→`StringType`, bare `Pattern`→`RegexType`,
  `java.util.AbstractList`/`java.util.Vector`→markers. Register fresh Go Protocols
  `clojure.lang.IDeref` / `clojure.lang.IFn` so dynaload's `LazyVar` deftype
  compiles.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./test/ -run Malli`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add indexed?/class/uri?/monitor-enter, host-class markers, clojure.lang.IDeref/IFn protocols"`

## Task 6: malli.transform statics — string coercion + java.time stubs (C1–C4)

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Test: `/Users/andrew/Projects/let-go/test/malli_compat_test.lg`

- [ ] **Step 1: Write the failing tests.** `.lg`: `(Long/parseLong "42")`→42,
  `(Float/parseFloat "3.5")`→3.5, `(Double/parseDouble "3.5")`→3.5,
  `(UUID/fromString "00000000-0000-0000-0000-000000000000")` returns a uuid,
  `(-> (DateTimeFormatterBuilder.) (.appendPattern "x") (.toFormatter))` returns a
  value (chain threads).
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./test/ -run Malli`. Expected: FAIL.
- [ ] **Step 3: Implement.** Real `Long/parseLong`/`Integer/parseInt`/
  `Float/parseFloat`/`Double/parseDouble` (Go `strconv`) on the existing
  `Long`/`Integer`/`Float`/`Double` namespaces; bare `UUID/fromString`
  (`vm.ParseUUID`); a chainable java.time stub (builder methods → self;
  `.parse`/`.format` → throw) bound to `DateTimeFormatterBuilder.`,
  `DateTimeFormatter/ofPattern`, `ZoneId/of`, `Date`/`Instant`; `ChronoField/*`
  markers; `BigDecimal.`/`URI.` loud stubs.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./test/ -run Malli`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add malli.transform coercion statics (parse fns, UUID, java.time chainable stubs)"`

## Task 7: Remove throwaway, rebuild, gate full malli load

**Files:**
- Delete: `/Users/andrew/Projects/let-go/pkg/rt/malli_throwaway.go`
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go` (remove the throwaway hook call)

- [ ] **Step 1: Delete the throwaway** and its `installMalliThrowaway(ns)` call in
  `installClojureCompatAliases`. Confirm no other reference remains
  (`grep -rn "malliThrowaway\|installMalliThrowaway\|mtw" pkg/`).
- [ ] **Step 2: Build.** Run: `cd /Users/andrew/Projects/let-go && make build`. Expected: builds clean.
- [ ] **Step 3: Full test suite.** Run: `go test ./...`. Expected: PASS.
- [ ] **Step 4: Full-load gate + smoke.** Fetch malli 0.20.1 + dynaload v0.3.5
  sources, then run the `:ALL-LOADED` gate and the three smoke scripts
  (`scratchpad/malli_full.lg`, `malli_seq.lg`, `malli_tx.lg`) via
  `LG_READ_CLJ=1 lg -source-paths "<malli>/src:<dynaload>/src" <script>`.
  Expected: `:ALL-LOADED` with no `failed to load`; every smoke line shows the
  feature working (no `ERR:`), matching the recorded reference output.
- [ ] **Step 5: Commit.** `git commit -m "Remove malli discovery throwaway; gate full malli load"`

## Task 8: lgx `with-malli` example

**Files:**
- Create: `examples/clojure-libs/with-malli/lgx.edn`
- Create: `examples/clojure-libs/with-malli/main.lg`

- [ ] **Step 1: Write `lgx.edn`.** Mirror `with-integrant/lgx.edn`: `:main "main.lg"`,
  `:targets {:bin {:out "bin/with-lib"}}`, `:deps` listing `metosin/malli`
  (`:git/tag "0.20.1"`) and `borkdude/dynaload` (`:git/tag "v0.3.5"`) directly, with
  a comment that lgx doesn't resolve transitive deps.
- [ ] **Step 2: Write `main.lg`.** `(ns main (:require [malli.core :as m] [malli.error
  :as me] [malli.util :as mu] [malli.transform :as mt]))`, a small labeled-output
  helper, then exercise the headline features on real input, in the neighbors' voice
  with comments naming each feature: schema definition + `validate`; `explain` +
  `me/humanize`; the schema zoo (`:map`/`:vector`/`:set`/`:map-of`/`:enum`/`:maybe`/
  `:and`/`:or`/closed maps); the sequence engine (`:cat`/`:*`/`:+`/`:repeat` validate
  + `m/parse`); `malli.util` (`merge`/`select-keys`/`optional-keys`); and string
  coercion (`m/decode` with `mt/string-transformer` over ints/keywords/a map). No
  top-level side effects that need `*compiling-aot*` guarding beyond the demo prints
  (there is no `-main`).
- [ ] **Step 3: Commit.** `git commit -m "Add with-malli example"`

## Task 9: Verify the example end-to-end (both ways)

- [ ] **Step 1: Direct run.** Run: `LG_READ_CLJ=1 <lg> -source-paths "<malli>/src:<dynaload>/src" examples/clojure-libs/with-malli/main.lg`. Expected: every headline section prints working output, no `error:`/`ERR:`.
- [ ] **Step 2: Through lgx.** Build lgx if needed (`make build`), then
  `cd examples/clojure-libs/with-malli && LGX_LG=<lg> <lgx-bin> run main.lg`.
  Expected: lgx auto-installs deps, sets `LG_READ_CLJ`, and output matches Step 1.
- [ ] **Step 3: Commit** (only if the example needed adjustment). `git commit -m "Polish with-malli example after end-to-end verification"`

## Task 10: Docs

**Files:**
- Modify: `docs/knowledge-base/let-go-stdlib-quick-ref.md`
- Create: `docs/issues/malli-letgo-compat.md`
- Modify: `README.md`

- [ ] **Step 1: Quick-ref.** Add the new fns/behaviors (`indexed?`, `class`, `uri?`,
  `Long/parseLong` & friends, the collection-interface interop, HashMap/ArrayDeque,
  the host-class markers) in the file's existing style; keep its `Verify against:`
  footer accurate.
- [ ] **Step 2: Issues note.** Write `docs/issues/malli-letgo-compat.md` in the
  style of `docs/issues/integrant-dependency-compat.md` / `clojure-lib-compat.md`:
  per-gap minimal repro, the exact error, the fix, and status; plus the
  degraded-by-design list (date/decimal/URI coercion, `-run`, LazyVar).
- [ ] **Step 3: README.** Add malli to the supported-libs list mirroring the other
  `with-*` entries.
- [ ] **Step 4: Commit.** `git commit -m "Document malli let-go compatibility"`
