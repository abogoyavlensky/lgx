# Override Built-in Commands, `:task` Steps, and `:args/rest` Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a project task in `lgx.edn` override a built-in command (with `lgx:<name>` always reaching the original), add a `:task` step that invokes another task or built-in, and add an explicit `:args/rest` placeholder so an override keeps the built-in's CLI args.

**Tech Stack:** let-go (Clojure dialect, `.lg`), `lgx.spec` schema engine, bash e2e harness (`tests/e2e.sh`).

---

## Design

### Why

lgx's built-in names (`test`, `build`, `run`, `clean`) are the most common
task names in existence, so collisions are structural. Today a task named
like a built-in makes the whole `lgx.edn` invalid (`config.lg`
`task-name-errors`), which is what turned the `clean` command in 0.2.0 into a
breaking change. Mix and Leiningen both let aliases shadow built-in tasks and
reach the original from inside the alias; that is the model here.

Out of scope: changing the auto-context conventions (`:dev`/`:test`),
shipping defaults as data, and a `:depends` key.

### Dispatch order

`dispatch` in `lgx.lg` resolves a command word in this order. First match
wins.

1. `nil` → usage, exit 1 (unchanged).
2. **Fixed commands**, never overridable: `help`/`-h`/`--help`,
   `version`/`-v`/`--version`, `new`, `completion`, `__complete`. They run
   without a project, so a project can never sit in front of them.
3. **`lgx:<name>`** → strip the prefix. If `<name>` is an overridable
   built-in, run that built-in. Otherwise
   `lgx: 'lgx:<name>' is not a built-in command (built-ins: lgx:build, lgx:clean, lgx:info, lgx:install, lgx:nrepl, lgx:repl, lgx:run, lgx:test)`
   on stderr, exit 1.
4. **Project task**: with a project found and its config loading cleanly
   (`config/find-project` + non-throwing `config/load-config`), a task whose
   name equals the command word runs via `cmd-task`. An invalid `lgx.edn`
   skips this step silently; built-ins that need the config keep reporting
   the errors themselves, exactly as today.
5. **Overridable built-in**: `run repl nrepl build test install info clean`.
6. Unknown → existing branch (with a project and an invalid config, the
   validation report; otherwise `'<cmd>' is not a lgx command`).

The overridable and fixed sets live in `lgx/config.lg` and replace
`reserved-task-names`. The speculative reservations `add`, `update`, `tasks`
are dropped.

### Task-name rules (config load)

- A fixed name → `conflicts with built-in command "new", which cannot be overridden; rename the task`.
- A name starting with `lgx:` → `the lgx: prefix is reserved for built-in commands; rename the task`.
- A name starting with `-` → `task names cannot start with "-"`.
- Any overridable name is accepted.

### `:task` step

A third step type next to `:sh` and `:run`. Value is a symbol or a vector
whose first item is a symbol, followed by strings, `:arg/<name>`
placeholders, or `:args/rest`:

```edn
{:task fmt}
{:task [fmt "check"]}
{:task lgx:test}
{:task [lgx:test "--exclude" "a.b-test"]}
{:task [lgx:test :args/rest]}
```

**Execution model: the step re-invokes lgx itself as a child process.** Every
built-in either exits the process on its own paths or hands the process to
`lg` (`runner/exec-lg-interactive!`), and `repl`/`nrepl` are interactive, so
an in-process call cannot return to continue the chain. Spawning lgx itself
reuses dispatch, arity checks, basis layering, and headers unchanged, and a
wrapped `lgx:nrepl` owns the terminal like a direct call would. The child is
the same binary, never a `PATH` lookup.

- **Self binary** comes from `os/args` (`cli/self-invocation`): in dev
  (`lg lgx.lg ...`, argv[1] ends in `.lg`) bin = argv[0] and prefix =
  `[argv[1]]`; as a bundle bin = argv[0] and prefix = `[]`. Same rule as
  `cli/user-args`. let-go has no executable-path builtin, and argv[0] is a
  bare `lgx` when the user invoked it through `PATH`, so the bin is resolved
  once by `cli/resolve-self-bin`: a value containing `/` is absolutized
  against `os/cwd`; a bare name takes the first `PATH` directory where
  `<dir>/<name>` exists (`os/stat`, split on `os/path-separator`); no hit
  leaves it unchanged. The child therefore runs the exact file the parent
  is, even under a version-manager shim (the shim path is what resolves,
  and the child inherits the cwd the shim keys on).
