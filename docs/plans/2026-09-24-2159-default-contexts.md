# Default Contexts Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `:dev` and `:test` as default contexts that lgx carries as data, make `lgx test` discover tests through the `:test` context's paths instead of a hardcoded `test/`, and have `lgx info` print its own version, the effective contexts, and which contexts each built-in applies.

**Tech Stack:** let-go (Clojure dialect, `.lg`), `lgx.spec` schema engine, bash e2e harness (`tests/e2e.sh`).

---

## Design

### Why

Three things are implicit today. `test/` is hardcoded in `cmd-test`
(`lgx.lg:824`) and in the test runner's display paths
(`lgx/test_runner.lg:80`). The `:dev`/`:test` conventions live in code
(`auto-with!` call sites in `lgx.lg`) and apply only when a project happens to
define those contexts. Nothing prints what a command will apply. A deps.edn
user expects the tool's defaults to be visible data that a project overrides by
name, the way the Clojure CLI's root deps.edn ships `:test {:extra-paths
["test"]}`.

This plan keeps the conventions exactly as they are (run applies `:dev`; repl
and nrepl apply `:dev` and `:test`; test applies `:test`; build and install
apply nothing) and moves the defaults into data that `lgx info` prints. The
conventions themselves stay fixed and are not configurable: changing what a
context *contains* is the customization point, and an override task such as
`nrepl {:with [:integration] :do {:task lgx:nrepl}}` can add contexts on top.

Out of scope: a `--no-auto` flag to drop a convention context, shipping default
tasks, and any change to `lgx new` templates (they stay bare because the
defaults cover them).

### The defaults

```clojure
;; lgx/config.lg
(def default-contexts
  {:dev  {}
   :test {:extra-paths ["test"]}})

(def auto-contexts
  {"run"   [:dev]
   "repl"  [:dev :test]
   "nrepl" [:dev :test]
   "test"  [:test]})
```

**Defaults are not merged into the loaded config.** `load-config` keeps
returning the user's file verbatim (38 tests in `config_test.lg` assert exact
`{:cfg cfg}` equality, and the raw file and the effective view are different
things). Instead:

- `config/contexts [cfg]` returns `(merge default-contexts (or (:contexts cfg) {}))`.
  A project entry replaces the default of the same name wholesale
  (deps.edn alias semantics).
- `config/default-context? [cfg name]` is true when `name` is in
  `default-contexts` and the project's own `:contexts` does not define it.
- `config/auto-context-names [command]` returns `(get auto-contexts command [])`.
  It replaces `auto-context [cfg name]`, whose "only if defined" branch is
  no longer needed because both names always exist. `auto-context` is
  deleted only once its caller in `lgx.lg` has moved (Task 2): let-go fails
  to load a namespace that references a missing var, so removing it earlier
  would break the `lg lgx.lg test` runs that verify Task 1.
- `with-refs-errors` validates task `:with` entries against the same union
  the accessor returns, so `:with [:dev]` is valid in a project that defines
  no contexts. Its `(defined: ...)` label lists the union.

Everything downstream already reads through `config/contexts`
(`with->overlay!`, `overlay-basis`, completion), so `--with dev` and
`--with test` are always valid, on every command including `install`.

### Missing default paths stay silent

`repl` and `nrepl` apply `:test`, and `overlay-basis` resolves context paths
through `resolve-project-paths`, which warns on every missing entry. A project
without tests would otherwise warn `warning: :paths entry not found: test` on
every REPL start.

- `resolve-project-paths [label project paths optional]` takes a set of
  relative paths that resolve without a warning; the 3-arity form passes
  `#{}`. `basis` gains the same trailing parameter and threads it through.
- `overlay-basis` computes `optional` as the `:extra-paths` of every applied
  context name for which `config/default-context?` is true.
- A user-defined context with a missing path still warns, as today. A user
  who writes `:test {:extra-paths ["test"]}` explicitly has declared it and
  gets the warning when `test/` is absent.

### `lgx test` walks the `:test` paths

