# Desktop apps: Wails v3 under lgx

[Wails v3](https://v3.wails.io) pairs a Go backend with a webview
frontend. Running it under let-go works, and
[`examples/wails-desktop/`](../../examples/wails-desktop) is the worked
example. This note records how the pieces fit, what was actually
verified, and where the edges are — the things that are not obvious from
either project's docs.

## What was verified

**A native window, on macOS** (2026-09-01, Wails v3.0.0-beta.16): a real
WKWebView window created from let-go, both handlers answering
`Call.ByName`, and a let-go map arriving in the frontend as a JSON object
with its nested vector intact. cgo, the Cocoa platform layer and the
webview are all exercised. Nothing needed packaging into a `.app` —
`ActivationPolicyRegular` is the zero value, so the bare binary shows and
focuses a window.

**The rest, on linux/amd64:** Wails linked into an lgx-built runtime,
values crossing both ways, errors propagating, custom assets served, and
`lgx build` producing a standalone binary. That machine had no
GTK4/WebKitGTK, so it ran in Wails' cgo-free `-tags server` mode — an HTTP
server and a browser instead of a webview.

**Still untested: the Linux GTK4/WebKitGTK window.** macOS covers the
"desktop app" claim, and the two platform layers share everything above
them, but the GTK path has not been run. Say so rather than generalising
from macOS.

## The shape that works

All the Go lives in one hand-written shim, published as the
[`wails`](https://github.com/abogoyavlensky/letgo-packages/tree/master/wails)
package in letgo-packages. A project depends on that package and writes
only let-go.

```
frontend (JS)  --Call.ByName-->  Wails message processor
                                        |
                                 Bridge.Call  (the one bound Go method)
                                        |
                                 vm.Fn.Invoke --> a let-go handler
```

## Why none of it is generated

The other Go wrappers in letgo-packages lean on `lginterop`. This one
generates nothing, and cannot:

- **`-opaque-structs` means no constructors.** lgx always passes it
  (`lgx/gobuild.lg`), and `cmd/lginterop/lginterop.lg` then skips
  `vm.RegisterStruct` emission, so the generated namespace holds only
  package-level funcs and vars. Every Wails entry point takes a struct
  literal — `application.Options`, `WebviewWindowOptions` — and let-go has
  no way to build one.
- **Generics are skipped silently.** `application.NewService[T]`,
  `RegisterEvent[T]` and `InvokeSyncWithResult[T]` all vanish, with no
  warning, because `generic?` gates lginterop's emission sites. Service
  registration is the whole backend.
- **Wails binds a Go type's methods**, discovered reflectively. A let-go
  fn is not a Go method, so there is nothing to bind.

The escape hatch is that Wails resolves bound methods by fully-qualified
*name* at run time (`Call.ByName`, `pkg/application/bindings.go:173`), so
one Go method is enough for a whole app and `wails3 generate bindings` —
a static analyser over Go source — never enters the picture. You trade
generated TypeScript types for a three-line JS helper.

A consequence worth stating plainly: `:go/interop` is the wrong tool for
any framework-shaped library. It carries flat, function-oriented APIs like
`database/sql` well; it carries nothing that is configured by struct
literal or parameterised by generics. Reach for a `:go/local` shim
instead, and do not spend time trying to make interop work first.

## Things that bite

**cgo, and therefore no cross-compilation.** Wails is cgo on Linux (GTK4 +
WebKitGTK 6.0) and macOS (Cocoa); only Windows is pure Go. lgx forces
`CGO_ENABLED=0` on every `lgx build --target`
(`lgx/gobuild.lg`), so a cross-built GUI binary is not
possible — build on the machine you ship for. And Windows, the one
platform that would cross-build cleanly, is blocked by let-go itself
(see [`issues/windows-build-unix-only-term.md`](../issues/windows-build-unix-only-term.md)).

**Build tags have no config key.** Wails wants `-tags production` for
release builds and `-tags server` for headless. lgx has no `:go/build-tags`
(see [`issues/lgx-no-go-build-tags.md`](../issues/lgx-no-go-build-tags.md));
`GOFLAGS=-tags=...` in the environment reaches `go build` and works. Note
that `lginterop`'s own `-build-tags` flag does *not* help: it only emits a
`//go:build` line into the generated file and has no effect on the scan.

**Maps do not cross the boundary.** `[]any` does, since
`fix/vm-boxing-symmetry`, but a let-go map handed to a Go
`map[string]any` parameter fails with `reflect: Call using
*vm.PersistentMap as type map[string]interface {}`. Every shim entry point
taking options declares `vm.Value` and converts. Converting is its own
trap: a let-go map is a `*vm.PersistentMap` whose `Seq` yields
`vm.MapEntry`, so a type switch on `vm.Map` alone compiles, runs, and
silently turns every map into a list of pairs — JSON arrays where the
frontend expects objects. See
[`issues/interop-map-boxing.md`](../issues/interop-map-boxing.md).

**AOT runs your top-level forms.** `lgx build` started the Wails event
loop at compile time. `(when-not *compiling-aot* (-main))` is required,
and `application.New` has to be *inside* `-main` too: guarding only the
`Run` call still constructs the app and sets Wails' global while bundling.
This is the general
[bundling gotcha](./let-go-gotchas.md), but a GUI framework makes it
loud.

**A `:go/local` module path needs a dot in its first segment**, or lgx
classifies it as stdlib and rejects the coord: `module lgxwails/shim`
gives ":go/local do not apply ... is a standard-library package". See
[`issues/lgx-go-local-stdlib-heuristic.md`](../issues/lgx-go-local-stdlib-heuristic.md).

## Things that turned out fine

**The main thread.** Wails' `pkg/application/init_desktop.go` calls
`runtime.LockOSThread()` from `init()`, which runs before `main`, and `lg`
runs the script on the main goroutine. So a let-go program reaching
`app.Run()` is already on the main OS thread, with nothing to arrange.
The one rule: call it from the entry fn, not from a spawned thread.

**Calling let-go from Go's goroutines.** Wails dispatches service calls on
its own goroutines, and the shim invokes let-go fns from them. That is the
same thing `pkg/rt/http.go` already does for `http/serve` handlers.

**The dev loop.** A running app can reload its handlers from disk with no
restart, which `wails3 dev` cannot do — a Go backend has to rebuild and
relaunch. See [`lgx-live-reload.md`](./lgx-live-reload.md) for the watcher
and for why an nREPL cannot attach to a running app yet.

Build times, measured on linux/amd64 with warm Go caches: about 0.3s
when only `.lg` files changed, about 1.4s after a Go edit to the shim (a
full recompile and relink of the ~24 MB runtime). `:go/local` makes lgx
re-run the build steps every time, but Go's build cache absorbs it.

**Packaging composes.** `wails3 build` is just `go build`; the packaging
steps (`wails3 generate icons`, app bundles, dmg, AppImage, NSIS) are
separate subcommands that operate on an already-built binary plus a
`build/` directory. They work on an lgx-produced binary — wire them
through `:tasks`.

## Reproducing the verification

Wails is a `:go/*` dep, so it needs the whole go-deps stack; see
[`../go-deps-pr-verification.md`](../go-deps-pr-verification.md) for
building a combined `lg`. Then:

```bash
cd examples/wails-desktop
LGX_LETGO_REPLACE=/abs/path/to/let-go lgx run
```

Native needs Xcode command line tools on macOS, or GTK4 + WebKitGTK 6.0
dev packages on Linux. Give `LGX_LETGO_REPLACE` an **absolute** path: it
is resolved against the current directory, and the command is run from
inside `examples/wails-desktop`, so a relative path aimed at a sibling of
the repo silently becomes `examples/<name>` and surfaces as a wall of
`go mod tidy` output about a missing replacement directory.

On macOS the first build takes a few minutes — the Objective-C compile of
Wails' Cocoa layer — and is cached afterwards.

Without the platform headers, in server mode:

```bash
CGO_ENABLED=0 GOFLAGS=-tags=server \
  LGX_LETGO_REPLACE=/path/to/let-go lgx run
```

Both env vars are needed: several of Wails' internal packages gate on
`linux && cgo` without a `!server` guard, so the tag alone still pulls in
the GTK cgo files. Then drive a handler over the runtime's own HTTP
transport:

```bash
curl -s -X POST http://localhost:8080/wails/runtime \
  -H 'Content-Type: application/json' -H 'x-wails-client-id: probe' \
  -d '{"object":0,"method":0,"args":{"call-id":"c1",
       "methodName":"github.com/abogoyavlensky/letgo-packages/wails/shim.Bridge.Call",
       "args":["greet",["world"]]}}'
# => Hello, world! (from let-go)
```

`object: 0` is `callRequest` and `method: 0` is `CallBinding`
(`pkg/application/messageprocessor.go`); `call-id` is mandatory and must
be unique per in-flight call.

---

> **Verify against (in this repo):**
> [`lgx/gobuild.lg`](../../lgx/gobuild.lg) (cgo settings, build steps),
> [`lgx/config.lg`](../../lgx/config.lg) (`:go/*` coord validation),
> [`examples/wails-desktop/`](../../examples/wails-desktop).
>
> **In [nooga/let-go](https://github.com/nooga/let-go):**
> `cmd/lginterop/lginterop.lg` (`generic?`, `opaque-structs?`),
> `pkg/vm/value.go` (`BoxValue`, `ToLetGo`),
> `pkg/rt/http.go` (invoking a let-go fn from a Go goroutine).
>
> **In [wailsapp/wails](https://github.com/wailsapp/wails) (v3.0.0-beta.16):**
> `v3/pkg/application/services.go` (`NewService[T]`),
> `v3/pkg/application/bindings.go` (name-based dispatch),
> `v3/pkg/application/init_desktop.go` (`LockOSThread`),
> `v3/pkg/application/messageprocessor_call.go` (the call protocol).
>
> **In [letgo-packages](https://github.com/abogoyavlensky/letgo-packages):**
> `wails/shim/shim.go`, `wails/src/wails/core.lg`.
