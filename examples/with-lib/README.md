# with-lib example

Proves that lgx fetches a real public dep and exposes its namespaces to
`lg` end-to-end.

## Why let-go itself as the "lib"

There's no third-party let-go library ecosystem yet, and pure Clojure
libraries hit several let-go-side compat gaps (see
[../../issues/clojure-lib-compat.md](../../issues/clojure-lib-compat.md)).
let-go's own repo happens to contain `.lg` files with clean `(ns …)`
declarations under `test/` (e.g., `test.fib`, `test.primes`), which makes
it a convenient real public github dep to require from a user script.

Replace this with a real let-go library when one becomes available.

## Running

```
LGX_LG=/path/to/lg ../../bin/lgx run main.lg
```

`LGX_LG` should point to an `lg` build that supports `-source-paths`
(nooga/let-go feat-source-paths or later).

## Expected output

```
fib(10): 89
fib(15): 987
```
