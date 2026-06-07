# Styled Command Output Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print a short, colored status header before every built-in command (green) and custom project task (purple), so users get an immediate, satisfying "here's what I'm doing" signal — modeled on Cargo's build output.

**Tech Stack:** let-go (lgx source), 256-color ANSI escapes, bash e2e harness.

---

## Design

### Overview

lgx commands currently start their real work with no preamble. This adds a
one-line status header before each command and, for custom tasks, an indented
`$` line per step echoing the command about to run.

Two colors carry meaning:

- **Green** (`=> ...`) — built-in commands (`install`, `run`, `build`, `test`,
  `new`). The user is running lgx itself.
- **Purple** (`=> Running task <name>...`) — custom project tasks declared in
  `lgx.edn :tasks`. The user is running their own automation.

`version` and `help` get no header: they emit data the user asked for, not an
action.

### Streams

All new decoration (headers and `$` step lines) goes to **stderr**. This keeps
stdout clean: `lgx run | jq` sees only the script's output, matching Cargo
(`cargo run`'s status → stderr, program → stdout) and the existing `--verbose`
traces. The existing stdout lines are untouched and stay on stdout: the install
block (`installing N dep(s)...` / `lib -> path` / `done`), `built <abs-out>`,
`Created <name> at <abs>`, the test report, and version/help text.

### Color gating

let-go has no TTY detection (no `isatty`), so color cannot be auto-disabled when
piped. The only gate is the `LGX_NO_COLOR` env var, named with the project's
`LGX_` prefix (cf. `LGX_HOME`, `LGX_LG`, `LGX_RUN`). Color is disabled when
`LGX_NO_COLOR` is present and non-empty; otherwise color is emitted (the same
unconditional-color baseline the test harness already uses).

### Components

A new namespace `lgx.style` owns all color and header formatting. It is pure
(returns strings; no I/O), so callers `write!` the result to `*err*`. This
matches the repo convention that every `lgx/*.lg` helper is unit-testable.

```clojure
(ns lgx.style (:require [string :as str]))

(defn- color-enabled? [] (str/blank? (os/getenv "LGX_NO_COLOR")))
(defn- colorize [code s]
  (if (color-enabled?) (str "\u001b[38;5;" code "m" s "\u001b[0m") s))

(defn green  [s] (colorize 2 s))   ; built-ins (matches test harness green)
(defn purple [s] (colorize 5 s))   ; custom tasks

(defn header      [text] (green  (str "=> " text)))
(defn task-header [name] (purple (str "=> Running task " name "...")))
(defn step-line   [cmd]  (str "   " (purple "$") " " cmd))
```

Color codes use the 256-color base palette (`2` = green, `5` = magenta/purple),
so they respect the user's terminal theme — consistent with the test harness,
which already uses base code `2` for green and `1` for red.

The **test harness keeps its own inline color helpers** (`lgx/test_runner.lg`).
It is a generated `.lg` that runs under the *user's* `lg` runtime with only
`test`/`string`/`os` required, so it cannot `require` an lgx namespace.
`lgx.style` is for lgx's own bundled runtime only; unifying the two color
code-paths is out of scope (YAGNI).

### Per-command headers (all to stderr)

Each header prints **after** the command's inputs/preconditions are known but
**before** the real work, so a command that fails a precondition shows the clean
error rather than a misleading header.

| Command | Header (green) | When |
|---|---|---|
| `install` | `=> Installing dependencies...` | after project found |
| `run` | `=> Running <script>...` | after argv resolved; `<script>` = first script-arg token in the outgoing argv (explicit script or injected `:main`); falls back to `=> Running...` when there is none (`-e`, `-r`) |
| `build` | `=> Building <out>...` | after `:main`/`:targets` validation; `<out>` = the configured `:out` (relative, as written in `lgx.edn`) |
| `test` | `=> Running tests in <header>...` | after test discovery; `<header>` = `test/` (walk) or the file path (single-file) |
| `new` | `=> Creating project <name>...` | after name + target validation, before clone |

### `test` de-duplication

Today the generated harness prints a plain `Running tests in <header>...` to
**stdout**. To avoid a duplicate and give `test` the same green stderr header as
every other command:

- lgx prints the green `=> Running tests in <header>...` to **stderr** (lgx owns
  the header).
- The harness drops its own `Running tests in...` line and the following blank
  `(println)`. `harness-source` loses its now-unused `header` parameter and the
  `__TEST_HEADER__` substitution; `write-harness!` stops threading `header`.
- `cmd-test` still computes `header` for its own green stderr line; it just no
  longer passes it to `write-harness!`.

No e2e scenario asserts the harness's `Running tests in` line, so scenarios
39/40 keep passing. Three unit tests in `test/lgx/test_runner_test.lg` change
(see Task 3).

### Custom task output (purple)

`lgx/tasks.lg` owns all task decoration (requires `lgx.style`). The task **name**
is threaded from `dispatch` through `cmd-task` into `run-task!` (today only the
task *map* reaches `cmd-task`).

- `run-task!` writes the purple header `=> Running task <name>...` to `*err*`
  once at the top.
- Before each step runs, it writes the indented `$` line to `*err*`:
  - `:sh` → `   $ <cmd>` (`<cmd>` = value as-is; vectors joined with spaces — the
    same string `run-sh-step!` already builds).
  - `:run` → `   $ lgx run <args>` (`<args>` = the `:run` value as-is, joined).
- The step's child output is replayed exactly as today (child stdout → stdout,
  child stderr → stderr).
