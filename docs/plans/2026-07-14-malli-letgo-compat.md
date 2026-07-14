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
`/Users/andrew/Projects/let-go/pkg/rt/malli_throwaway.go` in the let-go tree, plus
two hooks (`installClojureCompatAliases` call + `invokeMethodFallback` block in
`pkg/rt/lang.go`; `System/arraycopy` in `pkg/rt/system.go`). **This plan
productionizes the throwaway and deletes it** (Task 1 resets, Tasks 2–6 rebuild real).

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

- **Scope = core + sequences + string coercion.** A representative schema across
  every category validates/explains/humanizes — scalars/predicates, `:map`
  (incl. `{:closed true}`), `:vector`/`:set`/`:map-of`, `:enum`/`:maybe`/`:and`/
  `:or`/`:re`, and the full `:cat`/`:*`/`:+`/`:?`/`:repeat` sequence engine — and
  `m/decode` string coercion works. This is the acceptance boundary: the smoke in
  Task 7 and the example in Task 8 enumerate exactly these; "every schema kind" is
  not a blanket guarantee beyond them. Date/decimal/URI coercion and the `-run`
  timeout helper stay degraded (loud stubs; malli's try/catch or non-headline
  paths absorb them).
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

- **let-go Go unit tests** for the pure Go type behavior of the two new value
  types — `pkg/rt/host_hashmap_test.go` (put/get) and
  `pkg/rt/host_arraydeque_test.go` (LIFO push/pop/peek/isEmpty) — constructing the
  type and calling `InvokeMethod` directly (no compiler). Run: `go test ./pkg/rt/
  -run 'HashMap|ArrayDeque'`.
- **let-go eval-level compat tests** in `test/malli_compat_test.go`, mirroring
  `test/medley_compat_test.go`: a package-`test` file with an `evalMalli(expr)`
  helper (compile+eval a string against the core NS, like `evalMedley`) and a
  `TestMalliCompat` function whose `t.Run` subtests exercise every gap's smallest
  form — `.valAt`/`.iterator`/`.nth`/`.count` on real collections, `(indexed? [])`
  /`(indexed? 1)`, `(class 1)`, `(uri? "x")`, `(instance? java.util.Map {})`,
  `(Long/parseLong "5")`, `createWithCheck`, `arraycopy`, HashMap/ArrayDeque via
  their ctor forms, the dynaload-protocol resolution, and the java.time chain.
  Run: `go test ./test/ -run TestMalliCompat`. **NB:** the `.lg` files in `test/`
  are subtests of the top-level `TestRunner`, which a `-run TestMalliCompat`/`-run
  Malli` filter *excludes* — so compat forms go in the Go test, not a `.lg` file.
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
- Create tests: `pkg/rt/host_hashmap_test.go` + `pkg/rt/host_arraydeque_test.go`
  (pure Go type behavior), and `test/malli_compat_test.go` (package `test`, an
  `evalMalli` helper + `TestMalliCompat` eval-level subtests for interop / statics
  / stdlib / host-class markers / transform — mirroring `test/medley_compat_test.go`).

**lgx repo (this repo):**

- Create `examples/clojure-libs/with-malli/lgx.edn` — `:main`, `:targets`, both
  deps pinned.
- Create `examples/clojure-libs/with-malli/main.lg` — headline demo.
- Modify `docs/knowledge-base/let-go-stdlib-quick-ref.md` — new fns/behaviors.
- Create `docs/issues/malli-letgo-compat.md` — repro + fix + status note.
- Modify `README.md` — add malli to the supported-libs list (mirror the other
  `with-*` entries).

---

