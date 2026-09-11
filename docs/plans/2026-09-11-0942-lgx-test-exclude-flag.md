# `lgx test --exclude` Implementation Plan (completed)

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `lgx test` skip named test namespaces via a repeatable `--exclude <ns,...>` flag.

**Tech Stack:** let-go (`.lg`), bundled lgx CLI, existing test harness generator in `lgx/test_runner.lg`, bash e2e suite in `tests/e2e.sh`.

---

## Design

### Today

`cmd-test` (`lgx.lg`, around line 778) accepts 0 or 1 positional arg.
With none it walks `test/` via `test-runner/discover-test-files`, maps
each file to a `[display-file ns-symbol]` entry with
`test-runner/test-entry`, and hands the vector to
`test-runner/write-harness!`. With one arg it validates the file and
builds a one-entry vector. There is no way to skip a namespace short of
deleting or renaming its file.

Discovery currently runs *after* the basis is built (`auto-with!`,
`overlay-basis`, `apply-runtime!`). Only the `test/`-exists check runs
before it.

### Change

Add a command-local flag, parsed like `build --target`:

```
lgx test --exclude lgx.slow-test                       # skip one ns
lgx test --exclude a.b-test,c.d-test                   # comma list
lgx test --exclude a.b-test --exclude c.d-test         # repeatable, same result
lgx test --exclude                                     # exit 1: value required
lgx test --exclude nope-test                           # exit 1: names no test ns
lgx test test/foo_test.lg --exclude bar-test           # exit 1: cannot combine
```

`--exclude` may appear anywhere after `test`. Its value is a
comma-separated list of test namespace names, trimmed, blanks dropped,
repeatable and accumulating (same rules as `--with`). Names are exact
namespace symbols as printed by the run (e.g. `lgx.config-test`). No
globs or prefixes.

### Rules

1. **Missing or blank value** →
   `lgx: --exclude requires a comma-separated list of test namespaces`
   on stderr, exit 1.
2. **More than one positional** → existing
   `lgx: test takes at most one argument`, exit 1.
3. **Positional file plus `--exclude`** →
   `lgx: --exclude cannot be combined with a test file`, exit 1. The
   filter applied to a one-file plan can only yield nothing to run, so
   the combination is a user mistake worth naming.
4. **Excluded name matches no discovered namespace** →
   `lgx: --exclude names no test namespace: <ns>` (one line per unmatched
   name, in the order given), exit 1. Strict, like task arity and
   `--with`, so a typo fails loud instead of silently running the test
   the user meant to skip.
5. **Every discovered file excluded** → print `All test files excluded`
   to stdout, exit 0. Mirrors the existing `No tests found in test/`
   path for an empty plan.
6. **Otherwise** the harness runs the remaining entries exactly as today.
   The `Running tests in test/...` header is unchanged.

Rule 4 is checked **before** either empty-plan exit. The filter runs on
the discovered entries even when discovery found nothing, so
`lgx test --exclude nope-test` in an empty `test/` fails with rule 4
rather than printing `No tests found in test/` and exiting 0. Order:
discover → filter → unmatched? exit 1 → nothing discovered? `No tests
found in test/` exit 0 → everything excluded? `All test files excluded`
exit 0.

### Ordering: cheap validation before the basis

Rules 1–4 and the empty checks run **before** `auto-with!` /
`overlay-basis` / `apply-runtime!`, extending the existing
"cheap validation first" comment in `cmd-test` (a bad invocation never
fetches deps). This moves discovery and single-file validation ahead of
the basis build. Both depend only on `project` and `test-dir`, so the
reorder is safe. Discovery must still come after the `test/`-exists
check, which is what makes `discover-test-files` safe to call.

### Verbose trace

Under `--verbose`, when at least one namespace is excluded, print
`+ excluded: a.b-test, c.d-test` to stderr next to the existing
`+ test runner: <path>` line.

### Components

- `lgx/cli.lg` — `parse-test-args`, pure:

  ```clojure
  (cli/parse-test-args ["--exclude" "a-test,b-test" "test/x_test.lg"])
  ;; => {:exclude ['a-test 'b-test] :positionals ["test/x_test.lg"]}
  ```

  Throws `ex-info` with the rule-1 message on a missing/blank value.
  Positional-count and file/exclude conflict checks stay in `cmd-test`
  so their messages live next to the other `cmd-test` errors.

