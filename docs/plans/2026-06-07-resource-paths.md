# Resource Paths Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an `lgx.edn` declare resource roots (for `io/resource`) that lgx
passes to `lg` as `-resource-paths`, so resources resolve at `run`/`test` time
and get embedded into the `build` binary.

**Tech Stack:** let-go (`.lg`), the lgx CLI, bash e2e harness.

---

## Background

The unreleased `lg` build adds a flag that parallels `-source-paths`:

```
-resource-paths string
    resource root directories for io/resource, separated by the OS path-list
    separator. Falls back to LG_RESOURCE_PATHS if unset. With -b, resources
    under these roots are embedded in the binary.
```

lgx already threads `-source-paths` from config through a basis to `lg`. This
change adds a second, parallel path-kind — `-resource-paths` — sourced from the
project's own config only.

**This feature requires the unreleased `lg`.** Build and test with it pinned:

```sh
export LG=/Users/andrew/Projects/let-go/lg      # bundling lgx (lg -b)
export LGX_LG=/Users/andrew/Projects/let-go/lg  # the lg lgx shells out to at runtime
```

## Design

### Decisions (locked during brainstorming)

- **Key names.** Top-level `:resource-paths`; in contexts and tasks
  `:extra-resource-paths`. This keeps the existing convention that the
  `extra-` prefix marks an additive overlay (matching `:paths`/`:extra-paths`
  and `:deps`/`:extra-deps`).
- **Scope: project-only.** Resource roots come *only* from the active project's
  `lgx.edn` (top-level + its contexts + its tasks). Dependencies never
  contribute resource roots. (Source paths still pull in dep dirs; resource
  paths do not.)
- **Runner shape.** A parallel positional `resource-paths` parameter on the
  runner fns (not a bundled paths map). Minimal, consistent with the existing
  positional `lib-paths`.
- **Validation-label cleanup.** `validate-paths!` currently hardcodes the
  label `":paths"` in its error text, so `:extra-paths` errors already
  misreport. Give it a `label` argument and pass the real key name at every
  call site. Same idea for the missing-dir warning in `resolve-project-paths`.

### Schema

| Level    | Key                     | Validation rule                               |
| -------- | ----------------------- | --------------------------------------------- |
| top      | `:resource-paths`       | vector of project-relative dirs (no `..`, no leading `/`, non-blank strings) |
| context  | `:extra-resource-paths` | same                                          |
| task     | `:extra-resource-paths` | same                                          |

All three reuse `validate-paths!` (same rule as `:paths`/`:extra-paths`).

### Layering

Resource roots resolve through the same layering as source paths, minus the
dep contribution. Lowest → highest precedence, concatenated then
dedup-keep-first:

```
project :resource-paths
  → task :with contexts' :extra-resource-paths   (in name order)
  → CLI --with contexts' :extra-resource-paths   (in name order)
  → task inline :extra-resource-paths            (highest)
```

For `run`/`build`/`test`/`install` there is no task, so only the project and
the CLI `--with` layers apply.

### Data flow

`config` (read + validate + accessors + `context-overlay`) → `overlay-basis`
(compose layers) → `basis` (resolve project-relative dirs to absolute, warn on
missing) → `cmd-run`/`cmd-build`/`cmd-test`/`cmd-task` → `runner/run-lg!`
(emit `-resource-paths`). `cmd-install` is untouched — it never invokes `lg`.

- `basis` returns a new `:resource-paths` key. Unlike `:paths`, **no dep dirs
  are appended** to it.
