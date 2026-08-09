# Transitive Deps Discovery and Auto-Resolution Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve git-pinned transitive deps from a dependency's own deps.edn/project.clj automatically, resolve well-known mvn-style transitives via a curated registry, and warn helpfully about everything else — keeping gitlibs as lgx's only resolution mechanism and adding no `:mvn/version` support.

**Tech Stack:** let-go (.lg), pinned lg 1.12.2 (no new lg features required), git. No new dependencies (grenadine is NOT used).

---

## Design

### Context and decision

This plan supersedes the parked Maven plan
(`docs/plans/2026-08-05-0228-mvn-deps.md`). Rationale for parking, agreed
in discussion: let-go-compatible libs are shallow by natural selection (a
deep transitive tree almost always hits Java interop and cannot run under
let-go anyway — the 8 libs in `examples/clojure-libs/` needed 0–2 extra
coords each), and `:mvn/version` in the lgx.edn schema is a one-way door
committing lgx to a Maven subsystem permanently. Gitlibs stays the single
resolution mechanism and cache.

The pain this plan actually targets is **discovery**: today a missing
transitive dep surfaces as a confusing require-time failure, and mapping a
Maven coordinate to a git repo + tag is manual work (the coordinate group
usually does NOT match the GitHub owner: `integrant/integrant` lives at
`weavejester/integrant`, `aero/aero` at `juxt/aero`, `org.clojure/*` at
`clojure/*`).

### The resolution ladder

When `ensure-all!` fetches a dep, transitive coords come from the first
available source:

1. **Dep has `lgx.edn`** → its `:deps` are resolved exactly as today
   (`config/coords-at`). deps.edn/project.clj are NOT read. Unchanged.
2. **Else `deps.edn`** (lenient read, top-level `:deps` only, aliases
   ignored) → each declared dep is classified and handled per the table
   below.
3. **Else `project.clj`** (lenient: `edn/read-string` the first form; if
   it is a `(defproject …)` list, find the `:dependencies` vector and
   translate `[lib "1.2.3"]` entries into `{:mvn/version "1.2.3"}`
   pairs). Anything that fails to parse or doesn't match this shape is
   silently skipped — these are third-party files and this path is
   best-effort.

   **Fallback trigger is file existence, not result emptiness:** the
   caller checks `file-exists?` — `project.clj` is consulted only when
   `deps.edn` is absent. A present deps.edn is authoritative even when
   empty or unparsable (`{}` legitimately means zero deps; a stale
   project.clj beside it must not resurrect old ones).

Per declared dep from source 2 or 3, after dropping entries matched by
the consuming coord's `:exclusions` and the built-in skip list
(`org.clojure/clojure`, `org.clojure/spec.alpha`,
`org.clojure/core.specs.alpha`):

| Declared shape | Action |
|---|---|
| Well-formed git coord: `:git/url` + (`:git/sha` or `:git/tag`) | **Auto-resolve**: queue as a BFS child (deps.edn requires sha, so these are fully pinned — no guessing) |
| Inferred-URL git coord: `io.github.X/Y` or `com.github.X/Y` lib name with `:git/sha`/`:git/tag`, no `:git/url` | **Auto-resolve** with `https://github.com/X/Y` |
| mvn-style (`:mvn/version`), lib in the **registry** | **Auto-resolve**: registry gives `:git/url` (+ optional `:deps/root`), tag from the entry's `:tag-format` applied to the version |
| mvn-style, lib name is a URL-certain group (`io.github.X/Y` / `com.github.X/Y`) | **Probe**: `git ls-remote` the candidate tags `<version>` and `v<version>`; on a hit, resolve; on miss, warn |
| mvn-style, unknown | **Warn** (see warning rules) |
| `:local/root` | Resolve relative to the dep's own dir (matches existing lgx.edn transitive behavior) |
| anything else / malformed | Warn |

Auto-resolved children carry provenance (`:via <declaring lib>`) and
recurse in the same walk — their own deps.edn/project.clj is read when
they are fetched. First-wins dedup by lib name (the existing `seen` map)
applies unchanged, so a top-level coord in the user's lgx.edn always
overrides anything declared by a dep.

**Error containment:** any failure while acting on third-party metadata —
registry clone fails (tag moved), probe-resolved clone fails, inferred
URL 404s — degrades to a warning and the walk continues. The status quo
without this feature is "not resolved at all", so failing soft is strictly
better. Hard errors remain only on the existing lgx.edn-sourced paths,
which the user controls.

