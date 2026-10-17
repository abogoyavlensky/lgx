# Wails desktop: a first real app, with live nREPL Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: completed and released 2026-10-17 (Task 22, the native checklist, is the user's).**

**Goal:** Build a first real let-go desktop app (a task manager on Wails v3) and fill the gaps it exposes: a broader `wails` shim, a new `nrepl` package that serves an nREPL from inside a running program, and `:go/build-tags` in lgx. Then correct the knowledge base.

**Tech Stack:** let-go 1.13.0 (`.lg`), Go 1.26 toolchain, Wails v3.0.0-beta.30, sqlite + ragtime + honeysql from letgo-packages, Alpine.js (vendored, no npm), `lgx test` / clojure.test, python3 for the nREPL smoke client.

**Repos:**
- Parts 1 and 2 happen in `/home/agent/Projects/letgo-packages` (the `nrepl` and `wails` packages).
- Parts 3–5 happen in this repo (`/home/agent/Projects/lgx`).
- Part 4 consumes Parts 1–3. Until their tags exist, it develops against `:local/root` coords.
- Release steps (pushing tags, opening PRs) are outward-facing. **Stop and ask the user before each one.**

**Verification limits:** this Linux machine has no GTK4/WebKitGTK headers and no sudo. Everything below runs in Wails' cgo-free server mode (`CGO_ENABLED=0 GOFLAGS=-tags=server`). The native window, menus, dialogs and asset reload need the user to check them on macOS; Task 22 is that checklist. Never report a native behaviour as verified.

---

## Design

### Where things stand

- `examples/wails-desktop` works on macOS (beta.16). Its shim (`letgo-packages/wails/shim/shim.go`) exposes `New`, `NewWindow`, `Register`, `Emit`, `Run` and `Quit`, with a handful of hand-mapped option keys. It is released as a tagged Go module (`wails/shim/v0.1.0`).
- Hot reload today is a `future` that polls one file and calls `load-string` on it (`docs/knowledge-base/lgx-live-reload.md`).
- The KB is wrong in two places, and this plan builds on the corrected facts:
  1. **The nREPL can run inside the app.** Namespaces live in a process-global registry. let-go's own tests build a working server with `compiler.NewCompiler(vm.NewConsts(), rt.NS(rt.NameCoreNS))` and `nrepl.NewNreplServer(ctx)` (`pkg/nrepl/server_test.go:79`). `Start` returns after spawning its accept goroutine and writes `.nrepl-port`. The server supports `eval` and `load-file`. Upstream `lg -n <script>` starts its nREPL only *after* the script returns (`pkg/cli/cli.go:689`), and a Wails app never returns, so a package is the way in.
  2. **Main-thread affinity is mostly handled by Wails.** Its public window methods already hop to the main thread with `InvokeSync` (e.g. `SetTitle`, `webview_window.go:427`). `InvokeSync(func())` and `InvokeAsync(func())` are not generic; only the `...WithResult[T]` forms are.
- `(require 'x :reload)` fails under let-go 1.13.0 (`require expected Symbol or Vector, got Keyword`, checked 2026-10-16). Namespace-granular reload therefore goes through nREPL `load-file` or `eval`, not `require`.
- beta.16 → beta.30: the `Options` and `WebviewWindowOptions` field sets barely moved (`ApplicationID` was added). The app API uses managers (`app.Window`, `app.Menu`, `app.Dialog`, `app.Event`). In server mode, menus are no-ops and file dialogs return an error. Both are safe to call.
- `lgx run` sets `LGX_RUN=1` and auto-applies the `:dev` context. `lgx build` embeds `:resource-paths` into the binary. Go code reaches resources through `rt.GetResourceProvider().Open(name)`. That is a disk-backed provider under `lgx run` and an embedded one in a built binary.

### Part 1: the `nrepl` package (letgo-packages)

This is a new package, `nrepl/`, with an **in-tree shim** (`{:go/local "shim"}`). It follows the README's model for new shim packages: no Go module tag, and it releases with the package tag alone.

Go (`nrepl/shim/shim.go`, namespace `nrepl.shim`):

```go
// Start serves nREPL on 127.0.0.1:port (0 = OS-picked) for the running
// process, evaluating in namespace nsName. Returns the bound port.
func Start(port int, nsName string) (int, error)
func Stop() error        // no-op when not running
func Port() int          // 0 when not running
```

- One server per process, kept in a mutex-guarded package var. A second `Start` while running returns an error naming the port.
- The context is `compiler.NewCompiler(vm.NewConsts(), ns)`. `ns` is `rt.NS(nsName)`; when that is nil, create the namespace the way let-go's `in-ns` does and refer `clojure.core`. Read `pkg/rt` for the right call rather than guessing. Acceptance: in a fresh session, `(+ 1 2)` returns `3` and `(ns-name *ns*)` returns the requested name.
- Binds loopback only. This is inherited from `NreplServer.Start` and is load-bearing for safety.

let-go veneer (`nrepl/src/nrepl/core.lg`, ns `nrepl.core`):

```clojure
(nrepl/start! {:port 0 :ns "user"})  ; => bound port; both keys optional
(nrepl/stop!)
(nrepl/port)                         ; => port or nil
```

The package does not decide when to start. Apps gate it themselves; the task app gates on `LGX_RUN`.

### Part 2: `wails` v0.2.0 (letgo-packages)

- **Bump** to `v3.0.0-beta.30`.
- **Move the shim in-tree:** `wails/lgx.edn` switches from `{:go/version "v0.1.0"}` to `{:go/local "shim"}`, matching livekit. This retires the Go-tag dance for wails. The README's "In-tree shims" paragraph and CI comment drop `wails` from the tagged list. The old `wails/shim/v0.1.0` tag stays as history.
- **Option keys accept keywords or strings.** `ToGo` already lowers a keyword key to its name, so `{:title "x"}` and `{"title" "x"}` are the same. New docs use keywords.

The full let-go surface after this change. Existing fns keep their signatures; the tasks must agree on these names:

```clojure
(w/new-app {:name "" :description ""
            :assets "public"            ; NEW: resource prefix, served via rt.GetResourceProvider
            :assets-dir "frontend"      ; kept: on-disk dir, cwd-relative
            :quit-on-last-window-closed true   ; NEW: Mac.ApplicationShouldTerminateAfterLastWindowClosed
            :on-shutdown f})            ; NEW: called with no args
(w/new-window app {:title "" :width 800 :height 600
                   :min-width 0 :min-height 0 :url "/" :hidden false}) ; min-*/hidden NEW
(w/set-title! win s) (w/show! win) (w/hide! win) (w/close! win)
(w/focus! win) (w/reload! win) (w/exec-js! win js)                    ; NEW
(w/handler! "name" #'f)         ; var or fn; a var is re-derefed on every call
(w/emit! app "name" data)
(w/on-event! app "name" f)      ; NEW: frontend Events.Emit("name", data) -> (f data)
(w/set-menu! app spec)          ; NEW: data-driven application menu, see below
(w/open-file app {:title "" :filters [["JSON" "*.json"]]})       ; NEW: path or nil
(w/save-file app {:title "" :filename "" :filters [...]})        ; NEW: path or nil
(w/message! app :info "Title" "Body")   ; NEW: kind :info|:warning|:error
(w/on-main! f)                  ; NEW: application.InvokeSync
(w/data-dir "app-name")         ; NEW: os.UserConfigDir()/app-name, created; path string
(w/watch-assets! win "resources/public") ; NEW, dev only: poll mtimes, (reload! win) on change; returns a stop fn
(w/run! app) (w/quit! app)
```