- `lgx/test_runner.lg` — `exclude-entries`, pure:

  ```clojure
  (tr/exclude-entries entries excluded)
  ;; entries:  [[display-file ns-sym] ...] from test-entry
  ;; excluded: [sym ...] from parse-test-args
  ;; => {:entries [kept entries, original order]
  ;;     :unmatched [excluded syms that matched no entry, original order]}
  ```

  Matching is `=` on the entry's ns symbol. Duplicate excluded names are
  fine; a name counts as matched if any entry has it.

- `lgx.lg` `cmd-test` — parse, validate (rules 1–3), discover or
  validate the single file, filter, validate (rule 4), handle empty
  plans, then build the basis and run as today. Help row for `test`
  updated.

- No completion change: `lgx/completion.lg` offers no flag completion
  for any command by design.

### Docs (same commit as the code)

- `README.md`: the command table row for `lgx test` and the
  "`lgx test` details" section.
- `docs/ARCHITECTURE.md`: the "`lgx test`" section — step 5 (file
  selection) gains the exclude filter and its ordering, and the closing
  "accepts 0 or 1 positional arg" paragraph documents the flag and its
  error messages.

## File Structure

- Modify: `lgx/cli.lg` — add `parse-test-args` next to `parse-build-args`.
- Modify: `lgx/test_runner.lg` — add `exclude-entries` after `test-entry`.
- Modify: `lgx.lg` — `cmd-test` wiring, `command-rows` help text.
- Modify: `test/lgx/cli_test.lg` — parser unit tests.
- Modify: `test/lgx/test_runner_test.lg` — filter unit tests.
- Modify: `tests/e2e.sh` — scenarios 50–53 after scenario 49.
- Modify: `README.md`, `docs/ARCHITECTURE.md` — same commit as Task 3.

## Tasks

### Task 1: `parse-test-args` in `lgx/cli.lg`

**Files:**
- Modify: `lgx/cli.lg`
- Test: `test/lgx/cli_test.lg`

