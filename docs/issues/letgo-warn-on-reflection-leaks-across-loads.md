# Issue: `*warn-on-reflection*` set in one file stays on for every later load

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft. Fix on `abogoyavlensky/let-go` branch
`fix/warn-on-reflection-per-load`; the upstream PR is not open yet.

## Summary

JVM Clojure's `load` binds `*warn-on-reflection*` and `*unchecked-math*`
before it compiles a file, so a top-level `set!` of either lasts only for that
file. let-go's `rt.WithFile` (`pkg/rt/file_var.go`) binds only `*file*`, so
the `set!` changes the value for the whole process. Every file loaded after a
library that turns the flag on compiles with it on.

## How it was found

`examples/web-app` requires HoneySQL, and five HoneySQL files start with
`#?(:clj (set! *warn-on-reflection* true))`, routine hygiene for a JVM
library. let-go reads the `:clj` branch. The namespaces loaded after it
(ragtime, and the letgo-packages sql and sqlite wrappers) then printed 14
reflection warnings on startup, though none of them sets the flag.

Wrapping the `require` in `(binding [*warn-on-reflection* false] ...)` does
not help: the `set!` writes that binding, and it stays true for the rest of
the `binding` body.

## Reproduction

```clojure
;; lib/setter.lg
(ns lib.setter)
(set! *warn-on-reflection* true)

;; lib/later.lg
(ns lib.later)
(defn f [s] (.length s))

;; (require 'lib.setter) (require 'lib.later)
;; => reflection warning, .../lib/later.lg:2:13: host target type is not statically known ...
;; and *warn-on-reflection* derefs to true from then on
```

On the JVM, `lib.later` compiles with the flag false and nothing is printed.

## Workaround

None worth carrying in a consumer. The warnings are noise, not errors, so
`examples/web-app` accepts them until a let-go release carries the fix.

## Fix

`WithFile` also pushes bindings for `*warn-on-reflection*` and
`*unchecked-math*` at their current values and pops them on every exit path.
Every file load goes through `WithFile`: the CLI runner, `-c`/`-b`, the WASM
builder, and the resolver's `loadFile`, which `require` uses. A file's own
`set!` still applies to the rest of that file, and a load inside
`(binding [*warn-on-reflection* true] ...)` still inherits `true`.

Plan and verification:
[`docs/plans/2026-09-25-1617-letgo-warn-on-reflection-per-load.md`](../plans/2026-09-25-1617-letgo-warn-on-reflection-per-load.md),
Task 1.