`cmd-test` derives its directories from the effective `:test` context, in
declared order, resolved against the project root with `path/join` and
`path/normalize`. All of the checks below run before the basis is built, so
a bad invocation never fetches deps (Scenario 102's guarantee).

1. `:test` has no `:extra-paths` (a project replaced it without any) →
   `lgx: the :test context defines no :extra-paths, so lgx test has nowhere to look`,
   exit 1.
2. None of the declared dirs exists (stat is nil or not a dir) →
   `lgx: no test directory in project (looked for: test/)`, exit 1. The
   list renders each declared relative path with a trailing `/`, comma
   separated. Declared dirs that are missing while at least one exists are
   skipped by *discovery*. The basis resolution that follows is unchanged:
   a missing dir in a user-declared `:test` context still gets the ordinary
   `warning: :paths entry not found: <p>` from `resolve-project-paths`, as
   any declared path does, while a missing default `test/` never warns
   anywhere. Discovery and the warning answer two different questions,
   "where do I look?" and "did you declare something that isn't there?",
   and both answers stand.
3. Walk mode concatenates `discover-test-files` over the existing dirs, in
   order. Each entry's display path is **project-relative**, so the default
   layout still shows `test/foo_test.lg` and a custom one shows
   `tests/foo_test.lg`.
4. Single-file mode validates the positional against the vector of existing
   dirs; the file must sit under one of them, and its namespace maps from
   that dir. Error: `lgx: test file must be under a test path (test/): <path>`
   with the same rendered list.
5. The header and the empty-plan message name the existing dirs, comma
   joined: `Running tests in test/...`, `No tests found in test/`. Single-file
   mode keeps the file's display path as the header.
6. `-source-paths` is `paths ++ [harness-dir]`. The test dirs arrive through
   the `:test` overlay, so the hand-appended `test-dir` goes away. Side
   effect: test dirs now sit with the project's own paths, before dep dirs,
   instead of after them, which matches how `:paths` already shadow libs.

Test runner API changes (`lgx/test_runner.lg`):

- `test-entry [project-root test-dir abs-path]` → `[display ns-symbol]`,
  display being `abs-path` relative to `project-root`. `path->ns` is
  unchanged.
- `validate-single-test-file! [test-dirs user-path project-root]` →
  `{:abs <path> :test-dir <the dir that contains it>}`; the containment
  check succeeds when any dir's normalized prefix matches. Reasons stay
  `:not-found`, `:bad-extension`, `:outside-test-dir`.

### `lgx info`

- Second head line: `lgx <version>` from the `version` def in `lgx.main`.
- Two blocks appended after `go-deps`, rendered from the accessors so they
  cannot drift from behaviour:

```
contexts      :dev {} (default)
              :test {:extra-paths ["test"]} (default)
              :integration {:extra-deps {...}}
applies       run :dev
              repl :dev :test
              nrepl :dev :test
              test :test
```

Contexts print the two defaults first in that fixed order, then the project's
other contexts sorted by name; values are `pr-str`. `applies` iterates
`["run" "repl" "nrepl" "test"]` and joins the names with spaces.

Scenario 126 currently asserts `(default)` is absent from the *whole* output in
explicit-runtime mode; that assertion narrows to the `lg-runtime` line.

### Help and docs

- The `lgx test` help row says
  `Run *_test.lg / *_test.cljc / *_test.clj files under the :test context's paths (test/ by default)`,
  keeping the hand-aligned description column.
- README: the `:contexts` section explains the shipped defaults, replacement
  by name, and `lgx info`; the annotated example's `:test` context becomes
  `{:extra-paths ["test" "test-support"]}`; the commands-table rows for
  `test` and `info` and the `lgx test` details section mention the paths.
- ARCHITECTURE: the `lgx info`, `lgx test` (steps 3 and 8), and Contexts
  sections.

### Release note (for the PR description)

- A project-defined `:test` context now **replaces** the default
  `{:extra-paths ["test"]}`, so it must list its own test dirs. A `:test`
  context that only adds deps or a helper dir needs `"test"` back in its
  `:extra-paths`.
- `--with dev` and `--with test` no longer error in a project that does not
  define those contexts; both always exist.
- `lgx test` error messages changed: `no test directory in project (looked for: ...)`
  and `test file must be under a test path (...)`.
- `lgx info` prints the lgx version, the effective contexts, and which
  contexts each command applies.

### Testing strategy

- Unit (`lg lgx.lg test <file>` from the repo root): config accessors and the
  `:with` union, test-runner multi-dir entries and single-file validation.
  `auto-with!`, `resolve-project-paths`, `overlay-basis`, `cmd-test`, and
  `info-lines` are private to `lgx.main` and are covered by e2e.
- E2E (`make test`): Scenarios 42, 49, 102, and 126 change their assertions;
  new scenarios cover a custom `:test` layout, two test dirs, a single file
  under a custom dir, a `:with [:dev]` task with no contexts defined,
  `--with test` on a bare project, no warning for a missing default `test/`,
  a warning for a missing user-declared `:test` path, and the new `info`
  blocks.

## File Structure

Modify:

- `lgx/config.lg` — `default-contexts`, `auto-contexts`, `contexts` merge,
  `default-context?`, `auto-context-names`; `with-refs-errors` union;
  `auto-context` removed.
- `lgx.lg` — `auto-with!` via the table; `resolve-project-paths` and `basis`
  gain `optional`; `overlay-basis` computes it; `cmd-test` over the `:test`
  paths; `validate-error-line` renders the dir list; `info-lines` version
  and blocks; help row.
- `lgx/test_runner.lg` — `test-entry` and `validate-single-test-file!`
  signatures.
- `test/lgx/config_test.lg`, `test/lgx/test_runner_test.lg` — unit tests.
- `tests/e2e.sh` — changed and new scenarios.
- `README.md`, `docs/ARCHITECTURE.md` — docs in the same change.

No new files.

## Tasks

Run unit tests from the repo root in dev mode, e.g.
`lg lgx.lg test test/lgx/config_test.lg`; the summary ends in `0 failures`
on success and a failing `deftest` prints a `✗` line. Smoke steps use the
bundle (`make build`, then `bin/lgx`) from a throwaway project, because dev
mode resolves `lgx/*.lg` from the cwd. `make test` runs everything.

### Task 1: Default contexts in config

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests**
  In `config_test.lg`: update `accessors-read-cfg-values` (line ~1074) so
  `(config/contexts cfg)` with `:contexts {:dev {}}` equals
  `{:dev {} :test {:extra-paths ["test"]}}`, and the empty-cfg accessor
  (line ~1083) equals `default-contexts`. Add `contexts-user-entry-replaces-default`
  (`:contexts {:test {:extra-deps {...}}}` → the `:test` value has no
  `:extra-paths`), `default-context?-true-when-not-defined`,
  `default-context?-false-when-defined`, `default-context?-false-for-user-name`.
  Replace the three `auto-context-*` tests (line ~1057) with
  `auto-context-names-per-command` (`"run"` → `[:dev]`, `"repl"` and
  `"nrepl"` → `[:dev :test]`, `"test"` → `[:test]`, `"build"` → `[]`).
  Leave `config/auto-context` itself in place for now; `lgx.lg` still calls
  it, and Task 2 deletes it.
  Update `load-rejects-task-with-when-no-contexts-defined` (line ~861): a
  `:with [:dev]` with no `:contexts` now loads; the rejection case uses
  `:with [:integration]` and expects the label `(defined: :dev, :test)`.
  Update `load-rejects-task-with-unknown-context` so its label lists the
  union (defaults plus the defined names, sorted).

- [x] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/config_test.lg`
  Expected: FAIL on the new accessor and label expectations.

- [x] **Step 3: Implement**
  Add `default-contexts` and `auto-contexts` as public defs near the schema
  with a comment explaining they are the tool's shipped defaults and that a
  project entry replaces a default by name. Rewrite `contexts` to merge,
  add `default-context?` and `auto-context-names`. Keep `auto-context` (it
  now always returns `[name]` for the two defaults) until Task 2.
  In `with-refs-errors`, compute `defined` from
  `(set (keys (merge default-contexts (or (:contexts cfg) {}))))` and drop
  the `(no contexts defined)` label branch, which can no longer occur.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/config_test.lg`
  Expected: `0 failures`.

- [x] **Step 5: Commit**
  `git commit -am "config: ship :dev and :test as default contexts"`

### Task 2: Auto-contexts table and silent default paths

**Files:**
- Modify: `lgx.lg`

- [x] **Step 1: Implement**
  `auto-with! [cfg command with verbose?]` looks up
  `(config/auto-context-names command)` and prepends it; the four call sites
  pass `"run"`, `"repl"`, `"nrepl"`, `"test"`. Keep the `+ auto context`
  verbose lines. Now delete `config/auto-context` from `lgx/config.lg`
  (nothing references it any more) and run
  `lg lgx.lg test test/lgx/config_test.lg` to confirm `0 failures`. Give `resolve-project-paths` a 4-arity
  `[label project paths optional]` (3-arity delegates with `#{}`) that skips
  the warning when `(contains? optional p)`. Thread an `optional-paths`
  parameter through `basis` to the `:paths` resolution only (resource paths
  are unaffected). In `overlay-basis`, compute it as the `:extra-paths` of
  every name in `names` for which `(config/default-context? cfg name)` holds,
  and pass it to `basis`. Update the docstrings that describe the layering.
  > Deviation: also collapsed `with->overlay!`'s `(no contexts defined in
  > lgx.edn)` branch, which became dead once `:dev`/`:test` always exist.

- [x] **Step 2: Smoke test**
  Run: `make build`, then in a throwaway dir with `{}` as `lgx.edn` and no
  `test/`:
  `bin/lgx --verbose --with test install`
  Expected: no `entry not found` warning, exit 0. Then write
  `{:contexts {:test {:extra-paths ["test"]}}}` and rerun.
  Expected: `warning: :paths entry not found: test` (the user declared it).

  > Deviation: `lgx install` never resolves `:paths` (it only fetches deps),
  > so the smoke used `bin/lgx --with test info` and `echo | bin/lgx repl`
  > instead; both warn only for the user-declared `test`. Task 5's scenarios 6
  > and 7 use `info` for the same reason.

- [x] **Step 3: Commit**
  `git commit -am "basis: auto-contexts from one table; missing default paths resolve silently"`

### Task 3: Test runner and `lgx test` over the `:test` context paths

`cmd-test` in `lgx.lg` calls `test-entry` and `validate-single-test-file!`,
and `lg lgx.lg test` runs *through* `cmd-test`, so the runner's signatures
and their caller must change in the same task or no unit test can run in
between.

**Files:**
- Modify: `lgx/test_runner.lg`, `lgx.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Write the failing tests**
  Update `test-entry-includes-display-file-and-ns` (line ~50) to the new
  arity `(tr/test-entry root test-dir abs)` and add
  `test-entry-display-is-project-relative-for-custom-dir` (root `/p`, dir
  `/p/tests`, file `/p/tests/a_test.lg` → `["tests/a_test.lg" 'a-test]`).
  Update every `validate-single-test-file-*` test (line ~283 onward) to
  pass a vector of dirs and expect the `{:abs :test-dir}` map. Add
  `validate-single-test-file-picks-the-containing-dir` (two dirs, file under
  the second) and `validate-single-test-file-outside-all-dirs-throws`
  (reason `:outside-test-dir`).

