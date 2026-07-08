# Integrant + dependency let-go compatibility Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `weavejester/dependency` 1.0.1 and then `weavejester/integrant` 1.0.1 load and run under let-go, driven through lgx, by closing a small set of runtime gaps in let-go upstream and adding two worked examples.

**Tech Stack:** let-go (Go VM + `.lg` stdlib in `/Users/andrew/Projects/let-go`, branch `integrant-compat`), lgx (this repo), Clojure `.cljc` libraries.

---

## Design

### Context

Both libraries ship as a single `.cljc` file:

- `dependency` → `src/weavejester/dependency.cljc` (bidirectional dependency graph; `defrecord MapDependencyGraph` + two protocols; `topo-sort` via Kahn's algorithm).
- `integrant` → `src/integrant/core.cljc` (data-driven micro-framework; `defrecord Ref/RefSet/Var/Profile`, `RefLike` protocol, many `defmulti`s, hierarchy-based `derive`/`isa?`).

let-go's local `lg` already resolves `.clj`/`.cljc` and matches `:clj` reader-conditional branches under `LG_READ_CLJ=1`. lgx exports `LG_READ_CLJ=1` on every spawn, so both libs are *reachable*; only specific runtime features are missing.

**Already present in let-go** (verified): `clojure.set`→`set` alias, `fnil`, `sorted-set-by`, transducer arities of `into`/`map`, `defprotocol`/`deftype`/`extend-type`, `defmulti`/`defmethod` (incl. docstring + attr-map), `defonce` (with metadata), `derive`/`isa?`/`ancestors`/`make-hierarchy`, `memoize`, `gensym`, `tree-seq`, `reduce-kv`, `vary-meta`, `assoc-in`, `get-in`, `select-keys`, `satisfies?`, `record?`, `var-get`, `(Foo. …)`→`(->Foo …)` desugar, `#?@` reader splice, `:refer-clojure :exclude`, `catch` on unresolved JVM classes, `instance?` on record types.

### The gaps (and fixes)

**Phase 1 — `dependency`:**

- **G1 — `defrecord` doesn't lexically scope record fields in protocol-method bodies.**
  `deftype` rewrites bare field references in inline method bodies (its `-dt-rewrite*` family turns a field symbol into `(.field recv)`), but `defrecord` passes method bodies **verbatim** to `extend-type`. So `MapDependencyGraph`'s `(get dependencies node #{})` fails to compile with `Can't resolve dependencies in this context`. This is the first thing that breaks and also blocks integrant (`Ref`/`RefSet` reference their `key` field inside `RefLike` methods).
  **Fix:** apply the same field-rewrite to `defrecord` method bodies, emitting **keyword access** `(:field recv)` (records are map-backed; keyword read is the canonical, nil-safe accessor). `deftype` keeps its `.field` emission unchanged.

- **G2 — `clojure.lang.PersistentQueue` is a load-only stub, not a real queue.**
  `dependency`'s headline `(topo-sort g)` (no-comparator path) seeds a FIFO worklist with `(into clojure.lang.PersistentQueue/EMPTY leaves)` and drives it with `conj`/`peek`/`pop`. The current stub binds `EMPTY` to a marker symbol that fails loudly when conj'd.
  **Fix:** add a real persistent queue value type to let-go implementing the `Collection` + `Sequable` + `Counted` interfaces (so `conj`/`into`/`seq`/`count`/`empty?` work for free), add `peek`/`pop` cases, bind `PersistentQueue/EMPTY` to a real empty queue, and wire type ancestry so `(instance? clojure.lang.PersistentQueue q)` and medley's `queue?`/`queue` work. (integrant does **not** hit this path — it uses `topo-comparator`, which takes the `sorted-set-by` path that already works. G2 exists to make the standalone `dependency` example's headline feature honest, and as a bonus un-degrades medley's queue.)

**Phase 2 — `integrant`** (in addition to G1):

- **G3 — `find-var` missing.** integrant's default `init-key` resolves a component fn from a qualified keyword (`find-key-init-fn` → `(some-> (find-var sym) var-get)`).
  **Fix:** add a real `find-var` (qualified symbol → interned var via let-go's namespace registry; `nil` when absent). Enables integrant's zero-boilerplate default `init-key`.

- **G4 — `enumeration-seq` + `clojure.lang.RT/baseLoader` unresolved.** Only reached inside integrant's JVM-only classpath scanners (`resources`/`load-hierarchy`/`load-annotations`).
  **Fix:** add compile-only stubs — an `enumeration-seq` fn and a `clojure.lang.RT` bare-ns with a `baseLoader` marker — so those `#?(:clj …)` defns **load**; degraded (throw) if actually called, matching the existing medley class-stub precedent.

- **G5 — `get-method` missing.** integrant's top-level `(defn- can-expand-key? [k] (get-method expand-key …))` references it, so the **whole namespace fails to load** even though `get-method` is only used by `expand`.
  **Fix:** add a real `get-method` (multimethod method-table lookup by dispatch value). Unblocks ns load and enables `expand`.

### Approach & decisions (locked with user)

- **Implement the real PersistentQueue (G2).** The `with-dependency` example's `topo-sort` must work end-to-end.
- **`with-integrant` example scope:** a small real init/halt lifecycle with a `#ig/ref` and `defmethod init-key`/`halt-key!`, **plus a `defmethod assert-key`** that validates a component value before init (demonstrating the assertion path through `build`).
- **Two-repo change.** Runtime fixes land in `/Users/andrew/Projects/let-go`; examples + docs land in this repo. After any Go change, rebuild `lg` (`make build` in the let-go repo) before running examples.
- **Dependency version.** integrant declares `dependency 0.2.1`/`1.0.0` in its own manifests, but per the user we pin **1.0.1** in the example. It is API-compatible for what integrant uses (`graph`, `depend`, `transitive-dependencies-set`, `transitive-dependents-set`, `topo-comparator`). lgx has no transitive resolution for plain Clojure libs, so the example's `lgx.edn` lists **both** deps directly.

### Testing strategy

- **let-go unit tests** (`go test ./test/...`, auto-discovers `test/*.lg`): a `.lg` test per gap exercising the smallest failing form, plus Go-level expression tests mirroring `test/medley_compat_test.go` for the queue/`find-var`/`get-method` surface.
- **Regression:** implementing G2 flips an existing assertion in `test/medley_compat_test.go` (`(into clojure.lang.PersistentQueue/EMPTY [1 2 3])` currently asserts an **error**); update it to assert a real queue result, and refresh the surrounding comments and `docs/issues/clojure-lib-compat.md` §1.
- **End-to-end:** each example is run two ways — directly (`LG_READ_CLJ=1 lg -source-paths <src> main.lg`) for a fast loop, and faithfully through lgx (`LGX_LG=<lg> lgx run main.lg`, which sets `LG_READ_CLJ` itself).
- Keep `make test` green in both repos.

### Error handling

Degraded-by-design surfaces fail **loudly** (throw) rather than returning plausible-but-wrong values: `enumeration-seq`/`clojure.lang.RT/baseLoader` throw if called at runtime; `find-var` returns `nil` for an unknown symbol (matching Clojure). The queue is a real, correct implementation with no degraded surface.

## File Structure

**let-go repo (`/Users/andrew/Projects/let-go`):**

- Modify `pkg/rt/core/core.lg` — generalize the `-dt-rewrite*` field-rewrite family to take a field-read emitter; make `defrecord` rewrite its method bodies with the keyword emitter (G1).
- Create `pkg/vm/persistent_queue.go` — the `PersistentQueue` value type (G2).
- Modify `pkg/rt/lang.go` — `peek`/`pop` queue cases, `PersistentQueue/EMPTY` real binding, queue ancestry/`queue?`, and the new `find-var` (G3), `enumeration-seq` + `clojure.lang.RT/baseLoader` stubs (G4), `get-method` (G5).
- Create `test/defrecord_field_scope_test.lg` — G1 regression.
- Create `test/persistent_queue_test.lg` — G2 behavior (conj/peek/pop/into/seq/count + a topo-sort-shaped FIFO drain).
- Create `test/integrant_compat_test.go` — Go expression tests for `find-var`/`get-method`/`enumeration-seq`/RT stub (mirrors `medley_compat_test.go`).
- Modify `test/medley_compat_test.go` — flip the queue assertion (G2 regression).
- (Optional) Modify `test/compat/run.lg` — add `dependency` + `integrant` to the coverage runner's `repos` map.

**lgx repo (this repo):**

- Verify/keep `examples/clojure-libs/with-dependency/{lgx.edn,main.lg}`.
- Create `examples/clojure-libs/with-integrant/lgx.edn` — both deps pinned directly.
- Create `examples/clojure-libs/with-integrant/main.lg` — init/halt/assert-key lifecycle demo.
- Modify `docs/knowledge-base/let-go-stdlib-quick-ref.md` — note the new fns/queue.
- Modify `docs/knowledge-base/let-go-gotchas.md` — defrecord field-scope + queue notes if warranted.
- Modify `docs/issues/clojure-lib-compat.md` — mark the defrecord/queue items resolved; refresh the medley queue note.
- Create `docs/issues/integrant-dependency-compat.md` — the upstream write-up for G1–G5.

---

## Phase 1 — `dependency`

### Task 1: G1 — `defrecord` field scope in protocol methods ✅ complete (`f67251a`, `da878ad`)

> Deviations:
> - Test function is `TestRunner` (not `TestLanguage`); subtest = `.lg` filename. All Task verification commands use `-run 'TestRunner/<file>'`.
> - Editing `pkg/rt/core/core.lg` requires regenerating the embedded bundle: `go run -tags bootstrap ./cmd/lgbgen` (writes `core_compiled.lgb` + `generated.sums`). Plan omitted this; needed before every `go test`/`make build`.
> - Codex review (P2) flagged that a `case` test-constant sharing a field name was wrongly rewritten to a field read. Added `case`-aware handling to `-dt-rewrite` (`-dt-rewrite-case`) — rewrites dispatch/result exprs, leaves test-constants literal; improves `deftype` too. Fixup commit `da878ad`.
> - Gitignored a pre-existing stray `.clj-pulse/` artifact in the let-go repo so `git add -A` stays clean.

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/core/core.lg` (+ regenerated `core_compiled.lgb`, `generated.sums`)
- Test: `/Users/andrew/Projects/let-go/test/defrecord_field_scope_test.lg`

- [x] **Step 1: Write the failing test.**
  In `defrecord_field_scope_test.lg`: `(ns defrecord-field-scope-test (:require [test]))`. Define a protocol `(defprotocol P (m1 [g n]) (m2 [g]))` and `(defrecord R [a b] P (m1 [g n] (get a n :none)) (m2 [g] (+ (count a) (count b))))`. `deftest` asserting `(m1 (->R {:x 1} {}) :x)` → `1`, `(m1 (->R {:x 1} {}) :z)` → `:none`, and `(m2 (->R {:x 1} {:y 2 :z 3}))` → `3`. Also assert an interop-ctor form `(R. {:x 1} {})` works and a `let` inside a method that **shadows** a field name (e.g. `(let [a 99] a)`) returns the local, not the field.

- [x] **Step 2: Run test to verify it fails.**
  Run: `cd /Users/andrew/Projects/let-go && go test ./test/... -run 'TestLanguage/defrecord_field_scope' -v -count=1`
  Expected: `--- FAIL: TestLanguage/defrecord_field_scope_test.lg` with a compile error `Can't resolve a in this context` (bare field ref not rewritten). (Subtests are named by `.lg` filename; targeting one keeps the go-test exit code meaningful — don't pipe through `grep`.)

