# let-go Version Pinning & Source Fetch Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a project pin the let-go version it targets via an optional
`:lg-version` key in `lgx.edn`. When pinned, `lgx install` fetches the matching
let-go **source** (not the binary) into a shared cache so editor tooling can
navigate into core/stdlib, and `lgx run/nrepl/build/test` check that the `lg` on
PATH matches the pin — warning during iteration, failing where it counts.

**Tech Stack:** let-go (`.lg`), the existing `lgx/spec.lg` schema engine,
`lgx/cache.lg` git-CLI fetcher, `lgx/config.lg`, `lgx.lg` command dispatch.

---

## Design

### Context & decisions

This is the **lgx-only** half of let-go-core navigation support; the editor
(clj-pulse) side is separate and out of scope here. The design was settled in
prior discussion; the key decisions:

- **`:lg-version` is optional, not required.** The smallest valid `lgx.edn`
  stays `{:paths ["."] :deps {}}`. Toolchain pins are opt-in (cf.
  `rust-toolchain.toml`); a required field would gate trivial scripts, break
  existing manifests, and create stale-pin landmines.
- **lgx fetches let-go _source_, never the binary.** lgx ships self-contained
  (`lg -b`), and `lg` is the user's responsibility (mise/brew/manual). We only
  fetch the `.lg` source so editors can navigate into let-go's `core`/stdlib.
  No `depends_on` in the formula (the Homebrew plan already chose caveats-only).
- **`lgx install` stays read-only on project files.** It never writes
  `:lg-version`; pinning is a deliberate manual edit. No `lgx new` stamping.
