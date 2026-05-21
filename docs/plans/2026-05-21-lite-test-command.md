# Built-in `lgx test` command

## Status: planned

## Context

Today, running tests in a let-go project means:

1. Add `(run-tests) (when-not test/*test-result* (os/exit 1))` to every
   test file.
2. Wire each file individually into a `Makefile` loop or `run.sh`
   script (see `tests/run.sh` in lgx itself; `Makefile` in
   `../wtr`/`../tiny-cli`).

That's repetitive and pulls `os/exit` into source files that should
contain nothing but `deftest` and fixtures.

Add a built-in `lgx test` subcommand that:

- Walks `test/` for `*_test.lg` and `*_test.cljc` files.
- Loads them into a let-go runtime that already has `:paths` + deps on
  the source path.
- Runs every discovered test and emits a per-`deftest` ✓/✗ report.
- Exits non-zero if any test failed or errored.

After this lands, a test file is exactly:

```clojure
(ns wtr.list-test
  (:require [test :refer [deftest is testing use-fixtures]]
            [wtr.format :as fmt]))

(deftest render-list-empty
  (is (= "(no worktrees)" (fmt/render-list [] "/any/path"))))
```

No trailing `(run-tests)`. No `os/exit`. Same as the other built-in
subcommands (`run`, `build`, `install`), `lgx test` reads `lgx.edn`
and turns it into one `lg` invocation.

## Behavior

`lgx test`:

| State                              | Effect                                                   |
| ---------------------------------- | -------------------------------------------------------- |
| `test/` directory missing          | exits 1: `lgx: no test/ directory in project`            |
| `test/` exists but empty           | prints `No tests found in test/`, exits 0                |
| All discovered tests pass          | per-test ✓ output, summary, exits 0                      |
| Any test fails or errors           | per-test ✗ for failing tests, summary, exits 1           |
| `--verbose` global flag            | trace line includes the generated harness path           |

No CLI args accepted in v1 (run-all only). No filter syntax. No
parallelism. Tests run sequentially in `*registered-tests*` order.

Output shape (the `:point` indentation is two spaces for readability;
colors via the `term` namespace):

```
Running tests in test/...

lgx.config-test
  ✓ validates-paths
  ✓ accepts-git-deps
  ✗ rejects-bad-deps
      FAIL (= :error (:status r))

lgx.path-test
  ✓ resolves-relative
  ✓ absolute-passthrough

5 tests, 12 assertions, 1 failure
FAIL
```

The `FAIL …` follow-up line is whatever let-go's `is` macro already
prints to stdout when an assertion fails (`pkg/rt/core/test.lg:39`).
We don't capture or reformat it in v1 — see *Out of scope*.

Source paths handed to `lg`:

- All resolved `:paths` from `lgx.edn` (same as `cmd-run` /
  `cmd-build`).
- All resolved dep paths (same).
- Plus `<project-root>/test` so test namespaces can `require` each
  other and so the harness can `require` them.

Files matched:

- `test/**/*_test.lg`
- `test/**/*_test.cljc`
- `.clj` is **not** matched. let-go's resolver (`pkg/resolver/...`)
  doesn't load `.clj`. Reconsider if/when the resolver grows that
  extension.

Reserved-task-names in `lgx/config.lg` gains `"test"` — defining
`:tasks {:test ...}` is rejected at parse time, matching the
existing policy for `run`, `build`, etc. Pre-alpha — accepted
breaking change.

## Design

### Where the harness lives

`lg` runs `.lg` files from disk. lgx itself is bundled, so we can't
ship a static `test-runner.lg` and rely on it being on the user's
filesystem. Two choices:

- **A. Generate per invocation.** `lgx test` builds a harness `.lg`
  string from the discovered ns list, writes it to a tempfile (under
  the OS temp dir; deleted on success), then `exec lg <tempfile>`.
- **B. Ship a static harness, pass ns list as args.** Same code on
  every invocation. Needs the harness on disk first — either dropped
  to `$LGX_HOME/cache/` once and reused, or extracted on every run.

Going with **A** because it's the smallest delta to existing
`cmd-run` / `cmd-build`: build args, hand off. No cache directory
contract, no extraction race, no stale-on-upgrade question. The
harness body is a small string template in `lgx/test_runner.lg`.

### How per-`deftest` ✓/✗ is computed

