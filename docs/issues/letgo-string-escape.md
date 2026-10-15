# clojure.string/escape ignores a fn cmap, and costs ~10 µs per short string

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1068](https://github.com/nooga/let-go/issues/1068).

Found while measuring let-go web-app performance, on let-go main `d0108ba6`.

## Summary

`clojure.string/escape` (`pkg/rt/core/string.lg`) is `(apply str (map (fn [c] (or (get cmap c) c)) s))`. That has two problems.

1. **A function `cmap` is ignored.** Clojure's docstring says `cmap` "may be a map or a function", and `get` on a fn returns nil.

   ```clojure
   (str/escape "a<b" (fn [c] (when (= c \<) "&lt;")))
   ;; Clojure: "a&lt;b"    let-go: "a<b"
   ```

2. **It is slow.** A lazy seq over the characters plus `apply str` costs about 10 µs for `"Item <5>"` with a four-entry map. HTML escaping calls it once per text node and attribute, so it dominated a hiccup-style page renderer: about 600 calls took roughly 7 ms of a 9–12 ms render.

Measured at `d0108ba6`.

## Numbers

| | per call, `"Item <5>"` |
|---|---|
| `str/escape` today | 10.4 µs |
| Go loop over runes with `ValueAt(vm.Char(r))` into a `strings.Builder` | 1.0 µs |
| CPython `html.escape` | 0.36 µs |

## Suggestion

A native `escape` that calls `cmap` when it is a fn and looks it up otherwise, writing into a `strings.Builder`. It could return `s` unchanged when nothing matched, so a clean string costs no allocation.
