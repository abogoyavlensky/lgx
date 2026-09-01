# wails-desktop

A desktop app whose UI is HTML and whose logic is let-go, built on
[Wails v3](https://v3.wails.io) through the
[`wails`](https://github.com/abogoyavlensky/letgo-packages/tree/master/wails)
package.

This is the `:go/*` pipeline's most demanding consumer: Wails is a large
cgo dependency, it calls back into let-go from its own goroutines, and its
API is entirely struct literals and generics — so unlike the sqlite stack,
none of it is reachable through `lginterop`. The package's Go shim is what
closes that gap; this example only ever sees let-go.

```clojure
(w/handler! "greet" (fn [name] (str "Hello, " name "!")))
```

```js
await call("greet", "world");   // => "Hello, world!"
```

## Running it

Wails is cgo on the Unix desktops, so this example needs more than a Go
toolchain:

| Platform | Needs |
|---|---|
| Linux | `libgtk-4-dev libwebkitgtk-6.0-dev` and a C compiler |
| macOS | Xcode command line tools |
| Windows | not supported — let-go does not build for `GOOS=windows` yet |

```sh
lgx run                     # first run builds the custom runtime, ~1 min
lgx build && ./bin/app      # or a single binary
```

Without the platform webview headers you can still exercise everything but
the window, using Wails' cgo-free server mode — an HTTP server and your
browser instead of a native webview:

```sh
CGO_ENABLED=0 GOFLAGS=-tags=server lgx run    # then open http://localhost:8080
```

Both env vars are needed: a few of Wails' internal packages gate on
`linux && cgo` without a `!server` guard.

## What to look at

- `main.lg` — the whole app. Note `(when-not *compiling-aot* (-main))`:
  `lg -b` runs top-level forms at compile time, so without it `lgx build`
  would start the event loop while bundling.
- `frontend/index.html` — the three-line `Call.ByName` helper that reaches
  a handler. There is no generated bindings module, because there are no
  Go methods to generate from.

See [`docs/knowledge-base/lgx-wails-desktop.md`](../../docs/knowledge-base/lgx-wails-desktop.md)
for how the pieces fit and what the limits are.
