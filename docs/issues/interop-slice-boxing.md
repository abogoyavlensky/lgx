# Issue: `[]any` does not cross the Go/let-go boundary as native values

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status: implemented (2026-08-23).** Both directions fixed on
`fix/vm-boxing-symmetry`, merged into `integration/go-interop`. Verified end to
end against the sqlite wrapper.

## Summary

Two gaps, mirror images of each other, both in `pkg/vm`. Neither is exercised
by anything in the let-go tree, which is why they survived; both were found by
building the first real wrapper library over `database/sql`.

`[]any` is the natural Go type for "a row of unknown column types", and a
let-go `nil` is the natural value for SQL NULL, so a wrapper hits both
immediately.

## What was found

**Boxing (Go to let-go).** `BoxValue`'s slice branch switched on the slice's
*static* element type. For a `[]any` that kind is `Interface`, so every element
missed the string/int/float paths and became an opaque `vm.Boxed`. Those print
as `<go.string Ada>` and compare equal to nothing:

```clojure
(= "Ada" (first (sql/ScanRow rows)))   ; => false
```

**Unboxing (let-go to Go).** Converting a let-go vector into a Go `[]any`
parameter gave up when an element had no Go counterpart and handed the whole
slice over as `[]vm.Value`, which the reflect call rejected:

```
reflect: Call using []vm.Value as type []interface {}
```

A let-go `nil` was the common trigger, so every NULL parameter failed.

The let-go guide's own `database/sql` worked example did not work as written,
which is the first thing a wrapper author copies.

## How it was found

Building the sqlite wrapper (`letgo-packages/sqlite`). The shim worked around
both by hand: `ScanRow` returned `[]vm.Value` and converted each column itself,
and `Query`/`Exec` took `[]vm.Value` and unboxed parameters themselves. That
works, but it pushes boxing knowledge into every wrapper anyone writes.

## The fix

Box interface-typed elements by their **dynamic** type, and make conversion
into `any` **total**.

Two details carried the work:

- A nil interface element must stay wrapped. `Elem()` on a nil interface yields
  the zero `reflect.Value`, and `BoxValue` reports an invalid value as an
  error, so unwrapping unconditionally turns every SQL NULL into a boxing
  error. Leaving it wrapped lets the existing nil-interface guard return `NIL`.

- Unwrapping is an **allowlist**, not an opt-out. `BoxValue` has paths that
  panic rather than error: its slice/array case calls `IsNil` (invalid for an
  array), the `[]byte`/`[]int64`/`[]float64` fast paths assert the exact slice
  type, and `ChanType.Box` spawns a goroutine calling `Recv`, which on a
  send-only channel panics in *another* goroutine and takes the process down.
  Those predate this work, but unwrapping would newly route `[]any` elements
  into them, and the channel case cannot be contained by any local recover.
  Only exact predeclared scalars, exactly `[]byte`/`[]int64`/`[]float64`, and
  `[]any` are unwrapped; everything else boxes exactly as before.

## Verification

`make test` and the 6311-assertion `clojure-compat-report` green, unchanged,
after every commit.

End to end against the sqlite wrapper, with its shim rewritten to the plain
`[]any` shapes the let-go guide documents:

| runtime | result |
|---|---|
| without the fix | `reflect: Call using []vm.Value as type []interface {}` |
| with the fix | rows read back as native values, `(= "Ada" (:name r))` is `true`, a `nil` parameter inserts SQL NULL, a NULL column reads back as `nil` |

So the wrapper's hand-written workarounds are no longer necessary. The shim was
reverted afterwards; what its final shape should be is a separate decision.

The let-go guide's sketches were corrected in the same PR, including a second
instance of `(apply sql/Exec db q params)` that has never been possible:
`Exec` is a method, methods are not first-class values in let-go, and `apply`
needs a function value to spread into.