- [x] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/test_runner_test.lg`
  Expected: FAIL inside the updated deftests (wrong arity / wrong return
  shape); the run itself still starts because `cmd-test` is unchanged so far.

- [x] **Step 3: Implement the runner side**
  `test-entry` takes `project-root` first and builds the display with
  `relative-test-path project-root abs-path` (the existing helper already
  strips a `<dir>/` prefix). `validate-single-test-file!` takes `test-dirs`
  and returns the map; the `:outside-test-dir` message becomes
  `test file must be under a test path: <path>`. Update both docstrings and
  the ns header comment.

- [x] **Step 4: Implement the `cmd-test` side**
  In `cmd-test`, replace the `test-dir`/`stat` bindings with: `declared`
  (the effective `:test` context's `:extra-paths`), the "no :extra-paths"
  exit, `test-dirs` (declared entries resolved with `path/join` +
  `path/normalize` and filtered to existing dirs), and the "no test
  directory" exit rendering `declared` as `<p>/` joined by `, `. Add a small
  private `render-test-dirs` used by that error, the header, the empty-plan
  message, and `validate-error-line`'s `:outside-test-dir` branch (which now
  takes the rendered list). Walk mode maps `test-entry project dir abs` per
  dir; single-file mode calls the new `validate-single-test-file!` and uses
  the returned `:test-dir` for the entry. `source-paths` becomes
  `(vec (concat paths [harness-dir]))`. Update the comments that mention
  `test/`.

  > Deviation: walk mode drops a second entry with the same display path, so
  > a declared dir nested in another (`["test" "test/it"]`) doesn't run its
  > files twice under two namespaces; the outer dir's entry wins, matching
  > single-file mode's first-containing-dir rule.
  > Deviation (codex review): `lgx test` now exits 1 when a planned namespace
  > is defined by more than one file (`unit/foo_test.lg` and
  > `integration/foo_test.lg`), since only the first would load and the other
  > file's tests would silently not run. New `test-runner/ns-collisions`;
  > Task 5 gets an e2e scenario for it.

- [x] **Step 5: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/test_runner_test.lg && lg lgx.lg test`
  Expected: `0 failures` for the file, and the whole suite still runs
  through the reworked `cmd-test` with `Running tests in test/...`.