**Serving assets from resources.** `:assets "public"` serves URL path `/x` as the resource `public/x`, and `/` as `public/index.html`. Content-Type comes from `mime.TypeByExtension`; a missing resource is a 404. The same code serves files from disk under `lgx run`, so edits show up on the next request, and from the embedded archive in a built binary. That fixes the blank window a `.app` gets when started from Finder with cwd `/`. Normalize names with `rt.NormalizeResourceName` and reject `..`.

**Menu spec.** This is data, so `set-menu!` can be re-run from the REPL to rebuild the menu live:

```clojure
[{:role :app-menu}                                   ; macOS application menu
 {:label "File"
  :items [{:label "Export…" :accelerator "CmdOrCtrl+E" :on-click #'export!}
          {:separator true}
          {:role :quit}]}
 {:role :edit-menu}                                  ; copy/paste work only with this on macOS
 {:role :window-menu}]
```

- Supported roles: `:app-menu :file-menu :edit-menu :view-menu :window-menu :help-menu :quit :about :close-window :reload`. An unknown role or a malformed item is an error that names the offending path.
- The Go builder walks the `vm.Value` directly rather than going through `ToGo`, because `:on-click` must stay a `vm.Fn`.
- `:on-click` is called with no args.

**Callbacks into let-go** (menu clicks, `on-event!`, `on-shutdown`) go through one Go helper. It invokes the `vm.Fn` and, on error, writes `wails: <where>: <err>` to stderr. It never panics a Wails goroutine. Passing a var instead of a fn makes any callback hot. A `*vm.Var` satisfies `vm.Fn` (`pkg/vm/var.go:72`), so `Register` and the helper need no special case. Task 6 proves it.

**Tests.** The package gets its first `test/`. The tests run the app in server mode inside the `lgx test` process: `WAILS_SERVER_PORT` picks a port, `run!` goes in a `future`, and the test drives `/wails/runtime` and `/` with `http/post` and `http/get`. CI sets `CGO_ENABLED=0 GOFLAGS=-tags=server` for the wails package only. If `Run` cannot be driven off the main goroutine even in server mode, fall back to a `wails/test/e2e.sh` that launches `example/` and curls it, and record why in the README.

### Part 3: `:go/build-tags` in lgx

Wails needs `-tags production` for a release build (no devtools, no dev asset server) and `-tags server` for headless runs. Today the only route is `GOFLAGS` (`docs/issues/lgx-no-go-build-tags.md`).

```clojure
{:go/build-tags ["server"]                            ; every runtime this project builds
 :targets {:bin {:out "bin/tasks"
                 :go/build-tags ["production"]}}}     ; added for the lgx build bundle base only
```

- **Validation:** a vector of distinct strings, each matching `^[A-Za-z0-9_.]+$`. The target-level key is rejected when `:target` is `:lgb`, `:wasm` or `:native`. Those builds do not bundle onto a runtime lgx builds with `go build`, so the tags could not reach them; the message says so.
- **Runtime identity:** `runtime-hash` adds a `tags|a,b` line (sorted, deduped) only when tags are non-empty, so every existing cache entry keeps its key.
- **Reach:** top-level tags apply to **every** `ensure-runtime!` call: `apply-runtime!` (run/test/repl/nrepl/build host), the cross-target bundle bases in `cmd-build`, `build-wasm!` and `build-native!`.
- **Build:** `build-runtime!` passes `-tags a,b` to `go build`.
- **`GOFLAGS` merges, not overrides.** An explicit `go build -tags` replaces a `-tags=` coming from `GOFLAGS`; Go does not combine them. So when config tags are non-empty, lgx reads `-tags=`/`--tags=` entries out of `GOFLAGS` (whitespace-separated `-flag=value` entries, comma-separated tags) and unions them into the explicit `-tags`. `GOFLAGS=-tags=server lgx build` with `["production"]` therefore builds with `production,server`. With no config tags, lgx passes no `-tags` and `GOFLAGS` behaves as today. `GOFLAGS` is already in `runtime-stamp`, so the cache stays honest.
- **`lgx build`, default `:bin` target:** the host runtime still executes `lg -b`. When the bin target adds tags, lgx builds a second runtime with top-level ∪ target tags and passes it as `-bundle-base`, so the shipped binary carries the production tags. This is the same two-runtimes rule `cmd-build` already applies to cross targets (`lgx.lg:1093`). A user-supplied `-bundle-base` still wins.
- **Not covered:** `lginterop`'s scan ignores tags (as the issue notes); it stays that way. A dep's top-level `:go/build-tags` is ignored, like every top-level key of a dep.

### Part 4: the task manager app (`examples/wails-tasks`, this repo)

**Why a task manager first:** it reuses the stack `examples/web-app` already proves (sqlite + ragtime + honeysql + vendored Alpine.js). It also exercises every new shim piece: handlers, menus with accelerators and roles, both file dialogs, backend→frontend events, the data dir, embedded assets and the production build. An RSS reader would add an HTTP poller and an XML parser, and let-go has no XML. It goes to the backlog as the second app.

**Features:**
- **Tasks:** `id`, `title`, `notes`, `done`, `created_at`.
- **UI:**
  - add a task by typing a title and pressing Enter;
  - toggle done;
  - edit the title inline (double-click, Enter to save, Esc to cancel);
  - expand to edit notes;
  - delete;
  - filter tabs All / Active / Done, with counts;
  - "clear completed".
- **Menu:**
  - App role menu;
  - File: Export… (`CmdOrCtrl+E`) writes JSON through a save dialog; Import… (`CmdOrCtrl+I`) reads JSON through an open dialog and appends the tasks, then emits `tasks-changed`; Quit role;
  - Edit role menu;
  - Window role menu.
- **Storage:** `$TASKS_DB` if set, else `(w/data-dir "lgx-tasks")/tasks.db`.

**Namespaces**, each with one job:

| ns | job |
|---|---|
| `tasks.migrations` | ragtime history; `migrate!` |
| `tasks.db` | honeysql queries over a conn: `list-tasks add-task! update-task! toggle-task! delete-task! clear-done!` |
| `tasks.transfer` | `export-json` (tasks → string), `import-json!` (string → inserted count). JSON shape `{"version":1,"tasks":[{title,notes,done}]}`; a bad shape throws `ex-info` with `:reason` |
| `tasks.state` | `(defonce conn* (atom nil))`, `(defonce app* (atom nil))`, `(defonce win* (atom nil))`, so reloading any ns keeps live state |
| `tasks.api` | handler fns reading `@state/conn*`; `register!` binds each name to its **var** (`#'list-tasks`) |
| `tasks.menu` | `spec` (data, `:on-click` vars) and `install!` |
| `tasks.dev` | `start!` when `LGX_RUN` is set: `nrepl/start!` on port 0, and `w/watch-assets!` on `resources/public` |
| `main.lg` | `-main`: open db + migrate, `register!`, new-app, window, `install!`, `dev/start!`, `run!`; ends with `(when-not *compiling-aot* (-main))` |