> **Build model for the implementation tasks (1–7).** Task 1 first **resets the
> tree to a clean baseline**: delete `pkg/rt/malli_throwaway.go` and remove its two
> hook sites in `lang.go` — the `installMalliThrowaway(ns)` call in
> `installClojureCompatAliases` and the `mtwInterop(...)` block in
> `invokeMethodFallback` — in the same change (deleting the file without removing
> the `mtwInterop` call would fail to compile). Leave `System/arraycopy` in
> `system.go` (it is already real; Task 4 just tests it). Read the throwaway
> (`/Users/andrew/Projects/let-go/pkg/rt/malli_throwaway.go`) as the reference
> before deleting it; every gap's fix is also described concretely in the Design
> above. **After the reset, malli no longer loads
> (expected)** — each task then adds real code TDD-style against the clean tree, so
> its eval/unit test is genuinely *red* until implemented, and keeps `make build` +
> `go test ./...` green. Full malli load returns at Task 7. Because the throwaway is
> gone from step 1, there are no double registrations and no cross-slice helper
> breakage.

## Task 1: Reset baseline + HashMap real value type (A2 — critical path)

**Files:**
- Delete: `/Users/andrew/Projects/let-go/pkg/rt/malli_throwaway.go`
- Create: `/Users/andrew/Projects/let-go/pkg/rt/host_hashmap.go`
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go` (`installClojureCompatAliases` + `invokeMethodFallback`)
- Test: `/Users/andrew/Projects/let-go/pkg/rt/host_hashmap_test.go`, `/Users/andrew/Projects/let-go/test/malli_compat_test.go`

- [ ] **Step 1: Reset to clean baseline.** `/Users/andrew/Projects/let-go/pkg/rt/malli_throwaway.go`
  is the working reference that Tasks 1–6 reimplement — **read it first** (the
  Design section above also describes every fix, so the reference is a convenience,
  not a dependency). Then delete it and remove its two hook sites in
  `/Users/andrew/Projects/let-go/pkg/rt/lang.go` — the `installMalliThrowaway(ns)`
  call in `installClojureCompatAliases` and the `mtwInterop(...)` block in
  `invokeMethodFallback` — in the same change. Run:
  `cd /Users/andrew/Projects/let-go && make build && go test ./...`. Expected:
  builds clean, existing tests PASS, and `grep -rn "mtw\|installMalliThrowaway" pkg/`
  → no hits. malli no longer loads — that's expected until Task 7.
- [ ] **Step 2: Write the failing tests.** In `host_hashmap_test.go` (pure Go),
  construct a HashMap value, `.putAll` a `vm.PersistentMap`, assert `.get` returns
  stored values and `vm.NIL` for absent keys, and assert `Type().Name()` is
  `"java.util.HashMap"` (not `java.lang.Object`). Create `test/malli_compat_test.go`
  now (an `evalMalli` helper mirroring `evalMedley` in `test/medley_compat_test.go`
  + a `TestMalliCompat` function) with a subtest asserting
  `(let [m (java.util.HashMap. 4 0.5)] (.putAll m {:a 1}) (.get m :a))` → `1`.
- [ ] **Step 3: Run to verify they fail.** Run: `go test ./pkg/rt/ -run HashMap && go test ./test/ -run TestMalliCompat`. Expected: FAIL (undefined type / `Can't resolve ->HashMap`).
- [ ] **Step 4: Implement.** Reimplement the reference `hashMapCompat` as a proper
  `pkg/rt` type with a dedicated `theHashMapType` `ValueType` (Name
  `"java.util.HashMap"`) and a `Receiver` implementing **only** `putAll` and `get`
  (drop the unused `size`/`containsKey` — YAGNI; malli's `fast-registry` uses only
  those two). Register the ctor in `installClojureCompatAliases`:
  `HashMap.`/`->HashMap` and `java.util.HashMap.`/`->java.util.HashMap`.
- [ ] **Step 5: Run to verify they pass.** Run: `go test ./pkg/rt/ -run HashMap && go test ./test/ -run TestMalliCompat`. Expected: PASS. `make build` still succeeds.
- [ ] **Step 6: Commit.** `git commit -m "Reset malli discovery scaffold; add mutable HashMap host-compat type"`

## Task 2: ArrayDeque real value type (B1)

