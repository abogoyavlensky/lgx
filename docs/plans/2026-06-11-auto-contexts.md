# Auto-Applied :dev / :test Contexts Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `lgx.edn` defines a context named `:dev`, apply it automatically to `lgx run` and `lgx nrepl`; when it defines `:test`, apply it automatically to `lgx test` — so dev/test deps and paths attach to the right built-in commands without `--with` on every invocation.

**Tech Stack:** let-go (`.lg`), lgx's own test runner (`lgx test`), bash e2e harness (`tests/e2e.sh`).

---

## Design

### Problem

Splitting deps by environment is routine: nREPL tooling and dev-only source
dirs belong to development runs, test helpers belong to test runs, and none of
them belong in a built binary. Contexts already model this
(`:contexts {:dev {...} :test {...}}` + `--with`), but the flag must be typed
on every invocation: `lgx --with dev run`, `lgx --with test test`. Forgetting
it gives a confusing "namespace not found" rather than a hint that a context
was meant to be applied.

The alternative considered — letting projects override built-in commands —
was rejected: built-ins keep a uniform meaning across projects
(`reserved-task-names` in `lgx/config.lg` already enforces this), and the
stated need is *extras*, not replacement.

### Solution overview

Adopt the Leiningen-style convention, scoped tightly:

- `lgx run` and `lgx nrepl` auto-apply the context named `:dev` **iff** it is
  defined in the project's `:contexts`.
- `lgx test` auto-applies the context named `:test` iff defined.
- Nothing else changes: `build`, `install`, and `new` never auto-apply (dev
  and test deps cannot leak into artifacts), and a task's `:run` steps do not
  inherit auto-contexts — tasks already declare `:with` explicitly.
- An undefined `:dev`/`:test` is a silent no-op, not an error. `:dev` and
  `:test` stay ordinary context names — no schema change, no reservation.

### Layering and precedence

The auto-context name is **prepended** to the CLI `--with` list before the
existing `overlay-basis` call. Since `config/context-overlay` folds
`merge-coords` left to right (last-wins on a lib-name collision), this yields,
lowest → highest precedence:

```
project :deps / :paths / :resource-paths
  → auto context (:dev or :test)
  → CLI --with contexts (in order)
```

`lgx --with dev run` (naming the auto context explicitly) is harmless:
duplicate dep names dedupe in `merge-coords`, duplicate paths in
`dedup-keep-first`.

### Visibility

Silent by default. Under `--verbose`, the command prints one stderr line
before invoking `lg`:

```
+ auto context :dev
```

`lgx run` stays header-free by design (its output mirrors the built binary —
see the comment in `cmd-run`), which is why the default is silence rather
than a status line. Discoverability lives in the help text and README:

- One plain line appended after the option rows in `lgx help`:
  `A :dev context auto-applies to run/nrepl, :test to test (when defined; --with adds on top).`
- A short "Default contexts" paragraph in the README's existing
  "Contexts (`:contexts`)" section.
- The layering list in `docs/ARCHITECTURE.md` gains the auto-context layer.

### Components

1. **`config/auto-context` (new, `lgx/config.lg`)** — pure helper:
   `(auto-context cfg name)` returns `[name]` when `name` is a key of the
   cfg's `:contexts` map, else `[]`. Lives in `config.lg` (not `lgx.lg`)
   because `lgx.main`'s load runs `(main)`, so it cannot be required from a
   unit test.
2. **Call sites (`lgx.lg`)** — `cmd-run`, `cmd-nrepl` compute
   `(concat (config/auto-context cfg :dev) with)`; `cmd-test` the same with
   `:test`; each passes the combined vector to `overlay-basis` and prints the
   verbose line when the auto part is non-empty.
3. **Help text (`lgx.lg`)** — the auto-context note after `option-rows` in
   `usage-for`.

### Error handling

No new error paths. An unknown name in `--with` still fails loudly via
`with->overlay!`; the auto name is only ever added when defined, so it can
never trigger that error.

### Testing strategy

- **Unit** (`test/lgx/config_test.lg`): `auto-context` returns `[name]` when
  defined, `[]` when the name is absent and when the cfg has no `:contexts`.
- **E2E** (`tests/e2e.sh`, new scenarios appended after Scenario 97):
  `:dev` extra-path visible to `run`; `:test` extra-path visible to `test`;
  `--with` stacks on top of the auto context; `build` does **not** see
  `:dev`; verbose line printed under `--verbose` for `run`.