- `--verbose` keeps its low-level traces (`+ sh -c ...`, `+ env ...`,
  `+ lg ...`). The `$` line is the always-on friendly view; verbose adds the
  exact-spawn detail.

Example, `lgx ci`:

```
=> Running task ci...        ← purple, stderr
   $ cljfmt check            ← stderr
<cljfmt's own output>
   $ lgx run main.lg --check ← stderr
<script output>
```

### Error handling

Headers and step lines are pure additive `write!`s to `*err*`. They never touch
control flow or exit codes — a task's first non-zero step still stops the chain
and sets the exit code as today. A step's `$` line prints *before* it runs, so a
failure shows which command failed. `LGX_NO_COLOR` non-empty degrades every
header/step line to plain text. No new failure modes.

### Testing strategy

- **Unit:** new `test/lgx/style_test.lg` covers `green`/`purple` wrapping,
  `LGX_NO_COLOR` disabling (set + restore in-test), and the three header
  builders. `test/lgx/test_runner_test.lg` updates for the dropped `header`
  param.
- **e2e** (`tests/e2e.sh`): color stays ON globally because scenarios 39/40
  assert raw ANSI summary codes. New header/task scenarios set
  `LGX_NO_COLOR=1` per-scenario for deterministic plain-text assertions on
  **stderr**, plus one scenario *without* `LGX_NO_COLOR` to prove the header is
  colored.
- **No existing scenario needs changing for the decoration itself.** Every
  current `assert_eq` scenario (install/run/build/task happy paths) captures
  **stdout only**, and all new decoration is on stderr — so those exact-equality
  assertions still hold untouched. The `2>&1` scenarios use `assert_contains`/
  `assert_not_contains`, which tolerate the extra stderr line. The e2e work is
  therefore purely *additive*; do not "fix" passing assertions.
- **Gate:** `make build` → `bash tests/run.sh` (unit) → `bash tests/e2e.sh` all
  green.

## File Structure

| File | Responsibility |
|---|---|
| `lgx/style.lg` | **new** — color helpers (`LGX_NO_COLOR`) + header builders. Pure. |
| `test/lgx/style_test.lg` | **new** — unit tests for `lgx.style`. |
| `lgx.lg` (`lgx.main`) | require `lgx.style`; print green header in `cmd-install`/`cmd-run`/`cmd-build`/`cmd-test`; thread task name into `cmd-task`; drop `header` arg to `write-harness!`. |
| `lgx/tasks.lg` | require `lgx.style`; `run-task!` prints purple header + `$` step lines; accept `task-name`. |
| `lgx/new.lg` | require `lgx.style`; print `=> Creating project <name>...` after validation. |
| `lgx/test_runner.lg` | drop the harness `Running tests in...` line + the `header` param from `harness-source`/`write-harness!`. |
| `test/lgx/test_runner_test.lg` | update three header-related tests for the dropped param. |
| `tests/e2e.sh` | add stderr-header / clean-stdout / colored-header assertions. |
| `docs/ARCHITECTURE.md` | document styled output, streams, color gating, and the `test` header relocation. |
| `README.md` | note styled output + `LGX_NO_COLOR` in the env-vars section. |

