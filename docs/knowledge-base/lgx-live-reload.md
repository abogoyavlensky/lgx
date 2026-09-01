# Live reload for a running let-go app

Editing code and seeing a running program change, without restarting it.
The backend half works today with no changes to let-go or lgx; this note
records the technique, what it costs, and what an nREPL would add.

Written from the Wails desktop example, but the backend technique is not
Wails-specific: it applies to any long-running let-go program, an
`http/serve` process included.

## What was verified

The watcher below was run end to end against
[`examples/wails-desktop/`](../../examples/wails-desktop): a handler's
source was edited while the app was running, and the next call returned
the new result with no restart and no manual step. `emit!` on reload runs
clean.

Not verified: the browser receiving the reload event and re-rendering,
which needs a real webview. The fallback for that is one line, noted
below.

## The backend technique

Split the parts you want hot into their own file, and poll its mtime from
a `future`.

`handlers.lg` — re-evaluated on every save, so it holds registrations and
nothing else:

```clojure
(require '[wails.core :as w])

(w/handler! "greet"
  (fn [name] (str "Hello, " name "!")))
```

`main.lg` — sets up the app once, watches the other file:

```clojure
(defn- reload! [app]
  (try
    (load-string (slurp "handlers.lg"))
    (println "reloaded handlers.lg")
    (when app (w/emit! app "lg-reloaded" {}))
    (catch e (println "reload failed:" (ex-message e)))))

(defn- watch! [app]
  (future
    (loop [prev (:mod-time (os/stat "handlers.lg"))]
      (sleep 300)
      (let [now (:mod-time (os/stat "handlers.lg"))]
        (when (not= now prev) (reload! app))
        (recur now)))))
```

`future` is what keeps this legal: `run!` must block the main goroutine,
so the watcher cannot live there.

Note the primitives actually available. let-go has **no `load-file` and no
`load`**; `load-string` plus `slurp` is the reloading pair, and it
evaluates every form in the string, returning the last. `os/stat` returns
a record whose `:mod-time` is a string, which compares fine for change
detection.

### Why swapping a handler is safe

Two properties, neither of which had to be built:

- The Wails shim's registry is a `sync.Map` keyed by name, so
  `(w/handler! "greet" f)` is an atomic replace of a live entry.
- let-go's `Var.root` is an `atomic.Pointer[Value]` with lock-free reads
  (`pkg/vm/var.go`). Redefining a var while another goroutine derefs it
  yields either the old or the new value, never a torn one.

That matters because Wails dispatches frontend calls on its own
goroutines, so a reload always races live callers. It is safe by
construction rather than by locking.

### What it costs

- **Only the watched file is hot.** Editing `main.lg` still needs a
  restart, since that is where the app and window are built.
- **The file re-runs wholesale.** A `println` in it prints on every save.
  Keep it to registrations.
- **Guard it out of production builds.** The watcher is a dev
  convenience; put it behind an env check or a flag.
- Polling at 300ms is a deliberate choice over a filesystem-notify
  dependency. It costs one `stat` per tick.

## The frontend half, under Wails

Assets served with `http.FileServer(http.Dir(...))` are read from disk on
every request, so a running app already picks up edits; only the reload
trigger is missing. The cheapest trigger needs no Node:

```html
<script>
  let seen = null;
  setInterval(async () => {
    const t = await (await fetch("/", { cache: "no-store" })).text();
    if (seen !== null && t !== seen) location.reload();
    seen = t;
  }, 500);
</script>
```

`cache: "no-store"` is load-bearing: without it the conditional request
returns 304 and the text never changes.

To close the loop from the backend, have `reload!` emit an event and let
the page re-render:

```js
import { Call, Events } from "/wails/runtime.js";
Events.On("lg-reloaded", render);
```

If the event does not arrive, `setInterval(render, 500)` gets the same
effect by polling.

### Vite is more than an env var