- [x] **Step 6: Smoke test**
  Run `make build` first (the bundle from Task 2 predates these changes).
  With the bundle, in a throwaway project holding `tests/foo_test.lg` (one
  passing `deftest`) and `{:contexts {:test {:extra-paths ["tests"]}}}`:
  `bin/lgx test` → header `Running tests in tests/...`, the summary line,
  exit 0. `bin/lgx test tests/foo_test.lg` → header names the file.
  `bin/lgx test src/x.lg` (create the file) → `must be under a test path (tests/)`.
  Remove `tests/` → `no test directory in project (looked for: tests/)`.
  Write `{:contexts {:test {:extra-deps {}}}}` → `defines no :extra-paths`.
  Run `bin/lgx test` in the lgx repo itself → unchanged output shape,
  `Running tests in test/...`.

  > Note: `lg` here is a mise shim pinned by the repo's config, so running from
  > `/tmp` needed `LGX_LG=$(mise which lg)`.

- [x] **Step 7: Commit**
  `git commit -am "lgx test: discover tests through the :test context's paths"`

### Task 4: `lgx info` version, contexts, and applies

**Files:**
- Modify: `lgx.lg`

- [ ] **Step 1: Implement**
  In `info-lines`, insert `(info-line "lgx" version)` after the `project`
  line. Append a `contexts` block: names in the order `[:dev :test]` then
  the project's other names sorted by `str`, each rendered as
  `<name> <pr-str value>` plus ` (default)` when `config/default-context?`,
  the first through `info-line` and the rest through `info-continuation`.
  Append an `applies` block over `["run" "repl" "nrepl" "test"]` rendering
  `<command> <names joined by space>`. Update the docstring.

