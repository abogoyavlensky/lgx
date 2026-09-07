# Issue: a dot-less `:go/local` module path is rejected as stdlib

**Repo:** this one (lgx)

**Status:** draft. Trivial to work around; the diagnostic is the problem.

## Summary

lgx classifies a Go coord as standard-library when the first segment of
the package path has no dot — the same rule the Go toolchain uses. That
rule is right for *published* modules, but a `:go/local` module is a
directory on disk, and Go itself accepts any module path there,
`lgxwails/shim` included.

Declaring one gets rejected:

```clojure
{:deps {lgxwails/shim {:go/local "shim"}}}
```

```
:deps lgxwails/shim — lgxwails/shim is a standard-library package: it has no
module requirement, so :go/version/:go/local do not apply - declare
:go/interop "shim" only
```

The message is confidently wrong: the package is not stdlib, and the
advice (`:go/interop "shim"`) leads nowhere.

## Where it comes from

The stdlib test in `lgx/config.lg` runs before anything looks at whether
the coord carries `:go/local`. A local module's real path is available —
`lgx/gobuild.lg` already reads it out of the target's own `go.mod` — so
the check has better information available than the one it uses.

## The workaround

Give the shim module a dotted first segment, which is good practice
anyway:

```
module example.com/lgxwails/shim
```

## What a fix looks like

Either is fine, and the second is cheaper:

1. Skip the stdlib classification when the coord has `:go/local`, and let
   the `go.mod` read decide. A local directory is never stdlib.
2. Keep the check but fix the message for the `:go/local` case: say that a
   local module path needs a dot in its first segment or Go will treat it
   as standard library, and name the `go.mod` line to change.

The current text is the worst of both: it asserts something false about
the user's code and prescribes a fix that cannot work.
