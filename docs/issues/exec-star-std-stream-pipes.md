# Issue: `os/exec*` gives the child a pipe for stdout/stderr since #611, so a REPL child loses the tty

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft, worked around in lgx (`runner/exec-lg-interactive!`
rebinds `*out*` / `*err*` when they are terminals - see Workaround)

## Summary

`os/exec*` wires the child's stdout and stderr to the current `*out*` /
`*err*` handle writers
([`pkg/rt/os.go:196-208`](https://github.com/nooga/let-go/blob/v1.13.0/pkg/rt/os.go#L196-L208),
the `execStar` fn):

```go
outH := resolveIOHandleVar(ec, "*out*")
if outH != nil && outH.Writer() != nil {
    cmd.Stdout = outH.Writer()
}
```

Since #611 (shipped in 1.13.0) the root handles come from
`newStdStreamHandle`
([`pkg/rt/iort.go:50-52`](https://github.com/nooga/let-go/blob/v1.13.0/pkg/rt/iort.go#L50-L52)),
whose writer is a `stdStreamWriter`
([`pkg/rt/iort.go:43-45`](https://github.com/nooga/let-go/blob/v1.13.0/pkg/rt/iort.go#L43-L45))
that re-reads `os.Stdout` / `os.Stderr` on every write. That is not an
`*os.File`, and Go's `os/exec` only hands the descriptor to the child when
`cmd.Stdout` is an `*os.File`; for any other `io.Writer` it creates a pipe
and a copying goroutine. Measured under a pty:

| lg runtime | child fd 0 | child fd 1 / 2 |
|---|---|---|
| lg 1.12.2 | `/dev/pts/N` | `/dev/pts/N` |
| lg 1.13.0 | `/dev/pts/N` | `pipe:[...]` |

One-line reproduction on Linux (`script(1)` provides the pty):

```
script -qfec "lg -e '(os/exec* \"sh\" \"-c\" \"ls -l /proc/self/fd/1; test -t 1 && echo tty || echo notty\")'" /dev/null
```

1.12.2 prints `/dev/pts/N` and `tty`; 1.13.0 prints `pipe:[...]` and
`notty`.

The output still arrives (the goroutine copies it), so the regression is
invisible until the child asks whether it has a terminal.

## Concrete impact

- A nested `lg` REPL launched with `os/exec*` (lgx's `lgx repl`,
  `lgx nrepl`, and `lgx run -r` all do this) prints its banner and
  evaluates forms but shows no prompt, no echo and no line editing:
  `chzyer/readline`'s `DefaultIsTerminal` needs stdout or stderr to be a
  tty.
- TUI programs run through `os/exec*` see no terminal on stdout
  (`term/size`, `term/tty?`, isatty probes), so they fall back to their
  non-interactive mode.
- Anything that colours output based on isatty goes monochrome.

## Proposal

In `execStar`, keep passing the descriptor through for the unrebound root
handles and only fall back to the generic `Writer()` for genuinely rebound
ones (`with-out-str`, `binding` to a file handle):

```go
// cmdStream picks what the child inherits for one std stream. A root
// std-stream handle (file set, stdStreamWriter) hands over the CURRENT
// os.Stdout/os.Stderr *os.File so the child gets the descriptor and #611's
// test-time swap of the package variable still applies. Any other handle
// (with-out-str buffer, a file opened by the program) keeps its Writer().
func cmdStream(h *IOHandle, fallback *os.File) io.Writer {
    if h == nil || h.Writer() == nil {
        return fallback
    }
    if sw, ok := h.Writer().(stdStreamWriter); ok && h.File() != nil {
        return sw.cur()
    }
    return h.Writer()
}

cmd.Stdout = cmdStream(outH, os.Stdout)
cmd.Stderr = cmdStream(errH, os.Stderr)
```

This keeps #611's intent (writes and the child follow the package variable
at call time) and restores the pre-1.13.0 behaviour where a child of an
unrebound `*out*` inherits the real descriptor. An alternative with the same
effect is an `IOHandle` method that answers "file-backed and unrebound"
(e.g. `func (h *IOHandle) InheritableFile() *os.File`), so `execStar` does
not need to know the `stdStreamWriter` type.

A regression test can run `sh -c 'test -t 1'` under a pty (`term/open-pty`
exists) and assert exit code 0, or, without a pty, compare
`/proc/self/fd/1` readlink output with and without a `with-out-str`
rebinding.

## Workaround (lgx)

`runner/exec-lg-interactive!` in lgx checks `(term/tty? *out*)` and
`(term/tty? *err*)` and, for each stream that is a terminal, rebinds the
var to a handle from `(open "/dev/stdout" :append)` /
`(open "/dev/stderr" :append)` for the duration of the `os/exec*` call. A
handle from `open` is backed by the raw `*os.File`, so the child inherits
the descriptor. Streams that are a pipe or a regular file are left alone:
reopening `/dev/stdout` creates a new open file description, so a child's
writes would not advance the shell's offset and
`{ lgx run ...; echo done; } > out.txt` would overwrite the child's output.

Remove the rebinding once lgx's minimum let-go version carries the fix.