- **Child argv**: `<prefix> [--verbose] [--with a,b] <callee> <args...>`.
  `--verbose` propagates when the parent runs verbose. `--with` carries the
  parent's *effective* contexts, task `:with` ++ CLI `--with`, so the
  child's existing layering does the union with the caller's contexts winning
  on collision. No new precedence rule.
- **Stdio** is inherited through `runner/exec-interactive!` (the tty
  passthrough extracted from `exec-lg-interactive!`), so output streams live
  and interactive children work. `os/exec*` returns the child's exit code.
- **Echo line**: `$ lgx <callee> <args>` via `style/step-line`, matching the
  `:run` step's `$ lgx run ...`.
- **Exit**: as today, the first non-zero step exit stops the chain and
  becomes the task's exit code.
- **Validation** at config load (root-level cross-check like
  `with-refs-errors`): a callee `lgx:<x>` must name an overridable built-in →
  else `references unknown built-in lgx:<x> (built-ins: lgx:build, ...)`;
  any other callee must be a defined task → else
  `references unknown task <x> (defined: a, b)` or `(no other tasks defined)`;
  a task whose `:task` step names itself →
  `calls itself; use lgx:<name> to call the built-in`. Error paths are
  `[:tasks <task> :do <i> :task]`.

### Cycle guard: `LGX_TASK_STACK`

One mechanism covers direct `:task` recursion, indirect cycles, and the
`{:sh "lgx test"}` mistake inside an override of `test`, because every hop
is a child process. `cmd-task`:

1. Reads `LGX_TASK_STACK` (comma-separated task names, `""` when unset).
2. If the task's name is already on it, prints
   `lgx: task '<name>' is already running (<a> > <b> > <name>); to call the built-in from a task, use lgx:<name>`
   and exits 1. The chain lists the inherited stack followed by the
   re-entered name, joined by ` > `.
3. Otherwise sets `LGX_TASK_STACK` to `<stack>,<name>` (or `<name>`) before
   running steps. `:sh` and `:task` children inherit it.

`LGX_TASK_STACK` joins `runner/lgx-set-env-names` so the `--verbose`
`+ env` trace shows it. Only user task names go on the stack; `lgx:<name>`
built-ins never re-enter tasks.

### `:args/rest` passthrough

Today a task without `:args` rejects any CLI args, so a wrapper such as
`test {:do [{:sh "docker compose up -d"} {:task lgx:test}]}` would break
`lgx test test/foo_test.lg` and `--exclude`.

- `:args/rest` is a placeholder allowed in **vector-form** step values only
  (`:sh`, `:run`, `:task`). No `{{rest}}` string form: a raw joined splice
  would lose quoting.
- Its presence anywhere in a task's steps (`args/uses-rest?`) relaxes the
  "too many arguments" check. Rest = the CLI args left after the declared
  positionals bind (all of them when the task declares no `:args`).
- Expands to N items: each shell-quoted in `:sh`, verbatim in `:run` and
  `:task`. Bound values travel in the same `bindings` map as
  `:arg/<name>` entries, under the key `:args/rest` (a vector of strings).
- Usage and the help signature append `[args...]` when a task uses it.
- A task that does not use `:args/rest` keeps strict arity, and its
  surplus-args error gains a hint:
  `lgx: test: task takes no arguments (got 1); to forward extra args to a step, add :args/rest to it`
  (same suffix on the "too many arguments" variant). Implicit append-to-last-step
  (Mix, npm) was rejected: it misroutes args into teardown steps, needs a
  quoting rule for `:sh` strings, and drops strict arity.
- The namespace differs from `:arg/` on purpose so it can never collide with
  a declared arg named `rest`. An unknown `:arg/rest` placeholder gets a hint:
  `...; for the leftover CLI args use :args/rest`.

### Help and completion

- `lgx help` task rows for a task that overrides a built-in append
  `(overrides built-in; run lgx:<name> for the original)` to the doc column
  (just that text when the task has no `:doc`).
- A new built-in row:
  `  lgx lgx:<command>            Run a built-in command directly, even when a project task overrides it`.
- No stderr notice when an overriding task is invoked; the user wrote it.
- Completion at the command position offers `lgx:<name>` for each built-in
  the project actually overrides, and every `lgx:<overridable>` form once the
  typed word starts with `lgx:`. A bare TAB does not gain eight extra entries.

### Testing strategy

- Unit (`test/lgx/`, run with `lg lgx.lg test <file>` from the repo root):
  config validation (name rules, `:task` shapes and targets, `:args/rest`
  acceptance and hint), args binding with rest, cli self-invocation and
  child-argv helpers, completion candidates, runner env-name list.
