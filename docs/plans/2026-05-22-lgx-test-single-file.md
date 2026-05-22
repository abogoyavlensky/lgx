# Single-file `lgx test <file>` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add an optional positional file argument to `lgx test` so users can run a single test file instead of walking the entire `test/` tree.

**Tech Stack:** let-go (`.lg`), bundled lgx CLI, existing test harness generator in `lgx/test_runner.lg`.

---

## Design

### Today

`cmd-test` (`lgx.lg:163-184`) rejects any positional args with
`lgx: test takes no arguments in this version`. Discovery walks
`<project-root>/test` for `*_test.lg` and `*_test.cljc` files via
`test-runner/discover-test-files`, maps each to a
`[display-file ns-symbol]` entry via `test-runner/test-entry`, and
hands the resulting plan to the harness generator. The harness
`:require`s every entry's ns and iterates `*registered-tests*`.

### Change

Allow exactly one optional positional arg:

```
lgx test                     # walk test/, run everything (today's behavior)
lgx test <file>              # run only <file>, validated
lgx test <a> <b> ...         # exit 1: takes at most one argument
```

`<file>` is project-root-relative (matching `lgx run <script>` /
`:main`), must end in `.lg` or `.cljc`, must exist on disk, and must
resolve under `<project-root>/test/`.

### Why this shape

- Project-root-relative matches every other path input in lgx.
- Under-`test/` containment is the simplest contract that keeps both
  the path→ns derivation (`test-entry` strips `test-dir/` to build
  the ns symbol) and the let-go resolver happy (the harness adds
  `test/` to `-source-paths`, so the file must live under that root
  to be loadable via `(:require [<ns>])`).
- The harness layer is unchanged — it already accepts a vector of
  entries. The single-file path just produces a one-entry vector.

### Validation (in `cmd-test`)

Performed after `test-dir` is computed (single source of truth — no
new `"test"` literals added in check logic, to keep a future
`:contexts`/`:extra-paths` swap localized to where `test-dir` is
defined):

1. Resolve the arg to an absolute path. If relative, join against
   the project root.
2. `os/stat` the path. Missing →
   `lgx: test file not found: <user-path>` exit 1.
3. Extension check. Not `.lg`/`.cljc` →
   `lgx: not a test file (expected .lg or .cljc): <user-path>`
   exit 1.
4. Containment check: resolved absolute path must start with
   `<abs test-dir> + sep`. Otherwise →
   `lgx: test file must be under test/: <user-path>` exit 1. The
   string `test/` in the message is a user-facing display detail; the
   *check* uses the `test-dir` variable, so reconfiguring it later
   only touches one site.

Sequencing matters: stat first, so a typo on the filename produces
"file not found" (most useful) rather than "must be under test/".

`<user-path>` in error messages echoes what the user typed, not the
resolved absolute form.

### Validation helper

To keep `cmd-test` thin and unit-testable, extract a pure helper in
`lgx/test_runner.lg`:

```
(validate-single-test-file! test-dir user-path project-root)
  → absolute-path on success
  → throws ex-info with
    {:reason :not-found | :bad-extension | :outside-test-dir
     :path <user-path>}
```

`cmd-test` catches the throw and maps each `:reason` to its stderr
message + `os/exit 1`. Each reason has a unit test for the helper,
and an e2e test for the error wiring.

### Entry construction (no change)

On success, build `(test-runner/test-entry test-dir <abs-path>)` —
the existing helper. It produces `[display-file ns-sym]` where:

- `display-file` is `test/<rel>` (consistent with the walk-mode header
  output)
- `ns-sym` is derived by `path->ns` from the path under `test-dir`.

Then feed `[entry]` into the existing harness writer.

### Harness header parameterization

Today's harness body hardcodes the header line:

```
(println "Running tests in test/...")
```

For the single-file case the header should read `Running tests in
<display-file>...` so the user sees what's actually being run. Make
the header a template parameter in `harness-source`:

- Add a `header` arg (string) to `harness-source`.
- Body template gets a `__TEST_HEADER__` placeholder, substituted at
  generation time the same way `__TEST_ENTRIES__` is today.
