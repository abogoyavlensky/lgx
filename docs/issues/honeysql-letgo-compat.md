# Issue: run seancorfield/honeysql under let-go

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** implemented on the local `host-compat/string-and-builder` branch

## Summary

Making [`seancorfield/honeysql`](https://github.com/seancorfield/honeysql)
v2.7.1437 load and run under let-go (via lgx) surfaced six gaps, all in JVM
host-interop: honeysql's `:clj` reader-conditional branches lean on
`java.lang.String` methods, `StringBuilder`, `clojure.lang.Keyword` accessors,
and `java.util.Locale` for performance and correctness fast paths. The gaps are
version-independent (v2.6 has the same fast paths). Each fix is additive and
ships with a test (`test/host_string_interop_test.go`).

An earlier honeysql porting round produced upstream PRs
[#754](https://github.com/nooga/let-go/pull/754) (`thrown?` in `is`),
[#756](https://github.com/nooga/let-go/pull/756) (`#'other-ns/private-var`),
[#758](https://github.com/nooga/let-go/pull/758) (invokable symbols),
[#760](https://github.com/nooga/let-go/pull/760) (variadic min-arity),
[#762](https://github.com/nooga/let-go/pull/762) (`reify Object`),
[#764](https://github.com/nooga/let-go/pull/764) (insertion-ordered small
maps). Those cover honeysql's *test suite* (its two main test namespaces load
private vars across namespaces, #756) and the `INSERT` column-order divergence
(#764). The gaps below are what the *library itself* needs at runtime.

Worked repro lives in lgx:

```
cd examples/clojure-libs/with-honeysql && LGX_LG=/path/to/let-go/bin/lg lgx run
```

## G1 — no `StringBuilder` host class

`honey.sql.util/str` (the library's optimized `clojure.core/str` replacement)
and `util/join` build every SQL string through `(StringBuilder.)` / `.append` /
`.toString`:

```
caused by: Can't resolve ->StringBuilder in this context
```

**Fix (`pkg/rt/host_stringbuilder.go`, Go):** a mutable `java.lang.StringBuilder`
shim over `strings.Builder`, following the `host_arraydeque.go` pattern —
mutable JVM type, so it lives in the compat layer, not `pkg/vm`. Ctor forms
`StringBuilder.`/`->StringBuilder` (+ fully-qualified), `.append` (returns the
builder, Java chaining semantics; `nil` appends `"null"`), `.toString`,
`.length`.

## G2 — `java.lang.String` methods missing

`format-entity` walks entities with `.length`/`.charAt`/`.indexOf`;
`upper-case` calls `.toUpperCase` with a locale; `util/str` calls
`.toString`/`.concat`. Only `.replace` and `.getBytes` existed. Worse,
`(.concat "a" "b")` silently resolved to core `concat` through the name→fn
fallback and returned `(a b)` — a wrong value, not an error.

**Fix (`pkg/vm/string.go`, Go — interop dispatch on a native type):**
`toString`, `length`, `isEmpty`, `charAt`, `indexOf` (string, char, and Java's
`(int ch)` codepoint form, optional fromIndex), `concat`, `substring`,
`startsWith`, `endsWith`, `contains`, `toUpperCase`/`toLowerCase` (optional
locale argument accepted and ignored — Go's case mapping is locale-independent,
which is exactly what `Locale/US` callers want), `trim`. Indices are **rune**
indices: Java's are UTF-16 units, and runes match them for all BMP text where
byte indices break on the first non-ASCII character.

## G3 — `clojure.lang.Keyword` accessors missing

`kw->sym` converts keywords via `(.sym ^clojure.lang.Keyword k)`:

```
error: method-invoke expected Receiver
```

**Fix (`pkg/vm/keyword.go`, Go):** `InvokeMethod` on `Keyword` with `sym`,
`getName`, `getNamespace`, `toString`, `hashCode`.

## G4 — `^Tag` hints strip a value's method surface (general bug)

Independent of G3: `^Tag x` in expression position compiles to a runtime
`(with-meta x {:tag Tag})`, and keywords — being invokable — wrap into
`vm.MetaFn`, which delegated everything **except** `InvokeMethod`. So
`(.sym k)` worked while `(.sym ^clojure.lang.Keyword k)` failed. Any hinted
receiver whose type implements `Receiver` had this bug.

**Fix (`pkg/vm/meta_value.go`, Go):** `MetaValue` delegates `InvokeMethod` to
the wrapped value. Metadata must not change interop dispatch.

## G5 — `java.util.Locale/US` static unresolved

```
caused by: Can't resolve java.util.Locale/US in this context
```

**Fix (`pkg/rt/host_jvm_statics.go`, Go — static registration table):**
`Locale`/`java.util.Locale` namespaces with `US`, `ROOT`, `ENGLISH` as opaque
markers. G2's case methods accept and ignore them.

## G6 — `unchecked-int`/`unchecked-long` reject characters

honeysql's `alphanumeric?` state machine feeds `.charAt` results straight into
`(unchecked-long (unchecked-int c))`. Java widens `char` to `int`; Clojure's
`unchecked-*` inherit that. let-go threw
`unchecked-int expected integer or float, got let-go.lang.Character`.

**Fix (`pkg/rt/lang.go`, Go):** `unchecked-long/int/short/byte` accept `Char`
as its codepoint.

## G7 — `#_` discard drops a comment instead of the next form (reader bug)

`#_ ;; note<newline> (form)` left `(form)` alive: `Read()` surfaces a line
comment as VOID and `readFormComment` discarded that instead of the form.
honeysql's suite hit this with a `#_`-disabled test that then executed.
Clojure's `#_` skips whitespace and comments before the form it discards.

**Fix (`pkg/compiler/reader.go`, Go compiler):** loop past VOID in
`readFormComment` (same pattern the reader-conditional value path uses).
Tests: `test/reader_discard_comment_test.lg`.

## G8 — Clojure 1.11 trailing-map kwargs

`(f :dialect :mysql {:pretty true})` into `[& {:as opts}]` threw
`hash-map requires an even number of arguments`. This is the known gap
mparrett flagged on #760, and honeysql's suite gates the test on
`(clojure-version)` being 1.11+ — which resolves once `clojure-version`
exists (see below).

**Fix (`pkg/rt/core/core.lg`, .lg):** `seq-to-map-for-destructuring`
(Clojure 1.11's name): pairs assoc'd in order, a single trailing map's
entries assoc'd in place (so they win on collision), empty kwargs binds
`nil` (matching Clojure), odd count without a trailing map still throws.
`fn-expand` emits it instead of `(apply hash-map …)`. Defined early in the
bootstrap, so the body sticks to primitives that exist there.
Tests: `test/kwargs_trailing_map_test.lg`.

## G9 — smaller suite unblocks

- `clojure-version` / `*clojure-version*` (`pkg/rt/core/core.lg`, .lg):
  reports the tracked language level (1.11.0); an unresolvable
  `clojure-version` stopped `honey.sql-test` from loading.
- `Locale/getDefault`/`setDefault`/`forLanguageTag` as honest no-ops
  (`host_jvm_statics.go`): a default-locale change genuinely cannot affect
  let-go's case mapping, which is what the Turkish-locale regression test
  asserts.
- `java.net.URLEncoder/encode` (`host_jvm_statics.go`): Go's
  `url.QueryEscape` implements the same form-urlencoded rules.

## Not let-go's to fix (honeysql `:lg` branches)

**Status: implemented (2026-09-08) on `lg/inline-str-and-formatv-gate` in the
fork ([abogoyavlensky/honeysql](https://github.com/abogoyavlensky/honeysql)),
branched from `develop`.** Not pushed and no PR opened yet — update this when
the PR opens, and again when it merges.

honeysql upstream **already ships `:lg` reader-conditional branches** (e.g.
`formatv` is disabled under `:lg` because `clojure.template` doesn't exist;
`inline-str` substitutes a plain `"'"` for the `#"(?<!\\)'"` lookbehind
regex Go's re2 can't express). Three gaps remained, all fixed in the fork.
Measured against let-go `main` (`dc310b6`) across all twelve test namespaces:

| | Tests | Pass | Fail |
|---|---|---|---|
| fork `develop` as-is | — | — | nothing loads (H0) |
| + H0 fixed | 156 | 663 | 0 |
| + H1 fixed | 173 | 761 | 8 |
| + H2 fixed | **173** | **769** | **0** |

The JVM suite is unchanged by all three (177 tests, 2841 assertions, 0
failures, byte-identical before and after) — every edit is confined to a
`:lg` branch.

### H0 — `with-inline` breaks `honey.sql` entirely (regression vs v2.7.1437)

**The one a future reader is most likely to hit again**, because it is *not*
in any release: it arrived with upstream PR
[#609](https://github.com/seancorfield/honeysql/pull/609) (`4fa833b`,
"[perf] Promote `:inline` to a separate dynvar"), which is on `develop` only.

`with-inline` is defined `#?(:clj …)` and selected at five call sites with
`#?(:clj with-inline :default binding)`. let-go matches `:clj`, so it takes
`with-inline`, whose expansion needs `push-thread-bindings` /
`pop-thread-bindings` — which let-go does not have:

```
caused by: Can't resolve push-thread-bindings in this context
```

`honey.sql` then fails to compile and **nothing loads at all** — which also
makes the baseline misleading, since the rest of the suite is absent rather
than failing.

**Fix (honeysql):** route `:lg` to `binding` at the five call sites, which is
what `:default` (ClojureScript) already does and is semantically identical —
`with-inline` is a performance shortcut, not a behaviour change. The
`defmacro` needs no change: its body is syntax-quoted, so
`push-thread-bindings` is never resolved at definition time.

Adding `push-thread-bindings`/`pop-thread-bindings` to let-go is the
alternative, and remains a legitimate gap worth filing on its own.

### H1 — `issue-495-formatv` not gated for `:lg` (predicted below, now fixed)

`issue-495-formatv` was gated `#?(:clj …)` only, but `formatv` is
`:lg`-disabled in src. let-go's reader matches `:clj`, so it read a test for a
macro `:lg` deliberately leaves undefined; `honey.sql-test` — most of the
suite — failed to compile with `Can't resolve sut/formatv`, taking ~17 tests
and ~98 assertions with it.

**Fix (honeysql):** `#?(:lg () :clj (deftest issue-495-formatv …))`, matching
the style `src/honey/sql.cljc` already uses for `formatv` itself.

### H2 — `inline-str` doubles already-escaped quotes (predicted below, now fixed)

The 8 "inline quote CVE" failures (mysql / non-conforming-postgres) came from
the `:lg` `inline-str` branch double-escaping already-escaped `\'`.

**Fix (honeysql):** an alternation that consumes `\'` as a unit, so only bare
quotes reach the replacement. Left-to-right alternation prefers `\'`, so an
escaped quote is matched whole and returned unchanged — and no lookbehind, so
re2 accepts it:

```clojure
(str \' #?(:lg (str/replace s #"\\'|'" (fn [m] (if (= m "'") "''" m)))
           :default (str/replace s #"(?<!\\)'" "''"))
     \')
```

The conditional moves up to wrap the whole `str/replace` because the branches
now need different *replacements* as well as different patterns. `:default`
stays byte-identical: the alternation was measured equivalent to the
lookbehind on 11 inputs (including `\\'` and runs of consecutive quotes), so
unifying them would be safe — but it would change code every honeysql user
runs for no behavioural gain.

### Still out of reach: two namespaces, not honeysql's fault

`honey.cache-test` and `honey.sql-alphanumeric-test` remain unloadable, and
git coords will not recover them — the blocker is JVM host interop inside the
dependencies themselves, verified by putting the libraries' source directly on
`-source-paths` and watching them fail to compile:

| namespace | needs | fails on |
|---|---|---|
| `honey.cache-test` | `core.cache` → `data.priority-map` | `java.util.SortedMap` / `Map.Entry` interop |
| `honey.sql-alphanumeric-test` | `test.check` → `test.check.random` | `JavaUtilSplittableRandom.`, a deftype over `java.util.SplittableRandom` |

Both fail identically before and after, so they are noise rather than signal.
Porting either library is its own project.

## Also fixed while here

Universal `.toString`: every JVM object answers it, so `invokeMethodFallback`
maps `.toString` on any value to `str` semantics — except `nil`, which fails
loudly like the NPE it would be on the JVM. (`honey.sql.util/str`'s 1- and
2-arity branches call `(.toString a)` on arbitrary values.)

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> `pkg/vm/string.go` (String.InvokeMethod), `pkg/vm/keyword.go`
> (Keyword.InvokeMethod), `pkg/vm/meta_value.go` (MetaValue.InvokeMethod),
> `pkg/rt/host_stringbuilder.go`, `pkg/rt/host_jvm_statics.go` (Locale,
> URLEncoder), `invokeMethodFallback` and the `unchecked-*` coercions in
> `pkg/rt/lang.go`, `readFormComment` in `pkg/compiler/reader.go`,
> `seq-to-map-for-destructuring` and `clojure-version` in
> `pkg/rt/core/core.lg`, and the tests `test/host_string_interop_test.go`,
> `test/host_jvm_statics_test.go`, `test/reader_discard_comment_test.lg`,
> `test/kwargs_trailing_map_test.lg`, `test/clojure_version_test.lg`.