- [x] **Step 1: Write the failing tests**
  Add a `;; parse-test-args` section after the `parse-build-args` tests,
  following their style. Cover:
  - no flags: `["test/x_test.lg"]` → `{:exclude [] :positionals ["test/x_test.lg"]}`;
    `[]` → `{:exclude [] :positionals []}`.
  - single name: `["--exclude" "a-test"]` → `{:exclude ['a-test] :positionals []}`.
  - comma list with spaces and blanks: `"a-test, b-test,,"` → `['a-test 'b-test]`.
  - repeated flag accumulates in order.
  - flag anywhere: `["test/x_test.lg" "--exclude" "a-test"]` keeps the positional.
  - two positionals are both returned (the count check is `cmd-test`'s job).
  - missing value (`["--exclude"]`) throws; blank value (`["--exclude" " , "]`) throws.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && bin/lgx test test/lgx/cli_test.lg`
  Expected: FAIL — the new deftests error with an unresolved `cli/parse-test-args`.

- [x] **Step 3: Implement `parse-test-args`**
  Add after `parse-build-args` in `lgx/cli.lg`. Define a private
  `exclude-error` string with the rule-1 message and a private
  `parse-exclude-value` mirroring `parse-with-value` but producing symbols
  (`mapv symbol`). Loop over tokens like `parse-build-args`: `--exclude`
  consumes the next token; every other token is a positional, in order.
  Docstring: names the return shape and the throw.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && bin/lgx test test/lgx/cli_test.lg`
  Expected: PASS, summary line ends in `0 failures`.

- [x] **Step 5: Commit**
  `git commit -m "Add parse-test-args for lgx test --exclude"`

### Task 2: `exclude-entries` in `lgx/test_runner.lg`

**Files:**
- Modify: `lgx/test_runner.lg`
- Test: `test/lgx/test_runner_test.lg`

- [x] **Step 1: Write the failing tests**
  Add a `;; exclude-entries` section after the `test-entry` test. Use
  literal entries such as `[["test/a_test.lg" 'a-test] ["test/b_test.lg" 'b-test]]`.
  Cover:
  - empty excluded list returns all entries and `:unmatched []`.
  - one match drops that entry, keeps order, `:unmatched []`.
  - unmatched name is reported in `:unmatched`, entries untouched.
  - mixed matched and unmatched names: only the unmatched one is reported.
  - several unmatched names come back in the order given.
  - a duplicated excluded name (`['a-test 'a-test]`) drops the entry once
    and reports nothing unmatched.
  - empty entries with a non-empty excluded list reports every name unmatched.
  - all entries excluded yields `:entries []`.
  - `:entries` is a vector.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && bin/lgx test test/lgx/test_runner_test.lg`
  Expected: FAIL with unresolved `tr/exclude-entries`.

- [x] **Step 3: Implement `exclude-entries`**
  Add after `test-entry`. Build the set of discovered ns symbols from
  `(map second entries)`; `:unmatched` is `excluded` filtered to names not
  in that set (`vec`, original order); `:entries` is entries filtered to
  those whose ns is not in `(set excluded)`. Docstring per the Design
  fragment.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && bin/lgx test test/lgx/test_runner_test.lg`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Add exclude-entries filter for the test plan"`

### Task 3: Wire `cmd-test` and update help

**Files:**
- Modify: `lgx.lg` (`cmd-test`, `command-rows`)
- Modify: `README.md`, `docs/ARCHITECTURE.md`
- Test: `tests/e2e.sh`

> Deviation: scenarios 50–53 were already taken by `lgx new`, so the new
> ones were inserted after scenario 49 as **49b–49e** (the file's existing
> convention for inserted scenarios, cf. 4b, 35c, 67b), keeping them next
> to the other `lgx test` scenarios.

- [x] **Step 1: Write the failing e2e scenarios**
  Append scenarios 50–53 after scenario 49 in `tests/e2e.sh`, following
  scenario 45 (two files `foo_test.lg` / `bar_test.lg` with `pass-foo` /
  `pass-bar`) and scenario 49 (project with an empty `test/`, no lg
  needed). Wrap the ones that run tests in `if supports_source_paths`.
  - **50: `--exclude` happy path.** `"$LGX" test --exclude bar-test`
    → rc 0, output contains `pass-foo`, not `pass-bar`, contains
    `Running tests in test/`. Also check the repeated form
    `--exclude bar-test --exclude foo-test` prints `All test files excluded`
    and exits 0.
  - **51: unknown namespace.** `"$LGX" test --exclude nope-test` → rc 1,
    output contains `lgx: --exclude names no test namespace: nope-test`.
    Run it twice: once in a project whose `test/` has one real test file,
    and once in a project with an empty `test/` (must still be rc 1 and
    must not print `No tests found in test/`). Neither run needs lg, since
    the error fires before the basis and harness.
  - **52: missing value.** `"$LGX" test --exclude` in an empty-`test/`
    project → rc 1, output contains
    `lgx: --exclude requires a comma-separated list of test namespaces`.
  - **53: combined with a file.** `"$LGX" test test/foo_test.lg --exclude bar-test`
    → rc 1, output contains `lgx: --exclude cannot be combined with a test file`.
    Create the file so the error is unambiguously the conflict.

- [x] **Step 2: Run e2e to verify the new scenarios fail**
  Run: `make build && bash tests/e2e.sh 2>&1 | tail -30`
  Expected: scenario 50 fails (`--exclude` is treated as a second positional →
  `test takes at most one argument`), or 52/53 fail on their messages.

- [x] **Step 3: Rewire `cmd-test`**
  In `lgx.lg`:
  - Replace the leading count check with a parse:
    `(cli/parse-test-args forward-args)` inside a `try` that writes
    `(ex-message e)` plus newline to stderr and exits 1 (same shape as the
    `parse-build-args` call site around line 660). Bind `exclude` and
    `positionals`.
  - Keep `lgx: test takes at most one argument` on `(> (count positionals) 1)`.
  - Add rule 3: single file and non-empty `exclude` → the conflict message, exit 1.
  - After the `test/`-exists check and **before** `auto-with!`, compute
    `entries`: single-file path unchanged; walk path discovers, maps every
    file to an entry (possibly an empty vector), then applies
    `test-runner/exclude-entries` **before** any empty check. If
    `:unmatched` is non-empty, write one
    `lgx: --exclude names no test namespace: <ns>` line per name and exit 1.
    Then, if nothing was discovered, print `No tests found in test/` and
    exit 0 (existing behaviour); else if the filtered `:entries` is empty,
    print `All test files excluded` and exit 0.
  - Move the basis build (`auto-with!`, `overlay-basis`, `apply-runtime!`)
    below that, then continue as today (`header`, `write-harness!`, run).
  - Under `verbose?`, when `(seq exclude)`, write
    `+ excluded: <names joined by ", ">` to stderr beside the harness-path line.
  - Update the comment above the `test/` check so it describes all the
    pre-basis validation (flags, file, discovery, exclusions).
  - Update `command-rows`: the `test` row becomes
    `lgx test [file] [--exclude <ns,...>]` with the second line mentioning
    that excluded namespaces are skipped. Keep the row hand-aligned to
    `doc-col` (31); if the left side exceeds the column, follow the existing
    two-space overflow rule in `task-line` and check `bin/lgx help` output.

- [x] **Step 4: Run the whole suite**
  Run: `make test 2>&1 | tail -40`
  Expected: unit tests `0 failures`, all e2e scenarios pass, `All tests passed.`

- [x] **Step 5: Manual check**
  Run from the repo root:
  `bin/lgx test --exclude lgx.cli-test,lgx.test-runner-test` (the two
  files are skipped; summary is green) and
  `bin/lgx --verbose test --exclude lgx.cli-test 2>&1 | grep excluded`
  (prints `+ excluded: lgx.cli-test`).

- [x] **Step 6: README**
  Docs change in the same commit as the code (repo rule in `AGENTS.md`).
  - Command table row: `lgx test [file] [--exclude <ns,...>]`, description
    adds "`--exclude` skips the named test namespaces (repeatable, comma-separated)."
  - "`lgx test` details" section: one short paragraph with the example
    `lgx test --exclude lgx.slow-test,lgx.net-test`, stating names are
    exact namespace symbols, an unknown name is an error, and the flag
    cannot be combined with a single file. Fix the sentence that says the
    harness runs "every `deftest`".

- [x] **Step 7: ARCHITECTURE**
  In the "`lgx test`" section of `docs/ARCHITECTURE.md`:
  - Step 3 (or a new step before the basis) notes that `--exclude` is
    parsed and the file/exclude conflict rejected before the basis build.
  - Step 5: after the walk, "apply `--exclude`: drop entries whose ns
    symbol is named; any name matching no entry → `lgx: --exclude names no
    test namespace: <ns>` + exit 1 (checked before the empty-plan exits);
    all entries dropped → `All test files excluded` + exit 0." State that
    selection now runs before step 4's basis build.
  - Closing paragraph: document the flag syntax, the three error messages,
    and the `+ excluded:` verbose line.

- [x] **Step 8: Re-read and commit**
  Run `git diff --stat`, re-read both doc sections once for stale claims,
  then commit code, tests, and docs together:
  `git commit -m "lgx test --exclude: skip named test namespaces"`

---

## Status: completed (2026-09-11, branch `lgx-test-exclude-flag`)

**Implemented** in three commits:
- `0bf2290` `cli/parse-test-args` + unit tests (rule 1, positional split).
- `d2a9999` `test-runner/exclude-entries` + unit tests (order-preserving
  filter, `:unmatched` reporting).
- `a7f5c45` `cmd-test` rewired (parse → rules 2–3 → `test/` check →
  discover/single-file → filter → rule 4 → empty-plan exits → basis →
  run), `+ excluded:` verbose line, help row, e2e scenarios 49b–49e,
  README and ARCHITECTURE updated in the same commit.

**Verification:** `make test` green (604 unit tests / 937 assertions,
332 e2e assertions). Manual check from the repo root and a scratch
project exercised all six invocation shapes from the Design section;
each produced the specified message and exit code. Codex reviewed each
commit: no actionable findings.

**Issues encountered:** none in the work itself. Pre-existing, untouched:
`cljfmt check` flags `test/lgx/cli_test.lg` (ns require order, `lgx new`
map layout) and `make lint` warns on `clean.lg`/`gobuild.lg`.

**Deviations:**
- e2e scenarios added as **49b–49e** instead of 50–53 (those numbers
  were already `lgx new` scenarios; the file uses letter suffixes for
  inserted scenarios).
- Help row uses the two-space overflow form on one line
  (`lgx test [file] [--exclude <ns,...>]  Run ...`), as the plan's
  `task-line` rule directs, since the left side exceeds `doc-col`.

**What the plan could have specified better:** the e2e scenario numbers
were stale — a plan should cite the highest existing scenario or say
"insert with a letter suffix" rather than pin numbers.