- E2E (`tests/e2e.sh`, needs `make build`): override `test` and confirm the
  file arg passes through; `lgx lgx:test` bypasses the wrapper; `:sh "<lgx> test"`
  inside `test` errors with the hint; `:task` into a user task inherits
  `--with` contexts; `:task` exit code stops the chain; help marks the
  override; config errors for `lgx:` names and unknown targets; completion
  offers `lgx:test` only when overridden. Scenario 19 flips from "rejected" to
  "runs the task".

## File Structure

Modify:

- `lgx/config.lg` — `overridable-commands` / `fixed-commands` replace
  `reserved-task-names`; `task-name-errors` rules; `:task` in step schema;
  `:args/rest` accepted in step vectors; `task-targets-errors` root
  cross-check; `overridable-command?` accessor.
- `lgx/args.lg` — `bind-args` 3-arity with `rest?`; `substitute` splices
  `:args/rest`; `uses-rest?`; `signature`/`usage-line` render `[args...]`.
- `lgx/cli.lg` — `self-invocation`, `resolve-self-bin`, `strip-lgx-prefix`, `child-args`.
- `lgx/runner.lg` — `exec-interactive!` extracted; `LGX_TASK_STACK` in
  `lgx-set-env-names`.
- `lgx/tasks.lg` — `run-task-step!`; `run-task!` gains the effective `--with`
  list to forward.
- `lgx.lg` — dispatch order, `run-builtin`, `cmd-task` stack guard and rest
  binding, `task-line` mark, help row.
- `lgx/completion.lg` — `lgx:` candidates.
- `tests/e2e.sh` — Scenario 19 flipped; new scenarios appended after the last
  numbered one.
- `test/lgx/config_test.lg`, `test/lgx/args_test.lg`, `test/lgx/cli_test.lg`,
  `test/lgx/completion_test.lg`, `test/lgx/runner_test.lg` — unit tests.
- `README.md`, `docs/ARCHITECTURE.md` — docs in the same change.

No new source files: every piece extends a module that already owns that
responsibility.

## Tasks

Run unit tests from the repo root in dev mode, e.g.
`lg lgx.lg test test/lgx/config_test.lg`. The summary line ends in
`0 failures` on success; a failing `deftest` prints a `✗` line with the
assertion. Run the whole suite with `make test` (bundles, unit, e2e).

### Task 1: Command sets and task-name rules

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`, `test/lgx/completion_test.lg`

- [x] **Step 1: Write the failing tests**
  In `config_test.lg`, replace `load-rejects-reserved-task-names` (around
  line 568) with: `load-accepts-overridable-task-names` (a config whose
  `:tasks` has `run`, `test`, `clean`, and `add` loads with no errors);
  `load-rejects-fixed-task-names` (`new`, `help`, `version`, `completion`,
  `__complete` each produce the "cannot be overridden" message with path
  `[:tasks <name>]`); `load-rejects-lgx-prefixed-task-name` (`lgx:test` →
  the reserved-prefix message); `load-rejects-dash-prefixed-task-name`
  (`-v` → the dash message). In `completion_test.lg`, update
  `completion-commands-reserved` (line 156) to assert `completion` and
  `__complete` are in `config/fixed-commands`.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/config_test.lg`
  Expected: the new tests fail (`reserved-task-names` still rejects `run`;
  `fixed-commands` is unresolved).

