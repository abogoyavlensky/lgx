# lower-go: host method calls allocate an arg slice and dispatch by name

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1070](https://github.com/nooga/let-go/issues/1070).

Found while measuring let-go web-app performance, on let-go main `d0108ba6`.

## Summary

A host method call in lowered code goes through `rt.CoreMethodInvoke(target, vm.Symbol("append"), arg)`. That is variadic, so every call allocates the argument slice, and then the receiver dispatches on the method name with a string switch. For `StringBuilder.append` this costs about 7x a direct call:

| | ns/op | allocs/op |
|---|---|---|
| `rt.CoreMethodInvoke(sb, 'append, "<td>")` | 65 | 1 |
| `strings.Builder.WriteString("<td>")` | 9 | 0 |

Go benchmark at `d0108ba6`. In a lowered hiccup renderer built on a `StringBuilder`, `CoreMethodInvoke` was about 8% of CPU, with roughly 3,000 `.append` calls per 8 KB page. It is a modest cost, but it applies to every interop-heavy inner loop.

## Possible directions

Ordered from no design change to one:

1. Fixed-arity entry points (`CoreMethodInvoke0/1/2`, or a `Receiver` method that takes args without a slice), emitted by `lower-go` when the arity is static. This removes the allocation without touching dispatch semantics.
2. Resolve the method once per call site. For example, cache the `(type, name)` → handler pair at the site, the way `CachedVarFnEC` caches vars.
3. With #1024 keeping `:tag` on locals, let a hinted receiver (`^StringBuilder sb`) lower to a direct typed call, with a type check that falls back to dynamic dispatch. #1024 notes that using tags for dispatch needs its own sign-off; this issue is a concrete case for it.
