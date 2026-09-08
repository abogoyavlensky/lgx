# Issue: `push-thread-bindings` / `pop-thread-bindings` are missing

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft. Found by HoneySQL; worked around there with an `:lg` reader
conditional.

## Summary

let-go implements `binding`, but not the two public functions Clojure builds it
from:

| | let-go |
|---|---|
| `binding` | ✅ `#'core/binding` |
| `push-binding!` / `pop-binding!` | ✅ let-go's own per-var primitives |
| `bound-fn`, `bound-fn*`, `with-redefs` | ✅ |
| **`push-thread-bindings`** | ❌ |
| **`pop-thread-bindings`** | ❌ |
| `with-bindings`, `get-thread-bindings` | ❌ |

That is fine until a library calls them directly, which real ones do: they are
public `clojure.core` API, and the usual reason to reach for them is exactly the
one HoneySQL had — avoiding `binding`'s per-call macro overhead on a hot path.

## How it was found

HoneySQL's `develop` (upstream PR
[#609](https://github.com/seancorfield/honeysql/pull/609), "[perf] Promote
`:inline` to a separate dynvar") added:

```clojure
#?(:clj (defmacro ^:private with-inline [bindings & body]
          `(do (push-thread-bindings inline-true-map)
               (try ~@body (finally (pop-thread-bindings))))))
```

selected at five call sites by `#?(:clj with-inline :default binding)`.

let-go matches `:clj`, takes `with-inline`, and fails to compile the expansion:

```
Can't resolve push-thread-bindings in this context
```

`honey.sql` does not load at all, so the whole library is unusable — not one
degraded feature. Note this is a *regression* relative to v2.7.1437, which
predates #609.

The failure is at the call sites, not the `defmacro`: a macro body is
syntax-quoted, so the symbol is never resolved at definition time. That makes
the error appear far from its cause.

## Workaround

Route `:lg` to `binding`, which is what ClojureScript already does:

```clojure
(#?(:lg binding :clj with-inline :default binding) [*inline* true] ...)
```

Semantically identical — `with-inline` is a performance shortcut, not a
behaviour change. Being carried as an `:lg` conditional in HoneySQL.

## Why it looks cheap to fix

The machinery is already there, in both directions:

- `pkg/vm/exec_context.go` exposes `PushBinding` / `PopBinding` to Go
  (`exec_context.go:191-192`), over the per-goroutine binding stack.
- `core.lg` already surfaces those as `push-binding!` and `pop-binding!`, and
  `binding` (`core.lg:621`) is a macro over them, with a `try`/`finally` so the
  pops run on a non-local exit.

So the gap is the *shape*, not the capability. Clojure's versions take a whole
frame at once:

```clojure
(push-thread-bindings {#'*foo* 1 #'*bar* 2})
(pop-thread-bindings)   ; pops the frame, no arguments
```

## The part that needs a decision

`pop-thread-bindings` takes **no arguments** and pops one whole frame, whereas
let-go's `pop-binding!` pops one named var. Implementing the Clojure API
therefore needs a notion of a binding *frame* — a stack of pushed sets — rather
than just per-var stacks, so that a single argument-less pop can unwind exactly
what the matching push installed.

Whether that is a thin bookkeeping layer over the existing per-var stacks or a
change to how bindings are represented is the design question, and it is the
reason this is filed rather than fixed. `with-bindings` and
`get-thread-bindings` fall out of the same frame representation.

A narrower option, if frames are unwelcome: implement `push-thread-bindings`
and have `pop-thread-bindings` unwind the most recent pushed set recorded in a
side stack, leaving the existing per-var API untouched.

## Impact beyond HoneySQL

Any library reaching for the fast path rather than the `binding` macro. It is
also the kind of gap that appears suddenly: HoneySQL worked, upstream landed a
performance PR, and the library stopped loading entirely with an error naming a
function rather than a feature.