- [x] **Step 3: Implement the fix.**
  In `core.lg`, generalize the field-rewrite family (`-dt-rewrite`, `-dt-rewrite-let`, `-dt-rewrite-fn`, `-dt-rewrite-method`, `-dt-rewrite-impls`) so the leaf field-read form is produced by an injected emitter rather than hard-coded to `(.field recv)`. The emitter has shape `(fn [recv field-sym] → read-form)`. `deftype` passes the dot emitter `(fn [recv f] (list (symbol (str "." (name f))) recv))` (unchanged behavior). In `defrecord`, when `protocol-impls` is non-empty, rewrite them with the **keyword** emitter `(fn [recv f] (list (keyword f) recv))` and empty `muts` (records have no mutable fields) **before** handing them to `extend-type`. Keep computing `protocol-parents`/`parent-forms` and the positional/map constructors as today; use `-dt-field-name` on fields for robustness, mirroring `deftype`. Thread the emitter explicitly through the helper signatures, or bind it via a dynamic var around the rewrite call — either is acceptable; keep `deftype`'s output byte-for-byte unchanged.

- [x] **Step 4: Run test to verify it passes.**
  Run: `cd /Users/andrew/Projects/let-go && go test ./test/... -run 'TestLanguage/defrecord_field_scope' -v -count=1`
  Expected: `--- PASS: TestLanguage/defrecord_field_scope_test.lg`.