- [ ] **Step 2: Smoke test**
  Run `make build` first. With the bundle, in a throwaway project with
  `{:contexts {:integration {:extra-paths ["it"]}}}`:
  `bin/lgx info`
  Expected: an `lgx  0.x.y` line, then `contexts` with `:dev {} (default)`,
  `:test {:extra-paths ["test"]} (default)`, `:integration {:extra-paths ["it"]}`,
  then `applies` with four rows. With `{:contexts {:test {:extra-paths ["tests"]}}}`
  the `:test` line has no `(default)` marker.

- [ ] **Step 3: Commit**
  `git commit -am "info: print the lgx version, effective contexts, and what each command applies"`

### Task 5: Help row and e2e

**Files:**
- Modify: `lgx.lg`, `tests/e2e.sh`

- [ ] **Step 1: Help row**
  Change the `lgx test` description in `command-rows` to
  `Run *_test.lg / *_test.cljc / *_test.clj files under the :test context's paths (test/ by default)`
  and the continuation line's `walk test/` to `walk them`. Keep alignment.

- [ ] **Step 2: Update existing scenarios**
  Scenario 42 (line ~959) and Scenario 102 (line ~2654): expect
  `lgx: no test directory in project (looked for: test/)`. Scenario 49's
  under-test check (line ~1117): expect
  `lgx: test file must be under a test path (test/): src/foo.lg`.
  Scenario 126 (line ~3224): replace the whole-output
  `assert_not_contains "$out" "(default)"` with a check on the
  `lg-runtime` line only, and add assertions that the default-mode output
  contains `lgx  ` followed by the version (`grep '^lgx  '`), `:dev {} (default)`,
  `:test {:extra-paths ["test"]} (default)`, `run :dev`, and `nrepl :dev :test`.
  Scenario 77 (line ~2146) keeps `:typo`/`:nope`; only its `(defined: ...)`
  expectations gain `:dev, :test` if they assert the label.

