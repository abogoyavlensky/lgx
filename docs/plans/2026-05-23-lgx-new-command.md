# `lgx new <project-name>` Command Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add a `lgx new <project-name>` subcommand that scaffolds a new let-go application from a hardcoded default template fetched from GitHub and cached locally, substituting `projectname` for the user's chosen project name in both file paths and file contents.

**Tech Stack:** let-go (`.lg`), bundled lgx CLI, existing gitlibs-style git cache in `lgx/cache.lg`, existing filesystem-walk pattern in `lgx/test_runner.lg`.

---

## Design

### What this builds

```
lgx new foo-bar
  → ./foo-bar/                          (created)
      lgx.edn                            (contents: bin/foo-bar)
      main.lg                            (contents: (ns foo-bar.main ...))
      src/foo_bar/greeter.lg             (path: underscore; contents: ns hyphen)
      test/foo_bar/greeter_test.lg
      README.md, LICENSE, .mise.toml, .cljfmt.edn, .gitattributes, .gitignore
  → "Created foo-bar at <abs path>"
  → "Next steps: cd foo-bar / lgx run"
```

V1 has exactly one template (the default), no flags, project name as the only configurable input.
Future work — `-t / --template <git-url>`, tag support, `:lgx/version` plumbing, registry — is explicitly out
of scope and tracked in the roadmap.

### Distribution: fetch + cache, not bundle

`lg -b` only bundles `.lg` source (transitively `require`d). The template has 10 files including
`lgx.edn`, `README.md`, `Makefile` (in the actual repo's case, no Makefile), `.gitignore`,
`.mise.toml`, `.cljfmt.edn`, `.gitattributes`, and `LICENSE` — none of which `lg` can carry into a bundle without
being smuggled in as `def`'d string blobs. So we fetch the template via `git` on first use, cache it,
and reuse on subsequent runs.

Cache layout, parallel to gitlibs:

```
~/.lgx/templates/<host>/<owner>/<repo>/<sha>/    ← checked-out worktree, .git/ stripped
```

The cache key is `(url, sha)`. Sha-pin only — `:git/tag` isn't needed until `-t` lands. The clone routine
is the same atomic clone-into-tmp → checkout → drop `.git/` → mv-into-place pattern that
`lgx/cache.lg` already uses for deps.

### Default template

Hardcoded in `lgx/new.lg`:

```clojure
(def default-template
  {:git/url "https://github.com/abogoyavlensky/lgx-template-base"
   :git/sha "eade5971bff8fe828202c7c4f9af031ef976140c"})
```

Two env overrides for testing and power users:

- `LGX_TEMPLATE_BASE_URL` — replaces `:git/url`.
- `LGX_TEMPLATE_BASE_SHA` — replaces `:git/sha`.

Both default to the hardcoded values when unset or blank (using `os/getenv` + `str/blank?`, matching
the `LGX_LG` pattern in `lgx/runner.lg`). E2E tests set both to a `file://` URL pointing at a fixture
repo plus its HEAD sha.

### Placeholder substitution

Single placeholder token: **`projectname`** (no separator). Two substitution rules, applied per file:

| Where | `projectname` →                                  |
|-------|--------------------------------------------------|
| Path segments | user input with every `-` replaced by `_`  |
| File contents | user input verbatim (hyphen form preserved) |

Examples for `lgx new foo-bar`:

- Template path `src/projectname/greeter.lg` → output `src/foo_bar/greeter.lg`
- Template content `(ns projectname.greeter)` → output `(ns foo-bar.greeter)`
- Template content `:bin {:out "bin/projectname"}` → output `:bin {:out "bin/foo-bar"}`

For `lgx new myapp` (no hyphen), both substitutions are no-ops on the user-name side but still
swap `projectname` for `myapp`.

The unified token works for the current template because `project-name` (hyphen form) only
appeared in contents and `project_name` (underscore form) only appeared in paths. The single token
makes that split implicit in the substitution rule, so the template author can't accidentally write
the wrong form in the wrong place.

Caveat for template authors: avoid the literal word `projectname` in any prose where you don't
want it substituted (e.g. README example commands). Use `<name>` or `your-app` instead.
Documented in the new project's onboarding docs (not part of this PR; the template repo's
README is its own concern).

### Project name validation

Regex: `^[a-z][a-z0-9-]*$`. Lowercase letter start, then lowercase letters / digits / hyphens.
Matches the let-go ns convention and forbids inputs that would produce broken ns names
(uppercase, leading digit, embedded slash) or strange paths (leading dot, underscore at start).

