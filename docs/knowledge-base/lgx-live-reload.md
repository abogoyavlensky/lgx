# Live reload for a running let-go app

Editing code and seeing a running program change, without restarting it.
There are two ways, and neither needs a change to let-go or lgx:

- **An nREPL inside the app**, from the
  [`nrepl`](https://github.com/abogoyavlensky/letgo-packages/tree/master/nrepl)
  package in letgo-packages. Your editor connects to the running program,
  and loading a buffer redefines its code in place. This is the one to use.
- **A file watcher**, a `future` that re-evaluates one file when it
  changes. No dependency, but only that file is hot.

Both work for any long-running let-go program, a Wails window or an
`http/serve` process alike. [`examples/wails-tasks`](../../examples/wails-tasks)
is the worked example of the first.

## The nREPL inside the app

```clojure
(require '[nrepl.core :as nrepl]
         '[string :as str])

(when-not (str/blank? (os/getenv "LGX_RUN"))   ; `lgx run` only
  (nrepl/start!))                              ; port 0: a free one, in .nrepl-port
(w/run! app)                                   ; then block as usual
```

`start!` returns at once (the server accepts on its own goroutine), so it
goes before the call that blocks. Test `LGX_RUN` for a non-blank value:
`os/getenv` returns `""` for an unset variable, and `""` is truthy, so a
bare `(when (os/getenv "LGX_RUN") ...)` would serve an nREPL from the
shipped binary too.

### Why `lgx nrepl` cannot do this

`lgx nrepl` starts a separate `lg` process, which cannot see a running
app's state. And `lg -n` itself starts its server only after the given
script returns (`pkg/cli`), which a program blocked in an event loop never
does. The `nrepl` package builds the server inside the process instead:
namespaces live in a process-global registry, so a fresh
`compiler.NewCompiler` context sees every var the program defined, and
`nrepl.NewNreplServer(ctx).Start(port)` serves it. let-go's own nREPL
tests construct a server exactly this way. The upstream fix would be for
`lg -n` to start the server before running the script; see
[`../issues/letgo-nrepl-with-script.md`](../issues/letgo-nrepl-with-script.md).

Two let-go facts shape it:

- **`*ns*` is process-global, and `NewCompiler` sets it.** Sessions all
  evaluate in the process's current namespace, so there is no per-server
  namespace option; `(in-ns 'x)` switches it, as in any REPL. The package
  restores the namespace after building its context, so starting a server
  changes nothing for the caller.
- **No `(require 'x :reload)`.** let-go 1.13.0 rejects the flag. Reload a
  namespace by loading its file: an editor's load-file sends the buffer,
  which re-evaluates every form in place.

### Make the parts you reload hot

Redefining a var changes every call that goes *through the var*. A fn
value captured earlier keeps the old code:

- **Register vars, not fns.** `(w/handler! "greet" #'greet)`, and
  `:on-click #'export!` in a menu spec. A `*vm.Var` implements `vm.Fn` and
  `Var.Invoke` reads the root on every call (`pkg/vm/var.go`), so the
  wails shim needs no special case.
- **Keep state in `defonce`.** Live state in a `defonce` atom survives a
  reload of its namespace. With integrant that is one atom holding the
  whole system (`tasks.system/system*` in wails-tasks), and components get
  their dependencies as arguments. A handler that needs the connection is
  registered as `(partial #'add-task conn)`: the partial keeps the var,
  so it stays hot.
- **Data is reloadable too.** A Wails menu spec is data: edit it, call
  `set-menu!` again, and the menu bar is rebuilt.
- **What `-main` built needs a restart.** The app and its windows. A
  Wails app cannot be halted and started again in one process, so the
  integrant reset cycle (halt, reload, init) does not apply to it.

### Why redefining under load is safe

Wails dispatches frontend calls on its own goroutines, so a redefinition
always races live callers. Two properties make that safe without locking:
let-go's `Var.root` is an `atomic.Pointer[Value]` with lock-free reads, so
a caller sees the old or the new fn and never a torn one; and the wails
shim's handler registry is a `sync.Map`.

### Main-thread work

Evaluation runs on the nREPL's goroutine. That is fine for logic and
state. Platform UI calls must run on the main thread, but Wails' own
window methods already move themselves there (`InvokeSync` inside, e.g.
`WebviewWindow.SetTitle`), so `(w/set-title! win "x")` from the REPL is
safe. For anything else, `(w/on-main! f)` wraps `application.InvokeSync`,
which, unlike `InvokeSyncWithResult[T]`, is not generic.

## The file watcher

Split the hot parts into their own file and poll its mtime from a
`future`:

```clojure
(defn- reload! []
  (try
    (load-string (slurp "handlers.lg"))
    (catch e (println "reload failed:" (ex-message e)))))

(defn- watch! []
  (future
    (loop [prev (:mod-time (os/stat "handlers.lg"))]
      (sleep 300)
      (let [now (:mod-time (os/stat "handlers.lg"))]
        (when (not= now prev) (reload!))
        (recur now)))))
```

let-go has no `load-file` and no `load`; `load-string` plus `slurp` is the
pair. The file re-runs wholesale on every save, so keep it to
registrations, and only that file is hot.

## The frontend half, under Wails

Serve the frontend from resources (`(w/new-app {:assets "public"})`):
under `lgx run` that reads the project's `:resource-paths` from disk on
every request, so a reload shows the edit. To trigger the reload,
`(w/watch-assets! win "resources/public")` reloads the window whenever a
file under the directory changes (it polls a fingerprint of the tree, so
a file with a future timestamp does not mask edits to the others).

Without the shim, a page can poll itself:

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

### Vite is more than an env var

`FRONTEND_DEVSERVER_URL` looks like a one-line answer and is not. Wails
reads it (`internal/assetserver/build_dev.go`), but `GetStartURL`
substitutes the dev server's port into the **window's** start URL, so the
page then loads from Vite. `import { Call } from "/wails/runtime.js"`
resolves against Vite, which does not have it, and in desktop mode there
is no HTTP port to proxy back to - assets go through the webview's custom
scheme. Wails' own templates import `@wailsio/runtime` from npm instead.
Real HMR means adding npm, that dependency, and changing the import; the
asset watcher is enough for a dev loop.

## What was verified

On Linux in Wails' server mode (2026-10-17): the `nrepl` package's tests
drive a real server over TCP, and `examples/wails-tasks/smoke.sh`
redefines a handler of the running app over its nREPL and sees the next
call return the new result. Not verified: the window reloading on an
asset change, which needs a real webview.

---

> **Verify against (in this repo):**
> [`examples/wails-tasks/`](../../examples/wails-tasks),
> [`lgx.lg`](../../lgx.lg) (`cmd-run` sets `LGX_RUN`, `cmd-nrepl`).
>
> **In [nooga/let-go](https://github.com/nooga/let-go):**
> `pkg/nrepl/server.go` (`NewNreplServer`, non-blocking `Start`),
> `pkg/nrepl/server_test.go` (a server built from `NewCompiler`),
> `pkg/cli/cli.go` (when `-n` starts the server),
> `pkg/compiler/compiler.go` (`NewCompiler` sets `rt.CurrentNS`),
> `pkg/vm/var.go` (`root` as `atomic.Pointer`, `Var.Invoke`).
>
> **In [letgo-packages](https://github.com/abogoyavlensky/letgo-packages):**
> `nrepl/shim/shim.go`, `nrepl/src/nrepl/core.lg`,
> `wails/shim/window.go` (`WatchAssets`, `InvokeSync`).
>
> **In [wailsapp/wails](https://github.com/wailsapp/wails) (v3.0.0-beta.30):**
> `v3/pkg/application/mainthread.go` (`InvokeSync`),
> `v3/pkg/application/webview_window.go` (methods hopping to the main thread),
> `v3/internal/assetserver/build_dev.go` (`GetDevServerURL`).
