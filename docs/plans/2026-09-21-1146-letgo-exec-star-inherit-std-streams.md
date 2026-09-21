# let-go PR: `os/exec*` passes file-backed `*out*` / `*err*` to the child as descriptors

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status: completed (2026-09-21) except PR creation — see Completion summary.**

**Goal:** A PR to `nooga/let-go` so that `os/exec*` hands the child process a real file descriptor whenever the bound `*out*` / `*err*` is file-backed (the root std streams, or a handle from `open`), and only falls back to a pipe for handles that wrap arbitrary writers. This restores the terminal for REPL and TUI children without undoing #611.

**Tech Stack:** Go (`pkg/rt/iort.go`, `pkg/rt/os.go`), Go tests next to the package, a let-go `.lg` test under `test/`, the repo's `make build` / `make test` / `make generate` / `make check-generated` / `make lint` gates, lgx in dev mode under `script(1)` as the end-to-end probe.

**Repo:** `~/Projects/let-go` (fork `abogoyavlensky/let-go`, remote `upstream` = `nooga/let-go`). Branch `fix/exec-star-inherit-std-streams` off `upstream/main` `6cdeb6d`. The fork's own `main` is ~97 commits behind; do not branch from it. No open PR from this fork touches `pkg/rt/os.go` or `pkg/rt/iort.go`.

---

## Design

### Problem

`os/exec*` (`pkg/rt/os.go`, `execStar`, around line 177) wires the child's
stdout/stderr to `outH.Writer()` / `errH.Writer()` where `outH` is the
IOHandle bound at `*out*`. Since #611 the root handles come from
`newStdStreamHandle` (`pkg/rt/iort.go`, around line 50): the writer is a
`stdStreamWriter{cur}` that re-reads `os.Stdout` per write, so that tests
which swap the package variable still silence output. Go's `os/exec` only
passes a descriptor through when `cmd.Stdout` is an `*os.File`; any other
writer gets a pipe plus a copying goroutine.

Measured under a pty with `lg -e '(os/exec* "sh" "-c" "ls -l /proc/self/fd/1")'`:

| lg | child fd 0 | child fd 1 / 2 |
|---|---|---|
| 1.12.2 | `/dev/pts/N` | `/dev/pts/N` |
| 1.13.0 | `/dev/pts/N` | `pipe:[...]` |

Consequences: a nested `lg` REPL's readline sees stdout and stderr as
non-tty and disables the prompt, echo, and editing (`DefaultIsTerminal` in
`chzyer/readline` needs stdin plus one of stdout/stderr to be a tty). TUI
programs launched through `os/exec*` see no terminal on stdout. lgx hit this
for `lgx repl` / `lgx nrepl` / `lgx run` once built on 1.13.0 and currently
works around it by rebinding `*out*` / `*err*` to `/dev/stdout` /
`/dev/stderr` handles (lgx plan `2026-09-21-0937-exec-star-tty-passthrough.md`,
issue note `docs/issues/exec-star-std-stream-pipes.md`).

### Fix

Add one method to `IOHandle` in `pkg/rt/iort.go`:

```go
// ProcessWriter returns the writer to hand a child process. Go's os/exec
// passes an *os.File through as the child's descriptor and pipes anything
// else, so file-backed handles yield their file: the std-stream handles
// resolve the CURRENT os.Stdout/os.Stderr (test-time swaps still redirect
// the child), and a handle over a file from `open` yields that file.
// Handles over arbitrary writers (with-out-str, io/buffer) keep the writer.
func (h *IOHandle) ProcessWriter() io.Writer
```

Rules, in order:

1. `writer` is a `stdStreamWriter` → return `w.cur()`.
2. `file != nil` and `writer == io.Writer(file)` (a plain `NewIOHandle`) →
   return `file`.
3. otherwise → return `writer` (nil stays nil).