- Callers compute the header string and pass it in. Walk path passes
  `"test/..."`; single-file path passes the entry's display-file.

This keeps both modes through one code path. Existing
`harness-source` tests get updated to call the new arity; one new
test asserts the header substring lands in the output.

### CLI / help

`cmd-test` accepts 0 or 1 positional arg. ≥2 → exit 1 with
`lgx: test takes at most one argument`. Replace the existing
"takes no arguments in this version" guard.

`base-usage` (`lgx.lg:11-26`) updates to:

```
  lgx test [file]              Run *_test.lg / *_test.cljc files under test/
                               (one file if given, else walk test/)
```

### `--verbose`

Unchanged behavior: still prints the harness path to stderr. Whether
walk or single-file, the same trace line fires.

### Out of scope (YAGNI)

- Multiple files (`lgx test a.lg b.lg`). Add when needed; the harness
  layer already supports it — only the CLI shape needs to widen.
- Glob/pattern matching (`lgx test 'test/lgx/*.lg'`).
- Single-deftest selection (`lgx test file.lg::test-name`).
- Files outside `test/`. Would require either reading the file's
  `(ns …)` form or a separate ns-derivation rule; revisit if real
  workflows demand it.
- Configurable test root (`:contexts` / `:extra-paths`). Tracked
  separately; design here keeps the `test-dir` variable as the
  single source of truth to ease that later change.

## File Structure

### Modify

- `lgx/test_runner.lg`
  - Add `validate-single-test-file!` pure helper.
  - Add `header` parameter to `harness-source` (templated header
    line via `__TEST_HEADER__`).
  - Update `harness-body` template to include the placeholder.

- `lgx.lg`
  - Update `cmd-test` to accept 0 or 1 positional arg; on 1, call
    `validate-single-test-file!`, build a one-entry plan, and feed
    it through the existing harness path with the per-file header.
  - Pass the appropriate `header` string into `harness-source` /
    `write-harness!` for both walk and single-file modes.
  - Update `base-usage` help line.

- `test/lgx/test_runner_test.lg`
  - Add unit tests for `validate-single-test-file!` (happy +
    three reason branches).
  - Update `harness-source` tests to pass a header arg, add a test
    that the header substring lands in the generated source.

- `tests/e2e.sh`
  - Add five new scenarios after Scenario 44 (45-49).

- `lgx/path.lg`
  - Add a tiny `absolute?` predicate (no current equivalent) used by
    `validate-single-test-file!`.

- `README.md`
  - Update `lgx test` bullet under "Commands" to mention the optional
    file arg.

- `docs/ARCHITECTURE.md`
  - Update `### lgx test` data-flow subsection to describe the
    file-arg branch (walk vs. single-file selection step).

## Implementation Steps

### Task 1: `path/absolute?` predicate

**Files:**
- Modify: `lgx/path.lg`
- Test: `test/lgx/path_test.lg`

- [x] **Step 1: Write the failing tests**
  In `test/lgx/path_test.lg`, add tests asserting:
  - `(path/absolute? "/foo/bar")` → `true`
  - `(path/absolute? "foo/bar")` → `false`
  - `(path/absolute? "")` → `false`
  - `(path/absolute? "/")` → `true`

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL.

- [x] **Step 3: Implement**
  Add to `lgx/path.lg`:
  ```
  (defn absolute? [p]
    (and (string? p)
         (str/starts-with? p os/file-separator)))
  ```

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: add path/absolute? predicate"`

### Task 2: `validate-single-test-file!` helper

