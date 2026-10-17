# The Wails native window has never run on Linux

**Status: open**

## Problem

The `wails` package and `examples/wails-tasks` were verified on Linux only
in Wails' server mode (`CGO_ENABLED=0 GOFLAGS=-tags=server`), where there
is no window, the menu is a no-op and file dialogs return an error. The
GTK4/WebKitGTK path - the real window, menus, accelerators, dialogs,
`watch-assets!` reloading the webview - has not been built or run: the
machine it was written on has no `libgtk-4-dev` or `libwebkitgtk-6.0-dev`
and no root to install them.

## Proposed fix

On a Linux desktop with `libgtk-4-dev`, `libwebkitgtk-6.0-dev` and a C
compiler, run `lgx run` and `lgx build` in `examples/wails-tasks` and walk
the same checklist as macOS: the window opens, File > Export and Import
show dialogs, the accelerators fire, editing `resources/public` reloads the
window, and an nREPL redefinition takes effect. Record the result under
"Verified on" in the example's README and in
[`lgx-wails-desktop.md`](../knowledge-base/lgx-wails-desktop.md).

## Origin

[`docs/plans/2026-10-16-2307-wails-desktop-first-app.md`](../plans/2026-10-16-2307-wails-desktop-first-app.md)
(2026-10-17), which could verify only server mode on Linux.
