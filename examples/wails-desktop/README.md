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

## Prerequisites

Wails is a `:go/*` dep, so this needs a `lg` carrying the still-open
out-of-tree-interop work. A prebuilt branch with all of it merged is on
[`abogoyavlensky/let-go@go-deps-combined`](https://github.com/abogoyavlensky/let-go/tree/go-deps-combined):

```sh
git clone https://github.com/abogoyavlensky/let-go.git
cd let-go && git checkout go-deps-combined && make build SMOKE-BOOT-BUDGET-MS=40
cd /path/to/lgx && make build LG=/path/to/let-go/bin/lg
```

Then every command below wants `LGX_LETGO_REPLACE=/path/to/let-go` in its
environment. See [`docs/go-deps-pr-verification.md`](../../docs/go-deps-pr-verification.md).

## Running it

Wails is cgo on the Unix desktops, so this example needs more than a Go
toolchain:

| Platform | Needs |
|---|---|
| Linux | `libgtk-4-dev libwebkitgtk-6.0-dev` and a C compiler |
| macOS | Xcode command line tools |
| Windows | not supported — let-go does not build for `GOOS=windows` yet |

Confirmed working on macOS (Wails v3.0.0-beta.16). The Linux GTK path
should work but has not been run.

```sh
export LGX_LETGO_REPLACE=/abs/path/to/let-go   # see Prerequisites
lgx run                     # first run builds the custom runtime
lgx build && ./bin/app      # or a single binary
```

Give `LGX_LETGO_REPLACE` an absolute path. It resolves against the current
directory, and you run these from inside this one, so `../let-go` means
`examples/let-go` and fails with a wall of `go mod tidy` output about a
missing replacement directory.

The first build takes a few minutes on macOS (the Objective-C compile of
Wails' Cocoa layer) and is cached afterwards. Run from this directory
either way — `assets-dir` is resolved against the process working
directory.

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
for how the pieces fit and what the limits are, and
[`lgx-live-reload.md`](../../docs/knowledge-base/lgx-live-reload.md) for
editing handlers without restarting the app.