- [x] **Step 5: Guard against deftype regressions.**
  Run: `cd /Users/andrew/Projects/let-go && go test ./test/... -run 'TestLanguage|Deftype' -count=1`
  Expected: exit 0 with no `--- FAIL` — existing `deftype_capture_test.lg` / `deftype_reify_hygiene_test.lg` still pass.

- [x] **Step 6: Confirm `dependency` loads past the record.**
  Rebuild: `cd /Users/andrew/Projects/let-go && make build`
  Run: `LG_READ_CLJ=1 /Users/andrew/Projects/let-go/lg -source-paths ~/.lgx/gitlibs/github.com/weavejester/dependency/1.0.1/src /Users/andrew/Projects/worktrees/lgx/integrant-compat/examples/clojure-libs/with-dependency/main.lg 2>&1 | head`
  Expected: all demos print **except** the final `topo-sort`, which now fails on `PersistentQueue` (fixed in Task 2) — the record/protocol error is gone.

- [x] **Step 7: Commit** (in let-go repo)
  `git add -A && git commit -m "fix(core): scope record fields in defrecord protocol-method bodies"`
  (Use `git add -A`, not `commit -am` — this task creates a new test file, which `-a` would not stage.)

### Task 2: G2 — real `clojure.lang.PersistentQueue` ✅ complete (`3e3133a`, `f37bcda`)

