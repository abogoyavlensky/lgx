# Gate let-go Source Fetch Behind `LGX_FETCH_LET_GO_SOURCE` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lgx install`'s let-go source fetch opt-in via the `LGX_FETCH_LET_GO_SOURCE` env var, off and silent by default.

**Tech Stack:** let-go (`lg` ≥ 1.11.0), lgx's own `.lg` sources, `clojure.test` unit tests, bash e2e harness.

---

## Design

### Background

`lgx install` ends by calling the private `install-letgo-source!` (`lgx.lg:141`),
which fetches the matching let-go **source** (not the binary) into
`$LGX_HOME/let-go/source/<version>/` whenever `:lg-version` is set in `lgx.edn`.
The source is only useful to editor tooling that navigates into let-go's
`core`/stdlib — today that's the experimental clj-pulse LSP server, which has no
users yet. So every pinned project currently pays for a clone it almost never
needs, and a user who sees the fetch has no obvious reason for it.

### Approach

Make the source fetch **opt-in**. It fires only when **both** conditions hold:

1. `LGX_FETCH_LET_GO_SOURCE` is set to a non-blank value, **and**
2. `:lg-version` is present in the loaded config.

Default (flag unset) is **off and completely silent** — no fetch, no output, no
warning. The fetch mechanism (`cache/ensure-letgo-source!`) is unchanged; this
is one small predicate plus a one-line gate.

### Key decisions

1. **Env semantics: any non-blank value enables it.** Matches the existing house
   style — `LGX_NO_COLOR` (`style.lg`) and `LGX_SKIP_VERSION_CHECK` are both
   "set to any non-empty value." `LGX_FETCH_LET_GO_SOURCE=1` is the canonical
   example; `=true` works too. Whitespace-only counts as unset (`str/blank?`).
2. **Silent when off.** When `:lg-version` is set but the flag is not, lgx does
   nothing and prints nothing — no hint line. This is the point: no surprise
   behavior, no "why is lgx doing that?" The clj-pulse setup docs are where its
   users learn to set the flag.
3. **Predicate lives in `cache.lg`.** That module already owns the whole
   let-go-source domain (`ensure-letgo-source!`, `letgo-source-dir`,
   `letgo-repo-url`), and each module owns its own env var
   (`home`→`LGX_HOME`, `runner`→`LGX_LG`, `style`→`LGX_NO_COLOR`,
   `new`→`LGX_TEMPLATE_*`). Making it public also makes it unit-testable.
4. **Name `LGX_FETCH_LET_GO_SOURCE`** as proposed.

### Testing strategy

- **Unit** (`test/lgx/cache_test.lg`): the predicate's both branches offline,
  toggling via `os/setenv` and restoring afterward.
- **E2E** (`tests/e2e.sh`): the real default-off `install` path offline — with
  `:lg-version` set and the flag unset, `lgx install` exits 0, prints no
  `Fetched let-go`, prints no `failed to fetch` warning, and creates no
  `$LGX_HOME/let-go/source/` directory.
- The ON *fetch mechanism* stays covered by the existing
  `ensure-letgo-source!` fixture tests, so the suite needs no network.

ARCHITECTURE.md and the knowledge-base do not describe this step, so no doc
drift there. README is the only doc to update.

## File Structure

- **Modify `lgx/cache.lg`** — add the public `letgo-source-fetch-enabled?`
  predicate alongside the existing let-go-source helpers.
- **Modify `lgx.lg`** — gate `install-letgo-source!` on the new predicate;
  update its preceding comment.
- **Modify `test/lgx/cache_test.lg`** — unit tests for the predicate.
- **Modify `tests/e2e.sh`** — one offline default-off install scenario.
- **Modify `README.md`** — command-table row (line 87), the `:lg-version` first
  bullet (~311–314), and a new env-var table row including the LSP/diagnostics
  rationale.

### Commands

- Full suite (build + unit + e2e): `make test`
- Unit tests only (after a build): `bin/lgx test`

---

## Task 1: `letgo-source-fetch-enabled?` predicate

**Files:**
- Modify: `lgx/cache.lg`
- Test: `test/lgx/cache_test.lg`

- [x] **Step 1: Write the failing tests**
  In `test/lgx/cache_test.lg`, add a small section for
  `letgo-source-fetch-enabled?`. Cover: unset → false; `""`/whitespace-only →
  false; `"1"` → true; `"true"` → true. Set the var with `os/setenv` and, after
  each assertion group, restore it to `""` so other tests are unaffected. Follow
  the file's existing `deftest`/`is` style.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build LG="$LGX_LG" >/dev/null && bin/lgx test`
  Expected: FAIL — `letgo-source-fetch-enabled?` is unresolved in `lgx.cache`.

