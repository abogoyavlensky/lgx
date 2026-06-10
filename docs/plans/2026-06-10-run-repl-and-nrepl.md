# Interactive `lgx run` REPL + `lgx nrepl` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lgx run` fully interactive (live REPL when no script/`:main`, streaming output otherwise) and add an `lgx nrepl` command that starts lg's nREPL server on a random or user-chosen port.

**Tech Stack:** let-go (lg 1.10.0+), lgx's own `.lg` sources, bash e2e harness.

---

## Design

### Problem

`lgx run` without a script and without `:main` in `lgx.edn` prints lg's REPL
banner and then hangs: `lgx/runner.lg` shells out via `os/sh`, which buffers
the child's stdout/stderr until exit and gives it no stdin. The TODO at
`lgx/runner.lg:46-50` documents exactly this and asks for an inherited-stdio
runner "once let-go ships one."

let-go 1.10.0 (the version pinned in `.mise.toml`) ships it: `os/exec*`
(`let-go/pkg/rt/os.go`) runs a command with the parent's
stdin/stdout/stderr inherited and returns the child's exit code. Verified
present in the installed binary:
`lg -e '(println (type os/exec*))'` → `let-go.lang.NativeFn`.

lg also has nREPL support: `lg -n` starts an nREPL server (port from
`-p`, default 2137), writes the port to a `.nrepl-port` file in the cwd,
prints `nREPL server started on port N on host 127.0.0.1 - nrepl://127.0.0.1:N`,
and then drops into the terminal REPL in the same process. Note: lg writes
the literal `-p` value to `.nrepl-port`, so a "random port" cannot be
delegated to the OS via port 0 — lgx must pick the number itself.

### Scope decision (approved)

Only `lgx run` and the new `lgx nrepl` switch to inherited stdio.
`lgx test` keeps the captured `os/sh` path (it must inspect lg's output to
strip the harness marker and detect swallowed load errors); `lgx build` and
task `:run` steps also keep current behavior.

### Component 1: runner (`lgx/runner.lg`)

- Extract a private helper from `run-lg!` covering what its body does
  today before the `os/sh` call: set `LG_READ_CLJ=1` and
  `LG_SUPPRESS_SOURCE_PATHS_WARNING=1`, build the argv from
  lib-paths/resource-paths/forward-args, and (when verbose) write the env
  trace line and `+ <bin> <args>` line to `*err*`. It returns `[bin args]`.
  Keep the pure argv assembly (`source-paths-flag` + `resource-paths-flag`
  + forward args concat) as a separate pure function `lg-args` so it is
  unit-testable; the helper composes it with the env/trace side effects.
- `run-lg!` calls the helper then `(apply os/sh bin args)` — captured
  behavior byte-identical; its docstring and callers unchanged.
- New public `exec-lg-interactive!`: calls the same helper, then
  `(apply os/exec* bin args)`, then `(os/exit code)`. Docstring states the
  child inherits stdin/stdout/stderr and the function never returns.
- Delete the resolved TODO block at `lgx/runner.lg:46-50`.

The two existing comments above `run-lg!` about `LG_READ_CLJ` and the
source-paths warning move into (or stay attached to) the extracted helper,
since that is where the `os/setenv` calls land.

### Component 2: `cmd-run` (`lgx.lg`)

One-line change: `runner/exec-lg!` → `runner/exec-lg-interactive!`. All
arg logic (`:main` resolution, `--` injection, `LGX_RUN=1`, install
printing) stays as is. Net effect:

