# Issue: `BoxValue` wraps a `uint64` above `math.MaxInt64` to a negative Int

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft, worked around in letgo-packages `duckdb/shim`

## Summary

`vm.BoxValue` converts every unsigned integer kind with `Int(v.Uint())`
([`pkg/vm/value.go:192-193`](https://github.com/nooga/let-go/blob/main/pkg/vm/value.go#L192)):

```go
case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
    return Int(v.Uint()), nil
```

`Int` is an `int64`, so any `uint64` (or 64-bit `uint`) above
`math.MaxInt64` silently wraps to a negative number. No error, no
warning: the value is simply wrong.

## Repro

Any Go API returning a large `uint64` shows it. The case that found it is
DuckDB's `UBIGINT` through `database/sql`, scanned into `any` and boxed:

```clojure
;; duckdb-go/v2 driver, scanned by sql.shim/ScanRow
(sql.core/execute-one! conn ["select 18446744073709551615::UBIGINT as v"])
;; => {:v -1}
```

## Workaround

Convert before boxing. letgo-packages' `duckdb/shim` checks
`x > math.MaxInt64` and returns the value as a decimal string instead.

## Possible fixes

let-go already has an arbitrary-precision integer, `vm.BigInt`
(`pkg/vm/bigint.go`). Boxing to it when the value does not fit is the
fix that preserves the number:

```go
case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
    u := v.Uint()
    if u > math.MaxInt64 {
        return NewBigInt(new(big.Int).SetUint64(u)), nil
    }
    return Int(int64(u)), nil
```

Returning a type error instead would at least make the failure loud, but
loses a value that let-go can represent.

---

> **Verify against:** `pkg/vm/value.go` (`BoxValue`) and `pkg/vm/bigint.go`
> in [nooga/let-go](https://github.com/nooga/let-go);
> `duckdb/shim/shim.go` in
> [letgo-packages](https://github.com/abogoyavlensky/letgo-packages).
