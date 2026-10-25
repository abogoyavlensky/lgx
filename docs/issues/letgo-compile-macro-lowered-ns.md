# `lg compile`: a macro from a lowered namespace expands to symbols it cannot resolve

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1098](https://github.com/nooga/let-go/issues/1098)

Found while building Quel natively (`:target :native`), on let-go `main`
`18df3ad5` and lgx 0.5.1. Quel uses `sql.core/with-transaction` from
letgo-packages, and lgx then lowered every reachable namespace.

## Summary

When a syntax-quoted macro and the namespace that defines it are both passed
to `lg compile`, a caller's expansion cannot resolve the namespace's vars.
With the macro's namespace left as bytecode, the same program builds and
runs.

## Minimal repro

`m/core.lg`:

```clojure
(ns m.core)
(defn begin [x] x)
(defmacro with-begin [[s v] & body]
  `(let [~s (begin ~v)] ~@body))
```

`app.lg`:

```clojure
(ns app (:require [m.core :refer [with-begin]]))
(defn -main [& _] (with-begin [x 1] (println x)))
(-main)
```

`lg compile app.lg` builds and prints `1`. `lg compile app.lg m/core.lg`
fails with `Can't resolve begin in this context`, in either file order.

## lgx impact and workaround

Macros in dependencies are common, so `lgx build` with `:target :native`
lowers only the project's own namespaces by default and leaves dependency
namespaces as bytecode. `:native {:lower :all}` opts back in for deps that
lower cleanly. A project namespace that defines a syntax-quoted macro used
by another project namespace can still hit this.
