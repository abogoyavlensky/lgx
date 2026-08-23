# juxt/aero on let-go — Compatibility Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make [`juxt/aero`](https://github.com/juxt/aero) 1.1.6 load and run under let-go so aero is usable in real let-go programs, with `examples/clojure-libs/with-aero` resolving a real `config.edn` (env/profile/ref/merge/coercion reader tags) under lgx as the proof.

**Tech Stack:** Go (`pkg/compiler`, `pkg/vm`, `pkg/rt`), let-go Clojure (`pkg/rt/core/*.lg`), the lgx example harness.

**Target repo:** `/Users/andrew/Projects/let-go`, a **fresh branch off current `main`**. **This plan does NOT touch lgx** except the final verify + doc-status steps.

---

> ## Revision 2026-08-22 — re-verified against `main` @ `d270802`
>
> The original plan (2026-07-15) was written against `91486bc` and never
> executed: the `with-aero` branch still points at exactly that commit, which
> has since been absorbed into `main` by unrelated work. **Zero tasks were
> done.** `main` has advanced ~120 commits since (24 of them IR/lowering).
>
> **The gap analysis survived re-probing intact.** All twelve gaps still fail on
> `d270802`, each reproducing the exact symptom the plan predicted — `(format
> "%s" 42)` → `"%!s(int=42)"`, the syntax-quote / namespaced-`:keys` / seq-meta
> probes → `nil`, `(clojure.lang.PersistentQueue/EMPTY)` → "is not a function".
> The task *designs* are still the right ones.
>
> **What rotted is the mechanics.** Corrections are inline below and marked
> `[2026-08-22]`. The load-bearing ones:
>
> 1. **The build/regen rules were wrong and would ship red CI** — see the
>    superseding contract in "Build / regen rules", which now replaces the
>    per-task "Regen + rebuild" steps wholesale.
> 2. **Two backends.** `*ir-compile-strict*` landed since. Compiler/resolution
>    fixes need the IR builder (`pkg/rt/core/ir/build.lg`) considered, or they
>    silently fail to apply under `*ir-compile*`. This bit an unrelated PR
>    (nooga/let-go#756) after review caught it. Concretely for this plan: the
>    `nsAliases` table (G1) is **mirrored** at
>    `pkg/rt/core/ir/passes/purity.lg:396`.
> 3. **G10's scope is larger than written** — the vector seqs lack `WithMeta`
>    too. Verified two ways (probe + grep); see Task 8.
> 4. **Primitive registration changed** (`feat(rt): hoist 222 clojure.core
>    primitives to named //lg:native decls`, #639). New builtins are declared
>    with `//lg:native` / `//lg:name` markers and picked up by a generated
>    registrar, not hand-written `ns.Def` calls.
> 5. Two claims in the original encoded **prototype knowledge as fact** and did
>    not hold on re-check (the G8 exemption list; G10's scope). Treat any
>    remaining unverified claim the same way — re-probe before trusting.
>
> **Relationship to the six open HoneySQL PRs** (nooga/let-go#754, #756, #758,
> #760, #762, #764): **no overlap, no blocker.** They touch no file this plan
> touches, and aero's source and test suite use none of the constructs they fix
> (no `thrown?`, no `#'ns/private`, no `reify`). They are based 2 commits behind
> `main`, so they neither conflict with nor gate this work. The one incidental
> benefit is #764 (insertion-ordered small maps): an aero-resolved config will
> print in `config.edn` order rather than scrambled, which makes the example's
> output readable — cosmetic, not required.

---

## Design

### Why aero is a big surface

aero is not "data in, data out" — it is a small **reader + expansion engine**. `read-config`:

1. reads the EDN with a `:default` handler so every `#tag value` becomes a **tagged literal** (tag + form preserved), then
2. walks that tagged-literal tree, dispatching each tag through two multimethods (`reader`, `eval-tagged-literal`) to the final value.

That exercises machinery let-go had never used: a real `clojure.lang.TaggedLiteral`, `edn/read` with `:readers`/`:default`/`:eof`, metadata-carrying seqs, and syntax-quote / destructuring corners. Every gap here was found by **running aero under a patched `lg` and reading the first error**, and the three general compiler/core fixes plus the map+scalar expansion engine were validated end-to-end. Full gap analysis: `lgx/docs/issues/aero-compat.md`.

### Current state `[2026-08-22 — re-probed on main @ d270802]`

The malli/host-compat merge (#510 generic JVM collection interop, #512
HashMap/ArrayDeque, #516 host compile-stubs) **already closed most of gap G3**:
`Long/parseLong`, `Double/parseDouble`, `Integer/parseInt`, `Float/parseFloat`
exist (`pkg/rt/host_jvm_statics.go:142-145` — anchor still exact); `with-open`
closes via `close!` on an `LGReader` (generic interop).

Still open, each re-verified by running it: **G1, G2, G3-Boolean, G5, G6, G7,
G8, G9, G10, G11, G12**. `#include` (G4) stays **explicitly deferred** — it
needs a host `File` type + `StringReader` + `io/reader` coercion the example
does not exercise.

Adjacent capabilities that *do* exist, which narrow three gaps usefully:

| Probe | Result | Bearing |
|---|---|---|
| `(edn/read-string "{:a 1}")` | `{:a 1}` | the `edn` ns is real; G11 is only "no `read` with opts", not "no edn" |
| `(read-string "#uuid \"…\"")` | a UUID | built-in tag dispatch works; G11 extends it rather than inventing it |
| `(read-string "#env \"PORT\"")` | `"PORT"` | unknown tags silently **drop the tag** and return the payload — the exact hole G6 fills |
| `(meta (with-meta (list 1 2) {:k 1}))` | `{:k 1}` | `List` carries meta; it is the *only* seq type that does (see Task 8) |
| `(ns t (:import [clojure.lang PersistentQueue]))` | accepted | `:import` is **not** a gap — relevant because aero's test ns imports `aero.core.Deferred` |

**`tagged-literal?` is a silent lie today.** `pkg/rt/core/core.lg:1985-1988` is
`(defn tagged-literal? [_] false)` with a comment admitting there is no
TaggedLiteral type. aero calls it, so on current `main` aero gets a *wrong
answer* rather than a loud failure. Task 9 replaces it; if this plan is ever
shelved mid-way, that stub is worth making throw instead (the house rule is
that a stub which fails loudly beats one that plausibly lies).

**Verifying with aero's own test suite.** aero ships
`test/aero/core_test.cljc` — 251 lines, 28 `deftest`s, 49 `is` forms, one
`are`, one `testing`. Running it under `lg` is the strongest available proof
and is worth doing after Task 13 (see the note there). It needs **G1**, since
its `ns` form requires `clojure.java.io`; it uses no `thrown?`, so it does not
depend on the in-flight clojure.test work.

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

The syntax-quote fix (qualify a bare symbol to the current ns when it is defined-locally **or** unresolvable-anywhere) is a general correctness fix but touches every macro-expansion. Treat the full `make test` suite as the guard; expect to exempt some contextual symbols.

> `[2026-08-22]` The original said this "already required exempting
> `catch`/`finally`/`&`". That was **prototype knowledge from the throwaway
> branch and is not in the tree** — today's guard at
> `pkg/compiler/reader.go:899` exempts only `with-meta` and checks only
> `cns.LookupLocal(sform) != nil`:
> ```go
> if ns == vm.NIL && sform != "with-meta" {
>     cns := rt.CurrentNS.Deref().(*vm.Namespace)
>     if cns.LookupLocal(sform) != nil {
> ```
> `catch`/`finally`/`&` are also absent from `specialForms`
> (`pkg/compiler/compiler.go:927-936`, which holds only
> `if do def set! fn* quote var let* loop* recur try`), so the special-form
> escape at `reader.go:876` does not cover them either. Treat the exemption
> list as a **hypothesis to re-derive under `make test`**, not a known
> quantity. Also see "Two backends" — verify under `*ir-compile-strict*`.

### Ordering

General fixes first (smallest, benefit every library, independently landable), then loading shims, then the two subsystems (TaggedLiteral + `edn/read`; seq metadata), then the reader-ctor stub, then end-to-end verify. Each task keeps `make test` green.

### Build / regen rules `[2026-08-22 — REWRITTEN; supersedes every task's "Regen + rebuild" step]`

The original rules here were incomplete in a way that ships red CI, and every
task below inherited them. **Ignore the per-task rebuild commands and use
this contract instead.**

- **Build:** `make build` (promotes to `bin/lg`; the old `go build -o lg .`
  bypasses generation). `make build` can mtime-skip regeneration after a branch
  switch — when in doubt, `make generate` forces it.
- **After *any* change that will be committed — Go or `.lg`:** run
  `make generate`, then **commit all three tracked generated artifacts**:
  `pkg/rt/core_compiled.lgb`, `pkg/rt/generated.manifest`,
  `pkg/rt/generated.sums`. This is **not** an `.lg`-only concern, which is the
  trap the old rule set: 87 `pkg/vm/*.go` files plus `pkg/compiler/` and
  `pkg/bytecode/` are registered as bundle *generators*, so a one-file Go
  change stales the manifest exactly as an `.lg` edit does. Nearly every task
  in this plan touches one of those directories.
  (`pkg/rt/core_go_lowered/` is gitignored — regenerated, never committed.)
- **The gate:** `make check-generated`. CI runs it; **`make test` does not
  cover it**. The local loop that actually proves a change is clean is
  `make test && make check-generated`.
- **Full test suite:** `make test`. (Correction: `test/*.lg` files are
  discovered and run per-file by `TestRunner` in `test/language_test.go`, each
  inside a clean dynamic-binding scope — not by a `TestMain`. Any new
  `test/*.lg` file is picked up automatically; a single-segment ns resolves to
  a sibling file in `test/`, which is how a two-namespace fixture is built.)
- **Semantics changes:** for anything touching core data structures or
  evaluation semantics, `make clojure-compat-report` (the jank
  clojure-test-suite corpus) is the honest regression check — the README quotes
  its pass count.
- **Fast per-gap signal:** `LG_READ_CLJ=1 bin/lg -e "<form>"`. Note `-e` echoes
  the form's return value after any printed output, so read the second-to-last
  line, not the last.

### Two backends `[2026-08-22 — new]`

let-go compiles through the bytecode compiler (`pkg/compiler/`) **and** a
self-hosted IR builder (`pkg/rt/core/ir/build.lg`), which implement resolution
and special-form behavior separately. A fix to one often needs its mirror in
the other, or the gap merely moves: under `*ir-compile*` the IR path either
throws (strict mode) or silently falls back to bytecode, so the fix looks
complete while quietly not applying, and tests on the default path do not
notice.

Tasks affected: **Task 2 (G8 syntax-quote)** and **Task 3 (G7 static field in
call position)** are compiler changes — grep `ir/build.lg` for the same form
before declaring either done, and gate with
`(binding [*ir-compile* true *ir-compile-strict* true] …)`. **Task 5 (G1
alias)** looks like a one-line map edit but the `nsAliases` table is
**mirrored** at `pkg/rt/core/ir/passes/purity.lg:396` — update both or the
backends disagree about what `clojure.java.io` resolves to.

### PR structure `[2026-08-22 — new]`

Land this as **independent PRs, smallest-risk first**, not one 13-task branch.
The six HoneySQL PRs showed the maintainer reviews each one closely (building
at the PR head, with babashka as a Clojure oracle), and a single branch
spanning compiler + reader + vm + rt + core.lg is not reviewably sized.

Suggested tranches, each independently valuable even if the next never lands:

- **T1 — general wins, no aero dependency:** Tasks 1 (G9), 4 (G12), 5 (G1),
  6 (G3), 7 (G2). Five small PRs; every one is a general Clojure-compat fix.
- **T2 — seq metadata:** Task 8 (G10), after re-deriving its scope.
- **T3 — the reader/compiler subsystem:** Tasks 2 (G8), 3 (G7), 9 (G6),
  10 (G11), 11 (G5). This is where aero actually starts working, and where the
  design risk is concentrated.

G8 (Task 2) deserves separate thought before T3: it changes every
macroexpansion, and review of nooga/let-go#754 surfaced a *second*
syntax-quote divergence (auto-gensyms are scoped per-macroexpansion rather
than per-syntax-quote-form, so a nested syntax-quote reuses the outer symbol
where JVM Clojure generates a fresh one). Those two are plausibly one
syntax-quote-semantics workstream and worth raising with the maintainer
before implementing either.

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

## Task 1: G9 — namespaced `:keys` destructuring (`.lg`) ✅

**Branch:** `aero/g9-namespaced-keys` · **Commit:** `62fe6b8`

**Files:** Modify `pkg/rt/core/core.lg`; Test `test/destructure_namespaced_keys_test.lg`

> Deviation: tests live in `test/destructure_namespaced_keys_test.lg`, not a
> shared `test/aero_compat_test.lg`. The plan's single-file design would make
> every PR in this series conflict in that one file; per-topic test files also
> match the repo's existing convention (190 such files). Task 12 still creates
> `test/aero_compat_test.lg` on the integration branch for the aero-shaped
> composite suite.

> Deviation: the per-task "Regen + rebuild" commands are superseded by the
> "Build / regen rules" contract (`make build` / `make generate` /
> `make test && make check-generated`), as that section instructs.

> Environment note (not a plan deviation): `mise` declares no `go` version for
> this repo, so the `go` shim fails and `make build` dies. Builds here prepend
> `~/.local/share/mise/installs/go/1.26.6/bin` to `PATH`. The user's global mise
> config was left untouched.

- [x] **Step 1: Write the failing test** — `deftest keys-entry-namespace`, `keys-entry-namespace-mixed`, `syms-entry-namespace`, `namespaced-keys-regressions`, `entry-namespace-beats-directive-namespace`. Covers the plan's four assertions plus `:or` defaults, `:as`, `:strs`, mixed namespaced/plain entries, and entry-beats-directive precedence.
- [x] **Step 2: Verify it fails** — `LG_READ_CLJ=1 bin/lg -e "(let [{:keys [a/b]} {:a/b 7}] (prn b))"` → printed `nil`.
- [x] **Step 3: Implement** — in `destructure-map`'s `:keys`/`:syms` reducer, take the lookup namespace from the **entry** symbol when it is namespaced, falling back to the directive namespace `dns`. Exact change:
  ```clojure
  ;; add before `lookup`:
  lns (or (when (or (keyword? x) (symbol? x)) (namespace x)) dns)
  ;; then use lns (not dns) in the syms/keyword branches:
  (= kind "syms") (list 'quote (symbol lns (name x)))
  :else            (keyword lns (name x))
  ```
- [x] **Step 4: Regen + rebuild** — `make build`, `make generate` (per the Build/regen contract).
- [x] **Step 5: Verify pass** — probe prints `7`; `make test` green; `make check-generated` OK.
- [x] **Step 6: Commit** — `62fe6b8`.
- [x] **Codex review** — clean, no findings ("correctly derives lookup namespaces from qualified :keys/:syms entries while preserving existing plain and directive-qualified behavior").

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

## Task 3: G7 — `(Class/STATIC_FIELD)` static field access in call position (Go) ✅

**Branch:** `aero/g7-static-field` · **Commit:** `6c627e9`

> **The plan's "Two backends" warning fired, exactly as written — and my first
> IR test was worthless.** Codex round 3 (P1): the fix was bytecode-only, so a
> `defn` body compiled under `*ir-compile*` still raised "is not a function".
> My IR test had wrapped a top-level `eval` in `(binding [*ir-compile* true] …)`,
> which **stays on the bytecode path and proves nothing**.
>
> Two things worth carrying forward for any future compiler work here:
> - The way to actually exercise the IR path is a **top-level `defn` after
>   `(require 'ir.passes.pipeline)` and `(set! *ir-compile* true)`**, or to
>   drive `ir.build/build-fn` directly. `binding` + `eval` does not do it.
>   (Separately, `eval`-ing a `defn` *or* a `require` under `*ir-compile-strict*`
>   fails on `main` too — a pre-existing limitation, easy to mistake for your
>   own bug. Always control-test against a `main`-built binary.)
> - The fix now lives in **one** place, `rt.IsHostStaticFieldRef`, called from
>   both `compileForm` and `ir/build.lg`'s `build-call`, so the backends cannot
>   drift. Duplicating the rule in both would have been the obvious move and the
>   wrong one.
>
> Also ran `make ir-stress-gate` (2505/2516, baseline unchanged) since this
> touches the IR builder — a gate the plan does not mention but should.

> **The plan's "accepted edge" was not acceptable, and the plan's own fallback
> was taken.** The plan proposed gating on "resolves to a non-`vm.Fn` var" and
> accepting that `(my.ns/some-scalar)` would silently return the value; it also
> said to "narrow the guard to host-class namespaces if `make test` surfaces
> breakage". `make test` did not, but codex flagged it P1 with a second reason
> I had missed: gating on the *current root* bakes a compile-time decision into
> a var that may later be redefined or dynamically bound to a function.
>
> So the guard is namespace-gated. Two refinements followed:
> 1. `DefNSBare` turned out **not** to be a usable marker — it also creates
>    ordinary user namespaces. Added an explicit `MarkHostStaticNS` registry,
>    called from `defStaticNS` and the five `DefNSBare` host-class sites.
> 2. Codex round 2: gating on the symbol's textual qualifier breaks under
>    aliasing — `(:require [foo.core :as Boolean])` would make
>    `(Boolean/answer)` look like a host static read. Now gated on the
>    **resolved var's own namespace**. Verified the alias case raises.
>
> Note the plan's fear that this affects "every qualified non-fn var" was
> overstated in one respect: maps, sets, keywords and vectors all implement
> `vm.Fn`, so they never matched the original guard either.
>
> Pre-existing quirk found while testing, not introduced here: calling a
> non-invokable *scalar* raises a `TypeError` that escapes `catch`, on `main`
> too. That case is therefore verified by hand rather than asserted.

### Original task text

## Task 3 (original): G7 — `(Class/STATIC_FIELD)` static field access in call position (Go)

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

## Task 4: G12 — `format` `%s` renders non-string args ✅

**Branch:** `aero/g12-format-s` · **Commit:** `d7165a9`

**Files:** Modify `CoreFormatf` (`pkg/rt/lang.go:6629` — anchor exact); Test `test/format_percent_s_test.lg`

Aero's need is `%s` on **numbers** (`"Config error on line %s"` with an int).

> Deviation: scope widened from "numbers only" to **all `%s` args**, routed
> through `strValue` (the helper `clojure.core/str` already uses) with `nil`
> special-cased to `"null"`. Two rounds got here:
>
> 1. First attempt enumerated the broken types (`Int`/`Float`/`Boolean`/
>    `Char`/`nil`). Codex review caught that `Float32` (from `(float 1.5)`)
>    and `BigDecimal` still emitted `%!s(float64=1.5)` / `%!s(*big.Float=1.5)`.
> 2. Enumeration is the wrong shape — the next type added would silently
>    regress. `strValue` was then measured against JVM Clojure's `%s` across
>    the whole tower and agrees on **every** type except `nil` (`""` vs
>    `"null"`), so it replaced the enumeration wholesale.
>
> Consequence the plan explicitly wanted avoided: keyword rendering changes
> (`kw` → `:kw`). It is kept because the Clojure oracle says `:kw` is correct
> and `kw` is the bug; list rendering likewise moves `[1 2]` → `(1 2)`. Both
> are called out in the commit body. `make test` is green, so nothing in-tree
> depended on the old rendering.
>
> 3. Round-2 codex review then caught that `strValue` regressed **UUID**:
>    `Unbox()` gave the bare canonical form (Java's `UUID.toString`, what
>    Clojure prints), `strValue` gives the readable `#uuid "..."`. Rather than
>    guess at the rest, a main-built baseline binary was diffed against the
>    fixed one and against the Clojure oracle across 22 values — UUID was the
>    **only** regression. Special-cased alongside `nil`.
>
> Two pre-existing divergences are documented in the commit body but left
> alone: a regex renders `#"a.c"` where Clojure gives `a.c`, and `(str uuid)`
> still gives the readable form (only `%s` is corrected, so `str` and `%s`
> now disagree on UUID — worth a follow-up PR against `strValue`).
>
> Every expectation was verified against JVM Clojure (`clojure -M -e`) before
> being asserted.

- [x] **Step 1: Write the failing test** — `deftest format-percent-s-numbers`, `format-percent-s-other-scalars`, `format-percent-s-mixed-with-other-verbs`, `format-regressions` (covers `%d`, `%.2f`, width/flags `%4s`/`%-4s`, literal `%%`, string args, collection args, no-arg format strings).
- [x] **Step 2: Verify it fails** — probe printed `"%!s(int=42)"`.
- [x] **Step 3: Implement** — handle `%s` ahead of the coercion switch in `CoreFormatf`, rendering from the let-go value rather than its unboxed Go form.
- [x] **Step 4: Rebuild** — `make build`.
- [x] **Step 5: Verify pass** — all 18 probes match the Clojure oracle; `make test` green; `make check-generated` OK; `golangci-lint ./pkg/rt` 0 issues.
- [x] **Step 6: Commit** — `88b989e`.

## Task 5: G1 — `clojure.java.io` → `io` namespace alias (Go) ✅

**Branch:** `aero/g1-io-alias` · **Commit:** `4b5761f`

**Files:** Modify `pkg/rt/lang.go`, `pkg/rt/core/ir/passes/purity.lg`; Test `test/clojure_java_io_alias_test.lg`

- [x] **Step 1: Write the failing test** — `deftest clojure-java-io-requires`, `clojure-java-io-is-the-io-namespace` (asserts both names reach the *same var*, not two copies), `clojure-java-io-runtime-use`.
- [x] **Step 2: Verify it fails** — probe printed `unable to load namespace clojure.java.io`.
- [x] **Step 3: Implement** — `"clojure.java.io": "io"` in `nsAliases`, **plus its mirror** `"io" "clojure.java.io"` in `ns-canonical-aliases` (`ir/passes/purity.lg:409`), as the plan's "Two backends" section requires.
- [x] **Step 4: Rebuild** — `make build`.
- [x] **Step 5: Verify pass** — probe succeeds; `make test` green; `make check-generated` OK. Confirmed the aliased var also resolves under `*ir-compile-strict*`. (`require` *inside* `eval` under IR-strict fails, but it fails identically on `main` with `clojure.string` — a pre-existing limitation, not this change.)
- [x] **Step 6: Commit** — `4b5761f`.

## Task 6: G3 — `Boolean/parseBoolean` static (Go) ✅

**Branch:** `aero/g3-parse-boolean` · **Commit:** `41ffc54`

**Files:** Modify `pkg/rt/host_jvm_statics.go`; Test `test/boolean_parse_boolean_test.lg`

- [x] **Step 1: Write the failing test** — `deftest parse-boolean-true-cases`, `parse-boolean-false-cases`, `parse-boolean-returns-real-booleans`, `boolean-ns-still-carries-type`.
- [x] **Step 2: Verify it fails** — probe printed `Can't resolve Boolean/parseBoolean`.
- [x] **Step 3: Implement** — `parseBoolean` beside the `Long/parseLong` block; `defStaticNS("Boolean").Def(...)`. **The registration-home question is resolved:** `defStaticNS` and `DefNSBare` both look up `nsRegistry` first, so `defStaticNS("Boolean")` returns the *same* namespace `lang.go:4675` created for `Boolean/TYPE` — it adds a member rather than displacing one. Pinned by a test asserting `Boolean/TYPE` still resolves. (Also needed a `strings` import.)
- [x] **Step 4: Rebuild** — `make build`.
- [x] **Step 5: Verify pass** — all 8 cases match the JVM oracle exactly, including `nil` → `false` (JVM `parseBoolean(null)` is false, not a throw) and `" true"` → `false`; `make test` green; `make check-generated` OK.
- [x] **Step 6: Commit** — `41ffc54`.

## Task 7: G2 — `IMapEntry` / `IRecord` / `IObj` interface markers (Go) ✅

**Branch:** `aero/g2-interface-markers` · **Commit:** `621c6af`

> Codex round 3 raised a fourth would-be false positive (`vm.Map`, which has no
> `WithMeta`). **Refuted with evidence:** `vm.Map` implements `vm.Fn` (maps are
> invokable), so `CoreWithMeta` takes its `MetaFn` branch — metadata
> round-trips, and the wrapped value still answers `map?`/`get`/`=`/`count`/
> `keys` correctly. Verified across nine map-producing forms and pinned by
> `map-metadata-goes-through-the-fn-wrapper`. No change made.

**Files:** Modify `pkg/rt/lang.go`, `pkg/rt/hierarchy.go`; Test `test/interface_markers_test.lg`

- [x] **Step 1: Write the failing test** — `deftest iobj-true-for-metadata-bearing-types`, `iobj-false-for-scalars`, `iobj-agrees-with-with-meta`, `irecord`, `imapentry-resolves-and-is-false`, `markers-do-not-disturb-existing-ancestry`.
- [x] **Step 2: Verify it fails** — all four of `IMapEntry`/`IRecord`/`IObj`/`IMeta` printed `Can't resolve …`.
- [x] **Step 3: Implement** — markers added to the registration list in `installClojureCompatAliases`; `cljIObj`/`cljIRecord` declared and wired in `directTypeParents`. The plan's "consider" is taken: `IObj` covers vector, map, sorted map, set, sorted set, list/sequence, queue, record.
- [x] **Step 4: Rebuild** — `make build`.
- [x] **Step 5: Verify pass** — `make test` green; `make check-generated` OK; **`make clojure-compat-report` 6311/6311 (100%), unchanged** — run because this touches type ancestry, which is evaluation semantics.
- [x] **Step 6: Commit** — `afbeba9`.

**The governing rule this task settled on:** `IObj` must never be a *false
positive*. A caller that trusts the marker and copies metadata must not lose it
silently; a false negative is merely conservative. Three codex rounds all
turned on this, and the invariant is now a test over 27 values.

> Deviation: `IObj` also covers **all three function types** (`Fn`,
> `NativeFn`, `MultiFn`). The oracle says `(instance? IObj inc)` is true on the
> JVM, and let-go fns — including builtins like `+`/`println` and `defmulti`
> values — do round-trip `with-meta`.

> Deviation (round 3, beyond the plan's file list): **`MapEntry` gains
> `Meta`/`WithMeta`** in `pkg/vm/persistent_map.go`. Codex found that a map
> entry reports `ArrayVectorType` and satisfies `vector?`, but the struct
> implemented no `IMeta` — so `with-meta` silently dropped metadata on it, and
> any marker keyed on `ArrayVectorType` was false-positive for exactly those
> values. Rather than drop vectors from `IObj` (which would gut the common
> case), the root cause is fixed: `MapEntry.WithMeta` now mirrors
> `ArrayVector.WithMeta`, yielding a metadata-carrying `PersistentVector`.
> More permissive than the JVM, where this throws `ClassCastException`.

> Deviation: **seqs are deliberately excluded from `IObj`**, though Clojure says
> they are. `PersistentList` is the reported type for both real lists (carry
> metadata) and `Cons`/`LazySeq`/`MapSeq`/`ArrayVectorSeq` (drop it), so a
> type-level marker cannot be honest for all values of that type. **This is a
> hard ordering constraint the plan did not anticipate: Task 8 (G10) must land
> before seqs can join `IObj`,** and Task 8's Step 3c should add them.

> Known divergence, pinned by tests: a **map entry** answers `IMapEntry` false
> where the JVM says true. No type can answer it without claiming every vector
> is a map entry. An `IMapEntry` branch falls through to the `coll?`/`vector?`
> branch beside it for the same result — the behaviour the plan predicted for
> aero's walk.

## Task 8: G10 — seqs carry metadata through `with-meta` (Go) ✅

**Branch:** `aero/g10-seq-meta` (stacked on `aero/g2-interface-markers`) · **Commit:** `6df8c66`

> **Three codex rounds, each finding a real defect:**
> 1. `TypedArraySeq` (a *no-op* `WithMeta` stub), `ArrayChunk` and `ChunkBuffer`
>    also report `ListType` → three more `IObj` false positives. Fixed, and a
>    35-value sweep test now guards the invariant.
> 2. `ChunkBuffer` is **mutable** (`Append` writes through `vs`), so the shallow
>    copy aliased the backing array and two buffers could overwrite each other.
>    `WithMeta` now copies the storage. Also: `LazySeq`'s allocation attribution
>    hardcoded 64 bytes and my extra field made it stale — now derived via
>    `unsafe.Sizeof`.
> 3. `LazySeq.WithMeta` reset observable `realized?` state. **This one overturned
>    my design.** Checking JVM Clojure showed `LazySeq.withMeta` is
>    `new LazySeq(meta, seq())` — it *realizes*, and `realized?` is true for
>    both afterwards. My "don't force it" reasoning (and the test asserting it)
>    were wrong: realization is incremental, so forcing the head never hangs.
>    The plan's "preferred: realize-then-delegate" was right after all, and my
>    reason for rejecting it — "it would hang on infinite seqs" — was false.

> **Scope re-derived, and it is larger than either version of the plan said.**
> Nine seq view types lack `WithMeta`, not four: `Cons`, `LazySeq`, `MapSeq`,
> `ChunkedCons` (the plan's list) **plus** `ArrayVectorSeq`,
> `PersistentVectorSeq`, `SetSeq`, `SortedMapSeq`, `SortedSetSeq`. All nine had
> to be done together, because **every one of them reports `ListType`** — so
> leaving any behind keeps `ListType` a mix of metadata carriers and droppers,
> which is exactly what blocked Task 7 from marking it `IObj`. Verified by
> enumerating `) First() Value` and `) WithMeta(` across `pkg/vm`.
>
> `MapSeq`'s anchor is `map.go:110`, not `map.go:110` as a struct with a
> `meta` slot — it had none. The `chunk.go:112` anchor for `ChunkedCons` was
> exact.
>
> **LazySeq:** neither of the plan's two options was used. Realize-then-delegate
> (the plan's "preferred") is wrong — it makes `(with-meta (iterate inc 1) m)`
> hang forever. The alt (delegating shell) is close to what shipped, but
> simpler: `WithMeta` returns a fresh `LazySeq` whose *thunk yields the
> original*, so realization happens once in the original and is shared, no
> mutex is copied, and the concrete type stays `*LazySeq`. Tests assert
> `with-meta` does not force the seq and that an unbounded seq survives it.
>
> Also completes **Task 7's deferred Step 3c**: `ListType`/`SequenceType` now
> answer `IObj`.
>
> Out of scope, documented and pinned by a test: `Range`, `Repeat` and
> `Iterate` still drop metadata. They report their own types, are not claimed
> as `IObj`, and so stay self-consistent.

- [x] **Step 1: Write the failing test** — `test/seq_metadata_test.lg`: 8 deftests covering lazy seqs, cons, every collection seq view, laziness preservation, non-destructiveness, and nil defaults.
- [x] **Step 2: Verify it fails** — the `map-indexed` probe printed `nil`.
- [x] **Step 3: Implement** — as above.
- [x] **Step 5: Verify pass** — `go test ./pkg/vm/...` green; `make test` green; `make check-generated` OK; **`make clojure-compat-report` 6311/6311, unchanged**.
- [x] **Step 6: Commit** — `a0785b9`.

### Original task text

## Task 8 (original): G10 — seqs carry metadata through `with-meta` (Go)

The types that **lack `WithMeta`** and thus lose metadata are **`LazySeq`**
(`lazy_seq.go:16` — what `map`/`map-indexed`/`filter` return), **`Cons`**
(`cons.go:12`), **`MapSeq`** (`map.go:110`), and **`ChunkedCons`**
(`chunk.go:112`). **Aero's only need is `LazySeq`** — `kv-seq` does
`(with-meta (map-indexed …) {…})`; the others are for general correctness.
Note: `(type (map …))` prints `PersistentList` because `type` *realizes* the
seq — `with-meta` sees the unrealized `LazySeq`, which is why the meta is lost.

> `[2026-08-22 — SCOPE CORRECTION, re-derive before implementing]` The original
> claim that "the vector-seqs (`ArrayVectorSeq`/`PersistentVectorSeq`) and
> `List` already carry meta" is **false on `main`**. Verified two ways:
> `(meta (with-meta (seq [1 2]) {:k 1}))` returns `nil`, and neither vector-seq
> type appears among the types that implement `WithMeta`. Only **`List`**
> (`list.go:62`) carries meta among the seq types.
>
> The full set implementing `WithMeta` today is: `Atom`, `DTypeInstance`,
> `ExInfo`, `Func`/`Closure`/`MultiArityFn`, `MetaValue`/`MetaFn`, `List`,
> `NativeFn`, `MultiFn`, `PersistentVector`, `PersistentMap`, `PersistentSet`,
> `PersistentQueue`, `Record`, `Set`/`SetWithMeta`, `Protocol`/`ProtocolFn`,
> `SortedMap`, `SortedSet`, `TypedArray`/`TypedArraySeq` (both no-ops),
> `ArrayVector`. Re-derive the seq list against the tree at implementation time
> rather than trusting either version of this paragraph, and decide explicitly
> whether the vector-seqs are in scope for this task or a follow-up — aero does
> not need them, but `(with-meta (seq v) m)` silently dropping metadata is a
> general correctness bug worth its own PR.
>
> Note also that `pkg/vm/map.go` (`MapSeq`) is being restructured by
> nooga/let-go#764; if that lands first, re-check the anchor.

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
- [ ] **Step 3c: `.lg` glue** — in `pkg/rt/core/core.lg`: replace the `tagged-literal?` stub at `:1985-1988` — currently `(defn tagged-literal? [_] false)`, a hardcoded wrong answer aero actually calls — with `(defn tagged-literal? [x] (instance? clojure.lang.TaggedLiteral x))`; add `(def ^:dynamic *data-readers* {})` and `(def default-data-readers {})`. Both are empty maps: aero merges them into its reader map, and its `:default tagged-literal` handles every tag — the example uses no `#uuid`/`#inst`, so keep these empty (YAGNI). If `#uuid`/`#inst` in a config are wanted later, add `'uuid`/`'inst` entries here that call the reader's existing UUID/instant parsers — a trivial follow-up, out of scope now.
- [ ] **Step 4: Regen + rebuild** — `go run -tags bootstrap ./cmd/lgbgen && go build … -o lg .`
- [ ] **Step 5: Verify pass** — all probes in Step 1 pass; `make test` green.
- [ ] **Step 6: Commit** — `git add pkg/vm/tagged_literal.go && git commit -am "feat(vm,rt): clojure.lang.TaggedLiteral type + tagged-literal(?) + *data-readers*"`

## Task 10: G11 — `edn/read` with `:readers`/`:default`/`:eof` + reader tag dispatch

**Files:** Modify `pkg/compiler/reader.go`, `pkg/compiler/eval.go`, `pkg/rt/core/edn.lg`; Test `test/aero_compat_test.lg`

Depends on Task 9 (produces `TaggedLiteral`s).

- [ ] **Step 1: Write the failing test** — `deftest edn-read`: with a string/reader source `"#env \"PORT\""`, `(edn/read {:default tagged-literal} <reader>)` returns a `TaggedLiteral` with tag `env` form `"PORT"`; `:readers {'env (fn [v] [:got v])}` routes `#env` to that fn; `:eof :end` returns `:end` at end of input; a plain form (`"{:a 1}"`) reads as data. **Sequential-read guard:** from one reader over `"1 2 3"`, three successive `(edn/read {} r)` calls return `1`, `2`, `3` and a fourth with `:eof :done` returns `:done` (proves buffered read-ahead isn't discarded between calls).
- [ ] **Step 2: Verify it fails** — `LG_READ_CLJ=1 ./lg -e "(require '[clojure.edn :as edn]) (prn edn/read)"` → `Can't resolve edn/read`.
- [ ] **Step 3a: Reader dispatch** — in `pkg/compiler/reader.go`: add opts fields to `LispReader` (`dataReaders map[tag]Fn`, `defaultReader Fn`, and an eof sentinel/flag). `[2026-08-22]` Anchors confirmed: `readTaggedLiteral` is at `reader.go:1503` (dispatched from `:1494`), hardcodes only `uuid`/`inst`, and its `default:` branch silently returns the value **un-tagged** — that silent tag-drop is the observable bug (`(read-string "#env \"PORT\"")` → `"PORT"`). `LispReader` (`reader.go:45-59`) currently has no opts fields at all: `inputName, pos, line, column, lastCol, lastRune, maxPercent, inShortFn, r, Tokens, tokenizing, splicing`. Change `readTaggedLiteral` to consult the new fields: if `dataReaders[tag]` → call it with the value; else if built-in `uuid`/`inst` (and not overridden) → parse as today; else if `defaultReader` → call it with `(tag, value)`; else current best-effort. Reading with no opts set keeps today's behavior (so `read-string` is unchanged).
- [ ] **Step 3b: `edn/read` primitive (reader reuse!)** — in `pkg/compiler/eval.go` (where `read-string` is installed): a Go fn `(opts, source)` that reads **one** form and returns the `:eof` value at EOF instead of erroring. **The `LispReader` wraps a `bufio.Reader` that reads ahead, so a fresh `LispReader` per call would discard buffered bytes and corrupt the next read** — you must reuse **one** `LispReader` per source across calls: attach it to the source (a field on `rt.LGReader`, which `pkg/compiler` may import) or memoize it in a registry keyed by the source-reader pointer. A bare string source can build a one-shot reader. Set `:readers`/`:default`/`:eof` from `opts` on that reader before each read. Install as `core/-edn-read` (or into the `edn` ns). The sequential-read test in Step 1 is the guard.
- [ ] **Step 3c: `.lg` entry** — in `pkg/rt/core/edn.lg`, add `(defn read ([source] (core/-edn-read {} source)) ([opts source] (core/-edn-read opts source)))`. `[2026-08-22]` There is **no stub to replace** — `edn.lg` is 28 lines holding only the ns form, `read-string` (single-arity, delegating to `core/read-string`), `write-string`, `deep-sort`, and `pretty`. `read` is a new definition, and `read-string` gains no opts arity here.
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
- [ ] **Step 3b: Run aero's own test suite** `[2026-08-22 — new]` — the strongest available proof, and cheap once aero loads. Write a throwaway runner (not committed) and put aero's `src` **and** `test` on the source path:
  ```clojure
  ;; .tmp/aero-suite.lg
  (require 'test)
  (require 'aero.core-test)
  (test/run-tests)
  ```
  ```
  LG_READ_CLJ=1 <lg> -source-paths "$AERO_SRC:$AERO_ROOT/test" .tmp/aero-suite.lg
  ```
  The suite is 251 lines / 28 deftests / 49 assertions. It needs **G1** (its ns
  requires `clojure.java.io`) and `:import` (already supported); it uses no
  `thrown?`. Judge from the printed `Tests: … Pass: … Fail: … Error: …` summary,
  not the exit code, and use the no-arg `(test/run-tests)` — the
  explicit-namespaces arity is currently broken upstream (it calls `name` on a
  Namespace object). Record the counts; any failure is a fresh gap to triage
  with a minimal repro rather than a reason to stop.

- [ ] **Step 4: Docs (lgx knowledge-base)** — add the new fns/behaviors (`edn/read`, `tagged-literal`/`tagged-literal?`, `Boolean/parseBoolean`, seq metadata, `clojure.java.io` alias) to `docs/knowledge-base/let-go-stdlib-quick-ref.md`; keep each `Verify against:` footer accurate.
- [ ] **Step 5: Docs (lgx issue status)** — flip `docs/issues/aero-compat.md` status to implemented; correct G3 (mostly pre-closed by the malli/host-compat merge — only `Boolean/parseBoolean` was added here) and the `#include` deferral; list the shipped let-go commits.
- [ ] **Step 6: Commit (lgx)** — `git commit -am "docs: aero runs under let-go; update quick-ref + issue status"`

---

---

# COMPLETED 2026-08-23

**aero 1.1.6 loads and runs under let-go.** The example resolves a real
`config.edn` — every tag — directly and through lgx, with identical output.

**The proof is stronger than the plan asked for:** the same `config.edn` read
by aero on JVM Clojure 1.12 and by aero on let-go produces **byte-identical**
output under `:default`, `:prod` and `:test`. Throughout, expected values were
taken from JVM Clojure (`clojure -M -e`) rather than assumed.

## Shipped as 12 reviewable PR branches (the requested split)

| Branch | Head | Gap |
|---|---|---|
| `aero/g9-namespaced-keys` | `62fe6b8` | G9 destructuring |
| `aero/g12-format-s` | `ce7936d` | G12 `format` `%s` |
| `aero/g1-io-alias` | `4b5761f` | G1 `clojure.java.io` |
| `aero/g3-parse-boolean` | `e669929` | G3 `Boolean/parseBoolean` |
| `aero/g2-interface-markers` | `621c6af` | G2 markers |
| `aero/g10-seq-meta` | `6df8c66` | G10 seq metadata (on g2) |
| `aero/g7-static-field` | `6c627e9` | G7 static field |
| `aero/g6-tagged-literal` | `9b3b7cc` | G6 TaggedLiteral |
| `aero/g11-edn-read` | `8cda75d` | G11 `edn/read` (on g6) |
| `aero/g5-reader-ctor` | `2749019` | G5 reader ctor + `with-open` |
| `aero/g8-syntax-quote` | `460fb7c` | G8 syntax-quote |
| `aero/integration` | `9538198` | all merged + the four gaps only integration found |

Every branch: own tests, `make test` green, `make check-generated` OK,
`clojure-compat-report` 6311/6311 unchanged, `golangci-lint` clean. Compiler
and vm changes additionally ran `make ir-stress-gate` (2505/2516, baseline).

Each task went through `review-with-codex` — 20 rounds total. **Codex found a
real defect in 9 of the 12**, several of them P1. That checkpoint earned its
cost and should not be skipped.

## What the plan got wrong

1. **G8's design was insufficient.** The plan's rule ("qualify to current ns
   when defined-locally or unresolvable") would have left aero broken: aero
   writes `` `reassemble `` through a `:refer`, which is neither. The actual
   Clojure rule is *resolve, then qualify to the defining namespace*.
2. **The blocking bug was not on the list.** `seq?` answered true for a map
   entry, so aero's walk turned every entry into a list and rebuilding any map
   failed — before a single tag was reached. No per-gap branch could have found
   it; only loading the library did.
3. **G4 `#include` could not simply be "left as-is".** The plan assumed an
   absent `io/file` would "fail loudly if ever exercised". An unresolvable
   symbol is a *compile* error, so aero would not load at all. It needs a
   resolving-but-throwing stub.
4. **G5 was bigger than a ctor stub.** `with-open` could not close a reader at
   all (`close!` knew only channels and IOHandles), and `slurp` + `with-open`
   double-closes, which Go's `os.File.Close` rejects.
5. **The "two backends" warning fired exactly as written** (G7), and my first
   IR test was worthless — `binding` + `eval` stays on the bytecode path.
6. **G10's scope was 9 seq types, not 4**, plus `TypedArraySeq`/`ArrayChunk`/
   `ChunkBuffer`; and its "preferred" LazySeq approach was right for a reason
   the plan got backwards (realization is incremental, so forcing never hangs).

## What the plan could have specified better

Two things would have saved the most time:

- **"Load the library first, then fix what breaks."** The gap list was
  accurate but incomplete, and the missing item (`seq?` on map entries) was
  the one that blocked everything. An early "just try to load it" step would
  have surfaced it on day one instead of after eleven tasks.
- **A worked example of exercising the IR backend.** The plan correctly warned
  about two backends but not *how* to test the second one; the obvious method
  is silently wrong, and `eval`-under-strict fails on `main` too, which is easy
  to mistake for your own bug. Always control-test against a `main`-built
  binary.

Minor: the plan's per-task "Regen + rebuild" commands were already known stale,
but `make build` can also mtime-skip regeneration — a reader change needs
`make generate` or the bundle keeps stale macroexpansions and tests fail for
reasons unrelated to the code.

## Still open (recorded in docs/issues/aero-compat.md)

- G4 `#include` — needs a real `java.io.File`. 20 of 22 remaining failures in
  aero's own suite.
- `^:meta` in printed EDN not read back (9 failures).
- `#inst ^:ref [...]` — ref not resolved before the inst reader (1 failure).

aero's own suite: **28 tests, 7 pass, 9 fail, 22 error**, every failure in one
of those three buckets.

---

## Done when

- `make test` is green in let-go with the new `test/aero_compat_test.lg` (primitive suite) passing.
- `examples/clojure-libs/with-aero` resolves `config.edn` under `:default` and `:prod` both directly and through lgx, with `#env #or #long #double #boolean #keyword #profile #join #ref #merge #read-edn #envf` all working.
- `#include` remains deferred (fails loudly if used); docs reflect status.
