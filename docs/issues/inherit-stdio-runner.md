# Issue: add `os/run` (or equivalent) for shelling out with inherited stdio

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

## Summary

`os/sh` ([`pkg/rt/os.go:122`](https://github.com/nooga/let-go/blob/master/pkg/rt/os.go#L122))
captures stdout/stderr into buffers and returns them as strings on a
result record. That's the right shape when the caller wants the output
programmatically, but there's no escape hatch for cases where the child
process should drive the parent's terminal:

- Long-running scripts can't stream output — everything appears at once
  after the child exits.
- The child has no stdin — interactive subprocesses (REPL, `read-line`,
  password prompts) can't work.
- Users see no progress on long-running operations.

`os/exec` returns a raw `*exec.Cmd`, but no `Run` / `Wait` is exposed on
it, and `Stdout` / `Stderr` / `Stdin` fields aren't reachable from let-go.

## Concrete impact

In `lgx`, the entry point for running a project script is `lgx run …`,
which exec's `lg` with computed `-source-paths`. With only `os/sh`
available, `lgx run -r script.lg` (REPL mode) cannot work — `lg`'s REPL
needs a real stdin and a streaming stdout.

## Proposal

Add `(os/run cmd & args)` that runs the command with `cmd.Stdout`,
`cmd.Stderr`, `cmd.Stdin` wired to the parent's, and returns the exit
code as an Int.

```clojure
(let [code (os/run "git" "clone" "--quiet" url dest)]
  (when-not (zero? code)
    (throw (ex-info "git clone failed" {:exit code}))))
```

Implementation is small — same shape as `os/sh` minus the buffers, plus
exit-code passthrough.

Alternative shapes if preferred: extend `os/sh` with an `:inherit-io true`
opts arg, or expose `(os/cmd …)` builders + `(os/start cmd)` /
`(os/wait cmd)` for finer control. The narrow `os/run` is the smallest
surface that solves the immediate problem.