**Files:**
- Modify: `lgx/test_runner.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Write the failing tests**
  Add tests in `test/lgx/test_runner_test.lg`:
  - happy path: existing `.lg` file under `test-dir` returns its
    absolute path.
  - happy path: existing `.cljc` file under `test-dir` returns abs
    path.
  - `:not-found` branch: non-existent path throws `ex-info` with
    `{:reason :not-found :path <user-path>}`.
  - `:bad-extension` branch: existing file with `.txt` suffix
    throws `{:reason :bad-extension :path <user-path>}`.
  - `:outside-test-dir` branch: existing `.lg` file located outside
    `test-dir` throws `{:reason :outside-test-dir :path <user-path>}`.
  - relative path: when called with a relative `user-path`, the
    function joins it against the provided `project-root` before
    stat/containment.

  Use a tmpfs-style scratch directory (e.g. `/tmp/lgx-validate-<uuid>`)
  with controlled `test-dir`, file fixtures, and an out-of-tree
  `.lg` file to exercise the outside-test-dir branch.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL (helper not yet defined).

- [x] **Step 3: Implement the helper**
  Add to `lgx/test_runner.lg`:
  ```
  (defn validate-single-test-file!
    "Resolve user-path against project-root, stat it, check extension
     and containment under test-dir. Returns the absolute path on
     success; throws ex-info on any failure."
    [test-dir user-path project-root]
    …)
  ```
  Resolution: if `(path/absolute? user-path)`, use as-is; otherwise
  `(path/join project-root user-path)`.

  Containment check uses `test-dir` (the variable) plus
  `os/file-separator`. Do not introduce new `"test"` string
  literals in this function — the message string can contain
  `test/` as a display hint, but the check itself uses the variable.

  Throw forms:
  ```
  (throw (ex-info "<msg>"
                  {:reason :not-found :path user-path}))
  ```
  …and similarly for `:bad-extension`, `:outside-test-dir`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS, all helper tests green.

- [x] **Step 5: Commit**
  `git commit -m "feat: add validate-single-test-file! helper"`

### Task 3: Parameterize `harness-source` with a header string

**Files:**
- Modify: `lgx/test_runner.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Update existing harness tests**
  Update `harness-source-empty-ns-list-parses`,
  `harness-source-includes-each-ns`, and
  `harness-source-summary-and-exit` in
  `test/lgx/test_runner_test.lg` to call `harness-source` with an
  explicit header argument (e.g. `"test/..."`). Add a new test
  `harness-source-uses-provided-header` asserting that a custom
  header string (e.g. `"test/foo_test.lg..."`) appears in the
  generated source via a `Running tests in <header>` substring
  check.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL (`harness-source` arity mismatch / new substring
  missing).

- [x] **Step 3: Implement the parameterization**
  In `lgx/test_runner.lg`:
  - Change `harness-body` template's literal
    `(println "Running tests in test/...")` to
    `(println "Running tests in __TEST_HEADER__...")`.
  - Update `harness-source` signature to
    `[entries header]` and add a `str/replace` for
    `__TEST_HEADER__` alongside the existing `__TEST_ENTRIES__`
    substitution.
  - Update `write-harness!` signature to
    `[entries version header]` and forward `header` into
    `harness-source`.
  - Pick safe substitution semantics: `header` must not contain the
    literal sequence `__TEST_HEADER__` (it won't in practice — it's
    a display-file string). No escape work needed.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: parameterize test harness header line"`

### Task 4: Wire single-file branch into `cmd-test`

**Files:**
- Modify: `lgx.lg`

