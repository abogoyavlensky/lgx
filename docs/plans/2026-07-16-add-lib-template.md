# Add built-in `lib` template Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register `lib` as a third built-in `lgx new` template (`lgx new <name> -t lib`) and keep every place that lists the templates in sync.

**Tech Stack:** let-go (`.lg` Clojure), lgx test runner, bash e2e harness, Markdown/HTML docs.

---

## Design

`lgx new` already has a complete template engine: a `templates` registry in
`lgx/new.lg` maps a built-in name to a pinned git coord, `resolve-template-coord`
turns a `-t`/`--template` value (nil/`base`, a registry name, or a `://` URL)
into a coord, and the coord is cached and rendered. Adding a built-in is a
one-entry registry change — no engine changes.

The new template:

- **Name:** `lib`
- **Coord:** `{:git/url "https://github.com/abogoyavlensky/lgx-template-lib" :git/sha "9206700b76e0729c5539ec70faacb3fc8e031431"}`
- **Invocation:** `lgx new <name> -t lib` (the flag form — the same UX as the
  existing `cli` built-in). This plan does **not** add positional-template
  support.

Decisions locked in during design:

- **Follows `cli`, not `base`.** Only `base` has the scoped
  `LGX_TEMPLATE_BASE_URL/SHA` env overrides; `cli` has none, and `lib` follows
  `cli`. No new env vars, no change to `resolve-template-coord`.
- **Error list sorts itself.** The "unknown template" message builds its list
  via `(sort (keys templates))`, so it becomes `base, cli, lib` automatically.
  Only the *asserted* copies of that string (unit test, e2e, ARCHITECTURE doc)
  need updating.
- **Docs table label:** "Library project skeleton" (mirrors `cli`'s
  "Command-line app skeleton").
- **Landing page** updated for consistency alongside the README/help.

### Testing strategy

- Unit (`test/lgx/new_test.lg`): add a `lib-returns-pinned` test mirroring the
  existing `cli-returns-pinned`, and update the `unknown-name-throws` assertion
  to expect `base, cli, lib`.
- E2e (`tests/e2e.sh`): update scenario 106's asserted error string.
- Manual verify: `lgx help` shows the updated row.

## File Structure

| File | Change |
| --- | --- |
| `lgx/new.lg` | Add `"lib"` entry to the `templates` map (source of truth) |
| `test/lgx/new_test.lg` | Add `resolve-template-coord-lib-returns-pinned`; update `unknown-name-throws` assertion |
| `tests/e2e.sh` | Update scenario 106 asserted error string to `base, cli, lib` |
| `lgx.lg` | Help row (line ~37): list `lib` among built-in names |
| `README.md` | Command table (line ~84) + templates section table/example (lines ~113-126) |
| `docs/ARCHITECTURE.md` | Update `(built-in: base, cli)` → `base, cli, lib` (line ~484) |
| `landing/index.html` | Mention `lib` alongside `base`/`cli` (line ~159) |

Work order: tests first (registry entry + its unit tests), then the doc/help
text sweep, then verify.

---

### Task 1: Register the `lib` template with a test

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing test**
  In `test/lgx/new_test.lg`, directly after `resolve-template-coord-cli-returns-pinned`,
  add `resolve-template-coord-lib-returns-pinned`. Mirror the `cli` test exactly:
  blank both `LGX_TEMPLATE_BASE_URL`/`LGX_TEMPLATE_BASE_SHA`, then assert
  `(= (get new/templates "lib") (new/resolve-template-coord "lib"))`.

- [x] **Step 2: Run test to verify it fails**
  Run: `make test` (or `lgx test test/lgx/new_test.lg`)
  Expected: FAIL — `(get new/templates "lib")` is `nil`, so the entry is missing.

- [x] **Step 3: Add the registry entry**
  In `lgx/new.lg`, add to the `templates` map after the `"cli"` entry:
  ```clojure
  "lib" {:git/url "https://github.com/abogoyavlensky/lgx-template-lib"
         :git/sha "9206700b76e0729c5539ec70faacb3fc8e031431"}
  ```

- [x] **Step 4: Run test to verify it passes**
  Run: `make test` (or `lgx test test/lgx/new_test.lg`)
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Add lib built-in template to lgx new"`