- [x] **Step 3: Implement**
  In `config.lg` replace `reserved-task-names` with
  `(def overridable-commands #{"run" "repl" "nrepl" "build" "test" "install" "info" "clean"})`
  and `(def fixed-commands #{"new" "help" "version" "completion" "__complete"})`,
  plus `(defn overridable-command? [s] ...)`. Rewrite the last clause of
  `task-name-errors` into the three rules from the design (fixed name, `lgx:`
  prefix, leading `-`), using `(str k)` as today so a namespaced `foo/run`
  stays untouched. Update the comment above the defs to explain why the sets
  are split. Grep the repo for `reserved-task-names` and fix every
  reference.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/config_test.lg && lg lgx.lg test test/lgx/completion_test.lg`
  Expected: both summaries end in `0 failures`.

- [x] **Step 5: Commit**
  `git commit -am "config: tasks may use built-in names except the fixed commands"`

### Task 2: `:task` step schema and target validation

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests**
  Add to `config_test.lg`: `load-accepts-task-step-symbol`
  (`{:task fmt}` with `fmt` defined); `load-accepts-task-step-vector`
  (`{:task [fmt "check"]}`); `load-accepts-task-step-builtin`
  (`{:task lgx:test}`, `{:task [lgx:test "--exclude" "a"]}`);
  `load-rejects-task-step-non-symbol` (`{:task "fmt"}` and `{:task ["fmt"]}`
  → a message naming the expected shape); `load-rejects-task-step-unknown-task`
  (`{:task nope}` → `references unknown task nope (defined: fmt)`, path
  `[:tasks ci :do 0 :task]`); `load-rejects-task-step-unknown-builtin`
  (`{:task lgx:nope}` → the "unknown built-in" message listing the eight
  `lgx:` names); `load-rejects-task-step-self-call` (task `test` with
  `{:task test}` → `calls itself; use lgx:test to call the built-in`);
  `load-rejects-step-with-task-and-sh` (exactly-one-action message now names
  `:sh, :run, :task`); `load-normalizes-single-task-step-map`.

- [x] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/config_test.lg`
  Expected: FAIL, `:task` is an unknown step key.

- [x] **Step 3: Implement**
  In `config.lg`: add `task-value-errors` (symbol, or non-empty vector whose
  first item is a symbol and whose remaining items pass the same rule as
  `action-value-errors` items); add `[:task {:optional true} [:fn task-value-errors]]`
  to `step-schema`; extend `exactly-one-action-errors` to
  `[:sh :run :task]` and its message. Generalize `step-placeholder-errors` to
  find the present action key and, for `:task`, skip the leading symbol.
  Add `task-targets-errors` (root-level, after `with-refs-errors` in
  `lgx-schema`): walk every task's `:do` (map or vector, since validation runs
  before `normalize-config`), and for each `:task` step apply the three
  rules from the design. Add a small `task-callee` helper returning the
  symbol from either value form; `normalize-config` needs no change beyond
  the single-map wrapping it already does.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/config_test.lg`
  Expected: `0 failures`.

- [x] **Step 5: Commit**
  `git commit -am "config: validate :task steps and their targets"`

### Task 3: `:args/rest` binding and substitution

**Files:**
- Modify: `lgx/args.lg`, `lgx/config.lg`
- Test: `test/lgx/args_test.lg`, `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests**
  `args_test.lg`: `bind-rest-collects-surplus` (`(args/bind-args [] ["a" "b"] true)`
  → `{:bindings {:args/rest ["a" "b"]}}`); `bind-rest-after-declared`
  (decls `[{:name :env}]`, args `["prod" "x" "--flag"]`, rest? true →
  env bound, rest `["x" "--flag"]`); `bind-rest-empty-when-none`
  (rest? true, no surplus → `:args/rest []`); `bind-without-rest-still-strict`
  (2-arity unchanged, surplus errors); `substitute-splices-rest-verbatim`
  (`[lgx:test :args/rest]` with rest `["a" "b"]`, quote? false →
  `[lgx:test "a" "b"]`); `substitute-quotes-each-rest-item`
  (quote? true → each item single-quoted); `uses-rest-detects-placeholder`
  (`(args/uses-rest? [{:sh "x"} {:task [lgx:test :args/rest]}])` → true,
  and false without it, and false for a string-form value);
  `signature-appends-rest`, `usage-line-appends-rest` (`[args...]`).
  `config_test.lg`: `load-accepts-args-rest-in-step-vector` (`:sh`, `:run`,
  and `:task` vector forms with `:args/rest`, no `:args` declared);
  `load-rejects-arg-rest-with-hint` (`{:sh [:arg/rest]}` → message ends
  with `for the leftover CLI args use :args/rest`).

- [x] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/args_test.lg`
  Expected: FAIL, arity and unresolved `uses-rest?`.

- [x] **Step 3: Implement**
  `args.lg`: `bind-args` gets a 3-arity `[decls cli-args rest?]`; the
  2-arity delegates with `false` and keeps its exact return shape. With
  `rest?` true, surplus args (those past the declared positionals) bind under
  `:args/rest` instead of erroring. `substitute`: when an item is
  `:args/rest`, splice `(get bindings :args/rest)` (quoted per item when
  `quote?`), so the function now builds its result with `mapcat`-style
  accumulation rather than `mapv`; an absent `:args/rest` binding is a
  programmer error like an unbound `:arg/` placeholder. Add
  `uses-rest? [steps]` (true when any step's vector-form value contains
  `:args/rest`; string values never match). `signature`/`usage-line` take
  an optional trailing `rest?` and append `[args...]`. Update the ns header
  comment. `config.lg`: `action-value-errors` and `task-value-errors` accept
  `:args/rest` items; `step-placeholder-errors` ignores `:args/rest` and
  appends the hint when the unknown placeholder is exactly `:arg/rest`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/args_test.lg && lg lgx.lg test test/lgx/config_test.lg`
  Expected: `0 failures` for both.