> Deviations:
> - Codex review (2× P2) flagged that the new queue diverged from let-go's own equality/type conventions: `(= queue seq)` was false, and `clojure.lang.PersistentQueue` resolved to a symbol marker rather than a type. Fixup `f37bcda`: added `*vm.PersistentQueue` to `isSequentialType` (cross-type sequential `=` via the rt path, exactly like vectors) and bound `clojure.lang.PersistentQueue` → `vm.QueueType` (so `(type q)` and `instance?` agree); dropped the now-redundant self-marker in `directTypeParents`.
> - Ancestry wiring lives in `pkg/rt/hierarchy.go` (`directTypeParents`), not only `lang.go` as the plan implied.

**Files:**
- Create: `/Users/andrew/Projects/let-go/pkg/vm/persistent_queue.go`
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Modify: `/Users/andrew/Projects/let-go/test/medley_compat_test.go`
- Test: `/Users/andrew/Projects/let-go/test/persistent_queue_test.lg`
- Test: `/Users/andrew/Projects/let-go/pkg/vm/persistent_queue_test.go`

- [x] **Step 1: Write the failing `.lg` test.**
  In `persistent_queue_test.lg`: build `(def q (into clojure.lang.PersistentQueue/EMPTY [1 2 3]))`. Assert `(peek q)` → `1` (FIFO front), `(peek (pop q))` → `2`, `(count q)` → `3`, `(seq q)` → `(1 2 3)`, `(peek (conj q 4))` → `1`, `(empty? clojure.lang.PersistentQueue/EMPTY)` → `true`, and a drain loop (peek/pop until empty) yields `[1 2 3]` in order.

- [x] **Step 2: Run to verify it fails.**
  Run: `cd /Users/andrew/Projects/let-go && go test ./test/... -run 'TestLanguage/persistent_queue' -v -count=1`
  Expected: `--- FAIL: TestLanguage/persistent_queue_test.lg` — `into` on the marker stub errors.

- [x] **Step 3: Implement the queue type.**
  In `persistent_queue.go` define a `PersistentQueue` (Okasaki two-list form: a front `Seq` + a rear `[]Value` + `count`, plus optional `meta`). Implement the `vm.Value` methods (`Type`/`Unbox`/`String`/`Hash`/`Equals`), `Counted` (`RawCount`/`Count`), `Collection` (`Empty` → the empty queue, `Conj` → append to rear/front per Clojure semantics), and `Sequable` (`Seq` → front concatenated with reversed rear, `EmptyList` when empty). Add exported `Peek()` (front element or `NIL`) and `Pop()` (drop front; when front empties, promote reversed rear). Create a package-level `EmptyPersistentQueue` singleton. Register a `PersistentQueueType` `ValueType` for `instance?`/ancestry.