---

## Task 1: `lgx.style` module

**Files:**
- Create: `lgx/style.lg`
- Test: `test/lgx/style_test.lg`

- [x] **Step 1: Write the failing test**
  In `test/lgx/style_test.lg`, require `lgx.style` and `string`. Test:
  `green`/`purple` wrap input as `\u001b[38;5;2m<s>\u001b[0m` /
  `\u001b[38;5;5m<s>\u001b[0m` when `LGX_NO_COLOR` is unset; both return the bare
  input (no `\u001b`) when `LGX_NO_COLOR` is set to `"1"` (set with `os/setenv`,
  restore to `""` after each case so other tests are unaffected). `header`
  returns a string containing `=> hello` for input `"hello"`; `task-header`
  returns a string containing `=> Running task ci...` for `"ci"`; `step-line`
  returns a string containing `   ` (3-space indent), a `$`, and the command
  text for input `"echo hi"`.

- [x] **Step 2: Run test to verify it fails**
  Run: `bash tests/run.sh`
  Expected: FAIL — `lgx.style` namespace not found / vars unresolved.

- [x] **Step 3: Write minimal implementation**
  Create `lgx/style.lg` per the Design "Components" snippet: `color-enabled?`
  reads `LGX_NO_COLOR` via `os/getenv` (disabled when present and non-empty;
  `str/blank?` of the value means enabled), `colorize`, `green` (code 2),
  `purple` (code 5), `header`, `task-header`, `step-line`.

- [x] **Step 4: Run test to verify it passes**
  Run: `bash tests/run.sh`
  Expected: PASS, including the new `lgx.style` tests.

- [x] **Step 5: Commit**
  `git commit -m "Add lgx.style color and header helpers"`

---

## Task 2: Built-in headers for install / run / build

**Files:**
- Modify: `lgx.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Wire the headers**
  In `lgx.lg`, add `[lgx.style :as style]` to the `ns` require. Then:
  - `cmd-install`: after `(config/find-project!)`, write
    `(style/header "Installing dependencies...")` + newline to `*err*`.
  - `cmd-run`: after computing the outgoing `args`, derive the script label as
    the first element of `args` satisfying `script-arg?`; write
    `=> Running <script>...` (or `=> Running...` when none) to `*err*` before
    `runner/exec-lg!`.
  - `cmd-build`: after the `:main`/`:bin` validation and `resolve-main-script!`,
    write `=> Building <out>...` (using `(:out bin)`) to `*err*` before
    `print-installs!`/`invoke-lg!`.

- [x] **Step 2: Add e2e assertions**
  In `tests/e2e.sh` add scenarios (use the next free scenario numbers):
  - A `run` scenario with `LGX_NO_COLOR=1`, capturing stderr separately
    (`2>err.txt`), asserting stderr contains `=> Running ` and stdout has no
    `=>`.
  - A `build` scenario with `LGX_NO_COLOR=1` asserting stderr contains
    `=> Building `.
  - An `install` scenario with `LGX_NO_COLOR=1` asserting stderr contains
    `=> Installing dependencies...`.
  - One scenario *without* `LGX_NO_COLOR` asserting stderr contains the colored
    header prefix `$'\e[38;5;2m=>'`.

- [x] **Step 3: Build and run e2e**
  Run: `make build && bash tests/e2e.sh`
  Expected: all scenarios PASS (existing + new).

- [x] **Step 4: Commit**
  `git commit -m "Print green status header for install/run/build"`

---

## Task 3: `test` header relocation

**Files:**
- Modify: `lgx/test_runner.lg`
- Modify: `lgx.lg`
- Modify: `test/lgx/test_runner_test.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Update the harness unit tests first**
  In `test/lgx/test_runner_test.lg`:
  - Change the `harness-source` calls in `harness-source-empty-ns-list-parses`,
    `harness-source-includes-each-ns`, `harness-source-emits-ready-marker`, and
    `harness-source-summary-and-exit` to the single-arg form `(tr/harness-source
    <entries>)`.
  - Remove `harness-source-uses-provided-header` and
    `harness-source-escapes-special-header-chars` (header no longer lives in the
    harness). Add one test `harness-source-omits-running-tests-banner` asserting
    `(not (str/includes? src "Running tests in"))`.

