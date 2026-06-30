# Auto-Apply `:test` Context to `lgx nrepl` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `lgx nrepl` auto-applies **both** the `:dev` and `:test` contexts
(each when defined in `lgx.edn`), so a REPL session has dev tooling *and* test
helpers on the source path without typing `--with`. `lgx run` stays
`:dev`-only; `lgx test` stays `:test`-only.

**Tech Stack:** let-go (`.lg`), lgx's own test runner (`lgx test`), bash e2e
harness (`tests/e2e.sh`).

---

## Design

### Problem

`lgx nrepl` is the dev REPL. Today it auto-applies only the `:dev` context, so
test-only deps and `test-support/` source dirs (declared under a `:test`
context) are absent from the REPL — you cannot `(require ...)` a test namespace
or its helpers interactively without `lgx --with test nrepl`. Since the nREPL
session is exactly where you'd iterate on tests, `:test` should be on the path
by default, alongside `:dev`.

### Solution overview

The wiring already exists. `auto-with!` (`lgx.lg`) prepends a single convention
context to the CLI `--with` list, and `config/auto-context` (`lgx/config.lg`)
returns `[name]`-or-`[]` for one name. The change generalizes `auto-with!` from
a single name to an **ordered list of names**, then each command passes its own
list:

- `cmd-run` → `[:dev]`
- `cmd-nrepl` → `[:dev :test]`  ← the behavioral change
- `cmd-test` → `[:test]`

`auto-with!` resolves each name through `config/auto-context` (so an undefined
name is silently skipped), prepends the defined ones to `--with`, and under
`--verbose` prints one `+ auto context <name>` line per defined name.

### Layering and precedence

Auto names are prepended to the CLI `--with` list, before `overlay-basis`.
`config/context-overlay` folds `merge-coords` left-to-right (last-wins on a
lib-name collision). For `nrepl` the resolved order is:

```
project :deps / :paths / :resource-paths
  → auto context :dev
  → auto context :test          (wins over :dev on a lib-name collision)
  → CLI --with contexts (in order, win over both)
```

The `[:dev :test]` order means `:test` wins over `:dev` on a collision, matching
Leiningen's REPL convention (test layered on dev). Such collisions are rare
(dev and test deps are usually disjoint). An explicit `--with` still beats both,
unchanged.

### Key decisions

- **Generalize the helper, don't special-case nrepl.** One ordered-list
  signature keeps the three commands uniform and the precedence logic in one
  place. `auto-with!` is private (`defn-`), so the signature change touches only
  its three call sites. (Rejected alternative: nesting two `auto-with!` calls in
  `cmd-nrepl` — reverses the order confusingly and duplicates the verbose
  logic.)
- **Order `[:dev :test]`** (user-confirmed): `:test` wins over `:dev` on a
  collision.
- **No change to `config/auto-context`** — it already handles one name;
  `auto-with!` maps it over the list. No schema change; `:dev`/`:test` stay
  ordinary context names.

### Components touched

1. **`auto-with!` (`lgx.lg`)** — signature `name` → `names` (vector). Resolve
   the defined names via `(mapcat #(config/auto-context cfg %) names)`; under
   `--verbose`, `doseq` one `+ auto context <name>` line per defined name;
   return `(vec (concat auto with))`. Both `mapcat` and `doseq` are already used
   in this codebase.
2. **Call sites (`lgx.lg`)** — `cmd-run` `[:dev]`, `cmd-nrepl` `[:dev :test]`,
   `cmd-test` `[:test]`.
3. **Help row (`lgx.lg`, `command-rows`)** — the `nrepl` sub-line changes to
   `auto-applies :dev and :test contexts if defined`.
4. **Docs** — `README.md` (nrepl table row + "Default contexts" paragraph);
   `docs/ARCHITECTURE.md` (nrepl walkthrough, Contexts section, layering
   mentions) updated to say nrepl applies `:dev` *and* `:test`.

### Error handling

No new error paths. An unknown `--with` name still fails loudly via the existing
overlay resolution; auto names are only ever added when defined, so they can't
trigger that error.