- `run-lg!` splices the flag between `-source-paths` and the forwarded args, so
  it shows up in the `--verbose` trace automatically and lands before `-b` on
  the build path (Go's flag parser is order-insensitive there — verified).
- No env var is set by lgx; lgx passes the `-resource-paths` flag directly.

### Behavior

- `lgx run` / task `:run` steps: `io/resource` resolves against the roots.
- `lgx build`: resources under the roots are embedded in the bundled binary
  (verified: a standalone binary resolves `io/resource` from a clean dir).
- `lgx test`: basis resource roots flow through; the `test/` dir is **not**
  auto-added as a resource root (resources stay config-declared, unlike the
  source path where `test/` is auto-added).

### Testing strategy

- **Unit** (`config_test.lg`): schema accept/reject for the three keys, the
  `resource-paths` accessor, and `context-overlay` merging
  `:extra-resource-paths`.
- **E2E** (`e2e.sh`): gated behind a new `supports_resource_paths` helper and
  run with `LGX_LG` pinned to the unreleased `lg`. The read-API-independent
  signal `(some? (io/resource "x"))` is `true` only when the root is on the
  path, which keeps fixtures simple.

## File Structure

- **Modify `lgx/config.lg`** — schema validation, `validate-paths!` label
  param, `:resource-paths`/`:extra-resource-paths` in the allowed-key sets and
  error strings, new `resource-paths` accessor, `context-overlay` returns
  `:resource-paths`.
- **Modify `lgx.lg`** — `basis` + `overlay-basis` thread resource paths; the
  four `cmd-*` forward them; `resolve-project-paths` gains a label.
- **Modify `lgx/runner.lg`** — `resource-paths-flag` helper; `resource-paths`
  param on `run-lg!`/`invoke-lg!`/`exec-lg!`.
- **Modify `test/lgx/config_test.lg`** — unit tests.
- **Modify `tests/e2e.sh`** — `supports_resource_paths` + new scenarios 78–82.
- **Modify `README.md`** — top-level key list, a "Resource paths" subsection,
  `:extra-resource-paths` notes in the Tasks and Contexts sections.
- **Modify `docs/ARCHITECTURE.md`** — data-flow steps and overlay/contexts
  section.

### Commands used throughout

```sh
# Fast unit-test loop (dev mode, no rebuild):
LGX_LG=$LGX_LG $LGX_LG lgx.lg test test/lgx/config_test.lg

# Full suite against the unreleased lg (build + unit + e2e):
LG=$LG LGX_LG=$LGX_LG make test
```

---

## Task 1: Schema, validation, and config accessors (`lgx/config.lg`)

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [ ] **Step 1: Write failing unit tests**
  In `config_test.lg`, add tests:
  - `validate-config!` accepts `{:resource-paths ["resources"]}` (returns it
    unchanged), and accepts `{:resource-paths []}`.
  - `validate-config!` rejects `{:resource-paths "resources"}` (not a vector)
    and `{:resource-paths ["../x"]}` (`..` segment) via the existing `threw?`
    helper.
  - A context with `:extra-resource-paths ["res"]` is accepted; an unknown
    key in a context still rejected (already covered — leave as-is).
  - A task with `:extra-resource-paths ["res"]` (plus a `:do`) is accepted.
  - `context-overlay` returns `:resource-paths`: extend the existing
    `context-overlay-*` tests or add one — a context
    `{:extra-resource-paths ["res"]}` yields `{:resource-paths ["res"] ...}`;
    two contexts concatenate in name order.
  - `config/resource-paths` accessor: returns `["resources"]` for a fixture /
    `[]` when absent. (Mirror the `config/paths` accessor test at
    `config_test.lg:176`. Reuse `tests/fixtures/sample-project` only if you add
    `:resource-paths` there; otherwise assert via a temp file or skip the
    fixture-backed accessor test and cover the accessor through `validate`.)

- [ ] **Step 2: Run tests, verify they fail**
  Run: `LGX_LG=$LGX_LG $LGX_LG lgx.lg test test/lgx/config_test.lg`
  Expected: FAIL — unknown top-level key `:resource-paths`, and
  `context-overlay` missing `:resource-paths`.

- [ ] **Step 3: Implement schema + accessors**
  In `lgx/config.lg`:
  - Give `validate-paths!` a `label` parameter; use it in its two `bad!`
    messages and pass it down to `validate-rel-path!` (replace the hardcoded
    `":paths"`/`":paths entry"`). Update all call sites to pass the right
    label: `":paths"` (top-level), `":extra-paths"` (task + context), plus the
    new `":resource-paths"` / `":extra-resource-paths"`.
  - Add `:resource-paths` to `allowed-top-level`; validate it in
    `validate-config!` with `validate-paths!`.
  - Add `:extra-resource-paths` to `allowed-context-keys` and
    `allowed-task-keys`; validate each with `validate-paths!` in
    `validate-context!` / `validate-task!`.
  - Update the two "Allowed keys: …" error strings (context and task) to list
    the new key.
  - Add a `resource-paths` accessor mirroring `paths` (returns
    `(:resource-paths cfg)` or `[]`).
  - In `context-overlay`, compute and return `:resource-paths` — the
    concatenation of each named context's `:extra-resource-paths`, in name
    order (mirror how `:paths` is built via `mapcat`).

- [ ] **Step 4: Run tests, verify they pass**
  Run: `LGX_LG=$LGX_LG $LGX_LG lgx.lg test test/lgx/config_test.lg`
  Expected: PASS — all config tests green.

- [ ] **Step 5: Commit**
  `git commit -am "Add :resource-paths / :extra-resource-paths to lgx.edn schema"`

---

## Task 2: Thread resource paths through the basis and runner (`lgx.lg`, `lgx/runner.lg`)

These two files change together: the runner gains a parameter that the `cmd-*`
functions must supply, so a green tree requires both edits in one task.

**Files:**
- Modify: `lgx/runner.lg`
- Modify: `lgx.lg`

- [ ] **Step 1: Add the runner flag plumbing**
  In `lgx/runner.lg`:
  - Add a private `resource-paths-flag` mirroring `source-paths-flag`: returns
    `["-resource-paths" (str/join os/path-separator paths)]` when `(seq paths)`,
    else nil.
  - Add a `resource-paths` parameter to `run-lg!`, `invoke-lg!`, and
    `exec-lg!` (place it right after `lib-paths`). In `run-lg!`, splice
    `(resource-paths-flag resource-paths)` into `args` between the
    source-paths flag and `forward-args`. Thread the arg through
    `invoke-lg!`/`exec-lg!` to `run-lg!`.

- [ ] **Step 2: Thread resource paths through the basis**
  In `lgx.lg`:
  - `basis`: add a `raw-resource-paths` parameter. Resolve it to absolute
    project-relative dirs (reuse `resolve-project-paths`; give that helper a
    `label` parameter so the missing-dir warning reads
    `:resource-paths entry not found`). Return the resolved list as
    `:resource-paths` in the basis map. **Do not append dep paths.**
  - `overlay-basis`: compute `raw-resource-paths` =
    `dedup-keep-first(config/resource-paths project ++ (:resource-paths overlay)
    ++ (or (:extra-resource-paths task) []))` and pass it to `basis`.
  - `cmd-run`, `cmd-build`, `cmd-test`, `cmd-task`: destructure
    `:resource-paths` from the basis and forward it to the runner call
    (`exec-lg!` / `invoke-lg!` / `run-lg!`). In `cmd-test`, pass the basis
    `:resource-paths` straight through (the `test/` dir is added only to
    `source-paths`, not to resource paths).
  - Leave `cmd-install` unchanged.

- [ ] **Step 3: Build and run the existing suite (no regressions)**
  Run: `LG=$LG LGX_LG=$LGX_LG make test`
  Expected: PASS — bundle builds, all unit tests and existing e2e scenarios
  pass. Resource paths are absent from every existing fixture, so the new flag
  is omitted (empty → nil) and behavior is unchanged.

- [ ] **Step 4: Manual smoke (resource resolves)**
  Create a temp project with `resources/greeting.txt`, an `m.lg` that prints
  `(some? (io/resource "greeting.txt"))`, and
  `lgx.edn` = `{:main "m.lg" :resource-paths ["resources"]}`. Run
  `LGX_LG=$LGX_LG bin/lgx --verbose run`.
  Expected: trace line includes `-resource-paths`, and the script prints
  `true`. Re-run without `:resource-paths` → prints `false`.

- [ ] **Step 5: Commit**
  `git commit -am "Pass :resource-paths through to lg's -resource-paths flag"`

---

## Task 3: End-to-end tests (`tests/e2e.sh`)

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Add the gate helper**
  Add a `supports_resource_paths` helper next to `supports_source_paths`:
  `"$lg_bin" -resource-paths "" -e '(println :ok)'` succeeds. (Released `lg`
  on `PATH` lacks the flag; the helper skips those scenarios.)

- [ ] **Step 2: Add scenarios (78–82)**
  Each gated on `supports_resource_paths`, using
  `(some? (io/resource "greeting.txt"))` as the signal:
  - **78 — top-level `:resource-paths` on `run`:** project with
    `resources/greeting.txt`, `m.lg` printing the signal,
    `{:main "m.lg" :resource-paths ["resources"]}` → output contains `true`.
  - **79 — `--with` context `:extra-resource-paths`:** resource dir only via a
    `:contexts {:res {:extra-resource-paths ["assets"]}}`; `lgx --with res run`
    → `true`. (Optionally assert that without `--with` it is `false`.)
  - **80 — task inline `:extra-resource-paths`:** a task whose `:run` step
    prints the signal, with `:extra-resource-paths ["assets"]` → `true`.
  - **81 — `build` embeds the resource:** `lgx build` with
    `:resource-paths`, then copy the bundled binary to a clean dir (no
    `resources/` nearby) and run it → `true`. (Mirror the build scenarios'
    bundle-and-run pattern.)
  - **82 — `--verbose run` trace shows the flag:** assert the stderr trace
    contains `-resource-paths` when `:resource-paths` is set.
  Bump the final summary line is automatic (`$PASS_COUNT`).

- [ ] **Step 3: Run e2e, verify PASS**
  Run: `LG=$LG LGX_LG=$LGX_LG make test`
  Expected: PASS — new scenarios pass; nothing else regresses. (Without
  `LGX_LG` pinned, scenarios 78–82 SKIP rather than fail.)

- [ ] **Step 4: Commit**
  `git commit -am "Add e2e coverage for resource paths"`

---

## Task 4: Documentation (`README.md`, `docs/ARCHITECTURE.md`)

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update README**
  - Top-level keys line ("Top-level keys: `:paths`, …") → add
    `:resource-paths`.
  - Add a short "Resource paths" subsection near "Source paths and entrypoint":
    `:resource-paths` lists project-relative resource roots for `io/resource`;
    `lgx run`/`test` make them resolvable and `lgx build` embeds them in the
    binary; missing dirs warn.
  - Tasks section: add `:extra-resource-paths` to the allowed-keys sentence
    ("A task may contain only …") and to the per-task extras subsection.
  - Contexts section: note `:extra-resource-paths` as an allowed context key
    alongside `:extra-paths`/`:extra-deps`, and that it layers like paths.

- [ ] **Step 2: Update ARCHITECTURE.md**
  - `config.lg` / `runner.lg` one-liners (≈ lines 31, 34): mention resource
    paths / `-resource-paths`.
  - Schema sketch (≈ line 54): add `:resource-paths`.
  - `run` step 5–6, `build` step 8, `test` step 9–10: note the parallel
    `-resource-paths` (project-only; embedded by `-b`; not auto-extended with
    `test/`).
  - Contexts / `overlay-basis` section (≈ lines 263–283): note that
    `context-overlay` also returns `:resource-paths` and that the basis layers
    resource roots the same way as source paths, **minus the dep contribution**.
  - Check the `Verify against:` footer still names the right source files.

- [ ] **Step 3: Verify docs build/read consistently**
  Re-read both edited sections; confirm key names and behavior match the
  implemented code (no stale `:paths`-only claims where resources now apply).

- [ ] **Step 4: Commit**
  `git commit -am "Document :resource-paths and :extra-resource-paths"`

---

## Done criteria

- `LG=$LG LGX_LG=$LGX_LG make test` is green (unit + e2e).
- A project with `:resource-paths` resolves `io/resource` under `run`/`test`
  and a built binary resolves it from a clean dir.
- `:extra-resource-paths` works in a context (via `--with` and task `:with`)
  and as task-inline extras, layering project < contexts < CLI < task-inline.
- Path errors report the actual key name; missing resource dirs warn but do
  not abort.
- README and ARCHITECTURE.md describe the feature and stay consistent with the
  source.