**Dev loop:**
1. `lgx run` starts the app and prints the nREPL port; `.nrepl-port` lands in the project dir.
2. Connect any editor. Edit `src/tasks/api.lg` and load the buffer: the next frontend call runs the new code, because handlers are registered by var.
3. Edit the menu spec, then eval `(tasks.menu/install!)`.
4. Save anything under `resources/public`: the window reloads.
5. Editing `main.lg` still needs a restart.

**Errors:** a handler that throws rejects the frontend promise; the UI shows the message in a dismissible banner. Import validates its input before inserting anything.

**Tests** (`lgx test`, no window): `db_test` (CRUD round-trip on a temp file), `transfer_test` (export→import round-trip, a bad-shape rejection), `api_test` (handlers over a temp db through `state/conn*`), `menu_test` (`spec` is data and every `:on-click` is a var).

**Smoke, server mode** (`examples/wails-tasks/smoke.sh`):
1. Launch on a free port.
2. curl `/` and `/app.js`.
3. Drive add → list through the bridge.
4. Connect the python nREPL client, redefine `tasks.api/list-tasks` to return a sentinel, and curl again to see it.

### Part 5: docs

- Rewrite the nREPL and main-thread sections of `lgx-live-reload.md` around the package, and fix the facts above.
- Update `lgx-wails-desktop.md`: beta.30, in-tree shim, resource assets, `:go/build-tags`, the new app.
- In `examples/wails-desktop/README.md`, drop the stale `LGX_LETGO_REPLACE` instructions (the example pins 1.13.0), bump to `wails-v0.2.0`, and register by var.
- Close `docs/issues/lgx-no-go-build-tags.md`.
- Draft (do not file) `docs/issues/letgo-nrepl-with-script.md`: `lg -n script.lg` should start the nREPL before running the script. That is the upstream form of the `nrepl` package.
- Document `:go/build-tags` in `ARCHITECTURE.md` and `README.md`.
- Backlog entries, one commit each: the RSS reader app; native Linux GTK verification.

---

## File Structure

**letgo-packages:**

| Path | Action | Responsibility |
|---|---|---|
| `nrepl/lgx.edn` | create | `:paths ["src"]`, `:lg-runtime :built`, `:lg-version "1.13.0"`, shim coord `{:go/local "shim"}` |
| `nrepl/shim/go.mod`, `nrepl/shim/shim.go` | create | `Start`, `Stop`, `Port`; registers `nrepl.shim` |
| `nrepl/src/nrepl/core.lg` | create | `start!`, `stop!`, `port` |
| `nrepl/test/nrepl/core_test.lg`, `nrepl/test/nrepl/client.py` | create | start → eval over TCP → stop |
| `nrepl/README.md` | create | usage, gating advice, loopback note |
| `nrepl/.gitignore` | create | `.nrepl-port` |
| `wails/shim/go.mod` | modify | beta.30 |
| `wails/shim/shim.go` | modify | split into files once it outgrows one (see next row) |
| `wails/shim/{app.go,window.go,menu.go,dialogs.go,assets.go,callback.go,convert.go}` | create | one concern each; `shim.go` keeps the package doc and `init()` registration |
| `wails/src/wails/core.lg` | modify | veneer for the new surface |
| `wails/lgx.edn` | modify | `{:go/local "shim"}`; own `:lg-runtime`/`:lg-version` for tests |
| `wails/test/wails/core_test.lg` | create | server-mode integration tests |
| `wails/test/resources/public/index.html` | create | asset fixture |
| `wails/example/*` | modify | keyword opts, var handlers |
| `wails/README.md`, `README.md`, `.github/workflows/test.yml` | modify | in-tree shim, CI env for wails |

**lgx:**

| Path | Action | Responsibility |
|---|---|---|
| `lgx/config.lg` | modify | schema for top-level and `:targets :bin` `:go/build-tags`; accessors `go-build-tags`, `bin-go-build-tags` |
| `lgx/gobuild.lg` | modify | hash line, `-tags` on `go build`, `ensure-runtime!` takes tags |
| `lgx.lg` | modify | thread tags through `apply-runtime!` and `cmd-build` |
| `test/lgx/config_test.lg`, `test/lgx/gobuild_test.lg` | modify | validation, hash and arg rendering |
| `examples/wails-tasks/**` | create | the app (see Part 4) |
| `examples/wails-desktop/{README.md,lgx.edn,main.lg}` | modify | wails-v0.2.0, var handlers, stale env var |
| `docs/knowledge-base/lgx-live-reload.md`, `lgx-wails-desktop.md` | modify | corrected facts |
| `docs/ARCHITECTURE.md`, `README.md` | modify | `:go/build-tags` |
| `docs/issues/lgx-no-go-build-tags.md` | modify | status: resolved |
| `docs/issues/letgo-nrepl-with-script.md` | create | upstream draft |
| `docs/backlog/rss-reader-app.md`, `docs/backlog/wails-linux-gtk-unverified.md` | create | backlog |

---

## Part 1: `nrepl` package

Work in `/home/agent/Projects/letgo-packages` on a branch `nrepl-package` off a freshly pulled master.

### Task 1: Scaffold the package

**Files:** create `nrepl/lgx.edn`, `nrepl/shim/go.mod`, `nrepl/.gitignore`, `nrepl/README.md` (stub)

- [x] **Step 1:** Copy the shape of `livekit/lgx.edn`: `:paths ["src"]`, `:lg-runtime :built`, `:lg-version "1.13.0"`, `:deps {github.com/abogoyavlensky/letgo-packages/nrepl/shim {:go/local "shim"}}`. No `:go/replace` is needed.
- [x] **Step 2:** `nrepl/shim/go.mod`: module `github.com/abogoyavlensky/letgo-packages/nrepl/shim`, `go 1.26`, `require github.com/nooga/let-go v0.0.0`. lgx's replace supplies let-go; mirror `livekit/shim/go.mod`.
- [x] **Step 3:** `.gitignore` with `.nrepl-port`.
- [x] **Step 4:** Commit: `nrepl: scaffold the package`

### Task 2: The Go shim

**Files:** create `nrepl/shim/shim.go`

- [x] **Step 1:** Implement `Start(port int, nsName string) (int, error)`, `Stop() error` and `Port() int` as specified in the Design. Use one mutex-guarded `*nrepl.NreplServer`, and resolve or create the namespace (read `pkg/rt` and `in-ns` in let-go for the creation call). Register them in `init()` with `vm.NewNamespace("nrepl.shim")` + `ns.Def(..., vm.MustBox(...))` + `rt.RegisterNS(ns)`, exactly as `wails/shim/shim.go` does. Its comment explains why not `rt.RegisterInstaller`; copy that comment.
- [x] **Step 2:** In the package doc comment, explain why this package exists: `lg -n` starts its nREPL only after the script returns.
- [x] **Step 3:** Commit: `nrepl: in-process server shim`

> Deviation: no `:ns` option. let-go's `*ns*` is process-global and `compiler.NewCompiler` sets it, so sessions always evaluate in the process's current namespace. `Start(port)` saves and restores the namespace root so starting a server has no side effect; `start!` takes only `:port`. `Stop` returns nothing (upstream `NreplServer.Stop` has no error).

### Task 3: Veneer and test

**Files:** create `nrepl/src/nrepl/core.lg`, `nrepl/test/nrepl/core_test.lg`, `nrepl/test/nrepl/client.py`

