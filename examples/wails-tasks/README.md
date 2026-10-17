# wails-tasks

A desktop task manager written in let-go: the window is
[Wails v3](https://v3.wails.io), the UI is one HTML page with
[Alpine.js](https://alpinejs.dev), and everything behind it - the
handlers, sqlite storage, the menu, import and export - is let-go.

It is the first real app on the
[`wails`](https://github.com/abogoyavlensky/letgo-packages/tree/master/wails)
package, and it shows the dev loop that package enables: an nREPL inside
the running app, so you redefine a handler and the next click runs it.

- Add a task by typing and pressing Enter; tick it off; double-click to
  rename (Enter saves, Esc cancels); open its notes; delete it.
- Filter All / Active / Done; clear completed tasks.
- File > Export… and Import… move tasks to and from a JSON file.
- Tasks live in sqlite under your config directory
  (`~/Library/Application Support/lgx-tasks/tasks.db` on macOS,
  `~/.config/lgx-tasks/tasks.db` on Linux), or at `$TASKS_DB`.

## Prerequisites

Wails is cgo on the Unix desktops, so this needs more than Go:

| Platform | Needs |
|---|---|
| Linux | `libgtk-4-dev libwebkitgtk-6.0-dev` and a C compiler |
| macOS | Xcode command line tools |
| Windows | not supported - let-go does not build for `GOOS=windows` yet |

It also needs an lgx with `:go/build-tags` (newer than 0.5.0; until a
release has it, use this repo's `bin/lgx`). The first run builds a custom
`lg` runtime with Wails and sqlite linked in; on macOS that takes a few
minutes (the Cocoa layer) and is cached afterwards.

## Run it

```sh
lgx run
```

`lgx run` sets `LGX_RUN`, which turns on the dev loop (`src/tasks/dev.lg`):

- **An nREPL inside the app.** It prints its port and writes
  `.nrepl-port`, so your editor connects to the running app, not a fresh
  process.
- **Redefine and go.** The handlers are registered as vars
  (`src/tasks/api.lg`), so editing `add-task` and loading the buffer
  changes what the next click runs. The same holds for the menu's
  `export!` and `import!`.
- **Rebuild the menu.** Edit `tasks.menu/spec`, then evaluate
  `(tasks.menu/install!)`.
- **Edit the frontend.** Saving anything under `resources/public` reloads
  the window.
- **State survives reloads.** The connection, app and window live in
  `defonce` atoms (`src/tasks/state.lg`), so reloading a namespace keeps
  them.

Only `main.lg`, which builds the app and the window, needs a restart.

## Build it

```sh
lgx build && ./bin/tasks
```

The binary embeds `resources/`, so it does not depend on the directory it
starts in (a macOS app started from Finder runs in `/`). `lgx.edn` adds the
`production` build tag for `lgx build` only (`:targets {:bin
{:go/build-tags ["production"]}}`): the shipped binary drops Wails'
devtools and dev asset server, while `lgx run` keeps them. Outside
`lgx run` there is no nREPL and no asset watcher.

Packaging (an `.app` bundle, icons, a dmg or AppImage) is the `wails3`
CLI's job and works on the built binary; it is not wired up here.

## Without a desktop

On a machine without the webview headers, Wails' server mode runs the same
app as an HTTP server you open in a browser:

```sh
CGO_ENABLED=0 GOFLAGS=-tags=server lgx run    # http://localhost:8080
```

The menu and file dialogs do nothing there. The tests and the smoke check
run this way:

```sh
CGO_ENABLED=0 GOFLAGS=-tags=server lgx test
bash smoke.sh    # serves, calls the handlers, redefines one over the nREPL
```

`smoke.sh` uses the small nREPL client from the letgo-packages `nrepl`
package's tests; point `NREPL_CLIENT` at it if your checkout is elsewhere.

## Layout

| Path | What it does |
|---|---|
| `main.lg` | builds the app and the window, opens the database, starts the dev loop |
| `src/tasks/api.lg` | the handlers the frontend calls, registered by var |
| `src/tasks/db.lg` | the sqlite queries (HoneySQL) |
| `src/tasks/migrations.lg` | the schema history (ragtime) |
| `src/tasks/transfer.lg` | JSON export and import |
| `src/tasks/menu.lg` | the application menu, as data |
| `src/tasks/dev.lg` | the nREPL and the asset watcher, under `lgx run` only |
| `src/tasks/state.lg` | the live connection, app and window |
| `resources/public/` | the frontend: `index.html`, `app.js`, `style.css` |

## Verified on

- Linux, Wails server mode (2026-10-17, Wails v3.0.0-beta.30, let-go
  1.13.0): `lgx test`, `smoke.sh`, and the UI driven in headless
  Chromium.
- The native window (menus, dialogs, Cmd+C/V, asset reload, a Finder
  launch of the built app) has not been checked yet.
