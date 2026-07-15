# juxt/aero on let-go — Compatibility Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make [`juxt/aero`](https://github.com/juxt/aero) 1.1.6 load and run under let-go so `examples/clojure-libs/with-aero` resolves a real `config.edn` (env/profile/ref/merge/coercion reader tags) under lgx.

**Tech Stack:** Go (`pkg/compiler`, `pkg/vm`, `pkg/rt`), let-go Clojure (`pkg/rt/core/*.lg`), the lgx example harness.

**Target repo:** `/Users/andrew/Projects/let-go`, branch `with-aero` (HEAD `91486bc`). **This plan does NOT touch lgx** except the final verify + doc-status steps.

---

## Design

### Why aero is a big surface

aero is not "data in, data out" — it is a small **reader + expansion engine**. `read-config`:

1. reads the EDN with a `:default` handler so every `#tag value` becomes a **tagged literal** (tag + form preserved), then
2. walks that tagged-literal tree, dispatching each tag through two multimethods (`reader`, `eval-tagged-literal`) to the final value.

That exercises machinery let-go had never used: a real `clojure.lang.TaggedLiteral`, `edn/read` with `:readers`/`:default`/`:eof`, metadata-carrying seqs, and syntax-quote / destructuring corners. Every gap here was found by **running aero under a patched `lg` and reading the first error**, and the three general compiler/core fixes plus the map+scalar expansion engine were validated end-to-end. Full gap analysis: `lgx/docs/issues/aero-compat.md`.

### Current state (after the malli/host-compat merge into `with-aero`)

