# Simplify `lgx run` and Add `lgx repl` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lgx run` clear and heuristic-free — it runs `:main`; put a
script or `lg` flags before `--` and you drive `lg` yourself; program args go
after `--`. Drop the `.lg`/`.cljc`/`.clj` extension-sniffing that today decides
whether `:main` is injected. Add a first-class `lgx repl` that opens lg's
built-in REPL with the project's deps on the source path, restoring plain-REPL
access that a defined `:main` otherwise hides.

**Tech Stack:** let-go (`.lg`), lgx's own test runner (`lgx test`), bash e2e
harness (`tests/e2e.sh`).

---

## Design

### Problem

`lgx run` today fuses two jobs — "run my project's app" and "a thin `lg`
front-end that puts my deps on the path" — and disambiguates them with two
implicit mechanisms in `runner/plan-run-args`:

1. **A `--` separator** whose presence flips whether `:main` is injected.
2. **Extension-sniffing** (`has-script?`/`script-arg?` on `.lg`/`.cljc`/`.clj`)
   that decides, when `--` is present, whether the user already named a script.

The result is behavior a user can't predict from the command they typed:
`lgx run -r` runs no `:main`, but `lgx run -r -- foo` suddenly injects it;
whether `:main` appears depends on a filename suffix. Separately, once `:main`
is defined, there is **no way** to reach lg's plain built-in REPL with the
project's paths — `lgx run` always runs `:main`, and the only REPL is
`lgx nrepl` (which binds a port and writes `.nrepl-port`).

### Solution overview

Two coordinated changes:

**A. A structural, heuristic-free `run` grammar.** Split `forward-args` at the
first `--` into `pre` / `post`. The rule, in one sentence:

> `lgx run` runs `:main`. Put anything before `--` and you're driving `lg`
> yourself — name your own script, `:main` won't be added. Program args go
> after `--`.

Concretely (`pre` = tokens before the first `--`, `post` = tokens after it;
with no `--`, `pre` = all args and `post` = empty):

- `pre` **non-empty** → pass `pre ++ post` through verbatim, **never** inject
  `:main`.
- `pre` **empty** + `:main` set → inject `:main`, then `post` as program args:
  `lg <main> <post>`.
- `pre` empty + no `:main` + `post` non-empty → error (`:needs-main`): args were
  meant for `:main`, but there is none.
- `pre` empty + no `:main` + `post` empty → error (`:no-target`): bare
  `lgx run` with nothing to run — points at `lgx repl` / naming a script.

This deletes `has-script?`, `script-arg?`, and `script-exts` entirely. The
`--` convention itself stays — it matches `cargo run -- args` and
`npm run x -- args`.

**B. A new `lgx repl` command.** Opens lg's built-in REPL (`lg <paths>`, no
`-n`/`-p`) with the project's deps/paths, never touching `:main`. Auto-applies
`:dev` and `:test` (mirrors `lgx nrepl` — the only difference between the two
REPLs is the socket). Takes no arguments of its own; `--with`/`--verbose` are
the usual leading global options. Reserved as a built-in task name.

The command trio becomes coherent: `run` (my app), `repl` (plain REPL),
`nrepl` (networked REPL).

### Forms table (new `run` behavior)

| You type | lgx runs | `:main`? | `*command-line-args*` |
| --- | --- | --- | --- |
| `lgx run` | `lg <paths> <main>` | ✔ injected | `nil` |
| `lgx run -- a b` | `lg <paths> <main> a b` | ✔ injected | `("a" "b")` |
| `lgx run other.lg` | `lg <paths> other.lg` | ✗ | `nil` |
| `lgx run other.lg -- a` | `lg <paths> other.lg a` | ✗ | `("a")` |
| `lgx run other.lg a` | `lg <paths> other.lg a` | ✗ | `("a")` (lg stops at the positional) |
| `lgx run -e '(…)'` | `lg <paths> -e '(…)'` | ✗ | — |
| `lgx run -r -- a` | `lg <paths> -r a` | ✗ | (per lg) |
| `lgx run -- a -- b` | `lg <paths> <main> a -- b` | ✔ | `("a" "--" "b")` |
| `lgx run` *(no `:main`)* | **error** (`:no-target`) → points to `lgx repl` | — | — |
| `lgx run -- a` *(no `:main`)* | **error** (`:needs-main`) | — | — |

