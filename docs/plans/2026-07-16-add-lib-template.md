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

- [ ] **Step 1: Write the failing test**
  In `test/lgx/new_test.lg`, directly after `resolve-template-coord-cli-returns-pinned`,
  add `resolve-template-coord-lib-returns-pinned`. Mirror the `cli` test exactly:
  blank both `LGX_TEMPLATE_BASE_URL`/`LGX_TEMPLATE_BASE_SHA`, then assert
  `(= (get new/templates "lib") (new/resolve-template-coord "lib"))`.

- [ ] **Step 2: Run test to verify it fails**
  Run: `make test` (or `lgx test test/lgx/new_test.lg`)
  Expected: FAIL — `(get new/templates "lib")` is `nil`, so the entry is missing.

- [ ] **Step 3: Add the registry entry**
  In `lgx/new.lg`, add to the `templates` map after the `"cli"` entry:
  ```clojure
  "lib" {:git/url "https://github.com/abogoyavlensky/lgx-template-lib"
         :git/sha "9206700b76e0729c5539ec70faacb3fc8e031431"}
  ```

- [ ] **Step 4: Run test to verify it passes**
  Run: `make test` (or `lgx test test/lgx/new_test.lg`)
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -m "Add lib built-in template to lgx new"`

### Task 2: Update the unknown-template assertions

**Files:**
- Modify: `test/lgx/new_test.lg`
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Update the unit assertion**
  In `test/lgx/new_test.lg`, `resolve-template-coord-unknown-name-throws`: change
  the `str/includes?` check from `"base, cli"` to `"base, cli, lib"`.

- [ ] **Step 2: Run the unit test to verify it passes**
  Run: `make test` (or `lgx test test/lgx/new_test.lg`)
  Expected: PASS (the real message already sorts to `base, cli, lib`).

- [ ] **Step 3: Update the e2e assertion**
  In `tests/e2e.sh`, scenario 106 (`lgx new -t rejects unknown built-in name`):
  change the asserted string
  `lgx: unknown template: nope (built-in: base, cli)` →
  `lgx: unknown template: nope (built-in: base, cli, lib)`.

- [ ] **Step 4: Commit**
  `git commit -m "Update unknown-template assertions for lib"`

### Task 3: Update help output and docs

**Files:**
- Modify: `lgx.lg`
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `landing/index.html`

- [ ] **Step 1: Update the help row**
  In `lgx.lg` (line ~37), the `lgx new` row currently reads
  `... (template: built-in names \`base\`, \`cli\` or git URL)`. Add `lib`:
  `... (template: built-in names \`base\`, \`cli\`, \`lib\` or git URL)`.
  Keep column alignment consistent with the surrounding rows.

- [ ] **Step 2: Update the README**
  - Command table (line ~84): `... from a built-in template (\`base\`, \`cli\`, \`lib\`) or a git URL.`
  - Templates table (after the `cli` row, line ~126): add
    `| \`lib\` | [lgx-template-lib](https://github.com/abogoyavlensky/lgx-template-lib) | Library project skeleton. |`
  - Leave the example block (lines ~116-118) as-is unless a `lib` example reads
    naturally; the `-t cli` example already demonstrates the flag form.

- [ ] **Step 3: Update ARCHITECTURE.md**
  Line ~484: `(built-in: base, cli)` → `(built-in: base, cli, lib)`.

- [ ] **Step 4: Update the landing page**
  `landing/index.html` (line ~159): the copy "built-in `base` or `cli` templates"
  → "built-in `base`, `cli`, or `lib` templates". Update only the prose; leave
  the terminal example block unchanged.

- [ ] **Step 5: Verify help output**
  Run: `make build` then `./<built lg/lgx> help` — or run the repo's usual
  `lgx help` — and confirm the `lgx new` row lists `base`, `cli`, `lib`.
  Expected: the row shows all three built-in names.

- [ ] **Step 6: Commit**
  `git commit -m "Document lib template in help and docs"`

### Task 4: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the unit suite**
  Run: `make test`
  Expected: PASS, including the two new/updated `new_test` assertions.

- [ ] **Step 2: Run the e2e suite (or scenario 106)**
  Run: `bash tests/e2e.sh` (or the project's e2e make target).
  Expected: PASS, including scenario 106's updated assertion.

- [ ] **Step 3: Optional live scaffold smoke test**
  Run: `lgx new demo-lib -t lib` in a scratch dir, confirm it scaffolds without
  error, then remove the scratch dir. (Requires network to clone the template.)