### Warning rules

- Emitted **after the walk completes** (so a dep resolved later in BFS
  order never falsely warns), and gated by command:
  - **`lgx install` shows all pending warnings, always** — it is the
    deliberate dependency-management moment, and it doubles as the
    "re-show me the warnings" command. This also covers `:local/root`
    deps, whose `:installed?` is hardcoded false
    (`lgx/cache.lg:156`) and which would otherwise never warn.
  - **run/build/test warn only for deps freshly installed in that walk**
    (`:installed?` true — the moment a lib is being added); cached runs
    stay silent, so a deliberate partial-use setup is not nagged in the
    day-to-day loop. `:exclusions` silences permanently.
  Mechanically: `ensure-all!` gains a `warn-all?` flag; `cmd-install`
  passes true, `basis` callers false.
- One stderr line per miss, existing warning style, declared coord
  verbatim (so the version needed for tag-picking is visible):

  ```
  warning: dev.weavejester/integrant declares weavejester/dependency {:mvn/version "0.2.1"} - not resolved by lgx; add a :git coord to lgx.edn :deps or exclude it (see examples/clojure-libs/)
  ```

- **Suppression matching** (is a declared dep already resolved?) is
  tiered by available identity — it is a heuristic and must never gate
  anything:
  - declared coord has a URL (explicit or inferred) → normalized-URL
    match against resolved coords (strong);
  - mvn-style → exact lib symbol match, else artifact-segment match (the
    name after `/` equals a resolved lib's name segment — so declared
    `weavejester/dependency` is suppressed when the user listed
    `dev.weavejester/dependency`).

### `:exclusions` on coords

Any lgx.edn coord may carry `:exclusions [lib-sym …]` — tools.deps
vocabulary, per-consuming-dep scope: the listed symbols, matched exactly
as written in that dep's deps.edn/project.clj, are skipped entirely (no
auto-resolution, no warning). Schema: optional vector of symbols, valid
on every coord type. Nuance vs tools.deps (documented, accepted): applies
to the dep's direct declarations, not a whole subtree — observably the
same for the shallow trees this ecosystem has.

### The registry

`lgx/registry.lg`: a data literal mapping mvn lib symbols to verified git
coordinates — **curated fact, not guessing**:

```clojure
{integrant/integrant {:git/url "https://github.com/weavejester/integrant"
                      :tag-format "%s"}
 org.clojure/tools.cli {:git/url "https://github.com/clojure/tools.cli"
                        :tag-format "…verified…"
                        :deps/root "src/main/clojure"}
 …}
```

- Entry shape: `:git/url` (required), `:tag-format` (required — a format
  string applied to the declared version, e.g. `"%s"` or `"v%s"`),
  `:deps/root` (optional, e.g. tools.cli).
- Seeded from the already-verified `examples/clojure-libs/` set (8 libs +
  their transitive deps), each entry's URL and tag format checked against
  the live repo (`git ls-remote`) during implementation. Include old and
  new group aliases where both exist on Clojars
  (`weavejester/dependency` AND `dev.weavejester/dependency` →
  same repo; `medley/medley` AND `dev.weavejester/medley`; `bond/bond`
  AND `circleci/bond`).
- Miss is never an error — it falls to the warning rung. New mappings
  ship with lgx releases; the escape hatch until then is an explicit
  top-level git coord (first-wins already overrides).

### Install-output provenance

`print-installs!` annotates installs that came from third-party metadata:

```
installing 2 dep(s)...
  dev.weavejester/integrant -> ~/.lgx/gitlibs/...
  weavejester/dependency -> ~/.lgx/gitlibs/...  (via dev.weavejester/integrant deps.edn)
```

Result rows gain optional `:via` (declaring lib symbol) and `:via-source`
(`:deps-edn` / `:project-clj` / `:registry`); rows without `:via` print
exactly as today.

### Teaching schema error

In `coord-errors` (`lgx/config.lg:64`), a coord containing `:mvn/version`
gets a dedicated message BEFORE the generic missing-`:git/url` checks:
`":mvn/version is not supported - let-go runs Clojure libs from source; use :git/url + :git/tag (or :git/sha) pointing at the lib's repo (see examples/clojure-libs/)"`.
Someone pasting a deps.edn coord from a README gets taught, not confused.
The key stays unoccupied — no API commitment.

### Ergonomics, honestly

