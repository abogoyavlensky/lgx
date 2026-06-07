# Help Output Layout Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape `lgx help` so project tasks read as first-class commands — aligned to the same column as built-in commands, shown as `lgx <task>`, with a one-line usage synopsis (`lgx [options] <command> [args...]`), global options moved to the bottom, and green/purple section titles mirroring the runtime headers.

**Tech Stack:** let-go (lgx source), `lgx.style` color helpers, bash e2e harness.

---

## Design

### Current state

`lgx help` prints (via the static `base-usage` def + `tasks-block`):

```
Usage:
  lgx install                  Fetch dependencies declared in lgx.edn
  ...
Global flags:
  --with <a,b,...>             ...
Project tasks:
  ci        Run the full CI pipeline locally
  fmt       Format all sources
```

Problems: the `Project tasks` block uses a different, narrower description
column, shows bare task names (no `lgx ` prefix), and sits *after* Global flags,
so it reads as a detached list rather than a continuation of the commands.

### Target

```
lgx - project manager for let-go

Usage: lgx [options] <command> [args...]

Built-in commands:                                    (green title)
  lgx install                  Fetch dependencies declared in lgx.edn
  lgx run [args...]            Run a script via `lg` with deps on the source path
                               (uses :main from lgx.edn when script is omitted)
  ...
  lgx help                     Show this help

Project tasks:                                        (purple title)
  lgx ci                       Run the full CI pipeline locally
  lgx fmt                      Format all sources
  lgx test-all                 Run unit tests and lint

Global options:
  --with <a,b,...>             Apply named :contexts (extra deps/paths) ...
  --verbose                    Print the env vars lgx sets ...
```

Changes:
1. **Tasks aligned as commands** — each task row is `lgx <task>` with its doc at
   the shared description column (31), so tasks read as first-class commands.
2. **Order** — Built-in commands → Project tasks → Global options. Commands and
   tasks are adjacent; options are a footer.
3. **Titles** — a real one-line `Usage: lgx [options] <command> [args...]`
   synopsis, the command list titled `Built-in commands:`, paired with
   `Project tasks:`.
4. **Color** — `Built-in commands:` green, `Project tasks:` purple (via
   `lgx.style`, gated by `LGX_NO_COLOR`); `Global options:` stays neutral.

### Implementation notes

- **Call-time assembly.** The colored titles must be built when help runs, not in
  a top-level `def` — a `def` evaluates during `lg -b` bundling and would bake the
  `LGX_NO_COLOR` decision at build time. So the final help string is assembled in
  a function (`usage-for`); only the **color-free** row blocks stay as static
  defs.
- **Shared column.** The built-in command rows and global-flag rows are already
  hand-aligned to description column **31** (verified: both command rows and
  continuation lines start their text at column 31). Introduce
  `(def ^:private doc-col 31)` and align task rows to it; a comment ties the
  constant to the hand-aligned static rows.
- **Task row.** left = `"  lgx " <name>`. With a `:doc`, pad left to `doc-col`
  then append the doc; if `lgx <name>` already meets/exceeds `doc-col`, use a
  2-space gap instead of negative padding. Without a `:doc`, emit just the left.
- **No project / no tasks.** `usage-for` takes the result of `config/find-project`
  (which may be nil). The Project tasks section is omitted when there are no tasks
  (current `tasks-block` already returns nil then), so no-project help is just
  Built-in commands + Global options.
- **Streams.** Help prints to stdout (data the user asked for), unchanged.

### Testing

e2e only (help assembly lives in `lgx.main`, matching the current untested-by-unit
structure). Extend the existing help scenarios; keep `Usage:` assertions valid via
the synopsis line.

## File Structure

| File | Change |
|---|---|
| `lgx.lg` (`lgx.main`) | Split `base-usage` into color-free `command-rows`/`option-rows` defs; add `doc-col`; rewrite `task-line`/`tasks-block` (`lgx ` prefix, `doc-col` alignment, purple title); add `usage-for` assembling the new order with colored titles + synopsis; point `print-usage!` at it. |
| `README.md` | Rename "Global flags" → "Global options" in the `LGX_NO_COLOR` row / any help description. |
| `tests/e2e.sh` | Update/extend the help scenarios for the new task row format, ordering, and colored titles. |

---

## Implementation Steps

### Task 1: Reshape the help assembly in `lgx.lg`

**Files:**
- Modify: `lgx.lg`

- [x] **Step 1: Split the static usage into color-free blocks**
  Replace the single `base-usage` def with two color-free static defs holding the
  existing rows verbatim (no section titles):
  - `command-rows` — the `  lgx install ...` through `  lgx help ...` lines
    (each ending in `\n`).
  - `option-rows` — the `  --with ...` and `  --verbose ...` lines.
  Keep them aligned to column 31 exactly as today.

- [x] **Step 2: Add the shared description column constant**
  Add `(def ^:private doc-col 31)` with a comment noting the static rows above are
  hand-aligned to it and the task rows align to it too.

- [x] **Step 3: Rewrite the task row + block**
  Change `task-line` to build left = `(str "  lgx " name)`; with a non-blank
  `:doc`, pad left to `doc-col` (reuse `pad-right`) then append the doc, but if
  `(count left)` ≥ `doc-col` append `"  "` + doc instead; with a blank `:doc`,
  return just left. Update `tasks-block` to drop the old dynamic `width`, title
  the block with `(style/purple "Project tasks:")`, and keep returning nil when
  there are no tasks. (`lgx.style` is already required in `lgx.lg`.)