let-go's `test/run-tests` runs everything and only exposes
aggregate counters (`*report-counters*`) and an aggregate boolean
(`*test-result*`). To get per-test marks, the harness bypasses
`run-tests` and iterates `*registered-tests*` itself:

```clojure
(doseq [[ns-sym test-vars] *registered-tests*]
  (println (str ns-sym))
  (doseq [tv test-vars]
    (set! *report-counters* (update *report-counters* :test inc))
    (let [before *report-counters*]
      (try ((deref tv))
           (catch e
             (set! *report-counters* (update *report-counters* :error inc))
             (set! *test-result* false)))
      (let [after *report-counters*
            failed? (or (> (:fail after)  (:fail before))
                        (> (:error after) (:error before)))
            name-str (str (:name (meta tv)))]
        (println " " (if failed? (red "✗") (green "✓")) name-str)))))
```

The let-go `is` macro still prints its own `PASS`/`FAIL …` lines —
fine, they appear under the offending test row and double as the
"what failed" report. v1 doesn't try to suppress that noise.

Each-fixtures (`test/*each-fixtures*`) are applied by composing
them around the test invocation, mirroring what `run-tests` does
(`pkg/rt/core/test.lg:57-69`). `:once` fixtures are unsupported
upstream — out of scope here too.

### Colors

`term/set-fg` + `term/reset-style` (`pkg/rt/term.go`). Green = 2,
red = 1, ANSI 256 palette. No TTY-detection in v1; if the user
pipes output the codes appear inline. Cheap to add later.

### Mapping file path → ns symbol

`test/lgx/config_test.lg` → `lgx.config-test`. Rule:

1. Strip `test/` prefix and `.lg`/`.cljc` suffix.
2. Replace `/` with `.`.
3. Replace `_` with `-` per segment.

Same rule the let-go resolver applies in reverse
(`docs/knowledge-base/let-go-resolver.md`).

## Implementation Steps

<!--
Each task ends with tests + a green test run before the next task.
The ✓/✗ output and exit code are validated via the e2e harness
(tests/e2e.sh) — that's where real end-to-end behavior lives.
-->

### Task 1: Test discovery + ns-mapping helpers

- [x] create `lgx/test_runner.lg` with two pure helpers:
  - [x] `discover-test-files [test-dir]` — recursive walk using
    `os/ls` + `os/stat`, returns sorted vector of absolute paths
    for `*_test.lg` / `*_test.cljc`
  - [x] `path->ns [test-dir abs-path]` — strips `test-dir/` and
    extension, splits on `/`, hyphenates `_` per segment, joins
    with `.`, returns ns symbol
- [x] handle empty / missing `test-dir` (return `[]` for empty;
  raise distinct value for missing so caller can print friendly
  error)
- [x] add `tests/test_runner_test.lg` covering:
  - [x] `path->ns` happy path (`test/foo_test.lg` →
    `foo-test`)
  - [x] `path->ns` nested (`test/lgx/config_test.lg` →
    `lgx.config-test`)
  - [x] `path->ns` `.cljc` extension
  - [x] `discover-test-files` finds `.lg` + `.cljc`, ignores
    non-`_test` files, recurses, returns sorted output (using
    a small fixture under `tests/fixtures/sample-tests/`)
  - [x] `discover-test-files` against a missing dir
- [x] `bash tests/run.sh` (or `lg tests/test_runner_test.lg`)
  — must pass before next task

### Task 2: Harness string template + generator

- [ ] add `harness-source [ns-syms]` in `lgx/test_runner.lg` —
  returns a `.lg` source string with:
  - [ ] `(ns lgx.test-harness ...)` form that `:require`s every
    discovered ns plus `test`, `term`, `os`
  - [ ] the per-test iteration loop sketched in *Design*
  - [ ] color helpers (green ✓ / red ✗ via `term/set-fg` +
    `term/reset-style`)
  - [ ] final summary line: `N tests, M assertions, K failures`
    (drawing from `*report-counters*`)
  - [ ] `(os/exit (if (zero? (+ :fail :error)) 0 1))`
- [ ] add `write-harness! [ns-syms]` — emits the source to a
  tempfile under `os/temp-dir` (or fallback to project root /
  `.lgx/`) and returns the absolute path
