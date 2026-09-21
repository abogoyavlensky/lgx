# Keep the terminal for `lgx repl` / `nrepl` / `run` on let-go 1.13.0

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the child `lg` spawned by `runner/exec-lg-interactive!` inherit lgx's real stdout/stderr again when lgx runs on let-go 1.13.0, and file the upstream issue that makes the workaround removable.

**Tech Stack:** let-go (`lg` 1.13.0 as lgx's runtime and as the child), lgx unit tests via `lgx test`, `script(1)` for pseudo-terminal verification.

---

## Design

### Problem

`lgx repl`, `lgx nrepl`, and `lgx run` all launch `lg` through
`runner/exec-lg-interactive!` (`lgx/runner.lg:190`), which calls let-go's
`os/exec*`. `os/exec*` wires the child's stdout and stderr to the current
`*out*` / `*err*` handle writers (`pkg/rt/os.go`, comment above `exec*`).

Since let-go PR #611 (shipped in 1.13.0) the root `*out*` / `*err*` handles are
built by `newStdStreamHandle`, whose writer is a `stdStreamWriter` wrapper,
not the raw `*os.File`. Go's `os/exec` only passes a descriptor through when
`cmd.Stdout` is an `*os.File`; for any other writer it creates a pipe and a
copying goroutine. Result, measured under a pty:

| lgx runtime | child fd 0 | child fd 1 / 2 |
|---|---|---|
| lg 1.12.2 | `/dev/pts/N` | `/dev/pts/N` |
| lg 1.13.0 | `/dev/pts/N` | `pipe:[...]` |

The child `lg`'s readline treats the session as non-interactive when stdout
and stderr are both non-tty (`chzyer/readline` `DefaultIsTerminal`): banner
prints, forms evaluate, but no prompt, no echo, no editing. Programs run via
`lgx run` that probe `term/size` or `isatty` on stdout see no terminal.

The released lgx 0.3.0 still works only because its bundle embeds an older
let-go runtime. `.mise.toml` now pins lg 1.13.0, so the next lgx build
regresses unless this lands.

### Fix (lgx side)

Rebind `*out*` and `*err*` around the `os/exec*` call to handles opened on
`/dev/stdout` and `/dev/stderr`. `open` returns an IOHandle built by
`NewIOHandle(f)`, whose writer is the `*os.File` itself, so `os/exec*` hands
the descriptor to the child. Verified under a pty on lg 1.13.0: child fd 1/2
become `/dev/pts/N` again and the nested REPL prompt returns. `binding` on
`*out*` / `*err*` works on both lg 1.12.2 and 1.13.0.

Decisions:

- **One helper, one call site.** `passthrough-handles` in `lgx/runner.lg`
  takes the two device paths, opens both in `:append` mode, and returns
  `[out err]` or `nil` if either open throws. `exec-lg-interactive!` binds
  when it gets a pair and falls back to a plain `os/exec*` otherwise.
- **Append mode.** `:write` carries `O_TRUNC`, which would truncate a regular
  file when stdout is redirected. `:append` is safe for a tty, a pipe, and a
  file.
- **Always rebind.** No tty detection. Inheriting stdio is the documented
  contract of this function, and nothing in lgx captures `*out*` around it.
  *Superseded during execution (see Task 2 deviation): rebind only the
  streams that are currently a terminal (`term/tty?`).*
- **Handles are not closed.** The function ends in `os/exit` with the child's
  exit code.
- **Verification is manual with a pty.** The e2e suite has no pseudo-terminal
  harness and `script(1)` flags differ between Linux and macOS. Task 4 lists
  exact commands for Linux; the gap is recorded in the plan and the issue note.
- **macOS assumption.** `/dev/stdout` and `/dev/stderr` exist on darwin as
  links into `/dev/fd`, so the same code applies. Not tested here.

### Upstream issue (let-go side)

A `docs/issues/` note proposes that `os/exec*` pass the handle's underlying
current std-stream file when `*out*` / `*err*` is the unrebound root handle
(`h.File()` is set and the writer is a `stdStreamWriter`), and only use the
generic `Writer()` for genuinely rebound handles (`with-out-str`, file
handles). That keeps #611's intent (tests swapping `os.Stdout`) and restores
descriptor inheritance. The note records the lgx workaround and the removal
condition: drop the binding once lgx's minimum lg carries the fix.

### Docs affected

- `docs/ARCHITECTURE.md` (~216-226) promises stdout/stderr inheritance from
  `os/exec*` alone.
- `docs/knowledge-base/let-go-gotchas.md` (~55-70): the `os/sh` section makes
  the same promise, and the next section claims `*out*` / `*err*` cannot be
  rebound with `binding`, which is false on 1.12.2 and 1.13.0.
- `docs/knowledge-base/let-go-stdlib-quick-ref.md` (~115) describes `exec*`
  as inheriting stdio.
- `docs/issues/inherit-stdio-runner.md` status and `docs/issues/README.md`
  table.

## File Structure

- Modify: `lgx/runner.lg` - add `passthrough-handles`, change
  `exec-lg-interactive!` to bind through it, fix its docstring.
- Modify: `test/lgx/runner_test.lg` - unit tests for `passthrough-handles`.
- Create: `docs/issues/exec-star-std-stream-pipes.md` - upstream issue note.
- Modify: `docs/issues/README.md` - new table row; point the
  `inherit-stdio-runner.md` row at the follow-up.
- Modify: `docs/issues/inherit-stdio-runner.md` - status pointer.
- Modify: `docs/ARCHITECTURE.md`,
  `docs/knowledge-base/let-go-gotchas.md`,
  `docs/knowledge-base/let-go-stdlib-quick-ref.md` - correct the stale claims.

## Tasks

### Task 1: `passthrough-handles` with tests

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [x] **Step 1: Write the failing tests**
  Add a `passthrough-handles` section to `test/lgx/runner_test.lg`:
  - `(runner/passthrough-handles "/dev/stdout" "/dev/stderr")` returns a
    two-element vector whose elements are both non-nil.
  - `(runner/passthrough-handles "/nonexistent/dir/out" "/dev/stderr")`
    returns `nil`.
  - `(runner/passthrough-handles "/dev/stdout" "/nonexistent/dir/err")`
    returns `nil`.
  `open` on `/dev/stdout` succeeds under `lgx test` even though stdout is a
  pipe there, so the positive case is stable in CI.

- [x] **Step 2: Run tests to verify they fail**
  Run from the repo root: `lg lgx.lg test`
  Expected: the three new tests fail to load or error with
  `Can't resolve passthrough-handles` (message wording may differ).

- [x] **Step 3: Implement `passthrough-handles`**
  In `lgx/runner.lg`, just above `exec-lg-interactive!`, add a public fn
  with the signature `(passthrough-handles out-path err-path)`. Wrap the two
  `(open path :append)` calls in a single `try`; return `[out err]` on
  success and `nil` from the `catch`. Docstring: why the handles exist
  (let-go 1.13.0 `os/exec*` pipes anything that is not a raw file), why
  `:append` (no `O_TRUNC`), and that the caller falls back to plain `exec*`
  on `nil`. Reference `docs/issues/exec-star-std-stream-pipes.md`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test`
  Expected: all runner tests pass, `0 failures, 0 load failures`.

- [x] **Step 5: Commit**
  `git commit -am "runner: add passthrough-handles for exec* stdio inheritance"`

> Deviation: let-go's `catch` takes no exception class, so the helper uses
> `(catch _ nil)`; `open` was added to `.clj-kondo/config.edn`'s builtin
> exclude list so `make lint` stays clean.

### Task 2: Bind `*out*` / `*err*` in `exec-lg-interactive!`

**Files:**
- Modify: `lgx/runner.lg`

- [x] **Step 1: Change the call**
  In `exec-lg-interactive!`, after computing `[bin args]`, call
  `(passthrough-handles "/dev/stdout" "/dev/stderr")`. If it returns a
  pair, run `(apply os/exec* bin args)` inside
  `(binding [*out* out *err* err] ...)`; otherwise call `os/exec*` directly.
  Keep `os/exit` on the result in both branches. Do not close the handles.

- [x] **Step 2: Fix the docstring**
  Replace the current "parent's stdin/stdout/stderr inherited (via os/exec*)"
  wording. State: stdin is inherited by `os/exec*`; stdout/stderr are
  inherited only because `*out*` / `*err*` are rebound to `/dev/stdout` and
  `/dev/stderr` file handles for the duration of the call, since let-go
  1.13.0's `os/exec*` pipes any non-file writer. Name the fallback.

- [x] **Step 3: Run the unit tests**
  Run: `lg lgx.lg test`
  Expected: `0 failures, 0 load failures`.

- [x] **Step 4: Commit**
  `git commit -am "runner: keep the tty on stdout/stderr for interactive lg children"`

> Deviation: codex review reproduced output corruption with the plan's
> "always rebind" rule - on Linux, `open "/dev/stdout"` creates a *new open
> file description*, so when stdout is a regular file the child's `O_APPEND`
> writes do not advance the shell's offset and
> `{ lgx run ...; echo after; } > out.txt` ends up with `after` overwriting
> the child's output. Fix (fixup commit): `exec-lg-interactive!` rebinds
> `*out*` / `*err*` only for the streams where `(term/tty? h)` is true
> (`tty-handle?` helper, false on non-file-backed handles). Pipes and files
> keep going through `os/exec*`'s own path, which writes on the inherited
> descriptor. `term/tty?` verified on lg 1.12.2 and 1.13.0; `term` added to
> the clj-kondo namespace exclude list.

### Task 3: Upstream issue note and index

**Files:**
- Create: `docs/issues/exec-star-std-stream-pipes.md`
- Modify: `docs/issues/README.md`
- Modify: `docs/issues/inherit-stdio-runner.md`

- [x] **Step 1: Write the issue note**
  Follow the shape of `docs/issues/nrepl-port-zero.md`: title, `**Repo:**`,
  `**Status:** draft`, `## Summary`, `## Concrete impact`, `## Proposal`.
  Content, with `file:line` links into nooga/let-go at `v1.13.0`:
  - Summary: `os/exec*` (`pkg/rt/os.go`, the `execStar` fn) sets
    `cmd.Stdout = outH.Writer()`. Since #611, the root handles come from
    `newStdStreamHandle` (`pkg/rt/iort.go`) whose writer is
    `stdStreamWriter`, not an `*os.File`, so Go's `os/exec` substitutes a
    pipe. Include the fd table from the Design section and the one-line
    pty reproduction:
    `script -qfec "lg -e '(os/exec* \"sh\" \"-c\" \"ls -l /proc/self/fd/1; test -t 1 && echo tty || echo notty\")'" /dev/null`
  - Concrete impact: `lgx repl` / `lgx nrepl` lose the readline prompt
    (readline's `DefaultIsTerminal` needs stdout or stderr to be a tty);
    TUI programs under `lgx run` see no terminal on stdout.
  - Proposal: in `execStar`, when the resolved handle has `h.File() != nil`
    and its writer is a `stdStreamWriter`, set `cmd.Stdout` to the current
    std-stream file (the `cur()` result, so #611's test swap still works);
    otherwise keep `Writer()`. Same for stderr. Mention the alternative of
    an `IOHandle` method that exposes "file-backed and unrebound".
  - Workaround section: lgx rebinds `*out*` / `*err*` to `/dev/stdout` /
    `/dev/stderr` handles in `runner/exec-lg-interactive!`; remove once
    lgx's minimum lg contains the fix.

- [x] **Step 2: Update the index and the old note**
  Add a row to the upstream table in `docs/issues/README.md`:
  file, subject "`os/exec*` pipes the child's stdout/stderr since #611
  (`stdStreamWriter` is not an `*os.File`), so REPL children lose the tty",
  status `draft, worked around in lgx`. Change the
  `inherit-stdio-runner.md` row and that file's `**Status:**` line to add
  "regressed for stdout/stderr in 1.13.0, see exec-star-std-stream-pipes.md".

- [x] **Step 3: Commit**
  Stage the new file explicitly, then commit:
  `git add docs/issues/exec-star-std-stream-pipes.md docs/issues/README.md docs/issues/inherit-stdio-runner.md`
  `git commit -m "docs(issues): os/exec* pipes stdout/stderr on let-go 1.13.0"`

Scope note: this task produces the local draft note only, matching how the
other `docs/issues/` entries are handled. Filing it on GitHub is a separate
manual step for the maintainer; when filed, add the issue URL to the note's
`**Status:**` line.

### Task 4: Correct the architecture and knowledge-base notes

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/knowledge-base/let-go-gotchas.md`
- Modify: `docs/knowledge-base/let-go-stdlib-quick-ref.md`

- [ ] **Step 1: ARCHITECTURE.md**
  In the paragraph starting "The exec call uses `runner/exec-lg-interactive!`"
  (around line 216), add one or two sentences: on let-go >= 1.13.0 `os/exec*`
  only inherits stdin; the runner rebinds `*out*` / `*err*` to `/dev/stdout`
  / `/dev/stderr` handles so the child keeps the tty, with a link to the new
  issue note.

- [ ] **Step 2: let-go-gotchas.md**
  - In the `os/sh` section, qualify the "inherits the parent's
    stdin/stdout/stderr" claim the same way and link the issue note.
  - Rewrite the "`binding` only works on dynamic Vars" section: `*out*` /
    `*err*` can be rebound with `binding` (verified on lg 1.12.2 and 1.13.0;
    `println`, `write!` and `os/exec*` all follow the binding). Keep whatever
    of the old advice is still true, such as writing to `*err*` via `write!`,
    and drop the false claim.
  - Add `pkg/rt/os.go` (`exec*`) to the `Verify against:` footer if it is
    not already listed.

- [ ] **Step 3: let-go-stdlib-quick-ref.md**
  In the `os` bullet, change the `os/exec*` description to "child inherits
  stdin; stdout/stderr follow `*out*` / `*err*`, which pipe unless rebound to
  a file handle on lg >= 1.13.0 - see gotchas".

- [ ] **Step 4: Commit**
  `git commit -am "docs: exec* stdout/stderr inheritance on let-go 1.13.0"`

### Task 5: Pseudo-terminal verification (manual, Linux)

**Files:** none

Set `LG113` to the lg 1.13.0 binary (`mise which lg` in the repo root) and
run from the repo root. Each command feeds a form after a pause and then EOF.

- [ ] **Step 1: Child descriptors through dev-mode lgx**
  `lgx run` always spawns `$LGX_LG`, so point it at a probe script:
  ```
  cat > /tmp/lgprobe <<'EOF'
  #!/bin/sh
  ls -l /proc/self/fd/1 /proc/self/fd/2; test -t 1 && echo tty1 || echo notty1
  EOF
  chmod +x /tmp/lgprobe
  LGX_LG=/tmp/lgprobe script -qfec "$LG113 lgx.lg repl" /dev/null
  ```
  Expected: fd 1 and fd 2 point at `/dev/pts/N`, output contains `tty1`.
  (lgx's version probe of the fake binary yields nil and is skipped.)

- [ ] **Step 2: REPL prompt through dev-mode lgx**
  Run:
  ```
  LGX_LG=$LG113 script -qfec "$LG113 lgx.lg repl" /dev/null < <(sleep 3; printf '(+ 1 2)\n'; sleep 1; printf '\x04') | cat -A | head
  ```
  Expected: a line containing `user=>` before `3`, and readline redraw
  sequences (`^[[J`) present. Before this change the same command prints
  only the banner and `3`.

- [ ] **Step 3: nREPL variant**
  Same as Step 2 with `nrepl` instead of `repl`.
  Expected: `nREPL server running at tcp://127.0.0.1:<port>` followed by a
  `user=>` prompt. Delete the `.nrepl-port` file it leaves behind.

- [ ] **Step 4: Bundled binary**
  Run `make build`, then repeat Step 2 with `bin/lgx repl` in place of
  `$LG113 lgx.lg repl`.
  Expected: same prompt.

- [ ] **Step 5: Redirected output still lands in the right place**
  The rebinding applies to every invocation, so check the non-tty cases:
  ```
  printf '(println :out) (write! *err* "err\\n")\n' | LGX_LG=$LG113 $LG113 lgx.lg repl > /tmp/o.txt 2> /tmp/e.txt
  cat /tmp/o.txt; echo ---; cat /tmp/e.txt
  printf '(println :both)\n' | LGX_LG=$LG113 $LG113 lgx.lg repl > /tmp/both.txt 2>&1; cat /tmp/both.txt
  ```
  Expected: `:out` in `/tmp/o.txt` and `err` in `/tmp/e.txt` (not swapped,
  not duplicated, file not truncated mid-run); `/tmp/both.txt` holds the
  banner and `:both`. Run each command twice and confirm the second run
  appends nothing unexpected from the first (the shell truncates, lgx opens
  the same file with `O_APPEND`).

- [ ] **Step 6: Full test suite**
  Run: `make test`
  Expected: `All tests passed.`

- [ ] **Step 7: Commit anything left (should be nothing)**
  `git status` should be clean apart from `bin/lgx` if it is untracked.