- [x] **Step 4: Assemble `usage-for` in the new order**
  Write `usage-for [project]` returning, in order: `lgx - project manager for
  let-go` → blank → `Usage: lgx [options] <command> [args...]` → blank →
  `(style/green "Built-in commands:")` + `command-rows` → the tasks block (if any)
  → blank → `Global options:` + `option-rows`. Point `print-usage!` at
  `(usage-for (config/find-project))` (drop the `base-usage` fallback; `usage-for`
  handles a nil project by omitting the tasks section).

- [x] **Step 5: Build and render to verify by eye**
  Run: `LG=/Users/andrew/Projects/let-go/lg make build`
  Then render with a throwaway project that declares a few tasks (with and without
  `LGX_NO_COLOR=1`) and confirm: synopsis line present; `Built-in commands:`
  green, `Project tasks:` purple (plain under `LGX_NO_COLOR`); task rows show
  `lgx <task>` with docs at column 31; Global options last.
  Expected: layout matches the Target mockup above.

- [x] **Step 6: Run the unit suite (no regressions)**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg bin/lgx test`
  Expected: `267 tests, ... 0 failures`.

- [x] **Step 7: Commit**
  `git commit -m "Reshape lgx help: tasks as aligned commands, colored titles"`

### Task 2: Update e2e coverage

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Extend the help scenario assertions**
  In scenario 18 (help lists project tasks), add assertions that:
  - the help contains `Built-in commands:`;
  - a task renders with the `lgx ` prefix (e.g. `lgx fmt`);
  - `Global options:` appears *after* `Project tasks:` (e.g. capture the output and
    check the index of `Global options:` is greater than that of `Project tasks:`,
    or grep line numbers).
  Add a small color check: with color on, the output contains the green
  `Built-in commands:` and purple `Project tasks:` escape-wrapped titles
  (substring `\u001b[38;5;35m` before `Built-in commands:` is awkward to match, so
  instead assert the colored sequence via `$'\e[38;5;35mBuilt-in commands:'` and
  `$'\e[38;5;98mProject tasks:'`); with `LGX_NO_COLOR=1`, assert the plain titles
  are present and those escape sequences are absent.
  Leave scenario 2 and the no-project scenarios unchanged — `Usage:` still appears
  via the synopsis.

- [x] **Step 2: Run the full suite**
  Run: `LG=/Users/andrew/Projects/let-go/lg LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg bash tests/run.sh`
  Expected: unit `0 failures` and `All N e2e assertions passed.`

- [x] **Step 3: Commit**
  `git commit -m "Cover reshaped help output in e2e"`

### Task 3: Docs touch-up

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md`

- [x] **Step 1: Rename the term and note the layout**
  Rename "Global flags" → "Global options" wherever it appears in `README.md`
  (e.g. the `LGX_NO_COLOR` row) and `docs/ARCHITECTURE.md`, so the docs match the
  renamed help section. If `docs/ARCHITECTURE.md` describes help/usage, add a
  short sentence that `lgx help` lists built-in commands and project tasks in one
  aligned `lgx <name>` column (green / purple titles), with global options last.

- [x] **Step 2: Commit**
  `git commit -m "Document the reshaped help layout and Global options rename"`

---

## Done criteria

- `lgx help` matches the Target mockup: `Usage: lgx [options] <command> [args...]`
  synopsis, green `Built-in commands:`, purple `Project tasks:` with `lgx <task>`
  rows aligned at column 31, `Global options:` last.
- `LGX_NO_COLOR=1` renders the titles plain.
- No-project `lgx help` shows commands + flags (no tasks section) and still
  contains `Usage:`.
- `bash tests/run.sh` green (unit + e2e).

---

## Implementation summary

**Status:** Complete. All three tasks implemented, tested, and committed on
branch `rework-cmd-output-title`.

**What shipped (as designed):**
- `lgx.lg`: replaced the static `base-usage` with `doc-col` (31) + color-free
  `command-rows`/`option-rows` defs; `task-line` now renders `lgx <name>` padded
  to `doc-col`; `tasks-block` titles with `style/purple`; new `usage-for`
  assembles synopsis → green `Built-in commands:` → purple `Project tasks:` (if
  any) → neutral `Global options:`; `print-usage!` calls it with
  `(config/find-project)` (nil → no tasks section).
- e2e scenario 18 extended: usage synopsis, `Built-in commands:` title, `lgx fmt`
  task-row prefix, `Global options:` ordered after `Project tasks:`, green/purple
  titles with color on and absent under `LGX_NO_COLOR`.
- Docs: README + ARCHITECTURE renamed "Global flags" → "Global options"; an
  ARCHITECTURE note describes the help layout and call-time title coloring.

**Results:** `bash tests/run.sh` green — 267 unit tests, 198 e2e assertions.
Verified by eye: colored, `LGX_NO_COLOR=1` plain, and no-project renders.

**Issues / deviations:** none. The pre-existing help assertions (scenario 2,
no-project scenarios, the `fmt`/`Project tasks:` checks) kept passing unchanged,
since `Usage:` still appears via the synopsis and task names remain substrings of
the `lgx <name>` rows.