- [x] **Step 2: Run unit tests to verify they fail**
  Run: `bash tests/run.sh`
  Expected: FAIL — `harness-source` still takes two args / still emits the
  banner.

- [x] **Step 3: Update the harness and cmd-test**
  - `lgx/test_runner.lg`: drop the `header` param from `harness-source` and
    `write-harness!`; remove the `__TEST_HEADER__` substitution; remove the
    `(println (str "Running tests in " __TEST_HEADER__ "..."))` line and the
    `(println)` blank line that followed it in `harness-body`. Update the
    `harness-source` docstring.
  - `lgx.lg` `cmd-test`: write `(style/header (str "Running tests in " header
    "..."))` + newline to `*err*` before `print-installs!`; change the
    `write-harness!` call to `(test-runner/write-harness! entries version)`.

- [x] **Step 4: Run unit tests to verify they pass**
  Run: `bash tests/run.sh`
  Expected: PASS.

- [x] **Step 5: Add/adjust e2e and run**
  In `tests/e2e.sh`, extend the `test` happy-path scenario (39) to capture
  stderr and assert it contains `=> Running tests in test/` (color is ON there,
  but the needle is a contiguous substring inside the green wrap, so it matches).
  Run: `make build && bash tests/e2e.sh`
  Expected: all PASS, including 39/40.

- [x] **Step 6: Commit**
  `git commit -m "Move the test banner to a green lgx header on stderr"`

---

## Task 4: `new` header

**Files:**
- Modify: `lgx/new.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Wire the header**
  In `lgx/new.lg`, add `[lgx.style :as style]` to the require. In `cmd-new!`,
  after `validate-target!` succeeds and before `resolve-template-coord`/
  `ensure-template!`, write `(style/header (str "Creating project " name
  "..."))` + newline to `*err*`.

- [x] **Step 2: Add e2e assertion**
  `new` is already e2e-tested hermetically via the template fixture repo
  (scenarios 50/51, which capture `2>&1`). Extend scenario 50 to assert the
  combined output contains `=> Creating project my-app...`. Color is ON there,
  but the needle is a contiguous substring inside the green wrap, so it matches.
  The existing `Created my-app at` assertion (stdout) is unchanged.

- [x] **Step 3: Build and run e2e**
  Run: `make build && bash tests/e2e.sh`
  Expected: all PASS.

- [x] **Step 4: Commit**
  `git commit -m "Print green status header for new"`

---

## Task 5: Custom task output

**Files:**
- Modify: `lgx/tasks.lg`
- Modify: `lgx.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Thread the task name and print decoration**
  - `lgx.lg`: in `dispatch`, the task branch already has `cmd` (the task name).
    Pass it: `(cmd-task cmd task verbose? with)`. Update `cmd-task` to accept
    `task-name` and pass it to `tasks/run-task!`.
  - `lgx/tasks.lg`: add `[lgx.style :as style]` to the require. `run-task!`
    accepts `task-name` as its first param; write
    `(style/task-header task-name)` + newline to `*err*` before the step loop.
    In `run-sh-step!`, before `os/sh`, write `(style/step-line cmd)` + newline to
    `*err*`. In `run-run-step!`, before `invoke-lg!`, write
    `(style/step-line (str "lgx run " (as-string value)))` + newline to `*err*`.
    (`run-run-step!` will need the raw `value` to format; pass it through or
    compute the string in `run-step!` and hand it down.)

- [x] **Step 2: Add e2e assertions**
  In `tests/e2e.sh`, add a task scenario with `LGX_NO_COLOR=1` capturing stderr,
  asserting stderr contains `=> Running task <name>...` and `   $ <cmd>`, and
  asserting the task's stdout is unchanged (the existing `assert_eq` on stdout
  still holds — decoration is on stderr). Add a `:run`-step task scenario
  asserting stderr contains `   $ lgx run `.

