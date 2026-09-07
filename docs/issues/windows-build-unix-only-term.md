# let-go does not compile for GOOS=windows

**Status:** draft

Found while verifying lgx cross-compilation (2026-08-24, let-go checkout
on the `integration/go-interop` line).

`pkg/rt/term.go` uses `golang.org/x/sys/unix` (SIGWINCH, PollFd, Poll,
POLLIN/POLLHUP/POLLERR/POLLNVAL, EINTR) with no build tag guarding it,
so any `GOOS=windows` build of let-go fails:

```
$ GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build .
pkg/rt/term.go:55:29: undefined: unix.SIGWINCH
pkg/rt/term.go:183:16: undefined: unix.PollFd
...
```

Consequence for lgx: `lgx build --target windows/amd64` (and windows in
`:platforms`) cannot work until this is fixed upstream — the failure
happens in the runtime's final `go build`, with Go's own diagnostics
shown. Every unix-family target lgx was verified against (linux/amd64,
linux/arm64, darwin/arm64) builds fine.

Likely fix shape upstream: split `term.go` into `term_unix.go`
(`//go:build unix`) plus a windows fallback implementing the same
surface with `golang.org/x/sys/windows` or a no-op raw mode.