- [x] **Step 5: Commit**
  `git commit -am "args: :args/rest forwards the leftover CLI args into a step"`

> Deviation (Step 3): while rewriting `bind-args` into a 2/3-arity form a
> closing paren went missing, which let-go swallowed silently — the whole tail
> of `args.lg` ended up nested inside `bind-args` and every var after
> `rest-key` became unresolvable, with no reader error. Fixed by balancing the
> form; noting it because "silent truncation after an unbalanced form" is a
> let-go gotcha worth remembering.

### Task 4: CLI helpers for self-invocation and `lgx:` names

**Files:**
- Modify: `lgx/cli.lg`
- Test: `test/lgx/cli_test.lg`

- [x] **Step 1: Write the failing tests**
  `self-invocation-dev-prefix` (`["lg" "lgx.lg" "run"]` →
  `{:bin "lg" :prefix ["lgx.lg"]}`); `self-invocation-bundle`
  (`["/x/bin/lgx" "run"]` → `{:bin "/x/bin/lgx" :prefix []}`);
  `strip-lgx-prefix` (`"lgx:test"` → `"test"`, `"test"` → nil, `"lgx:"` →
  `""`); `child-args-plain` (`(cli/child-args [] false "fmt" ["check"])` →
  `["fmt" "check"]`); `child-args-with-and-verbose`
  (`[:dev :test]`, true → `["--verbose" "--with" "dev,test" "fmt" "check"]`);
  `child-args-keeps-context-namespace` (`[:app/dev]` → `"--with" "app/dev"`,
  which `parse-with-value` reads back as `:app/dev`);
  `resolve-self-bin-absolute` (`"/x/bin/lgx"` unchanged);
  `resolve-self-bin-relative-absolutizes` (`"./bin/lgx"` with cwd `/w` →
  `/w/bin/lgx`); `resolve-self-bin-bare-searches-path` (`"lgx"`, PATH
  `/a:/b`, an injected `exists?` true only for `/b/lgx` → `/b/lgx`);
  `resolve-self-bin-bare-unresolved-unchanged` (no hit → `"lgx"`).

- [x] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/cli_test.lg`
  Expected: FAIL, unresolved fns.

- [x] **Step 3: Implement**
  Add the pure fns to `cli.lg` next to `user-args`, sharing its
  "argv[1] ends with `.lg`" rule. `child-args` renders each context keyword
  as `(subs (str k) 1)` so a namespaced `:app/dev` survives the round trip
  (never `name`, which drops the namespace), comma-joined, and emits
  `--with` only when the list is non-empty. `resolve-self-bin` takes
  `[argv0 cwd path-env sep exists?]` so tests inject the filesystem check;
  `self-invocation` wires it to `os/cwd`, `(os/getenv "PATH")`,
  `os/path-separator`, and an `os/stat`-based `exists?` that rejects
  directories. Use `path/absolute?` and `path/join` from `lgx/path.lg`.

- [x] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/cli_test.lg`
  Expected: `0 failures`.

- [x] **Step 5: Commit**
  `git commit -am "cli: self-invocation, lgx: prefix, and child argv helpers"`

> Deviation (Step 3): `self-invocation` stays pure (an argv split only), as its
> planned unit tests require — the filesystem resolution lives in
> `resolve-self-bin` (pure, injected `exists?`) plus a thin
> `resolve-self-bin!` wrapper. Callers compose the two. The planned PATH walk
> (`os/stat` per candidate dir) was replaced after codex review: `os/stat`
> reports no mode bits, so the walk could pick a non-executable file the shell
> would skip. `resolve-self-bin` now takes `[argv0 cwd lookup]` and
> `cli/path-lookup` delegates the bare-name case to `command -v`, the same way
> `runner/lg-resolved-path` already does.

### Task 5: Runner: `exec-interactive!` and the stack env name

**Files:**
- Modify: `lgx/runner.lg`
- Test: `test/lgx/runner_test.lg`

