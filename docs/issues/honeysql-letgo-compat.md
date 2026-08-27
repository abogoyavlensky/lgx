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

## Also fixed while here

Universal `.toString`: every JVM object answers it, so `invokeMethodFallback`
maps `.toString` on any value to `str` semantics — except `nil`, which fails
loudly like the NPE it would be on the JVM. (`honey.sql.util/str`'s 1- and
2-arity branches call `(.toString a)` on arbitrary values.)

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> `pkg/vm/string.go` (String.InvokeMethod), `pkg/vm/keyword.go`
> (Keyword.InvokeMethod), `pkg/vm/meta_value.go` (MetaValue.InvokeMethod),
> `pkg/rt/host_stringbuilder.go`, `pkg/rt/host_jvm_statics.go` (Locale),
> `invokeMethodFallback` and the `unchecked-*` coercions in `pkg/rt/lang.go`,
> and `test/host_string_interop_test.go`.
