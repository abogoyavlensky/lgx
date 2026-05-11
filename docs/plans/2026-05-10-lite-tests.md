# Test suite for lgx — unit + hermetic e2e + CI

## Context

lgx ships with no automated tests. The "Running tests" question has come
up while iterating on output behavior (`lgx install` / `lgx run`), and
every regression is currently caught by hand. We want fast unit feedback
for pure logic and a hermetic e2e suite that exercises the public
commands (`install`, `run`, `version`, `help`) against the bundled
binary, plus a CI job that runs both on every push and PR.

Pattern reference: [`nooga/lgcr`](https://github.com/nooga/lgcr) —
another bundled-`lg` CLI tool. lgcr splits tests into
`tests/lib_test.lg` (unit, embedded `test` ns) and `tests/e2e.sh`
(driving the bundle). We follow the same split.

let-go's embedded `test` namespace (`(:require [test :refer [deftest
is testing run-tests]])`) is the framework — same surface as
`clojure.test`.

## Layout

```
tests/
  config_test.lg   # unit: lgx.config validation + parsing
  cache_test.lg   # unit: lgx.cache URL parsing, coord-dir, cached path of ensure-lib!
  e2e.sh          # public-command coverage against bin/lgx
  run.sh          # orchestrator: build → unit → e2e
  fixtures/       # static fixtures (sample lgx.edn for find-project! walk-up)
.github/workflows/
  test.yml        # CI: install lg, make test
```

`make test` is the single entry point; it shells out to `tests/run.sh`.

## Source changes to enable testing

Three small changes, defensible on their own.

### 1. Make three pure helpers public

Drop the `-` from:

- `lgx.config/validate-config!`
- `lgx.cache/parse-git-url`
- `lgx.cache/coord-dir`

let-go has no `(var ns/private)`, `#'ns/private`, or `ns-resolve` —
the compiler rejects references to private vars before reflection can
intervene. Verified with a 3-line probe. These helpers are stateless;
the public-surface cost is negligible.

`validate-coord!`, `home-dir`, `gitlibs-root` stay private (tested
indirectly via the public entry points).

### 2. Extend `parse-git-url` to accept `file://`

Hermetic e2e uses a local bare git repo as the "remote" so tests need
no network. Required behavior:

- `file:///tmp/foo.git` parses cleanly.
- Cache key: `_local/<parent-dir-basename>/<repo>/<sha>`. The `_local`
  sentinel never collides with a real hostname.
- `https://…` URLs unchanged.
- `git@host:owner/repo` (ssh) still rejected.

Regex changes from `^https?://([^/]+)/([^/]+)/([^/]+)$` to admit
`file` as a scheme and allow an empty host segment for `file://`.

### 3. No other production changes

`runner.lg`, `cmd-*` fns, `main`, README, AGENTS.md stay as they are.

## Unit tests

### `tests/config_test.lg` (`ns lgx.config-test`)

```clojure
(ns lgx.config-test
  (:require [lgx.config :as config]
            [test :refer [deftest is testing run-tests]]))

(deftest validate-config-accepts-valid-deps …)
(deftest validate-config-rejects-non-map-top-level …)
(deftest validate-config-rejects-unknown-top-level-key …)
(deftest validate-config-rejects-deps-not-a-map …)
(deftest validate-config-rejects-coord-missing-url …)
(deftest validate-config-rejects-coord-without-sha-or-tag …)
(deftest validate-config-accepts-tag-only-coord …)
(deftest coords-empty-deps-returns-empty-vec …)
(deftest coords-reads-and-parses-fixture …)   ; tests/fixtures/sample-lgx.edn

(run-tests)
(when-not test/*test-result* (os/exit 1))
```

`find-project!` is harder to unit-test (walks `(os/cwd)`, `os/exit`s on
failure). Skipped here; e2e covers walk-up by running `lgx install`
from a nested subdir.

Assertion style for thrown errors: `(try (config/validate-config! bad)
:no-throw (catch e :threw))` with `(is (= :threw …))`, since let-go's
`is` may not have a `thrown?` matcher. Final form verified against
let-go stdlib during implementation.

### `tests/cache_test.lg` (`ns lgx.cache-test`)

```clojure
(deftest parse-git-url-https-with-and-without-dotgit …)
(deftest parse-git-url-file-uri-derives-local-host …)
(deftest parse-git-url-rejects-ssh-form …)
(deftest parse-git-url-rejects-malformed …)
(deftest coord-dir-assembles-path-correctly …)
(deftest coord-dir-handles-dotgit-suffix …)
(deftest ensure-lib-returns-installed-false-when-cached …)
```

`ensure-lib-…-when-cached` is the one test that touches the filesystem:
it sets `LGX_HOME=$(mktemp -d)`, pre-creates the resolved cache dir
plus a `src/` subdir, calls `ensure-lib!`, and asserts the returned
map is `{:path "<dir>/src" :installed? false}`.

## E2E shell tests

`tests/e2e.sh` is `bash`, `set -eu`, one scenario per function.
Captures stdout/stderr per scenario and asserts with plain
`grep -q`-style helpers.

### Helpers

