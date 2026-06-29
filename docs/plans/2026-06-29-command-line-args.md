# Adopt `*command-line-args*`, Drop the Injected `--` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop injecting a `--` marker into the `lg` command line; have lgx-built apps read their arguments from let-go's `core/*command-line-args*` instead, which works identically in `lgx run` and in a bundled binary.

**Tech Stack:** let-go (`lg` ≥ 1.11.0), lgx (self-hosted let-go CLI), Bash e2e harness.

---

## Design

### Background

let-go 1.11.0 added `core/*command-line-args*`: a seq of strings holding **exactly the positionals after the script**, verbatim (or `nil` when none). It is populated in both script mode and bundled-binary mode, and `os/args` is left untouched (the var is purely additive). A literal `--` among the args is preserved, not stripped.

Today lgx injects a trailing `--` into the `lg` command line so a script can locate its own args with the `(rest (drop-while #(not= "--" %) os/args))` idiom, and the README steers app authors toward an `LGX_RUN`-keyed helper to bridge dev vs. bundled modes. `*command-line-args*` makes both unnecessary: `lg` already stops flag-parsing at the first positional (the script), so everything after the script is shielded from `lg` and is exactly what fills the var. The injected `--` was only ever a locator.

This is a **clean break** (decision A): lg 1.11.0 becomes the floor, and the `--`-marker convention is replaced by `*command-line-args*`. It rides with one adjacent cleanup (decision a): let-go 1.11.0 deleted the source-paths transition warning and its `LG_SUPPRESS_SOURCE_PATHS_WARNING` env var (let-go #230), which lgx still sets as a no-op.

### New `cmd-run` arg-assembly behavior

Four rules, first match wins. The change across all four: **lgx never emits a `--`**. A *second*, user-authored `--` is preserved as a literal arg (standard getopt: only the first `--` is the separator).

1. **No forwarded args + `:main` set** → inject `:main`. `lg <lg-flags> <main>`. → `*command-line-args*` = `nil`.
2. **`--` present + pre-`--` slice has a script** (`.lg`/`.cljc`/`.clj`) → drop the separator, pass the rest through. `lgx run foo.lg -- bar` → `lg foo.lg bar` → `("bar")`.
3. **`--` present + pre-`--` slice has no script** → inject `:main` at the boundary, drop the separator. `lgx run -r -- foo` → `lg -r <main> foo` → `("foo")`; `lgx run -- a -- b` → `lg <main> a -- b` → `("a" "--" "b")`. With `:main` unset → exit `lgx: -- requires :main to be set in lgx.edn` (unchanged).
4. **Anything else** (no `--`, or no args and no `:main`) → pass through verbatim. `lgx run foo.lg`, `lgx run -e '(...)'`, `lgx run -r`, and bare `lgx run` with no `:main` (→ REPL) are unchanged.

### Components

The branching currently lives inline in `cmd-run` and is exercised only by slow shell e2e tests. Extract the **decision** into a pure function and leave the **side effects** in `cmd-run`:

- **`runner/plan-run-args [forward-args main-script]`** — pure, in `lgx/runner.lg` (the module that owns "how we build the lg command"). Returns one of:
  - `{:argv [...] :inject? true}` — `:main` was injected; the caller must validate it exists on disk.
  - `{:argv [...] :inject? false}` — pass-through or explicit script; no validation.
  - `{:error :needs-main}` — `--` given with no `:main`.
- The private helpers `position`, `script-exts`, `script-arg?`, `has-script?` move from `lgx.lg` into `runner.lg` (they are used only by this logic).
- `cmd-run` shrinks to: call `plan-run-args`; on `{:error :needs-main}` print + exit via the existing `require-main-for-double-dash!`; on `:inject?` call `resolve-main-script!` (existence check, which returns the same relative token already in `:argv`); then exec `(:argv plan)`.

### Error handling

Unchanged in observable behavior: a `--` with no `:main` still exits 1 with `lgx: -- requires :main to be set in lgx.edn`; an injected `:main` that is missing on disk still exits 1 with `lgx: :main script not found: <path>`. Both paths are driven by `plan-run-args`' return value plus the existing helpers; the pure function never performs I/O or exits.

### Adjacent cleanup (decision a)

`runner.lg` removes `"LG_SUPPRESS_SOURCE_PATHS_WARNING"` from `lgx-set-env-names` and deletes the `(os/setenv "LG_SUPPRESS_SOURCE_PATHS_WARNING" "1")` call and its comment. `LGX_RUN` stays (still set in `cmd-run`) but is reframed in docs as a dev-vs-bundle signal only — no longer the arg-parsing mechanism.

### Testing strategy

`make test` (fast unit) becomes the authoritative coverage of the branching via new `plan-run-args` tests; `tests/e2e.sh` (needs a real `lg` ≥ 1.11.0 on PATH or via `LGX_LG`) keeps a thin end-to-end confirmation, rewritten to assert `*command-line-args*` instead of slicing `os/args` on `--`.

### Scope boundaries

**Out of scope / recorded as follow-ups:**
- **nrepl port via `os/free-port` / `-p 0`** (decision b, deferred). let-go #229 makes `-p 0` report the OS-assigned port, which makes the rationale in ARCHITECTURE.md (lines ~207–209) stale. This plan records a `docs/issues/` note so the stale claim is not left silent, but changes no nrepl behavior.
- **Template repos** `lgx-template-cli` / `lgx-template-base` (separate repos) — their `main.lg` likely uses the old `--` idiom and their `:lg-version` pins need bumping to 1.11.0. Flagged as required external follow-up; not editable from this repo.
- No new runtime "minimum lg version" floor check in lgx — deliberately doc-level plus the existing `:lg-version` pin. lgx itself does not need the var; only apps do, and lgx cannot detect app usage. The in-repo `examples/` do not parse CLI args, so none need code changes.

---

## File Structure

**Modify:**
- `lgx/runner.lg` — add public `plan-run-args`; move in `position`, `script-exts`, `script-arg?`, `has-script?`; drop `LG_SUPPRESS_SOURCE_PATHS_WARNING` from `lgx-set-env-names` and from `lg-invocation!`.
- `lgx.lg` — `cmd-run` calls `runner/plan-run-args`; remove the now-moved private helpers.
- `test/lgx/runner_test.lg` — add `plan-run-args` unit tests; update the env-trace test that asserted `LG_SUPPRESS_SOURCE_PATHS_WARNING`; tidy the `lg-args` test data that used `--`.
- `tests/e2e.sh` — rewrite scenarios 21 and 31–38 to assert `*command-line-args*` (note 36/37/38 use explicit scripts `other.lg`/`other.cljc`, not `main.lg`); add a second-`--` scenario; remove Scenario 88 and any other `LG_SUPPRESS_SOURCE_PATHS_WARNING` assertion.
- `README.md` — rewrite `### lgx run details`; reword the `LGX_RUN` env-table row; remove the stale `LG_SUPPRESS_SOURCE_PATHS_WARNING` mention in the `--verbose` bullet (line ~106); bump lg version references `1.10.0` → `1.11.0`.
- `docs/ARCHITECTURE.md` — rewrite the four `cmd-run` rules; remove the stale `LG_SUPPRESS_SOURCE_PATHS_WARNING` mention in "External dependencies" (line ~562); update the lg version note.
- `docs/issues/nrepl-port-zero.md` — mark resolved upstream (let-go 1.11.0) and record the deferred lgx-side simplification, the now-stale ARCHITECTURE claim, and the template-repo follow-ups. (This file already exists — extend it; do **not** create a duplicate.)

---

## Tasks

### Task 1: Pure `plan-run-args` planner in `runner.lg`

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [ ] **Step 1: Write the failing tests**
  In `test/lgx/runner_test.lg`, add a `plan-run-args` section covering every rule:
  - empty args + `:main` → `{:argv ["main.lg"] :inject? true}`
  - `["--" "list"]` + `:main` → `{:argv ["main.lg" "list"] :inject? true}`
  - `["--" "-v"]` + `:main` → `{:argv ["main.lg" "-v"] :inject? true}`
  - `["-r" "--" "foo"]` + `:main` → `{:argv ["-r" "main.lg" "foo"] :inject? true}`
  - `["--" "a" "--" "b"]` + `:main` → `{:argv ["main.lg" "a" "--" "b"] :inject? true}` (second `--` preserved)
  - `["foo.lg" "--" "bar"]` (any `:main`) → `{:argv ["foo.lg" "bar"] :inject? false}`
  - `["foo.lg" "arg"]` → `{:argv ["foo.lg" "arg"] :inject? false}` (rule 4 pass-through)
  - `["-e" "(...)"]` → `{:argv ["-e" "(...)"] :inject? false}`
  - `["--" "foo"]` + `:main` nil → `{:error :needs-main}`
  - empty args + `:main` nil → `{:argv [] :inject? false}` (REPL pass-through)
  Use `lgx.runner/plan-run-args`; `:main` is passed as the bare string `"main.lg"` or `nil`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL — `plan-run-args` is unresolved.

- [ ] **Step 3: Implement `plan-run-args` and move the helpers**
  In `lgx/runner.lg`: move `position`, `script-exts`, `script-arg?`, `has-script?` from `lgx.lg` (keep them `^:private`). Add public `plan-run-args [forward-args main-script]` implementing the cond in the design order: empty+`:main` → inject; no `--` (`position` returns -1) → pass-through; else split on the first `--`, and if the pre slice has a script pass `pre ++ post`, otherwise require `:main` (else `{:error :needs-main}`) and emit `pre ++ [main-script] ++ post`. Return maps as specified; the function performs no I/O.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -m "Add pure plan-run-args planner to runner"`

### Task 2: Rewire `cmd-run` to drop the injected `--`

**Files:**
- Modify: `lgx.lg`

- [ ] **Step 1: Replace the inline `args` cond**
  In `cmd-run`, replace the `dd`/`cond` block with: `(let [plan (runner/plan-run-args forward-args main-script)] ...)`. On `{:error :needs-main}` call `(require-main-for-double-dash! main-script)` (prints + exits). On `:inject?` call `(resolve-main-script! project main-script)` to validate existence. Exec `(:argv plan)` via `runner/exec-lg-interactive!`. Keep `(os/setenv "LGX_RUN" "1")` and `print-installs!` as they are.

- [ ] **Step 2: Remove the now-moved private helpers**
  Delete `position`, `script-exts`, `script-arg?`, `has-script?` from `lgx.lg` (now in `runner.lg`). Keep `resolve-main-script!` and `require-main-for-double-dash!` in `lgx.lg`.

- [ ] **Step 3: Verify unit tests still pass**
  Run: `make test`
  Expected: PASS (no `--` regression in unit scope; `cmd-run` is covered by e2e in Task 4).

- [ ] **Step 4: Commit**
  `git commit -m "Drop injected -- from cmd-run; use plan-run-args"`

### Task 3: Remove the dead `LG_SUPPRESS_SOURCE_PATHS_WARNING`

This task removes *every* trace of the env var — code, tests, and the two prose mentions — so the removal is atomic and self-consistent.

**Files:**
- Modify: `lgx/runner.lg`, `README.md`, `docs/ARCHITECTURE.md`
- Test: `test/lgx/runner_test.lg`

- [ ] **Step 1: Update the env-trace test**
  In `test/lgx/runner_test.lg`, change `env-trace-line-includes-suppress-warning`: with `LG_SUPPRESS_SOURCE_PATHS_WARNING` no longer in the allowlist, `env-trace-line` must skip it even when present in the lookup map. Assert the output is `"+ env LG_READ_CLJ=1 LGX_RUN=1\n"` for the same 3-key input map (rename the test to reflect that the suppress var is now ignored). Also update the `lg-args-builds-full-argv` test data to drop the trailing `"--"` (it is no longer representative of forwarded args).

- [ ] **Step 2: Run tests to verify the env-trace test fails**
  Run: `make test`
  Expected: FAIL — `env-trace-line` still includes `LG_SUPPRESS_SOURCE_PATHS_WARNING`.

- [ ] **Step 3: Remove the env var from code**
  In `lgx/runner.lg`: drop `"LG_SUPPRESS_SOURCE_PATHS_WARNING"` from `lgx-set-env-names`; delete the `(os/setenv "LG_SUPPRESS_SOURCE_PATHS_WARNING" "1")` call and its comment in `lg-invocation!`; update the `lgx-set-env-names` docstring/comment to list only `LG_READ_CLJ` and `LGX_RUN`.

- [ ] **Step 4: Remove the two stale prose mentions**
  Use the /writing-clearly skill. In `README.md` (~line 106) drop the `LG_SUPPRESS_SOURCE_PATHS_WARNING=1 ... silences lg's source-paths transition notice` clause from the `--verbose` bullet, leaving the remaining env vars accurate. In `docs/ARCHITECTURE.md` (~line 562, "External dependencies") drop the sentence about exporting `LG_SUPPRESS_SOURCE_PATHS_WARNING=1` before every spawn.

- [ ] **Step 5: Run tests + grep to verify**
  Run: `make test`
  Expected: PASS.
  Run: `grep -rn 'LG_SUPPRESS_SOURCE_PATHS_WARNING' lgx.lg lgx/ test/ README.md docs/ARCHITECTURE.md`
  Expected: no matches. (`tests/e2e.sh` still references it in Scenario 88, removed in Task 4; historical `docs/plans/` entries keep their mentions — both are out of scope here.)

- [ ] **Step 6: Commit**
  `git commit -m "Remove dead LG_SUPPRESS_SOURCE_PATHS_WARNING (let-go 1.11.0)"`

### Task 4: Rewrite e2e scenarios for `*command-line-args*`

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Rewrite the arg-forwarding scenarios**
  Change the relevant fixture script in scenarios 21 and 31–38 to `(when-not *compiling-aot* (prn *command-line-args*))` and update assertions. Scenarios 21 and 31–35 drive `:main`, so edit each scenario's `main.lg`; scenarios 36/37/38 drive **explicit** scripts (`other.lg`, `other.lg`, `other.cljc` respectively), so edit those files — and keep their existing `:main`-not-injected checks (assert the `:main-ran` marker is absent for 36 and 38).
  - 21 bare run → output `nil`.
  - 31 `run -- list` → `("list")`.
  - 32 `run -- -v` → `("-v")` (flag shielded by script position).
  - 33 `--verbose run -r -- foo` trace → contains `-r ... main.lg foo` (no `--`).
  - 34 bare `run --` → `nil`.
  - 35 `run -- foo` without `:main` → exits with `lgx: -- requires :main` (unchanged).
  - 36 `run other.lg -- bar` → `("bar")`, and `:main` not injected.
  - 37 `run other.lg -- bar` (no `:main` set) → `("bar")`.
  - 38 `run other.cljc -- baz` → `("baz")`, and `:main` not injected.

- [ ] **Step 2: Add a second-`--` preservation scenario**
  New scenario: `run -- a -- b` with `:main` set → `*command-line-args*` prints `("a" "--" "b")`.

- [ ] **Step 3: Remove the suppress-warning scenario**
  Delete Scenario 88 (asserts lgx exports `LG_SUPPRESS_SOURCE_PATHS_WARNING` and that lg silences the notice). Grep `tests/e2e.sh` for any remaining `LG_SUPPRESS_SOURCE_PATHS_WARNING` references and remove them.

- [ ] **Step 4: Run the e2e suite**
  Run: `make test` (or the project's e2e entrypoint; requires `lg` ≥ 1.11.0 on PATH or `LGX_LG`).
  Expected: PASS, all scenarios green.

- [ ] **Step 5: Commit**
  `git commit -m "Rewrite e2e scenarios to assert *command-line-args*"`

### Task 5: Update README and ARCHITECTURE

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: Rewrite README `### lgx run details`**
  Use the /writing-clearly skill. Replace the "injects a trailing `--`" intro with `lg <paths> :main` (no `--`). Replace the `cli-argv`/`drop-while`/LGX_RUN-for-args block with guidance to read `*command-line-args*`, noting it is identical in `lgx run` and a bundled binary. Update each **Forms** line to drop `--` (e.g. `lgx run -- foo bar` → `lg <paths> :main foo bar`; `lgx run -r -- foo` → `lg <paths> -r :main foo`; `lgx run foo.lg -- bar` → `lg <paths> foo.lg bar`). Keep the `LGX_RUN` env-table row but reword it as a dev-vs-bundle signal, not an arg mechanism.

- [ ] **Step 2: Bump lg version references in README**
  Change the prerequisite (line ~20) and the `:lg-version` examples (lines ~236 and ~303) from `1.10.0` to `1.11.0`. Note that `*command-line-args*` requires `lg` ≥ 1.11.0 where the run convention is described.

- [ ] **Step 3: Rewrite the ARCHITECTURE `cmd-run` rules**
  Use the /writing-clearly skill. Rewrite the four rules (lines ~149–174) to match the new behavior (no emitted `--`, separator dropped, `*command-line-args*` as the app's arg source, second `--` preserved as literal). Update the "(lg >= 1.10.0)" note (line ~188) to call out the 1.11.0 `*command-line-args*` requirement.

- [ ] **Step 4: Sanity-check docs**
  Run: `grep -n -- 'drop-while\|injecting\|trailing `--`' README.md docs/ARCHITECTURE.md`
  Expected: no stale references to the old `--` convention remain.

- [ ] **Step 5: Commit**
  `git commit -m "Document *command-line-args* convention; require lg 1.11.0"`

### Task 6: Record deferred follow-ups

The existing `docs/issues/nrepl-port-zero.md` is the upstream issue draft that let-go 1.11.0 resolved. Extend it rather than create a parallel note.

**Files:**
- Modify: `docs/issues/nrepl-port-zero.md`

- [ ] **Step 1: Mark the issue resolved upstream**
  Use the /writing-clearly skill. In `docs/issues/nrepl-port-zero.md`, change **Status** from `draft` to `resolved upstream (let-go 1.11.0)`, and add a "Resolution" section: let-go 1.11.0 made `-p 0` report the OS-assigned port (#229) and added `os/free-port` (#209), so lgx can now request a free port instead of guessing.

- [ ] **Step 2: Record the deferred lgx-side work and stale doc**
  In the same file, note the deferred lgx change (its own plan): `cmd-nrepl` can drop the random `(+ 49152 (rand-int 16384))` guess in favor of `-p 0` (reading the real port back) or `os/free-port`; and the rationale in `docs/ARCHITECTURE.md` (~207–209) is now stale and should be updated by that plan. Also record the external follow-up: bump `lgx-template-cli` / `lgx-template-base` to `:lg-version "1.11.0"` and migrate their `main.lg` off the `--` idiom to `*command-line-args*`.

- [ ] **Step 3: Commit**
  `git commit -m "Mark nrepl port-zero issue resolved; record follow-ups"`

---

## Verification

- `make test` passes (unit + e2e), with a real `lg` ≥ 1.11.0 available to the e2e suite.
- `lgx run` (bare, with `:main`) yields `*command-line-args*` = `nil`; `lgx run -- a b` yields `("a" "b")`; `lgx run -- a -- b` yields `("a" "--" "b")`.
- No `LG_SUPPRESS_SOURCE_PATHS_WARNING` remains in source, tests, the README, or ARCHITECTURE.md (historical `docs/plans/` entries keep their mentions and are out of scope).
- README and ARCHITECTURE describe only the `*command-line-args*` convention; no `drop-while`/`--`-marker guidance survives.
