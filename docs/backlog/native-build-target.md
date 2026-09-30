# `lgx build` cannot compile application Lisp to native Go (`:target :native`)

**Status: open**

## Problem

GitHub issue #60 asks `lgx build` to lower an application's Lisp (and its
reachable dependencies) to Go through let-go's AOT compiler (`lg.compiler`,
`scripts/lg-compile`) and link an OS executable, selected by
`:targets {:bin {:target :native ...}}`. Phase 1 shipped only
`:target :lgb` (`docs/plans/2026-09-30-2116-lgb-build-target.md`), because
both ways of building a native binary break on let-go main `a141e406`
(checked 2026-09-30).

## The two routes and what blocks them

**Entry frame** (`lg-compile --entry-frame`, then
`lg -c -entry-frame-entry ns/-main`, then `go build`; what `lg compile`,
let-go PR #977, automates). Compiled library namespaces work and install as
`<native-fn>`s. A compiled `-main` does not:

- `eval` panics: `clojure.core/eval` is nil in the frame (let-go #992).
- an inline `fn` panics on a nil lambda-lifted var (let-go #783).

**Custom runtime + `lg -b`**. lgx already generates a Go module for `:go/*`
deps. Adding the lowered packages to it as blank imports, then bundling with
that runtime as `-bundle-base`, would keep everything a normal bundle has:
the REPL, `eval`, dynamic loading, cross-builds. But the bundled binary
never installs the compiled functions: `lib/g` is `<native-fn>` while `-b`
runs the script and a bytecode `<fn>` in the finished binary. `rt.RunExecUnit`
does drain `ApplyGoOverrides` after each namespace chunk, the unit's
`NSOrder` lists the namespace, and it loads once, so the cause is still
unknown (let-go #991).

This is the preferred route once #991 is fixed.

## Related upstream work

- let-go #660: a machine-readable per-function report and an opt-in strict
  mode. Until it lands, lgx cannot fail a build on fallbacks that were not
  approved, which #60 asks for.
- let-go #990: a compiled caller keeps calling the old compiled callee after
  `with-redefs` or `alter-var-root`, so #60's redefinition criterion cannot
  hold.
- let-go PR #977 (`lg compile`): its module requires only let-go, so it
  cannot carry a project's `:go/*` deps.

## Acceptance

An execution test must prove compiled functions run, for example that the
var holds a `<native-fn>`. Correct output alone proves nothing: a silent
bytecode fallback produces the same output.