**Files:**
- Create: `/Users/andrew/Projects/let-go/pkg/rt/host_arraydeque.go`
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Test: `/Users/andrew/Projects/let-go/pkg/rt/host_arraydeque_test.go`

- [ ] **Step 1: Write the failing test.** In `host_arraydeque_test.go` (pure Go),
  assert LIFO: push 1,2,3 → peek 3 → pop 3 → pop 2 → isEmpty false → pop 1 →
  isEmpty true; pop on empty errors.
- [ ] **Step 2: Run to verify it fails.** Run: `go test ./pkg/rt/ -run ArrayDeque`. Expected: FAIL.
- [ ] **Step 3: Implement.** Reimplement the reference `arrayDeque` as a proper
  `pkg/rt` type with a dedicated `theArrayDequeType` `ValueType` (Name
  `"java.util.ArrayDeque"`) and a `Receiver` implementing **only**
  `push`/`pop`/`peek`/`isEmpty` (drop the unused `size`). Register the ctor in
  `installClojureCompatAliases`: `ArrayDeque.`/`->ArrayDeque` and
  `java.util.ArrayDeque.`/`->java.util.ArrayDeque`.
- [ ] **Step 4: Run to verify it passes.** Run: `go test ./pkg/rt/ -run ArrayDeque`. Expected: PASS. `make build` still succeeds.
- [ ] **Step 5: Commit.** `git commit -m "Add mutable ArrayDeque host-compat type for let-go interop"`

## Task 3: Generic JVM collection-interface interop (A5 + B2 interop)

**Files:**
- Create: `/Users/andrew/Projects/let-go/pkg/rt/host_iterator.go`
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go` (`invokeMethodFallback`)
- Test: `/Users/andrew/Projects/let-go/pkg/rt/host_iterator_test.go`, `/Users/andrew/Projects/let-go/test/malli_compat_test.go`

- [ ] **Step 1: Write the failing tests.** Go unit (`host_iterator_test.go`):
  `seqIterator` over a vector yields its elements then `hasNext`→false. Eval-level
  subtests in `test/malli_compat_test.go`: `(.valAt {:a 1} :a)`→1,
  `(.valAt {:a 1} :b :nf)`→`:nf`, `(.nth [10 20] 1)`→20, `(.count [1 2 3])`→3, and
  iterating `(let [it (.iterator [1 2])] [(.hasNext it) (.next it) (.next it) (.hasNext it)])`.
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./pkg/rt/ -run Iterator && go test ./test/ -run TestMalliCompat`. Expected: the new subtests FAIL (`method-invoke expected Receiver`).
- [ ] **Step 3: Implement.** Add `seqIterator` (Receiver over a normalized seq;
  `hasNext`/`next`) in `host_iterator.go`, plus a self-contained helper
  `hostCollectionMethod(rec, name, args) (Value, bool, error)` mapping
  `valAt`→`Lookup.ValueAt/ValueAtOr`, `iterator`→`seqIterator`,
  `assoc`→`Associative.Assoc`, `cons`→`Collection.Conj`, `nth`→`Indexed.Nth`,
  `count`→`Counted.Count`, `hashCode`→`hash`, `longValue`→identity (the helper
  looks up the `seq` and `hash` builtins itself — no shared state with other
  tasks). Call it near the top of `invokeMethodFallback`, returning when handled.
  Normalize seqs to `NIL`-when-empty using the `seq` builtin.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./pkg/rt/ -run Iterator && go test ./test/ -run TestMalliCompat`. Expected: PASS. `make build` still succeeds.
- [ ] **Step 5: Commit.** `git commit -m "Support JVM collection-interface interop (.valAt/.iterator/.assoc/...) on let-go collections"`

## Task 4: Static methods — vector/map builders + regex hash (A1, A3, A4, B2 statics)

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go` (`installClojureCompatAliases`), `/Users/andrew/Projects/let-go/pkg/rt/system.go` (`installSystemNS`)
- Test: `/Users/andrew/Projects/let-go/test/malli_compat_test.go`