Rated in discussion: ~6/10 for a general Clojure audience (mvn-style
transitives outside the registry still need a manual URL+tag hunt; no
version mediation), ~8/10 for lgx's actual audience (shallow curated
ecosystem, everything pinned and reproducible, discovery gap closed,
deps.edn-native and registry libs fully automatic). If lgx's ambition
grows to "any Clojars lib just works", the parked Maven plan is the
answer — this plan deliberately keeps that door open.

### Out of scope

- `:mvn/version` support in lgx.edn (parked plan)
- Reading deps.edn `:aliases`, `:paths`; project.clj profiles
- Version mediation beyond first-wins
- A `lgx deps` inspection command (natural follow-up, not now)

---

## File Structure

- **Create** `lgx/registry.lg` — registry data literal + `lookup` fn +
  entry→coord translation (tag-format application).
- **Create** `test/lgx/registry_test.lg` — lookup + translation tests.
- **Modify** `lgx/config.lg` — `:exclusions` validation on coords;
  `:mvn/version` teaching error; `declared-deps-at` (lenient deps.edn
  reader); `project-clj-deps-at` (lenient project.clj reader); declared-
  coord classification (`classify-declared`); suppression matching
  (`unresolved-declared`).
- **Modify** `test/lgx/config_test.lg` — schema + reader + classification
  + suppression tests.
- **Modify** `lgx/cache.lg` — `tag-exists?` probe helper (`git ls-remote
  <url> refs/tags/<tag>`), reusing the `git!` wrapper.
- **Modify** `test/lgx/cache_test.lg` — probe tests against `file://`
  fixture repos (existing pattern).
- **Modify** `lgx.lg` — `ensure-all!` ladder integration, post-walk
  warning emission, provenance in results; `print-installs!` annotation.
- **Modify** `tests/e2e.sh` — scenarios for auto-install, warning,
  exclusion, provenance.
- **Modify** `docs/ARCHITECTURE.md` — transitive resolution section.
- **Modify** `docs/plans/2026-08-05-0228-mvn-deps.md` — PARKED status
  note.

---

### Task 1: Schema — `:exclusions` + `:mvn/version` teaching error

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write failing tests**
  Valid: `:exclusions ['a/b 'c/d]` on a git coord and on a local coord.
  Invalid: `:exclusions` not a vector / containing non-symbols → error
  naming the key. A coord `{:mvn/version "1.0"}` → single error whose
  message contains ":mvn/version is not supported" and "see
  examples/clojure-libs/" (and does NOT also emit the generic
  "missing :git/url" noise).

- [x] **Step 2: Run tests to verify they fail**
  Run: `bin/lgx test` (after `make build`)
  Expected: FAIL on the new assertions.

- [x] **Step 3: Implement in `coord-errors`**
  The `:mvn/version` check comes first and short-circuits; `:exclusions`
  validation applies to all coord shapes. Coord maps stay open.

- [x] **Step 4: Run tests to verify they pass**
  Run: `bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Add :exclusions to coords; teach :mvn/version rejection"`

> Deviation: extended the existing `at-key` helper to nest `{:path :msg}`
> maps (not just plain strings) so `:exclusions` entry errors get an index
> in their path; needed because per-item errors carry a relative path.

Codex review: no findings.

### Task 2: Lenient declared-deps readers

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write failing tests**
  `declared-deps-at`: missing deps.edn → `[]`; unparsable → `[]` (no
  throw, no output); valid → `[lib coord]` pairs; non-map `:deps` → `[]`.
  `project-clj-deps-at`: missing → `[]`; a normal `(defproject foo "1.0"
  :dependencies [[a/b "1.2"] [c "3.4"]])` → pairs with
  `{:mvn/version "1.2"}` coords (bare symbol `c` → `c/c`? No — keep the
  symbol as written); a project.clj with reader-unfriendly content
  (`~unquote`) → `[]` silently.

- [x] **Step 2: Run tests to verify they fail**
  Run: `bin/lgx test`
  Expected: FAIL (fns unresolved).

- [x] **Step 3: Implement both readers**
  Next to `coords-at`. Unlike `coords-at`, these NEVER throw — any
  parse or shape surprise returns `[]`. Wrap `edn/read-string` in
  try/catch; for project.clj walk the defproject list for the keyword
  `:dependencies` followed by a vector.

- [x] **Step 4: Run tests to verify they pass**
  Run: `bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Read declared deps from deps.edn and project.clj leniently"`