- [x] **Step 1: Write the client.** `client.py` takes `port code` as args. It speaks bencode over TCP: `clone`, then `eval` in that session. It prints the `value` (or `err`) of the first response carrying one, and exits non-zero on an `err`/`ex` or after 5s. Use the standard library only, with a minimal hand-written bencode.
- [x] **Step 2: Write the failing test.** `core_test.lg`:
  - `start!` with port 0 returns a positive int that equals `(port)`;
  - a second `start!` throws;
  - `client.py <port> "(+ 1 2)"` prints `3` (run it through `os/sh` and use the exit code + output);
  - start with `{:ns "nrepl.core-test"}` for the rest: `(ns-name *ns*)` evaluates to `nrepl.core-test`, and after evaluating `(def probe 42)` over the client, `nrepl.core-test/probe` resolves to 42 in the test process (proves it shares the process). Check the default `"user"` ns in the first start only through `(ns-name *ns*)`;
  - `stop!` makes `(port)` nil;
  - always `stop!` in `finally` and delete `.nrepl-port`.
- [x] **Step 3:** Run: `cd nrepl && lgx test`. Expected: FAIL (`nrepl.core` not found).
- [x] **Step 4: Implement `core.lg`.** `start!` takes an optional opts map and defaults to `{:port 0 :ns "user"}`. It calls `shim/Start`, throws `ex-info` on the error value, and returns the port. `stop!` and `port` return nil when the server is not running. Each fn gets a docstring; the `start!` docstring tells apps to gate on `LGX_RUN` or similar.
- [x] **Step 5:** Run: `cd nrepl && lgx test`. Expected: PASS. The first run builds the runtime and takes minutes.
- [x] **Step 6:** Commit: `nrepl: start!/stop!/port with a TCP round-trip test`

> Deviation: the namespace-sharing test uses `(intern 'nrepl.core-test 'probe 42)` over the client rather than starting in that namespace (see Task 2). Tasks 1–3 were reviewed by codex together, after Task 3 proved the shim: clean.

### Task 4: README and release prep

**Files:** create `nrepl/README.md`; modify root `README.md` (package list) and `.github/workflows/test.yml` only if the changed-packages script needs it (check `.github/scripts/changed-packages.sh`)

- [x] **Step 1:** README: what it is, `{:git/tag "nrepl-v0.1.0" :deps/root "nrepl"}`, a gated-start example, loopback-only, one server per process, and the upstream draft it substitutes for.
- [x] **Step 2:** Commit: `nrepl: README`
- [x] **Step 3: ASK THE USER** before pushing the branch, opening a PR, and (after merge) tagging `nrepl-v0.1.0`. Link the PR with `link_pull_request`.

> Deviation: the release asks for Tasks 4, 12, 16 and 24 are batched into one confirmation at the end, so local work is not blocked waiting on pushes. `wails-0.2` is stacked on `nrepl-package` (both touch the root README).

---

## Part 2: `wails` v0.2.0

Same repo, branch `wails-0.2` off master. If Part 1 has merged, start from it.

### Task 5: Bump Wails and move the shim in-tree

**Files:** modify `wails/shim/go.mod`, `wails/lgx.edn`, `wails/example/lgx.edn`, `README.md` ("In-tree shims"), `.github/workflows/test.yml` (comment lists)

- [x] **Step 1:** In `wails/shim`, set `github.com/wailsapp/wails/v3 v3.0.0-beta.30` and refresh `go.sum`. The module only resolves with let-go replaced; follow the root README's shim-dev instructions.
- [x] **Step 2:** Change the `wails/lgx.edn` coord to `{:go/local "shim"}`, and add `:lg-runtime :built :lg-version "1.13.0"` for the package's own tests (mirror livekit's comment).
- [x] **Step 3:** Run the example in server mode to prove the bump: `cd wails/example && CGO_ENABLED=0 GOFLAGS=-tags=server WAILS_SERVER_PORT=8765 lgx run &`. Then repeat the curl from `lgx/docs/knowledge-base/lgx-wails-desktop.md` ("Reproducing the verification") against port 8765. Expected: `Hello, world! (from let-go)`. Kill the process.
- [x] **Step 4:** Commit: `wails: Wails v3.0.0-beta.30, shim in-tree`

### Task 6: Test harness and the bridge

**Files:** create `wails/test/wails/core_test.lg`, `wails/test/resources/public/index.html`; modify `.github/workflows/test.yml`

- [x] **Step 1: Write the harness.** A once-per-namespace fixture:
  1. Set `WAILS_SERVER_PORT` to a free port (`os/free-port` if let-go has it; otherwise a fixed high port).
  2. Build `new-app` with `:assets "public"`, add a window, and `run!` in a `future`.
  3. Poll `/` until it answers (≤10s).

  A `call` helper POSTs the bridge payload (the shape is in the wails KB) with a unique `call-id` and decodes the JSON. Use `test/resources` as a resource root; check how `lgx test` picks resource paths (`docs/ARCHITECTURE.md` "test") and set `:resource-paths` in `wails/lgx.edn` if needed.
- [x] **Step 2: Write the tests.**
  - a fn handler returns a map → the JSON is an object with a nested array;
  - a **var** handler: register `#'h`, call it, `alter-var-root`/redefine `h`, call again → the new result;
  - a throwing handler → an error response;
  - an unknown name → an error naming it.
- [x] **Step 3:** Add the env to CI. In `.github/workflows/test.yml`, run the wails package with `CGO_ENABLED=0 GOFLAGS=-tags=server` (prefix that one `lgx test`), and update the "tagged Go shim" comments so wails is no longer listed.
- [x] **Step 4:** Run: `cd wails && CGO_ENABLED=0 GOFLAGS=-tags=server lgx test`. Expected: PASS for the existing surface. If `run!` cannot run in a `future`, switch to the e2e-script fallback from the Design, record it in `wails/README.md`, and continue.
- [x] **Step 5:** Commit: `wails: server-mode test harness`

> Deviation: the `:test` context in `wails/lgx.edn` must restate `:extra-paths ["test"]`, since defining it replaces lgx's default. Wails answers a string result as plain text, not JSON, so string assertions read `:body`.

### Task 7: Resource-served assets

**Files:** create `wails/shim/assets.go`, `wails/shim/convert.go` (move `ToGo`/`keyString`/`asMap`/`asInt` there unchanged); modify `wails/shim/app.go` (or `shim.go`)

- [x] **Step 1: Write the failing tests.** `GET /` returns the fixture HTML with `text/html`; `GET /nope.js` returns 404; `GET /../lgx.edn` does not escape (404).
- [x] **Step 2:** Run the tests. Expected: FAIL.
- [x] **Step 3: Implement.** Write an `http.Handler` over `rt.GetResourceProvider()` with the prefix, `index.html` for `/`, `mime.TypeByExtension`, and `NormalizeResourceName`. Wire it to the `"assets"` key in `New`. When both `assets` and `assets-dir` are set, `New` returns an error rather than picking one. `New`'s signature becomes `(*application.App, error)`, and the veneer throws on the error.
- [x] **Step 4:** Run the tests. Expected: PASS.
- [x] **Step 5:** Commit: `wails: serve the frontend from resources`

> Deviation: added a `test/resources/secret.txt` fixture to prove prefix containment (`/../index.html` legitimately resolves inside the prefix). Codex fixup: commit the 200 before copying the body, since Wails' native writers answer 501 for an empty file that never wrote a header.

