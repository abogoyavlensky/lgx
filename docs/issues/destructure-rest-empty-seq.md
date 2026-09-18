# Issue: `[x & more]` destructuring binds `more` to `()` where Clojure binds `nil`

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

Vector destructuring expands the `&` rest binding with `drop`
([`pkg/rt/core/core.lg:754`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/core.lg#L754),
at `f26eb497`):

```clojure
(= x '&) (recur (drop 2 e) i (conj o (second e) (list 'drop i n)))
```

Clojure's `destructure` uses `nthnext`, so when nothing is left the rest
binding is `nil`. Under let-go it is an empty lazy seq, which is truthy:

```clojure
(let [[a & more] (list 1)] more)  ; Clojure: nil   let-go 1.12.2: ()
(let [[a & more] nil] more)       ; Clojure: nil   let-go 1.12.2: ()
```

Plain fn rest args are unaffected (`((fn [a & more] more) 1)` is `nil`;
the compiler handles them). Only `let`/`loop` vector destructuring goes
through `destructure-vector`.

## Why it matters

The idiom `(if-let [[x & xs] coll] ... )` / `(when-let [[x & xs] s] ...)`
relies on the rest seq becoming `nil` to terminate a loop.
[`weavejester/dependency`](https://github.com/weavejester/dependency) 1.0.1
uses it in `reachable?`:

```clojure
(loop [unexpanded (seq (neighbors from)) visited #{}]
  (if-let [[node & more] unexpanded]
    (cond
      (= node to) true
      (contains? visited node) (recur more visited)
      :else (recur (concat more (neighbors node)) (conj visited node)))
    false))
```

Once `unexpanded` is `(concat () nil)` the loop binds `node` to `nil`,
finds it in `visited`, recurs with `more` = `()` (truthy), and never
exits. `dep/depend` calls `reachable?` on every edge whose target already
has an edge, so any integrant config with a three-component chain
(`server -> handler -> db`) hangs in `ig/init` - or not, depending on
the map iteration order `dependency-graph`'s `reduce-kv` happens to
walk, which is what kept lgx's two-component `with-integrant` example
green.

Repro, on lg 1.12.2 and on `main` at `f26eb497`:

```clojure
(require '[weavejester.dependency :as dep])
(-> (dep/graph)
    (dep/depend :b :a)
    (dep/depend :c :b))   ; never returns
```

## Fix

Bind the rest to a seq that is `nil` when empty. `nthnext` is defined
after `destructure-vector` in `core.lg`, so the smallest change that
resolves at bootstrap is:

```clojure
(= x '&) (recur (drop 2 e) i (conj o (second e) (list 'seq (list 'drop i n))))
```

with a test asserting `(nil? (let [[a & more] [1]] more))` and the
`dep/depend` chain above terminating.

## Verify against (in [nooga/let-go](https://github.com/nooga/let-go))

- `pkg/rt/core/core.lg` - `destructure-vector`