## File structure

- Modify: `lgx/config.lg` — add `auto-context` near the other cfg accessors.
- Modify: `lgx.lg` — `cmd-run`, `cmd-nrepl`, `cmd-test`, `option-rows`/`usage-for`.
- Modify: `test/lgx/config_test.lg` — unit tests for `auto-context`.
- Modify: `tests/e2e.sh` — Scenarios 98–101.
- Modify: `README.md` — "Default contexts" paragraph in the Contexts section.
- Modify: `docs/ARCHITECTURE.md` — layering list + run/nrepl/test command notes.

## Tasks

### Task 1: `config/auto-context` helper

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests**
  In `test/lgx/config_test.lg`, add three `deftest`s for
  `config/auto-context`:
  - cfg `{:contexts {:dev {:extra-paths ["dev"]}}}` with name `:dev` → `[:dev]`
  - same cfg with name `:test` → `[]`
  - cfg `{}` with name `:dev` → `[]`

- [x] **Step 2: Run tests to verify they fail**
  Run: `bin/lgx test test/lgx/config_test.lg` (build first with `make build`
  if `bin/lgx` is stale; see `docs/knowledge-base/lgx-dev-workflow.md` for the
  `LGX_LG` setup).
  Expected: FAIL — `auto-context` is undefined, so the test file fails to
  load and lgx reports `a test file failed to load`.

- [x] **Step 3: Implement `auto-context`**
  In `lgx/config.lg`, next to the `contexts` accessor:
  `(defn auto-context [cfg name] ...)` — `[name]` when
  `(contains? (contexts cfg) name)`, else `[]`. Docstring should state the
  convention: callers prepend the result to the CLI `--with` list so
  explicit `--with` wins on collisions.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && bin/lgx test test/lgx/config_test.lg`
  Expected: PASS, 0 failures.

- [x] **Step 5: Commit**
  `git commit -m "Add config/auto-context helper"`

### Task 2: Apply auto-contexts in run, nrepl, test

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh`

