# Verbose lg Version & Path Implementation Plan — ✅ COMPLETED

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `--verbose`, print the resolved `lg` version and full binary path alongside the existing env/invocation trace.

**Tech Stack:** let-go (Clojure dialect), lgx self-hosted bundle, bash e2e harness.

---

## Design

### What & why

`--verbose` exists to answer "what is lgx about to run". Today it prints two
`*err*` trace lines from `runner/lg-invocation!`:

```
+ env LG_READ_CLJ=1 LG_SUPPRESS_SOURCE_PATHS_WARNING=1
+ lg -source-paths … <args>
```

It does not say *which* `lg` (version) or *where* it lives. With `LGX_LG` dev
overrides in play, the resolved path is the most useful missing fact; the
version is a cheap complement. We add one line, prepended to the trace:

```
+ lg 1.10.0 (/usr/local/bin/lg)
+ env LG_READ_CLJ=1 LG_SUPPRESS_SOURCE_PATHS_WARNING=1
+ lg -source-paths … <args>
```

Best-effort: unknown version → omit the version token; unresolved path → fall
back to the bare bin name. The line never crashes the trace.

### Key decisions

- **Per-invocation, in `lg-invocation!`.** That function is the single
  chokepoint every lg run passes through (run/nrepl/build/test + each task
  `:run` step), so wiring there covers all paths with no duplication. The cost
  is repetition in multi-step tasks (each `:run` step reprints the line); that
  is acceptable and far simpler than threading "already printed" state.
- **Reuse the `lg -v` probe.** `version/installed` already shells `lg -v` and
  parses the token. `version.lg` requires `runner`, so `runner` cannot require
  `version` back (cycle). Resolution: extract the probe into
  `runner/lg-version`, and have `version/installed` delegate to it. DRY, no
  behavior change.
- **Path resolution.** If the bin contains a separator (explicit `LGX_LG`
  path), normalize to absolute against `os/cwd`. Otherwise resolve on PATH via
  `sh -c 'command -v -- "$1"' sh <bin>` — bin passed as a positional arg, never
  interpolated into the script, so no shell-injection surface. Returns `nil`
  when unresolved.
- **Format** `+ lg <version> (<path>)`, `+`-prefixed to match the rest of the
  trace.
- **Cost:** verbose-only, up to two extra subprocesses (`lg -v`, `command -v`)
  per invocation. Negligible; no caching (YAGNI).

### Testing strategy

Mirror the existing `env-trace-line` pattern: the pure formatter and the pure
path-display branch get `runner_test.lg` unit tests; the shellouts stay thin
and untested (as `lg-binary`/exec are today). One e2e assertion extends the
existing verbose-run scenario.

## File Structure

- Modify `lgx/runner.lg` — add `lg-version` (extracted probe), `lg-resolved-path`
  (path resolution + pure `display-path` branch helper), `binary-trace-line`
  (pure formatter); call it from `lg-invocation!` under `verbose?`.
- Modify `lgx/version.lg` — `installed` delegates to `runner/lg-version`.
- Modify `test/lgx/runner_test.lg` — unit tests for `binary-trace-line` and
  `display-path`.
- Modify `lgx.lg` — extend the `--verbose` help text (line ~41).
- Modify `README.md` — extend the `--verbose` options bullet (line ~101).
- Modify `tests/e2e.sh` — extend Scenario 12 with a version/path-line assertion.

Test command (full suite): `make test` (bundles, runs `bin/lgx test`, then
e2e). For faster unit iteration: `make build && bin/lgx test`.

---

### Task 1: Pure trace formatter

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [x] **Step 1: Write the failing tests**
  In `runner_test.lg`, add cases for a new pure `runner/binary-trace-line`
  (takes a version string-or-nil and a path string-or-nil, returns the `+ …\n`
  line):
  - version + path → `"+ lg 1.10.0 (/usr/local/bin/lg)\n"`
  - version nil, path present → `"+ lg (/usr/local/bin/lg)\n"` (no version token)
  - version present, path nil → `"+ lg 1.10.0 (lg)\n"` (bare bin fallback — pass
    the fallback bin name in; see Step 3)
  Match the existing `env-trace-line` test style.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && bin/lgx test`
  Expected: FAIL — `binary-trace-line` unresolved / wrong output.

- [x] **Step 3: Write minimal implementation**
  Add `binary-trace-line` to `runner.lg`: a pure fn `[version path bin]` that
  builds `+ lg` + optional ` <version>` (when non-blank) + ` (<path-or-bin>)`
  + `\n`. The path argument falls back to `bin` when nil/blank. Keep it
  alongside `env-trace-line`, docstring in the same voice.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -am "Add binary-trace-line formatter to runner"`

### Task 2: Version & path resolution

**Files:**
- Modify: `lgx/runner.lg`
- Modify: `lgx/version.lg`
- Test: `test/lgx/runner_test.lg`

- [x] **Step 1: Write the failing test**
  In `runner_test.lg`, add cases for a pure `runner/display-path` helper that
  resolves the explicit-path (`LGX_LG`) branch given `[bin cwd]`:
  - absolute bin (`"/opt/lg"`, any cwd) → `"/opt/lg"` unchanged
  - relative bin (`"./.tmp/lg"`, cwd `"/home/u/proj"`) → normalized absolute
    `"/home/u/proj/.tmp/lg"` (use `path/join` + `path/normalize`)