- [x] **Step 3: Implement the predicate**
  In `lgx/cache.lg`, in the let-go-source section (near `letgo-repo-url`), add a
  public `letgo-source-fetch-enabled?` returning
  `(not (str/blank? (os/getenv "LGX_FETCH_LET_GO_SOURCE")))`. `str` is already
  required. Add a one-line docstring noting any non-blank value enables the
  source fetch.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build LG="$LGX_LG" >/dev/null && bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -am "feat: add letgo-source-fetch-enabled? env gate predicate"`

## Task 2: Gate the install-time fetch

**Files:**
- Modify: `lgx.lg`
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add the e2e default-off scenario**
  In `tests/e2e.sh`, after Scenario 4b, add a scenario: write an `lgx.edn` with
  `{:paths ["."] :lg-version "9.9.9" :main "main.lg"}`, a trivial `main.lg`, and
  a fresh `LGX_HOME`. Run `lgx install` (flag unset) capturing stdout+stderr.
  Assert: exit 0; output does **not** contain `Fetched let-go`; output does
  **not** contain `failed to fetch`; and `$LGX_HOME/let-go/source` does **not**
  exist. Use the existing `assert_*` helpers and clean up the temp dirs.

- [x] **Step 2: Gate `install-letgo-source!`**
  In `lgx.lg`, change the gate to fetch only when the flag is on. Use the `and`
  short-circuit so `version` is still bound:
  `(when-let [version (and (cache/letgo-source-fetch-enabled?) (config/lg-version cfg))] …)`.
  Update the preceding comment (currently "Runs regardless of :deps…") to state
  the fetch is opt-in via `LGX_FETCH_LET_GO_SOURCE` and silent when off.

- [x] **Step 3: Run the full suite to verify pass**
  Run: `make test`
  Expected: PASS, including the new Scenario. (Skip a "verify it fails first"
  run here — on the unfixed code the flag-off path attempts a real network clone
  of v9.9.9 and would hang offline; the gate is what removes that.)

- [x] **Step 4: Commit**
  `git commit -am "feat: fetch let-go source only when LGX_FETCH_LET_GO_SOURCE is set"`

## Task 3: README documentation

**Files:**
- Modify: `README.md`

- [x] **Step 1: Update the command table**
  Line ~87 (`lgx install` row): note the let-go source fetch is opt-in via
  `LGX_FETCH_LET_GO_SOURCE`, not automatic when `:lg-version` is set.

- [x] **Step 2: Update the `:lg-version` section**
  The first bullet (~311–314): clarify the source fetch happens only when
  `LGX_FETCH_LET_GO_SOURCE` is set; without it, `:lg-version` only drives the
  `run`/`nrepl`/`build`/`test` compatibility check.

- [x] **Step 3: Add the env-var table row**
  In the environment-variables table (~549), add `LGX_FETCH_LET_GO_SOURCE`,
  default _(unset)_. Describe it as: set to any non-empty value to make
  `lgx install` fetch the let-go source matching `:lg-version` into
  `$LGX_HOME/let-go/source/<version>/`. Include the rationale — the source is
  for editor diagnostics via an LSP server navigating into let-go's
  `core`/stdlib; off by default since most users don't run such tooling. Use
  /writing-clearly.

- [x] **Step 4: Commit**
  `git commit -am "docs: document LGX_FETCH_LET_GO_SOURCE opt-in source fetch"`

---

## Completion Summary

**Status: complete.** All three tasks landed; full suite green (440 unit tests,
281 e2e assertions).

Commits on the branch:
- `56f25fa` — `letgo-source-fetch-enabled?` predicate in `lgx/cache.lg` + 4 unit
  tests in `test/lgx/cache_test.lg`.
- `802013a` — gate `install-letgo-source!` in `lgx.lg` on the predicate (`and`
  short-circuit, comment updated) + offline e2e Scenario 4c in `tests/e2e.sh`.
- `7174674` — README: command-table row, `:lg-version` bullet, and a new
  env-var row covering the LSP-diagnostics rationale.

The fetch is now opt-in: it runs only when `LGX_FETCH_LET_GO_SOURCE` holds a
non-blank value **and** `:lg-version` is set; otherwise `lgx install` is silent.

**Second-opinion review (codex, branch vs `master`):**
- *[P2] e2e not hermetic* — **fixed.** Scenario 4c now clears
  `LGX_FETCH_LET_GO_SOURCE=` inline on the `install` invocation, so it tests the
  default-off path even when the caller's environment has the flag set. Verified
  by running the e2e with `LGX_FETCH_LET_GO_SOURCE=1` exported — Scenario 4c
  still passes.
- *[P3] env var undocumented* — **no change needed.** Codex reviewed a transient
  state while the Task 3 README edits were mid-flight; the env-var table row was
  already present in the final commit (`README.md` env table).

No deviations from the plan. The ON fetch path stays covered offline by the
existing `ensure-letgo-source!` fixture tests, so the suite needs no network.