### Task 8: Callbacks, events, app options

**Files:** create `wails/shim/callback.go`, `wails/shim/app.go`; modify `wails/src/wails/core.lg`

- [x] **Step 1: Write the failing test.** `on-event!` with a var that `deliver`s a promise. Have the frontend side emit through the runtime HTTP transport; find the event-emit message shape in `messageprocessor*.go` for beta.30 and use it. Then assert that the promise receives the data as a let-go value.
- [x] **Step 2:** Run the test. Expected: FAIL.
- [x] **Step 3: Implement.** Write the callback helper (see Design). Add `OnEvent(app, name, fn)` on `app.Event.On`, converting `event.Data` with `vm.ToLetGo`. In `New`, add `on-shutdown` and `quit-on-last-window-closed`.
- [x] **Step 4:** Run the test. Expected: PASS.
- [x] **Step 5:** Commit: `wails: events from the frontend, shutdown hook`

> Deviation: new `FromJSON` conversion for call args and event data. JSON numbers decode as float64, so whole numbers become Ints (an id of 3 arrived as 3.0), and `null` becomes nil (`vm.ToLetGo` cannot box it). This changes handler args too. Codex fixup: the int64 upper bound is exclusive (2^63 stays a Float).

### Task 9: Window controls

**Files:** create `wails/shim/window.go`; modify `wails/src/wails/core.lg`

- [x] **Step 1: Implement.** `NewWindow` gains `min-width`, `min-height` and `hidden`. Add `SetTitle`, `Show`, `Hide`, `Close`, `Focus`, `Reload`, `ExecJS` and `InvokeSync` (`on-main!`, wrapping the fn with the callback helper). Each is a one-line pass-through to the Wails method, which already hops to the main thread.
- [x] **Step 2:** Test what server mode allows: each fn can be called on the test window without throwing, and `on-main!` runs its fn. Real window effects go in Task 22.
- [x] **Step 3:** Run: `CGO_ENABLED=0 GOFLAGS=-tags=server lgx test`. Expected: PASS.
- [x] **Step 4:** Commit: `wails: window controls and on-main!`

### Task 10: Menus

**Files:** create `wails/shim/menu.go`; modify `wails/src/wails/core.lg`

- [x] **Step 1: Write the failing tests.** A pure builder `BuildMenu(spec vm.Value) (*application.Menu, error)` is exported to let-go as `build-menu` (a private-ish `-build-menu` in the veneer is fine) so it can be tested without a window:
  - a valid spec (the Design example) builds with no error;
  - `{:role :nope}` returns an error naming `[0 :role]`;
  - an item with neither `:label` nor `:role` nor `:separator` errors with its path;
  - `:on-click` that is not a fn errors.
- [x] **Step 2:** Run the tests. Expected: FAIL.
- [x] **Step 3: Implement.**
  - Walk the `vm.Value` (a vector of maps), and read keys as keywords or strings.
  - Map the roles from the Design to `application.<Role>`.
  - Map `:accelerator` to `SetAccelerator`, and `:on-click` through the callback helper.
  - Nested `:items` become submenus.
  - Add `SetMenu(app, spec)`, which builds and then calls `app.Menu.Set`.
- [x] **Step 4:** Run the tests. Expected: PASS. In server mode `set-menu!` is a no-op, so the tests call it only to prove it does not throw.
- [x] **Step 5:** Commit: `wails: data-driven application menu`

> Deviation: `build-menu` became `check-menu` (builds, destroys, returns true or throws), and Task 19's menu test uses it. Codex fixups: menus need the app (`new-app` first), a failed build and a replaced menu are destroyed so REPL rebuilds do not leak Wails' global item map, and a malformed accelerator is an error naming its path. Fns that can fail return `(bool, error)`: let-go throws on the error of a pair but returns a lone `error` as a value.

### Task 11: Dialogs, data dir, asset watcher

**Files:** create `wails/shim/dialogs.go`; modify `wails/shim/app.go`, `wails/src/wails/core.lg`

- [x] **Step 1: Implement.**
  - `OpenFile(app, opts)` and `SaveFile(app, opts)` return the path, or nil on cancel. In server mode both return the error Wails gives, and the veneer throws it.
  - `Message(app, kind, title, body)`.
  - `DataDir(name)` returns `os.UserConfigDir()/name`, created with 0700.
  - `WatchAssets(win, dir)`: a goroutine polls the newest mtime under `dir` (`filepath.WalkDir`) every 300ms and calls `win.Reload()` on change. It returns a stop fn as a `vm.Fn`; build it with `vm.NewNativeFn` or the boxing helper the codebase uses.
- [x] **Step 2:** Tests:
  - `data-dir` returns an existing dir under the user config dir (point `XDG_CONFIG_HOME` at a temp dir);
  - `open-file` in server mode throws with Wails' "not available in server mode" message, which proves the error path;
  - `watch-assets!` returns a callable stop fn.
- [x] **Step 3:** Run: `CGO_ENABLED=0 GOFLAGS=-tags=server lgx test`. Expected: PASS.
- [x] **Step 4:** Commit: `wails: file dialogs, data-dir, dev asset watcher`

### Task 12: Example, README, release

**Files:** modify `wails/example/main.lg`, `wails/example/frontend/index.html` (only if paths change), `wails/README.md`, root `README.md`

- [x] **Step 1:** Update the example to keyword opts and `#'greet`/`#'stats`.
- [x] **Step 2:** Update `wails/README.md`: the full API from the Design, the menu spec, the reload-by-var convention, resource assets, and the server-mode test command. Update the root README's "In-tree shims" so wails follows the livekit model.
- [x] **Step 3:** Rerun `CGO_ENABLED=0 GOFLAGS=-tags=server lgx test` and the Task 5 curl. Expected: PASS and the greeting.
- [x] **Step 4:** Commit: `wails: example and README for v0.2.0`
- [x] **Step 5: ASK THE USER** before pushing, opening the PR, and (after merge) tagging `wails-v0.2.0`. Link the PR.

> Deviation: Task 11 codex fixups: the asset watcher compares an fnv fingerprint of the tree, not the newest mtime (a file with a future timestamp masked every other edit), and the data-dir test isolates the config dir (on macOS it read the real one). Driving the UI in Task 20 found two more shim bugs, fixed on this branch: `ToGo` turned `[]` into `[null]` and an empty list into `{}` (an empty seq yields one nil; `isMap` now checks Associative), and a rejected call showed the raw error chain, so `handlerError` walks `GetCause` to the handler's own `ex-message`.

---

## Part 3: `:go/build-tags` in lgx

This repo, branch `go-build-tags` off master. Read `lgx/gobuild.lg` (`runtime-hash`, `build-runtime!`, `ensure-runtime!`) and `lgx.lg` (`apply-runtime!`, `cmd-build`) first.

### Task 13: Config schema and accessors