> Deviation: `~unquote` and `#"regex"` do NOT defeat let-go's reader (it
> reads them as `(unquote …)` / `(re-pattern …)`), so the planned
> "reader-unfriendly → []" test was rewritten to assert the opposite —
> such a project.clj still yields its `:dependencies`. Unparsable input is
> still covered (empty file, truncated form, non-list top level).
>
> Deviation: Leiningen entries carry trailing options
> (`[org.clojure/clojure "1.7.0" :scope "provided"]`); the reader takes the
> first two elements and ignores the rest. Also drops non-symbol lib keys
> from a deps.edn `:deps` map.

Codex review: no findings.

> Finding (upstream let-go, recorded for Task 8): let-go's `edn/read-string`
> throws on `#_` in a map **value** position — `{:a #_:x 1}` fails while
> `{:a 1 #_:x :b 2}` parses. malli's real `deps.edn` uses the former, so it
> reads as `[]`. Correct per the lenient contract and no regression (malli's
> transitives are listed explicitly today), but it silently costs
> auto-resolution for such files.

### Task 3: Classification and suppression matching

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write failing tests**
  `classify-declared` — a pure fn `[lib coord] -> {:action … :coord …}`
  covering the ladder table: well-formed git → `{:action :resolve}` with
  the coord as-is; inferred `io.github.X/Y`+sha → `:resolve` with
  synthesized `:git/url`; mvn-style → `{:action :mvn :version …}`
  (registry/probe decision happens in lgx.lg, not here);
  `:local/root` → `:resolve`; skip-list libs → `{:action :skip}`;
  malformed → `{:action :warn}`.
  `unresolved-declared` — suppression: URL-normalized match (trailing
  `.git`, trailing slash) suppresses; exact lib match suppresses;
  artifact-segment match suppresses (`weavejester/dependency` vs
  resolved `dev.weavejester/dependency`); non-matching lib is returned.
  `:exclusions` filtering: exact declared-symbol match removes the entry
  before classification.

- [x] **Step 2: Run tests to verify they fail**
  Run: `bin/lgx test`
  Expected: FAIL.

- [x] **Step 3: Implement the pure fns**
  All in `lgx/config.lg`, no I/O. Inferred-URL rule: lib groups
  `io.github.X` / `com.github.X` → `https://github.com/X/<name>`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Classify declared transitive deps and match resolved libs"`

> Deviation: `classify-declared` also accepts `:sha` as a spelling of
> `:git/sha` (normalizing it away in the returned coord). Real deps.edn
> files use both — malli, dynaload, and tools.cli all declare git coords
> with plain `:sha`, and without this they would all fall to `:warn`.
>
> Deviation: the exclusions filter landed as its own exported pure fn
> `without-exclusions`, rather than being folded into the caller, so it is
> directly testable.