- [ ] **Step 1: Write the failing tests.** Add `TestMalliCompat` subtests:
  `(LazilyPersistentVector/createOwning (object-array 0))`→`[]`; a `createWithCheck`
  round-trip built with a real object array —
  `(let [a (object-array 4)] (aset a 0 :a) (aset a 1 1) (aset a 2 :b) (aset a 3 2)
  (clojure.lang.PersistentArrayMap/createWithCheck a))`→`{:a 1 :b 2}`, and the same
  with a duplicate key throws; a `System/arraycopy` round-trip over two
  `object-array`s; `(Array/newInstance java.lang.Object 3)` returns a 3-element
  array; `(Util/hashCombine 1 2)` returns an int. (`object-array-of` does **not**
  exist — build flat arrays with `object-array`+`aset` as shown.)
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./test/ -run TestMalliCompat`. Expected: the new subtests FAIL. (`System/arraycopy` survived the Task-1 reset and already resolves — its subtest is a characterization check that stays green.)
- [ ] **Step 3: Implement.** Reimplement from the reference: `LazilyPersistentVector/createOwning`
  (=`vec`), `PersistentArrayMap/createWithCheck` (fold pairs → PersistentMap, error on
  dup), `Array/newInstance` (→`object-array`), `Util/hash`+`Murmur3/hashLong` (=`hash`),
  `Util/hashCombine` (standard combine) — registered in `installClojureCompatAliases`
  (bare + `clojure.lang.` names where malli uses bare). `System/arraycopy` already
  lives in `system.go` (kept through the reset) — confirm it stays.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./test/ -run TestMalliCompat`. Expected: PASS. `make build` still succeeds.
- [ ] **Step 5: Commit.** `git commit -m "Add createOwning/createWithCheck/arraycopy/Array-newInstance/Util-hash statics"`

## Task 5: Stdlib fns + host-class markers + dynaload protocols + timeout stubs (A6, A7, A8, A9)

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Test: `/Users/andrew/Projects/let-go/test/malli_compat_test.go`