**Files:** modify `lgx/config.lg`, `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests.**
  - `{:go/build-tags ["server"]}` is valid;
  - `["a" "a"]` is rejected for duplicates;
  - `["-x"]` and `[""]` are rejected by the pattern;
  - `"server"` (not a vector) is rejected;
  - `:targets {:bin {:out "b" :go/build-tags ["production"]}}` is valid;
  - the same with `:target :lgb`, `:wasm` or `:native` is rejected with the Design's reason;
  - the accessors `go-build-tags` and `bin-go-build-tags` return `[]` when the key is absent.
- [x] **Step 2:** Run: `make test` (or the repo's documented test command; check `Makefile`/`lgx.edn` `:tasks`). Expected: the new tests FAIL.
- [x] **Step 3: Implement.** Add the schema entries (top-level map and the closed `:bin` map at `lgx/config.lg:852`), a cross-key rule beside `bin-target-errors`, and the two accessors.
- [x] **Step 4:** Run the tests. Expected: PASS.
- [x] **Step 5:** Commit: `config: :go/build-tags, top-level and on :targets :bin`

### Task 14: Hash and go build args

**Files:** modify `lgx/gobuild.lg`, `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write the failing tests.**
  - `runtime-hash` with empty tags equals today's value for the same inputs (pin it against the existing arity);
  - non-empty tags change it;
  - `["b" "a"]` and `["a" "b"]` hash the same;
  - the go build arg vector contains `-tags` `a,b` only when tags are non-empty;
  - a pure `effective-tags` fn: config `["production"]` with `GOFLAGS="-mod=mod -tags=server,x"` gives `["production" "server" "x"]` (sorted, deduped); empty config tags give `[]` whatever `GOFLAGS` says.
- [x] **Step 2:** Run the tests. Expected: FAIL.
- [x] **Step 3: Implement.** Thread an optional tags vector through `runtime-hash`, `build-runtime!` and `ensure-runtime!`. The new arity defaults to `[]`, so existing callers are unchanged. `build-runtime!` renders `-tags` from `effective-tags` (taking the `GOFLAGS` value as an argument, so it stays testable). Put `-tags` before `-o` in the `go build` args. Hash the config tags, not the merged set, since `GOFLAGS` is already stamped. Update the `runtime-stamp` comment near `lgx/gobuild.lg:214`, which says GOFLAGS is the only route.
- [x] **Step 4:** Run the tests. Expected: PASS.
- [x] **Step 5:** Commit: `gobuild: build tags in the runtime hash and go build`

### Task 15: Wire through run/test/repl/nrepl and build

**Files:** modify `lgx.lg`; test via an e2e check

- [x] **Step 1: Implement.**
  - Grep `lgx.lg` for every `gobuild/ensure-runtime!` call (today: `apply-runtime!`, the cross base in `cmd-build`, `build-wasm!`, `build-native!`). Each one passes `(config/go-build-tags cfg)`.
  - In `cmd-build`'s default `:bin` path, when `bin-go-build-tags` is non-empty and the user gave no `-bundle-base`, compute `base` as `ensure-runtime!` with top-level ∪ bin tags (with `target` for cross builds, nil for native). Native builds then also inject a `base`. Today they pass `runtime`; keep that when the bin tags are empty.
- [x] **Step 2: Add checks to the existing e2e or integration tests** (find how `lgx build` is covered: `test/` or `tests/`). Use fixture projects with no Go deps and `:lg-runtime :built`:
  - (a) `:targets {:bin {:out "bin/x" :go/build-tags ["lgxprobe"]}}`: `lgx build -v` shows a second runtime build with `-tags lgxprobe`;
  - (b) top-level `:go/build-tags ["lgxprobe"]` only, with `lgx build -v --target linux/arm64`: the cross base is built with `-tags lgxprobe`;
  - (c) (a) with `GOFLAGS=-tags=lgxextra`: `-tags lgxextra,lgxprobe`.

  Mark the checks slow if the suite has such a marker.
- [x] **Step 3:** Run the full test suite. Expected: PASS.
- [x] **Step 4:** Commit: `build: :targets :bin :go/build-tags builds a tagged bundle base`

### Task 16: Docs for the key

**Files:** modify `docs/ARCHITECTURE.md` (config shape ~line 100, the build section), `README.md` (config reference), `docs/issues/lgx-no-go-build-tags.md`

- [x] **Step 1:** Document both keys, the union rule, the rejected targets, and that `GOFLAGS` still works. Set the issue to `**Status:** resolved in <branch/PR>` and keep its lginterop note.
- [x] **Step 2:** Commit: `docs: :go/build-tags`
- [x] **Step 3: ASK THE USER** before pushing and opening the PR. Link it.

> Deviation: Task 14 parses `GOFLAGS` with go's quoting rules (`-tags='a b'`, `"-tags=a,b"`) and re-quotes a merged field with the quote it lacks. Tags need `:lg-runtime :built`; without it they are a config error. The e2e checks are Scenario 179, gated on `LGX_BUILD_TAGS_E2E=1` since they build runtimes. Codex found the `:native` and `:wasm` targets built without the tags; they now get them through a `GOFLAGS` override around the subprocess (checked with a tag-gated probe shim: off before the fix, on after).

---

## Part 4: `examples/wails-tasks`

This repo, branch `wails-tasks-example` (stacked on `go-build-tags` if that has not merged). Use `bin/lgx` built from this branch, since the example uses `:go/build-tags`. **The committed `lgx.edn` always names the release tags** (`wails-v0.2.0`, `nrepl-v0.1.0`) from Task 17 on. Until those tags exist, edit the two coords locally to `{:local/root "/home/agent/Projects/letgo-packages/<pkg>"}` and **keep that edit unstaged**: stage files by name, never `git add -A`, and run `git diff --cached -- examples/wails-tasks/lgx.edn` before each commit to confirm no `:local/root` is staged. Task 21 drops the local edit and verifies against the tags.

### Task 17: Scaffold, schema, db

**Files:** create `examples/wails-tasks/{lgx.edn,.gitignore,.mise.toml}`, `src/tasks/migrations.lg`, `src/tasks/db.lg`, `test/tasks/db_test.lg`

- [x] **Step 1: Write `lgx.edn`.** Mirror `examples/web-app/lgx.edn`: `:paths ["src"]`, `:resource-paths ["resources"]`, `:main "main.lg"`, `:lg-runtime :built`, `:lg-version "1.13.0"`, `:targets {:bin {:out "bin/tasks" :go/build-tags ["production"]}}`. Deps: letgo-sqlite `sqlite-v0.2.0`, honeysql `v2.7.1479`, letgo-ragtime `ragtime-v0.2.0`, wails, nrepl. Comment each dep's purpose, as web-app does. Copy `.gitignore` (`bin/`, `*.db`, plus `.nrepl-port`) and `.mise.toml` from web-app.
- [x] **Step 2:** Migration `001-create-tasks`: `id integer pk`, `title text not null`, `notes text not null default ''`, `done integer not null default 0`, `created_at text not null default (datetime('now'))`. Copy web-app's `migrations.lg` structure.
- [x] **Step 3: Write the failing test.** `db_test.lg`, on a temp file:
  - add → list shows the task with `:done false`;
  - `update-task!` changes title/notes;
  - toggle flips done;
  - `clear-done!` deletes only done tasks and returns the count;
  - delete returns true, then false for a missing id.
  - Return booleans for `done`; convert sqlite's 0/1 in `db`.
- [x] **Step 4:** Run: `cd examples/wails-tasks && ../../bin/lgx test`. Expected: FAIL.
- [x] **Step 5:** Implement `tasks.db` with honeysql, following `examples/web-app/src/app/db.lg`.
- [x] **Step 6:** Run the tests. Expected: PASS.
- [x] **Step 7:** Commit: `examples(wails-tasks): schema and queries`

