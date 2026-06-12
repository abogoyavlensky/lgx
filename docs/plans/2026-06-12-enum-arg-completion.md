# Enum Arg Completion Implementation Plan

> **Status: COMPLETED** (2026-06-12). See summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `lgx __complete` offers a task's `[:enum ...]` values when the cursor sits on that positional arg, so TAB completes enum-typed task args in bash/zsh/fish.

**Tech Stack:** let-go (lgx codebase), existing completion plumbing.

---

## Design

No shell script changes: the bundled bash/zsh/fish scripts already pass
every typed word to the hidden `lgx __complete` endpoint at any cursor
position. Today `candidates` (`lgx/completion.lg`) returns `[]` whenever
the command word is already typed; this feature fills that branch for
exactly one case — a project task arg whose decl `:type` is
`[:enum v1 v2 ...]`.

**`prompt-state`** currently collapses everything after the command into
`:command-typed`. Change it to also report the command and how many
words follow it, e.g. `{:state :command-typed, :command "deploy",
:args-typed 1}` (and plain maps `{:state :command-position}` /
`{:state :awaiting-value}` for the other outcomes). Leading global
flags and `--with <value>` pairs are skipped exactly as today.

**`candidates`** changes signature: the third parameter becomes `tasks`,
a map of task-name string → `:args` decls vector (possibly nil), instead
of a seq of task names. Task names for the command position come from
the map's keys, so that behavior is unchanged. When the command is
typed, return enum values iff:

- the command is a key in `tasks`, and
- a decl exists at index `:args-typed`, and
- its `:type` is a vector (validated as `[:enum ...]` by config).

Result: `(rest type)` prefix-filtered against `cur` and sorted, same as
command candidates. Everything else — built-in commands, `:int`/`:string`
args, positions past the last decl, `cur` starting with `-` — stays `[]`
so the shell falls back to file completion (right for `lgx run <path>`).

**Config plumbing.** Rename `project-task-names` to `project-tasks`,
returning the map (`(str k)` keys, `(:args task)` values) via the same
non-throwing config readers and try/catch, so a broken `lgx.edn` still
never breaks the user's shell. `complete!` passes it through.

**Error handling.** Unchanged: `complete!` keeps its catch-all; the new
lookup code is pure data access on already-validated config.

**Testing.** Unit tests in `test/lgx/completion_test.lg` (existing 20
tests get a mechanical signature update: task-name vectors become maps).
One new e2e assertion in Scenario 111 of `tests/e2e.sh`, which already
exercises `__complete` against a fixture project.

## File Structure

- Modify: `lgx/completion.lg` — `prompt-state` returns command + arg
  count; `candidates` takes a tasks map and offers enum values;
  `project-tasks` plumbing.
- Modify: `test/lgx/completion_test.lg` — new enum cases, signature
  update for existing tests.
- Modify: `tests/e2e.sh` — one enum completion assertion in Scenario 111.
- Modify: `README.md` — one line in "Shell completions" mentioning enum
  arg values.

## Implementation Steps

### Task 1: Enum candidates logic

**Files:**
- Modify: `lgx/completion.lg`
- Test: `test/lgx/completion_test.lg`

- [x] **Step 1: Write/update unit tests**
  New cases: enum values offered for first and second arg positions;
  prefix filtering (`"st"` → `["staging"]`); defaulted enum arg still
  completes; `:int`/`:string` arg offers nothing; position past the
  last decl offers nothing; built-in command (e.g. `run`) offers
  nothing; global flags before the task (`--verbose`, `--with x`)
  don't shift positions; `cur` starting with `-` offers nothing.
  Update existing `candidates` calls: task-name vectors become maps
  (e.g. `["deploy"]` → `{"deploy" nil}`).

- [x] **Step 2: Run unit tests, expect failures**
  Run: `make build && bin/lgx test`
  Expected: new enum tests FAIL (existing ones updated, passing).

- [x] **Step 3: Implement**
  In `lgx/completion.lg`: extend `prompt-state` to return
  `{:state ... :command ... :args-typed ...}`; rework `candidates` per
  Design; rename `project-task-names` → `project-tasks` returning the
  name→decls map; update `complete!` and docstrings (notably the
  module header comment that says "no per-command argument
  completion").

- [x] **Step 4: Run unit tests**
  Run: `bin/lgx test` (rebuild first: `make build`)
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Complete enum values for task typed args"`

### Task 2: E2E assertion and docs

**Files:**
- Modify: `tests/e2e.sh` (Scenario 111)
- Modify: `README.md` ("Shell completions" section)

- [x] **Step 1: Extend Scenario 111**
  In the fixture project used by the scenario, ensure a task with an
  enum-typed arg exists (add one if the fixture lacks it, matching how
  the scenario builds its project), then assert
  `lgx __complete <task> ""` prints the enum values and
  `lgx __complete <task> <prefix>` filters them.

- [x] **Step 2: Add README line**
  In "Shell completions" (~line 490), mention that completion also
  offers declared `[:enum ...]` values for task args. Use
  /writing-clearly.

- [x] **Step 3: Run the full suite**
  Run: `make test`
  Expected: unit + e2e PASS. (Note: shared-fs race — avoid running
  `make test` concurrently from the macOS shell; it clobbers
  `bin/lgx`.)

- [x] **Step 4: Commit**
  `git commit -m "Cover enum arg completion in e2e and docs"`

---

## Completion summary (2026-06-12)

Both tasks done; full suite green (408 unit + 277 e2e). `lgx __complete
<task>` now offers a task arg's `[:enum ...]` values at that arg's
position, prefix-filtered, in bash/zsh/fish.

Implementation matched the plan, plus one security hardening found in
review:

- **Shell-injection guard (codex P1).** Enum values are
  project-controlled arbitrary strings, but completion candidates land
  on the shell command line on TAB. A value like `$(cmd)` or one with
  spaces would be active syntax once accepted, so a malicious `lgx.edn`
  could run code on a stray TAB. Fix: the bash script reads candidates
  straight into `COMPREPLY` (no `compgen -W` wordlist expansion), and —
  the uniform, shell-agnostic guard — `candidates` only offers enum
  values matching `^[A-Za-z0-9._/:=+,@-]+$`. Unsafe values are omitted
  from completion but still validate and run when typed. Covered by a
  regression test (`unsafe-enum-values-omitted`) and noted in the README.

Commits: `54803ec` (logic + unit tests), `8ab7399` (bash COMPREPLY),
`d92c6ad` (shell-safe filter), `9268bd6` (e2e + docs), `d51fde7` (doc
wording).