- [ ] add tests:
  - [ ] `harness-source` for `[]` ns list compiles to syntactically
    valid let-go (parse via reading it back? — or assert on key
    substrings if a parser API isn't exposed)
  - [ ] `harness-source` for a non-empty list includes the
    expected `:require` entries
- [ ] `bash tests/run.sh` — must pass before next task

### Task 3: Wire `cmd-test` into `lgx.lg`

- [ ] add `cmd-test [forward-args verbose?]` modeled on `cmd-run`
  / `cmd-build` (`lgx.lg:107-159`):
  - [ ] `config/find-project!` → `project-basis` (same as `run`)
  - [ ] resolve `<project-root>/test` absolute path; if missing,
    write `lgx: no test/ directory in project` to stderr and
    `(os/exit 1)`
  - [ ] call `discover-test-files`; if empty, `println "No tests
    found in test/"` and `(os/exit 0)`
  - [ ] compute ns symbols via `path->ns`
  - [ ] call `write-harness!` to materialize the temp file
  - [ ] build source-paths = project paths + dep paths + `test/`
  - [ ] hand off via `runner/exec-lg!` with args `[<harness-path>]`
  - [ ] reject extra forward-args (v1 takes none — print friendly
    error if any provided)
- [ ] add `"test"` to the `case` arm in `dispatch`
  (`lgx.lg:223-239`)
- [ ] extend `base-usage` (`lgx.lg:11-24`) with:
  ```
    lgx test                    Run *_test.lg / *_test.cljc files under test/
  ```
- [ ] add `"test"` to `reserved-task-names` in `lgx/config.lg`
- [ ] extend the existing reserved-name doseq in
  `tests/config_test.lg` to assert `"test"` is rejected
- [ ] `bash tests/run.sh` — must pass before next task

### Task 4: End-to-end fixture run

- [ ] add a self-test scenario in `tests/e2e.sh`:
  - [ ] **N.** Happy path: create a throwaway project with one
    `test/foo_test.lg` containing two passing `deftest`s; assert
    `lgx test` exits 0 and stdout contains the expected `✓`
    lines for each test name
  - [ ] **N+1.** Failure path: one passing + one failing test;
    assert `lgx test` exits 1 and stdout contains `✗` for the
    failing test
  - [ ] **N+2.** Empty dir: `mkdir test/` with nothing inside;
    assert exits 0 with `No tests found in test/`
  - [ ] **N+3.** Missing dir: no `test/` at all; assert exits 1
    with `lgx: no test/ directory in project`
  - [ ] **N+4.** Nested layout: `test/foo/bar_test.lg`; assert
    the ✓ line is printed under ns `foo.bar-test`
  - [ ] **N+5.** `lgx --verbose test`: trace contains the
    generated harness path
- [ ] `bash tests/run.sh` — both unit and e2e must pass

### Task 5: Migrate lgx's own tests onto `lgx test`

- [ ] rename `tests/` → `test/` (Clojure convention; same one
  `lgx test` enforces)
- [ ] move `*_test.lg` files into `test/lgx/` so namespaces
  become `lgx.config-test`, `lgx.path-test`, `lgx.cache-test`
  (update each `(ns …)` form)
- [ ] strip the trailing `(run-tests) (when-not test/*test-result*
  (os/exit 1))` from each test file (this is the boilerplate
  the new command exists to replace)
- [ ] move `test_runner_test.lg` into `test/lgx/` too
- [ ] rewrite the unit-test stage of `tests/run.sh` to just call
  `lgx test` (keep the e2e stage as-is; it tests the bundled
  binary)
- [ ] update the `Makefile` `test` target only if `tests/run.sh`
  references move
- [ ] `make test` — must pass

### Task 6: Docs

- [ ] `docs/ARCHITECTURE.md` — new `### lgx test` subsection under
  Data flow:
  - project basis (same as `run`/`build`)
  - walk `test/` for `*_test.{lg,cljc}`
  - generate harness `.lg`, hand it to `lg` with source-paths
    extended by `test/`
- [ ] `README.md`:
  - add `lgx test` to the Commands list
  - add a short "Writing tests" section showing the minimal
    `deftest`-only file shape (no `(run-tests)`)
  - flip the roadmap `lgx test` entry from `[ ]` to `[x]` if
    present
- [ ] `docs/knowledge-base/let-go-gotchas.md` — append a note:
  test files loaded by `lgx test` must NOT call `(run-tests)` at
  the top level (it'll fire mid-load and skip everything after)
- [ ] `bash tests/run.sh` — final green run

## Technical Details

**Generated harness skeleton** (templated by `harness-source`):

```clojure
(ns lgx.test-harness
  (:require [test :refer [*registered-tests* *report-counters*
                          *test-result* *each-fixtures*]]
            [term :as term]
            [os :as os]
            ;; one entry per discovered test ns:
            [lgx.config-test]
            [lgx.path-test]))

(defn- green [s] (str (term/set-fg 2) s (term/reset-style)))
(defn- red   [s] (str (term/set-fg 1) s (term/reset-style)))

(println "Running tests in test/...\n")

(doseq [[ns-sym test-vars] *registered-tests*]
  (println (str ns-sym))
  (doseq [tv test-vars]
    (set! *report-counters* (update *report-counters* :test inc))
    (let [before *report-counters*]
      (try ((deref tv))
           (catch e
             (set! *report-counters* (update *report-counters* :error inc))
             (set! *test-result* false)
             (println "  ERROR:" e)))
      (let [after *report-counters*
            failed? (or (> (:fail  after) (:fail  before))
                        (> (:error after) (:error before)))]
        (println " " (if failed? (red "✗") (green "✓"))
                 (str (:name (meta tv)))))))
  (println))

(let [c *report-counters*
      asserts (+ (:pass c) (:fail c))
      failures (+ (:fail c) (:error c))]
  (println (str (:test c) " tests, " asserts " assertions, "
                failures " failures"))
  (println (if (zero? failures) "OK" "FAIL"))
  (os/exit (if (zero? failures) 0 1)))
```

**Temp file lifecycle.** Harness is written to `os/temp-dir`/
`lgx-test-<pid>.lg`. We don't actively delete it (let the OS reap
`/tmp`); if `--verbose`, log the path so the user can inspect.

**`*report-counters*` :test counter.** `run-tests` increments
`:test` once per test; we replicate that in the harness loop (the
`set!` before the `before` snapshot above).

**Each-fixtures composition.** Wrap the `(deref tv)` invocation
with `(reduce compose-fixtures default-fixture *each-fixtures*)`
the same way `pkg/rt/core/test.lg:57-69` does. Lift those locals
into the harness body.

## Out of scope (YAGNI)

- Filtering: `lgx test <ns>` / `lgx test <ns>/<deftest>`. v1 runs
  all. Add when we feel the lack.
- Capturing let-go's built-in `is` PASS/FAIL chatter and
  reformatting it. Living with the noise for v1; if we want
  cleaner failure blocks later, the path is either a
  `(binding [*out* ...])` wrapper around each test or a
  `redef`-style swap of `is` in the harness.
- `:once` fixtures (upstream doesn't support them).
- `.clj` extension support (resolver doesn't load it; revisit
  when/if it does).
- `:test-paths` config key — `test/` is hardcoded. Make
  configurable when more than one user wants it.
- TTY detection / `--no-color`. Codes always emitted.
- Parallel test execution. Sequential only.
- A progress bar.
- `lgx test --help` (`lgx help` covers it).
- A separate test-runner package / library — built-in by design,
  per the "no extra tooling needed" principle.

## Verification

- Project with `test/foo_test.lg` containing one `(deftest pass-1
  (is (= 1 1)))`: `lgx test` exits 0, prints `✓ pass-1`.
- Add `(deftest fail-1 (is (= 1 2)))` to the same file: `lgx test`
  exits 1, prints `✓ pass-1` and `✗ fail-1`, summary shows
  `2 tests, 2 assertions, 1 failures`.
- Project with no `test/`: `lgx test` exits 1 with friendly
  message on stderr.
- Project with empty `test/`: exits 0 with `No tests found`.
- Nested test ns (`test/foo/bar_test.lg`): listed under ns
  `foo.bar-test`, ✓ printed.
- `tests/config_test.lg` rejects `:tasks {:test ...}`.
- lgx's own `make test` passes after Task 5 migration.
- `lgx --verbose test` trace shows
  `+ lg -source-paths … /tmp/lgx-test-<pid>.lg`.

## Post-Completion

**Consuming-project migration** (not part of this PR):

- `../wtr`: strip trailing `(run-tests) (when-not test/*test-result*
  (os/exit 1))` from each test file; switch Makefile `test` target
  from the per-file loop to `lgx test`; rename `test/` already
  matches.
- `../tiny-cli`: same migration.
- Communicate via release notes that test files must not call
  `(run-tests)` at top level anymore (the new gotchas-doc entry
  is the durable home for that rule).