- [x] **Step 3: Build and run e2e**
  Run: `make build && bash tests/e2e.sh`
  Expected: all PASS, including unchanged scenarios 13–15.

- [x] **Step 4: Commit**
  `git commit -m "Print purple task header and per-step command lines"`

---

## Task 6: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md`

- [x] **Step 1: Update ARCHITECTURE.md**
  Add a short "Output styling" subsection (or fold into the relevant data-flow
  sections): green headers for built-ins and purple `=> Running task <name>...`
  for tasks, all on stderr; stdout reserved for program/data output; color gated
  by `LGX_NO_COLOR` (no TTY detection in let-go); the `lgx.style` component;
  the `test` banner now coming from lgx (stderr), not the harness. Update the
  Components list to include `lgx/style.lg`. Update the `lgx test` data-flow note
  that previously described the harness banner.

- [x] **Step 2: Update README.md**
  Add `LGX_NO_COLOR` to the environment-variables section with a one-line
  description (set to disable colored output). Mention the styled headers if the
  README documents command output. Use the /writing-clearly skill.

- [x] **Step 3: Commit**
  `git commit -m "Document styled command output and LGX_NO_COLOR"`

---

## Done criteria

- `make build && bash tests/run.sh && bash tests/e2e.sh` all green.
- `lgx install`/`run`/`build`/`test`/`new` each print a green `=> ...` header to
  stderr; `version`/`help` print none.
- `lgx <task>` prints a purple `=> Running task <name>...` header and a `   $ ...`
  line per step to stderr; step output and exit-code semantics unchanged.
- stdout for every command is free of headers (`lgx run | jq` works).
- `LGX_NO_COLOR=1` disables all color.
- Docs updated in the same PR (AGENTS.md same-PR doc rule).

---

## Implementation summary

**Status:** Complete. All six tasks implemented, tested, and committed on
branch `rework-cmd-output-title`.

**What shipped (as designed):**
- `lgx/style.lg` — pure color + header builders, color gated by `LGX_NO_COLOR`
  (green = 256-color `2`, purple = `5`). Unit-tested in `test/lgx/style_test.lg`.
- Green `=> ...` headers on **stderr** for `install`/`run`/`build`/`test`/`new`;
  `version`/`help` unchanged.
- Purple `=> Running task <name>...` header + indented `$ <cmd>` step lines on
  stderr for custom tasks; `:run` steps shown as `lgx run <args>`.
- `test` banner relocated from the harness (stdout) to lgx's green header
  (stderr); `harness-source`/`write-harness!` lost the `header` param.
- Docs: ARCHITECTURE.md (new "Output styling" section, `lgx/style.lg` in
  Components, banner note) and README.md (`LGX_NO_COLOR` row).

**Results:** 267 unit tests, 193 e2e assertions — all green
(`make build && bash tests/run.sh`). Codex second-opinion review: no issues.

**Issues encountered / deviations:**
- **ANSI bytes in source:** the editor/JSON path mangled raw ESC; resolved by
  using `\u001b` escape sequences (let-go's reader decodes them, as the test
  harness already relies on).
- **e2e scenario 60** (`run -e` for `LG_READ_CLJ`) captured `2>&1` and asserted
  on the *first line* — the new run header pushed it down. Fixed by capturing
  child stdout only (`2>/dev/null`). This was the only existing scenario the
  decoration affected; all other `assert_eq` scenarios are stdout-only and were
  untouched, as the plan predicted.
- **TDD catch:** `write-harness-uses-versioned-stable-path` also called the
  3-arg `write-harness!`; updated to 2 args.
- **lg binary:** must run with `LGX_LG=let-go/.tmp/lg` (keeps implicit cwd on the
  source path). The freshly-rebuilt `let-go/lg` (branch `source-paths-defaults`)
  drops implicit cwd and breaks `bin/lgx test`. Decide by self-test, not by
  filename. Bundle with either (the bundle is cwd-independent).
