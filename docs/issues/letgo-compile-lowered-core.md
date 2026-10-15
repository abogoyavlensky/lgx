# lg compile: compiled programs still call bytecode core

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1067](https://github.com/nooga/let-go/issues/1067).

Found while measuring let-go web-app performance (JSON APIs, DB-bound), on let-go main `d0108ba6`.

## Summary

Code built with `lg compile` lowers to Go, but its calls into core namespaces still run as bytecode on the VM. The generated module never links `pkg/rt/core_go_lowered`, and `clojure.string` has no lowered package at all. So for code that is mostly core calls, compiling barely helps.

Measured at `d0108ba6`.

## Example

```clojure
(defn escape-html [s]
  (str/escape (str s) {\< "&lt;" \> "&gt;" \& "&amp;" \" "&quot;"}))
```

`lowering-census.lg` reports the program at 100% lowered. The generated `EscapeHtml` still calls `ec.Invoke2(rt.CachedVarFnEC(..., "clojure.string", "escape"), ...)`, which runs the bytecode `escape`.

A small `http/serve` app (hiccup-style page rendering plus `json/write-json`), 50 connections:

| | page | JSON |
|---|---|---|
| bytecode VM | 120 req/s | 4.8k |
| `lg compile` | 123 | 4.7k |
| `lg compile` + blank imports of `core_go_lowered/{core,walk}` | 178 | 5.9k |

Linking the lowered core needs a hand-added file and a `replace` onto a checkout. `core_go_lowered` is a gitignored `make lowered` artifact, so it is in no published module. That's the same root cause as #940 for `-w`.

## Ask

- Let `lg compile` link the lowered core, for example with a flag, or by default when it is available.
- Make the lowered core available outside a checkout, which is where #940 also lands.
- Lower `clojure.string`, and the other embedded namespaces that application code calls.