### Task 18: State, transfer, api

**Files:** create `src/tasks/state.lg`, `src/tasks/transfer.lg`, `src/tasks/api.lg`, `test/tasks/transfer_test.lg`, `test/tasks/api_test.lg`

- [x] **Step 1: Write the failing tests.**
  - transfer: export then import into a fresh db reproduces titles/notes/done; `{"version":2}` and a missing `tasks` throw `ex-info` with `:reason :bad-version` / `:bad-shape`, inserting nothing.
  - api: with `state/conn*` reset to a temp conn, the handler fns give the same results as db; `register!` called twice does not throw.
- [x] **Step 2:** Run the tests. Expected: FAIL.
- [x] **Step 3: Implement.**
  - `state` uses three `defonce` atoms.
  - `transfer` uses let-go's `json` ns (see `docs/knowledge-base/let-go-stdlib-quick-ref.md`).
  - `api` has one fn per frontend call: `list-tasks`, `add-task`, `update-task`, `toggle-task`, `delete-task` and `clear-done`, each taking plain args from JS. `register!` loops over a `{"list-tasks" #'list-tasks ...}` map calling `w/handler!`.
  - Comment the var choice: it is what makes the handlers hot.
- [x] **Step 4:** Run the tests. Expected: PASS.
- [x] **Step 5:** Commit: `examples(wails-tasks): handlers, import/export`

### Task 19: Menu, dev, main

**Files:** create `src/tasks/menu.lg`, `src/tasks/dev.lg`, `main.lg`, `test/tasks/menu_test.lg`

- [x] **Step 1: Write the failing test.** `menu_test`: `(menu/spec)` is a vector; every `:on-click` reachable in it is a var; `w/check-menu` accepts it (after the app exists).
- [x] **Step 2:** Run the test. Expected: FAIL.
- [x] **Step 3: Implement.**
  - **`menu`:**
    - `export!` opens `w/save-file` (default name `tasks.json`) and `spit`s `export-json`; on cancel it does nothing.
    - `import!` opens `w/open-file` with a JSON filter, calls `import-json!`, emits `tasks-changed`, and shows `w/message!` with the count. On `ex-info` it shows an `:error` message.
    - `install!` calls `w/set-menu!` with `@state/app*`.
  - **`dev`:**
    - `start!` returns nil unless `(os/getenv "LGX_RUN")`;
    - otherwise it calls `nrepl/start!` with port 0, prints `nREPL on <port> (.nrepl-port)`, and calls `w/watch-assets!` on `resources/public` with `@state/win*`.
  - **`main.lg`:**
    1. Open the conn (`TASKS_DB` or `data-dir`) and migrate; `reset!` it into state.
    2. `register!` the handlers.
    3. `new-app` with `:assets "public"` and `:quit-on-last-window-closed true`, then `new-window` 900×650 with min 480×400.
    4. `install!` the menu, then `dev/start!`, then `run!`.
    5. Guard the whole thing with `(when-not *compiling-aot* (-main))`.
- [x] **Step 4:** Run the tests. Expected: PASS.
- [x] **Step 5:** Commit: `examples(wails-tasks): menu, dev loop, entry point`

> Deviation: `dev?` tests for a non-blank `LGX_RUN`, and `main.lg` treats a blank `TASKS_DB` as unset. `os/getenv` returns `""` for an unset variable and `""` is truthy, so the plan's `(os/getenv "LGX_RUN")` would have started an nREPL in the shipped binary (codex P1). `:on-shutdown` stops the dev loop and closes the connection.

### Task 20: Frontend

**Files:** create `resources/public/index.html`, `resources/public/app.js`, `resources/public/style.css`, `resources/public/alpine.min.js` (copy from `examples/web-app/resources/public/alpine.min.js`)

- [x] **Step 1: Implement.**
  - `app.js` imports `Call` and `Events` from `/wails/runtime.js` and defines `call(name, ...args)` over the bridge constant (copy the comment from wails-desktop).
  - It exposes an Alpine component holding the list, the filter and the error banner, with the Part 4 UI behaviours, and does `Events.On("tasks-changed", reload)`.
  - Alpine is loaded as a classic script after the module defines the component; follow web-app's index.html ordering.
  - CSS stays plain and system-font, with readable spacing; no framework.
  - **Use /frontend-design** for the look, keeping it to one CSS file.
- [x] **Step 2: Server-mode run.** `CGO_ENABLED=0 GOFLAGS=-tags=server WAILS_SERVER_PORT=8766 TASKS_DB=/tmp/wt.db ../../bin/lgx run`, then open `http://localhost:8766` with the preview tools (`preview_open`/`preview_snapshot`). Check that adding, toggling, editing, filtering and deleting all work, and take a screenshot for the summary.
- [x] **Step 3:** Commit: `examples(wails-tasks): frontend`

> Deviation: the preview tools could not start (AppArmor, no sudo), so the UI was driven with playwright-core and headless Chromium (`.tmp/drive-tasks.cjs`, not committed): add, toggle, edit and Esc-cancel, notes, filters, the error banner, persistence across a reload, delete and clear, no console errors, in light, dark and narrow layouts. It found the two shim bugs noted under Task 12, plus a strike line spanning the whole row, text vanishing mid-transition in dark mode (only `background-size` transitions now), and `x-collapse`, which needs an Alpine plugin (dropped).

### Task 21: Smoke script, README, swap to tags

**Files:** create `examples/wails-tasks/smoke.sh`, `examples/wails-tasks/README.md`; modify `examples/wails-tasks/lgx.edn`

- [x] **Step 1: Write `smoke.sh`.**
  1. Start the app as in Task 20 on a free port, in the background with a trap-kill.
  2. Wait for `/`.
  3. Assert that `/` and `/app.js` return 200.
  4. Bridge `add-task "smoke"`, then `list-tasks`, and assert it contains `smoke`.
  5. Read `.nrepl-port` and run `letgo-packages/nrepl/test/nrepl/client.py` (path via an env var, defaulting to the sibling checkout) with `(in-ns 'tasks.api) (defn list-tasks [] [{:title "redefined"}])`.
  6. Bridge `list-tasks` again and assert `redefined`.
  7. Exit 0.
- [x] **Step 2:** Run: `bash smoke.sh`. Expected: `smoke: ok`.
- [x] **Step 3: Write the README.** Cover what the app is, prerequisites (copy the table from wails-desktop), `lgx run` and the dev loop (nREPL, load buffer, `tasks.menu/install!`, asset save → reload), `lgx build` (production tags, embedded assets), packaging pointers (`wails3` commands via `:tasks`, not wired), server mode, and `smoke.sh`.
- [x] **Step 4:** Commit: `examples(wails-tasks): smoke script and README`
- [x] **Step 5:** Once `wails-v0.2.0` and `nrepl-v0.1.0` are tagged (Tasks 4 and 12), discard the local `lgx.edn` edit (`git checkout -- examples/wails-tasks/lgx.edn`) and re-run `lgx test` and `smoke.sh` against the tags. Expected: PASS and `smoke: ok`. If the tags are not out yet, stop here and tell the user; the committed tree is already correct.

> Deviation: `smoke.sh` runs the app under `set -m` rather than `setsid`, which macOS lacks, so cleanup kills the process group. Step 5 passed against the published tags.