> Deviation: the `lib` test also asserts the literal `{:git/url ... :git/sha ...}`
> (not only registry self-comparison), so a mistyped pin can't pass silently.
> Adopted from the background codex plan review — the SHA is the payload of this
> change and self-comparison is tautological.

### Task 2: Update the unknown-template assertions

**Files:**
- Modify: `test/lgx/new_test.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Update the unit assertion**
  In `test/lgx/new_test.lg`, `resolve-template-coord-unknown-name-throws`: change
  the `str/includes?` check from `"base, cli"` to `"base, cli, lib"`.

- [x] **Step 2: Run the unit test to verify it passes**
  Run: `make test` (or `lgx test test/lgx/new_test.lg`)
  Expected: PASS (the real message already sorts to `base, cli, lib`).

- [x] **Step 3: Update the e2e assertion**
  In `tests/e2e.sh`, scenario 106 (`lgx new -t rejects unknown built-in name`):
  change the asserted string
  `lgx: unknown template: nope (built-in: base, cli)` →
  `lgx: unknown template: nope (built-in: base, cli, lib)`.

- [x] **Step 4: Commit**
  `git commit -m "Update unknown-template assertions for lib"`

### Task 3: Update help output and docs

**Files:**
- Modify: `lgx.lg`
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `landing/index.html`

- [x] **Step 1: Update the help row**
  In `lgx.lg` (line ~37), the `lgx new` row currently reads
  `... (template: built-in names \`base\`, \`cli\` or git URL)`. Add `lib`:
  `... (template: built-in names \`base\`, \`cli\`, \`lib\` or git URL)`.
  Keep column alignment consistent with the surrounding rows.

- [x] **Step 2: Update the README**
  - Command table (line ~84): `... from a built-in template (\`base\`, \`cli\`, \`lib\`) or a git URL.`
  - Templates table (after the `cli` row, line ~126): add
    `| \`lib\` | [lgx-template-lib](https://github.com/abogoyavlensky/lgx-template-lib) | Library project skeleton. |`
  - Leave the example block (lines ~116-118) as-is unless a `lib` example reads
    naturally; the `-t cli` example already demonstrates the flag form.

- [x] **Step 3: Update ARCHITECTURE.md**
  Line ~484: `(built-in: base, cli)` → `(built-in: base, cli, lib)`.
  Also line ~455: `(`base`, `cli`; sha-pinned)` → `(`base`, `cli`, `lib`; sha-pinned)`.

> Deviation: the plan named only line ~484, but ARCHITECTURE.md lists the
> registry twice. The background codex plan review caught the second mention
> (line ~455); both are now updated so the doc matches the registry.

- [x] **Step 4: Update the landing page**
  `landing/index.html` (line ~159): the copy "built-in `base` or `cli` templates"
  → "built-in `base`, `cli`, or `lib` templates". Update only the prose; leave
  the terminal example block unchanged.

- [x] **Step 5: Verify help output**
  Run: `make build` then `./<built lg/lgx> help` — or run the repo's usual
  `lgx help` — and confirm the `lgx new` row lists `base`, `cli`, `lib`.
  Expected: the row shows all three built-in names.

- [x] **Step 6: Commit**
  `git commit -m "Document lib template in help and docs"`

### Task 4: Full verification

**Files:** none (verification only)

- [x] **Step 1: Run the unit suite**
  Run: `make test`
  Expected: PASS, including the two new/updated `new_test` assertions.

- [x] **Step 2: Run the e2e suite (or scenario 106)**
  Run: `bash tests/e2e.sh` (or the project's e2e make target).
  Expected: PASS, including scenario 106's updated assertion.

- [x] **Step 3: Optional live scaffold smoke test**
  Run: `lgx new demo-lib -t lib` in a scratch dir, confirm it scaffolds without
  error, then remove the scratch dir. (Requires network to clone the template.)

### Task 5: Make the scaffold "Next steps" `:main`-aware

> Added mid-execution. The background codex implementation review found that
> `cmd-new!` always prints `lgx run` as the first next step, but the `lib`
> template has no `:main`, so that command exits with "nothing to run". A
> library's "see it work" is a passing test, so a runnable project (`:main`
> present) should suggest `lgx run` and a library should suggest `lgx test`.
> Keys off the same `:main` signal `lgx run` itself uses, so the suggestion can
> never contradict the tool's real behavior. User-approved scope addition.

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing test**
  In `test/lgx/new_test.lg`, add tests for a pure `new/next-step-command`
  helper: a cfg map with `:main` → `"lgx run"`; a cfg map without `:main` (and
  `nil`) → `"lgx test"`.

- [x] **Step 2: Run test to verify it fails**
  Run: `lg lgx.lg test test/lgx/new_test.lg`
  Expected: FAIL — `next-step-command` is unresolved.

- [x] **Step 3: Implement**
  In `lgx/new.lg`: require `lgx.config`; add a pure
  `next-step-command` returning `"lgx run"` when `(:main cfg)` is truthy else
  `"lgx test"`. In `cmd-new!`, after render, load the rendered project with
  `config/load-config` and print `(next-step-command (:cfg <result>))` as the
  last next step instead of the hardcoded `lgx run`.

- [x] **Step 4: Run test to verify it passes**
  Run: `lg lgx.lg test test/lgx/new_test.lg`
  Expected: PASS.

- [x] **Step 5: Verify both kinds end-to-end**
  Build `bin/lgx`, then scaffold `-t lib` (expect `lgx test`) and `-t cli`
  (expect `lgx run`) in scratch dirs; confirm the printed next step matches.

- [x] **Step 6: Commit**
  `git commit -m "Make lgx new next-step suggestion :main-aware"`

---

## Completion Summary

**Status: Complete.** All tasks implemented, committed, and verified.

**What was implemented**

- Registered `lib` as a third built-in `lgx new` template
  (`https://github.com/abogoyavlensky/lgx-template-lib` @
  `9206700b76e0729c5539ec70faacb3fc8e031431`), invoked as
  `lgx new <name> -t lib`.
- Synced every place that lists the templates: help output (`lgx.lg`), README
  (command table + templates table), `docs/ARCHITECTURE.md` (both registry
  mentions), the landing page, and the unit/e2e assertions that spell out the
  built-in names.
- Made the scaffold's "Next steps" `:main`-aware (Task 5): a runnable project
  (has `:main`, e.g. `base`/`cli`) suggests `lgx run`; a library (no `:main`,
  e.g. `lib`) suggests `lgx test`.

**Verification**

- Full suite green: `make test` → unit tests pass + all 296 e2e assertions.
- Live end-to-end: `lgx new demo-lib -t lib` scaffolds the real template at the
  pinned sha and prints `lgx test`; `lgx new demo-cli -t cli` prints `lgx run`.
- `make fmt-check` clean.

**Deviations (all surfaced above, in-task)**

1. Task 1 — added a literal-pin assertion (not just registry self-comparison)
   so a mistyped url/sha can't pass silently. (codex plan-review advisory)
2. Task 3 — updated a second `base, cli` mention in `docs/ARCHITECTURE.md`
   (line ~455) the plan hadn't named. (codex plan-review finding)
3. Task 5 — new, user-approved: the `:main`-aware next-step suggestion,
   prompted by the codex implementation review finding that the fixed `lgx run`
   next step fails for a library template.

**Execution-process note**

- Consolidated the per-task codex reviews into two focused passes (full
  implementation diff after Tasks 1–3, then the Task 5 commit) rather than one
  per task — proportionate to a change that is largely one registry entry plus
  synchronized doc/assertion edits.
- The Task 5 codex review caught that `docs/ARCHITECTURE.md`'s "next-steps"
  description (line ~498) still said the scaffold always prints `lgx run` —
  stale after the `:main`-aware change. Fixed in a follow-up commit per the
  repo's same-PR doc rule.

**What the plan could have specified better**

- It scoped the work as "registry entry only, no engine changes" and so missed
  that adding a *library* template (a different kind than the existing app
  templates) exposes an app-centric assumption in `cmd-new!`'s hardcoded
  `lgx run` next step. A future "add a template" plan should check whether the
  new template's *kind* breaks any shared scaffold output, not just whether the
  registry and docs are in sync.
