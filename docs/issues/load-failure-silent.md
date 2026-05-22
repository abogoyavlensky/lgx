# Namespace load failures are silent — stderr-only, no signal to caller

**Repo:** [nooga/let-go](https://github.com/nooga/let-go) ·
**File:** [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go) ·
**Status:** draft

## Problem

When a file referenced by `(:require [some.ns])` fails to compile,
the resolver in `pkg/resolver/resolver.go:65-86` prints
`error: failed to load <path>: <CompileError>` to stderr and returns
`nil`. There is no signal — no throw, no non-zero return from
`lg`, no callable hook — that the caller can use to detect the
failure.

```go
chunk, _, err := freshCtx.CompileMultiple(f)
...
if err != nil {
    fmt.Fprintf(os.Stderr, "error: failed to load %s: %s\n", path, err)
    return nil
}
```

For `lg <file>` the result is invisible: any top-level forms that
*were* compiled before the error register their side effects (e.g.
`deftest`/`defn`), the file's remaining forms silently disappear,
and `lg` exits 0 because nothing else went wrong.

Reproduction (with `lg 2.0.2`):

```
$ cat broken.lg
(ns broken)
(def a 1)
(undefined-symbol)
(def b 2)

$ lg broken.lg
error: failed to load /tmp/broken.lg: CompileError: Can't resolve undefined-symbol in this context
$ echo $?
0
```

`a` is defined (registered before the error), `b` is not, exit 0.

## Impact

The bug surfaces sharply in any tooling that loads user code by ns
and then iterates registered state. `lgx test` is the canonical case
([`lgx/test_runner.lg`](../../lgx/test_runner.lg)): its generated
harness `(:require [foo-test])`s each test file, then walks
`*registered-tests*`. A typo or bad import in a test file silently
drops the rest of its `deftest`s; the harness prints `OK` for
whatever did register and exits 0. CI passes, hidden tests rot.

Any future REPL / build / lint tool consuming `lg`'s namespace
machinery has the same blind spot.

## Possible fixes

1. **Bubble the error up.** Change `loadFromFile` (and the embedded
   / precompiled variants on lines 179, 198) to return an error
   instead of `nil`. Adjust callers (compile-time `(:require)` use
   site in particular) to propagate. Highest-impact fix; might be
   breaking for existing callers that rely on the swallow.
2. **Set a process-level "had load errors" flag.** Cheaper; doesn't
   change the resolver contract. `lg`'s main loop checks the flag
   at exit and returns 1. Doesn't help in-process callers
   (`lgx test` runs in a let-go subprocess but could re-use the
   exit-code signal).
3. **Expose a hook.** A `*load-error-handler*` dynvar, called with
   `[path err]`. Lets consumers decide policy (throw, log, mark).

Option 2 is the smallest behavior change that closes the CI hole.

## lgx-side workaround (until upstream lands)

If 2 above is adopted, `lgx test`'s harness will inherit the exit
code naturally. Until then, lgx can either:

- Wrap each `:require` in the generated harness with `try`/`catch`,
  set a flag, and exit 1 alongside the summary.
- Capture stderr from the `lg <harness>` exec and pattern-match
  `error: failed to load ` lines; force exit 1 if present.

Both are defensive patches; neither helps non-lgx consumers of the
resolver.

## Verify against

- [`pkg/resolver/resolver.go:65-86`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go)
  — the swallow site for filesystem loads.
- [`pkg/resolver/resolver.go:175-205`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go)
  — same shape for embedded / precompiled loads.
- [`lgx/test_runner.lg`](../../lgx/test_runner.lg) — harness
  generator; demonstrates the consumer-side blind spot.
- E2E coverage for `lgx test` exit codes lives in
  [`tests/e2e.sh`](../../tests/e2e.sh) (scenarios 39–49) — does
  *not* currently exercise the compile-error case.