- `lgx run script.lg` streams output live and the script can read stdin.
- `lgx run` with no args and no `:main` lands in lg's real REPL.
- `lgx run -r script.lg` (lg's script-then-REPL mode) now works.

`runner/exec-lg!` keeps its current `invoke-lg!`-based definition; after
this change nothing in `lgx.lg` calls it, so fold it away if it has no
remaining callers (check `lgx/tasks.lg` first — task `:run` steps use the
runner too and must keep captured behavior).

### Component 3: `lgx nrepl` (`lgx.lg` + `lgx/cli.lg`)

- `lgx/cli.lg`: pure `parse-nrepl-args` taking the command's rest-args,
  returning `{:port <int-or-nil>}`. `--port <n>` must be an integer in
  1–65535; throw `ex-info` with message
  `lgx: --port requires an integer port between 1 and 65535` on a missing
  value, non-integer, or out-of-range value, and
  `lgx: nrepl does not take arguments other than --port <n>` on any other
  token. No flag → `{:port nil}` (caller picks random).
- `lgx.lg`: `cmd-nrepl`, shaped like `cmd-run`:
  1. Parse rest-args with `cli/parse-nrepl-args`; on `ex-info`, print the
     message to `*err*` and exit 1 (same pattern as `main`'s
     `parse-leading-flags` catch).
  2. `config/find-project!` → `overlay-basis project with nil` (so
     `--with` contexts apply) → `print-installs!`.
  3. Port: the parsed value, else `(+ 49152 (rand-int 16384))` (IANA
     ephemeral range; `rand-int` verified in lg 1.10.0).
  4. `runner/exec-lg-interactive!` with forward args `["-n" "-p" (str port)]`.
  Do **not** set `LGX_RUN=1` — that env var advertises script-arg handling
  to a spawned program, which doesn't apply to a REPL.
- `dispatch`: add `"nrepl"` → `cmd-nrepl` (before the task fallback, like
  the other built-ins).
- Help: add a row to `command-rows` after the `run` rows, hand-aligned to
  `doc-col` (31): `lgx nrepl [--port N]` — "Start a REPL with an nREPL
  server (random port unless --port given)".

### Error handling

- All `--port` parse failures: `lgx: ...` line on stderr, exit 1.
- Port collision: lg prints `failed to run nREPL server on port N` and
  still enters the terminal REPL. Accepted — rerunning picks a new random
  port; no retry loop (YAGNI).
- Everything else (REPL errors, Ctrl-C) is lg's own behavior;
  `exec-lg-interactive!` propagates lg's exit code.

### Testing strategy

- Unit (`test/lgx/runner_test.lg`): `lg-args` builds the expected argv
  from lib-paths/resource-paths/forward-args (and omits flags for empty
  path lists).
- Unit (`test/lgx/cli_test.lg`): `parse-nrepl-args` — no args → nil port;
  `--port 7888` → 7888; missing value / non-integer / out-of-range /
  unexpected extra token → throws.
- e2e (`tests/e2e.sh`), following the existing scenario pattern:
  1. In a fixture without `:main`, `echo '(println (+ 1 2))' | lgx run`
     → exit 0, output contains `3` (inherited stdin is the pipe; lg's
     REPL exits on EOF).
  2. `echo '' | lgx nrepl --port <fixed free port>` → output contains
     `nREPL server started on port <port>`, `.nrepl-port` contains the
     port. Remove `.nrepl-port` afterwards (lg only cleans it up on
     graceful server stop).
  3. `echo '' | lgx nrepl` → output matches `nREPL server started on port`
     (random port, so match the prefix only). Remove `.nrepl-port`.
  4. `lgx nrepl --port abc` → exit 1, stderr contains
     `--port requires an integer`.
- Run the full suite (`make test`); existing `lgx run` scenarios capture
  combined output, which inherited stdio still satisfies, but ordering of
  stdout vs stderr interleaving changes — fix any ordering-sensitive
  assertions that surface.

### Docs (same-PR, per AGENTS.md)

- `README.md`: add `nrepl` to the command list; note the `lgx run` REPL
  fallback; check off the roadmap item `[ ] lgx repl - run repl` (delivered
  as the `lgx run` REPL fallback + `lgx nrepl`).
- `docs/ARCHITECTURE.md`: the `lgx run` section's buffering caveat
  (~lines 165–169, referencing `issues/inherit-stdio-runner.md`) is stale
  after this change — rewrite it around `os/exec*`; add an `lgx nrepl`
  subcommand section parallel to `lgx run`'s.
- `docs/issues/inherit-stdio-runner.md`: status `draft` → resolved;
  note let-go shipped `os/exec*` in 1.10.0.
- `docs/knowledge-base/let-go-stdlib-quick-ref.md`: the Process line lists
  `os/sh` (buffered) and `os/exec` but not `os/exec*` — add it.
- `docs/knowledge-base/let-go-gotchas.md` and
  `docs/knowledge-base/lgx-dev-workflow.md`: spot-check their `Verify
  against:` claims about `os/sh` buffering / `exec-lg!` and fix any that
  go stale (the dev-workflow footer names `exec-lg!`).

## File Structure

- Modify: `lgx/runner.lg` — extracted invocation helper, pure `lg-args`,
  new `exec-lg-interactive!`, TODO removal.
- Modify: `lgx.lg` — `cmd-run` switch, `cmd-nrepl`, dispatch entry, help
  row, version bump.
- Modify: `lgx/cli.lg` — `parse-nrepl-args`.
- Test: `test/lgx/runner_test.lg`, `test/lgx/cli_test.lg`.
- Test: `tests/e2e.sh` — four new scenarios.
- Docs: `README.md`, `docs/ARCHITECTURE.md`,
  `docs/issues/inherit-stdio-runner.md`,
  `docs/knowledge-base/let-go-stdlib-quick-ref.md` (+ gotchas/dev-workflow
  spot-checks).

Dev-mode commands run from the project root (`lg lgx.lg <cmd>`, see
`docs/knowledge-base/lgx-dev-workflow.md`); the e2e suite drives the built
`bin/lgx` via `make test`.

---

### Task 1: Runner — pure `lg-args` + `exec-lg-interactive!`

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [ ] **Step 1: Write the failing tests**
  In `test/lgx/runner_test.lg`, add deftests for a public pure
  `runner/lg-args`: (a) lib-paths + resource-paths + forward args →
  `["-source-paths" "<joined>" "-resource-paths" "<joined>" & forward]`,
  joined with `os/path-separator`; (b) empty lib-paths and empty
  resource-paths → just the forward args; (c) empty everything → `[]`.

- [ ] **Step 2: Run tests to verify they fail**
  Run from the project root: `lg lgx.lg test test/lgx/runner_test.lg`
  Expected: FAIL (`lg-args` unresolved).

- [ ] **Step 3: Implement**
  In `lgx/runner.lg`: add pure `lg-args` composing `source-paths-flag`,
  `resource-paths-flag`, and forward args. Extract the env-setting +
  verbose-trace + argv assembly from `run-lg!` into a private helper
  returning `[bin args]` (move the `LG_READ_CLJ` / source-paths-warning
  comments with their `os/setenv` calls). Rewrite `run-lg!` as
  helper + `(apply os/sh bin args)`. Add `exec-lg-interactive!` as
  helper + `(apply os/exec* bin args)` + `(os/exit code)`; docstring says
  the child inherits stdin/stdout/stderr and the function never returns.
  Delete the resolved TODO block (current lines 46–50).

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/runner_test.lg`
  Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**
  `git commit -m "Add inherited-stdio runner via os/exec*"`

### Task 2: Switch `lgx run` to inherited stdio

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh`

- [ ] **Step 1: Add the failing e2e scenario**
  In `tests/e2e.sh`, following the existing scenario pattern: in a fixture
  project without `:main`, run `echo '(println (+ 1 2))' | bin/lgx run`;
  assert exit 0 and output contains `3`.

- [ ] **Step 2: Run the scenario to verify it fails**
  Run: `make test` (or rebuild then `bash tests/e2e.sh`)
  Expected: the new scenario FAILs (REPL gets no stdin under `os/sh`).

- [ ] **Step 3: Implement**
  In `cmd-run`, replace `runner/exec-lg!` with
  `runner/exec-lg-interactive!`. If `runner/exec-lg!` now has no callers
  (check `lgx/tasks.lg`), delete it and its mention in the
  `lgx-dev-workflow.md` footer.

- [ ] **Step 4: Run the full suite**
  Run: `make test`
  Expected: PASS, including the new scenario. Fix any existing `lgx run`
  assertions that depended on replayed (post-exit) output ordering.

- [ ] **Step 5: Commit**
  `git commit -m "Make lgx run interactive (REPL + streaming output)"`

### Task 3: `parse-nrepl-args` in `lgx.cli`

**Files:**
- Modify: `lgx/cli.lg`
- Test: `test/lgx/cli_test.lg`

- [ ] **Step 1: Write the failing tests**
  deftests: no args → `{:port nil}`; `["--port" "7888"]` → `{:port 7888}`;
  throws on `["--port"]`, `["--port" "abc"]`, `["--port" "0"]`,
  `["--port" "70000"]`, and `["extra"]` (use the existing `threw?` helper).

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/cli_test.lg`
  Expected: FAIL (`parse-nrepl-args` unresolved).

- [ ] **Step 3: Implement**
  `parse-nrepl-args` per the design: `{:port <int-or-nil>}`, ex-info
  messages `lgx: --port requires an integer port between 1 and 65535` and
  `lgx: nrepl does not take arguments other than --port <n>`.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/cli_test.lg`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -m "Add nrepl arg parsing to lgx.cli"`

### Task 4: `lgx nrepl` command

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh`

- [ ] **Step 1: Add the failing e2e scenarios**
  Scenarios 2–4 from the testing strategy: fixed `--port` (assert the
  `nREPL server started on port <port>` line and `.nrepl-port` content,
  then remove the file), bare `lgx nrepl` (assert the
  `nREPL server started on port` prefix, remove the file), and
  `--port abc` (exit 1, stderr contains `--port requires an integer`).
  Pipe empty stdin so the REPL exits on EOF. For the fixed-port scenario,
  pick a high uncommon port and note in the scenario comment that a
  collision makes lg degrade to `failed to run nREPL server` with exit 0,
  which is what the started-on-port assertion guards against.

- [ ] **Step 2: Run to verify they fail**
  Run: `make test`
  Expected: new scenarios FAIL (`nrepl` is not a lgx command).

- [ ] **Step 3: Implement**
  `cmd-nrepl` per the design (parse → basis with `--with` → installs →
  random-or-given port → `exec-lg-interactive!` with
  `["-n" "-p" (str port)]`; no `LGX_RUN`). Add the `"nrepl"` dispatch case
  and the `command-rows` help row aligned to `doc-col`.

- [ ] **Step 4: Run the full suite**
  Run: `make test`
  Expected: PASS. Also check `help lists run`-style assertions still pass
  with the new row.

- [ ] **Step 5: Commit**
  `git commit -m "Add lgx nrepl command"`

### Task 5: Docs sync + version bump

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`,
  `docs/issues/inherit-stdio-runner.md`,
  `docs/knowledge-base/let-go-stdlib-quick-ref.md`, `lgx.lg`
- Spot-check: `docs/knowledge-base/let-go-gotchas.md`,
  `docs/knowledge-base/lgx-dev-workflow.md`

- [ ] **Step 1: Update docs**
  Apply the docs section of the design: README command list + REPL note +
  roadmap checkbox; ARCHITECTURE `lgx run` buffering caveat rewrite +
  `lgx nrepl` section; inherit-stdio issue marked resolved (shipped as
  `os/exec*` in let-go 1.10.0); quick-ref Process line gains `os/exec*`;
  spot-check the two knowledge-base footers for newly stale claims.

- [ ] **Step 2: Bump version**
  In `lgx.lg`, bump `version` to `0.1.0-alpha14` (repo convention: bump
  after a feature lands).

- [ ] **Step 3: Run the full suite**
  Run: `make test`
  Expected: PASS (the test harness embeds `version`; e2e asserts on
  `lgx version` output if covered).

- [ ] **Step 4: Commit**
  `git commit -m "Sync docs for interactive run and lgx nrepl; bump version"`
