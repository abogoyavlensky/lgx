# json/write-json: encode values directly instead of via map[string]any + encoding/json

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1066](https://github.com/nooga/let-go/issues/1066).

Found while measuring let-go web-app performance (JSON APIs, DB-bound), on let-go main `d0108ba6`.

## Summary

`json/write-json` converts the value to `map[string]any`/`[]any` (`fromValue`, `pkg/rt/json_value.go`), then calls `encoding/json.Marshal`. That pays for two allocation passes, plus reflection and key sorting in `encoding/json`. A JSON API spends most of its handler CPU here.

## Numbers

Go benchmark at `d0108ba6`, 50 maps `{:id :name :price :tags [3 strings]}`, 3.5 KB of output:

| | ns/op | allocs/op |
|---|---|---|
| `json/write-json` | 188,000 | 1970 |
| `encoding/json.Marshal` on equivalent `[]map[string]any` | 128,000 | 603 |
| direct encoder walking `vm.Value` into a `[]byte` | 45,000 | 902 |

CPython 3.14's `json.dumps` takes 51 µs on the same data and machine.

The direct encoder is ~60 lines: a type switch over `String`/`Keyword`/`Int`/`Boolean`/maps/sequables, `strconv.Append*`, and a hand-rolled string quoter. It iterates maps with `eachEntry`. Iterating with `Seq()` allocates an entry per key, and with it the encoder took 99 µs.

## Open questions

- Key order: `encoding/json` sorts map keys; a direct encoder writes them in map order (as Cheshire and jsonista do).
- Escaping: match `encoding/json`'s HTML escaping of `<>&`, or not.
- `read-json` has the same shape (`decodeJSON` into `any`, then `toValue`). I have not profiled it, but it takes 360–400 µs on the 3.5 KB string, against 39 µs for CPython's `json.loads`.