Errors (stderr, exit 1, before any filesystem touch):

| Condition | Message |
|-----------|---------|
| no arg | `lgx: new requires a project name` |
| > 1 arg | `lgx: new takes exactly one argument` |
| name fails regex | `lgx: invalid project name: <input>` + a second stderr line `name must start with a letter and contain only lowercase letters, digits, and hyphens` |

### Target directory rules

`./<project-name>` resolved against `os/cwd`. Behavior:

| Target state | Action |
|--------------|--------|
| Does not exist | create it during render (parent mkdir is recursive) |
| Exists and is an empty dir | proceed, lay files into it |
| Exists and is a non-empty dir | exit 1: `lgx: target directory already exists and is not empty: <path>` |
| Exists and is a file | exit 1: `lgx: target exists and is not a directory: <path>` |

Empty-vs-non-empty is determined by `(empty? (os/ls path))`. No `--force` flag in V1.

### Render flow

```
1. Validate name. Throw → cmd-new! catches → stderr + exit 1.
2. Validate target. Same pattern.
3. Resolve template coord (apply env overrides).
4. Ensure template cached (clone if missing).
5. Walk cached template dir → vector of absolute source file paths.
6. For each source path:
     a. rel = path-relative-to-cache-root
     b. dst-rel = substitute-path-segments(rel, name-pair)
     c. dst-abs = path/join(target, dst-rel)
     d. mkdir parent of dst-abs (recursive, idempotent)
     e. spit(dst-abs, substitute-contents(slurp(src-abs), name-pair))
7. Print summary + next steps.
```

`name-pair` is computed once: `{:hyphen "foo-bar" :underscore "foo_bar"}`.

Per-segment substitution (not whole-path) so the substitution lands in each path component
individually — `src/projectname/projectname_helpers.lg` → `src/foo_bar/foo_bar_helpers.lg`. In
practice the template has at most one `projectname` segment per path, but per-segment is the
right primitive.

### Error handling

All validation is upfront. Once render starts, we fail-fast on the first IO error and exit 1 with
`lgx: failed to write <path>: <reason>` (let-go IO throws expose `(.getMessage e)` equivalents
via `ex-message`/`(:message (ex-data e))` depending on the call). No rollback — partial output
stays on disk; the user can `rm -rf` and retry.

Git clone failures replay the underlying `git` stderr after a `lgx: failed to fetch template:` prefix,
matching the style in `lgx/cache.lg`'s `git!` helper.

### Module boundaries

`lgx/new.lg` owns the command end-to-end. `lgx.lg` only adds dispatch + help. `lgx/config.lg`
adds `"new"` to `reserved-task-names`. `lgx/cache.lg` exposes two existing helpers (`clone-sha!`,
`finalize-worktree!`) by changing `defn-` to `defn`. No new shared utility namespace is needed —
the only cross-cutting concern is the git clone routine, which already lives in `cache.lg`.

The walk pattern in `lgx/test_runner.lg:13-24` is duplicated in `lgx/new.lg` (rather than extracted)
because the predicates differ enough (test files vs. all files) that the helper would still need a
predicate argument, and the body is six lines. Extract when a third caller appears.

### Testing strategy

**Unit tests** in `test/lgx/new_test.lg` — pure helpers, no network:

- `valid-name?` / `validate-name!`: happy + each invalid branch (empty, starts-with-digit,
  uppercase, contains `_`, contains `/`, contains `.`).
- `name-pair` from `"foo-bar"` → `{:hyphen "foo-bar" :underscore "foo_bar"}`; from `"myapp"`
  → `{:hyphen "myapp" :underscore "myapp"}`.
- `substitute-path-segments` on a multi-segment relative path with mixed segments.
- `substitute-contents` on a string containing `projectname` multiple times.
- `validate-target!`: non-existent (returns), empty dir (returns), non-empty dir (throws
  `:non-empty`), regular file (throws `:not-a-dir`).
- `render!` against a hand-built tiny source tree on tmpfs (two source files, one with
  `projectname` in path, one without). Assert exact output paths and contents.
- `resolve-template-coord`: env overrides applied when set; defaults used when unset/blank.

**E2E tests** in `tests/e2e.sh` — six scenarios after the current final scenario:

