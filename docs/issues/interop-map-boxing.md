# Issue: a let-go map does not cross the boundary as a Go map

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status: implemented (2026-09-01).** Both directions, plus nesting, fixed on
`fix/vm-boxing-symmetry` ([#778](https://github.com/nooga/let-go/pull/778)) —
the same PR that fixed `[]any`, extended rather than a second one. Found
building the Wails v3 wrapper
([letgo-packages `wails/`](https://github.com/abogoyavlensky/letgo-packages/tree/master/wails)),
which had worked around it in its shim.

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

## The fix

Symmetrical with the `[]any` work, in three commits:

- **Boxing.** `BoxValue`'s map branch boxes keys and values by their
  **dynamic** type, using the same allowlist `interop-slice-boxing.md`
  settled on. The allowlist gained exactly `map[string]any` — a string key
  and the empty interface, nothing else.

- **Unboxing.** A new `unboxMapInto` converts a let-go map into any Go map,
  key by key. Map sources are identified by an explicit **type switch** on
  `vm.Map`, `*vm.PersistentMap` and `*vm.SortedMap`, not by inspecting the
  first element for a `MapEntry`: every map type yields `EmptyList` from
  `Seq()` when empty, so an empty map and an empty vector are
  indistinguishable that way. It is wired into both `unboxInto` (nested in a
  struct field or slice element) and `boxArgForReflect` (the direct parameter
  path that actually failed).

- **Nesting.** A collection reaching an `any` target converts into its natural
  Go shape instead of being handed over as a let-go value. Without this, the
  fix only worked one level deep and a wrapper author would still have written
  the recursive converter.

Three details carried the work:

- Maps must be tested **before** sequences, because every let-go map is also
  `Sequable` and the sequential branch would otherwise turn a map into a vector
  of entries.

- The nesting rule is keyed on what `Unbox()` already produces — a `[]Value` —
  **not** on `Sequable`. `Sequable` is far too broad: `String` implements it,
  and so does `NIL`, whose `Seq()` returns itself and whose `First()` is
  itself, giving unbounded recursion. Keying on the `Unbox` result also
  excludes a `Seq`, which may be infinite: a `LazySeq` over an infinite range
  is handed over unrealized, as it was before, rather than iterated until
  memory runs out.

- A Go map key must be hashable, and `reflect.Type.Comparable` is not enough to
  decide it — a `struct{ X any }` holding a slice reports comparable and still
  panics when hashed. The insert is attempted behind a localized recover, so an
  unhashable key is a conversion error rather than a panic. That matters
  because `unboxMapInto` is reached from `RecordToStruct`, which has no recover
  of its own.

## The decision on key coercion

Settled explicitly, since it was the part flagged for review:

**Keyword keys become string keys, and do not come back as keywords.** So
`{:a 1}` round-trips as `{"a" 1}`.

Going to Go, this is not a new rule: `unboxInto`'s existing `reflect.String`
case already accepts a `Keyword`, and a keyword stores its name without the
leading colon. Coming back, a Go string key boxes to a let-go **string**.
Auto-keywordising would be wrong — Go map keys may contain spaces and dots,
which do not make valid keywords. Lossy but predictable, and it matches
`clojure.data.json` with no `:key-fn`.

One rejection follows from it: a **numeric key into a string-keyed Go map is an
error**, not a conversion. Go reports `int64` as `ConvertibleTo` `string` and
converts it to a rune, so the generic fallback would silently turn the let-go
key `65` into the Go key `"A"`. The rejection is local to the map path, so no
shared conversion behaviour changes.

## Verification

`make test`, `check-generated` and lint green on the PR branch.

End to end on the refreshed `go-deps-combined`, through a scratch `:go/local`
shim declaring plain Go signatures:

| direction | result |
|---|---|
| let-go map → `map[string]any` | arrives as a native Go map; a nested map arrives as `map[string]any` holding a native `[]any` |
| Go `map[string]any` → let-go | arrives as a real let-go map, read with `(get m "runtime")`; keyword lookup correctly misses |

The `examples/wails-desktop` example is unchanged: `stats` still returns
`{"count":3,"items":["a","b","c"],"runtime":"let-go","ui":"wails v3"}`.

## What the Wails shim can now drop

Narrower than it first looked. `asMap` and the `vm.Value` options parameters on
`New` and `NewWindow` can go — those become `map[string]any` directly.

**`ToGo` cannot.** `Bridge.Call` lowers `fn.Invoke`'s return value and `Emit`
lowers its `data`, and neither crosses a reflect boundary, so no automatic
conversion applies. let-go exports no deep let-go→Go converter — only
`vm.ToLetGo`, the other direction. That is a separate gap, not one this change
closes.

The simplification itself is left to a change in `letgo-packages`.