- [ ] **Step 1: Write the failing tests.** `TestMalliCompat` subtests:
  `(indexed? [1])`→true, `(indexed? {})`→false, `(class 1)` returns a type,
  `(uri? "x")`→false, `(instance? java.util.Map {})`→true,
  `(instance? CharSequence "s")`→true, `(instance? Pattern #"x")`→true,
  `(monitor-enter :x)`→nil, `(= TimeUnit/MILLISECONDS TimeUnit/MILLISECONDS)`→true.
  For the loud `FutureTask.` stub, assert **compile-only** resolution without
  triggering the throw: `(fn? (fn [] (FutureTask. nil)))`→true (the ctor call sits
  in an unevaluated fn body, so it must *resolve* but is never run). Do **not**
  evaluate `(FutureTask. nil)` directly — it is designed to throw.
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./test/ -run TestMalliCompat`. Expected: the new subtests FAIL (`Can't resolve ...`).
- [ ] **Step 3: Implement.** Add `indexed?` (`vm.Indexed` check), `class`
  (alias of `type`), `uri?` (constant false), `monitor-enter`/`monitor-exit`
  (no-ops) as builtins. `RegisterHostClass` for `java.util.Map`→`PersistentMapType`,
  `CharSequence`→`StringType`, bare `Pattern`→`RegexType`,
  `java.util.AbstractList`/`java.util.Vector`→markers. Register fresh Go Protocols
  `clojure.lang.IDeref` / `clojure.lang.IFn` so dynaload's `LazyVar` deftype
  compiles. Register the degraded timeout-path stubs (`malli.impl.util/-run`):
  loud `FutureTask.`/`->FutureTask`, `Thread.`/`->Thread`, and a
  `TimeUnit/MILLISECONDS` marker.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./test/ -run TestMalliCompat`. Expected: PASS. `make build` still succeeds.
- [ ] **Step 5: Commit.** `git commit -m "Add indexed?/class/uri?/monitor-enter, host-class markers, IDeref/IFn protocols, timeout stubs"`

## Task 6: malli.transform statics — string coercion + java.time stubs (C1–C4)

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Test: `/Users/andrew/Projects/let-go/test/malli_compat_test.go`

- [ ] **Step 1: Write the failing tests.** `TestMalliCompat` subtests:
  `(Long/parseLong "42")`→42, `(Float/parseFloat "3.5")`→3.5,
  `(Double/parseDouble "3.5")`→3.5,
  `(UUID/fromString "00000000-0000-0000-0000-000000000000")` returns a uuid,
  `(-> (DateTimeFormatterBuilder.) (.appendPattern "x") (.toFormatter))` returns a
  value (chain threads).
- [ ] **Step 2: Run to verify they fail.** Run: `go test ./test/ -run TestMalliCompat`. Expected: the new subtests FAIL.
- [ ] **Step 3: Implement.** Real `Long/parseLong`/`Integer/parseInt`/
  `Float/parseFloat`/`Double/parseDouble` (Go `strconv`) on the existing
  `Long`/`Integer`/`Float`/`Double` namespaces; bare `UUID/fromString`
  (`vm.ParseUUID`); a chainable java.time stub (builder methods → self;
  `.parse`/`.format` → throw) bound to `DateTimeFormatterBuilder.`,
  `DateTimeFormatter/ofPattern`, `ZoneId/of`, `Date`/`Instant`; `ChronoField/*`
  markers; `BigDecimal.`/`URI.` loud stubs.
- [ ] **Step 4: Run to verify they pass.** Run: `go test ./test/ -run TestMalliCompat`. Expected: PASS. `make build` still succeeds.
- [ ] **Step 5: Commit.** `git commit -m "Add malli.transform coercion statics (parse fns, UUID, java.time chainable stubs)"`

## Task 7: Rebuild + gate full malli load

**Files:** (verification only — the throwaway was removed in Task 1)

- [ ] **Step 1: Confirm clean tree.** The throwaway was deleted in Task 1; confirm
  no reference remains: `grep -rn "malliThrowaway\|installMalliThrowaway\|mtw" /Users/andrew/Projects/let-go/pkg/`
  (expect no hits).
- [ ] **Step 2: Build + full test suite.** Run: `cd /Users/andrew/Projects/let-go && make build && go test ./...`. Expected: builds clean, all tests PASS (incl. `TestMalliCompat`, `-run 'HashMap|ArrayDeque|Iterator'`).
- [ ] **Step 3: Fetch the library sources.** Run:
  `git clone --branch 0.20.1 --depth 1 https://github.com/metosin/malli /tmp/malli-src`
  and `git clone --branch v0.3.5 --depth 1 https://github.com/borkdude/dynaload /tmp/dynaload-src`
  (skip either clone if already present). Set
  `SRCS=/tmp/malli-src/src:/tmp/dynaload-src/src`.
- [ ] **Step 4: Full-load gate.** Run:
  `LG_READ_CLJ=1 /Users/andrew/Projects/let-go/lg -source-paths "$SRCS" -e "(require '[malli.core] '[malli.error] '[malli.util] '[malli.transform]) (println :ALL-LOADED)" 2>&1`.
  Expected: prints `:ALL-LOADED`; **no** `failed to load` / `Can't resolve` on stderr.
- [ ] **Step 5: Functional smoke.** Write this self-contained script to
  `/tmp/malli_smoke.lg` (via a heredoc) and run it with
  `LG_READ_CLJ=1 lg -source-paths "$SRCS" /tmp/malli_smoke.lg`. It tracks failures
  and exits non-zero, so the step fails loudly rather than relying on eyeballing:

  ```clojure
  (require '[malli.core :as m] '[malli.error :as me] '[malli.util :as mu] '[malli.transform :as mt])
  (def failures (atom 0))
  (defn ck [label got exp]
    (let [pass (= got exp)]
      (when-not pass (swap! failures inc))
      (println (if pass "ok  " "FAIL") label "=>" (pr-str got))))
  (ck "validate scalar"  (m/validate :int 42) true)
  (ck "validate map"     (m/validate [:map [:n :string] [:a :int]] {:n "Ada" :a 36}) true)
  (ck "closed map reject"(m/validate [:map {:closed true} [:x :int]] {:x 1 :z 9}) false)
  (ck "vector/set/mapof" [(m/validate [:vector :int] [1 2]) (m/validate [:set :keyword] #{:a})
                          (m/validate [:map-of :string :int] {"a" 1})] [true true true])
  (ck "enum/maybe/and/or"[(m/validate [:enum "M"] "M") (m/validate [:maybe :int] nil)
                          (m/validate [:and :int [:> 0]] 5) (m/validate [:or :int :string] "x")] [true true true true])
  (ck "re"               (m/validate [:re #"\d+"] "123") true)
  (ck "seq cat/*/+/?/rep"[(m/validate [:cat :int :keyword] [1 :a]) (m/validate [:* :int] [1 2])
                          (m/validate [:+ :string] ["a"]) (m/validate [:? :int] [1])
                          (m/validate [:repeat {:min 1} :int] [1 2])] [true true true true true])
  (ck "parse cat"        (m/parse [:cat :int :keyword] [1 :a]) [1 :a])
  (ck "humanize"         (me/humanize (m/explain [:map [:a :int]] {:a "x"})) {:a ["should be an int"]})
  (ck "mu/merge form"    (m/form (mu/merge [:map [:x :int]] [:map [:y :string]])) [:map [:x :int] [:y :string]])
  (ck "decode int"       (m/decode :int "42" (mt/string-transformer)) 42)
  (ck "decode map"       (m/decode [:map [:id :int] [:t :keyword]] {:id "7" :t "x"} (mt/string-transformer)) {:id 7 :t :x})
  (when (pos? @failures) (println "SMOKE FAILURES:" @failures) (os/exit 1))
  (println "SMOKE OK")
  ```

  Expected: every line begins with `ok`, ends with `SMOKE OK`, and exit code 0.

(No commit — Task 7 is verification only; the runtime changes were committed in
Tasks 1–6. If the gate/smoke surfaces a regression, fix it in the owning task and
re-run this gate.)

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
  `:and`/`:or`/closed maps); the sequence engine (`:cat`/`:*`/`:+`/`:?`/`:repeat`
  validate + `m/parse`); `malli.util` (`merge`/`select-keys`/`optional-keys`); and string
  coercion (`m/decode` with `mt/string-transformer` over ints/keywords/a map). No
  top-level side effects that need `*compiling-aot*` guarding beyond the demo prints
  (there is no `-main`).
- [ ] **Step 3: Commit.** `git commit -m "Add with-malli example"`

## Task 9: Verify the example end-to-end (both ways)

- [ ] **Step 1: Direct run.** Run: `LG_READ_CLJ=1 <lg> -source-paths "<malli>/src:<dynaload>/src" examples/clojure-libs/with-malli/main.lg`. Expected: every headline section prints working output, no `error:`/`ERR:`.
- [ ] **Step 2: Through lgx.** Build lgx if needed (`make build`), then
  `cd examples/clojure-libs/with-malli && LGX_LG=<lg> <lgx-bin> run main.lg`.
  Expected: lgx auto-installs deps, sets `LG_READ_CLJ`, and the **demo output**
  matches Step 1 (ignore lgx's own cold-cache dependency-install/progress lines,
  which appear only on the first run before the demo output).
- [ ] **Step 3: lgx test suite green.** Run: `cd /Users/andrew/Projects/lgx && make test`. Expected: PASS (the example doesn't regress lgx).
- [ ] **Step 4: Commit** (only if the example needed adjustment). `git commit -m "Polish with-malli example after end-to-end verification"`

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