- [ ] **Step 3: Append new scenarios**
  Continue the numbering after the last scenario in the file. Gate the ones
  that run `lg` on `supports_source_paths` like the other test scenarios.
  1. **Custom test dir**: `{:contexts {:test {:extra-paths ["tests"]}}}` with
     `tests/foo_test.lg` → `lgx test` passes, header
     `Running tests in tests/...`, stdout shows `tests/foo_test.lg`.
  2. **Two test dirs**: `["test" "integration"]` each holding one test →
     both files run, header `Running tests in test/, integration/...`.
  3. **Single file under the second dir**: `lgx test integration/it_test.lg`
     runs only it; `lgx test src/x.lg` errors with `(test/, integration/)`.
  4. **`:test` replaced without paths**: `{:contexts {:test {:extra-deps {}}}}`
     → exit 1, `defines no :extra-paths`.
  5. **`:with [:dev]` with no contexts defined** loads and runs.
  6. **`--with test` on `{}`**: `lgx --with test install` exits 0 with no
     `unknown context` and no `entry not found` warning.
  7. **User-declared `:test` path missing warns**:
     `{:contexts {:test {:extra-paths ["test"]}}}` without `test/` →
     `lgx --with test install` prints `warning: :paths entry not found: test`.
  8. **info marks a replaced `:test`**: with `["tests"]` the `:test` line has
     no `(default)` and the `:dev` line still does.
  9. **Test dir precedes dep dirs**: a dep providing ns `shadow` and
     `test/shadow.lg` defining the same ns; a test requiring `shadow` sees the
     project's copy (`--verbose` shows the test dir before the gitlibs path in
     `-source-paths`).

- [ ] **Step 4: Run the full suite**
  Run: `make test`
  Expected: `All tests passed.`

- [ ] **Step 5: Commit**
  `git commit -am "e2e: default contexts, :test paths, info blocks"`

### Task 6: Documentation

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: README**
  Commands table: `lgx test` row says "under the `:test` context's paths
  (`test/` by default)"; `lgx info` row adds the version, contexts, and
  applies blocks. `lgx test` details (line ~233): the paths rule and the
  two new errors. `:contexts` section (line ~607): a "Shipped defaults"
  paragraph with the two-entry map, replace-by-name, the `lgx info` view,
  and the always-valid `--with dev`/`--with test`; rewrite "Default contexts"
  to say the conventions are fixed and printed; annotated example (line
  ~310) becomes `:test {:extra-paths ["test" "test-support"]}` with a comment
  that a project `:test` replaces the default. Use /writing-clearly.

- [ ] **Step 2: ARCHITECTURE**
  `lgx info` (line ~137): the new lines. `lgx test` steps 3 and 8 (lines
  ~354 and ~422): dirs from the `:test` context, project-relative display,
  no hand-appended test dir. Contexts (line ~617): defaults as data, the
  accessor-level merge and why not load-time, `auto-contexts` as the single
  table, the `optional` path rule. Components table: `lgx/config.lg` line
  mentions the shipped defaults.

- [ ] **Step 3: Commit**
  `git commit -am "docs: default contexts, :test paths, info output"`

## Follow-ups (not in this plan)

- `--no-auto` (or similar) to drop a convention context from one invocation,
  if anyone needs `nrepl` without `:test`.
- Bump the version and put the release note above into the GitHub release.