### Key decisions

- **Structural rule, no extension-sniffing** (user-agreed): the presence of any
  `pre`-`--` token — not a filename suffix — decides whether `:main` is
  injected. Simpler to state, simpler to implement (net code deletion).
- **`lgx run` no longer opens a REPL.** With no `:main` and empty `pre`, it now
  *errors* and points at `lgx repl`, instead of silently dropping into lg's
  REPL. Now that `repl` exists, a REPL fallback inside `run` is redundant and
  muddies `run`'s identity. **This is a behavior change from today — surfaced
  for veto.**
- **You can no longer run `:main` together with an `lg` flag** in one shot
  (`lgx run -r -- foo` is now `lg -r foo`, no `:main`). Rare; the workaround is
  to name the script (`lgx run -r main.lg -- foo`). Accepted (user-agreed).
- **`lgx repl` auto-applies `:dev` + `:test`** (mirrors `nrepl`), so the two
  REPLs differ only in the socket. `run` stays `:dev`-only. Convention:
  `run` → `:dev`; `repl`/`nrepl` → `:dev` + `:test`; `test` → `:test`;
  `build`/`install` → none.
- **Two distinct error reasons** (`:needs-main` vs `:no-target`) so each gets a
  precise message, rather than one vague catch-all.
- **`drop-arg-separator` is untouched** — task `:run` steps keep their own
  separator handling; only `plan-run-args` (the `lgx run` decision) changes.

### Components touched

1. **`runner/plan-run-args` (`lgx/runner.lg`)** — rewrite to the 4-branch
   structural rule above; delete `has-script?`, `script-arg?`, `script-exts`.
2. **`cmd-run` (`lgx.lg`)** — handle the two error reasons with clear messages
   (the `:no-target` one names `lgx repl`); replace
   `require-main-for-double-dash!`.
3. **`cmd-repl` (new, `lgx.lg`)** — `lg <paths>` REPL, `[:dev :test]` auto
   contexts, rejects positional args.
4. **Dispatch / reservation / completion / help (`lgx.lg`, `lgx/config.lg`,
   `lgx/completion.lg`)** — route `"repl"`, reserve the name, offer it in
   completion, add the help row.
5. **Docs** — README (`run` forms + `repl`), `docs/ARCHITECTURE.md` (`run`
   rules rewrite + `repl` section + layering).

### Error handling

- `lgx run` with no runnable target exits 1 with a message that teaches the
  alternatives (`:main`, an explicit script, or `lgx repl`).
- `lgx repl <anything>` exits 1 (`lgx: repl does not take arguments`), like
  `nrepl`'s arg guard.
- An injected `:main` that doesn't exist still errors via the existing
  `resolve-main-script!` path (unchanged).

### Testing strategy

- **Unit** (`test/lgx/runner_test.lg`): update the two `plan-run-args` tests
  whose expected value changes (`[] nil` → `:no-target`; `["-r" "--" "foo"]
  "main.lg"` → passthrough, no inject), add coverage for the new `:no-target`
  branch and for a lone `pre` flag suppressing `:main`. The unchanged cases stay
  as-is.
