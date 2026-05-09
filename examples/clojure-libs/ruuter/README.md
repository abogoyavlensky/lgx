# ruuter — fails at let-go compiler

Fetch, resolve, and read all work; let-go's compiler rejects `def` with
a docstring at
[`src/ruuter/core.cljc:252`](https://git.nmm.ee/asko/ruuter/src/commit/31209771dafba33e36e8f72bbf31de95555ca511/src/ruuter/core.cljc#L252):

```clojure
(def ^:private compile-routes*
  "Memoized version of compile-routes for implicit compilation."
  (memoize compile-routes))
```

Error: `CompileError: def: wrong number of forms (3), need 1 or 2`.

Tracked as gap #2 in
[../../../docs/issues/clojure-lib-compat.md](../../../docs/issues/clojure-lib-compat.md).