`execStar` replaces the two `Writer()` reads with `ProcessWriter()` and keeps
its nil checks and its two `Sync()` calls (buffered handles still flush; a
file's `Sync()` is harmless). `os/sh` is untouched.

Behaviour after the change:

| `*out*` binding | child stdout |
|---|---|
| root (unbound) | the process's current fd 1, tty included |
| `(binding [*out* (open "f" :append)] ...)` | the file, written directly |
| `with-out-str`, `io/buffer`, `NewWriterHandle` | pipe, captured as today |

### Tests

- `pkg/rt/iort_process_writer_test.go` (Go, same build tags as the other
  `pkg/rt` tests, i.e. none or `!tinygo`):
  - `newStdStreamHandle` with a `cur` that returns a temp file →
    `ProcessWriter()` is that `*os.File`; change what `cur` returns → the
    new file comes back (the swap contract of #611).
  - `NewIOHandle(tempfile)` → the same `*os.File`.
  - `NewWriterHandle("buf", &bytes.Buffer{})` → the buffer itself.
  - Linux-only end to end (`t.Skip` elsewhere): swap `os.Stdout` and
    `os.Stderr` to two temp files for the test's duration, invoke `os/exec*`
    via `LookupVar("os", "exec*")` (the `http_empty_headers_test.go`
    pattern) with `sh -c 'readlink /proc/self/fd/1; readlink /proc/self/fd/2 >&2'`,
    restore both, and assert each temp file's content is its own path, not
    a `pipe:` link. Both streams are part of the fix.
- `test/os_exec_star_test.lg`, new `deftest exec-star-follows-out-binding`:
  - `(with-out-str (os/exec* "sh" "-c" "echo captured"))` is `"captured\n"`,
    guarding the pipe path.
  - `binding` `*out*` to `(open tmp :append)` where `tmp` is a fresh path
    under `(os/temp-dir)`, run `(os/exec* "sh" "-c" "echo to-file")`,
    `close!`, `slurp`, expect `"to-file\n"`, then `delete-file`.
- Gates: `make build`; `go test ./pkg/rt -run ProcessWriter -count=1`;
  `go test ./test/ -run 'TestRunner/os_exec_star' -count=1`; `make test`;
  `make generate` (a Go change under `pkg/rt` moves the generator-input
  digest, so `pkg/rt/generated.manifest` / `generated.sums` refresh and are
  committed); `make check-generated`; `make lint`. Each long gate runs as
  its own background job.

### End-to-end proof (manual, Linux)

With `LG=~/Projects/let-go/bin/lg` after `make build`, from
`~/Projects/lgx` on a branch that does **not** carry the lgx workaround
(e.g. `master` before the passthrough PR merges, or with the binding
temporarily commented out):

```
LGX_LG=$LG script -qfec "$LG lgx.lg repl" /dev/null < <(sleep 3; printf '(+ 1 2)\n'; sleep 1; printf '\x04') | cat -A | head
```

Expected: a `user=>` prompt before `3`. Before the fix the same command
prints only the banner and `3`.

### Docs

`docs/guide/os.md`, the `os/exec*` bullet: "streams through the current
`*out*` and `*err*` bindings; when a binding is file-backed (the std streams
by default, or a handle from `open`) the child receives that descriptor
directly, so an interactive child keeps the terminal; other writers are
piped." Bump `last-verified` to the PR date; leave `human-verified` as is.

### Commit and PR

One commit for code, tests, docs, and manifests:
`fix(rt): os/exec* passes file-backed *out*/*err* to the child as descriptors`.
Body: the symptom (nested REPL loses its prompt on 1.13.0, TUI children see
no tty), the cause (`stdStreamWriter` is not an `*os.File` so `os/exec`
pipes), the rule `ProcessWriter` applies, and "make generate after this
change" for the manifests.

PR against `nooga/let-go` `main`, title equal to the commit subject. Body:
the fd table above, the one-line pty reproduction, the behaviour matrix, a
link to lgx's issue note, and a note that lgx carries a rebinding
workaround it will remove once a release ships this.

## File Structure

- Modify: `pkg/rt/iort.go` - add `ProcessWriter` next to `Writer()`.
- Modify: `pkg/rt/os.go` - `execStar` uses `ProcessWriter()` for stdout and stderr.
- Create: `pkg/rt/iort_process_writer_test.go` - Go tests listed above.
- Modify: `test/os_exec_star_test.lg` - `exec-star-follows-out-binding`.
- Modify: `docs/guide/os.md` - bullet and `last-verified`.
- Regenerate: `pkg/rt/generated.manifest`, `pkg/rt/generated.sums`.

All paths are relative to `~/Projects/let-go`.

## Tasks

### Task 1: Branch and failing tests

**Files:**
- Create: `pkg/rt/iort_process_writer_test.go`
- Modify: `test/os_exec_star_test.lg`

- [x] **Step 1: Branch from upstream**
  `cd ~/Projects/let-go && git fetch upstream && git checkout -b fix/exec-star-inherit-std-streams upstream/main`
  Expected: branch at `6cdeb6d` or newer.

- [x] **Step 2: Write the Go tests**
  Create `pkg/rt/iort_process_writer_test.go` with the four cases from the
  Design section. Use `t.TempDir()` for files, `t.Cleanup` to restore
  `os.Stdout`, and `runtime.GOOS != "linux"` → `t.Skip` for the
  `/proc/self/fd` case. Name the top-level tests `TestIOHandleProcessWriter`
  and `TestExecStarPassesStdoutDescriptor`.

- [x] **Step 3: Write the lg test**
  Append `exec-star-follows-out-binding` to `test/os_exec_star_test.lg`
  with the two assertions from the Design section.

- [x] **Step 4: Run both to verify they fail for the right reason**
  Run: `go test ./pkg/rt -run 'ProcessWriter|ExecStarPasses' -count=1 2>&1 | tail -5`
  Expected: compile error, `h.ProcessWriter undefined`.
  Run: `make build 2>&1 | tail -1 && go test ./test/ -run 'TestRunner/os_exec_star' -count=1 2>&1 | grep -E "Finished|FAIL|^ok"`
  Expected: `with-out-str` passes already; the file-binding assertion also
  passes today because `Writer()` of an `open` handle is the file. That is
  fine: this deftest is a regression guard, not the red step. The red step
  is the Go test.

### Task 2: Implement `ProcessWriter` and use it in `exec*`

**Files:**
- Modify: `pkg/rt/iort.go`
- Modify: `pkg/rt/os.go`

- [x] **Step 1: Add the method**
  In `pkg/rt/iort.go`, directly after `Writer()` / `ReaderRaw()`, add
  `ProcessWriter` implementing the three rules with the doc comment from
  the Design section.

- [x] **Step 2: Use it in `execStar`**
  In `pkg/rt/os.go` replace `outH.Writer()` / `errH.Writer()` in the
  `cmd.Stdout` / `cmd.Stderr` assignments (and their nil guards) with
  `ProcessWriter()`. Update the comment block above `execStar`: the child
  streams through the current `*out*` / `*err*`, and file-backed bindings
  are passed as descriptors so an interactive child keeps the terminal.

- [x] **Step 3: Run the targeted tests**
  Run: `go test ./pkg/rt -run 'ProcessWriter|ExecStarPasses' -count=1 2>&1 | tail -3`
  Expected: `ok`.
  Run: `make build 2>&1 | tail -1 && go test ./test/ -run 'TestRunner/os_exec_star' -count=1 2>&1 | grep -E "Finished|FAIL|^ok"`
  Expected: `ok`.

- [x] **Step 4: Pty proof with lgx**
  Run the End-to-end proof command from the Design section with
  `LG=~/Projects/let-go/bin/lg`, on an lgx tree without the rebinding
  workaround.
  Expected: `user=>` appears before `3`. Also run the fd probe:
  `script -qfec "$LG -e '(os/exec* \"sh\" \"-c\" \"ls -l /proc/self/fd/1 /proc/self/fd/2\")'" /dev/null`
  Expected: both point at `/dev/pts/N`.

- [x] **Step 5: Confirm capture still works from the CLI**
  Run: `$LG -e '(println (with-out-str (os/exec* "sh" "-c" "echo hi")))'`
  Expected: `hi` printed once, from the captured string.

> Deviation: `ProcessWriter` rule 1 falls back to the raw `stdStreamWriter` when `cur()` returns nil, so a nil `os.Stdout` can never become a closed child descriptor. The session task-list tools were unavailable in this harness; the plan document is the only tracking surface. The codex review for Tasks 1 and 2 ran once, after Task 2, because the plan's single commit lands in Task 3.

### Task 3: Docs, gates, commit

**Files:**
- Modify: `docs/guide/os.md`
- Regenerate: `pkg/rt/generated.manifest`, `pkg/rt/generated.sums`

- [x] **Step 1: Update the guide**
  Edit the `os/exec*` bullet and `last-verified` as described in Docs.

- [x] **Step 2: Regenerate and gate (background jobs, one at a time)**
  Run: `make generate`, then `make check-generated`, then `make test`,
  then `make lint`.
  Expected: all green; `git status` shows `generated.manifest` and
  `generated.sums` modified and nothing else unexpected.

- [x] **Step 3: Commit**
  ```
  git add pkg/rt/iort.go pkg/rt/os.go pkg/rt/iort_process_writer_test.go \
    test/os_exec_star_test.lg docs/guide/os.md \
    pkg/rt/generated.manifest pkg/rt/generated.sums
  git commit -m "fix(rt): os/exec* passes file-backed *out*/*err* to the child as descriptors"
  ```
  Body as specified in Commit and PR.

> Deviation: the gates ran to completion but only after clearing Go build caches three times — the machine's disk was at 100% (`make check-generated` and `make lint` both died with "no space left on device" first). Only self-rebuilding caches were removed (`~/.cache/go-build`, `.cache/local/cache/go-build` here and in the `let-go-pr773` worktree, a Go tarball, `/tmp/go-build*`). The boot-budget smoke gate also failed once on timing noise (median 8.17ms vs 8ms budget on a 2-core box) and passed on rerun; no override was used.

### Task 4: Push and open the PR

**Files:** none

- [x] **Step 1: Push**
  `git push -u origin fix/exec-star-inherit-std-streams`

- [ ] **Step 2: Open the PR**
  `gh pr create -R nooga/let-go --base main --head abogoyavlensky:fix/exec-star-inherit-std-streams --title "fix(rt): os/exec* passes file-backed *out*/*err* to the child as descriptors" --body-file <body>`
  Body per Commit and PR. Record the URL in `.tmp/pr-exec-star-link.txt`
  (gitignored scratch, matching the earlier let-go plans).

- [ ] **Step 3: Update the lgx issue note**
  In `~/Projects/lgx/docs/issues/exec-star-std-stream-pipes.md` set
  `**Status:**` to `PR open: <url>` and add the same to the README table
  row. Commit in lgx, staging only those two files:
  `git add docs/issues/exec-star-std-stream-pipes.md docs/issues/README.md && git commit -m "docs(issues): link the os/exec* descriptor PR"`.

> Blocked: the `gh` token is a fine-grained PAT without `createPullRequest` on `nooga/let-go` (`Resource not accessible by personal access token`); pushing to the fork worked. A prefilled compare link (title + body) is in `~/Projects/let-go/.tmp/pr-exec-star-link.txt` — open it in the browser to create the PR, then do Step 3 with the resulting URL.

## lgx follow-up (not part of this PR)

When a let-go release contains the fix and lgx's `.mise.toml` / `:lg-version`
move to it: delete `passthrough-handles` and the `binding` in
`runner/exec-lg-interactive!`, drop its tests, restore the plain wording in
`docs/ARCHITECTURE.md`, `docs/knowledge-base/let-go-gotchas.md` and the
stdlib quick reference, and mark the issue note resolved.

## Completion summary (2026-09-21)

**Implemented.** Commit `fec44c2` on `fix/exec-star-inherit-std-streams` (pushed to `abogoyavlensky/let-go`, based on `upstream/main` `6cdeb6d`): `IOHandle.ProcessWriter` in `pkg/rt/iort.go` with the three rules; `execStar` in `pkg/rt/os.go` uses it for `cmd.Stdout`/`cmd.Stderr`; `pkg/rt/iort_process_writer_test.go` (unit rules + Linux `/proc/self/fd` end-to-end on both streams); `exec-star-follows-out-binding` in `test/os_exec_star_test.lg`; `docs/guide/os.md` bullet + `last-verified`; regenerated `pkg/rt/generated.manifest` / `generated.sums`.

**Verified.** Targeted Go and lg tests green; `make build`, `make generate`, `make check-generated`, `make test`, `make lint` (0 issues) all green. End to end under `script(1)` on an lgx `master` worktree (no workaround): unpatched `upstream/main` build → child fds 1/2 `pipe:[...]`, nested REPL prints only banner and `3`; patched build → `/dev/pts/0` on fds 0/1/2 and a `user=>` prompt with echo/editing. `with-out-str` and an `io/buffer` bound at `*err*` still capture. Codex reviewed twice (uncommitted after Task 2, then commit `fec44c2`): no actionable findings either time.

**Not done.** PR creation and the lgx issue-note link (Task 4 Steps 2–3): the `gh` PAT cannot create PRs on `nooga/let-go`. Prefilled compare link in `~/Projects/let-go/.tmp/pr-exec-star-link.txt`.

**Deviations (all recorded inline above).**
- `ProcessWriter` rule 1 falls back to the raw writer when `cur()` returns nil (never hands the child a closed fd).
- Session task-list tools were unavailable; this document was the only tracking surface. One codex review covered Tasks 1+2 (single commit lands in Task 3).
- Disk at 100% broke `check-generated` and `lint`; cleared only self-rebuilding Go build caches (three times). Boot-budget smoke gate failed once on timing noise, passed on rerun, no override used.

**What the plan could have specified better:** that `gh` on this machine cannot open PRs against `nooga/let-go` (earlier PRs from this fork must have been opened another way), so Task 4 should have planned for a compare link from the start; and a note that `go` is mise-managed but not on PATH here.
