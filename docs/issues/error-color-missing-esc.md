# Error formatter emits ANSI codes without the `\x1b` ESC byte

**Repo:** [nooga/let-go](https://github.com/nooga/let-go) ·
**File:** [`pkg/vm/ansi.go`](https://github.com/nooga/let-go/blob/master/pkg/vm/ansi.go) ·
**Status:** draft (fix proposed)

## Problem

The error formatter in `pkg/vm/errfmt.go` wraps spans with the constants
declared in `pkg/vm/ansi.go`:

```go
const (
    ansiBold     = "[1m"
    ansiBoldRed  = "[1;31m"
    ansiBoldBlue = "[1;34m"
    ansiReset    = "[0m"
)
```

These are **missing the `\x1b` (ESC, 0x1B) prefix** that turns a `[...`
sequence into a CSI escape. Without ESC, terminals treat the bytes as
plain text. Compile/runtime errors render as:

```
[1;31merror:[0m Can't resolve m/index-by in this context
  [1;34m-->[0m main.lg:9:19
   [1;34m|[0m
 [1;34m9[0m [1;34m|[0m (println "by-id:" (m/index-by :id people))
```

instead of colored output. Confirmed by dumping raw bytes:

```
$ lg main.lg 2>&1 | od -c | head -2
0000000   [   1   ;   3   1   m   e   r   r   o   r   :   [   0   m
0000020   C   a   n   '   t       r   e   s   o   l   v   e       m   /
```

No `033` anywhere. This is independent of TTY state — same result under
a real terminal and under `script` / pipe.

The REPL banner (`lg_ansi.go` at the repo root, used by `lg.go`) has the
ESC byte in its constants and renders correctly, so the bug is isolated
to `pkg/vm/ansi.go`. The plan9 stub (`pkg/vm/ansi_plan9.go`) is also
correct — it stubs the constants to empty strings.

## Fix

```go
const (
    ansiBold     = "\x1b[1m"
    ansiBoldRed  = "\x1b[1;31m"
    ansiBoldBlue = "\x1b[1;34m"
    ansiReset    = "\x1b[0m"
)
```

After the change, `od -c` of the same failing script shows
`033 [ 1 ; 3 1 m e r r o r :` and the error renders bold red in any
ANSI-aware terminal.

## Notes

- No call-site changes needed — `errfmt.go` already concatenates the
  constants into `fmt.Fprintf` format strings.
- Plan9 build (`ansi_plan9.go`) is unaffected; it already uses empty
  strings.
- Worth considering a TTY check (or `NO_COLOR` env support) at the
  emission site as a follow-up so output is plain when stdout/stderr
  isn't a terminal. Out of scope for this fix.
