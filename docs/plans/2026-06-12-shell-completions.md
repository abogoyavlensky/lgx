# Shell Completions Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TAB-complete lgx's first-level built-in commands and the current project's custom task names in bash, zsh, and fish, via `lgx completion <shell>` and a hidden `lgx __complete` endpoint.

**Tech Stack:** let-go (lg), shell scripts embedded as string constants.

---

## Design

Two entry points, following the pattern proven in wtr
(`../wtr/src/wtr/completion.lg` and its three scripts under
`../wtr/resources/completions/` — port those scripts, including wtr's
post-review fish two-rule pattern and the zsh sourced/fpath dual mode):

1. **`lgx completion <shell>`** — prints the bash/zsh/fish completion
   script to stdout. **Hidden:** no row in `command-rows` in `lgx.lg`,
   and not offered as a TAB candidate either; it is documented only in
   the README. Unknown or missing shell → one-line error to stderr,
   exit 1.

2. **`lgx __complete <words…>`** — hidden endpoint the shell scripts
   call on TAB. The last argument is the word under the cursor
   (possibly empty). Prints one prefix-filtered candidate per line.
   Always exits 0 and swallows every error (no project, invalid
   `lgx.edn`), so completion can never break the user's shell. Empty
   output makes the shell fall back to file completion — which is
   exactly right for `lgx run <script>` / `lgx test <file>`.

Both are new branches in the `dispatch` case in `lgx.lg`, so they take
precedence over project tasks; `"completion"` and `"__complete"` also
join `reserved-task-names` in `lgx/config.lg` so a task cannot shadow
them.

### Candidate logic (deliberately minimal)

Pure function in a new `lgx/completion.lg` namespace:

`(candidates words cur task-names)` — `words` are the typed tokens
before the cursor (binary name and `__complete` excluded), `cur` the
word being completed, `task-names` a vector of task-name strings.
Candidates are offered **only at the command position**; there is no
flag completion, no shell-name completion after `lgx completion`, and
no per-command argument completion:

- Walk `words` with lgx's grammar
  (`lgx [--verbose|--with a,b]* <command> [args…]`): skip any
  `-`-prefixed token (as wtr does — so a stray `--foo` or `-v` can't
  be mistaken for a command); `--with` additionally consumes the
  following word. If `--with` is the final word, the cursor sits on
  its value → return `[]`.
- A non-flag token before the cursor means the command is already
  typed → return `[]`.
- `cur` starting with `-` → return `[]`.
- Otherwise → built-in command names + `task-names`, prefix-filtered
  by `cur`, sorted.

Built-in names offered: `build help install new nrepl run test
version`. `completion` and `__complete` are deliberately excluded
(hidden). The list is a def in `lgx/completion.lg` with a comment
pointing at `dispatch` in `lgx.lg` as the source of truth.

Task names come through as strings via `str` over the `:tasks` map's
symbol keys, preserving namespaced names like `foo/bar`.

### I/O entry points

`complete!` (in `lgx/completion.lg`) is the `__complete` handler: takes
the raw argv after `__complete`, splits it into `words` (butlast) and
`cur` (last, or `""` when argv is empty), reads task names with the
**non-throwing** config path — `config/find-project` (nil outside a
project) and `config/load-config` (returns `{:cfg …}` or
`{:errors …}`) — and prints each candidate on its own line. The whole
body is wrapped in try/catch: on any error it prints nothing. It never
calls `os/exit`; the dispatch branch does `(os/exit 0)` after it
returns, keeping the function testable.

`cmd-completion!` is the `completion` handler: exactly one argument in
`#{"bash" "zsh" "fish"}` → print the matching script constant to
stdout; anything else → `lgx: unsupported shell: <arg> (expected one
of: bash, zsh, fish)` to stderr (for a missing argument:
`lgx: completion requires a shell argument (bash, zsh, or fish)`),
exit 1.

Note on argv: `cli/parse-leading-flags` runs before dispatch, but
`__complete` is always the first user token, so the words being
completed are never consumed as leading flags (e.g.
`lgx __complete --with ""` reaches dispatch intact).

### Shell scripts

String constants in `lgx/completion.lg` — **not** `io/resource`:
lgx runs as plain `lg lgx.lg` in dev and is bundled with plain
`lg -b` in the Makefile, so resources would require changing both
invocations and would behave differently between dev and bundle. Each
script is ~15 lines, ported from wtr with `wtr` → `lgx`:

- **bash** — `_lgx_complete()` calls
  `"${COMP_WORDS[0]}" __complete "${COMP_WORDS[@]:1:COMP_CWORD}"`,
  fills `COMPREPLY` via `compgen -W`; registered with
  `complete -o default -F _lgx_complete lgx` (`-o default` = filename
  fallback when output is empty).
- **zsh** — `#compdef lgx` header; calls
  `"${words[1]}" __complete "${(@)words[2,CURRENT]}"`, offers via
  `compadd -Q`, falls back to `_default` when empty; works both
  sourced and as `_lgx` on `$fpath` (the `funcstack` check at the
  bottom).
- **fish** — two-rule pattern: a `__lgx_complete` function calling
  `$words[1] __complete $words[2..-1] "$cur"` (quoted `"$cur"` so the
  empty boundary word survives), one `complete -c lgx -f -n` rule for
  dynamic candidates and one `complete -c lgx -n … -F` fallback rule
  for file completion.

Scripts invoke the binary by the name it was called as, so install
location does not matter.

### Error handling summary

- `__complete`: never errors, always exits 0, prints nothing on any
  failure. Outside a project or with a broken `lgx.edn`, built-ins
  still complete; task names just drop out.
- `completion` with unknown/missing shell: error to stderr, exit 1.
- `lgx help` output is unchanged (the command is hidden).

## File Structure

- Create: `lgx/completion.lg` — built-in name list, pure `candidates`,
  the three script constants, `complete!`, `cmd-completion!`.
- Create: `test/lgx/completion_test.lg` — unit tests.
- Modify: `lgx.lg` — two dispatch branches (`"__complete"`,
  `"completion"`); require `lgx.completion`.
- Modify: `lgx/config.lg` — add `"completion"` and `"__complete"` to
  `reserved-task-names`.
- Modify: `tests/e2e.sh` — completion e2e checks.
- Modify: `README.md` — "Shell completions" section.
- Modify: `docs/ARCHITECTURE.md` — components table + a short
  completion paragraph (AGENTS.md same-PR rule).

All commands below run from the repo root
(`/Users/andrew/Projects/worktrees/lgx/completions`). Dev-mode unit
test command (verified working in this environment):
`LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg lg lgx.lg test`
(366 tests / 503 assertions pass before this work).

## Implementation Steps

### Task 1: Pure candidate logic

**Files:**
- Create: `lgx/completion.lg`
- Test: `test/lgx/completion_test.lg`

- [ ] **Step 1: Write failing tests for `candidates`**
  Cover: empty `words` + empty `cur` → all built-ins plus task names,
  sorted; prefix filter (`"ru"` → `["run"]`, `"te"` → `["test"]`);
  a namespaced task name `foo/bar` offered and prefix-matched by
  `"foo"`; empty `task-names` → built-ins only; `completion` and
  `__complete` absent from output; leading `["--verbose"]` and
  `["--with" "dev"]` still complete command names; `["--with"]` as
  the final word → `[]`; a typed command (`["run"]`, and
  `["--verbose" "build"]`) → `[]`; an unknown flag-looking token
  (`["--foo"]`) is skipped and command names still complete;
  `cur` of `"-"`/`"--"` → `[]`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg lg lgx.lg test test/lgx/completion_test.lg`
  Expected: FAIL (namespace `lgx.completion` does not exist yet).

- [ ] **Step 3: Implement `builtin-commands` and `candidates`**
  Pure code only — no I/O in these functions. Loop-based word walk as
  designed above; prefix filter with `str/starts-with?`; sort the
  result.

- [ ] **Step 4: Run the full unit suite**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg lg lgx.lg test`
  Expected: PASS (366 + new assertions, 0 failures).

- [ ] **Step 5: Commit**
  `git commit -m "Add pure completion candidate logic"`

### Task 2: Script constants and the `completion` command

**Files:**
- Modify: `lgx/completion.lg`, `lgx.lg`, `lgx/config.lg`
- Test: `test/lgx/completion_test.lg`

- [ ] **Step 1: Write failing tests for the script constants and shell lookup**
  Each of the three script strings is non-empty, contains
  `__complete`, and registers completion for `lgx` (bash:
  `complete -o default`, zsh: `#compdef lgx`, fish: `complete -c
  lgx`); the shell→script lookup returns nil for `"nope"`. Also
  assert `"completion"` and `"__complete"` are in
  `config/reserved-task-names`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg lg lgx.lg test test/lgx/completion_test.lg`
  Expected: FAIL (constants and lookup missing).

- [ ] **Step 3: Implement the scripts, lookup, and `cmd-completion!`**
  Port the three wtr scripts (see Design) as string constants with a
  `completion-script` lookup fn; `cmd-completion!` validates its
  single argument and prints the script or the stderr error + exit 1.
  Add `"completion"` and `"__complete"` to `reserved-task-names` in
  `lgx/config.lg`. Add the `"completion"` dispatch branch in `lgx.lg`
  (require `lgx.completion`). Do **not** touch `command-rows` — the
  command stays out of help.

- [ ] **Step 4: Run the full unit suite**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg lg lgx.lg test`
  Expected: PASS.