- [x] **Step 2: Run test to verify it fails**
  Run: `make build && bin/lgx test`
  Expected: FAIL — `display-path` unresolved.

- [x] **Step 3: Write minimal implementation**
  In `runner.lg`:
  - `display-path [bin cwd]` (pure): if `path/absolute?` return bin, else
    `path/normalize (path/join cwd bin)`. Requires adding `[lgx.path :as path]`
    to the ns.
  - `lg-version []`: the `lg -v` probe extracted from `version/installed`
    (shell `(runner/lg-binary) "-v"`, parse token, nil on failure).
  - `lg-resolved-path []`: if `(lg-binary)` contains `os/file-separator`, return
    `(display-path bin (os/cwd))`; else run
    `(os/sh "sh" "-c" "command -v -- \"$1\"" "sh" bin)`, and on zero exit with
    non-blank out return `(str/trim out)`, else nil.
  In `version.lg`: change `installed` to delegate to `runner/lg-version`
  (drop the duplicated probe; keep the docstring accurate).

- [x] **Step 4: Run test to verify it passes; confirm no regression**
  Run: `make build && bin/lgx test`
  Expected: PASS (new `display-path` cases + all existing runner/version-dependent
  tests).

- [x] **Step 5: Commit**
  `git commit -am "Add lg version/path resolution to runner; version delegates"`

### Task 3: Wire trace line + e2e

**Files:**
- Modify: `lgx/runner.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Wire into `lg-invocation!`**
  Under the existing `(when verbose? …)`, before the env line, write
  `(binary-trace-line (lg-version) (lg-resolved-path) bin)` to `*err*`. Keep
  the env and `+ <bin> <args>` lines exactly as they are. Update the
  `lg-invocation!` docstring to mention the version/path line.

- [x] **Step 2: Extend e2e Scenario 12**
  In `tests/e2e.sh` Scenario 12 (verbose run), add an `assert_contains` that
  `$out_verbose` includes `"+ lg "` followed by a parenthesized path — assert
  on `+ lg ` and on `(` / the bin path. Keep it tolerant of version being
  present or absent (don't hard-code a version number).

- [x] **Step 3: Run the full suite**
  Run: `make test`
  Expected: all unit + e2e pass, including the new Scenario 12 assertion.

- [x] **Step 4: Commit**
  `git commit -am "Print lg version and path on --verbose"`

### Task 4: Docs

**Files:**
- Modify: `lgx.lg`
- Modify: `README.md`

- [x] **Step 1: Update help text**
  In `lgx.lg` (the `--verbose` help line ~41), note it also prints the resolved
  `lg` version and path. Keep it to one concise clause.

- [x] **Step 2: Update README**
  In `README.md` (the `--verbose` options bullet ~101), document the new
  `+ lg <version> (<path>)` line and that the path reflects `LGX_LG` overrides.
  Use /writing-clearly.

- [x] **Step 3: Verify build still succeeds**
  Run: `make build && bin/lgx --verbose run -e '(println :ok)'`
  Expected: stderr shows the `+ lg <version> (<path>)` line above the env line.

- [x] **Step 4: Commit**
  `git commit -am "Document verbose lg version/path output"`

---

## Completion Summary

All four tasks landed on branch `add-verbose-lg-path-and-version` (4 commits,
one per task), following the design as written — no scope changes.

**What was implemented:**
- `runner/binary-trace-line` — pure formatter producing `+ lg <version> (<path>)`
  (version omitted when blank; path falls back to the bare bin name).
- `runner/lg-version` — the `lg -v` probe, extracted so it has one home.
- `runner/lg-resolved-path` — absolute path of the lg lgx will run: explicit
  `LGX_LG` paths normalized against cwd; bare names resolved on PATH via
  `sh -c 'command -v -- "$1"' sh <bin>` (bin passed as an argument, no injection).
- `runner/display-path` — pure helper for the `LGX_LG`-path branch.
- `lg-invocation!` prints the new line first under `verbose?`; env + invocation
  lines unchanged.
- `version/installed` now delegates to `runner/lg-version` (DRY, no behavior
  change).
- Unit tests for `binary-trace-line` and `display-path`; e2e Scenario 12
  extended with a grep for the `+ lg … (<path>)` line. Help text + README updated.

**Verification:** `make test` green — 421 unit tests / 575 assertions and 282
e2e assertions. Live trace confirmed:
```
+ lg 1.10.0 (/.../mise/installs/lg/1.10.0/lg)
+ env LG_READ_CLJ=1 LG_SUPPRESS_SOURCE_PATHS_WARNING=1 LGX_RUN=1
+ lg -source-paths … -e (println :ok)
```

**Second-opinion review (codex, vs master):** no actionable regressions — the
additions are scoped to verbose execution and preserve existing invocation
behavior.

**Issues encountered:** none in the code. One tooling hiccup — this codex
version (`codex-cli 0.139.0`) rejects a positional PROMPT alongside `--base`
(same restriction it has with `--uncommitted`); re-ran without the prompt.