### Testing strategy

- **Unit** (`test/lgx/config_test.lg`): `auto-context` is unchanged; existing
  tests stay green. No new unit test — the multi-name logic lives in the private
  `auto-with!`, which `lgx.main`'s load-time `(main)` makes un-requirable from a
  unit test (the same constraint the original auto-contexts plan noted).
- **E2E** (`tests/e2e.sh`, new scenario after Scenario 102): project with
  `:contexts {:dev {} :test {}}`; `lgx nrepl --verbose` (pipe EOF on stdin) must
  print **both** `+ auto context :dev` and `+ auto context :test` on stderr,
  exit 0, and print `nREPL server started`. Empty contexts add no paths/deps, so
  no `-source-paths` support is needed and the scenario needs no
  `supports_source_paths` guard. The assertion is **not** vacuous: the same
  `auto` list drives both the printed lines and the vector handed to
  `overlay-basis`, so `:test` cannot appear in the verbose output without being
  in the resolved basis.

## File structure

- Modify: `lgx.lg` — `auto-with!` signature + the three call sites + the `nrepl`
  help sub-line in `command-rows`.
- Modify: `tests/e2e.sh` — new Scenario 103 (nrepl applies `:dev` and `:test`).
- Modify: `README.md` — nrepl row in the command table + "Default contexts"
  paragraph.
- Modify: `docs/ARCHITECTURE.md` — nrepl walkthrough, Contexts section, and the
  auto-context layering mentions.

## Tasks

### Task 1: Generalize `auto-with!` and apply `[:dev :test]` to nrepl

**Files:**
- Modify: `lgx.lg`
- Test: `tests/e2e.sh`

- [x] **Step 1: Write the failing e2e scenario**
  Append **Scenario 113** (the file already had Scenarios up through 112; 103
  was taken) after Scenario 112 in `tests/e2e.sh`, following the
  structure of Scenarios 90–91 (tmp project + `LGX_HOME`, pipe `echo ''` to
  feed stdin EOF). The project's `lgx.edn` defines
  `{:contexts {:dev {} :test {}}}`. Run
  `lgx --verbose nrepl` (`--verbose` is a *leading* global option) capturing
  **both** streams (`2>&1`), then assert:
  - exit 0,
  - output contains `nREPL server started`,
  - output contains `+ auto context :dev`,
  - output contains `+ auto context :test`.
  Clean up the tmp dirs and `.nrepl-port` as the sibling scenarios do.

- [x] **Step 2: Run e2e to verify the new scenario fails**
  Run: `bash tests/e2e.sh`
  Expected: Scenario 103 FAILS on the `+ auto context :test` assertion — nrepl
  applies only `:dev` today.
  (Build `bin/lgx` first with `make build` if stale; see
  `docs/knowledge-base/lgx-dev-workflow.md` for the `LGX_LG` setup. Per
  `docs/knowledge-base/shared-fs-bin-lgx-race`, don't run the suite
  concurrently from two machines sharing the checkout.)

- [x] **Step 3: Generalize `auto-with!`**
  In `lgx.lg`, change `auto-with!` from a single `name` to an ordered `names`
  vector:
  - resolve defined names: `(vec (mapcat #(config/auto-context cfg %) names))`,
  - under `verbose?`, `(doseq [nm auto] (write! *err* (str "+ auto context " nm "\n")))`,
  - return `(vec (concat auto with))`.
  Update the docstring to state the conventions: `run` auto-applies `:dev`,
  `nrepl` `:dev` and `:test`, `test` `:test`; names prepend left-to-right so a
  later auto name wins over an earlier one and an explicit `--with` wins over
  all (last-wins).

- [x] **Step 4: Update the three call sites**
  In `lgx.lg`:
  - `cmd-run`: `(auto-with! cfg [:dev] with verbose?)`
  - `cmd-nrepl`: `(auto-with! cfg [:dev :test] with verbose?)`
  - `cmd-test`: `(auto-with! cfg [:test] with verbose?)`