- **Happy path A — name with hyphen.** Set `LGX_TEMPLATE_BASE_URL=file://$FIXTURE_REPO` and
  `LGX_TEMPLATE_BASE_SHA=$FIXTURE_SHA`. Run `lgx new my-app`. Assert exit 0, then assert
  the rendered tree: `my-app/src/my_app/greeter.lg` exists, `my-app/main.lg` contains
  `(ns my-app.main`, `my-app/lgx.edn` contains `bin/my-app`. Then `cd my-app && lgx run`
  works and prints the expected greeting.
- **Happy path B — name without hyphen.** Same setup, `lgx new myapp`. Asserts that
  `myapp/src/myapp/greeter.lg` exists (no underscore conversion when the input has no
  hyphens). Proves the no-conversion path.
- **Invalid name.** `lgx new Foo` (uppercase). Exit 1, stderr matches
  `lgx: invalid project name: Foo` and second line matches the rule description.
- **Target exists non-empty.** Pre-create `./foo/file`. Run `lgx new foo`. Exit 1, stderr matches
  `lgx: target directory already exists and is not empty:`.
- **Cache reuse.** Run `lgx new alpha` twice in a row (different LGX_HOMEs are OK; this scenario
  uses one LGX_HOME). After the first run, capture the mtime of the cached template dir; after
  the second, assert the mtime is unchanged. Proves the cache short-circuits the clone.
- **Cold cache.** Delete `~/.lgx/templates/`. Run `lgx new beta`. Assert success and that the
  cache dir reappears.

The fixture repo is a tiny git repo created at the start of `tests/e2e.sh` (in a `mktemp -d`
location), seeded with three files mirroring the template structure:

```
projectname/lgx.edn        (with :main "main.lg" :targets {:bin {:out "bin/projectname"}})
projectname/main.lg        ((ns projectname.main) printing a known string)
projectname/src/projectname/greeter.lg  ((ns projectname.greeter) (defn greet [] "hello"))
```

A small bash helper at the top of the e2e file sets up the fixture once and exports
`FIXTURE_REPO_URL` (a `file://` URL) and `FIXTURE_REPO_SHA` (`git rev-parse HEAD`).

E2E does not depend on the real github.com template repo — it works offline.

### What's out of scope (YAGNI)

- `-t` / `--template <git-url>` flag and any per-template config.
- `:git/tag` template pinning.
- `--force` flag for clobbering targets.
- Git init / initial commit in the new project (user picked "leave non-VCS").
- Multiple template registry, version-matched templates, `lgx new --list-templates`.
- Interactive prompts.
- Updating the new project's `.mise.toml` to match the currently running lgx version. Template
  author manages.
- Telemetry on which templates are popular.
- Cleaning up cached templates older than N days.

## File Structure

### Create

- `lgx/new.lg` — command implementation. Public `cmd-new!` + private helpers.
- `test/lgx/new_test.lg` — unit tests for the helpers.

### Modify

- `lgx.lg`
  - Add `[lgx.new :as new]` to the `:require`.
  - Add a `"new" (new/cmd-new! (vec rest-args) verbose?)` arm to `dispatch`.
  - Add a `lgx new <project-name>` line to `base-usage`.
- `lgx/config.lg`
  - Add `"new"` to `reserved-task-names`.
- `lgx/cache.lg`
  - Promote `clone-sha!` and `finalize-worktree!` from `defn-` to `defn`. No semantic change.
- `tests/e2e.sh`
  - Fixture-repo bootstrap at the top of the file (idempotent — only set up once per run).
  - Six new scenarios after the current last one.
- `README.md`
  - Add `lgx new <project-name>` to the Commands section. One sentence on name validation, one
    on the cache location. Mention `LGX_TEMPLATE_BASE_URL` / `LGX_TEMPLATE_BASE_SHA` in the
    env-vars list.
- `docs/ARCHITECTURE.md`
  - Add a `### lgx new` data-flow subsection after `### lgx <task>`.
  - Add `~/.lgx/templates/<host>/<owner>/<repo>/<sha>/` to the State layout block.
  - Mention `LGX_TEMPLATE_BASE_URL`/`LGX_TEMPLATE_BASE_SHA` in the external dependencies /
    config section.

## Pre-flight

Before starting Task 1, confirm the template repo is in the expected state:

- URL: `https://github.com/abogoyavlensky/lgx-template-base`
- Pinned sha: `eade5971bff8fe828202c7c4f9af031ef976140c`
- The sha's tree contains `lgx.edn`, `main.lg`, `src/projectname/greeter.lg`,
  `test/projectname/greeter_test.lg`, `README.md`, `LICENSE`, `.cljfmt.edn`, `.mise.toml`,
  `.gitignore`, `.gitattributes`.
