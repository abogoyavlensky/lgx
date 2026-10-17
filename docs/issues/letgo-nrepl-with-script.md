# Issue: `lg -n script.lg` never starts the nREPL server

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed ([nooga/let-go#1075](https://github.com/nooga/let-go/issues/1075)). Worked around with the letgo-packages
[`nrepl`](https://github.com/abogoyavlensky/letgo-packages/tree/master/nrepl)
package, which builds the server inside the program.

## Summary

`lg -n` serves nREPL, but given a script it starts the server only when
`-r` is also passed, and then only after the script has returned
(`pkg/cli/cli.go`: `nreplServe` sits in the `if !ranSomething || runREPL`
branch, after the script ran). A program that
never returns - a GUI event loop, an `http/serve` process, any long-running
service - therefore never gets a server, which is exactly where a REPL into
the live program is most useful.

```sh
lg -n -p 7888 app.lg      # no server at all
lg -n -r -p 7888 app.lg   # server after app.lg returns; (w/run! app) never does
```

## Proposed change

When `-n` is given together with files, start the server *before* running
them. `NreplServer.Start` already returns once its accept goroutine is up,
so the order is safe:

```go
if runNREPL {
    if err := nreplServe(context, nreplPort); err != nil { ... }
}
// then run the files, as today
```

Two details:

- **Do not exit when the files finish** if the server is running, so a
  script that does return keeps serving, as `-n -r` would.
- **One namespace for all.** `*ns*` is process-global, so sessions share
  the program's current namespace. That is how the in-process server in
  the `nrepl` package behaves today, and it is what an editor expects.

## Why it matters for lgx

`lgx nrepl` starts a fresh `lg` with the project's basis, which cannot see
a running app. With this change, `lgx run` could take an `--nrepl` flag
that passes `-n` through, and the `nrepl` package would no longer be
needed for the common case.

## Verify against

`pkg/cli/cli.go` (`nreplServe`, the `ranSomething` branch),
`pkg/nrepl/server.go` (`Start` returns after spawning the accept loop).
