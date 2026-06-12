# Task Arg String Templating Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let task steps embed declared positional args inside strings via `{{arg-name}}` tokens, e.g. `{:sh "git tag v{{version}}"}`.

**Tech Stack:** let-go (`.lg` sources), bash e2e harness.

---

## Design

### Current behavior

A task's `:args` declarations bind CLI values into a map keyed by
`:arg/<name>` keywords (`lgx.args/bind-args`). Placeholders work only
as whole items in vector-form step values
(`{:sh ["./deploy.sh" :arg/env]}`): `lgx.args/substitute` replaces each
keyword item, shell-quoted for `:sh`, verbatim for `:run`. String-form
commands have no placeholder syntax, and there is no way to combine an
arg with surrounding text in one item (`"v1.2"` from `:arg/version`).

### New behavior

Any string in a step's `:sh`/`:run` value — a whole-string command or a
string item inside a vector form — may embed `{{<name>}}` tokens. Before
the step runs, each token whose name matches a declared arg is replaced
with its bound value (the CLI string, or the stringified `:default`).

Semantics:

- **Raw splice.** No quoting is added. The task author writes their own
  quotes when needed: `{:sh "git tag 'v{{version}}'"}`. This is the
  textual counterpart to the keyword form, which stays the safe,
  auto-shell-quoted "exactly one word" option. Both forms may mix in one
  step.
- **Unknown names pass through.** A `{{...}}` token that does not name a
  declared arg is left untouched — it is not a config error. This
  doubles as the escape hatch for literal `{{...}}` text. `config.lg`
  validation does not change.
- **Values are inert.** A bound value that itself contains `{{other}}`
  is never re-expanded.
- **`:run` string form splits after expansion.** `{:run "notify.lg
  {{env}}"}` expands first, then the existing whitespace split builds
  argv — a value containing spaces becomes multiple argv entries. Docs
  tell users to prefer the vector form (`{:run ["notify.lg"
  "{{env}}"]}`) when a value must stay one argument, since a vector item
  remains one argv entry after expansion.

### Components and data flow

Two source files change; the CLI layer, `bind-args`, quoting, joining,
echoing, and validation are all untouched.

**`lgx/args.lg` — new pure fn `expand`.** `(expand s bindings)` →
string. Single-pass scanner over `s` using `string/index-of`:

1. Find the next `"{{"` from the current index. None → append the rest,
   done.
2. Find the next `"}}"` after it. None → append the rest starting at
   the current scan index (so the pending `"{{"` is included), done.
3. The text between is the candidate name. If it is non-empty, contains
   no `/`, and `(keyword "arg" name)` is a key in `bindings`, append the
   bound value and continue after the `"}}"`.
4. Otherwise append just the literal `"{{"` and continue scanning
   immediately after it (so `"{{a{{env}}"` still expands the inner
   token).

The empty/`/` guard avoids constructing odd keywords (let-go parses
`/` inside names as a namespace — see memory/docs) and such tokens can
never match a declared arg anyway, since arg `:name`s are validated as
unqualified keywords. Appending values without re-scanning them is what
makes values inert. `expand` sits next to `substitute` and takes the
same bindings map that `bind-args` produces (all values are strings).

**`lgx/tasks.lg` — `substituted` applies `expand`.** The helper at
`lgx/tasks.lg:35` currently substitutes keywords in vectors and passes
strings through. New behavior:

- string value → `(args/expand value bindings)`
- vector value → expand each string item, then the existing
  `args/substitute` pass for keyword items

Everything downstream is unchanged, so the echoed `$ <cmd>` step line
automatically shows the expanded command, `:sh` joining and keyword
quoting behave as today, and `:run`'s string form splits the expanded
string.

### Error handling

No new error paths. Unknown tokens pass through by design; malformed
tokens (unclosed `{{`, empty or `/`-containing names) degrade to
literal text. The existing `throw` for unbound `:arg/` keyword items in
`substitute` is unaffected.

### Testing strategy

- Unit tests for `expand` in `test/lgx/args_test.lg` (pure fn, table of
  input/expected cases).
- One e2e scenario exercising templating through the bundled binary in
  both a string-form `:sh` and a vector-form item, plus the
  default-fill case.
- Full suite via `make test` (builds `bin/lgx`, runs unit tests, then
  e2e). Note: the repo is shared between a macOS shell and this agent;
  avoid running `make test` concurrently from both (it rebuilds
  `bin/lgx` in place).

## File Structure

| File | Change |
| --- | --- |
| `lgx/args.lg` | Add `expand`; extend the ns header comment to mention `{{name}}` templating. |
| `lgx/tasks.lg` | Apply `expand` in `substituted`; update the ns header comment's placeholder paragraph. |
| `test/lgx/args_test.lg` | Unit tests for `expand`. |
| `tests/e2e.sh` | New scenario appended after the last one (Scenario 112). |
| `README.md` | Rewrite the "no templating inside string commands" rules; extend the `deploy` reference example. |
| `docs/ARCHITECTURE.md` | Update the `args.lg` one-liner (line ~33) and the step-substitution paragraph (lines ~354–361). |

## Task 1: `expand` in lgx.args

**Files:**
- Modify: `lgx/args.lg`
- Test: `test/lgx/args_test.lg`

