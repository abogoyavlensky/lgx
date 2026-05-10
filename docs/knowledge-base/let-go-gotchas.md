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
as strings. There's no way from let-go to inherit the parent's stdio.
Long-running scripts can't stream output; interactive subprocesses (REPL,
`read-line`, password prompts) can't read input. `os/exec` returns a
`*exec.Cmd` but exposes only `with-stdin` — no `Run`/`Wait`/`Stdout`
field access. Tracked in
[`docs/issues/inherit-stdio-runner.md`](../issues/inherit-stdio-runner.md).

## `binding` only works on dynamic Vars

Per-thread rebinding works for things defined as `(def ^:dynamic *x* …)`.
The IOHandle values `*in*` / `*out*` / `*err*` are not Vars — you can't
rebind them with `binding`. Write to the handle directly instead:

```clojure
(write! *err* "message")
```

## Bundle output path can't collide with a source directory

`lg -b foo lgx.lg` fails when a directory named `foo/` already exists in
the working directory. Bundle to a distinct path (`bin/lgx`, not `lgx`).