Codex review: one P2 — `{:local/root ""}` classified as resolvable, which
would resolve to the declaring dep's own directory. Fixed in `77c3872`
(blank roots now `:warn`, matching lgx's own schema) with a test.

### Task 4: Registry

**Files:**
- Create: `lgx/registry.lg`
- Test: `test/lgx/registry_test.lg`

- [x] **Step 1: Verify the seed mappings**
  For each lib in `examples/clojure-libs/` and its transitives, confirm
  URL and tag format against the live repo:
  `git ls-remote <url> "refs/tags/*"` and check how the example's pinned
  version appears (e.g. `1.0.1` vs `v1.0.1` vs contrib-style). Record
  the verified `:tag-format` per entry. Seed set: integrant, aero,
  hiccup, bond, medley, malli (+ borkdude/dynaload), tools.cli
  (+ `:deps/root "src/main/clojure"`), dependency — each under BOTH its
  old and new Clojars groups where both exist.

- [x] **Step 2: Write failing tests**
  `lookup`: known lib → entry; unknown → nil; old-group alias and
  new-group alias hit the same URL. `entry->coord`: applies
  `:tag-format` to a version (`"0.2.1"` + `"v%s"` → `:git/tag "v0.2.1"`),
  carries `:deps/root` through.

- [x] **Step 3: Run tests to verify they fail**
  Run: `bin/lgx test`
  Expected: FAIL.

- [x] **Step 4: Implement `lgx/registry.lg`**
  Data literal + the two fns. Pure; no I/O in this namespace.

- [x] **Step 5: Run tests to verify they pass**
  Run: `bin/lgx test`
  Expected: PASS.

- [x] **Step 6: Commit**
  `git commit -m "Add curated registry of known Clojure lib git mappings"`

> Deviation: the plan's alias list was partly wrong, and following it would
> have put guesses in a table whose whole point is verified fact. Checked
> against the Clojars API: `dev.weavejester/integrant`,
> `dev.weavejester/hiccup`, and `dev.weavejester/dependency` return 404 —
> those three publish under one group only (`integrant/integrant`,
> `hiccup/hiccup`, `weavejester/dependency`), so no alias rows were added
> for them. `medley/medley` + `dev.weavejester/medley` and `bond/bond` +
> `circleci/bond` do both exist and are both listed. The
> `examples/clojure-libs/` lgx.edn files use `dev.weavejester/…` as local
> lib *labels*, which is what the plan appears to have read as Clojars
> groups; registry keys must match what deps.edn files actually declare.
>
> Deviation: added a third fn, `coord-for` (lookup + translate), so
> `ensure-all!` has one call rather than two.
>
> All 11 rows were live-verified with `git ls-remote --tags`. 10 resolve for
> their current Clojars version; `bond/bond 0.2.6` misses because the old
> group's releases predate any tag in circleci/bond. Documented in the
> registry header — it degrades to a warning, never a wrong checkout.

Codex review: no findings.

### Task 5: Tag probe helper

**Files:**
- Modify: `lgx/cache.lg`
- Test: `test/lgx/cache_test.lg`

- [x] **Step 1: Write failing tests**
  `tag-exists?`: against a `file://` fixture repo (existing cache_test
  pattern) with a known tag — present tag → true, absent → false,
  unreachable url → false (no throw; this feeds the warn-not-error
  ladder).

- [x] **Step 2: Run tests to verify they fail**
  Run: `bin/lgx test`
  Expected: FAIL.

- [x] **Step 3: Implement**
  `git ls-remote <url> refs/tags/<tag>` via the existing `git!` style
  but returning false on failure instead of throwing.

- [x] **Step 4: Run tests to verify they pass**
  Run: `bin/lgx test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Add tag existence probe"`

> Deviation: the probe does not reuse `git!` — `git!` throws on non-zero
> exit, which is the opposite of what this fn promises. It shells out
> directly and converts every failure to false. It also runs under
> `env GIT_TERMINAL_PROMPT=0`: the URLs it probes are inferred from lib
> names, and a guess landing on a private/nonexistent https repo would
> otherwise leave git waiting for a username.
>
> Test reused the existing `setup-tagged-repo!` helper (a real local repo)
> rather than the `ensure-lib!` tests' pre-created-cache-dir trick, since a
> probe needs an actual remote to answer.

Codex review: one P2 — no deadline, so a remote that accepts the connection
then stalls could hang `lgx install`. Fixed in `b2562a4` with git's own
`http.lowSpeedLimit`/`http.lowSpeedTime` (portable; macOS ships no
`timeout`). Verified against a socket server that accepts and never
responds: returns false after ~10s instead of hanging.

### Task 6: ensure-all! integration

**Files:**
- Modify: `lgx.lg`

- [x] **Step 1: Wire the ladder into the BFS**
  In `ensure-all!` (`lgx.lg:71`): when a fetched dep has no lgx.edn,
  read `declared-deps-at`, falling back to `project-clj-deps-at`. Apply
  the consuming coord's `:exclusions`, then `classify-declared`:
  - `:resolve` → queue as child with provenance
    `[lib coord dir {:via <declaring-lib> :via-source :deps-edn|:project-clj}]`.
  - `:mvn` → registry `lookup` → `entry->coord` → queue with
    `:via-source :registry`; else URL-certain group → `tag-exists?`
    probe on `<version>` then `v<version>` → queue on hit; else
    accumulate a pending warning `{:declaring lib :declared [lib coord]
    :installed? <declaring dep's installed? flag>}`.
  - `:skip` → nothing; `:warn` → accumulate.
  Auto-resolution failures (clone error on a third-party-sourced child)
  are caught, converted to pending warnings, and the walk continues —
  they must NOT abort the command. lgx.edn-sourced children keep today's
  hard-error behavior.
  After the loop: drop pending warnings whose declared dep matches a
  resolved lib (`unresolved-declared`); then, unless `warn-all?` is set,
  drop those whose declaring dep was not freshly installed; emit one
  line each in the exact format from the Design section. `ensure-all!`
  takes the `warn-all?` flag: `cmd-install` passes true, `basis` false.
  deps.edn vs project.clj selection is by `file-exists?` on deps.edn
  (Design fallback rule), not by empty result.

- [x] **Step 2: Provenance in output**
  Thread `:via`/`:via-source` into result rows; extend `print-installs!`
  to append `  (via <lib> deps.edn)` / `(via <lib> project.clj)` /
  `(via <lib> registry)` for rows that have it.

- [x] **Step 3: Sanity-run the suite**
  Run: `bash tests/run.sh`
  Expected: PASS (all existing tests unaffected — no fixture in the
  current suite has a deps.edn, so behavior is unchanged for them).
  **Result: unit tests PASS (512 tests, 745 assertions). e2e FAILS on
  three pre-existing scenarios — see the blocker below.** Task 6's own
  behavior was verified manually end-to-end instead: auto-resolve with
  `(via test/liba deps.edn)` provenance and the child usable at runtime;
  warning in the exact planned format; `org.clojure/clojure` skipped;
  `lgx install` re-showing the warning on a warm cache; `lgx run` silent
  on a warm cache; `:exclusions` silencing it permanently.

- [x] **Step 4: Commit**
  `git commit -m "Auto-resolve and warn on transitive deps from deps.edn/project.clj"`

> Deviation: queue entries became maps (`{:lib :coord :base :via
> :via-source :via-installed?}`) instead of `[lib coord base]` vectors —
> provenance needs more fields than a positional vector carries well.
>
> Deviation: added a fourth `:via-source`, `:probe`, printing as
> `(via <lib> tag probe)`. The plan listed only
> `:deps-edn`/`:project-clj`/`:registry`, but a probe-resolved coord came
> from neither the registry nor the declaring file verbatim, and labelling
> it as either would misreport where the pin came from.
>
> Deviation: rung selection uses `file-exists?` on the dep's *lgx.edn* too,
> not just deps.edn — `coords-at` returns `[]` for both "absent" and "no
> :deps", and an lgx.edn declaring zero deps must not fall through to
> deps.edn.

---

## Suite status on this branch (diagnosed)

`bash tests/run.sh` was already red at the branch point (`d2c0476`, before
any code commit from this plan). Both failures trace to one thing this
branch changed before the plan started: `.mise.toml` pins **lg 1.12.2**
where `master` pins **lg 1.11.1**.

Proven by holding the lgx binary fixed and varying only `LGX_LG`:

| | lg 1.11.1 | lg 1.12.2 |
|---|---|---|
| `:deps` enumeration order | `libA libB` | `libB libA` (before the fix below) |
| require-time compile error | swallowed, `error: failed to load` on stderr | thrown, hard compile error |

- **Scenario 65** (relative local conflicts) failed because 1.12.2
  enumerates the project's `:deps` map in a different order, and lgx let
  that order decide which of two conflicting sibling coords first-wins
  keeps. **Fixed** in `6101f0b` per the approved option A: every coord map
  now reaches the resolver through `config/dep-pairs`, ordered by lib name,
  so resolution no longer depends on let-go's map iteration at all. Both lg
  versions now give `libA libB`.
- **Scenarios 68 and 70** (`lgx test` on a file that fails to compile /
  has a syntax error) fail because 1.12.2 **throws** instead of swallowing
  — which is precisely the upstream fix asked for in
  `docs/issues/load-failure-silent.md`. So `lgx: a test file failed to
  load` never prints: the test runner's stderr-scanning detection exists
  only to catch the swallow that no longer happens. Pre-existing, unrelated
  to transitive deps, and addressed in Task 9 below so the suite can be
  verified green.

**Correction to an earlier note in this file:** the ordering flip was first
attributed to Task 1's `config.lg` edit, "verified" by blob and binary
hashes. That was wrong — the confound was `.mise.toml`, since
`mise which lg` resolves a different binary per branch, so every
master-vs-branch comparison silently swapped the lg version too. Task 1's
content is not implicated.

### Task 7: e2e scenarios

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add scenarios (existing bare-repo fixture style)**
  1. **Auto-install:** bare repo A whose tree contains a `deps.edn`
     declaring bare repo B via `{:git/url "file://…B" :git/sha <sha>}`;
     project depends only on A → `lgx install` installs both; output
     contains `(via test/lib-a deps.edn)`; `lgx run` of a script
     requiring B's namespace works.
  2. **Warning + gating:** repo A declares `unknown/lib
     {:mvn/version "1.2.3"}` → first `lgx install` stderr contains
     `declares unknown/lib {:mvn/version "1.2.3"} - not resolved`;
     a second `lgx install` STILL warns (explicit install always
     re-shows); an `lgx run` on the warm cache does NOT warn.
  3. **Exclusion:** same fixture but project coord has
     `:exclusions [unknown/lib]` → no warning even on `lgx install`.
  4. **project.clj:** repo with only a `project.clj` declaring
     `unknown/lib "1.2.3"` → warning fires with translated coord; a
     repo with BOTH files where only project.clj declares deps → no
     warning (deps.edn is authoritative when present).
  5. **Soft failure:** repo A's deps.edn declares a git coord whose
     `:git/url` points at a nonexistent `file://` path → `lgx install`
     exits 0, installs A, and warns about the failed child instead of
     aborting.

- [x] **Step 2: Run the full suite**
  Run: `bash tests/run.sh`
  Expected: PASS.

- [x] **Step 3: Commit**
  `git commit -m "Add e2e coverage for transitive deps discovery"`

### Task 8: Docs and parking note

**Files:**
- Modify: `docs/ARCHITECTURE.md`, `docs/plans/2026-08-05-0228-mvn-deps.md`

- [x] **Step 1: ARCHITECTURE.md**
  Extend the transitive-deps section (near the existing lgx.edn
  transitive text, `docs/ARCHITECTURE.md:565-580`): the source ladder
  (lgx.edn > deps.edn > project.clj), the classification table, the
  registry, `:exclusions`, warning rules, and the containment principle
  (third-party metadata failures warn, never abort). Use
  /writing-clearly.

- [x] **Step 2: Park the Maven plan**
  Add a status header to `docs/plans/2026-08-05-0228-mvn-deps.md`:
  **PARKED** (date), superseded by this plan, two-line rationale
  (shallow ecosystem / one-way door), note that the let-go natives it
  needed (`os/unzip`, `hash/sha*`) are merged upstream, and that it
  remains executable if ecosystem-scale demand materializes.

- [x] **Step 3: Manual registry smoke (network)**
  The registry and probe branches can't be exercised hermetically (the
  registry is compiled-in and points at real GitHub URLs; the suite is
  network-free — their logic is unit-covered in Tasks 3–5). Verify once
  by hand: temp project depending on
  `dev.weavejester/integrant {:git/url … :git/tag "1.0.1"}` only →
  `lgx install` auto-resolves `weavejester/dependency` via the registry
  with `(via … registry)` in the output.