- [x] **Step 1: Write the failing e2e scenarios**
  Append after Scenario 97 in `tests/e2e.sh`, following the structure of
  Scenario 73 (tmp project + `LGX_HOME`, guarded by `supports_source_paths`):
  - **Scenario 98** — `:dev` auto-applies to `run`: project with
    `:main "m.lg"`, `:contexts {:dev {:extra-paths ["dev"]}}`, a
    `dev/devtool.lg` ns required by `m.lg`. Plain `lgx run` (no `--with`)
    prints the dev ns output. Also run with `--verbose` and assert the output
    contains `+ auto context :dev` — the line goes to stderr, so capture with
    `2>&1` as Scenario 73 does.
  - **Scenario 99** — `:test` auto-applies to `test`: project with
    `:contexts {:test {:extra-paths ["test-support"]}}`, a helper ns under
    `test-support/`, and a `test/x_test.lg` requiring it. Plain `lgx test`
    passes (`0 failures`).
  - **Scenario 100** — `--with` stacks on top: `:contexts` defines both
    `:dev {:extra-paths ["dev"]}` and `:extra {:extra-paths ["extra"]}`;
    `m.lg` requires one ns from each dir; `lgx --with extra run` succeeds.
  - **Scenario 101** — `build` ignores `:dev`: project whose `:main`
    does **not** require the dev ns, `:contexts {:dev {:extra-deps {...}}}`
    pointing at a `make_bare_repo` lib, plus `:targets {:bin {:out "bin/app"}}`.
    `lgx build` exits 0 (so the non-fetch isn't vacuous on a failed build)
    and its output does **not** contain `installing` (the dev dep is not
    fetched). Guard with `supports_source_paths`.

- [x] **Step 2: Run e2e to verify the new scenarios fail**
  Run: `bash tests/e2e.sh`
  Expected: Scenario 98/99/100 FAIL (ns not found without the auto context);
  Scenario 101 may already pass — that is fine, it pins the non-leak behavior.

- [x] **Step 3: Implement the call-site changes**
  In `lgx.lg`:
  - `cmd-run` and `cmd-nrepl`: after `load-config!`, compute
    `auto` as `(config/auto-context cfg :dev)`, pass
    `(vec (concat auto with))` to `overlay-basis`; when `verbose?` and
    `(seq auto)`, write `+ auto context :dev\n` to stderr before the basis
    is built.
  - `cmd-test`: same with `:test`.
  - `cmd-build`, `cmd-install`, `cmd-task`: untouched.
  Keep the verbose line emission in one small private helper in `lgx.lg`
  so the three commands don't repeat it — e.g.
  `(defn- auto-with! [cfg name with verbose?] ...)` returning the combined
  name vector after printing the verbose line.

- [x] **Step 4: Run the full test suite**
  Run: `make test`
  Expected: unit tests and all e2e scenarios PASS. (Note
  `docs/knowledge-base/shared-fs-bin-lgx-race`: don't run `make test`
  concurrently from two machines sharing the checkout.)

- [x] **Step 5: Commit**
  `git commit -m "Auto-apply :dev context to run/nrepl and :test to test"`

### Task 3: Help text and docs

**Files:**
- Modify: `lgx.lg` (help output)
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Test: `tests/e2e.sh` (extend Scenario 2)

- [x] **Step 1: Extend the help e2e assertion**
  In Scenario 2 (`lgx help`), assert the output contains
  `A :dev context auto-applies to run/nrepl, :test to test`.
  Run `bash tests/e2e.sh` briefly to confirm it FAILs.

- [x] **Step 2: Add the help line**
  In `lgx.lg`, append after the option rows inside `usage-for` (color-free,
  like `option-rows`):
  `\nA :dev context auto-applies to run/nrepl, :test to test (when defined; --with adds on top).\n`

- [x] **Step 3: Update README.md**
  In the "Contexts (`:contexts`)" section, after the two "Apply contexts two
  ways" bullets, add a short **Default contexts** paragraph: contexts named
  `:dev` and `:test` are conventions — `:dev` auto-applies to `lgx run` and
  `lgx nrepl`, `:test` to `lgx test`, when defined; `build`/`install` never
  auto-apply; `--with` layers on top; `--verbose` shows
  `+ auto context :dev`. Reuse the existing example config (it already
  defines `:dev` and `:test`). Use /writing-clearly.

- [x] **Step 4: Update docs/ARCHITECTURE.md**
  - Extend the layering list with the auto-context layer between the project
    layer and task `:with`:
    `project ... → auto context (:dev for run/nrepl, :test for test) → task :with contexts → CLI --with contexts → task inline extras`.
    Note that auto-contexts apply only to the three built-in commands, never
    to tasks or build/install.
  - Mention the auto-apply step in the run/nrepl/test command walkthroughs
    where `--with` contexts are mentioned.
  - Check the `Verify against:` footers of any touched knowledge-base file —
    none are expected to change, but confirm.

- [x] **Step 5: Run the full suite**
  Run: `make test`
  Expected: all PASS, including the extended Scenario 2.

- [x] **Step 6: Commit**
  `git commit -m "Document auto-applied :dev/:test contexts in help, README, architecture"`

---

## Completion summary (2026-06-11)

**Status: completed.** All three tasks implemented, full suite green
(unit + 237 e2e assertions).

Commits:

- `4ee5275` — `config/auto-context` helper + unit tests.
- `a9fc8a6` — `auto-with!` wired into `cmd-run`/`cmd-nrepl` (`:dev`) and
  `cmd-test` (`:test`); e2e Scenarios 98–101.
- `b611d33` — follow-up from the codex review checkpoint: `cmd-test` now
  validates `test/` exists *before* building the basis, so a missing test
  dir never fetches deps (pinned by Scenario 102, which asserts the cache
  side effect, not just output — the output-only assertion was vacuous).
- `84b675b` — help note after the option rows, README "Default contexts"
  paragraph + layering update, ARCHITECTURE walkthrough/layering updates.

Deviations from the plan, all small:

1. The verbose-line emission lives in `auto-with!` (as the plan's Task 2
   suggested) and the test-dir check moved ahead of it — a codex review
   finding, not in the original plan.
2. Scenario 102 (missing `test/` + `:test` context) was added beyond the
   planned 98–101, to pin the validation-order fix.
3. Codex also flagged that an auto `:dev` dir shadows a `--with` dir for a
   same-named namespace. Assessed as by-design: lgx path layering is
   first-match-wins (project first), identical to how a task's `:with`
   already relates to CLI `--with`; documented explicitly in the
   ARCHITECTURE contexts section instead of changed.
