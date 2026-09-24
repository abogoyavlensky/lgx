# let-go gotchas

Runtime quirks and surprises we hit during lgx development. Each entry:
what happens, why, and how to dodge it.

## Top-level forms run during AOT compile

`runFile` and `bundleBinary` both go through `CompileMultiple`, which
evaluates each top-level form as it compiles. Side effects at the end of
a script (a `(main)` call, side-effecting `println`s) therefore fire
during `lg -c`, `lg -b`, and `lg -w` — not only at run time.

Guard the entry call with `*compiling-aot*`:

```clojure
(when-not *compiling-aot* (main))
```

`*compiling-aot*` defaults to `false`. `lg.go` flips it to `true` only
when `-c`/`-b`/`-w` is set. Bundle execution doesn't touch it, so the
guard runs `(main)` exactly once at the bundled binary's start.

## Namespace name colliding with the file path causes self re-load

A script with `(ns foo)` saved as `foo.lg` executes twice: once as the
entry, once via the resolver re-loading `foo` when the compiler triggers
an `rt.NS("foo")` lookup that finds the same file on the search path.

Use a namespace name that doesn't collide with the entry file's resolver
candidates. We renamed `(ns lgx)` in `lgx.lg` to `(ns lgx.main)` —
`lgx.main` resolves to `lgx/main.lg`, which doesn't exist, so no
re-load.

## `os/args` is a value, not a function

In Go, `os.Args` is a slice. let-go's `os` namespace exposes it as a
let-go vector directly:

```clojure
(rest os/args)        ; correct
(rest (os/args))      ; wrong — "wrong number of arguments 0"
```

## `os/getenv` returns `""` for unset vars, not `nil`

The empty string is truthy in Lisp, so `(or (os/getenv "X") "default")`
returns `""` when `X` is unset, not `"default"`. Check explicitly:

```clojure
(let [v (os/getenv "LGX_LG")]
  (if (str/blank? v) "lg" v))
```

## `os/sh` buffers all output

`os/sh` waits for the child to exit, then returns captured stdout/stderr
as strings. Long-running scripts can't stream output; interactive
subprocesses (REPL, `read-line`, password prompts) can't read input. When
the child should drive the terminal, use `os/exec*` instead (lg >=
1.10.0): it inherits the parent's stdin and returns the exit code, and
wires the child's stdout/stderr to the current `*out*` / `*err*`. On lg
>= 1.13.0 the root `*out*` / `*err*` handles are not raw files, so the
child gets a *pipe* on those two streams and a REPL or TUI child no
longer sees a terminal; to hand the tty through, rebind the var to a
handle from `(open "/dev/stdout" :append)` around the call, but only when
the stream is a terminal (`term/tty?`) - reopening `/dev/stdout` for a
regular file breaks the shell's shared offset. lgx does exactly this in
`runner/exec-lg-interactive!` for `lgx run` / `lgx repl` / `lgx nrepl`
([`docs/issues/exec-star-std-stream-pipes.md`](../issues/exec-star-std-stream-pipes.md)).
`os/exec` returns a `*exec.Cmd` but exposes only `with-stdin` — no
`Run`/`Wait`/`Stdout` field access.
(History: [`docs/issues/inherit-stdio-runner.md`](../issues/inherit-stdio-runner.md).)

## `*out*` / `*err*` can be rebound with `binding`

`binding` works on `(def ^:dynamic *x* …)` Vars and also on the IOHandle
values `*in*` / `*out*` / `*err*` (verified on lg 1.12.2 and 1.13.0):
`println`, `write!`, and `os/exec*` all follow the binding, which is
what `with-out-str` relies on. To write to stderr without rebinding
anything, write to the handle directly:

```clojure
(write! *err* "message")
```

## Bundle output path can't collide with a source directory

`lg -b foo lgx.lg` fails when a directory named `foo/` already exists in
the working directory. Bundle to a distinct path (`bin/lgx`, not `lgx`).

## Test files loaded by `lgx test` must not call `(run-tests)` at top level

`test/run-tests` walks `*registered-tests*` and runs every entry
synchronously. When it appears at the top of a `*_test.lg` file, it
fires during the file's load — before later tests in the same file
register and before `lgx test`'s harness gets to iterate
`*registered-tests*` itself. The harness then sees a partial registry,
re-runs whatever was registered before the top-level call, and skips
the rest. On let-go's clojure.test port (#863) there is no registry, but
a top-level `(run-tests)` still runs and prints every test during the
load phase, ahead of the harness's own run, so the advice stands.

For files run through `lgx test`, define only `deftest` (and
fixtures). The harness owns the run and the exit code; the file owns
the definitions. The old idiom

```clojure
(run-tests)
(when-not test/*test-result* (os/exit 1))
```

is exactly what the new command exists to replace — strip it.

## `ns` loads `:as`-aliased requires before the rest

The `ns` macro emits its `:require` entries in written order, but the
compiler loads every `:as`-aliased namespace first (in written order),
then the unaliased ones. `(ns m (:require [a.one] [a.two] [a.three :as t]))`
loads `three, one, two`. Clojure loads them as written.

It matters when one library's compile depends on a namespace another
require provides - before let-go #901, `examples/web-app` carried a
`Thread` namespace so `ragtime.core`'s `Thread/currentThread` resolved,
and it had to load first. `require` the prerequisite explicitly after the
`ns` form, then the dependent library; ordering inside `:require` is
fragile here, and `cljfmt` (`:sort-ns-references?`) re-sorts it anyway.

## A branch that is never taken still has to compile

let-go compiles every top-level form before running it, and a symbol the
running let-go does not know is a compile error wherever it sits — an `if`
branch guarded by `(resolve 'the/marker)` included. So one file cannot
carry code for two let-go versions:

```clojure
(if (resolve 'test/test-ns)
  (ns-interns ns)        ; CompileError on lg 1.12.2: Can't resolve ns-interns
  (old-way ns))
```

Put each version's code in its own namespace, pick one at run time, load
it with `require` (a run-time call), and reach its functions through
`resolve` too — naming `lgx.test-harness.report/run-plan!` as a symbol
would resolve it at compile time, before the `require` ran:

```clojure
(def run-var
  (if (resolve 'test/test-ns)
    (do (require 'lgx.test-harness.report) 'lgx.test-harness.report/run-plan!)
    (do (require 'lgx.test-harness.legacy) 'lgx.test-harness.legacy/run-plan!)))
((var-get (resolve run-var)) plan)
```

Only the namespace that was required is ever compiled. The `lgx test`
harness used this to serve both sides of let-go's clojure.test port until
lgx's minimum lg (1.13.0) carried the port and the pre-port branch was
dropped.

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> [`lg.go`](https://github.com/nooga/let-go/blob/main/lg.go) (`bundleBinary`,
> `*compiling-aot*` flip),
> [`pkg/rt/os.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/os.go)
> (`os/sh`, `os/exec`, `os/exec*`, `os/args`, `os/getenv`),
> [`pkg/rt/iort.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/iort.go)
> (IOHandle, `*in*`/`*out*`/`*err*`),
> [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/main/pkg/resolver/resolver.go)
> (`Load` triggering self re-load),
> [`pkg/rt/core/core.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/core.lg)
> (`binding` macro, `ns` macro's require expansion),
> [`pkg/rt/core/test.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/test.lg)
> (`test-ns`, the clojure.test port the harness dispatch keys on).