- **Compatibility check severity is tiered and automatic** (no `--strict`
  flag — the pin's presence _is_ the strictness signal): **warn** on `run` /
  `nrepl` (iteration), **fail** on `build` / `test` (a build artifact or a test
  verdict against the wrong runtime is corrupt/misleading). `LGX_SKIP_VERSION_CHECK`
  opts out of both tiers. Unpinned → no check at all.
- **Source cache layout:** `$LGX_HOME/let-go/source/<version>/…` — the
  intermediate `source/` segment leaves room for sibling `let-go/<other>/` dirs
  later. The let-go repo is cloned whole (shallow); core lives at the standard
  `pkg/rt/core/` path inside it.

### Component 1 — schema + accessor (`lgx/config.lg`)

Add `:lg-version` to `lgx-schema` (the `:closed true` map) as an optional
non-blank string, mirroring the existing `:main` entry. Add a pure
`config/lg-version` accessor (returns the string or `nil`), mirroring
`config/main`. Because the map is `:closed`, the schema entry is what makes a
pinned manifest validate at all.

### Component 2 — source fetch (`lgx/cache.lg`)

A new public `ensure-letgo-source!` that fetches the let-go source at the pinned
version into the dedicated cache:

- Target dir: `(path/join (home/root) "let-go" "source" version)`.
- **Idempotent**: if the dir exists, return `{:installed? false :dir …}` without
  touching the network.
- Otherwise reuse the existing `clone-tag!` primitive (`git clone --depth 1
  --branch <tag>` + atomic tmp→rename via `finalize-worktree!`). `clone-tag!` is
  currently private (`defn-`) — make it public or add a thin public wrapper;
  don't duplicate its logic.
- Repo coords are hardcoded: `https://github.com/nooga/let-go`. The git **tag**
  is derived from the version — goreleaser tags are conventionally `v<version>`,
  so fetch tag `v<version>` (e.g. `v1.10.0`). Confirm against nooga/let-go's
  actual tags during implementation; if releases are tagged bare `<version>`,
  use that.
- Returns enough for the caller to log ("fetched" vs "already present").

This does **not** go through `ensure-lib!`/`coord-dir` (those hardcode the
`gitlibs/<host>/<owner>/<repo>/<ref>/` layout); it writes to the dedicated
`let-go/source/<version>/` path.

### Component 3 — wire into `lgx install` (`lgx.lg`, `cmd-install`)

After the existing deps install, when `config/lg-version` is set, call
`ensure-letgo-source!`. Logging is distinct from deps:

- Newly fetched: `Fetched let-go <version> source (for editor navigation)`.
- Already present: a quiet "up to date"-style line (consistent with the
  existing `all deps up to date`).

Wording is **"fetched," not "installed,"** and the reason stays generic (editor
navigation), not "LSP" — the source is for tooling broadly. Unpinned → nothing
printed, no fetch.

### Component 4 — version compatibility check (`lgx.lg`)

- `lg-installed-version` — run `lg -v` (via the same `os/sh` mechanism lgx uses
  to invoke `lg`), parse the version token out of let-go's banner output
  (`<version> (<commit>)` for released builds; `dev` for source builds). Reuse
  any existing `lg -v` probe if present.
- `check-lg-version!` — when `:lg-version` is pinned and `LGX_SKIP_VERSION_CHECK`
  is unset: compare the installed version to the pin (**exact** match). On
  mismatch, emit at the caller-specified severity, showing both versions and how
  to resolve (update the pin or the installed `lg`). A `dev`/unparseable
  installed version → a one-line info skip (don't warn-spam source builds).
  Warn is **once per invocation**.
- Wire it as a preflight: `cmd-run` (264) and `cmd-nrepl` (301) call it at
  **warn**; `cmd-build` (329) and `cmd-test` (373) at **fail** (non-zero exit).
  Task `:run` steps inherit warn; `:sh` steps are not policed.

### Component 5 — docs (`README.md`, `docs/knowledge-base/`)

- **README reference**: add `:lg-version "1.10.0"` to the commented
  `## Configuration: lgx.edn` example with a one-line description ("optional;
  the let-go version this project targets").
- **README mechanism section**: a concise `### let-go version pinning` under
  Configuration — what it does, the source fetch to
  `$LGX_HOME/let-go/source/<version>/`, the warn/fail tiers +
  `LGX_SKIP_VERSION_CHECK`, and the clarification that lgx does **not** install
  the runtime (you still get `lg` via mise/brew). Update the `lgx install` row
  in the Commands table to note the source fetch.
- **Knowledge-base** (optional, deeper): `docs/knowledge-base/let-go-version-pinning.md`
  with the rationale and the editor/clj-pulse integration angle, alongside the
  existing `let-go-*.md` notes.

### Error handling

- Network/clone failure during `ensure-letgo-source!`: surface a clear error
  but **do not fail `lgx install`'s dep step retroactively** — deps already
  installed succeed; the source fetch failure is reported as its own warning so
  a transient GitHub/network issue doesn't block the whole install. (Editor
  navigation simply won't work until the next successful fetch.)
- `lg` absent on PATH when checking: treat like a `dev`/unknown version — skip
  with an info line rather than crash (the user may not have `lg` yet).
- Tag not found (wrong version pinned): clear error naming the version and repo.

### Testing strategy

`make test` builds lgx and runs two layers: **unit** `.lg` tests in
`test/lgx/<module>_test.lg` (via `lgx test`) and **e2e** in `tests/e2e.sh`
(bash, driving the real `bin/lgx`, with `tests/fixtures/`). Use each where it
fits:

- **Schema** (unit, `test/lgx/config_test.lg`): pinned version validates;
  blank/non-string rejected; absent is valid; `config/lg-version` returns the
  value or `nil`.
- **Fetch** (unit, `test/lgx/cache_test.lg`): against a **local `file://` git
  remote fixture** (a tmp git repo with a tagged commit) — fetches into
  `let-go/source/<version>/`, second call is a no-op (`:installed? false`),
  tag-not-found errors clearly. Parameterize the repo URL + `home` so the test
  hits the fixture, not GitHub.
- **Check** (unit, `test/lgx/<…>_test.lg`): warn vs fail by command tier;
  exact-match pass; mismatch; `LGX_SKIP_VERSION_CHECK` bypass; `dev`/absent `lg`
  skip; unpinned no-op. Inject the "installed version" so it doesn't need a real
  `lg`.
- **Wiring end-to-end** (`tests/e2e.sh`, hermetic — no network): unpinned
  `lgx install` prints **no** `Fetched` line; with the cache dir **pre-seeded**
  at `$LGX_HOME/let-go/source/<version>/`, a pinned `lgx install` prints the
  already-present line and does not clone; the warn/fail tiers surface through
  the real binary (installed version stubbed via the check's seam). The actual
  clone is covered by the unit fetch test against the `file://` fixture, so e2e
  never hits GitHub.

## File Structure

- **Modify `lgx/config.lg`** — add `:lg-version` to `lgx-schema`; add
  `config/lg-version` accessor.
- **Modify `lgx/cache.lg`** — expose `clone-tag!` (or wrapper); add
  `ensure-letgo-source!` + the `let-go/source/<version>` path helper.
- **Modify `lgx.lg`** — `cmd-install` source-fetch + logging;
  `lg-installed-version` + `check-lg-version!`; preflight calls in
  `cmd-run`/`cmd-nrepl` (warn) and `cmd-build`/`cmd-test` (fail).
- **Modify `test/lgx/config_test.lg`** — schema + accessor tests.
- **Create `test/lgx/cache_test.lg`** — fetch tests (file:// remote fixture).
- **Add a check-logic unit test** — `test/lgx/<module>_test.lg` for
  `check-lg-version!` tiers/bypass/skip.
- **Modify `tests/e2e.sh` + `tests/fixtures/`** — install source-fetch line +
  warn/fail tiers through the real binary, with a tagged git fixture remote.
- **Modify `README.md`** — `:lg-version` reference, mechanism section, Commands
  table row.
- **Create `docs/knowledge-base/let-go-version-pinning.md`** (optional) — deeper
  rationale + editor integration.

Reuse `clone-tag!`, `finalize-worktree!`, `(home/root)`, `path/join`,
`config/main` (as the accessor template), the `os/sh` `lg` invocation, and the
`spec.lg` schema engine. No new external dependencies.

---

## Tasks

### Task 1: Schema + accessor for `:lg-version`

**Files:**
- Modify: `lgx/config.lg`
- Modify: `test/lgx/config_test.lg`

- [ ] **Step 1: Write failing tests**
  - `lgx.edn` with `:lg-version "1.10.0"` validates; with `:lg-version ""` or a
    non-string fails validation; absent validates.
  - `config/lg-version` returns `"1.10.0"` when present, `nil` when absent.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL (key unknown to the closed schema / accessor missing).

- [ ] **Step 3: Implement**
  Add `[:lg-version {:optional true} <non-blank-string-schema>]` to `lgx-schema`
  (reuse the same string shape `:main`/paths use, minus path semantics). Add
  `config/lg-version` returning `(:lg-version cfg)`.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS (no regressions in existing config tests).

- [ ] **Step 5: Commit**
  `git commit -m "Add optional :lg-version key to lgx.edn schema"`

### Task 2: `ensure-letgo-source!` in cache.lg

**Files:**
- Modify: `lgx/cache.lg`
- Create: `test/lgx/cache_test.lg`
- Modify: `tests/fixtures/` (tagged `file://` git remote fixture)

- [ ] **Step 1: Write failing tests** (against a local `file://` git remote: a
  tmp repo with one commit tagged `v0.0.1`)
  - `ensure-letgo-source!` with version `"0.0.1"` clones into
    `<home>/let-go/source/0.0.1/`, returns `:installed? true`, and the worktree
    has no `.git`.
  - A second call returns `:installed? false` and does not re-clone.
  - A missing tag errors with a message naming the version.
  (Parameterize the repo URL/`home` for the test so it points at the fixture,
  not GitHub.)

- [ ] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL (fn missing).

- [ ] **Step 3: Implement**
  - Make `clone-tag!` callable from the new fn (drop the `-`/private or add a
    thin public wrapper).
  - `ensure-letgo-source!`: compute `(path/join (home/root) "let-go" "source"
    version)`; if it exists, return `{:installed? false :dir …}`; else
    `clone-tag!` the let-go repo at tag `v<version>` into it; return
    `{:installed? true :dir …}`. Confirm nooga/let-go's tag format (`v<version>`
    vs `<version>`) and use the correct one.
  - **Testability seam**: take the repo URL (and, if not already global, the
    cache base) as parameters defaulting to `nooga/let-go` and `(home/root)`, so
    the unit test points them at the `file://` fixture without touching GitHub.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -m "Fetch let-go source into LGX_HOME/let-go/source/<version>"`

### Task 3: Wire source fetch into `lgx install`

**Files:**
- Modify: `lgx.lg` (`cmd-install`)
- Modify: `tests/e2e.sh` + `tests/fixtures/` (install behavior)

- [ ] **Step 1: Write failing test/e2e**
  With a project whose `lgx.edn` pins `:lg-version "0.0.1"` (pointing the fetch
  at the fixture remote), `lgx install` fetches the source and prints a
  `Fetched let-go 0.0.1 source …` line; a second `install` prints the
  already-present line and does not re-clone; an unpinned project prints neither.

- [ ] **Step 2: Run to verify it fails**
  Run: `make test`
  Expected: FAIL.

- [ ] **Step 3: Implement**
  In `cmd-install`, after the deps step, when `config/lg-version` is set, call
  `ensure-letgo-source!` and print `Fetched let-go <version> source (for editor
  navigation)` on fresh fetch / a quiet up-to-date line otherwise. Report a
  clone/network failure as its own warning without failing the (already
  successful) deps install.
  **Restructure so the fetch runs even with empty `:deps`** — today `cmd-install`
  early-returns on the `no deps in lgx.edn` branch; a deps-less project that
  pins `:lg-version` must still fetch the source.

- [ ] **Step 4: Run to verify it passes**
  Run: `make test`
  Expected: PASS.

- [ ] **Step 5: Commit**
  `git commit -m "lgx install: fetch let-go source when :lg-version is pinned"`

### Task 4: Version compatibility check (warn run/nrepl, fail build/test)

**Files:**
- Modify: `lgx.lg`
- Add: `test/lgx/<module>_test.lg` (check logic) + `tests/e2e.sh` (tiers via the binary)

- [ ] **Step 1: Write failing tests**
  - Pinned + matching installed version → no message, proceeds.
  - Pinned + mismatch → `cmd-run`/`cmd-nrepl` warn (once) and proceed;
    `cmd-build`/`cmd-test` fail (non-zero) with both versions shown.
  - `LGX_SKIP_VERSION_CHECK=1` → bypasses both tiers.
  - `dev`/absent `lg` → info skip, proceeds, no fail.
  - Unpinned → no check.
  (Stub/inject the "installed version" so tests don't depend on a real `lg`.)

- [ ] **Step 2: Run to verify they fail**
  Run: `make test`
  Expected: FAIL.

- [ ] **Step 3: Implement**
  - `lg-installed-version`: run `lg -v`, parse the version token; `nil`/`:dev`
    when unparseable or `lg` absent.
  - `check-lg-version!` (taking a severity): exact compare; honor
    `LGX_SKIP_VERSION_CHECK`; warn-once; clear remediation text.
  - Call at warn in `cmd-run`/`cmd-nrepl`, at fail in `cmd-build`/`cmd-test`,
    only when `config/lg-version` is set.

- [ ] **Step 4: Run to verify they pass**
  Run: `make test`
  Expected: PASS (existing run/build/test behavior unchanged when unpinned).

- [ ] **Step 5: Commit**
  `git commit -m "Check lg version against :lg-version (warn run/nrepl, fail build/test)"`

### Task 5: Docs

**Files:**
- Modify: `README.md`
- Create: `docs/knowledge-base/let-go-version-pinning.md` (optional)

- [ ] **Step 1: README reference + section**
  Add `:lg-version "1.10.0"` (commented, one-line description) to the
  `## Configuration: lgx.edn` example. Add a concise `### let-go version pinning`
  section (mechanism, cache path, warn/fail tiers, `LGX_SKIP_VERSION_CHECK`, and
  "lgx does not install `lg`"). Update the `lgx install` Commands-table row.

- [ ] **Step 2: Knowledge-base note (optional)**
  `docs/knowledge-base/let-go-version-pinning.md` — rationale and the
  editor/clj-pulse integration, matching the existing `let-go-*.md` notes. Use
  the /writing-clearly skill.

- [ ] **Step 3: Commit**
  `git commit -m "Document :lg-version pinning and the source-fetch mechanism"`

---

## Notes & limitations

- **Editor navigation is opt-in via the pin.** With no `:lg-version`, no source
  is fetched and editor core-navigation stays off — by design (install is
  read-only; nothing is stamped automatically).
- **Source ≠ runtime guarantee.** Since lgx does not fetch the binary, the
  fetched source can drift from the `lg` actually on PATH; the compatibility
  check is the guardrail (warn/fail). Eliminating drift entirely would require
  lgx to manage the binary too — explicitly out of scope.
- **Tag-format assumption** (`v<version>`) must be confirmed against
  nooga/let-go releases during Task 2.
