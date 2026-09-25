# Issue: the host reflection warning ignores type hints and constructor-bound locals

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft. Change on `abogoyavlensky/let-go` branch
`feat/reflection-warning-known-locals`; the upstream PR is not open yet.

## Summary

With `*warn-on-reflection*` on, let-go warns on every host call whose target
is a local, hinted or not. `hostTargetStaticallyKnown`
(`pkg/compiler/compiler.go`) returns false for any symbol, and the compiler
strips `:tag` metadata from fn params and let bindings before that check runs.
`(.length ^String s)` therefore warns just like `(.length s)`, and a local
bound to `(StringBuilder.)` warns on every `.append`. JVM Clojure warns on
neither, so a library that is reflection-clean on the JVM gives the author no
way to silence the warning under let-go.

## How it was found

`examples/web-app` requires HoneySQL, which turns the flag on in five files
(see [letgo-warn-on-reflection-leaks-across-loads.md](./letgo-warn-on-reflection-leaks-across-loads.md)).
HoneySQL itself then printed 33 reflection warnings at hinted or
constructor-bound call sites that the JVM compiles without reflection.

## Reproduction

```clojure
(set! *warn-on-reflection* true)
(fn [^String s] (.length s))
;; => reflection warning, ...: host target type is not statically known ...
(fn [] (let [sb (StringBuilder.)] (.append sb "x")))
;; => the same warning
```

## Workaround

A consumer has none. A library can skip the `set!` under let-go with
`#?(:lg nil :clj (set! *warn-on-reflection* true))`, which turns the warning
off for the whole file.

## Proposed change

A local is statically known when its binding carried `:tag` metadata, or,
for `let`, when its init form is itself known (a constructor call, a
`->Record` call, `with-meta`, or another known local). A `loop` local is
known only when hinted, because `recur` can rebind it. The check walks
enclosing contexts the way lexical resolution does, so an inner unhinted
binding shadows an outer hinted one, and a closure finds a hinted parameter
of its enclosing fn.

This changes the warning only. The tag is still not attached to the local,
and the call still dispatches dynamically. Upstream may prefer to keep the
warning until type-directed dispatch exists; if so, the HoneySQL-side guard
above is the fallback.

With this change and the per-load fix together, HoneySQL still prints 2
warnings. Both are chained calls whose target is another call's result:
`util.cljc:21` `(.concat (.toString a) ...)` and `sql.cljc:250`
`(.. s toString (toUpperCase ...))`. Clearing those needs method return
types, which let-go does not track.

Plan and verification:
[`docs/plans/2026-09-25-1617-letgo-warn-on-reflection-per-load.md`](../plans/2026-09-25-1617-letgo-warn-on-reflection-per-load.md),
Task 2.
