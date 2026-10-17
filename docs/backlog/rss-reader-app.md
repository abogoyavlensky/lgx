# An RSS reader as the second Wails app

**Status: open**

[`examples/wails-tasks`](../../examples/wails-tasks) is the first real app
on the `wails` package. An RSS reader was the other candidate, and it would
exercise what the task manager does not: parsing a foreign format, and work
that runs without the user, in the background.

## Problem

- **No XML parser.** let-go 1.13.0 has none in its stdlib. Go's
  `encoding/xml` through `:go/interop` is impractical: decoding targets
  tagged structs and the streaming API hands back `xml.Token` interface
  values, neither of which the generated bindings can carry. It needs a
  `:go/local` shim (or a letgo-packages package), possibly over
  [gofeed](https://github.com/mmcdole/gofeed), which also handles Atom and
  JSON Feed and returns plain data the shim can convert.
- **A background poller.** Feeds refresh on a timer, off the UI, and push
  new items to the window with `w/emit!`. A `future` loop works; the open
  question is stopping it cleanly from `:on-shutdown`.
- **Notifications.** Wails v3.0.0-beta.30 ships
  `pkg/services/notifications` (darwin and linux), which the `wails` shim
  does not wrap yet.

## Proposed fix

A `feed` package in letgo-packages (a shim over gofeed returning maps),
then `examples/wails-rss` on it: sqlite for feeds and items, a poller, and
a `notify!` in the `wails` veneer over the notifications service.

## Origin

Raised with the task manager in
[`docs/plans/2026-10-16-2307-wails-desktop-first-app.md`](../plans/2026-10-16-2307-wails-desktop-first-app.md)
(2026-10-17), which picked the task manager first because it needs no
parser.
