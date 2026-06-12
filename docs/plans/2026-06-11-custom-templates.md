# Custom and Built-in Templates for `lgx new` Implementation Plan ✅ COMPLETED

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `lgx new` scaffold from a user-chosen template — a second built-in (`cli`) or any git URL — via a `-t/--template` flag, reusing the existing cache/render pipeline.

**Tech Stack:** let-go (`.lg`), bash e2e harness (`tests/e2e.sh`).

---

## Design

### CLI surface

```
lgx new <name>                                     # base template (unchanged)
lgx new <name> -t cli                              # built-in by name
lgx new -t cli <name>                              # flag position-independent
lgx new <name> --template https://github.com/u/r  # custom URL, latest HEAD
```

One flag, `-t` / `--template`, taking either a built-in template name or a git
URL. Any value containing `://` is a URL; everything else is a name.

### Parsing (`lgx/cli.lg`)

A pure `parse-new-args`, mirroring `parse-nrepl-args`: walk `new`'s rest-args,
accept `-t`/`--template <value>` at any position, collect positionals.
Returns `{:name "myapp" :template <string-or-nil>}`. Throws `ex-info` with a
user-facing message on:

- missing flag value (`lgx: --template requires a value (built-in name or git URL)`)
- repeated flag (`lgx: --template given more than once`)
- zero positionals (`lgx: new requires a project name`)
- more than one positional (`lgx: new takes exactly one project name`)

Messages carry the `lgx: ` prefix, matching `parse-nrepl-args`; `cmd-new!`
catches, writes `(ex-message e)` plus newline straight to stderr, and exits 1
(the way `cmd-nrepl` does — not via `die!`, which prepends a second `lgx: `).
Existing name/target validation in `lgx/new.lg` is untouched.

### Template resolution (`lgx/new.lg`)

The single `default-template` def becomes a registry:

```clojure
(def templates
  {"base" {:git/url "https://github.com/abogoyavlensky/lgx-template-base"
           :git/sha "1d71ab376f1467ab05d98a8b22570336a1a28c5b"}
   "cli"  {:git/url "https://github.com/abogoyavlensky/lgx-template-cli"
           :git/sha "7948695c318e9bb7a2a9c8ecaf9c8a7959033178"}})
```

`resolve-template-coord` changes from 0-arity to 1-arity, taking the parsed
`-t` value:

| `-t` value | Resolution |
|---|---|
| `nil` | `"base"` from the registry, then `LGX_TEMPLATE_BASE_URL` / `LGX_TEMPLATE_BASE_SHA` env overrides apply (current behavior, preserved) |
| contains `://` | `cache/resolve-head-sha!` runs `git ls-remote <url> HEAD`; result is `{:git/url url :git/sha <head-sha>}` |
| any other string | registry lookup by name; env overrides apply when the name is `"base"` (so `-t base` behaves exactly like the default) |

Resolution errors are thrown as `ex-info` with prefix-free messages and
printed by `cmd-new!` via `die!` (which prepends `lgx: `), in a try/catch of
its own — **not** the existing `ensure-template!` catch, whose
`failed to fetch template:` wrapper would mangle them:

- unknown name → `unknown template: foo (built-in: base, cli)`
- `ls-remote` failure (bad URL, offline, empty output) →
  `failed to resolve template <url>: <git stderr>`

### HEAD resolution (`lgx/cache.lg`)

New `resolve-head-sha!`: shell out `git ls-remote <url> HEAD` via the existing
`git!` wrapper, take the first whitespace-separated token of the first output
line. Throw `ex-info` when the output is blank (the `git!` wrapper already
throws on non-zero exit). Works for `file://` URLs, which both `parse-git-url`
and `git ls-remote` support — used by tests and local template development.

### Caching and rendering — unchanged