- [ ] **Step 1: Write the failing test**
  Find the existing `env-trace-line` tests in `runner_test.lg` and add
  `env-trace-includes-task-stack` (a lookup map with `LGX_TASK_STACK`
  `"ci,test"` renders `LGX_TASK_STACK=ci,test` in the line, after `LGX_RUN`).

- [ ] **Step 2: Run test to verify it fails**
  Run: `lg lgx.lg test test/lgx/runner_test.lg`
  Expected: FAIL, the var is not in the trace.

- [ ] **Step 3: Implement**
  Add `"LGX_TASK_STACK"` to `lgx-set-env-names`. Extract
  `exec-interactive! [bin args]` from `exec-lg-interactive!`: it performs the
  tty check, `passthrough-handles`, the `binding`, and `(apply os/exec* bin args)`,
  and returns the exit code. `exec-lg-interactive!` becomes
  `lg-invocation!` followed by `(os/exit (exec-interactive! bin args))`.
  Move the passthrough rationale from the old docstring onto the new fn.

- [ ] **Step 4: Verify**
  Run: `lg lgx.lg test test/lgx/runner_test.lg`
  Expected: `0 failures`.
  Run: `lg lgx.lg run examples/hello/main.lg`
  Expected: the example's output, exit 0 (the interactive path still works).

- [ ] **Step 5: Commit**
  `git commit -am "runner: extract exec-interactive!, trace LGX_TASK_STACK"`

### Task 6: `:task` step execution

**Files:**
- Modify: `lgx/tasks.lg`

- [ ] **Step 1: Implement**
  Require `lgx.cli`. Add `run-task-step! [value bindings child-with verbose?]`:
  substitute the value (vector form: `args/substitute` verbatim; symbol form:
  one-item vector), take the callee as `(str (first v))` and the args as the
  remaining strings, build the argv with `cli/self-invocation os/args` and
  `cli/child-args`, echo `$ lgx <callee> <args...>` through `style/step-line`
  (blank line first, like the other steps), print `+ <bin> <argv>` under
  verbose, and return `(runner/exec-interactive! bin argv)`. Wire it into
  `run-step!` on `(contains? step :task)`. `run-task!` gains a trailing
  `child-with` parameter (the effective context-name vector) and threads it
  to `run-step!`. Update the ns header comment to list the third step type
  and the rest placeholder.