- **E2E** (`tests/e2e.sh`): add a `lgx repl` scenario (plain REPL starts, writes
  **no** `.nrepl-port`); update Scenario 33 (`-r -- foo` → no `:main`),
  Scenario 35 (new error message), Scenario 38 + the Scenario 31–38 block
  comment (drop the "suffix skips injection" framing — it's structural now); add
  a scenario for bare `lgx run` with no `:main` erroring and naming `lgx repl`.

## File structure

- Modify: `lgx/runner.lg` — rewrite `plan-run-args`; delete `has-script?`,
  `script-arg?`, `script-exts`.
- Modify: `lgx.lg` — `cmd-run` error handling, new `cmd-repl`, `dispatch` case,
  `command-rows` help rows.
- Modify: `lgx/config.lg` — add `"repl"` to `reserved-task-names`.
- Modify: `lgx/completion.lg` — add `"repl"` to `builtin-commands`.
- Modify: `test/lgx/runner_test.lg` — `plan-run-args` unit tests.
- Modify: `tests/e2e.sh` — repl scenario + run-scenario updates.
- Modify: `README.md` — commands table, options, `run` forms/details, `repl`
  details.
- Modify: `docs/ARCHITECTURE.md` — `run` rules rewrite, `repl` section, layering.

## Tasks

### Task 1: Add `lgx repl` (plain built-in REPL) — purely additive

This task changes no existing behavior, so the full suite stays green.

**Files:**
- Modify: `lgx.lg`, `lgx/config.lg`, `lgx/completion.lg`
- Test: `tests/e2e.sh`
- Docs: `README.md`, `docs/ARCHITECTURE.md`

- [x] **Step 1: Write the failing e2e scenario**
  Append a new scenario (next free number — the file currently ends at
  Scenario 113; use 114) after the last scenario, modeled on Scenario 91
  (`nrepl` without `--port`): tmp project with
  `{:contexts {:dev {} :test {}}}`, pipe `echo ''` to feed stdin EOF, run
  `lgx --verbose repl 2>&1`, and assert:
  - exit 0,
  - output contains `Ctrl-C to quit` (lg's REPL banner),
  - output does **not** contain `nREPL server started` (proves it's the plain
    REPL, not `nrepl`),
  - `$proj/.nrepl-port` was **not** created,
  - output contains `+ auto context :dev` and `+ auto context :test`.
  Clean up tmp dirs.

- [x] **Step 2: Run e2e to confirm it fails**
  Build first: `make build LG="$(mise which lg)"` (see
  `docs/knowledge-base/lgx-dev-workflow.md`). Run `bash tests/e2e.sh`.
  Expected: the new scenario FAILS — `repl` is not yet a command, so
  `lgx repl` errors with `'repl' is not a lgx command`.

- [x] **Step 3: Implement `cmd-repl` and wire it up**
  In `lgx.lg`, add `cmd-repl` next to `cmd-nrepl`, mirroring it but without the
  port logic: reject any positional args
  (`lgx: repl does not take arguments`), `find-project!` → `load-config!` →
  `check-lg-version! :warn` → `with (auto-with! cfg [:dev :test] with verbose?)`
  → `overlay-basis` → `print-installs!` →
  `(runner/exec-lg-interactive! paths resource-paths [] verbose?)`. No `LGX_RUN`
  (like `nrepl`). Add `"repl" (cmd-repl (vec rest-args) verbose? with)` to
  `dispatch`. In `lgx/config.lg`, add `"repl"` to `reserved-task-names`. In
  `lgx/completion.lg`, add `"repl"` to `builtin-commands` (keep the vector
  sorted: `... "nrepl" "repl" "run" ...`).

- [x] **Step 4: Add the help row**
  In `command-rows` (`lgx.lg`), insert a `lgx repl` row between the `run` and
  `nrepl` rows, column-aligned with the rest:
  `  lgx repl                     Start lg's built-in REPL with project deps on the source path`
  plus a continuation line:
  `                               (auto-applies :dev and :test contexts if defined)`.

- [x] **Step 5: Document `repl`**
  - README: add a `lgx repl` row to the command table (after `run`); add `repl`
    to the `--with` and `--verbose` scope lists and to the "find the nearest
    `lgx.edn`" line; add a short `### lgx repl details` note (plain REPL, deps on
    path, auto `:dev`/`:test`, no port/`.nrepl-port` unlike `nrepl`).
  - `docs/ARCHITECTURE.md`: add a `### lgx repl` section between the `run` and
    `nrepl` sections; mention `repl` in the auto-context layering (both
    `:dev`+`:test`, like `nrepl`) and in the `reserved-task-names` note. Use
    /writing-clearly.

- [x] **Step 6: Run the full suite**
  Run: `make test`. Expected: all PASS, including the new repl scenario.
  (Per `docs/knowledge-base/shared-fs-bin-lgx-race`, don't run `make test`
  concurrently from two machines sharing the checkout.)

- [x] **Step 7: Commit**
  `git commit -m "Add lgx repl command for the plain built-in REPL"`

### Task 2: Simplify the `lgx run` grammar (heuristic-free)

**Files:**
- Modify: `lgx/runner.lg`, `lgx.lg`
- Test: `test/lgx/runner_test.lg`, `tests/e2e.sh`
- Docs: `README.md`, `docs/ARCHITECTURE.md`

- [x] **Step 1: Update the unit tests**
  In `test/lgx/runner_test.lg`, adjust `plan-run-args` coverage for the new
  grammar:
  - `plan-run-args-empty-without-main-is-repl-passthrough`: rename/rewrite —
    `([] nil)` now returns `{:error :no-target}`.
  - `plan-run-args-lg-flag-before-separator-stays-before-main`: rewrite —
    `(["-r" "--" "foo"] "main.lg")` now returns
    `{:argv ["-r" "foo"] :inject? false}` (pre-token suppresses `:main`).
  - Add: `(["-r"] "main.lg")` → `{:argv ["-r"] :inject? false}` (lone `pre`
    flag, no inject).
  - Add: `(["--" "foo"] nil)` stays `{:error :needs-main}` (already covered by
    `plan-run-args-double-dash-without-main-errors`; keep it).
  - Leave the unchanged cases (empty+main, `-- args`+main, `-- -v`, second `--`,
    explicit-script cases, no-separator passthrough) as-is.

- [x] **Step 2: Run unit tests to confirm they fail**
  Run: `make build LG="$(mise which lg)" && bin/lgx test test/lgx/runner_test.lg`.
  Expected: FAIL on the rewritten cases (old `plan-run-args` still injects on
  the `-r -- foo` case and returns passthrough for `[] nil`).

- [x] **Step 3: Rewrite `plan-run-args`**
  In `lgx/runner.lg`, replace the body with the 4-branch structural rule:
  split at the first `--` into `pre`/`post`; `(seq pre)` → `{:argv (concat pre
  post) :inject? false}`; else `main-script` → `{:argv (cons main-script post)
  :inject? true}`; else `(seq post)` → `{:error :needs-main}`; else
  `{:error :no-target}`. Update the docstring. Delete `has-script?`,
  `script-arg?`, and `script-exts` (confirm with grep they have no other
  callers). Keep `position` and `drop-arg-separator`.

- [x] **Step 4: Update `cmd-run` error handling**
  In `lgx.lg`, replace `require-main-for-double-dash!` handling: when
  `(:error plan)` is `:needs-main`, print
  `lgx run: -- forwards args to :main, but no :main is set in lgx.edn`;
  when it is `:no-target`, print
  `lgx run: nothing to run — set :main in lgx.edn, run a script (lgx run <script>), or start a REPL (lgx repl)`;
  exit 1 in both cases. Remove the now-unused
  `require-main-for-double-dash!` helper if nothing else references it. The
  `:inject?`/`resolve-main-script!`/exec path is otherwise unchanged. (`cmd-run`
  no longer produces an empty argv, so it never opens a REPL.)

- [x] **Step 5: Run unit tests to confirm they pass**
  Run: `bin/lgx test test/lgx/runner_test.lg` (rebuild if needed).
  Expected: PASS, 0 failures.

- [x] **Step 6: Update the e2e scenarios**
  In `tests/e2e.sh`:
  - Scenario 33 (`-r -- foo`): the trace now reads `-r foo` with **no**
    injected `main.lg`. Rewrite the assertion to expect `-r` followed by `foo`
    and assert the trace does **not** contain `main.lg` (the flag suppresses
    `:main`). Keep the no-TTY-safe `--verbose ... 2>&1 >/dev/null` approach.
  - Scenario 35 (`run -- foo` without `:main`): update the expected error to the
    new `:needs-main` message; assert it contains `no :main is set` (or a stable
    substring of the new text).
  - Scenario 38 + the Scenario 31–38 block comment (~lines 667–673): drop the
    "script suffixes skip `:main` injection" framing. Retitle 38 to reflect that
    **any** explicit token before `--` suppresses `:main` (suffix-independent);
    the existing assertions still hold.
  - Add a new scenario: bare `lgx run` in a project with **no** `:main` exits
    non-zero and its stderr contains `lgx repl` (proves the `:no-target`
    pointer). Guard is not needed (no deps/paths).

- [x] **Step 7: Update the docs**
  - README `### lgx run details`: replace the Forms list and the four-rule prose
    with the new grammar + forms table from this plan's Design; drop the
    extension-sniffing bullet; change the "no `:main` → REPL" line to "no
    `:main` → error, use `lgx repl`". Update the command-table `run` row.
  - `docs/ARCHITECTURE.md` `### lgx run [args...]`: rewrite the `plan-run-args`
    rule list (rules 1–4) to the new structural branches; update the closing
    note that says bare `lgx run` without `:main` "lands in lg's REPL" → it now
    errors and points to `lgx repl`. Use /writing-clearly.

- [x] **Step 8: Run the full suite**
  Run: `make test`. Expected: all PASS (unit + e2e, including the updated run
  scenarios and the Task 1 repl scenario).

- [x] **Step 9: Commit**
  `git commit -m "Simplify lgx run to a heuristic-free :main/-- grammar"`

---

## Completion summary (2026-07-01)

**Status: completed.** Both tasks implemented, full suite green (441 unit tests
/ 597 assertions + 296 e2e assertions), fmt-check and lint clean.

`lgx run` is now heuristic-free — it runs `:main`; any token before `--`
means the user drives `lg` (no `:main` injected); program args go after `--`.
The `.lg`/`.cljc`/`.clj` extension-sniffing (`has-script?`/`script-arg?`/
`script-exts`) is gone. `lgx run` with no runnable target now errors (pointing
at `lgx repl`) instead of opening a REPL. New `lgx repl` opens lg's plain
built-in REPL with deps on the path and auto-applies `:dev`+`:test`.

Commits:

- `ede8a01` — Task 1: `lgx repl` command (cmd-repl, dispatch, reserved name,
  completion, help row, docs, e2e Scenario 114).
- (Task 2 commit) — `plan-run-args` rewrite + `cmd-run` two-reason errors +
  unit-test updates + e2e (33/35/38/89 updated, 35b/35c added) + README/
  ARCHITECTURE.

Deviations / notes:

1. **Reserving `repl`** broke 7 unit tests that used `repl` as an incidental
   fixture/command-list name (5 config tests, 2 completion tests) and one
   README example task named `repl`; all renamed (`repl` → `deploy`/`console`)
   or updated. Not anticipated in the plan.
2. **Scenario numbering:** the repl e2e is 114 (103–113 already existed); the
   run-error e2e are 35b/35c; the old Scenario 89 (bare-`run`-no-`:main` → REPL)
   was repurposed to test `lgx repl` driving an interactive REPL.
3. **Codex review finding (P2), fixed in Task 2:** the no-target error was
   checked *after* `overlay-basis`, so a bare `lgx run` in a project with deps
   fetched them before erroring. `cmd-run` now decides `plan-run-args` and
   errors *before* building the basis (mirroring `cmd-test`); Scenario 35c pins
   the no-fetch behavior via the cache side-effect.