- `projectname` appears in every place the substitution should fire; no stray `project-name` /
  `project_name` left over.

Verify with `gh api repos/abogoyavlensky/lgx-template-base/git/trees/<sha>?recursive=1` if in doubt.

## Implementation Steps

### Task 1: Expose clone helpers from `cache.lg`

**Files:**
- Modify: `lgx/cache.lg`

- [x] **Step 1: Promote `clone-sha!` and `finalize-worktree!` to public**
  Change `defn-` to `defn` for `clone-sha!` and `finalize-worktree!` in `lgx/cache.lg`. Leave
  `clone-tag!` and `git!` private — neither is needed yet.

- [x] **Step 2: Run existing tests to verify nothing broke**
  Run: `make test`
  Expected: PASS — public-vs-private change has no semantic effect on `cache.lg` callers.

- [x] **Step 3: Commit**
  `git commit -m "refactor: expose cache/clone-sha! and finalize-worktree!"`

### Task 2: `valid-name?` and `validate-name!` helpers

**Files:**
- Create: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing tests**
  In `test/lgx/new_test.lg`, add tests asserting:
  - `(new/valid-name? "foo")` → true
  - `(new/valid-name? "foo-bar")` → true
  - `(new/valid-name? "f")` → true
  - `(new/valid-name? "f1")` → true
  - `(new/valid-name? "Foo")` → false
  - `(new/valid-name? "1foo")` → false
  - `(new/valid-name? "foo_bar")` → false
  - `(new/valid-name? "foo/bar")` → false
  - `(new/valid-name? "foo.bar")` → false
  - `(new/valid-name? "")` → false
  - `(new/valid-name? "-foo")` → false
  - `(new/valid-name? nil)` → false
  - `(new/validate-name! "foo-bar")` returns `"foo-bar"`
  - `(new/validate-name! "Foo")` throws ex-info with
    `(:reason (ex-data e))` = `:invalid-name` and `(:name (ex-data e))` = `"Foo"`

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL — `lgx/new.lg` does not exist yet.

- [x] **Step 3: Implement the helpers**
  Create `lgx/new.lg`. ns: `lgx.new`. Add:
  - `valid-name?` — uses `re-matches` against `#"^[a-z][a-z0-9-]*$"`. Guards against non-string
    input by checking `string?` first.
  - `validate-name!` — returns the input on success; throws ex-info on failure with
    `{:reason :invalid-name :name <input>}`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: name validation for lgx new"`

### Task 3: `name-pair` and substitution helpers

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing tests**
  Add to `test/lgx/new_test.lg`:
  - `(new/name-pair "foo-bar")` → `{:hyphen "foo-bar" :underscore "foo_bar"}`
  - `(new/name-pair "myapp")` → `{:hyphen "myapp" :underscore "myapp"}`
  - `(new/name-pair "a-b-c")` → `{:hyphen "a-b-c" :underscore "a_b_c"}`
  - `(new/substitute-contents "(ns projectname.main)" {:hyphen "foo-bar" :underscore "foo_bar"})`
    → `"(ns foo-bar.main)"`
  - `(new/substitute-contents "before projectname after" {:hyphen "x" :underscore "x"})`
    → `"before x after"`
  - `(new/substitute-contents "no token here" {:hyphen "x" :underscore "x"})`
    → `"no token here"`
  - `(new/substitute-contents "projectname projectname" {:hyphen "abc" :underscore "abc"})`
    → `"abc abc"`
  - `(new/substitute-path-segments "src/projectname/greeter.lg" {:hyphen "foo-bar" :underscore "foo_bar"})`
    → `"src/foo_bar/greeter.lg"`
  - `(new/substitute-path-segments "projectname/projectname.lg" {:hyphen "x" :underscore "y"})`
    → `"y/y.lg"`
  - `(new/substitute-path-segments "src/nothing/here.lg" {:hyphen "a" :underscore "b"})`
    → `"src/nothing/here.lg"`

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL — helpers not defined.

- [x] **Step 3: Implement the helpers**
  In `lgx/new.lg`:
  - `name-pair` — returns `{:hyphen name :underscore (str/replace name "-" "_")}`.
  - `substitute-contents` — `(str/replace s "projectname" (:hyphen pair))`.
  - `substitute-path-segments` — splits on `"/"`, applies
    `(str/replace seg "projectname" (:underscore pair))` to each, rejoins with `"/"`. The split
    rule is `/` (forward slash) because that's what stored relative paths use; `os/file-separator`
    is only needed when assembling absolute filesystem paths. Stored template-relative paths
    use `/` per the convention in `lgx/path.lg`'s docstring.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: placeholder substitution helpers for lgx new"`

