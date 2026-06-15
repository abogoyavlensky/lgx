# Issue: `http` server delivers `:request-method` as a String, not a Keyword

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

The built-in `http` server hands the handler a Ring-style request map,
but `:request-method` arrives as the **string** `"get"` rather than the
keyword `:get`. In Ring (and every router built on it) `:request-method`
is conventionally a keyword, so routers that match on it silently fail
to match every route.

The value starts life as a keyword and is then thrown away. In
[`pkg/rt/http.go:49-58`](https://github.com/nooga/let-go/blob/master/pkg/rt/http.go#L49)
`methodToLG` returns a `vm.Keyword`:

```go
func methodToLG(scheme string) vm.Keyword {
    return map[string]vm.Keyword{
        "GET": vm.Keyword("get"), "POST": vm.Keyword("post"), ...
    }[scheme]
}
```

but the request record is built with an explicit `string(...)` cast
([`pkg/rt/http.go:90-91`](https://github.com/nooga/let-go/blob/master/pkg/rt/http.go#L90)):

```go
req := httpRequestMapping.StructToRecord(HTTPRequest{
    RequestMethod: string(methodToLG(request.Method)),
    ...
})
```

because the struct field is typed `string`
([`pkg/rt/types.go:23-24`](https://github.com/nooga/let-go/blob/master/pkg/rt/types.go#L23)):

```go
type HTTPRequest struct {
    RequestMethod string `letgo:"request-method"`
    ...
}
```

So `StructToRecord` stores a `vm.String`. The keyword is correct right
up until the cast.

## Concrete impact

Wiring let-go's server to a third-party Ring router
([ruuter](https://git.nmm.ee/asko/ruuter), used in
`examples/server/`) returns 404 for every request, because ruuter
matches `(= (:method route) (:request-method req))` and
`(= :get "get")` is false. Every Ring router has the same shape, so this
bites any "use the built-in server with a real routing lib" setup. The
workaround is to keywordize in the handler before routing:

```clojure
(defn handler [req]
  (r/route routes (update req :request-method keyword)))
```

which works, but it is non-obvious (the value *looks* right when
`println`-ed as `get`) and every let-go user wiring up a router has to
rediscover it.

The other Ring keys are correctly string-typed — `:scheme`, `:uri`,
`:path`, `:query-string`, `:body` are genuinely strings in Ring too.
`:request-method` is the lone key that Ring specifies as a keyword.

## Proposal

Keep the method as a keyword end to end. Change the struct field to a
`vm.Value` (mirroring `Headers`, which is already `vm.Value`):

```go
type HTTPRequest struct {
    RequestMethod vm.Value `letgo:"request-method"`
    ...
}
```

and drop the cast at the call site:

```go
RequestMethod: methodToLG(request.Method),
```

`methodToLG` already returns `vm.Keyword`, which satisfies `vm.Value`, so
this is a two-line change. After it, `(:request-method req)` is `:get`
and Ring routers match without per-handler massaging. This is a
behavior change for anyone string-comparing the method today (e.g.
`(= "get" (:request-method req))`), but aligning with the Ring contract
is the right default and matches how the rest of the ecosystem reads the
key.