The resolved coord flows into the existing pipeline: sha-keyed cache at
`~/.lgx/templates/<host>/<owner>/<repo>/<sha>`, `clone-sha!`, `render!` with
`projectname` substitution (underscored in path segments, hyphenated in
contents). HEAD-resolved shas land in the same cache layout naturally; a
repeat scaffold from the same URL costs one `ls-remote` round-trip, then hits
the cache. Custom templates follow the same authoring contract as `base`:
literal `projectname` placeholder, replaced everywhere.

### Help text and docs

- `command-rows` in `lgx.lg`: the `new` row becomes
  `lgx new <name> [-t <tpl>]` with description
  `Scaffold a let-go app (template: built-in name or git URL)`,
  hand-aligned to `doc-col` (31).
- `README.md`: document `-t/--template`, the built-in names (`base`, `cli`),
  custom-URL behavior (latest default-branch HEAD, cached by sha), and the
  `projectname` placeholder contract for template authors.
- `docs/ARCHITECTURE.md`: update the `new` command description (same-PR doc
  rule from AGENTS.md).

### Testing strategy

- **Unit** (`bin/lgx test`): `parse-new-args` permutations in
  `test/lgx/cli_test.lg`; `resolve-head-sha!` against a local `file://`
  fixture repo in `test/lgx/cache_test.lg`; registry/URL/unknown-name
  resolution in `test/lgx/new_test.lg` (existing 0-arity
  `resolve-template-coord` tests updated to pass `nil`).
- **E2E** (`tests/e2e.sh`, scenarios 105–107, placed inside the template
  fixture block before `rm -rf "$FIXTURE_REPO_DIR"` around line 1185):
  scaffold via `-t file://$FIXTURE_REPO_DIR` without env vars; unknown
  template name fails with the names list; missing flag value fails.
- No e2e against the real GitHub `cli` repo (network-dependent); the registry
  entry is covered by unit tests.

## File Structure

- Modify: `lgx/cli.lg` — add `parse-new-args` (pure parsing only).
- Modify: `lgx/cache.lg` — add `resolve-head-sha!` (git plumbing).
- Modify: `lgx/new.lg` — `templates` registry, 1-arity
  `resolve-template-coord`, `cmd-new!` wiring; add `[lgx.cli :as cli]` to the
  ns requires.
- Modify: `lgx.lg` — `command-rows` help text only (dispatch already forwards
  rest-args to `cmd-new!`).
- Modify: `test/lgx/cli_test.lg`, `test/lgx/cache_test.lg`,
  `test/lgx/new_test.lg`, `tests/e2e.sh`.
- Modify: `README.md`, `docs/ARCHITECTURE.md`.

Each task below ends with a commit; run `make build` before `bin/lgx test`
when source under `lgx/` changed since the last build.

---

### Task 1: `parse-new-args` in `lgx.cli`

**Files:**
- Modify: `lgx/cli.lg`
- Test: `test/lgx/cli_test.lg`

- [x] **Step 1: Write failing tests**
  In `test/lgx/cli_test.lg`, add a `parse-new-args` section (follow the
  existing `parse-nrepl-args` section style, using the local `threw?`
  helper):
  - `["myapp"]` → `{:name "myapp" :template nil}`
  - `["myapp" "-t" "cli"]` and `["-t" "cli" "myapp"]` → `{:name "myapp" :template "cli"}`
  - `["myapp" "--template" "https://github.com/u/r"]` → `{:name "myapp" :template "https://github.com/u/r"}`
  - `["myapp" "-t"]` → throws (missing value)
  - `["-t" "a" "--template" "b" "myapp"]` → throws (repeated flag)
  - `[]` → throws (no name)
  - `["a" "b"]` → throws (two positionals)

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/cli_test.lg`
  Expected: FAIL (missing fn `parse-new-args`)

- [x] **Step 3: Implement `parse-new-args`**
  In `lgx/cli.lg`, after `parse-nrepl-args`: loop over args; on `-t` or
  `--template` consume the next token as the value (throw `ex-info` with the
  messages from the design if value missing or already set); otherwise
  collect as positional. After the loop enforce exactly one positional.
  Return `{:name <first positional> :template <value-or-nil>}`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && ./bin/lgx test test/lgx/cli_test.lg`
  Expected: PASS