- [x] **Step 5: Update the nrepl help sub-line**
  In `command-rows` (`lgx.lg`), change the `nrepl` continuation line from
  `(free port unless --port given; auto-applies :dev context if defined)` to
  `(free port unless --port given; auto-applies :dev and :test contexts if defined)`.
  Keep the column alignment of the surrounding rows.

- [x] **Step 6: Run the full suite**
  Run: `make test`
  Expected: unit tests and all e2e scenarios PASS, including the new
  Scenario 113 and the unchanged Scenarios 98–102. (Result: all 282 e2e
  assertions pass; unit tests pass.)

- [x] **Step 7: Commit**
  `git commit -m "Auto-apply :test context to lgx nrepl alongside :dev"`

### Task 2: Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Update README.md**
  - In the command table, the `lgx nrepl [--port N]` row: note it auto-applies
    `:dev` and `:test` (when defined), consistent with the "Default contexts"
    paragraph.
  - In the "Default contexts" paragraph (the `## Contexts` section): change
    "`:dev` auto-applies to `lgx run` and `lgx nrepl`, and `:test` auto-applies
    to `lgx test`" to reflect that `lgx nrepl` applies **both** `:dev` and
    `:test`, while `run` stays `:dev`-only and `test` stays `:test`-only. Keep
    the rest (build/install never auto-apply; `--with` layers on top; `--verbose`
    prints `+ auto context <name>`). Use /writing-clearly.
  - Check the example-config comment (`;; :dev auto-applies to run/nrepl, :test
    to lgx test.`) and update it to mention `:test` also auto-applies to
    `nrepl`.

- [x] **Step 2: Update docs/ARCHITECTURE.md**
  - `### lgx nrepl [--port N]` walkthrough: it currently says "a defined `:dev`
    context applies, as in `run`" — change to "defined `:dev` and `:test`
    contexts apply (`auto-with!` with `[:dev :test]`)".
  - `### Contexts`: the name-convention sentence ("a context named `:dev` ...
    auto-applies to `run`/`nrepl`, and `:test` to `test`") and the layering
    paragraph that lists "auto context (:dev for run/nrepl, :test for test)" —
    update both to record that `nrepl` applies `:dev` *and* `:test`.
  - Any other `auto-with!` / "`run`/`nrepl` do with `:dev`" mentions: update so
    nrepl reflects `[:dev :test]`.
  - Confirm the `Verify against:` footers of any touched knowledge-base file
    still hold — none are expected to change.

- [x] **Step 3: Run the full suite**
  Run: `make test`
  Expected: all PASS (docs don't affect tests, but the help-text e2e assertions
  must still hold). (Result: 282 e2e assertions + unit tests pass.)

- [x] **Step 4: Commit**
  `git commit -m "Document :test auto-applying to nrepl in README and architecture"`

---

## Completion summary (2026-06-30)

**Status: completed.** Both tasks implemented, full suite green (unit + 282
e2e assertions). `lgx nrepl` now auto-applies both `:dev` and `:test`; `run`
stays `:dev`-only and `test` stays `:test`-only.

Commits:

- `e77cae2` — generalize `auto-with!` to an ordered name vector; `cmd-run`
  `[:dev]`, `cmd-nrepl` `[:dev :test]`, `cmd-test` `[:test]`; nrepl help
  sub-line; e2e Scenario 113.
- (docs commit) — README nrepl row + "Default contexts" paragraph +
  layering line + example-config comment; ARCHITECTURE nrepl walkthrough,
  Contexts section, and `test`-walkthrough parenthetical.

Deviations from the plan, both minor:

1. The new e2e scenario is **113** (appended after the existing Scenario 112),
   not 103 — 103 was already taken when the plan was written.
2. `--verbose` is a *leading* global option, so the scenario invokes
   `lgx --verbose nrepl`, not `lgx nrepl --verbose` (the latter forwards
   `--verbose` to nrepl's own arg parser, which rejects it).

Review: `review-with-codex` ran on each task's uncommitted diff. The only
finding (stale docs after the code change) was the planned Task 2, which
resolved it; the doc review then came back clean. No code/test defects were
found.
