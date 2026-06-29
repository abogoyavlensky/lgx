# `lgx nrepl` free-port Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the random port guess in `lgx nrepl` with let-go's `os/free-port`, so the default port is OS-vetted as free instead of a blind pick in the ephemeral range.

**Tech Stack:** let-go (`lg` ≥ 1.11.0), lgx (`.lg` source).

---

## Design

### Approach

`cmd-nrepl` currently defaults the nREPL port to `(+ 49152 (rand-int 16384))` — a random pick in the IANA ephemeral range that may already be taken. let-go 1.11.0 added `os/free-port`, which binds `127.0.0.1:0`, reads the OS-assigned port, and releases the listener. Swap the random pick for `(os/free-port)`. lgx still passes a concrete `-p <port>` to the spawned `lg -n`, so everything downstream (`.nrepl-port`, the startup banner) is unchanged — the number is just OS-vetted now.

This call runs in **lgx's own runtime** (lgx is itself an `lg` program), not the spawned user-project lg. So it depends only on the lg that builds/runs lgx, whose floor is already 1.11.0 (verified: `os/free-port` resolves and returns a port there). The spawned lg needs nothing new.

### Key decisions

- **`os/free-port`, not `-p 0`.** `-p 0` would force lgx to read the bound port back from `.nrepl-port`/lg's output *after* exec'ing an interactive process — awkward plumbing. `os/free-port` keeps the existing "pick a number, pass `-p N`" flow intact.
- **No `rand-int` fallback.** A missing `os/free-port` is a non-catchable compile-time *resolution* error (verified — `try`/`catch` can't intercept it), so graceful degradation for an ancient lg is impossible anyway; and the floor is already 1.11.0. If `os/free-port` throws at runtime (a `net.Listen` failure), the host can't bind sockets and nREPL wouldn't start regardless — crashing honestly beats handing back a random port that also won't bind. So: a direct `(or port (os/free-port))`.
- **No helper extraction / new unit test.** The change is a one-liner inside an untested, exec-only private fn whose result is non-deterministic; a unit test would be weak and the old `rand-int` line wasn't tested either. Verification is a build + a piped-stdin smoke run that exercises the real path.
- **Keep a collision note, reworded.** `os/free-port` is check-then-use, so a rare TOCTOU race can still leave the port taken between the probe and lg's own bind; lg then prints `failed to run nREPL server on port N` and opens the REPL anyway. Far less likely than before, but not impossible.

### Scope notes

- No version gating (floor already 1.11.0), no e2e changes (`nrepl` is interactive and has no e2e coverage today), no template-repo work (a separate deferred follow-up already tracked in `docs/issues/nrepl-port-zero.md`).

## File Structure

| File | Change |
| --- | --- |
| `lgx.lg` | `cmd-nrepl`: swap `(+ 49152 (rand-int 16384))` → `(os/free-port)`; rewrite the comment. Usage row: "random port" → "free port". |
| `lgx/cli.lg` | `parse-nrepl-args` docstring: "caller picks a random port" → "caller picks a free port". |
| `test/lgx/cli_test.lg` | Rename `nrepl-no-args-means-random-port` → `nrepl-no-args-means-auto-port` (assertion unchanged). |
| `README.md` | nrepl table row: "on a random port" → "on a free OS-assigned port". |
| `docs/ARCHITECTURE.md` | `lgx nrepl` section: replace the stale "lgx picks a random port because `-p 0` records 0" rationale; reword the collision note. |
| `docs/issues/nrepl-port-zero.md` | Mark the two deferred lgx follow-ups as landed. |

---

## Task 1: Swap the port default to `os/free-port`

**Files:**
- Modify: `lgx.lg`

- [ ] **Step 1: Replace the port default in `cmd-nrepl`**
  In `cmd-nrepl` (around line 314–318), replace the `port (or port (+ 49152 (rand-int 16384)))` binding and its preceding comment. New binding: `port (or port (os/free-port))`. Rewrite the comment to explain: lgx asks its own runtime (let-go ≥ 1.11.0) for a free port via `os/free-port`, which the OS vets as free, then passes it as the literal `-p <port>` that lg writes to `.nrepl-port`. Note the residual check-then-use race: lg may still print `failed to run nREPL server on port N` on a rare collision and open the REPL without an nREPL; rerunning picks a fresh port.

- [ ] **Step 2: Update the usage row**
  In the `command-rows` string (around line 30), change `(random port unless --port given; auto-applies :dev context if defined)` to `(free port unless --port given; auto-applies :dev context if defined)`.

- [ ] **Step 3: Build the bundle**
  Run: `make build`
  Expected: `built bin/lgx`, no errors. (Confirms `os/free-port` resolves in lgx's runtime lg.)

- [ ] **Step 4: Smoke-test the free-port path**
  Run from the repo root (which has `lgx.edn`), feeding EOF so the REPL exits immediately and cleaning up the artifact:
  `rm -f .nrepl-port; echo '' | bin/lgx nrepl > /tmp/lgx-nrepl-out.txt 2>&1; echo "---"; cat .nrepl-port; echo; grep -i 'nREPL server' /tmp/lgx-nrepl-out.txt; rm -f .nrepl-port`
  Expected: `.nrepl-port` holds a plausible port number, the banner line names that same port, and the output contains no `failed to run nREPL server`.

## Task 2: Update the cli docstring and rename the parse test

**Files:**
- Modify: `lgx/cli.lg`
- Test: `test/lgx/cli_test.lg`

- [ ] **Step 1: Reword the `parse-nrepl-args` docstring**
  In `lgx/cli.lg` (around line 47), change `flag is absent (caller picks a random port).` to `flag is absent (caller picks a free port).` — behavior is unchanged; this only fixes the description.

- [ ] **Step 2: Rename the parse test**
  In `test/lgx/cli_test.lg` (around line 85), rename `nrepl-no-args-means-random-port` to `nrepl-no-args-means-auto-port`. The assertion `(is (= {:port nil} (cli/parse-nrepl-args [])))` stays as-is — `parse-nrepl-args` still returns `{:port nil}`; only port *selection* moved, and that lives in `cmd-nrepl`.

- [ ] **Step 3: Run the unit tests**
  Run: `bin/lgx test`
  Expected: all tests PASS, including the renamed `nrepl-no-args-means-auto-port`.

## Task 3: Refresh the docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/issues/nrepl-port-zero.md`

- [ ] **Step 1: README nrepl row**
  In `README.md` (line ~89), change `Start a REPL with an nREPL server on a random port (or `N`).` to `Start a REPL with an nREPL server on a free OS-assigned port (or `N`).` Keep the `Writes `.nrepl-port`.` clause.

- [ ] **Step 2: ARCHITECTURE `lgx nrepl` section**
  In `docs/ARCHITECTURE.md` (the `### lgx nrepl [--port N]` section, ~lines 205–217): in step 5, replace `No flag → lgx picks a random port in the IANA ephemeral range (49152–65535). lg writes the literal -p value to .nrepl-port, so the random pick must happen in lgx — port 0 (OS-assigned) would record 0.` with a description that lgx, when no `--port` is given, asks its own runtime for a free port via `os/free-port` (let-go ≥ 1.11.0) and passes it as the literal `-p <port>`. In the closing paragraph, change `rerunning picks a fresh random port.` to reflect the OS-vetted port and the residual check-then-use race (rerunning picks a fresh free port). Use the /writing-clearly skill.

- [ ] **Step 3: Close the deferred follow-ups in the issue**
  In `docs/issues/nrepl-port-zero.md`, under "Follow-ups for lgx (deferred)", mark the **Simplify `cmd-nrepl`** and **Refresh stale docs** bullets as done (landed via this change), e.g. retitle the section and note both are resolved. Leave the "Unrelated follow-up: bump the template repos" section untouched — it is still outstanding. Use the /writing-clearly skill.

## Task 4: Full verification and commit

**Files:** none (verification + commit)

- [ ] **Step 1: Run the full test suite**
  Run: `make test`
  Expected: build succeeds, unit tests pass, e2e passes, `All tests passed.`
  (Note: if another shell shares this repo, a concurrent `make test` can clobber `bin/lgx` mid-run — rerun if you hit an `Exec format error`/`SIGBUS`; it is not a regression.)

- [ ] **Step 2: Commit**
  `git commit -am "Use os/free-port for the default lgx nrepl port"`
