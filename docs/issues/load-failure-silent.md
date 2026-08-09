# Namespace load failures are silent — stderr-only, no signal to caller

**Repo:** [nooga/let-go](https://github.com/nooga/let-go) ·
**File:** [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/master/pkg/resolver/resolver.go) ·
**Status:** partly fixed upstream in lg 1.12 — see "What lg 1.12 changed"

## What lg 1.12 changed

lg 1.12.2 splits the old single behaviour in two, and one half is now
*worse* than what this issue originally described. Measured by holding lgx
fixed and varying only `LGX_LG`:

| failing test file | lg 1.11.1 | lg 1.12.2 |
|---|---|---|
| compile error (unresolved symbol) | swallowed; `error: failed to load <path>: …` on stderr; exit 0 | **throws**; error + stack trace; non-zero exit |
| reader/syntax error (unbalanced form) | swallowed; `error: failed to load <path>: Syntax error reading source …`; exit 0 | **silently ignored — no stderr at all, exit 0** |

So the compile-error hole is closed: option 1 ("bubble the error up")
effectively landed for that path, and `lgx test` now reports the failure and
exits non-zero.

The reader-error path regressed. There is no longer *any* observable signal:
no diagnostic on stderr, exit 0, and the file's forms simply absent. lgx
cannot detect it from outside the process, and cannot detect it from inside
either — `find-ns` still returns a live ns object for a namespace whose
source never parsed:

```
$ cat test/bad_test.lg
(ns bad-test)
(def y (+ 1

$ lg -source-paths test -e "(require 'bad-test) (prn (find-ns 'bad-test))"
<ns bad-test>          ; no error printed, exit 0
```

That makes an unreadable test file indistinguishable from an empty one, so
the silent-CI-pass this issue is about is back for syntax errors
specifically.

**Ask:** apply the same fix the compile path got to the reader path — a
reader failure in a required file should throw (or at minimum print a
diagnostic and set a non-zero exit), not vanish.

## lgx-side status

`lgx test` detects everything it still can (`lgx.lg` `cmd-test`,
`lgx/test-runner`):

- `harness-ready?` — the harness writes a marker as its first body form, so
  a thrown load error (1.12 compile path) is caught as "the harness never
  started", independent of lg's wording;
- `load-error-before-harness?` — matches both the wrapped
  `error: failed to load <path>: …` form and 1.12's bare
  `error: Syntax error reading source at (<file>:L:C).`, for lg versions
  that still print one.

Together these cover every shape lg still reports, on both versions, so
`tests/e2e.sh` scenarios 68 and 70 pass under each — scenario 68 now asserts
the offending file and symbol rather than one version's phrasing.

What remains uncovered is narrower than the table above suggests: only a
reader error that leaves lg with *nothing* to report. `(def y #)` still
produces `error: Syntax error reading source at (…)` and a non-zero exit on
1.12, and is caught. An unterminated form running to EOF produces no output
at all, and is not detectable by any means available to lgx.

## Problem (as originally filed, against lg ≤ 1.11)

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
