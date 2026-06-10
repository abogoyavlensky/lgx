# Issue: support `-p 0` (OS-assigned port) for the nREPL server

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

`lg -n -p <port>` binds the nREPL server to a fixed port, and every
place the port is reported uses the *requested* number, not the one
actually bound:

- `NreplServer.Start` ([`pkg/nrepl/server.go:81-93`](https://github.com/nooga/let-go/blob/master/pkg/nrepl/server.go#L81))
  calls `net.Listen("tcp", "127.0.0.1:<port>")`, then writes the `port`
  argument to `.nrepl-port` and prints it in the
  `nREPL server started on port N ...` line.
- `lg.go` prints `nREPL server running at tcp://127.0.0.1:%d` from the
  `nreplPort` flag value
  ([`lg.go:886-892`](https://github.com/nooga/let-go/blob/master/lg.go#L886)).

Passing `-p 0` "works" at the listener level — `net.Listen` asks the OS
for a free port — but everything user-facing then reports port `0`:
`.nrepl-port` contains `0`, so editors that auto-connect via that file
dial the wrong address, and the startup banner is useless. The real
port is already available at bind time via
`l.Addr().(*net.TCPAddr).Port`; it is just never read.

## Concrete impact

`lgx nrepl` (the lgx subcommand wrapping `lg -n -p <port>`) wants
"start an nREPL on any free port" as its default. Because `-p 0` is
unusable, lgx has to *guess* a random port in the ephemeral range and
hope it is free. let-go exposes no socket primitive to probe with, and
a probe would be racy anyway (check-then-bind TOCTOU). On a collision
lg prints `failed to run nREPL server on port N` and continues into the
terminal REPL without an nREPL — recoverable, but silent-ish and
needless. OS-assigned ports would make the random-port path
collision-proof: `lgx nrepl` would just pass `-p 0` and read the real
port back from lg's output / `.nrepl-port`.

## Proposal

Derive the reported port from the listener instead of the argument:

```go
func (n *NreplServer) Start(port int) error {
    l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
    if err != nil {
        return err
    }
    n.listener = l
    n.port = l.Addr().(*net.TCPAddr).Port // actual port, == arg unless 0

    os.WriteFile(".nrepl-port", fmt.Appendf(nil, "%d", n.port), 0644)
    fmt.Printf("nREPL server started on port %d on host 127.0.0.1 - nrepl://127.0.0.1:%d\n",
        n.port, n.port)
    ...
}
```

plus a `Port()` accessor so `lg.go`'s
`nREPL server running at tcp://127.0.0.1:%d` line can print
`nreplServer.Port()` rather than the flag value. For any non-zero
`port` the behavior is byte-identical, so existing users see no change;
`-p 0` becomes "pick a free port and tell me which". Optionally the
`-p` flag help could mention `0 = OS-assigned`.