`FRONTEND_DEVSERVER_URL` looks like a one-line answer and is not.
Wails reads it (`internal/assetserver/build_dev.go`), but `GetStartURL`
substitutes the dev server's port into the **window's** start URL, so the
page then loads from Vite. `import { Call } from "/wails/runtime.js"`
resolves against Vite, which does not have it, and in desktop mode there
is no HTTP port to proxy back to — assets go through the webview's custom
scheme. Wails' own templates import `@wailsio/runtime` from npm instead.

So real HMR means adding npm, that dependency, and changing the import.
Worth it if you want preserved page state; the poller above is enough for
a dev loop.

## Potential nREPL implementation

The watcher reloads a *file*. An nREPL would let you evaluate a form
against the live app — redefine one handler, inspect state, drive the UI —
which is the same mechanism with a better interface.

### Why `lgx nrepl` does not do this today

Two independent obstacles:

- **`lgx nrepl` starts a separate process.** `cmd-nrepl` in
  [`lgx.lg`](../../lgx.lg) launches `lg` in nREPL mode with the project
  basis. That is a fresh runtime, so it cannot see the handlers a running
  app registered.
- **The nREPL server needs a compiler context lgx cannot reach.**
  `nrepl.NewNreplServer(ctx *compiler.Context)` is constructed in let-go's
  `lg.go` from a local passed to `nreplServe`. Nothing exposes the running
  context to let-go code, so a `:go/local` shim cannot construct a server
  for the process it is running in.

### What it would take

An in-process start, exposed to let-go. `NreplServer.Start` already
returns after spawning its accept goroutine, so the ordering is
straightforward:

```clojure
(nrepl/start! 7888)   ; returns immediately
(w/run! app)          ; blocks the main goroutine
```

`run!` never returns, so the server has to start first.

The upstream shape is a small `pkg/rt` binding over the running context —
useful for any long-running let-go program, not only a desktop app, which
is the argument for it landing in let-go rather than in a wrapper package.

### The concurrency question, already answered

Evaluating on the nREPL's goroutine while Wails calls handlers on others
is the same race the file watcher already runs, and the same two
properties cover it: the atomic `Var.root` and the `sync.Map` registry.
Redefinition under load is safe.

### The real caveat: main-thread affinity

Redefining handlers is safe because they touch no UI. Evaluating
`(w/new-window app ...)` from the REPL goroutine is not: platform UI calls
must happen on the main thread, which `pkg/application/init_desktop.go`
pins at init.

Wails provides `dispatchOnMainThread` for this, but its public form is
`InvokeSyncWithResult[T]` — generic, so `lginterop` cannot see it (see
[`lgx-wails-desktop.md`](./lgx-wails-desktop.md)) and a shim wrapper would
be needed. So a first cut can reload logic freely; driving the UI from the
REPL needs that hop first.

---

> **Verify against (in this repo):**
> [`examples/wails-desktop/`](../../examples/wails-desktop),
> [`lgx.lg`](../../lgx.lg) (`cmd-nrepl`),
> [`lgx-wails-desktop.md`](./lgx-wails-desktop.md).
>
> **In [nooga/let-go](https://github.com/nooga/let-go):**
> `pkg/nrepl/server.go` (`NewNreplServer`, non-blocking `Start`),
> `lg.go` (`nreplServe`, where the context comes from),
> `pkg/vm/var.go` (`root` as `atomic.Pointer`),
> `pkg/rt/core/core.lg` (`future`, `sleep`, `load-string`, `slurp`),
> `pkg/rt/os.go` (`os/stat`).
>
> **In [wailsapp/wails](https://github.com/wailsapp/wails) (v3.0.0-beta.16):**
> `v3/internal/assetserver/build_dev.go` (`GetDevServerURL`),
> `v3/internal/assetserver/assetserver.go` (`GetStartURL`),
> `v3/internal/runtime/desktop/@wailsio/runtime/src/events.ts` (`Events.On`).
