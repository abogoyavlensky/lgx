# Issue: `http` server panics on a response with `:headers {}`

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

A handler response carrying an empty headers map crashes the connection
with a nil dereference in the header loop
([`pkg/rt/http.go:134`](https://github.com/nooga/let-go/blob/main/pkg/rt/http.go#L134)
at `f26eb497`, `v := es.Next().First()`), and the client sees no reply
at all:

```clojure
(http/serve (fn [_] {:status 204 :headers {} :body ""}) ":8099")
```

```
http: panic serving [::1]:45470: runtime error: invalid memory address or nil pointer dereference
github.com/nooga/let-go/pkg/rt.(*Handler).ServeHTTP  pkg/rt/http.go:134
```

`{:status 204 :body ""}` (no `:headers` key) and a non-empty headers map
both work. Reproduced on lg 1.12.2 and on `main` at `f26eb497`.

`{}` is the natural value for "no headers" in a Ring response, so the
empty case should be handled before the entry loop (or the loop should
skip an entry with no value rather than dereference it).

## Verify against (in [nooga/let-go](https://github.com/nooga/let-go))

- `pkg/rt/http.go` - `Handler.ServeHTTP`, the `:headers` loop