- [ ] **Step 2: Verify it loads**
  Run: `lg lgx.lg help`
  Expected: usage prints, no load error (a signature mismatch surfaces
  only at call time, so Task 7's e2e is the real check).

- [ ] **Step 3: Commit**
  `git commit -am "tasks: :task step re-invokes lgx for a task or built-in"`

### Task 7: Dispatch, stack guard, and help marks

**Files:**
- Modify: `lgx.lg`

- [ ] **Step 1: Implement dispatch**
  Extract the eight overridable branches of the `case` in `dispatch` into
  `run-builtin [name rest-args verbose? with]` (returns nil for an unknown
  name). Rewrite `dispatch` in the order from the design: fixed names and
  flags first (keep the `nil` and hidden-command branches); then
  `cli/strip-lgx-prefix` → `run-builtin` or the "not a built-in command"
  error; then the project-task lookup using `config/find-project` and the
  non-throwing `config/load-config` (only a `{:cfg ...}` result is consulted);
  then `run-builtin`; then the existing unknown-command branch, which keeps
  using `load-config!` so an invalid config still prints its report.

- [ ] **Step 2: Implement the stack guard and rest binding in `cmd-task`**
  Before binding args: read `LGX_TASK_STACK`, split on `,` dropping blanks;
  if it contains `task-name`, print the "already running" line from the
  design and exit 1. Bind with
  `(args/bind-args decls rest-args (args/uses-rest? (:do task)))` and pass
  the same `rest?` to `usage-line`. When binding fails on surplus args and the task
  does not use `:args/rest`, append
  ` (to forward extra args to a step, add :args/rest to it)` to that error
  line before the usage line. After the basis is built and before
  `run-task!`, `os/setenv "LGX_TASK_STACK"` to the extended stack. Pass
  `(vec (concat (:with task) with))` as `child-with`.

- [ ] **Step 3: Help**
  `task-line`: when `(config/overridable-command? (str task-name))`, append
  ` (overrides built-in; run lgx:<name> for the original)` to the doc, or use
  that text alone when `:doc` is blank; the signature should include
  `[args...]` for rest-using tasks via `args/signature`. Add the
  `lgx lgx:<command>` row to `command-rows` after the `lgx clean` rows,
  keeping the hand-aligned description column (`doc-col`).

- [ ] **Step 4: Smoke test in dev mode**
  Create a throwaway project under `/tmp` with a `test/` dir holding one
  passing `*_test.lg` and this `lgx.edn`:
  ```edn
  {:tasks {test {:doc "Wrapped" :do [{:sh "echo wrapper"} {:task [lgx:test :args/rest]}]}}}
  ```
  Run from the lgx repo root (dev mode needs it):
  `(cd /tmp/proj && lg /home/agent/Projects/lgx/lgx.lg test)` is not enough
  because dev mode resolves `lgx/*.lg` from the cwd; instead run `make build`
  and use `bin/lgx` from `/tmp/proj`:
  `cd /tmp/proj && /home/agent/Projects/lgx/bin/lgx test`
  Expected: `wrapper` on stdout, then the purple step line and the built-in
  test run; exit 0. Then `bin/lgx test test/<file>` runs only that file, and
  `bin/lgx lgx:test` skips `wrapper`. Then change the task to
  `{:sh "/home/agent/Projects/lgx/bin/lgx test"}` and confirm the
  "already running" error with exit 1.

- [ ] **Step 5: Commit**
  `git commit -am "dispatch: project tasks override built-ins; lgx:<name> reaches the original"`

### Task 8: Completion candidates

**Files:**
- Modify: `lgx/completion.lg`
- Test: `test/lgx/completion_test.lg`

- [ ] **Step 1: Write the failing tests**
  `overridden-builtin-offers-lgx-form` (tasks `{"test" nil}` at the command
  position → candidates include `lgx:test`, and do not include `lgx:run`);
  `bare-prompt-has-no-lgx-forms-without-overrides` (no tasks → no `lgx:`
  candidates); `lgx-prefix-offers-all-builtins` (cur `"lgx:"` → all eight
  `lgx:` names, sorted); `lgx-prefix-filters` (cur `"lgx:t"` → `["lgx:test"]`).

- [ ] **Step 2: Run tests to verify they fail**
  Run: `lg lgx.lg test test/lgx/completion_test.lg`
  Expected: FAIL.

- [ ] **Step 3: Implement**
  In `candidates`, at the command position build the value list as
  `builtin-commands` ++ task names ++ `lgx:<name>` for each task name in
  `config/overridable-commands` ++ (when `cur` starts with `lgx:`) every
  `lgx:<overridable>`; dedupe before `matches`. Update the header comment
  about which names are offered when.

- [ ] **Step 4: Run tests to verify they pass**
  Run: `lg lgx.lg test test/lgx/completion_test.lg`
  Expected: `0 failures`.

- [ ] **Step 5: Commit**
  `git commit -am "completion: offer lgx:<name> for overridden built-ins"`

### Task 9: E2E scenarios

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Flip Scenario 19**
  Rename to `task named like a built-in overrides it`: a `run` task with
  `{:sh "echo task-run"}`; `lgx run` prints `task-run` and exits 0;
  `lgx lgx:run` in the same project (no `:main`) fails with the existing
  `nothing to run` error, proving the prefix bypasses the task.

- [ ] **Step 2: Append new scenarios after Scenario 133**
  Number them from 134 and gate the ones that run `lg` on
  `supports_source_paths` like the other test-command scenarios:
  1. **Override `test` with passthrough**: project with `test/foo_test.lg`
     (one passing `deftest`) and
     `test {:do [{:sh "echo wrapper"} {:task [lgx:test :args/rest]}]}`.
     `lgx test` → stdout contains `wrapper` and the harness summary line,
     exit 0. `lgx test test/foo_test.lg` → stderr contains
     `Running tests in test/foo_test.lg...`. `lgx lgx:test` → no `wrapper`.
     `lgx test a b` → still reaches the built-in, which rejects two positionals
     with its own `test takes at most one argument`, exit 1.
  2. **Self-recursion guard**: `test {:do {:sh "$LGX test"}}` (unquoted
     heredoc so the absolute bundle path lands in the file) → exit 1, output
     contains `task 'test' is already running` and `use lgx:test`.
  3. **`:task` into a user task inherits contexts**: context
     `:dev {:extra-paths ["dev"]}` with `dev/helper.lg`; `inner {:do {:run "scripts/hi.lg"}}`
     requiring `helper`; `outer {:with [:dev] :do {:task inner}}`. `lgx outer`
     prints the helper's output; `lgx inner` alone fails to resolve `helper`.
  4. **`:task` exit code stops the chain**: `inner {:do {:sh "exit 7"}}`,
     `outer {:do [{:task inner} {:sh "echo after"}]}` → exit 7, no `after`.
  5. **`:task` with args**: `greet {:args [{:name :who}] :do {:sh ["echo" "hi" :arg/who]}}`,
     `ci {:do {:task [greet "bob"]}}` → `hi bob`.
  6. **Help marks the override**: `lgx help` with a `clean` task shows
     `(overrides built-in; run lgx:clean for the original)` and the
     `lgx lgx:<command>` row.
  7. **Config errors**: task named `lgx:x` → `reserved for built-in commands`;
     task named `new` → `cannot be overridden`; `{:task nope}` →
     `references unknown task nope`; `{:task lgx:nope}` → `unknown built-in`;
     `test {:do {:task test}}` → `calls itself`.
  8. **CLI `lgx:nope`** → exit 1, `is not a built-in command`.
  9. **Completion**: `lgx __complete ""` in a project overriding `test` lists
     `lgx:test`; in a project without tasks it lists no `lgx:` entries;
     `lgx __complete "lgx:"` lists all eight.
  10. **Arity hint**: extend Scenario 107 (args passed to a task without
     `:args`) to assert the error ends with `add :args/rest to it`.
  11. **Invocation through PATH**: run the `:task` chain from scenario 3 as
     `PATH="$(dirname "$LGX"):$PATH" lgx outer` from the project dir (bare
     name, no path) and assert the same output, proving the child resolves
     to the same binary when argv[0] is bare.
  12. **Indirect cycle**: `a {:do {:task b}}`, `b {:do {:task a}}` →
     `lgx a` exits 1 with `task 'a' is already running (a > b > a)`.
  13. **Caller contexts reach the callee and layer after its own**: contexts
     `:one {:extra-paths ["one"]}` and `:two {:extra-paths ["two"]}`;
     `inner {:with [:one] :do {:run "scripts/hi.lg"}}`,
     `outer {:with [:two] :do {:task inner}}`. `lgx --verbose outer` →
     stderr shows the child's `--with two` and a `-source-paths` value
     containing both dirs with `one` before `two` (task `:with` precedes the
     forwarded CLI `--with`, matching the documented layering).

- [ ] **Step 3: Run the full suite**
  Run: `make test`
  Expected: `All tests passed.` and the final `All <N> e2e assertions passed.`

- [ ] **Step 4: Commit**
  `git commit -am "e2e: override built-ins, :task steps, :args/rest, cycle guard"`

### Task 10: Documentation

**Files:**
- Modify: `README.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: README**
  Commands table: extend the `lgx <task>` row (a task may override a built-in)
  and add a `lgx lgx:<command>` row. `:tasks` section: replace the "can't
  shadow built-ins ... `clean` since 0.2.0" paragraph with the override rule,
  the fixed-name list, and `lgx:<name>`; document the `:task` step (both
  value forms, self re-invocation, context inheritance, the cycle guard and
  its error); add an `:args/rest` subsection under positional args
  (vector-form only, rest semantics, `[args...]`). `:contexts` layering:
  one sentence that a `:task` step passes the caller's effective contexts as
  `--with`. Environment variables: `LGX_TASK_STACK`. Annotated `lgx.edn`
  example: add a `test` override using `{:task [lgx:test :args/rest]}` and
  switch the `ci` example's shell recursion to `{:task fmt}` style steps.
  Use /writing-clearly.

- [ ] **Step 2: ARCHITECTURE**
  Components table: update the `lgx/cli.lg`, `lgx/runner.lg`, `lgx/tasks.lg`
  lines. `lgx <task>` section: the new dispatch order, `lgx:` addressing,
  the `:task` step (child-process model and why), `LGX_TASK_STACK`,
  `:args/rest`, and replace the "reserved for later via an `:lgx/<name>`
  form" paragraph. Completion section: replace "both are reserved task
  names" with the fixed-commands wording and describe the `lgx:` candidates.
  Contexts section: the `:task` inheritance sentence.

- [ ] **Step 3: Commit**
  `git commit -am "docs: overriding built-ins, :task steps, :args/rest"`

## Follow-ups (not in this plan)

- The three `lgx new` templates' `check` task shells out to `lgx fmt check`
  and `lgx test`; they can move to `{:task ...}` steps once this ships.
- Defaults-as-data (built-in `:with` and the `:test` context shipped as a
  visible default config) builds on `:task` and is a separate slice.
- Bump the version and mention the dropped `add`/`update`/`tasks`
  reservations in the release notes.