### Task 22: Native checklist (user, macOS)

**Files:** none. Put this list in the PR description and in `examples/wails-tasks/README.md` under "Verified on".

- [ ] `lgx run` opens a native window with the UI.
- [ ] Cmd+C/V/Z work in inputs (Edit role).
- [ ] File ▸ Export… saves a JSON file; Import… of that file appends the tasks, and the list refreshes through `tasks-changed`.
- [ ] Connect an editor to `.nrepl-port`, change `add-task` to upper-case titles, and load the buffer: the next add is upper-cased with no restart.
- [ ] Edit `style.css`: the window reloads within ~1s.
- [ ] `lgx build && open bin/tasks` from Finder shows the UI (embedded assets, cwd `/`), devtools are unavailable (production tag), and data persists in `~/Library/Application Support/lgx-tasks/tasks.db`.
- [ ] Record the date and the Wails/let-go versions in the README.

---

## Part 5: knowledge base and backlog

This repo, on the `wails-tasks-example` branch.

### Task 23: KB corrections

**Files:** modify `docs/knowledge-base/lgx-live-reload.md`, `docs/knowledge-base/lgx-wails-desktop.md`, `examples/wails-desktop/{README.md,lgx.edn,main.lg}`, `AGENTS.md` (only if a pointer line changes)

- [x] **Step 1: Rewrite `lgx-live-reload.md`.**
  - Keep the file watcher as the no-dependency option.
  - Replace "Why `lgx nrepl` does not do this today" / "What it would take" with the `nrepl` package: how it builds its own context, why `lg -n` cannot, the `LGX_RUN` gate, and editor `load-file`.
  - Add "Register by var" and "`defonce` your state".
  - Note that `:reload` is unsupported in 1.13.0.
  - Rewrite the main-thread section: Wails methods self-dispatch; `on-main!` covers anything else.
  - Replace the frontend poller as the default with `watch-assets!` → `Reload`, and keep the poller as the zero-shim fallback.
  - Update the `Verify against` footer.
- [x] **Step 2: Update `lgx-wails-desktop.md`.**
  - beta.30; the in-tree shim (remove the `:go/version` pin story);
  - resource-served assets and the Finder-cwd trap they fix;
  - `:go/build-tags` (replace "Build tags have no config key");
  - the menu spec;
  - point to `examples/wails-tasks` as the full app;
  - still mark Linux GTK unverified;
  - update the footer paths (`wails/shim/*.go`).
- [x] **Step 3: Update `examples/wails-desktop`.** Bump to `wails-v0.2.0`, use keyword opts and `#'greet`, and in the README delete the `LGX_LETGO_REPLACE` export and paragraph, since 1.13.0 is pinned.
- [x] **Step 4:** Commit: `docs: refresh the Wails and live-reload notes`

> Deviation: `lgx-go-wrappers.md` also gained "Writing a shim: let-go facts to know" (the lone-error return rule, `GetCause`, empty seqs, vars as fns, float64 JSON numbers). Codex's only finding was that `wails-v0.2.0` is not published yet, which the release order covers.

### Task 24: Upstream draft and backlog

**Files:** create `docs/issues/letgo-nrepl-with-script.md`; create `docs/backlog/rss-reader-app.md`, `docs/backlog/wails-linux-gtk-unverified.md`

- [x] **Step 1: Write the issue draft.** Follow `docs/issues/README.md`'s format: the problem (`cli.go:689` order), the proposed change (start the nREPL before running files when `-n` is given with files), and that the `nrepl` package retires once it lands. Status: draft, not filed. Commit: `Issues: draft lg -n with a script`
- [x] **Step 2:** **Use /backlog** to add `rss-reader-app.md` (the second app; needs an XML parser, either `encoding/xml` via `:go/interop` or a shim, and a background poller with notifications). Commit: `Backlog: RSS reader as the second Wails app`
- [x] **Step 3:** **Use /backlog** to add `wails-linux-gtk-unverified.md` (the GTK4/WebKitGTK path has never run; the dev packages are needed). Commit: `Backlog: verify Wails on Linux GTK`
- [x] **Step 4: ASK THE USER** before pushing and opening the PR (stacked on `go-build-tags` if that is unmerged). Link every PR in the stack.

> Deviation: the RSS entry points at a shim (possibly over gofeed) rather than `encoding/xml` through `:go/interop`, which cannot carry tagged-struct decoding or `xml.Token` interfaces. Commit titles: `Backlog: an RSS reader as the second Wails app`, `Backlog: verify the Wails native window on Linux`.

## Completion summary

Shipped across two repos, as two stacks of branches:

- **letgo-packages `nrepl-package`:** the `nrepl` package, an nREPL served from inside a running program (`start!`, `stop!`, `port`), with a TCP round-trip test through a stdlib bencode client.
- **letgo-packages `wails-0.2`** (on `nrepl-package`): Wails v3.0.0-beta.30 with the shim in-tree, a server-mode test harness in CI, resource-served assets, events and a shutdown hook, window controls and `on-main!`, a data-driven menu, file dialogs, `data-dir` and the asset watcher, and var handlers that make redefinitions hot.
- **lgx `go-build-tags`:** `:go/build-tags`, top-level and on `:targets :bin`. Tags join the runtime hash, merge with `GOFLAGS`, build a tagged bundle base for `lgx build`, and reach the `:native` and `:wasm` builds.
- **lgx `wails-tasks-example`** (on `go-build-tags`): `examples/wails-tasks` (sqlite, HoneySQL, ragtime, Alpine; export and import; the dev loop), `examples/wails-desktop` on v0.2.0, the rewritten live-reload KB, the upstream draft for `lg -n` with a script, and two backlog entries.

Final runs: lgx `make test` with `LGX_BUILD_TAGS_E2E=1`, 909 unit tests and 569 e2e assertions, all passing. The package suites in server mode: wails 33 tests (68 assertions), nrepl 4, wails-tasks 16 (39 assertions), all passing; `smoke.sh` prints `smoke: ok`. The UI was driven end to end in headless Chromium. `make fmt-check` and `make lint` fail only on master's pre-existing findings; this work adds none.

Not done here:
- Task 22, the native window on macOS, is the user's checklist. Nothing native was verified: this machine has no GTK and no sudo. Linux GTK is in the backlog.

Released: letgo-packages #7 and #8, tagged `nrepl-v0.1.0` and `wails-v0.2.0`; lgx #67 and #68. Against the tags (Task 21 step 5), the example's `lgx test` (16 tests) and `smoke.sh` passed, and `examples/wails-desktop` served and answered `greet` in server mode. No lgx release yet carries `:go/build-tags` (0.5.0 does not), so the example needs an lgx built from master until one does.

What the plan could have specified better:
- **`os/getenv` returns `""` for an unset variable.** `let-go-gotchas.md` already says so. Pointing at it from the dev-loop step would have avoided a plan that, followed literally, shipped an nREPL in the production binary.
- **How to drive the UI without a desktop.** Wails' server mode plus a scripted headless browser was the only way to exercise the frontend, and it found five bugs that the Go-side tests could not see. The plan named preview tools that turned out to be unavailable.
- **Empty collections and errors across the bridge.** Only a real frontend hit `[]`, `()` and a rejected call. Bridge tests for them belong in Task 6's harness from the start.