- [x] **Step 1: Write the failing tests**
  Add an `expand` section to `test/lgx/args_test.lg` following the
  existing `deftest`/`is` style. Cases:
  - basic: `(expand "v{{version}}" {:arg/version "1.2"})` → `"v1.2"`
  - multiple tokens in one string: `"{{env}}-{{version}}"` → `"prod-1.2"`
  - token is the whole string: `"{{env}}"` → `"prod"`
  - unknown name passes through: `"v{{verison}}"` unchanged
  - empty bindings: string with tokens unchanged
  - unclosed `{{`: `"v{{version"` unchanged
  - empty name `"{{}}"` and `/`-name `"{{a/b}}"` unchanged
  - value is inert: `(expand "{{a}}" {:arg/a "{{b}}" :arg/b "x"})` →
    `"{{b}}"`
  - raw splice: value with shell metacharacters (`"1.2; echo hi"`)
    lands unmodified, no quotes added
  - `{{` directly before a real token: `"{{a{{env}}"` with only `:arg/env`
    bound → `"{{aprod"`
  - no tokens at all: plain string returned as-is

- [x] **Step 2: Run tests to verify they fail**
  Run: `bin/lgx test` (if `bin/lgx` is missing, `make build` first)
  Expected: FAIL — `expand` does not exist yet. All pre-existing tests
  still pass.

- [x] **Step 3: Implement `expand`**
  In `lgx/args.lg`, next to `substitute`. Loop with an output string
  accumulator and a scan index, per the scanner spec in the Design
  section (`string/index-of` with a from-index, `subs` for slices).
  Docstring states: raw splice, unknown/malformed tokens pass through,
  values are not re-scanned. Extend the file's ns header comment (lines
  4–13) to mention `{{name}}` templating alongside keyword
  substitution.

- [x] **Step 4: Run tests to verify they pass**
  Run: `bin/lgx test`
  Expected: PASS, including all pre-existing tests.

- [x] **Step 5: Lint, format, commit**
  Run: `make fmt && make lint`
  `git commit -m "Add args/expand for {{name}} templating"`

## Task 2: Wire expansion into task steps + e2e

**Files:**
- Modify: `lgx/tasks.lg`
- Test: `tests/e2e.sh`

- [x] **Step 1: Write the failing e2e scenario**
  Append Scenario 112 to `tests/e2e.sh`, modeled on Scenario 105
  (`tests/e2e.sh:2461`): fresh `mktemp -d` project + `LGX_HOME`, an
  `lgx.edn` like:

  ```edn
  {:tasks
   {deploy {:args [{:name :env}
                   {:name :version :default "latest"}]
            :do [{:sh "echo tag=v{{version}} env={{env}}"}
                 {:sh ["echo" "item=v{{version}}" :arg/env]}
                 {:sh "echo miss={{nope}}"}]}}}
  ```

  Assertions on `lgx deploy prod 1.2`: output contains
  `tag=v1.2 env=prod`, `item=v1.2 prod`, and `miss={{nope}}` (unknown
  token passes through). One more invocation `lgx deploy prod`
  asserting `tag=vlatest` (default fills the template).

- [x] **Step 2: Run the scenario to verify it fails**
  Run: `make test`
  Expected: unit tests pass; e2e fails at Scenario 112 with the
  un-expanded `tag=v{{version}}` output.

- [x] **Step 3: Apply expand in `substituted`**
  In `lgx/tasks.lg`, change `substituted` (line 35): string value →
  `args/expand`; vector value → map `args/expand` over string items
  (leave keywords for `args/substitute`, which runs as today). Update
  the ns header comment paragraph (lines 17–21) to cover both
  placeholder forms.

- [x] **Step 4: Run the full suite to verify it passes**
  Run: `make test`
  Expected: all unit + e2e tests pass, including Scenario 112.

- [x] **Step 5: Lint, format, commit**
  Run: `make fmt && make lint`
  `git commit -m "Expand {{name}} templates in task step strings"`

## Task 3: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update README**
  In the "Positional args (`:args`)" section (~line 391): replace the
  closing paragraph ("Placeholders work only in vector-form step
  values - there is no templating inside string commands...") with the
  two placeholder forms: `:arg/<name>` keyword items (auto-shell-quoted,
  one word, must name a declared arg) and `{{name}}` string templating
  (raw splice anywhere a string appears, author quotes it, unknown
  names pass through untouched, values never re-expanded). Note the
  `:run` string-form split caveat and the vector-form recommendation.
  Add one templated step to the `deploy` reference example (~line 303),
  e.g. `{:sh "echo deploying v{{version}}"}` — keep the example's
  existing enum-typed `:env` arg as-is — and mirror the new step in the
  prose that walks through `lgx deploy prod`.

- [ ] **Step 2: Update ARCHITECTURE.md**
  Line ~33: extend the `args.lg` one-liner with "expand `{{name}}`
  templates in step strings". Lines ~354–361: rewrite the substitution
  paragraph to cover both forms and drop "String-form values have no
  placeholder syntax"; keep the note that keyword placeholders are
  config-validated while `{{name}}` tokens are not.

- [ ] **Step 3: Verify docs match behavior**
  Re-read both edits against `lgx/args.lg` and `lgx/tasks.lg`; check
  the README example matches what Scenario 112 asserts.

- [ ] **Step 4: Commit**
  `git commit -m "Document {{name}} task arg templating"`