- [x] **Step 4: Run the full suite one last time**
  Run: `bash tests/run.sh`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "Document transitive discovery; park the Maven plan"`

---

## STATUS: COMPLETE — 2026-08-09

Full suite green: **523 unit tests / 765 assertions** and **314 e2e
assertions**, `bash tests/run.sh` exit 0.

### What was implemented

The resolution ladder as designed. A dep's transitive coords come from its
own `lgx.edn`, else its `deps.edn`, else its `project.clj`, chosen by file
existence. Each declared dep is classified (`config/classify-declared`):
already-pinned git coords resolve as-is, `io.github.X/Y`-style names get
their URL inferred, Maven coordinates resolve through the curated registry
(`lgx/registry.lg`, 11 live-verified rows) or a `git ls-remote` tag probe
when the lib name certifies the repo, and everything else warns. Warnings
land after the walk, are suppressed for anything already resolved, and are
gated by command — `install` always, `run`/`build`/`test` only for a fresh
install. `:exclusions` silences one permanently. Failures on third-party
metadata never abort the command. Install output annotates provenance:
`(via <lib> deps.edn|project.clj|registry|tag probe)`.

Verified end-to-end by hand beyond the e2e suite: `medley/medley
{:mvn/version "1.4.0"}` auto-resolves through the registry and the library
runs; `io.github.cognitect-labs/test-runner {:mvn/version "0.5.1"}`
resolves through the probe to tag `v0.5.1`; integrant's real
`weavejester/dependency {:mvn/version "0.2.1"}` declaration warns with the
declaration verbatim and exits 0.

### Issues encountered

**One genuine detour.** `bash tests/run.sh` was already red at the branch
point, and diagnosing it consumed most of the effort in this plan. Both
failures came from this branch pinning **lg 1.12.2** where `master` pins
**1.11.1** — not from any plan code:

- lg 1.12.2 enumerates a `:deps` map in a different order, and lgx let that
  order decide first-wins conflicts (scenario 65).
- lg 1.12.2 **throws** on a test file's compile error instead of swallowing
  it, so the test runner's stderr-scanning detection never fired
  (scenarios 68, 70).

Two false conclusions were reached and recorded before the real cause was
found: first that Task 1's `config.lg` edit had flipped the map order
("verified" by blob and binary hashes — but every master-vs-branch build
silently swapped the lg version too, since `mise which lg` reads the
checked-out `.mise.toml`), and second that scenarios 68/70 were
contamination from stale binaries. The corrected diagnosis is in
"Suite status on this branch" above. **Lesson: when comparing behaviour
across branches, pin the toolchain explicitly — `.mise.toml` is part of the
diff.**

Both were fixed with the user's approval (Task 9 and `6101f0b`), which also
found a real latent bug: a syntax error in a test file passed silently under
lg 1.12.2. `lgx test` now detects load failures two ways — the harness
never signalling ready (version-independent) and lg's diagnostic shapes
(both the wrapped and bare reader forms). One residual case remains
undetectable and is filed in `docs/issues/load-failure-silent.md`: an
unterminated form running to EOF, which lg 1.12.2 discards with no output
and exit 0.

### Deviations (gathered)

- `at-key` extended to nest `{:path :msg}` maps so `:exclusions` entry
  errors carry an index.
- `classify-declared` accepts `:sha` as well as `:git/sha`; malli,
  dynaload, and tools.cli all use the bare spelling, and without it every
  real git coord fell to `:warn`.
- Exclusions filtering became its own exported fn, `without-exclusions`.
- Registry alias rows corrected against the Clojars API: the plan asked for
  `dev.weavejester/{integrant,hiccup,dependency}` aliases, but all three
  404 — those libs publish under one group. Only medley and bond genuinely
  have two. The plan appears to have read the `dev.weavejester/…` *local
  labels* in `examples/clojure-libs/` lgx.edn files as Clojars groups.
- Added `registry/coord-for` (lookup + translate in one call).
- A fourth `:via-source`, `:probe`, printing as `(via <lib> tag probe)` —
  a probe-resolved coord came from neither the registry nor the file
  verbatim.
- The probe does not reuse `git!` (which throws, the opposite of its
  contract) and runs under `env GIT_TERMINAL_PROMPT=0` plus git's
  `http.lowSpeedLimit`/`http.lowSpeedTime`, so a guessed URL can neither
  prompt for credentials nor hang.
- Queue entries became maps; rung selection also checks for the dep's
  `lgx.edn` by file existence, since `coords-at` returns `[]` for both
  "absent" and "no `:deps`".
- Reader leniency: `~unquote` and `#"regex"` do *not* defeat let-go's
  reader, so that planned test asserts the opposite. Lein entries' trailing
  options (`:scope`) are ignored.