- [x] **Step 1: Update `cmd-test` dispatch**
  In `lgx.lg`:
  - Replace the existing "takes no arguments in this version"
    guard with branching on `(count forward-args)`:
    - `0` → walk-mode (today's behavior). Header = `"test/"`.
    - `1` → single-file mode.
    - `>= 2` → write
      `lgx: test takes at most one argument\n` to stderr and
      `(os/exit 1)`.
  - For walk-mode, pass `"test/"` as the header to `write-harness!`.
    The harness body appends `...` after `__TEST_HEADER__`, so the
    rendered line stays `Running tests in test/...` (matches today's
    output exactly).
  - For single-file mode:
    1. Compute `test-dir` (existing line stays).
    2. Stat `test-dir`. If missing (today's check), still error
       with `lgx: no test/ directory in project` first — the
       file argument can't be under a missing root.
    3. Call `test-runner/validate-single-test-file!` (from Task 2)
       inside a `try`/`catch`. On catch, inspect `(:reason (ex-data e))`
       and write the matching stderr line:
       - `:not-found` →
         `lgx: test file not found: <user-path>`
       - `:bad-extension` →
         `lgx: not a test file (expected .lg or .cljc): <user-path>`
       - `:outside-test-dir` →
         `lgx: test file must be under test/: <user-path>`
       Then `(os/exit 1)`.
    4. On success, build a one-entry plan via
       `[(test-runner/test-entry test-dir <abs-path>)]`.
    5. Header for `write-harness!` is the entry's display-file
       (first of the entry tuple).
    6. Source paths and exec are identical to walk-mode.

- [x] **Step 2: Update `base-usage` help text**
  Change the `lgx test` line in `base-usage` (`lgx.lg:11-26`) to:
  ```
  "  lgx test [file]              Run *_test.lg / *_test.cljc files under test/\n"
  "                               (one file if given, else walk test/)\n"
  ```
  Make sure indentation matches the surrounding lines.

- [x] **Step 3: Build lgx and smoke-test against its own tests**

  Build: `make build`
  Run: `make test`
  Expected: PASS — lgx's own walk-mode test suite still works
  unchanged.

  Also run manually from the lgx project root:
  ```
  lg lgx.lg test test/lgx/path_test.lg
  ```
  Expected: only `path-test`'s `deftest`s run; header line reads
  `Running tests in test/lgx/path_test.lg...`; exit 0.

  And error scenarios:
  ```
  lg lgx.lg test test/lgx/nope_test.lg
  lg lgx.lg test test/lgx/path_test.lg test/lgx/cache_test.lg
  lg lgx.lg test src/main.lg     # if you have any .lg outside test/
  ```
  Each should print the expected stderr and exit 1.

- [x] **Step 4: Commit**
  `git commit -m "feat: accept optional file arg in lgx test"`

### Task 5: End-to-end coverage

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add scenarios after Scenario 44**
  In `tests/e2e.sh`, append:

  - **Scenario 45: lgx test single file happy path.** Gated on
    `supports_source_paths`. Create a throwaway project with two
    test files: `test/foo_test.lg` (one passing `deftest pass-foo`)
    and `test/bar_test.lg` (one passing `deftest pass-bar`). Run
    `lgx test test/foo_test.lg`. Assert exit 0, stdout contains
    `Running tests in test/foo_test.lg`, contains `pass-foo`, and
    does **not** contain `pass-bar` (proves discovery was bypassed).

  - **Scenario 46: lgx test missing file.** Project with `test/`
    dir present. Run `lgx test test/nope.lg`. Assert exit 1, stderr
    contains `lgx: test file not found: test/nope.lg`. No
    `supports_source_paths` gate needed (no `lg` exec).

  - **Scenario 47: lgx test wrong extension.** Project with
    `test/foo.txt` (touched empty). Run `lgx test test/foo.txt`.
    Assert exit 1, stderr contains
    `lgx: not a test file (expected .lg or .cljc): test/foo.txt`.

  - **Scenario 48: lgx test outside test/.** Project with
    `src/foo.lg` (touched empty) and an empty `test/` dir. Run
    `lgx test src/foo.lg`. Assert exit 1, stderr contains
    `lgx: test file must be under test/: src/foo.lg`.

  - **Scenario 49: lgx test too many args.** Project with `test/`
    dir present. Run `lgx test a.lg b.lg`. Assert exit 1, stderr
    contains `lgx: test takes at most one argument`. No
    `supports_source_paths` gate needed.

  Follow the existing pattern: `mktemp -d` for project + LGX_HOME,
  `cat > … <<EOF` to seed files, `assert_contains` / `assert_eq`
  for assertions, `rm -rf` to clean up.

- [x] **Step 2: Run the e2e suite**
  Run: `make build && bash tests/e2e.sh`
  Expected: all assertions including 45–49 pass.

- [x] **Step 3: Commit**
  `git commit -m "test: e2e scenarios for lgx test <file>"`

### Task 6: Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: README**
  In the Commands section, update the `lgx test` bullet to mention
  the optional file argument. Keep the existing description for the
  walk case; add one short sentence: with `<file>`, only that file's
  tests run. Validation summary in one line:
  "`<file>` is project-root-relative, must end in `.lg` or `.cljc`,
  and must live under `test/`."

- [x] **Step 2: ARCHITECTURE**
  In the `### lgx test` subsection, update step 5 of the data flow
  to: if a positional file arg is provided, validate it (exists,
  `.lg`/`.cljc`, under `test/`) and use it as the sole entry;
  otherwise walk `test/`. Note the validation reasons and the
  matching error lines. Step 7's harness header is now per-entry
  (`Running tests in <display-file>...`) in the single-file case.

  Also update the "accepts no positional args in v1" paragraph at
  the end of the `### lgx test` section to reflect the new
  contract: 0 or 1 positional arg; ≥2 is an error.

- [x] **Step 3: Final green run**
  Run: `make test && make build && bash tests/e2e.sh`
  Expected: all unit tests and e2e scenarios pass.

- [x] **Step 4: Commit**
  `git commit -m "docs: lgx test <file> argument"`

## Verification

- `lgx test` (no arg) in the lgx repo still walks `test/` and runs
  every file — unchanged behavior.
- `lgx test test/lgx/path_test.lg` runs only `path-test`'s
  `deftest`s; header reads `Running tests in test/lgx/path_test.lg`;
  exit 0.
- `lgx test test/lgx/nope_test.lg` → stderr
  `lgx: test file not found: test/lgx/nope_test.lg`, exit 1.
- `lgx test README.md` → stderr
  `lgx: not a test file (expected .lg or .cljc): README.md`,
  exit 1.
- `lgx test lgx.lg` (existing `.lg` outside `test/`) → stderr
  `lgx: test file must be under test/: lgx.lg`, exit 1.
- `lgx test a.lg b.lg` → stderr
  `lgx: test takes at most one argument`, exit 1.
- `lgx --verbose test test/lgx/path_test.lg` → stderr still includes
  the harness path; stdout header includes the per-file display
  string.
- From a subdirectory: `cd test && lgx test test/lgx/path_test.lg`
  (path arg relative to project root) still resolves and runs the
  file — confirms `validate-single-test-file!` uses the project
  root, not `os/cwd`, for relative-path resolution.
- `make test && bash tests/e2e.sh` green.

## Post-Completion

- Bump `version` in `lgx.lg` (separate routine commit per recent
  history — `e013fab Bump lg version`).
- No consumer-side migration needed: walk-mode is the default and is
  byte-identical to today (modulo the header substitution change,
  which renders the same string).

## Implementation Summary (status: completed)

All 6 tasks landed across 8 commits on `test-cmd`:

- `0e81f2a feat: add path/absolute? predicate`
- `7f85bec feat: add validate-single-test-file! helper`
- `73ee624 fix: normalize paths in validate-single-test-file!
  containment check` (codex-flagged path-traversal fix; added
  `path/normalize`)
- `5243cc1 feat: parameterize test harness header line`
- `fd506df fix: pr-str harness header to escape special chars`
  (codex-flagged string-literal escaping)
- `bd72418 feat: accept optional file arg in lgx test`
- `cdae96d test: e2e scenarios for lgx test <file>` (scenarios 45-49)
- `b7c7266 docs: lgx test <file> argument`

Final test totals: 139 unit tests / 197 assertions, 113 e2e
assertions — all green via `make test`.

### Notes / deviations

- **Codex per-task review** caught two real issues during execution
  (path normalization, harness string-literal escaping); both fixed
  with follow-up commits + tests in the same task.
- **Scope addition:** `path/normalize` was added to `lgx/path.lg`
  (not in the original plan) to support safe `.`/`..` resolution in
  the containment check. Five unit tests added for it.
- **Pre-existing test-runner reliability**: when a unit-test file
  fails to compile, the harness still exits 0 (the compile error
  prints after the summary line). Out of scope for this PR but worth
  tracking. The TDD red-step in Task 1 relied on visually checking
  for the compile-error stderr rather than a non-zero exit.
- **Env**: this environment's system `lg` lacks `-source-paths`;
  used `LGX_LG=/Users/andrew/Projects/let-go/lg` (and `LG=...` for
  `make build`) throughout.
