# Issue: native `.clj` library support — three small diffs

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

`lgx` exists to install and run let-go applications that pull in libraries
from the Clojure ecosystem. Today, libraries shipped as `.clj` files
(hiccup, medley, fipp, data.json …) can be cloned into the lgx cache, but
their namespaces can't be located by `(require …)`. The let-go resolver
hardcodes `.lg` and `.cljc` extensions only
([`pkg/resolver/resolver.go::Load`](https://github.com/nooga/let-go/blob/main/pkg/resolver/resolver.go)).

This issue collects three small, additive upstream changes that together
unblock `.clj` library support without changing behavior for any file that
resolves today. Each is independently reviewable.

## Empirical confirmation of the gap

Renaming a working `greeter.lg` to `greeter.clj` in
[lgx-template-base](https://github.com/abogoyavlensky/lgx-template-base)
breaks the resolver:

```
$ lgx --verbose run
+ lg -source-paths .../src main.lg --
error: Can't resolve greeter/greet in this context
  --> main.lg:5:8
   |
 5 |   (prn (greeter/greet "let-go")))
   |        ^^^
```

Renaming to `greeter.cljc` works. So `.clj` is the only blocker for these
libraries — the reader/compiler already handle the source once it's loaded
(per `test/compat/run.lg`, which runs medley/hiccup/fipp/data.json through
`slurp` + `load-string`).

## Diff 1: resolver — append `.clj` to the candidate list

`pkg/resolver/resolver.go::Load` currently builds four candidates per
namespace:

```go
candidates := []string{
    hyphenPath + ".lg",
    underscorePath + ".lg",
    hyphenPath + ".cljc",
    underscorePath + ".cljc",
}
```

Append two more, **after** the `.cljc` entries:

```go
candidates := []string{
    hyphenPath + ".lg",
    underscorePath + ".lg",
    hyphenPath + ".cljc",
    underscorePath + ".cljc",
    hyphenPath + ".clj",       // new
    underscorePath + ".clj",   // new
}
```

The ordering matters: any project that resolves today resolves identically
afterwards. `.clj` is only consulted when neither `.lg` nor `.cljc` exists
for the namespace. A library that ships both `foo.cljc` and `foo.clj`
keeps loading the `.cljc` (let-go-safe) variant.

## Diff 2: env var — wire `LG_READ_CLJ` to `SetMatchCljConditional`

`pkg/compiler/reader.go:1063-1070` already documents the intended interface
but the env var is never read. Grep across the repo:

```
$ grep -rn "LETGO_READ_CLJ" .
pkg/compiler/reader.go:1069:// LETGO_READ_CLJ env var at startup.
```

Only the comment exists; no `os.Getenv(…)` call wires it up. The proposal
is to wire it at startup with one branch:

```go
if os.Getenv("LG_READ_CLJ") != "" {
    SetMatchCljConditional(true)
}
```

### Naming: `LG_READ_CLJ`, not `LETGO_READ_CLJ`

Every other env var in `pkg/` uses the `LG_*` prefix:

- `pkg/vm/native_func.go:135` — `LG_BOXARGS_DEBUG`
- `pkg/vm/errors.go:180` — `LG_PANIC_STACK`

The `LETGO_READ_CLJ` name in the comment is the outlier. Renaming to
`LG_READ_CLJ` aligns with the existing internal convention. If preferred,
both names can be honored (read either) to preserve the comment's promise.

## Diff 3: reader conditional priority — `:lg > :clj > :default`

The current matching logic at `pkg/compiler/reader.go:1124-1126` is
**first-match-wins**:

```go
isMatch := !found && (key == lgConditionalTag ||
    (matchCljConditional && key == cljConditionalTag) ||
    key == defaultConditionalTag)
```

The `!found` guard means the first branch whose key matches gets selected.
This has two consequences:

1. **Latent (pre-existing) surprise:** `#?(:default Z :lg X)` selects `Z`,
   even though `:lg` is the more specific match. Nobody writes branches
   in that order today, but the semantics are fragile.
2. **New surprise once `:clj` matching is on:** `#?(:clj Y :lg X)`
   selects `Y` despite `:lg` being available. This breaks let-go-native
   `.cljc` libraries that mix `:lg` and `:clj` branches (e.g.
   [tiny-cli](https://github.com/abogoyavlensky/tiny-cli) writes both
   `#?(:lg X :clj Y)` and `#?(:clj Y :lg X)` patterns).

Proposal: replace first-match-wins with priority-based matching:

```
priority: :lg > :clj (when matchCljConditional) > :default
```

The author can write branches in any order; `:lg` always wins when
present. Implementation: scan all branches in the conditional, track the
best match by priority, return its value. The reader has to read past
the first match (currently it short-circuits), but the algorithmic
change is small.

This is backward-compatible for every file currently passing the
[clojure-test-suite](https://github.com/jank-lang/clojure-test-suite) —
those files don't depend on first-match-wins behavior because they're
authored against vanilla Clojure (no `:lg` branches), so the priority
change only affects files that mix `:lg` with `:clj`/`:default`, and only
to make `:lg` win where it should have already.

## What lgx will do after these land

- `lgx/runner.lg::invoke-lg!` sets `LG_READ_CLJ=1` in the env before
  every `(os/sh "lg" …)`. The env var propagates to the child via
  Go's default `exec.Command` env inheritance.
- `lgx test` discovery walks for `*_test.clj` alongside `*_test.lg` and
  `*_test.cljc`.
- Validation error message in `lgx test <file>` includes `.clj` in the
  accepted-extension list.
- `docs/knowledge-base/let-go-resolver.md` drops the
  "**`.clj` is not searched**" note and gains a section on the new
  priority semantics.

The lgx-side PR can land most of these changes before this issue ships —
they're additive on the lgx side too — but the user-facing payoff
(actually being able to `(require '[hiccup.core])`) waits on this issue.

## What lgx will *not* do

- Per-project or per-dep opt-in for the `:clj` lens. The lens is
  process-global in let-go; lgx flips it unconditionally for every
  spawn. Users who want let-go-native semantics in their own `.cljc`
  files keep them by writing `:lg` branches explicitly (which the
  priority fix protects).
- A `lg --version` check at lgx startup. On older `lg` releases the env
  var is silently ignored and `.clj` requires fail with the existing
  `Can't resolve …` error — same as today, no regression.

## Relationship to existing issue docs

- [`clojure-lib-compat.md`](./clojure-lib-compat.md) §2 raises the same
  resolver gap (single-line ask: "add `.clj` to the resolver"). This
  issue supersedes that section by covering the full three-diff
  shape — see the pointer note at the top of §2 in that doc.
- [`clojure-lib-compat.md`](./clojure-lib-compat.md) §1 (`:default`
  reader-conditional referring to JVM classes) is orthogonal — that's
  about compile-time tolerance of unresolved class refs, not about which
  branch the reader picks. Left for separate work.

## Verify against (in [nooga/let-go](https://github.com/nooga/let-go))

- [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/main/pkg/resolver/resolver.go)
  (`Load`, candidate-list construction)
- [`pkg/compiler/reader.go`](https://github.com/nooga/let-go/blob/main/pkg/compiler/reader.go)
  (`matchCljConditional`, `SetMatchCljConditional`, `readConditional` —
  source-anchored line numbers above are current as of `main` at the
  time of filing)
- [`pkg/compiler/eval.go`](https://github.com/nooga/let-go/blob/main/pkg/compiler/eval.go)
  (`set-read-clj!` runtime function — for context; this issue doesn't
  change it)