### Task 4: `validate-target!` helper

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing tests**
  Add tests using tmpfs scratch dirs (mirror the pattern in `test/lgx/test_runner_test.lg`):
  - Non-existent path → returns the path.
  - Empty dir → returns the path.
  - Non-empty dir (file inside) → throws ex-info with `:reason :non-empty :path <p>`.
  - Path exists as a regular file → throws ex-info with `:reason :not-a-dir :path <p>`.

  Use `(str "/tmp/lgx-new-validate-" (rand-int 1000000))` for scratch dirs; clean up after each
  test via try/finally (matching test_runner_test patterns).

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL.

- [x] **Step 3: Implement**
  In `lgx/new.lg`, add `validate-target!`:
  - `os/stat` the path. If nil → return path (will be created).
  - If `:dir?` is false → throw `{:reason :not-a-dir :path p}`.
  - If `:dir?` is true → check `(empty? (os/ls p))`. Non-empty → throw `{:reason :non-empty :path p}`.
    Empty → return path.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: target-dir validation for lgx new"`

### Task 5: Template coord resolution

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing tests**
  Add tests asserting `resolve-template-coord`:
  - With no env vars set → returns `default-template`.
  - With `LGX_TEMPLATE_BASE_URL=https://example.com/a/b` → returns coord with that URL and
    the default sha.
  - With `LGX_TEMPLATE_BASE_SHA=abc123` → returns coord with the default URL and `abc123`.
  - With both set → both overridden.
  - Blank string envs treated as unset (matches `lgx/runner.lg` LGX_LG handling).

  Use `os/setenv` to set the vars in tests; reset to a known sentinel value or empty string
  between tests. Watch ordering: tests must not leak state.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL.

- [x] **Step 3: Implement**
  In `lgx/new.lg`:
  - `def default-template` with the URL `https://github.com/abogoyavlensky/lgx-template-base`
    and sha `eade5971bff8fe828202c7c4f9af031ef976140c`.
  - `resolve-template-coord` reads `LGX_TEMPLATE_BASE_URL` / `LGX_TEMPLATE_BASE_SHA`, treats
    blank as unset, applies overrides on top of the default coord.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: template coord resolution with env overrides"`

### Task 6: `ensure-template!` — cache + clone

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg` (unit test against a local fixture repo)

- [x] **Step 1: Write the failing test**
  Add a test that:
  - Creates a tiny throwaway git repo in `/tmp/lgx-template-fixture-<rand>` with one file and one
    commit. Captures its sha with `os/sh` calling `git rev-parse HEAD`.
  - Points an isolated `LGX_HOME` at `/tmp/lgx-new-home-<rand>` via `os/setenv`.
  - Calls `(new/ensure-template! {:git/url (str "file://" repo) :git/sha sha})`.
  - Asserts the return value is the absolute path
    `~/.lgx/templates/_local/_/<basename>/<sha>` (matches `cache.lg`'s `parse-git-url` rule
    for `file://`).
  - Asserts the cache dir exists, contains the fixture file, and does NOT contain `.git/`.
  - Calls `ensure-template!` again, captures mtime, asserts the second call is a no-op (mtime
    unchanged — proves cache short-circuit).

- [x] **Step 2: Run test to verify it fails**
  Run: `make test`
  Expected: FAIL — `ensure-template!` not defined.

- [x] **Step 3: Implement**
  In `lgx/new.lg`:
  - `templates-root` — `(path/join (home/root) "templates")`.
  - `template-dir` — `(let [[host owner repo] (cache/parse-git-url url)] (path/join (templates-root) host owner repo sha))`.
  - `ensure-template!` — if `(file-exists? dir)`, return dir; otherwise call
    `(cache/clone-sha! url sha dir)` and return dir. Reuse the public `clone-sha!` from Task 1.

  Require `[lgx.cache :as cache]`, `[lgx.home :as home]`, `[lgx.path :as path]` in the ns form.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: ensure-template! cache + clone for lgx new"`

### Task 7: `walk-template` and `render!`

**Files:**
- Modify: `lgx/new.lg`
- Test: `test/lgx/new_test.lg`