- [x] **Step 4: Wire it in `lang.go`.**
  Add `case *vm.PersistentQueue:` to the `peek` and `pop` native fns (peek → `Peek()`; pop → `Pop()`, erroring on empty like the other pop cases). Replace the `PersistentQueue/EMPTY` marker binding with `vm.EmptyPersistentQueue`. Wire the `clojure.lang.PersistentQueue` marker so it reports queue instances as ancestors (so `(instance? clojure.lang.PersistentQueue q)` is true and medley's `queue?` works). Confirm `into`/`conj`/`seq`/`count`/`empty?` need no extra cases (they dispatch through the `Collection`/`Sequable`/`Counted` interfaces) and that `transientable?` returns false for the queue so `into` uses `reduce conj`.

- [x] **Step 5: Add Go-level unit tests.**
  In `pkg/vm/persistent_queue_test.go`: table tests for conj/peek/pop/seq/count/Equals/Empty and FIFO ordering over a few hundred elements (front/rear rebalancing).
  Run: `cd /Users/andrew/Projects/let-go && go test ./pkg/vm/... -run PersistentQueue -count=1`
  Expected: PASS.

- [x] **Step 6: Update the medley regression.**
  In `test/medley_compat_test.go`, change the `PersistentQueue/EMPTY fails loudly when conj'd` case: `(into clojure.lang.PersistentQueue/EMPTY [1 2 3])` now returns a real queue — assert **no error** and that `(peek …)` is `1`. Update the test name and comment to reflect that the queue is real. Leave the `(instance? clojure.lang.PersistentQueue [1 2])` → false case (a vector is not a queue).

- [x] **Step 7: Run the full let-go suite.**
  Run: `cd /Users/andrew/Projects/let-go && make build && set -o pipefail && go test ./... -count=1 2>&1 | tail -25`
  Expected: exit 0, all packages `ok`, no `--- FAIL` (persistent-queue `.lg`, `pkg/vm` queue, medley compat, everything green). `set -o pipefail` ensures the pipe reflects a test failure rather than `tail`'s exit code.

- [x] **Step 8: Verify `with-dependency` end-to-end.**
  Run: `LG_READ_CLJ=1 /Users/andrew/Projects/let-go/lg -source-paths ~/.lgx/gitlibs/github.com/weavejester/dependency/1.0.1/src /Users/andrew/Projects/worktrees/lgx/integrant-compat/examples/clojure-libs/with-dependency/main.lg`
  Expected: **all** demos print, including `topo-sort` → a valid build order (deps before dependents, e.g. `[:core :ui :db :app]` or an equivalent valid topo order).

- [x] **Step 9: Commit** (in let-go repo)
  `git add -A && git commit -m "feat(vm): real clojure.lang.PersistentQueue (conj/peek/pop/seq)"`
  (New files `persistent_queue.go` + `persistent_queue_test.go` must be staged with `git add -A`.)

### Task 3: Phase 1 verification via lgx + docs

**Files:**
- Verify: `examples/clojure-libs/with-dependency/{lgx.edn,main.lg}` (this repo)
- Modify: `docs/knowledge-base/let-go-stdlib-quick-ref.md`, `docs/issues/clojure-lib-compat.md`

- [ ] **Step 1: Run `with-dependency` through lgx (faithful path).**
  Build lgx if needed: `cd /Users/andrew/Projects/worktrees/lgx/integrant-compat && make build`
  Run: `cd examples/clojure-libs/with-dependency && LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/worktrees/lgx/integrant-compat/bin/lgx run main.lg`
  Expected: identical full output (lgx sets `LG_READ_CLJ` itself). If the example reads awkwardly, tighten comments only — no behavior change.

- [ ] **Step 2: Update docs.**
  In `let-go-stdlib-quick-ref.md` note the real `clojure.lang.PersistentQueue` (conj/peek/pop/into/seq). In `clojure-lib-compat.md` §1, mark the PersistentQueue degradation resolved and point at the queue work. Keep each doc's `Verify against:` footer accurate.

- [ ] **Step 3: Commit** (this repo)
  `git add -A && git commit -m "docs: dependency runs under let-go; real PersistentQueue"`

## Phase 2 — `integrant`

### Task 4: G3/G4/G5 — `find-var`, `get-method`, classpath-scan stubs

**Files:**
- Modify: `/Users/andrew/Projects/let-go/pkg/rt/lang.go`
- Create: `/Users/andrew/Projects/let-go/test/integrant_compat_test.go`

- [ ] **Step 1: Write failing Go expression tests.**
  In `integrant_compat_test.go` (mirror `medley_compat_test.go`'s `eval…` helper against the core NS): (a) `(def x 5)` then `(var-get (find-var 'user/x))` → `5` and `(find-var 'user/nope)` → `nil`; (b) a `defmulti`/`defmethod` then `(get-method mm :some)` returns a non-nil fn and `(get-method mm :absent)` returns the default (or nil per Clojure); (c) `(defn f [] (clojure.lang.RT/baseLoader))` and `(defn g [e] (enumeration-seq e))` both **compile** without error.

- [ ] **Step 2: Run to verify failure.**
  Run: `cd /Users/andrew/Projects/let-go && go test ./test/... -run Integrant -count=1`
  Expected: FAIL — `Can't resolve find-var / get-method / enumeration-seq / clojure.lang.RT/baseLoader`.

- [ ] **Step 3: Implement `find-var` (G3).**
  Add a native `find-var`: takes a namespace-qualified symbol, looks up the namespace in the registry and returns the interned `*Var` (not its value), or `nil` if the ns or name is absent. Pair with the existing `var-get`.

- [ ] **Step 4: Implement `get-method` (G5).**
  Add a native `get-method`: given a multifn value and a dispatch value, return the method fn registered for that value (honoring the hierarchy the same way dispatch does), else the `:default` method, else `nil`. Follow the existing `vm.MultiFn` method-table structure used by `defmulti`/`defmethod`.

- [ ] **Step 5: Implement the classpath-scan stubs (G4).**
  Add a compile-only `enumeration-seq` (throws with a clear "not supported under let-go" message if called; resolves at compile). Add a `clojure.lang.RT` bare-ns with a `baseLoader` that resolves and returns a marker/throws if invoked — mirror the medley `java.util.ArrayList` load-only stub precedent and comment it the same way.

- [ ] **Step 6: Run to verify passes.**
  Run: `cd /Users/andrew/Projects/let-go && go test ./test/... -run Integrant -count=1`
  Expected: PASS.

- [ ] **Step 7: Confirm integrant loads.**
  Rebuild: `make build`. Then load integrant with both source paths (dependency is already cached; integrant will be cached by lgx in Task 5 — for this check, clone integrant 1.0.1 to a temp `src` or point at the lgx cache once present):
  Run: `LG_READ_CLJ=1 /Users/andrew/Projects/let-go/lg -source-paths "<dependency-src>:<integrant-src>" -e "(require 'integrant.core) (println :loaded)"`
  Expected: prints `:loaded` with no `Can't resolve` errors. Fix any newly-surfaced unresolved symbol before proceeding.

- [ ] **Step 8: Commit** (in let-go repo)
  `git add -A && git commit -m "feat(rt): find-var, get-method, and integrant classpath-scan stubs"`
  (New file `integrant_compat_test.go` must be staged with `git add -A`.)

### Task 5: `with-integrant` example

**Files:**
- Create: `examples/clojure-libs/with-integrant/lgx.edn`
- Create: `examples/clojure-libs/with-integrant/main.lg`

- [ ] **Step 1: Write `lgx.edn`.**
  Both deps pinned directly (lgx has no transitive resolution for Clojure libs):
  ```clojure
  {:main "main.lg"
   :targets {:bin {:out "bin/with-lib"}}
   :deps {dev.weavejester/dependency {:git/url "https://github.com/weavejester/dependency" :git/tag "1.0.1"}
          dev.weavejester/integrant  {:git/url "https://github.com/weavejester/integrant"  :git/tag "1.0.1"}}}
  ```

- [ ] **Step 2: Write `main.lg` — init/halt/assert-key lifecycle.**
  `(ns main (:require [integrant.core :as ig]))`. Define a small system with a dependency edge via `#ig/ref` (e.g. `::db` and a `::server` that refs `::db`). Provide `defmethod ig/init-key ::db`, `ig/init-key ::server` (returns a map echoing its resolved `::db` ref), `defmethod ig/halt-key! ::db`/`::server` (print a stop line), and a `defmethod ig/assert-key ::server` that throws via `ig/ex-info`-style check when a required config value is missing. Build config either with `ig/read-string` (`#ig/ref` tag) or a literal map using `(ig/ref ::db)`. Call `(ig/init config)` (printing init order), then `(ig/halt! system)` (printing reverse order), and demonstrate `assert-key` catching a bad value in a `try`. Guard the entry with `(when-not *compiling-aot* (-main))` per the AOT gotcha if a `-main` is used; a top-level script body is also fine.

- [ ] **Step 3: Run directly (fast loop).**
  Ensure integrant is cached: `cd examples/clojure-libs/with-integrant && LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/worktrees/lgx/integrant-compat/bin/lgx install`
  Run: `LG_READ_CLJ=1 /Users/andrew/Projects/let-go/lg -source-paths "<dependency-cache-src>:<integrant-cache-src>" main.lg`
  Expected: init prints `::db` before `::server` (dependency order); halt prints reverse; assert-key demo reports the caught assertion.

- [ ] **Step 4: Run through lgx (faithful path).**
  Run: `cd examples/clojure-libs/with-integrant && LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/worktrees/lgx/integrant-compat/bin/lgx run main.lg`
  Expected: identical output. Debug any runtime gap (e.g. hierarchy/`derive`/`isa?` or `sorted-set-by` comparator path) here; add the corresponding let-go fix + test back in Task 4 if a new gap appears, then re-run.

- [ ] **Step 5: Commit** (this repo)
  `git add -A && git commit -m "feat(examples): integrant init/halt/assert-key under let-go"`
  (New example dir `examples/clojure-libs/with-integrant/` must be staged with `git add -A`.)

### Task 6: Phase 2 docs + full green

**Files:**
- Create: `docs/issues/integrant-dependency-compat.md`
- Modify: `docs/knowledge-base/let-go-stdlib-quick-ref.md`, `docs/issues/clojure-lib-compat.md`, `docs/issues/README.md`

- [ ] **Step 1: Write the upstream issue note.**
  `docs/issues/integrant-dependency-compat.md`: summarize G1–G5, each with repro, the let-go change, and the resolved/degraded status — matching the style of `letgo-clj-support.md` and `clojure-lib-compat.md`. List it in `docs/issues/README.md`.

- [ ] **Step 2: Refresh stdlib/knowledge-base docs.**
  Add `find-var`, `get-method`, and the real queue to `let-go-stdlib-quick-ref.md`; note the defrecord field-scope behavior where relevant. Keep `Verify against:` footers accurate.

- [ ] **Step 3: Full test runs, both repos.**
  Run: `cd /Users/andrew/Projects/let-go && set -o pipefail && make test 2>&1 | tail -15`
  Run: `cd /Users/andrew/Projects/worktrees/lgx/integrant-compat && set -o pipefail && make test 2>&1 | tail -15`
  Expected: both exit 0 and green (`set -o pipefail` so a failure isn't masked by `tail`).

- [ ] **Step 4: Commit** (this repo)
  `git add -A && git commit -m "docs: integrant + dependency let-go compatibility"`

---

## Notes for the executor

- **Rebuild `lg` after every Go change** (`make build` in the let-go repo) — the examples run against `/Users/andrew/Projects/let-go/lg`.
- **Two repos, two commit streams** — let-go changes commit in `/Users/andrew/Projects/let-go` (branch `integrant-compat`); example/doc changes commit here.
- **Fast inner loop:** `LG_READ_CLJ=1 lg -source-paths <src> <file>` (dependency/integrant sources live under `~/.lgx/gitlibs/github.com/weavejester/<lib>/1.0.1/src`). Use lgx only for the faithful end-to-end check.
- **DRY/YAGNI:** G1 must reuse the existing `-dt-rewrite*` traversal (don't duplicate the shadowing logic); G2's `conj`/`into`/`seq`/`count` must come from interface conformance, not new type-switch cases.
- If loading integrant surfaces an unresolved symbol not in G1–G5, treat it as a new sub-gap: add the smallest let-go fix + a `.lg`/Go test, then continue — don't work around it in the example.