```bash
make_bare_repo()    # cd $1; git init --bare; commit one file; echo $sha
make_project()      # mkdir tmp; write lgx.edn pointing at file:///… and sha
assert_contains()   # grep -q expected literal in captured output
fail() { echo "FAIL: $1" >&2; exit 1; }
```

A single bare repo fixture is created at
`$LGX_HOME/_fixtures/test-repo.git`, holding one commit with
`src/test/fib.lg` (mirroring `examples/with-lib`). Sha captured via
`git rev-parse HEAD` after the seed commit.

Top of file exports
`GIT_AUTHOR_NAME=lgx-test GIT_AUTHOR_EMAIL=lgx@test.invalid`
(plus `GIT_COMMITTER_*`) so seed commits succeed without global
`git config` (matters in CI).

### Scenarios

1. `lgx version` → stdout contains `lgx 0.1.0`, exit 0. Same for
   `-v`, `--version`.
2. `lgx help` (and `-h`, `--help`, no-args) → stdout contains `Usage:`
   and the four command lines.
3. `lgx nope` → exit 1, output contains `unknown command: nope`.
4. `lgx install` against `{:deps {}}` → stdout is exactly
   `no deps in lgx.edn`, exit 0.
5. `lgx install` against the file:// bare repo, cold cache → stdout
   contains `installing 1 dep(s)...`, the lib name, `done`. Cache dir
   exists afterward. Exit 0.
6. `lgx install` again → stdout is exactly `all deps up to date`,
   exit 0.
7. `lgx install` from a nested subdir of the project → still works
   (walk-up coverage for `find-project!`).
8. `lgx run -e '(println :ok)'` against same repo, cold cache → stdout
   starts with the install block. The lg invocation may fail on
   `-source-paths` (upstream gap tracked in
   [`docs/issues/`](../issues/)); we assert only that the install
   block appears before any lg error.

## Wiring

### `tests/run.sh`

```bash
#!/usr/bin/env bash
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

echo "==> Bundling lgx..."
make build >/dev/null

echo
echo "==> Unit tests..."
lg tests/config_test.lg
lg tests/cache_test.lg

echo
echo "==> E2E tests..."
bash tests/e2e.sh

echo
echo "All tests passed."
```

### `Makefile`

Add a `test` target:

```make
.PHONY: build dev-install dev-run clean test
...
test:
	bash tests/run.sh
```

### `docs/knowledge-base/lgx-dev-workflow.md`

Append a short "Running tests" section pointing at `make test`. Keeps
testing discoverable from the agent index without inflating
`AGENTS.md`.

## CI

`.github/workflows/test.yml`:

```yaml
name: test
on:
  push:
    branches: [master, main]
  pull_request:
concurrency:
  group: test-${{ github.ref }}
  cancel-in-progress: true
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      LG_VERSION: 1.7.2
    steps:
      - uses: actions/checkout@v4
      - name: Install let-go (lg)
        run: |
          curl -sSL -o lg.tar.gz \
            "https://github.com/nooga/let-go/releases/download/v${LG_VERSION}/let-go_${LG_VERSION}_linux_amd64.tar.gz"
          tar -xzf lg.tar.gz
          sudo mv lg /usr/local/bin/lg
          lg -v
      - name: Run tests
        run: make test
```

Design choices:

- **Pinned `lg` version** matches `examples/with-lib/lgx.edn`. Bumping
  is a deliberate edit, not silent drift.
- **One Linux runner.** macOS/Windows is YAGNI until a user reports a
  platform issue.
- **No `actions/cache`.** `lg` is a tiny single binary; install is
  seconds.
- **Concurrency cancel-in-progress** stops stacked runs on force-push.

## Verification

1. `lg tests/config_test.lg` and `lg tests/cache_test.lg` pass locally.
2. `bash tests/e2e.sh` — all scenarios print PASS.
3. `make test` from clean checkout — green end-to-end.
4. Each test file when broken on purpose returns non-zero (sanity).
5. CI workflow runs green on the first push.

---

## Status: completed

**Commits:**

- `28acebd` — initial test suite, source changes, CI workflow.
- `b9adf81` — follow-ups from code review: `:git/tag` resolution
  scenario in e2e, sha256 checksum verification for the `lg` tarball in
  CI.

**Implemented:** all sections of the plan. 10 config unit tests, 10
cache unit tests, 19 e2e assertions; `make test` runs green end-to-end
locally.

**Deltas from the plan during execution:**

- `parse-git-url` for `file://` simplified to `["_local" "_"
  <basename>]` rather than basename-of-parent. Sha disambiguates
  collisions; fewer moving parts.
- Test scripts use `(when-not test/*test-result* (os/exit 1))` exactly
  as lgcr does — verified the dynamic var is observable after
  `run-tests` returns (`set!` works without an explicit `binding`
  because let-go updates the root binding in this case).
- Discovered and avoided let-go's "namespace name matching file path
  causes double-execution" gotcha by naming test namespaces
  `lgx.config-test` / `lgx.cache-test` (no matching resolver path).

**Issues encountered:**

- One iteration to rebuild `bin/lgx` after the `parse-git-url` change —
  the e2e was driving a stale bundle. `tests/run.sh` now invokes
  `make build` first, so this can't recur.
- `git clone` of an empty bare repo prints a benign warning; suppressed
  with `2>/dev/null` in `make_bare_repo`.