- [ ] **Step 5: Smoke-check in dev mode**
  Run: `lg lgx.lg completion bash | head -3` → bash script;
  `lg lgx.lg completion nope; echo exit=$?` → stderr error, `exit=1`;
  `lg lgx.lg help | grep -c completion` → `0`.

- [ ] **Step 6: Commit**
  `git commit -m "Add hidden lgx completion command with bash/zsh/fish scripts"`

### Task 3: `__complete` endpoint and e2e coverage

**Files:**
- Modify: `lgx/completion.lg`, `lgx.lg`, `tests/e2e.sh`

- [ ] **Step 1: Implement `complete!` and the dispatch branch**
  `complete!` as designed (words/cur split, non-throwing config read,
  try/catch around the whole body, no `os/exit` inside). Dispatch:
  `"__complete"` branch calls it then `(os/exit 0)`. Place both new
  branches near `"help"` in the case.

- [ ] **Step 2: Smoke-check in dev mode**
  From the repo root (lgx is itself an lgx project with no `:tasks`):
  `lg lgx.lg __complete ""` → the eight built-ins;
  `lg lgx.lg __complete ru` → `run`;
  `lg lgx.lg __complete run ""` → nothing, exit 0;
  from `/tmp` (no project): `lg` dev mode won't work there, so this
  case is covered in e2e instead.

- [ ] **Step 3: Add e2e checks to `tests/e2e.sh`**
  Following the file's existing helper/assert style: `bin/lgx
  __complete ""` lists `run` and `build`; in a fixture project that
  declares tasks, the task name appears in `__complete ""` output and
  filters by prefix; outside any project (e.g. a temp dir), 
  `__complete ""` exits 0 and still lists built-ins; with an invalid
  `lgx.edn` fixture, `__complete ""` exits 0; `bin/lgx completion
  bash` is non-empty and mentions `__complete`; `bin/lgx completion
  nope` exits 1; `bin/lgx help` does not mention `completion`.
  Reuse/extend an existing task fixture under `tests/fixtures/` if one
  declares `:tasks`; otherwise add a minimal one.

- [ ] **Step 4: Run the full suite (build + unit + e2e)**
  Run: `bash tests/run.sh`
  Expected: all pass. (Known flake: the macOS shell sharing this
  filesystem can clobber `bin/lgx` if it runs `make test`
  concurrently — an `Exec format error` mid-e2e means rerun, not a
  regression.)

- [ ] **Step 5: Interactive bash smoke test**
  `source <(bin/lgx completion bash)` in a bash shell, then check
  `lgx <TAB>` lists commands and `lgx ru<TAB>` completes to `run`.
  zsh/fish scripts follow wtr's tested patterns; if those shells are
  unavailable here, note it in the final report.

- [ ] **Step 6: Commit**
  `git commit -m "Add __complete endpoint for dynamic shell completion"`

### Task 4: Documentation

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: README "Shell completions" section**
  Under Installation, one snippet per shell: bash
  `source <(lgx completion bash)` in `~/.bashrc`; zsh
  `lgx completion zsh > ~/.zfunc/_lgx` (with an `fpath` note) or
  `source <(lgx completion zsh)`; fish
  `lgx completion fish > ~/.config/fish/completions/lgx.fish`.
  Mention that completion covers commands and project task names.
  Use /writing-clearly.

- [ ] **Step 2: Update `docs/ARCHITECTURE.md`**
  Add `lgx/completion.lg` to the components table and a short
  paragraph describing the two hidden entry points and the
  never-break-the-shell error policy. Note `completion`/`__complete`
  in the reserved-names context where the doc discusses task
  shadowing, if it does.

- [ ] **Step 3: Format check and final run**
  Run: `make fmt-check` then
  `LGX_LG=/Users/andrew/Projects/let-go/.tmp/lg lg lgx.lg test`
  Expected: both pass.

- [ ] **Step 4: Commit**
  `git commit -m "Document shell completions"`