- Added `config/dep-pairs` (approved out-of-plan fix) so coord ordering
  never depends on let-go's map iteration.
- Task 9 added beyond the plan, with approval, to unblock verification.

### Codex review findings addressed

Tasks 1, 2, 4 clean. Task 3: `{:local/root ""}` classified as resolvable
(would resolve to the declaring dep's own directory) — fixed. Task 5: no
deadline on the probe — fixed. Task 6: four P2s — nondeterministic declared
ordering (already fixed by `dep-pairs`), `:exclusions` dropped when
synthesizing a coord from a Maven declaration, fetch-failure warnings
showing the synthesized coord instead of the declaration, and `coord-id`
normalization running outside the fail-soft boundary — all three fixed and
verified. Final branch-level review (covering Tasks 7-9): one P2 — a
third-party `deps.edn` giving `:exclusions` a non-collection value made
`without-exclusions` throw from `empty?`, outside the fail-soft boundary,
aborting the command. Fixed: only a sequential collection of symbols
excludes anything. Verified with a three-level fixture where the middle dep
declares `:exclusions 5` — install exits 0, the child resolves, and its own
unresolvable dep warns.

### What the plan could have specified better

**Pin the toolchain in the plan's own verification step.** The plan said
Task 6 Step 3 should "PASS (all existing tests unaffected)" — but the suite
was already failing when the plan was written, on the lg version the branch
had already adopted. One line establishing the baseline ("`tests/run.sh` is
currently red on N scenarios because of the lg 1.12.2 bump; that is
pre-existing") would have saved the entire detour. More generally: a plan
whose branch changes the toolchain should say so in **Tech Stack** and state
what that breaks. The stated "pinned lg 1.12.2 (no new lg features
required)" was true and still hid the two behaviour changes that mattered.

Second, smaller: the registry seed list should have been given as
*coordinates to verify* rather than as asserted alias facts. Three of its
alias rows were wrong, and only a Clojars check caught it.
