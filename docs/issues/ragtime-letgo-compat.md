# Issue: run weavejester/ragtime (core) under let-go

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** resolved — G0 in [nooga/let-go#898](https://github.com/nooga/let-go/pull/898), G1 and G2 in [nooga/let-go#901](https://github.com/nooga/let-go/pull/901) (main at `045d9fb`); `examples/web-app` runs ragtime's core unmodified with the default `raise-error` strategy

## Summary

[`ragtime`](https://github.com/weavejester/ragtime) 0.12.1's `core` module
(`ragtime.core`, `protocols`, `strategy`, `reporter`, `repl`; the JDBC
modules are separate artifacts and never loaded) runs under let-go with two
gaps in let-go and one already fixed on a pending branch. Its own suite is
the measure: `core/test` runs 19 tests.

| let-go | Pass | Fail | Error | Cause |
|---|---|---|---|---|
| `main` at `f26eb497` + a `Thread/currentThread` shim | 39 | 42 | 4 | `& rest` destructuring (G0) |
| `fix/http-server-and-rest-destructure` + shim | 80 | 10 | 1 | `format` `%n` (G2), one JVM-thread test (G3) |

Worked repro in lgx: `examples/web-app` uses ragtime for its sqlite
migrations (`src/app/migrations.lg`, `test/app/migrations_test.lg`).

Suite runner (scratch):

```clojure
(require 'Thread) (require 'test)
(doseq [n '[ragtime.core-test ragtime.strategy-test ragtime.reporter-test ragtime.repl-test]] (require n))
(test/run-tests)
```
```
LG_READ_CLJ=1 lg -source-paths ragtime/core/src:ragtime/core/test:<shim-dir> suite.lg
```

## G0 - `[x & coll]` binds `()` (fixed on the pending branch)

`ragtime.strategy/unzip` is `(defn- unzip [[x & coll]] (if coll ...))`. With
`coll` an empty-but-truthy `()`, `split-at-conflict` returns garbage and
`raise-error` / `rebase` / `ignore-future` return an empty plan (no error,
no hang): `(strategy/raise-error [] ["a" "b"])` is `()` instead of
`([:migrate "a"] [:migrate "b"])`. Only `apply-new` (no `unzip`) works.
Fixed by `fix(core): [x & more] destructuring binds nil` on the
`fix/http-server-and-rest-destructure` branch; see
`destructure-rest-empty-seq.md`.

## G1 - `Thread/currentThread` and `.isInterrupted`

`ragtime.core/migrate-all` polls for interruption between migrations:

```clojure
(when (.isInterrupted (Thread/currentThread))
  (throw (InterruptedException. ...)))
```

`Thread/currentThread` does not resolve, so `ragtime.core` (and everything
requiring it) fails to compile:

```
CompileError: Can't resolve Thread/currentThread in this context
```

`InterruptedException.` already resolves. `Thread.`/`->Thread` are loud
stubs in `pkg/rt/host_jvm_stubs.go`; the static is missing.

**Home: Go**, `pkg/rt/host_jvm_stubs.go` - a static-member registration
(`defStaticNS("Thread").Def("currentThread", ...)`) returning a small value
whose `InvokeMethod("isInterrupted")` answers `false` and whose other
methods fail loudly. "Not interrupted" is the true answer under let-go,
which has no thread interruption, so this is not a lie the way a
fake-success stub would be. Static registration + interop dispatch is the
layer #519 keeps in Go.

The example's stand-in, until then (`examples/web-app/src/Thread.lg`): a
namespace named `Thread` with a `currentThread` fn returning a `deftype`
whose protocol method `isInterrupted` is `false`.

## G2 - `format` does not understand `%n`

Clojure's `format` is `java.util.Formatter`, where `%n` is the platform
line separator and takes no argument. let-go's `format` (`CoreFormatf`,
`pkg/rt/lang.go`) hands the verb to Go's `fmt`, which has none:

```clojure
(format "Applying %s%n" "x")   ; Clojure: "Applying x\n"   let-go: "Applying x%!n(MISSING)"
```

Nine of ragtime's test assertions build their expected output with `%n`.
Common in Clojure code generally (`(format "...%n")` is the idiomatic
newline in a format string).

**Home: Go**, `CoreFormatf` - translate `%n` to `"\n"` while walking the
verbs (it already scans them to coerce arguments), leaving `%%n` alone.
Test: `(= "a\nb" (format "a%nb"))`, `(= "%n" (format "%%n"))`.

## G3 - degraded by design

`ragtime.core-test/migrate-all-interrupted` spawns a real `Thread.`, calls
`.interrupt` and `.join`. JVM threading; the existing loud stub is the
right answer. Keep examples off that path.

## Verify against (in [nooga/let-go](https://github.com/nooga/let-go))

- `pkg/rt/host_jvm_stubs.go` - `Thread.` stub, `installJVMStubs` (G1)
- `pkg/rt/lang.go` - `CoreFormatf` (G2)
- `pkg/rt/core/core.lg` - `destructure-vector` (G0)