- [x] **Step 5: Commit**
  `git commit -m "Add parse-new-args for lgx new template flag"`

### Task 2: `resolve-head-sha!` in `lgx.cache`

**Files:**
- Modify: `lgx/cache.lg`
- Test: `test/lgx/cache_test.lg`

- [x] **Step 1: Write failing tests**
  In `test/lgx/cache_test.lg` (reuse its existing local-git-fixture helpers
  if present, else create a tmp repo with one commit the way
  `test/lgx/new_test.lg`'s `setup-fixture-repo!` does):
  - happy path: `(cache/resolve-head-sha! "file://<fixture>")` equals
    `git -C <fixture> rev-parse HEAD`
  - nonexistent path: `file:///nonexistent/repo` → throws

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/cache_test.lg`
  Expected: FAIL (missing fn `resolve-head-sha!`)

- [x] **Step 3: Implement `resolve-head-sha!`**
  In `lgx/cache.lg` under the git-wrappers section: call
  `(git! ["ls-remote" url "HEAD"] (str "git ls-remote failed: " url))`,
  split `:out` on whitespace, return the first token; throw `ex-info`
  `{:url url}` when output is blank.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && ./bin/lgx test test/lgx/cache_test.lg`
  Expected: PASS

- [x] **Step 5: Commit**
  `git commit -m "Add resolve-head-sha! for HEAD-tracking template URLs"`

### Task 3: template registry and resolution in `lgx.new`

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write/adjust failing tests**
  In `test/lgx/new_test.lg`:
  - Update the five existing `resolve-template-coord-*` tests to call
    `(new/resolve-template-coord nil)`; replace `new/default-template`
    expectations with `(get new/templates "base")`.
  - Add: `(new/resolve-template-coord "base")` honors env overrides the same
    as `nil`; `(new/resolve-template-coord "cli")` (with blank env overrides
    set) returns the pinned cli coord; unknown name throws `ex-info` whose
    message contains `base, cli`; a `file://` fixture-repo URL returns
    `{:git/url <url> :git/sha <rev-parse HEAD>}` (reuse
    `setup-fixture-repo!`).

- [x] **Step 2: Run tests to verify they fail**
  Run: `make build && ./bin/lgx test test/lgx/new_test.lg`
  Expected: FAIL (arity/missing `templates`)

- [x] **Step 3: Implement registry + resolution**
  In `lgx/new.lg`: replace `default-template` with the `templates` registry
  map from the design (base sha unchanged, cli pinned to
  `7948695c318e9bb7a2a9c8ecaf9c8a7959033178`). Rewrite
  `resolve-template-coord` as 1-arity with the three-way branch (nil/base →
  registry + env overrides; `://` → `cache/resolve-head-sha!` wrapped so
  failures throw `ex-info` with the `failed to resolve template` message;
  other → registry lookup or `unknown template` ex-info listing
  `(sort (keys templates))`).

- [x] **Step 4: Run tests to verify they pass**
  Run: `make build && ./bin/lgx test test/lgx/new_test.lg`
  Expected: PASS

- [x] **Step 5: Commit**
  `git commit -m "Add template registry with built-in cli template"`

### Task 4: wire `cmd-new!` and help text

**Files:**
- Modify: `lgx/new.lg`, `lgx.lg`

- [x] **Step 1: Rewire `cmd-new!`**
  In `lgx/new.lg`: require `[lgx.cli :as cli]`; replace the manual
  arg-count checks at the top of `cmd-new!` with
  `(cli/parse-new-args args)` in a try/catch that writes `(ex-message e)`
  plus newline to stderr and exits 1 (parse messages already carry the
  `lgx: ` prefix; do not route them through `die!`, which would double
  it). Resolve the coord via `(resolve-template-coord template)` in its
  own try/catch that calls `die!` with `(ex-message e)` — keep it separate
  from the existing `ensure-template!` catch, whose
  `failed to fetch template:` wrapper would mangle resolution errors.
  Rest of the flow (validate name/target, render, next-steps output)
  unchanged.

- [x] **Step 2: Update help text**
  In `lgx.lg` `command-rows`, replace the `new` row with
  `lgx new <name> [-t <tpl>]` + `Scaffold a let-go app (template: built-in name or git URL)`,
  hand-aligned to column 31 like neighboring rows.

- [x] **Step 3: Verify manually**
  Run: `make build && cd "$(mktemp -d)" && LGX_HOME="$(mktemp -d)" <repo>/bin/lgx new demo -t nope; <repo>/bin/lgx help | grep 'lgx new'`
  Expected: `lgx: unknown template: nope (built-in: base, cli)` with exit 1;
  help row renders aligned.

- [x] **Step 4: Run full unit suite**
  Run: `./bin/lgx test`
  Expected: PASS

- [x] **Step 5: Commit**
  `git commit -m "Wire --template flag into lgx new"`

### Task 5: e2e scenarios

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add scenarios 105–107**
  Inside the template-fixture block (before `rm -rf "$FIXTURE_REPO_DIR"`,
  after Scenario 55), following the structure of scenarios 50–55:
  - **105**: `lgx new tpl-url -t "$FIXTURE_REPO_URL"` with `LGX_HOME` set but
    *no* `LGX_TEMPLATE_BASE_*` vars → exit 0, `src/tpl_url/greeter.lg`
    exists, ns substituted, and the cache dir
    `$home/templates/_local/_/$FIXTURE_REPO_BASENAME/$FIXTURE_REPO_SHA`
    exists (HEAD resolved to the fixture sha).
  - **106**: `lgx new demo -t nope` → exit 1, output contains
    `lgx: unknown template: nope (built-in: base, cli)`.
  - **107**: `lgx new demo -t` → exit 1, output contains
    `--template requires a value`.

- [x] **Step 2: Run e2e**
  Run: `make test`
  Expected: all scenarios pass, including 105–107.

- [x] **Step 3: Commit**
  `git commit -m "Add e2e coverage for lgx new templates"`

### Task 6: docs

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`

- [x] **Step 1: Update README**
  In the `lgx new` section: document `-t/--template` with the three usage
  forms, the built-in names table (`base`, `cli` — short purpose each),
  custom-URL semantics (latest default-branch HEAD, cached by sha,
  `ls-remote` per run), and a short "writing your own template" note: any
  git repo using the literal `projectname` placeholder in paths and file
  contents. Use /writing-clearly.

- [x] **Step 2: Update ARCHITECTURE.md**
  Update the `new` command / template section to describe the registry,
  1-arity `resolve-template-coord`, and `resolve-head-sha!`; check the
  `Verify against:` footers still hold.

- [x] **Step 3: Final full run**
  Run: `make test`
  Expected: PASS

- [x] **Step 4: Commit**
  `git commit -m "Document lgx new templates"`

---

## Completion summary (2026-06-11)

Implemented in six commits (`97df5cd`..`f1ae51a`) exactly as planned:
`cli/parse-new-args`, `cache/resolve-head-sha!`, the `templates` registry
(`base` + `cli`, cli pinned to `7948695`), `cmd-new!` wiring, help row, e2e
scenarios 105–107, and README/ARCHITECTURE docs. Full suite green: 319 unit
tests, 246 e2e assertions.

Issues encountered:
- Codex review of the Task 3 commit flagged (correctly) that `cmd-new!`
  still called 0-arity `resolve-template-coord` at that intermediate
  commit; resolved one commit later by Task 4 as sequenced.
- Codex review of the Task 6 commit flagged the README's "any git repo
  works as a template" as overstated (SSH URLs are unsupported); fixed in
  a follow-up commit clarifying supported URL forms (`https://`,
  `file://`).
