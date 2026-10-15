# str on a StringBuilder returns #<java.lang.StringBuilder> instead of its contents

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1069](https://github.com/nooga/let-go/issues/1069).

Found while measuring let-go web-app performance, on let-go main `d0108ba6`.

## Summary

`str` and `format "%s"` on a `StringBuilder` return `#<java.lang.StringBuilder>` instead of its contents. `hostStringBuilder.String()` (`pkg/rt/host_stringbuilder.go`) returns the type name, and `str` uses it.

```clojure
(let [sb (StringBuilder.)]
  (.append sb "a") (.append sb 1)
  [(str sb) (format "%s" sb) (.toString sb)])
;; Clojure: ["a1" "a1" "a1"]
;; let-go:  ["#<java.lang.StringBuilder>" "#<java.lang.StringBuilder>" "a1"]
```

`(str sb)` is the usual way Clojure code finishes a builder, so ported code silently produces the type name instead of failing.

Seen at `d0108ba6`.

## Suggestion

Have `String()` return `s.b.String()`, so `str`, `format` and `println` match Clojure. `pr`/`pr-str` could keep an opaque `#object[java.lang.StringBuilder ...]`-style form, as Clojure does.