- [x] **Step 1: Write the failing tests**
  Add tests for `render!` against a hand-built source tree on tmpfs:
  - Setup: build `/tmp/lgx-new-src-<rand>/` with:
    - `lgx.edn` containing `bin/projectname`
    - `main.lg` containing `(ns projectname.main)`
    - `src/projectname/greeter.lg` containing `(ns projectname.greeter)`
  - Pick target `/tmp/lgx-new-tgt-<rand>/` (non-existent).
  - Call `(new/render! src target (new/name-pair "foo-bar"))`.
  - Assert: target exists; `target/lgx.edn` contains `bin/foo-bar`; `target/main.lg` contains
    `(ns foo-bar.main)`; `target/src/foo_bar/greeter.lg` exists and contains `(ns foo-bar.greeter)`;
    `target/src/projectname/greeter.lg` does NOT exist.

  Also add a test that `walk-template` against the same fixture returns the three absolute source
  paths in sorted order.

- [x] **Step 2: Run tests to verify they fail**
  Run: `make test`
  Expected: FAIL.

- [x] **Step 3: Implement**
  In `lgx/new.lg`:
  - `walk-template` — recursive file walker. Returns a sorted vector of absolute source paths.
    Pattern matches `walk*` in `lgx/test_runner.lg:13-24` but with no extension filter.
  - `render!` — for each source path, compute the relative-to-source path, run it through
    `substitute-path-segments`, join with target, mkdir parent recursive, slurp source, run
    contents through `substitute-contents`, spit to destination.

  Use `/` (not `os/file-separator`) when storing relative paths internally; convert via `path/join`
  only when producing an absolute path. This mirrors how `lgx/config.lg` validates `:paths`
  entries with `/`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git commit -m "feat: walk-template and render! for lgx new"`

### Task 8: `cmd-new!` and dispatcher wiring

**Files:**
- Modify: `lgx/new.lg`
- Modify: `lgx.lg`
- Modify: `lgx/config.lg`

- [x] **Step 1: Implement `cmd-new!` in `lgx/new.lg`**
  Public function. Steps:
  1. Validate arg count (0 → error, > 1 → error).
  2. `validate-name!` the single arg. On throw, write the two-line error message to stderr and `os/exit 1`.
  3. Compute `target = (path/join (os/cwd) name)`.
  4. `validate-target!` the target. On throw, dispatch by `:reason` to the matching stderr message and exit 1.
  5. `coord = (resolve-template-coord)`.
  6. Try `(ensure-template! coord)`. On throw, print `lgx: failed to fetch template: <stderr>` to
     stderr and exit 1.
  7. Try `(render! cache-path target (name-pair name))`. On throw, print
     `lgx: failed to write <path>: <message>` and exit 1.
  8. Print the success summary:
     ```
     Created <name> at <target>

     Next steps:
       cd <name>
       lgx run
     ```

- [x] **Step 2: Add `"new"` to `reserved-task-names` in `lgx/config.lg`**
  In the `reserved-task-names` set, add the string `"new"` between `"add"` and `"update"` (keep
  alphabetical-ish order matching existing style).

- [x] **Step 3: Wire dispatch in `lgx.lg`**
  - Add `[lgx.new :as new]` to the `:require`.
  - Add a `"new" (cmd-new! (vec rest-args) verbose?)` arm to `dispatch`, immediately after `"build"`.
    Mirror the pattern of `cmd-test`. (`verbose?` is accepted but currently unused; reserved
    for future logging like the cache-clone trace.)
  - Add a help line to `base-usage`:
    ```
    "  lgx new <project-name>       Scaffold a new let-go app from the default template\n"
    ```
    Place it after the `lgx test` line. Indent to match.

- [x] **Step 4: Build and smoke-test manually**
  Run: `make build`
  Then in a scratch dir:
  ```
  LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx new my-app
  cd my-app && cat lgx.edn && cat main.lg && ls src/my_app
  LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx run
  ```
  Expected: project scaffolded with correct hyphen/underscore substitution; `lgx run` prints
  the greeter output.

  Also check error paths:
  ```
  lgx new Foo                         # invalid name
  lgx new my-app                      # second call into non-empty dir
  ```
  Both exit 1 with the documented stderr lines.

- [x] **Step 5: Run the unit suite**
  Run: `make test`
  Expected: PASS, including all `new_test.lg` cases.

- [x] **Step 6: Commit**
  `git commit -m "feat: lgx new command"`

### Task 9: E2E scenarios

**Files:**
- Modify: `tests/e2e.sh`

- [x] **Step 1: Add fixture bootstrap helper at the top of e2e.sh**
  After existing setup, add a helper that builds a tiny git fixture repo once per e2e run:
  ```bash
  setup_template_fixture() {
    FIXTURE_REPO_DIR=$(mktemp -d)
    cd "$FIXTURE_REPO_DIR"
    git init -q -b master
    mkdir -p src/projectname
    cat > lgx.edn <<'EOF'
  {:paths ["src"]
   :main "main.lg"
   :targets {:bin {:out "bin/projectname"}}
   :deps {}}
  EOF
    cat > main.lg <<'EOF'
  (ns projectname.main
    (:require [projectname.greeter :as greeter]))
  (defn- main [] (prn (greeter/greet "let-go")))
  (when-not *compiling-aot* (main))
  EOF
    cat > src/projectname/greeter.lg <<'EOF'
  (ns projectname.greeter)
  (defn greet [name] (str "Welcome to " name "!"))
  EOF
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m fixture
    FIXTURE_REPO_URL="file://$FIXTURE_REPO_DIR"
    FIXTURE_REPO_SHA=$(git rev-parse HEAD)
    export FIXTURE_REPO_URL FIXTURE_REPO_SHA
  }
  setup_template_fixture
  ```

- [x] **Step 2: Add the six scenarios after the current final scenario**
  - **Scenario X: lgx new happy path with hyphenated name.**
    `LGX_HOME=$(mktemp -d)`. `LGX_TEMPLATE_BASE_URL=$FIXTURE_REPO_URL`,
    `LGX_TEMPLATE_BASE_SHA=$FIXTURE_REPO_SHA`. Run `lgx new my-app` in another tmp dir.
    Assert exit 0; `my-app/src/my_app/greeter.lg` exists; `my-app/main.lg` contains
    `(ns my-app.main`; `my-app/lgx.edn` contains `bin/my-app`; `cd my-app && lgx run` prints
    `Welcome to let-go!` (gated on `supports_source_paths`).

  - **Scenario X+1: lgx new happy path with non-hyphenated name.**
    Same setup. Run `lgx new myapp`. Assert `myapp/src/myapp/greeter.lg` exists (no underscore
    conversion fires because input has no hyphens); `myapp/main.lg` contains `(ns myapp.main`;
    run still works.

  - **Scenario X+2: invalid name.** Run `lgx new Foo`. Exit 1, stderr contains
    `lgx: invalid project name: Foo` and the second-line rule description.

  - **Scenario X+3: target exists non-empty.** Pre-create `foo/file`. Run `lgx new foo`. Exit 1,
    stderr contains `lgx: target directory already exists and is not empty:`.

  - **Scenario X+4: cache reuse.** Single LGX_HOME. Run `lgx new alpha`, capture mtime of
    `~/.lgx/templates/_local/_/<basename>/<sha>`. Run `lgx new beta` (different target, same
    template). Assert the cache dir mtime is unchanged (proves no re-clone).

  - **Scenario X+5: cold cache.** Run `lgx new gamma` with LGX_HOME pointing to a
    nonexistent dir. Assert exit 0 and that `~/.lgx/templates/_local/_/<basename>/<sha>` now
    exists (proves the cold-clone path runs).

  Follow the existing `mktemp`, `assert_contains`, `assert_eq`, cleanup conventions.

- [x] **Step 3: Run e2e**
  Run: `make build && bash tests/e2e.sh`
  Expected: all scenarios pass, including all six new ones.

- [x] **Step 4: Commit**
  `git commit -m "test: e2e scenarios for lgx new"`

### Task 10: Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: README**
  - In the Commands section, add a `lgx new <project-name>` entry. Body: one sentence on what
    it does (scaffolds from the default template, fetched once and cached locally). One sentence
    on name rules (`^[a-z][a-z0-9-]*$`, hyphens become underscores in path segments).
  - Add `LGX_TEMPLATE_BASE_URL` and `LGX_TEMPLATE_BASE_SHA` to the env-vars list near the
    existing `LGX_LG` / `LGX_HOME` entries, with one line each.

- [x] **Step 2: ARCHITECTURE**
  - Add a `### lgx new` subsection after `### lgx <task>`. Cover: argv shape (one positional),
    validation order (name → target → coord → ensure-template → render), the per-file
    substitution rule (paths use `_` form; contents use `-` form), error-message table.
  - Extend the State Layout block to include
    `~/.lgx/templates/<host>/<owner>/<repo>/<sha>/` with a short note that it parallels gitlibs.
  - In the External Dependencies section, add a bullet for the template repo URL and a note that
    `LGX_TEMPLATE_BASE_URL` / `LGX_TEMPLATE_BASE_SHA` can override it.
  - In `reserved-task-names` paragraph, add `"new"` to the listed names.

- [x] **Step 3: Final green run**
  Run: `make test && make build && bash tests/e2e.sh`
  Expected: full green.

- [x] **Step 4: Commit**
  `git commit -m "docs: lgx new command"`

### Task 11: Version bump

**Files:**
- Modify: `lgx.lg`

- [x] **Step 1: Bump version**
  Increment the `version` def in `lgx.lg` to the next alpha (likely `0.1.0-alpha6` based on the
  current `0.1.0-alpha5`). Match the style of prior `Bump version` commits in the history.

- [x] **Step 2: Commit**
  `git commit -m "Bump version"`

## Verification

After all tasks land:

- `lgx new my-app` in a scratch dir produces a project where:
  - `src/my_app/greeter.lg` exists (path underscore conversion).
  - `main.lg` contains `(ns my-app.main ...)` (contents hyphen form preserved).
  - `lgx.edn` contains `bin/my-app` (contents hyphen form preserved).
  - `cd my-app && lgx run` prints the greeter line.
  - `cd my-app && lgx test` runs the bundled greeter test.
  - `cd my-app && lgx build` produces `bin/my-app`.
- `lgx new myapp` (no hyphen) produces a project where `src/myapp/greeter.lg` exists and
  `(ns myapp.main)` lands in `main.lg`.
- `lgx new Foo` exits 1 with the invalid-name error.
- `lgx new my-app` re-run into the same dir exits 1 with the non-empty error.
- `lgx new` (no arg) exits 1 with the "requires a project name" error.
- `lgx new a b` exits 1 with the "takes exactly one argument" error.
- Cache survives across invocations (`~/.lgx/templates/...` is created on first call, reused on
  subsequent calls).
- `LGX_TEMPLATE_BASE_URL` / `LGX_TEMPLATE_BASE_SHA` set to a fixture repo override the
  defaults; unset/blank fall back to the hardcoded values.
- `make test && bash tests/e2e.sh` green.

## Post-Completion

- The roadmap (look for `docs/ROADMAP.md` or wherever items live; recent commits reference
  "Update tasks item in the roadmap") should note that `-t / --template <git-url>` remains the
  next step.
- No consumer-side migration. The first release containing `lgx new` is purely additive.

## Implementation Summary (status: completed)

All 11 tasks landed across 11 commits on `new-cmd`:

- `e52d424 refactor: expose cache/clone-sha! and finalize-worktree!`
- `945c0ce feat: name validation for lgx new`
- `b463a20 feat: placeholder substitution helpers for lgx new`
- `0bc428a feat: target-dir validation for lgx new`
- `67028bd feat: template coord resolution with env overrides`
- `d866f0e feat: ensure-template! cache + clone for lgx new`
- `5032bdb feat: walk-template and render! for lgx new`
- `b1678ff feat: lgx new command`
- `13c73c5 test: e2e scenarios for lgx new`
- `24d6b73 docs: lgx new command`
- `4c5538e Bump version`

Final test totals: 38 unit tests / 54 assertions in `new_test.lg`; 124 e2e
assertions (up from 113). `make test` green end-to-end. Manual smoke test
(`lgx new my-app` against the live `lgx-template-base@eade5971` sha)
produces a runnable project with correct hyphen/underscore substitution.

### Notes / deviations

- **File ordering in `lgx/new.lg`** — let-go compiles top-level forms
  sequentially, so `render!` referencing `substitute-path-segments`
  defined later failed to compile. Reorganized the file mid-Task-7 into
  dependency order: constants → validation → substitution → template
  cache → render → command entry. No semantic change.
- **`os/getenv` blank-vs-unset** — followed the `LGX_LG` precedent in
  `lgx/runner.lg`: `(str/blank? v)` falls back to default. Trailing
  whitespace and the empty string both fall back to the hardcoded
  template coord.
- **E2E cache-reuse assertion (Scenario 54)** — used a sentinel file
  written into the cache leaf after the first call. A re-clone would
  wipe the leaf via `cache/clone-sha!`'s mv-into-place, so the sentinel
  surviving the second call is a stronger and more portable proof of
  cache short-circuit than mtime checks.
- **Codex review** — passed cleanly ("I did not find any blocking
  correctness issues in the diff") after the core wiring (Tasks 1–8) was
  done. No follow-up commits required.
