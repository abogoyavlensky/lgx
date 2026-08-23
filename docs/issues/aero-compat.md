# Issue: run juxt/aero under let-go

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status: implemented (2026-08-23).** aero 1.1.6 loads and runs under let-go.
`examples/clojure-libs/with-aero` resolves a real `config.edn` — every tag
(`#env #or #long #double #boolean #keyword #join #ref #merge #read-edn #envf
#profile`) — both directly and through lgx.

**Verified against JVM aero**, not just "it printed something": the same
`config.edn` read by aero 1.1.6 on Clojure 1.12 and by aero on let-go produces
**byte-identical** output under `:default`, `:prod` and `:test`.

Shipped as twelve reviewable PRs against `nooga/let-go` (branches `aero/g*`),
each with tests, each keeping `make test` and the 6311-assertion
`clojure-compat-report` green. Where behaviour was in question, the expected
value was taken from JVM Clojure rather than assumed.

Two gaps remain open, both recorded below: `#include` (G4, needs a real
`java.io.File`) and reading `^:meta` back out of printed EDN.

## Summary

Making [`juxt/aero`](https://github.com/juxt/aero) 1.1.6 load and run under
let-go (via lgx) surfaces a larger surface than the previous single-`.cljc`
libraries, because aero is not "data in, data out" — it is a small **reader +
expansion engine**. It:

1. reads the EDN config with a `:default` handler so every `#tag value` becomes
   a **tagged literal** (tag + form preserved), then
2. walks that tagged-literal tree, dispatching each tag through two
   multimethods (`reader` and `eval-tagged-literal`) to produce the final value.

That design means aero leans on machinery let-go had never exercised: a real
`clojure.lang.TaggedLiteral`, `edn/read` with `:readers`/`:default`/`:eof`,
metadata-carrying seqs, and syntax-quote/destructuring corners. The gaps below
were found the reliable way — by running the library under a patched `lg` and
reading the first error each time, not by static reading.

aero is four namespaces (`aero.core`, `aero.alpha.core`, `aero.impl.walk`,
`aero.impl.macro`), one `.cljc` each, no runtime deps beyond `clojure.edn` and
`clojure.java.io`. Worked repro once the fixes land:

```
LGX_LG=/path/to/let-go/lg lgx run examples/clojure-libs/with-aero/main.lg
```

The gaps split into three buckets: **(A) loading** — aero's four namespaces must
compile; **(B) expansion** — the engine must resolve tags correctly; **(C)
reading** — `read-config` must turn an EDN file into the tagged-literal tree.

---

## A. Loading gaps (aero's namespaces must compile)

### G1 — `clojure.java.io` is not aliased to `io`

`aero.core` does `(:require [clojure.java.io :as io])`. let-go maps
`clojure.edn`→`edn`, `clojure.string`→`string`, etc., but has no
`clojure.java.io` entry, so the require fails and blocks the whole namespace:

```
CompileError: unable to load namespace clojure.java.io
```

**Fix (`pkg/rt/lang.go`):** add `"clojure.java.io": "io"` to `nsAliases`.
One line. (let-go's `io` ns already provides `reader`/`resource`/`slurp`.)

### G2 — interface markers `IMapEntry` / `IRecord` / `IObj` don't resolve

`aero.impl.walk` branches on host interfaces to walk records and reattach
metadata:

```clojure
(instance? clojure.lang.IMapEntry form)
(instance? clojure.lang.IRecord form)
(instance? clojure.lang.IObj x)
```

let-go registers `IEditableCollection`, `Seqable`, etc. as instance-testable
symbols but not these three, so the file won't compile:

```
Can't resolve clojure.lang.IMapEntry in this context
```

**Fix (`pkg/rt/lang.go`, `pkg/rt/hierarchy.go`):** register the three symbols in
`installClojureCompatAliases` (like the existing markers), and wire their
ancestry in `directTypeParents`: `IRecord` + `IObj` onto the `*vm.RecordType`
case; `IObj` onto the metadata-bearing collection cases (vector/map/list/set).
`IMapEntry` can register with no ancestry — in let-go a map entry **is** an
`ArrayVector`, so it correctly falls through aero's `IMapEntry` branch to the
`coll?` branch (which produces the identical walk result).

### G3 — `Long/parseLong`, `Double/parseDouble`, `Boolean/parseBoolean` missing

The `#long`/`#double`/`#boolean` reader methods call the JVM statics directly
(`(Long/parseLong (str value))`). let-go has `parse-long`/`parse-double` but not
the `Long`/`Double`/`Boolean` classes, so `aero.core` won't compile:

```
Can't resolve Long/parseLong in this context
```

**Fix (new `pkg/rt/*.go` installer):** register `Long`/`Double`/`Boolean` as
namespaces with `parseLong`/`parseDouble`/`parseBoolean` vars, exactly like the
existing `System` ns (`pkg/rt/system.go`) provides `System/getenv`. Trivial.

### G4 — `io/file` + a minimal `java.io.File` surface (only for `#include`)

aero's include resolvers use `(io/file …)` and call `.isAbsolute`/`.getParent`/
`.exists` on the result, with a `java.io.StringReader` fallback for a missing
include. let-go's `io` ns has no `file`:

```
Can't resolve io/file in this context
```

**Fix (`pkg/rt/ions.go`):** add `io/file` returning a file handle that answers
`.isAbsolute`/`.getParent`/`.exists` (method dispatch is runtime, so only
`io/file` itself must resolve to compile). Needed only for `#include`; keep the
example off `#include` until this lands (see G5).

### G5 — `StringReader.` / `LineNumberingPushbackReader.` constructors missing

`aero.core` imports `(java.io StringReader)` and wraps its reader:
`(-> source io/reader clojure.lang.LineNumberingPushbackReader.)`. The
`(Foo. …)` form compiles to `->Foo`, and neither `->StringReader` nor
`->clojure.lang.LineNumberingPushbackReader` resolves:

```
Can't resolve ->StringReader in this context
```

**Fix (`pkg/rt/lang.go`):** mirror the `java.util.ArrayList` load-stub
precedent. `LineNumberingPushbackReader.` should be a **real passthrough** over
the `io/reader` it wraps (so `edn/read` can consume it) that also answers
`.getLineNumber` (used only in aero's error path — a stub returning `-1` is
fine). `StringReader.` can be a load-only marker until `#include` is wired.

---

## B. Expansion gaps (found by running — the engine must resolve tags)

These are the interesting ones: aero's four namespaces can be made to **load**
with A alone, but the expansion engine then produces wrong values or crashes.
None are visible from static reading.

### G6 — no real `TaggedLiteral` type

let-go has a stub `(defn tagged-literal? [_] false)` and **no** `tagged-literal`
constructor or value type (`pkg/rt/core/core.lg`). aero's entire pipeline is
built on tagged literals: it constructs them (`(tagged-literal tag form)`),
tests them (`tagged-literal?`), reads their parts (`(:tag tl)`, `(:form tl)`),
and critically relies on `(map? tl)` being **false** (the `expand` dispatch
treats a tagged literal as a scalar, not a collection).

**Fix (`pkg/vm/*.go` + `pkg/rt/lang.go` + `pkg/rt/core/core.lg`):** a real
`TaggedLiteral` value type implementing `Value` + `Lookup` (`:tag`→tag,
`:form`→form), printing as `#tag form`; a `tagged-literal` constructor; register
the type so `(instance? clojure.lang.TaggedLiteral x)` resolves; rewrite the
`tagged-literal?` stub to `(instance? clojure.lang.TaggedLiteral x)`. Also add
`*data-readers*` (empty dynamic map) and `default-data-readers` — aero merges
them into its reader map (`(merge default-data-readers *data-readers*)`).
**Validated:** with this type in place, `tagged-literal?`/`:tag`/`:form`/`map?`
all behave correctly.

### G7 — `(ClassName/STATIC_FIELD)` in call position tries to invoke the field

aero's queue helper is `(into (clojure.lang.PersistentQueue/EMPTY) xs)` — a
**parenthesized** static-field access, valid Clojure (like `(Math/PI)`). let-go
resolves `clojure.lang.PersistentQueue/EMPTY` to the empty-queue value, then —
because it is in call position — tries to *invoke* it:

```
TypeError: clojure.lang.PersistentQueue is not a function
```

This fires inside `expand-coll`, so **every** collection in a config hits it.

**Fix (`pkg/compiler/compiler.go`) — validated:** in the call-compilation path,
when the head is a namespaced symbol resolving to a **non-`Fn`** var value and
there are **zero** args, emit the value instead of an invoke. Matches Clojure's
static-field-in-call-position semantics; `(Math/PI)` etc. also start working.

### G8 — syntax-quote doesn't qualify an unresolvable / self-referential symbol

aero's `reassemble` stores a fn in metadata under a syntax-quoted key and reads
it back:

```clojure
;; kv-seq (defined AFTER reassemble):  {`reassemble (fn …)}
;; reassemble (self-reference):        ((get (meta this) `reassemble) …)
```

let-go's syntax-quote only namespace-qualifies a bare symbol **if it is already
defined** in the current ns (`pkg/compiler/reader.go`, comment: "Only qualify if
symbol is defined in current namespace's local registry"). So the key stored by
`kv-seq` (reassemble already defined → `aero.alpha.core/reassemble`) and the key
read by `reassemble` (self-reference, not-yet-defined → bare `reassemble`)
**don't match** → `get` returns nil:

```
TypeError: nil is not a function   (at reassemble)
```

Clojure always qualifies a non-special, unresolvable bare symbol to the current
ns. Isolated repro:

```clojure
(defn self [] `self)   ; let-go: `self`  (bug)     Clojure: `user/self`
(defn other [] `self)  ; let-go: `user/self`       Clojure: `user/self`
```

**Fix (`pkg/compiler/reader.go`) — validated:** qualify to the current ns when
the symbol is defined locally **or** does not resolve anywhere (symbols that
resolve via refers, e.g. `clojure.core` fns, still fall through unqualified).
Must exclude the contextual keywords `catch`/`finally`/`&` (not in
`specialForms`, handled inside `tryCompiler`) or `with-open` breaks — a sign
this fix needs the full `make test` suite as a guard; there may be more
contextual symbols to exempt.

### G9 — `:keys` destructuring ignores a namespaced entry

aero destructures results with namespaced keys throughout, e.g.
`{:keys [:aero.core/value :aero.core/incomplete?]}`. let-go's `destructure-map`
(`pkg/rt/core/core.lg`) takes the lookup namespace from the **directive** key
(`:keys` → no namespace) instead of the **entry**, so
`{:keys [aero.core/value]}` looks up `:value`, not `:aero.core/value`, and binds
`nil`. This silently zeroes every expanded value (`{:a 42}` → `{:a nil}`), so
`resolve-tagged-literals` returns `nil`.

Isolated repro: `(let [{:keys [foo/bar]} {:foo/bar 7}] bar)` → `nil` (should be
`7`).

**Fix (`pkg/rt/core/core.lg`) — validated:** in the `:keys`/`:syms` expansion,
take the lookup namespace from the entry symbol when it is namespaced, falling
back to the directive's namespace. Plain `{:keys [x]}` and the namespaced
directive `{:foo/keys [bar]}` keep working.

### G10 — seqs / lazy-seqs don't carry metadata through `with-meta`

For **non-map** collections, `kv-seq` returns
`(with-meta (map-indexed …) {`reassemble …})` — `with-meta` on a lazy seq. In
let-go that metadata is dropped (`(meta (with-meta (map-indexed …) {…}))` →
`nil`; `(instance? clojure.lang.IObj <lazyseq>)` → `false`), so `reassemble`
can't find its fn and non-map values crash the same way as G8:

```
TypeError: nil is not a function   (for a vector/list/set value, or #ref/#merge)
```

Maps are unaffected (their `kv-seq` branch uses `(with-meta (into [] x) {…})` —
a vector, which does carry metadata).

**Fix (`pkg/vm/*.go`):** make let-go's seq types (`LazySeq`/`Cons`/`List`)
implement `IMeta` + `with-meta` (carry a metadata map, like vectors/maps
already do). This is the one remaining gap needed for **`#ref`, `#merge`, and
any vector/list/set value** — the headline `#ref` feature depends on it. Not yet
prototyped; deeper than the others.

---

## C. Reading gap (turn an EDN file into the tagged-literal tree)

### G11 — `edn/read` with `:readers`/`:default`/`:eof`, and reader tag dispatch

This is the largest piece. `read-config-into-tagged-literal` calls:

```clojure
(edn/read {:eof nil
           :readers (into {} (map (fn [[k v]] [k #(tagged-literal k %)])
                                  (merge default-data-readers *data-readers*)))
           :default tagged-literal}
          pr)
```

let-go's `edn` ns has only `read-string` (no `read`), and the compiler's reader
**discards** unknown tags (`readTaggedLiteral` in `pkg/compiler/reader.go`
returns the bare value "best-effort" for anything but `#uuid`/`#inst`). aero
needs the opposite: every `#tag value` routed through `:readers`/`:default` to
produce a `TaggedLiteral`.

```
Can't resolve edn/read in this context
```

**Fix (`pkg/compiler/reader.go` + `pkg/rt/edn.lg`/`pkg/rt/*.go`):** an `edn/read`
that reads one form from a reader (or string) via the existing `LispReader`, but
with a **data-reader hook**: when the reader hits `#tag value`, consult the
`:readers` map (by tag symbol) / `*data-readers*`, else call `:default` with
`(tag value)`, honoring `:eof`. Produce real `TaggedLiteral`s (G6). This is the
gate for reading a config **from a file at all** — without it aero can only run
on a hand-built tagged-literal tree (which is how the engine below was
validated).

---

## D. Minor

### G12 — `format` `%s` on a numeric arg leaks Go semantics

`(format "%s" 42)` → `"%!s(int=42)"` (Go `fmt` treats `%s` specially). Clojure's
`format` renders any object with `%s`. aero only hits this on error paths
(`"Config error on line %s"` with an int line number) and `#envf` pre-stringifies
its args, so it does not block the happy path — but it is a real, general bug.

**Fix (`pkg/rt/*.go`):** map Clojure `%s` to Go `%v` (or stringify args) so
`%s` renders numbers.

---

## Validation

Everything above was found by patching a throwaway branch and running aero under
`lg`, fixing the first error each pass. With G1–G9 in place (plus a real
`TaggedLiteral` for G6 and a resolving stub for G11), aero's **expansion engine
resolves a map+scalar config end-to-end**, driving `resolve-tagged-literals` on
a hand-built tagged-literal tree:

```clojure
;; #env #or #long #double #boolean #keyword #profile — all correct:
{:b true, :n 42, :prof "is-dev", :port 8080, :kw :abc,
 :home "/home/...", :d 3.14}
;; with {:profile :prod}: :prof => "is-prod"   (profile dispatch works)
```

## What shipped

| Gap | Fix | Branch |
|---|---|---|
| G1 | `clojure.java.io` → `io` alias (+ the IR-side mirror) | `aero/g1-io-alias` |
| G2 | `IObj`/`IRecord`/`IMapEntry` markers; `MapEntry` gains `IMeta` | `aero/g2-interface-markers` |
| G3 | `Boolean/parseBoolean` | `aero/g3-parse-boolean` |
| G5 | `LineNumberingPushbackReader.` + `.getLineNumber`; **`with-open` can close a reader at all** | `aero/g5-reader-ctor` |
| G6 | `clojure.lang.TaggedLiteral` type, `tagged-literal(?)`, `*data-readers*` | `aero/g6-tagged-literal` |
| G7 | `(Class/STATIC_FIELD)` in call position, **both backends** | `aero/g7-static-field` |
| G8 | syntax-quote resolves to the **defining** namespace | `aero/g8-syntax-quote` |
| G9 | namespaced `:keys`/`:syms` destructuring | `aero/g9-namespaced-keys` |
| G10 | seqs carry metadata (9 view types + chunks) | `aero/g10-seq-meta` |
| G11 | `edn/read` with `:readers`/`:default`/`:eof`, EDN-strict | `aero/g11-edn-read` |
| G12 | `format` `%s` renders non-string args | `aero/g12-format-s` |
| — | **`seq?` on a map entry**, `io/file`, `StringReader.`, `System/setProperty` | integration commit |

### The one that actually blocked everything

Not on the original list, and not findable gap-by-gap: **a map entry answered
both `vector?` and `seq?` true**. Clojure's `MapEntry` is a vector and reports
`seq?` false. aero's walk checks `seq?` before its collection branch, so every
entry came back as a list and rebuilding the map failed with *"conj! on
transient map expects [key val] pair"* — for **any** map, before a single aero
tag was reached. `builtins.IsSeq` already kept a negative list for exactly this
class of type and `MapEntry` was simply missing from it; a second, duplicated
copy of that switch in `lang.go` was the one actually bound to `seq?`, so the
first fix appeared to do nothing.

Lesson worth keeping: testing each gap in isolation cannot find an
interaction bug. Only loading the real library did.

## Still open

- **G4 `#include`** — needs a real `java.io.File` (`.isAbsolute`,
  `.getParent`, `.exists`, plus `io/reader` coercion). `io/file` now *resolves*
  and throws when called, because an unresolvable symbol is a compile error and
  aero's `#include` resolver is compiled whether or not it is used — without
  that, the library will not load at all. 20 of the 22 remaining failures in
  aero's own suite are this.
- **`^:meta` in EDN** — `read-config` on a printed form with
  `*print-meta*` does not read the metadata back (9 failures).
- **`#inst ^:ref [...]`** — the ref is not resolved before the `inst` reader
  runs (1 failure).

### aero's own test suite

Runnable now, which is the strongest available check:

```
cd <aero-checkout>
lg -source-paths "$AERO/src:$AERO/test" run.lg   # (require 'aero.core-test) (test/run-tests)
```

**28 tests, 7 pass, 9 fail, 22 error** — every remaining failure falls into the
three buckets above. Run it from aero's project root; the suite uses relative
paths like `test/aero/config.edn`.

## What lgx does

- The example lists only `aero` in `lgx.edn` — aero has no runtime deps beyond
  `clojure.edn`/`clojure.java.io` (both let-go builtins after G1).
- lgx exports `LG_READ_CLJ=1` on every spawn, so aero's `:clj` reader-
  conditional branches match.

## Verify against (in [nooga/let-go](https://github.com/nooga/let-go))

- `pkg/rt/lang.go` — `nsAliases` (G1); interface markers + `installClojure
  CompatAliases` (G2); ctor stubs (G5); `TaggedLiteral` registration (G6)
- `pkg/rt/hierarchy.go` — `directTypeParents` marker ancestry (G2)
- `pkg/rt/system.go` — model for the `Long`/`Double`/`Boolean` installer (G3)
- `pkg/rt/ions.go` — `io` ns, `io/file` (G4)
- `pkg/vm/*.go`, `pkg/rt/core/core.lg` — `TaggedLiteral` type + `tagged-literal?`
  (G6); seq `with-meta`/`IMeta` (G10)
- `pkg/compiler/compiler.go` — call-position static-field access (G7)
- `pkg/compiler/reader.go` — `syntaxQuote` qualification (G8); `readTaggedLiteral`
  + `edn/read` dispatch hook (G11)
- `pkg/rt/core/core.lg` — `destructure-map` namespaced `:keys` (G9)
- `pkg/rt/core/edn.lg` — `edn/read` (G11)
