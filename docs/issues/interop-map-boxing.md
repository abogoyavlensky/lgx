# Issue: a let-go map does not cross the boundary as a Go map

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft. Found building the Wails v3 wrapper
([letgo-packages `wails/`](https://github.com/abogoyavlensky/letgo-packages/tree/master/wails)),
worked around in its shim.

## Summary

This is the map-shaped sibling of
[`interop-slice-boxing.md`](./interop-slice-boxing.md). That issue fixed
`[]any` in both directions; maps were never covered, and they are the
natural type for the other half of a wrapper's surface — options,
configuration, structured results.

Two gaps, again mirror images:

**Unboxing (let-go to Go).** Passing a let-go map to a Go parameter of
type `map[string]any` fails:

```
reflect: Call using *vm.PersistentMap as type map[string]interface {}
```

A wrapper cannot declare the parameter it wants. Every entry point taking
options must declare `vm.Value` and convert by hand.

**Boxing (Go to let-go).** The reverse has no total conversion either. A
Go `map[string]any` returned to let-go arrives boxed rather than as a
map, so the caller cannot use `get`, `:keyword` lookup, or destructuring
on it.

## Why it matters more than it looks

The obvious hand-conversion is wrong in a way that compiles, runs, and
produces plausible output. A let-go map literal is a `*vm.PersistentMap`,
not a `vm.Map`, so this:

```go
switch t := v.(type) {
case vm.Map:                 // never matches a map literal
    ...
case vm.ArrayVector:
    ...
}
```

falls through to the sequence branch, where `Seq()` yields `vm.MapEntry`
values. Treat those as ordinary elements and every map silently becomes a
list of pairs. In the Wails wrapper that surfaced as the frontend
receiving

```json
[["runtime","let-go"],["ui","wails v3"],["count",3]]
```

where it expected

```json
{"runtime":"let-go","ui":"wails v3","count":3}
```

No error, no warning — just the wrong JSON. The correct conversion has to
know that `*vm.PersistentMap` exists, that `vm.Map` is a different type,
and that a map's `Seq` yields `MapEntry`. That is three pieces of internal
knowledge pushed into every wrapper anyone writes, which is exactly the
argument the `[]any` fix already accepted.

## The workaround, for reference

`wails/shim/shim.go` declares `vm.Value` on every options parameter and
carries a recursive `ToGo`:

```go
if s, ok := v.(vm.Sequable); ok {
    sq := s.Seq()
    if sq != nil {
        if _, isEntry := sq.First().(vm.MapEntry); isEntry {
            out := map[string]any{}
            for ; sq != nil; sq = sq.Next() {
                e := sq.First().(vm.MapEntry)
                out[keyString(e.Key)] = ToGo(e.Value)
            }
            return out
        }
    }
    ...
}
```

It works, and it is the thing that should not have to be written twice.

## Suggested fix

Symmetrical with the `[]any` work:

- **Unboxing:** make conversion into `map[K]V` total for let-go map types
  (`vm.Map` and `*vm.PersistentMap` at least), converting keys and values
  elementwise with the same allowlist discipline
  `interop-slice-boxing.md` settled on. Keyword keys need a decision:
  rendering `:name` as `"name"` is what a `map[string]any` consumer
  expects, and is what the workaround does.
- **Boxing:** make `BoxValue` produce a real let-go map for a Go map with
  a boxable key type, boxing values by their dynamic type — the same rule
  the slice branch now uses.

## Open question

Key coercion is the part that deserves review rather than a unilateral
choice. `{:a 1}` to Go and back is only round-trip-safe if the boundary
agrees on whether `"a"` returns as a keyword or a string. The slice fix
had no analogue of this, so it is worth settling explicitly rather than
inheriting whatever the first implementation does.