The merge (#510 generic JVM collection interop, #512 HashMap/ArrayDeque, #516 host compile-stubs) **already closed most of gap G3**: `Long/parseLong`, `Double/parseDouble`, `Integer/parseInt`, `Float/parseFloat` exist (`pkg/rt/host_jvm_statics.go:142-145`); `with-open` closes via `close!` on an `LGReader` (generic interop). What remains open (re-probed on `91486bc`): **G1, G2, G3-Boolean, G5, G6, G7, G8, G9, G10, G11, G12**. `#include` (G4) is **explicitly deferred** — it needs a host `File` type + `StringReader` + `io/reader` coercion that the example does not exercise.

### Where each fix lives (`.lg` vs Go)

Default is `.lg` (it lowers to native Go via the self-hosted IR pipeline; per [nooga/let-go #519]); Go is justified per gap below. aero's gaps are mostly compiler / reader / value-type / host-registration — categories that legitimately land in Go — so the thin glue is `.lg` and each Go landing has a reason.

| Gap | Home | Reason |
|---|---|---|
| G9 namespaced `:keys` | `.lg` (`core.lg`) | it is already the `destructure-map` macro |
| `*data-readers*` / `default-data-readers` / `tagged-literal?` | `.lg` (`core.lg`) | plain `def` / `instance?` predicate |
| G5 `LineNumberingPushbackReader.` ctor | `.lg` | ctor stub is `(def ->… identity)` |
| G6 **TaggedLiteral type** | **Go** (`pkg/vm`) | new value type; must be **opaque** — not `IRecord`/`map?`/`seq?` — so aero's `ref-meta-to-tagged-literal` postwalk treats it as `:else` exactly like Clojure's `clojure.lang.TaggedLiteral`; a `.lg` `defrecord` *is* `IRecord` and the walk would descend into it and double-process `:form`. Needs `ILookup` (`:tag`/`:form`), which `.lg` `deftype` cannot emit (#519 item 2). |
| `tagged-literal` ctor | Go builtin | must construct the Go value type |
| G7 static-field-in-call-position | Go (`compiler.go`) | compiler runs before `.lg` loads |
| G8 syntax-quote qualification | Go (`reader.go`) | reader/compiler |
| G10 seq metadata | Go (`pkg/vm`) | extends existing vm seq types' interface impls |
| G11 `edn/read` + tag dispatch | Go reader + thin `.lg` entry | inline tag dispatch must live in the Go `LispReader` |
| G1 `clojure.java.io`→`io` | Go (`lang.go`) | namespace-alias resolution table |
| G2 `IMapEntry`/`IRecord`/`IObj` markers | Go (`lang.go` + `hierarchy.go`) | `instance?` / host-class registration |
| G3 `Boolean/parseBoolean` | Go (`host_jvm_statics.go`) | host static-method table (extends the merged block) |
| G12 `format` `%s` | Go | fix the existing `format` primitive |

### Key correctness note (G6)

TaggedLiteral **must be opaque** to aero's record-walk. The earlier end-to-end validation drove `resolve-tagged-literals` on a hand-built tree, which bypassed `ref-meta-to-tagged-literal`; a `.lg` `defrecord` would quietly diverge there (postwalk would descend into the record and reprocess `:form`). Hence the Go value type, mirroring `clojure.lang.TaggedLiteral`: a plain 2-field value that answers `:tag`/`:form` and nothing else — `record?`/`map?`/`seq?`/`vector?` all false.

### G8 risk

The syntax-quote fix (qualify a bare symbol to the current ns when it is defined-locally **or** unresolvable-anywhere) is a general correctness fix but touches every macro-expansion. It already required exempting `catch`/`finally`/`&` (contextual keywords not in `specialForms`). Treat the full `make test` suite as the guard; expect to possibly exempt a few more contextual symbols.

### Ordering

General fixes first (smallest, benefit every library, independently landable), then loading shims, then the two subsystems (TaggedLiteral + `edn/read`; seq metadata), then the reader-ctor stub, then end-to-end verify. Each task keeps `make test` green.

### Build / regen rules

- After any **Go** change: rebuild — `go build -ldflags="-s -w -X main.commit=$(git rev-parse --short HEAD)" -o lg .`
- After any **`pkg/rt/core/*.lg`** change: regenerate the bundle first — `go run -tags bootstrap ./cmd/lgbgen` — then rebuild.
- Full test suite: `make test` (runs `go test -count=1 ./test/...`; `test/*.lg` deftests are compiled and run via `(run-tests)` by `test/language_test.go`'s `TestMain`).
- Fast per-gap signal: `LG_READ_CLJ=1 ./lg -e "<form>"`.

### Deferred (not in this plan)

`#include` (G4): `io/file` returning a host `File`, `.isAbsolute`/`.getParent`/`.exists`, real `StringReader`, and `io/reader` coercion for both. Tractable later via the existing `RegisterHostMethod` seam, but the example uses no `#include`, so it is out of scope. Leave the current absence as-is (aero's `#include` reader will fail loudly if ever exercised).

---

## File Structure

**Create:**
- `pkg/vm/tagged_literal.go` — `TaggedLiteral` value type (`{Tag, Form}`) + `TaggedLiteralType`; implements `Value` + `Lookup` (`:tag`/`:form`); opaque (no map/seq/record/IMeta-collection behavior).
- `test/aero_compat_test.lg` — `.lg` deftests covering the **primitives** aero needs (markers, tagged-literal, edn/read, syntax-quote, destructuring, seq-meta, static-field call), wired aero-style but **without loading aero** — the committed suite has no aero on its source path, so it tests the mechanisms, mirroring how `test/integrant_compat_test.go` tests `find-var`/`get-method` and not integrant. The real aero load + config resolution is verified through the lgx example (Task 13).

**Modify (Go):**
- `pkg/compiler/compiler.go` — G7 static-field-in-call-position.
- `pkg/compiler/reader.go` — G8 syntax-quote qualification; G11 `readTaggedLiteral` data-reader dispatch (+ new `LispReader` opts fields).
- `pkg/compiler/eval.go` — G11 install `edn/read` primitive.
- `pkg/vm/cons.go`, `pkg/vm/lazy_seq.go`, `pkg/vm/chunked_seq.go` — G10 `IMeta` (`Meta`/`WithMeta` + `meta` field), mirroring `pkg/vm/list.go`.
- `pkg/rt/lang.go` — G1 alias; G2 marker symbols; G6 register `clojure.lang.TaggedLiteral` + `tagged-literal` builtin; `format` (G12) if it lives here; G5 `.getLineNumber` host-method (or via `register-host-method!`).
- `pkg/rt/hierarchy.go` — G2 `IRecord`/`IObj` ancestry on the record case.
- `pkg/rt/host_jvm_statics.go` — G3 `Boolean/parseBoolean`.

**Modify (`.lg`, needs bundle regen):**
- `pkg/rt/core/core.lg` — G9 `destructure-map`; G6 `tagged-literal?` + `*data-readers*` + `default-data-readers`; G5 `->clojure.lang.LineNumberingPushbackReader` ctor stub.
- `pkg/rt/core/edn.lg` — G11 `read` entry (thin wrapper over the Go primitive).

**Verify (lgx, no code changes):**
- `examples/clojure-libs/with-aero/{main.lg,config.edn,lgx.edn}` — already updated; run it.
- `docs/issues/aero-compat.md`, `docs/knowledge-base/let-go-stdlib-quick-ref.md` — status + new-fn docs.

---

## Task 1: G9 — namespaced `:keys` destructuring (`.lg`)

**Files:** Modify `pkg/rt/core/core.lg`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — in `test/aero_compat_test.lg`, `deftest destructure-namespaced-keys`: assert `(let [{:keys [foo/bar]} {:foo/bar 7}] bar)` = `7`; `(let [{:keys [:a/b :a/c]} {:a/b 1 :a/c 2}] [b c])` = `[1 2]`; and regressions `(let [{:keys [x]} {:x 9}] x)` = `9`, `(let [{:foo/keys [bar]} {:foo/bar 3}] bar)` = `3`.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(let [{:keys [a/b]} {:a/b 7}] (prn b))"` → prints `nil`.
- [ ] **Step 3: Implement** — in `destructure-map`'s `:keys`/`:syms` reducer, take the lookup namespace from the **entry** symbol when it is namespaced, falling back to the directive namespace `dns`. Exact change:
  ```clojure
  ;; add before `lookup`:
  lns (or (when (or (keyword? x) (symbol? x)) (namespace x)) dns)
  ;; then use lns (not dns) in the syms/keyword branches:
  (= kind "syms") (list 'quote (symbol lns (name x)))
  :else            (keyword lns (name x))
  ```
- [ ] **Step 4: Regen + rebuild** — `go run -tags bootstrap ./cmd/lgbgen && go build -ldflags="-s -w -X main.commit=$(git rev-parse --short HEAD)" -o lg .`
- [ ] **Step 5: Verify pass** — the `-e` probe now prints `7`; `make test` green.
- [ ] **Step 6: Commit** — this task **creates** `test/aero_compat_test.lg`, so stage it: `git add test/aero_compat_test.lg && git commit -am "fix(core): namespaced :keys/:syms destructuring keys off the entry namespace"`

## Task 2: G8 — syntax-quote qualifies unresolvable/self-referential symbols (Go)

**Files:** Modify `pkg/compiler/reader.go`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest syntax-quote-qualifies`: define `(defn sq-self [] \`sq-self)` and `(defn sq-other [] \`sq-self)`; assert both return the same fully-qualified symbol and `(= (sq-self) (sq-other))`; assert `\`never-defined-sym` = a symbol whose `namespace` is the current ns.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(do (defn f [] \`f) (prn (namespace (f))))"` → prints `nil` (bare, unqualified).
- [ ] **Step 3: Implement** — in `syntaxQuote` (bare-symbol branch), change the guard so a bare symbol qualifies to the current ns when defined locally **or** unresolvable anywhere, and exempt the contextual keywords:
  ```go
  if ns == vm.NIL && sform != "with-meta" &&
      sform != "catch" && sform != "finally" && sform != "&" {
      cns := rt.CurrentNS.Deref().(*vm.Namespace)
      if cns.LookupLocal(sform) != nil || cns.Lookup(sform) == vm.NIL {
          qualified := vm.Symbol(cns.Name() + "/" + string(sform))
          // ...quote qualified (existing body)
      }
  }
  ```
- [ ] **Step 4: Rebuild** — `go build … -o lg .` (no core.lg change, but this changes how core macros compile → also run `go run -tags bootstrap ./cmd/lgbgen && go build … -o lg .` to recompile the bundle with the new reader).
- [ ] **Step 5: Verify pass** — probe prints the current ns; run **full** `make test` (this is the risky one — if a macro breaks with `Can't resolve <ns>/<contextual-sym>`, add that symbol to the exemption list and re-run).
- [ ] **Step 6: Commit** — `git commit -am "fix(compiler): syntax-quote qualifies unresolvable bare symbols to current ns"`

## Task 3: G7 — `(Class/STATIC_FIELD)` static field access in call position (Go)

**Files:** Modify `pkg/compiler/compiler.go`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest static-field-call-position`: assert `(clojure.lang.PersistentQueue/EMPTY)` returns the empty queue (`= (clojure.lang.PersistentQueue/EMPTY) clojure.lang.PersistentQueue/EMPTY`). **Regression guards** (must still hold — the fix only affects zero-arg calls to *non-fn* vars): a normal qualified fn call still invokes — `(clojure.string/upper-case "x")` = `"X"`; a zero-arg qualified fn call still invokes, not treated as a field — `(clojure.core/newline)` runs. **Accepted edge (document in the commit body):** a 0-arg call to a *non-fn* qualified var (e.g. a user `(def my.ns/m {…})` then `(my.ns/m)`) now returns the value instead of raising an arity/not-a-fn error — a minor divergence from Clojure, the cost of `(Math/PI)`-style access. If `make test` surfaces any real breakage from this, narrow the guard to host-class namespaces (`DefNSBare`-created) rather than all qualified vars.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (clojure.lang.PersistentQueue/EMPTY))"` → `TypeError: clojure.lang.PersistentQueue is not a function`.
- [ ] **Step 3: Implement** — in `compileForm`'s call path (after `argc` is computed, before the fast-opcode/invoke block): when the head is a namespaced symbol resolving to a **non-`vm.Fn`** var value with **zero args**, compile it as a value load instead of an invoke:
  ```go
  if fn.Type() == vm.SymbolType && argc == 0 {
      fsym := fn.(vm.Symbol)
      if sns, _ := fsym.Namespaced(); sns != vm.NIL && !c.resolvesAsLexical(fsym) {
          if v := c.CurrentNS().Lookup(fsym); v != vm.NIL {
              if vr, ok := v.(*vm.Var); ok {
                  if _, isFn := vr.Deref().(vm.Fn); !isFn {
                      if err := c.compileForm(fsym); err != nil { return err }
                      c.tailPosition = tp
                      return nil
                  }
              }
          }
      }
  }
  ```
- [ ] **Step 4: Rebuild** — `go build … -o lg .`
- [ ] **Step 5: Verify pass** — probe prints `#queue ()`; `make test` green.
- [ ] **Step 6: Commit** — `git commit -am "fix(compiler): (Class/STATIC_FIELD) reads the field in call position"`

## Task 4: G12 — `format` `%s` renders non-string args

**Files:** Modify `formatf` (`pkg/rt/lang.go:6921`); Test `test/aero_compat_test.lg`

Aero's need is `%s` on **numbers** (`"Config error on line %s"` with an int). Test numeric args only — avoid the keyword case, whose expected rendering (`:kw` vs `kw`) is a separate, already-shipped behavior this task must not change.

- [ ] **Step 1: Write the failing test** — `deftest format-percent-s`: `(format "%s" 42)` = `"42"`; `(format "%s-%s" 1 2)` = `"1-2"`; `(format "%s" 3.5)` = `"3.5"`; regression `(format "%d" 42)` = `"42"` and `(format "%s" "hi")` = `"hi"`.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (format \"%s\" 42))"` → `"%!s(int=42)"`.
- [ ] **Step 3: Implement** — in `formatf`, make `%s` render a numeric arg via its let-go `str` form (stringify Int/Float args before handing to Sprintf, or map the verb to Go `%v` for non-string args). Do **not** change `%d`/`%f`/`%x`, string, or keyword rendering — only fix `%s` on numbers.
- [ ] **Step 4: Rebuild** — `go build … -o lg .`
- [ ] **Step 5: Verify pass** — probe prints `"42"`; `make test` green.
- [ ] **Step 6: Commit** — `git commit -am "fix(rt): format %s renders non-string args"`

## Task 5: G1 — `clojure.java.io` → `io` namespace alias (Go)

**Files:** Modify `pkg/rt/lang.go`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest clojure-java-io-alias`: `(require '[clojure.java.io :as cjio])` then assert `cjio/reader` and `cjio/resource` resolve (e.g. `(fn? cjio/reader)`).
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(require '[clojure.java.io :as io])"` → `unable to load namespace clojure.java.io`.
- [ ] **Step 3: Implement** — add `"clojure.java.io": "io"` to the `nsAliases` map (`pkg/rt/lang.go`).
- [ ] **Step 4: Rebuild** — `go build … -o lg .`
- [ ] **Step 5: Verify pass** — probe succeeds; `make test` green.
- [ ] **Step 6: Commit** — `git commit -am "feat(rt): alias clojure.java.io to io"`

## Task 6: G3 — `Boolean/parseBoolean` static (Go)

**Files:** Modify `pkg/rt/host_jvm_statics.go`; Test `test/host_jvm_statics_test.go` (or `test/aero_compat_test.lg`)

- [ ] **Step 1: Write the failing test** — assert `(Boolean/parseBoolean "true")` = `true`, `(Boolean/parseBoolean "false")` = `false`, `(Boolean/parseBoolean "TRUE")` = `true` (case-insensitive, matching JVM).
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (Boolean/parseBoolean \"true\"))"` → `Can't resolve Boolean/parseBoolean`.
- [ ] **Step 3: Implement** — beside the `Long/parseLong` block (`host_jvm_statics.go:142-145`), add a `parseBoolean` fn (`strings.EqualFold(s, "true")`) and `defStaticNS("Boolean").Def("parseBoolean", parseBoolean)`.
- [ ] **Step 4: Rebuild** — `go build … -o lg .`
- [ ] **Step 5: Verify pass** — probe prints `true`; `make test` green.
- [ ] **Step 6: Commit** — `git commit -am "feat(rt): add Boolean/parseBoolean static"`

## Task 7: G2 — `IMapEntry` / `IRecord` / `IObj` interface markers (Go)

**Files:** Modify `pkg/rt/lang.go`, `pkg/rt/hierarchy.go`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest interface-markers`: `(instance? clojure.lang.IMapEntry (first {:a 1}))` resolves (value may be `false` — map entries are `ArrayVector`s, which is correct); `(instance? clojure.lang.IRecord (->SomeRecord …))` = `true` and `(instance? clojure.lang.IRecord 1)` = `false`; `(instance? clojure.lang.IObj [1])` resolves. The point is they **resolve** (aero's `aero.impl.walk` must compile) and records answer `IRecord` true.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (instance? clojure.lang.IMapEntry [1 2]))"` → `Can't resolve clojure.lang.IMapEntry`.
- [ ] **Step 3: Implement** — (a) in `installClojureCompatAliases` (`lang.go`), add `"clojure.lang.IMapEntry"`, `"clojure.lang.IRecord"`, `"clojure.lang.IObj"` to the marker-symbol registration list. (b) in `hierarchy.go`: declare `cljIRecord`/`cljIObj` symbols and add both to the `*vm.RecordType` case in `directTypeParents`. Leave `IMapEntry` with no ancestry (map entries are `ArrayVector`s → they fall through aero's `IMapEntry` branch to the `coll?` branch, producing the identical walk result). Consider adding `cljIObj` to the vector/map/list/set cases too so `(instance? IObj coll)` answers true (metadata-bearing) — needed for aero's walk meta-reattachment to behave.
- [ ] **Step 4: Rebuild** — `go build … -o lg .`
- [ ] **Step 5: Verify pass** — probe resolves; `make test` green.
- [ ] **Step 6: Commit** — `git commit -am "feat(rt): register IMapEntry/IRecord/IObj interface markers"`

## Task 8: G10 — seqs carry metadata through `with-meta` (Go)

The types that **lack `WithMeta`** (verified: `grep -L WithMeta` across `pkg/vm`) and thus lose metadata are **`LazySeq`** (`lazy_seq.go` — what `map`/`map-indexed`/`filter` return), **`Cons`** (`cons.go`), **`MapSeq`** (`map.go`), and **`ChunkedCons`** (`chunk.go`). The vector-seqs (`ArrayVectorSeq`/`PersistentVectorSeq`) and `List` already carry meta. **Aero's only need is `LazySeq`** — `kv-seq` does `(with-meta (map-indexed …) {…})`; the others are for general correctness. Note: `(type (map …))` prints `PersistentList` because `type` *realizes* the seq — `with-meta` sees the unrealized `LazySeq`, which is why the meta is lost.

**Files:** Modify `pkg/vm/lazy_seq.go`, `pkg/vm/cons.go`, `pkg/vm/map.go`, `pkg/vm/chunk.go`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest seq-metadata`: **aero-critical** — `(meta (with-meta (map-indexed vector [:a :b]) {:k 1}))` = `{:k 1}`; plus `(map inc [1 2])`, `(filter odd? [1 2 3])` (LazySeq), `(cons 1 [2])` (Cons); `(instance? clojure.lang.IObj (map inc [1]))` = `true`. Do **not** assert `(seq [1 2 3])` (already an `ArrayVectorSeq` with meta) or a nonexistent `ChunkedSeq`.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (meta (with-meta (map-indexed vector [:a :b]) {:k 1})))"` → `nil`.
- [ ] **Step 3a: Cons / MapSeq / ChunkedCons** — add a `meta Value` field + `Meta()`/`WithMeta()` mirroring `pkg/vm/list.go:54-69` (`cp := *l; cp.meta = m; return &cp`). These structs have no mutex, so the shallow copy is safe.
- [ ] **Step 3b: LazySeq (careful)** — `LazySeq` embeds a `sync.Mutex` (`{fn, s, sv, err, mu}`), so **do not `cp := *l`** (copies a mutex; and copying `fn` before realization risks double-running the thunk). Two acceptable representations, pick one and state it in the commit:
  - **(preferred) realize-then-delegate:** `WithMeta(m)` forces the seq (`l.Resolve()` / `l.seq()`) and returns the realized concrete seq with `m` attached (`(realized).WithMeta(m)`). Requires the realized type (`List`/`Cons`) to carry meta — `List` already does, `Cons` gets it in 3a. This is safe and sufficient for aero (`kv-seq` consumes the seq immediately). Trade-off: `with-meta` forces the lazy seq.
  - **(alt) meta field guarded by the existing mutex:** add `meta Value`; `WithMeta` allocates a *new* `LazySeq{fn: l.fn, meta: m}` that shares realization by delegating `First`/`Next`/`Resolve` through `l` (not by copying `mu`/`s`/`sv`). Preserves laziness but is more code.
- [ ] **Step 3c: IObj ancestry** — ensure these types answer `instance? clojure.lang.IObj` true (extend the `IObj` marker ancestry from Task 7 to the seq types, or gate on `vm.IMeta`).
- [ ] **Step 4: Rebuild** — `go build … -o lg .`
- [ ] **Step 5: Verify pass** — probe prints `{:k 1}`; `go test ./pkg/vm/...` and `make test` green (watch for laziness-dependent tests if you chose realize-then-delegate).
- [ ] **Step 6: Commit** — `git commit -am "feat(vm): LazySeq/Cons/MapSeq/ChunkedCons carry metadata (IMeta)"`

## Task 9: G6 — `TaggedLiteral` value type + `tagged-literal`/`?` + data-reader vars

**Files:** Create `pkg/vm/tagged_literal.go`; Modify `pkg/rt/lang.go`, `pkg/rt/core/core.lg`; Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest tagged-literal`: `(tagged-literal? (tagged-literal 'env "PORT"))` = `true`; `(tagged-literal? 1)` = `false`; `(:tag (tagged-literal 'env "PORT"))` = `'env`; `(:form …)` = `"PORT"`; **opaqueness** — `(map? …)` = `false`, `(record? …)` = `false`, `(seq? …)` = `false`, `(vector? …)` = `false`; `(pr-str (tagged-literal 'env "PORT"))` = `"#env \"PORT\""`; `*data-readers*` and `default-data-readers` resolve to maps.
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (tagged-literal 'x 1))"` → `Can't resolve tagged-literal`.
- [ ] **Step 3a: Implement the type** — `pkg/vm/tagged_literal.go`: a `TaggedLiteral struct { Tag, Form Value }` and `TaggedLiteralType` (mirror `pkg/vm/regex.go` boilerplate). Implement `Value` (`String()` → `"#" + Tag + " " + pr(Form)`, `Type()`, `Unbox()`) and `Lookup` (`ValueAt`/`ValueAtOr`: keyword `:tag`→Tag, `:form`→Form, else default). **Do not** implement map/seq/record/collection interfaces — it must stay opaque.
- [ ] **Step 3b: Register + constructor** — in `pkg/rt/lang.go`: `ns.Def("clojure.lang.TaggedLiteral", vm.TaggedLiteralType)` (beside the `PersistentQueue` registration in `installClojureCompatAliases`), and a `tagged-literal` core builtin `(tag form) → &vm.TaggedLiteral{Tag: tag, Form: form}`.
- [ ] **Step 3c: `.lg` glue** — in `pkg/rt/core/core.lg`: replace the `tagged-literal?` stub with `(defn tagged-literal? [x] (instance? clojure.lang.TaggedLiteral x))`; add `(def ^:dynamic *data-readers* {})` and `(def default-data-readers {})`. Both are empty maps: aero merges them into its reader map, and its `:default tagged-literal` handles every tag — the example uses no `#uuid`/`#inst`, so keep these empty (YAGNI). If `#uuid`/`#inst` in a config are wanted later, add `'uuid`/`'inst` entries here that call the reader's existing UUID/instant parsers — a trivial follow-up, out of scope now.
- [ ] **Step 4: Regen + rebuild** — `go run -tags bootstrap ./cmd/lgbgen && go build … -o lg .`
- [ ] **Step 5: Verify pass** — all probes in Step 1 pass; `make test` green.
- [ ] **Step 6: Commit** — `git add pkg/vm/tagged_literal.go && git commit -am "feat(vm,rt): clojure.lang.TaggedLiteral type + tagged-literal(?) + *data-readers*"`

## Task 10: G11 — `edn/read` with `:readers`/`:default`/`:eof` + reader tag dispatch

**Files:** Modify `pkg/compiler/reader.go`, `pkg/compiler/eval.go`, `pkg/rt/core/edn.lg`; Test `test/aero_compat_test.lg`

Depends on Task 9 (produces `TaggedLiteral`s).

- [ ] **Step 1: Write the failing test** — `deftest edn-read`: with a string/reader source `"#env \"PORT\""`, `(edn/read {:default tagged-literal} <reader>)` returns a `TaggedLiteral` with tag `env` form `"PORT"`; `:readers {'env (fn [v] [:got v])}` routes `#env` to that fn; `:eof :end` returns `:end` at end of input; a plain form (`"{:a 1}"`) reads as data. **Sequential-read guard:** from one reader over `"1 2 3"`, three successive `(edn/read {} r)` calls return `1`, `2`, `3` and a fourth with `:eof :done` returns `:done` (proves buffered read-ahead isn't discarded between calls).
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(require '[clojure.edn :as edn]) (prn edn/read)"` → `Can't resolve edn/read`.
- [ ] **Step 3a: Reader dispatch** — in `pkg/compiler/reader.go`: add opts fields to `LispReader` (`dataReaders map[tag]Fn`, `defaultReader Fn`, and an eof sentinel/flag). Change `readTaggedLiteral` to consult them: if `dataReaders[tag]` → call it with the value; else if built-in `uuid`/`inst` (and not overridden) → parse as today; else if `defaultReader` → call it with `(tag, value)`; else current best-effort. Reading with no opts set keeps today's behavior (so `read-string` is unchanged).
- [ ] **Step 3b: `edn/read` primitive (reader reuse!)** — in `pkg/compiler/eval.go` (where `read-string` is installed): a Go fn `(opts, source)` that reads **one** form and returns the `:eof` value at EOF instead of erroring. **The `LispReader` wraps a `bufio.Reader` that reads ahead, so a fresh `LispReader` per call would discard buffered bytes and corrupt the next read** — you must reuse **one** `LispReader` per source across calls: attach it to the source (a field on `rt.LGReader`, which `pkg/compiler` may import) or memoize it in a registry keyed by the source-reader pointer. A bare string source can build a one-shot reader. Set `:readers`/`:default`/`:eof` from `opts` on that reader before each read. Install as `core/-edn-read` (or into the `edn` ns). The sequential-read test in Step 1 is the guard.
- [ ] **Step 3c: `.lg` entry** — in `pkg/rt/core/edn.lg`, replace the stub with `(defn read ([source] (core/-edn-read {} source)) ([opts source] (core/-edn-read opts source)))`.
- [ ] **Step 4: Regen + rebuild** — `go run -tags bootstrap ./cmd/lgbgen && go build … -o lg .`
- [ ] **Step 5: Verify pass** — Step-1 probes pass; `make test` green (confirm `read-string` unaffected).
- [ ] **Step 6: Commit** — `git commit -am "feat(edn): edn/read with :readers/:default/:eof and tagged-literal dispatch"`

## Task 11: G5 — `LineNumberingPushbackReader.` ctor stub + `.getLineNumber`

**Files:** Modify `pkg/rt/core/core.lg` (+ `pkg/rt/lang.go` for `.getLineNumber`); Test `test/aero_compat_test.lg`

- [ ] **Step 1: Write the failing test** — `deftest reader-ctor-stub`: `(clojure.lang.LineNumberingPushbackReader. (io/string-reader "hi"))` returns a reader; `(.getLineNumber <that>)` returns an integer (does not throw).
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(prn (clojure.lang.LineNumberingPushbackReader. :r))"` → `Can't resolve ->clojure.lang.LineNumberingPushbackReader`.
- [ ] **Step 3: Implement** — in `core.lg`: `(def ->clojure.lang.LineNumberingPushbackReader identity)` (the compiler desugars `(Foo. x)` → `(->Foo x)`; the passthrough returns the `LGReader`, which `edn/read` consumes and `with-open`'s `close!` closes via the merged generic interop). For `.getLineNumber` (only hit on aero's read-error path): register a host-method returning `-1` on the reader type — either `register-host-method!` in `.lg` (preferred) or `RegisterHostMethod` in `lang.go` if the type is easier to reference from Go.
- [ ] **Step 4: Regen + rebuild** — `go run -tags bootstrap ./cmd/lgbgen && go build … -o lg .`
- [ ] **Step 5: Verify pass** — probes pass; `make test` green.
- [ ] **Step 6: Commit** — `git commit -am "feat(rt): LineNumberingPushbackReader. passthrough ctor + .getLineNumber"`

## Task 12: Integration — committed primitive suite (no aero dependency)

`make test` runs only in-tree source (`test/language_test.go` compiles `test/*.lg`); it cannot `require` aero. So — exactly like `test/integrant_compat_test.go`, which tests `find-var`/`get-method` and **does not load integrant** — the committed suite asserts the *primitives* aero needs, wired together the way aero wires them. The real aero load + config resolution is verified through the lgx example in Task 13 (which has aero on the source path).

**Files:** finalize `test/aero_compat_test.lg`

- [ ] **Step 1: Compose an aero-shaped primitive test** — `deftest aero-primitives-integration` in `test/aero_compat_test.lg`: build a tagged-literal tree by hand with `tagged-literal` (e.g. `{:port (tagged-literal 'long "8080") :xs (with-meta (map-indexed vector [1 2]) {:from :aero})}`), then exercise the exact mechanisms aero relies on **without loading aero**:
  - the `reassemble` pattern — `(get (meta (with-meta (map-indexed vector [1 2]) {`m (fn [_ q] q)})) `m)` is non-nil (G8 + G10 together);
  - namespaced-key destructuring of an `:aero.core/…`-style map (G9);
  - `(tagged-literal? …)`, `:tag`/`:form`, `(map? …)` false (G6);
  - `edn/read` with `:default tagged-literal` over a small string produces the expected `TaggedLiteral` (G11);
  - `(clojure.lang.PersistentQueue/EMPTY)` in call position (G7).
- [ ] **Step 2: Run** — `make test` → the new deftests pass; whole suite green.
- [ ] **Step 3: Commit** — `git add test/aero_compat_test.lg && git commit -am "test: aero-compat primitives (tagged-literal, edn/read, seq-meta, destructure, static-field)"`

> Note: `test/aero_compat_test.lg` is created in Task 1 and appended to by later tasks; this task finalizes it. The **first** commit that adds the file (Task 1, Step 6) must `git add` it before committing.

## Task 13: End-to-end via the lgx example + docs

This is where aero is actually loaded and a real `config.edn` resolved — the true verification. All files here are in the **lgx** repo.

**Files (lgx repo):** `docs/issues/aero-compat.md`, `docs/knowledge-base/let-go-stdlib-quick-ref.md`

- [ ] **Step 1: Provision aero source** — ensure aero 1.1.6 is fetched to the lgx gitlibs cache: `cd examples/clojure-libs/with-aero && LGX_LG=/Users/andrew/Projects/let-go/lg <lgx-bin> install` (resolves `lgx.edn` deps). The source lands at `~/.lgx/gitlibs/github.com/juxt/aero/1.1.6/src` (`AERO_SRC`). If lgx isn't built yet, `make build` in the lgx repo first.
- [ ] **Step 2: Direct run (fast loop)** — `AERO_SRC=$(echo ~/.lgx/gitlibs/github.com/juxt/aero/1.1.6/src); LG_READ_CLJ=1 /Users/andrew/Projects/let-go/lg -source-paths "$AERO_SRC" examples/clojure-libs/with-aero/main.lg` → resolves the config under `:default` and `:prod`, printing the labeled sections, no `error:` output. This is the real proof aero loads and every tag (`#env #or #long #double #boolean #keyword #join #ref #merge #read-edn #envf #profile`) resolves.
- [ ] **Step 3: Through lgx (faithful)** — `cd examples/clojure-libs/with-aero && LGX_LG=/Users/andrew/Projects/let-go/lg <lgx-bin> run main.lg`. Output must match Step 2.
- [ ] **Step 4: Docs (lgx knowledge-base)** — add the new fns/behaviors (`edn/read`, `tagged-literal`/`tagged-literal?`, `Boolean/parseBoolean`, seq metadata, `clojure.java.io` alias) to `docs/knowledge-base/let-go-stdlib-quick-ref.md`; keep each `Verify against:` footer accurate.
- [ ] **Step 5: Docs (lgx issue status)** — flip `docs/issues/aero-compat.md` status to implemented; correct G3 (mostly pre-closed by the malli/host-compat merge — only `Boolean/parseBoolean` was added here) and the `#include` deferral; list the shipped let-go commits.
- [ ] **Step 6: Commit (lgx)** — `git commit -am "docs: aero runs under let-go; update quick-ref + issue status"`

---

## Done when

- `make test` is green in let-go with the new `test/aero_compat_test.lg` (primitive suite) passing.
- `examples/clojure-libs/with-aero` resolves `config.edn` under `:default` and `:prod` both directly and through lgx, with `#env #or #long #double #boolean #keyword #profile #join #ref #merge #read-edn #envf` all working.
- `#include` remains deferred (fails loudly if used); docs reflect status.
