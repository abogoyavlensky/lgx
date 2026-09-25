# let-go: scope `*warn-on-reflection*` to the file that sets it, and honour type hints

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A library's `(set! *warn-on-reflection* true)` no longer turns the warning on for every file loaded after it, and a hinted or constructor-bound local no longer counts as an unknown host target, so a reflection-clean JVM library such as HoneySQL loads silently under let-go.

**Tech Stack:** Go, the let-go compiler and runtime at `~/Projects/let-go` (main, v1.13.0 plus five commits), `make test`, `make lint`.

**Repo:** `~/Projects/let-go`. `origin` is the fork `abogoyavlensky/let-go`; `upstream` is `nooga/let-go`. Each task is its own branch and PR against `upstream/main`. Read `docs/contributor-workflow.md` before starting; the commands below come from it.

Part of a four-plan set whose end goal is `lgx run` on `examples/web-app` printing zero warnings. Siblings: `2026-09-25-1617-letgo-packages-pin-sql-and-exclude-core-names.md`, `2026-09-25-1617-honeysql-exclude-upper-case-under-lg.md`, `2026-09-25-1617-lgx-dedupe-normalized-git-url-and-web-app-bump.md`. This plan is independent of the other three; the lgx plan waits for the release that carries it.

---

## Design

### What happens today

Running the web-app example prints 47 `reflection warning ... (host-interop)` lines: 33 from HoneySQL, 14 from ragtime and the letgo-packages sql and sqlite namespaces. Two let-go behaviours combine to produce them.

**The flag leaks across files.** `*warn-on-reflection*` defaults to false (`pkg/rt/lang.go`, `warnOnReflection`). HoneySQL does `#?(:clj (set! *warn-on-reflection* true))` at the top of five files, standard hygiene for a JVM library. JVM Clojure's `load` pushes thread bindings for `*warn-on-reflection*` and `*unchecked-math*` (among others) before compiling a file, so a `set!` in that file writes the binding and is popped when the load ends. let-go's `rt.WithFile` (`pkg/rt/file_var.go`) binds only `*file*`. The `set!` therefore lands on whatever binding is in effect for the whole process, and every file loaded after HoneySQL warns too. Verified: a two-file project where `lib.setter` sets the flag and `lib.later` does not; `lib.later` warns. Wrapping the `require` in `(binding [*warn-on-reflection* false] ...)` does not help, because the `set!` overwrites that binding for the rest of the load.

**The check is hint-blind.** `hostTargetStaticallyKnown` (`pkg/compiler/compiler.go`, around line 540) returns false for any symbol target. The compiler reads `^String s` as `(with-meta s {:tag String})` and deliberately strips the meta from fn params (around line 420) and let bindings (around line 1696) with a comment saying locals do not carry tags yet. So `(.length ^String s)` warns exactly like `(.length s)`, and `sb` bound to `(StringBuilder.)` warns on every `.append`. JVM Clojure warns on neither. HoneySQL's 33 sites are all of these two shapes, so nothing a library author can write satisfies the check.

### The two changes

**Task 1: per-load bindings, Clojure parity.** `rt.WithFile` also pushes bindings for `*warn-on-reflection*` and `*unchecked-math*` at their current values and pops them on exit. Every load path already goes through `WithFile`: the CLI file runner, `-c`/`-b` compilation, the WASM builder, and `NSResolver.loadFile`, which is what `require` uses. `set!` compiles to `OP_SET_VAR`, which writes the innermost binding when one exists (that is what the `binding`-wrapped experiment showed: the value was false again after the form), so a file's `set!` dies with its load. `*unchecked-math*` gets the same treatment because it is the other compile-time flag Clojure scopes per load and `uncheckedMathEnabled` reads it the same way; leaving it out would be a second copy of the same bug.

Root bindings are the right target. `reflectionWarningsEnabled` derefs through `vm.RootExecContext` at compile time, and `WithFile` already uses `Var.PushBinding`, which targets the root context.

**Task 2: known locals.** The compiler keeps two kinds of lexical binding: fn parameters in `Context.formalArgs` (set in `enterFn`, which strips the hint) and let/loop locals in the `Context.locals` scope stack (pushed by `pushLocals`, populated by `addLocal`). Each `fn` compiles in a fresh child `Context` whose `parent` points at the enclosing one; `resolvesAsLexical` shows the walk. So known-ness needs two stores on `Context`: `knownArgs map[vm.Symbol]bool` beside `formalArgs`, and `knownLocals []map[vm.Symbol]bool` beside `locals`. A binding is known when its form carried `:tag` metadata, or, for let/loop, when its init expression already satisfies the static-target check (a constructor form, a `->Record` call, `with-meta`).

`hostTargetStaticallyKnown` becomes a `Context` method. For a symbol it walks exactly as `resolvesAsLexical` does: for each context from the current one up through `parent`, look in that context's `locals` innermost-first, then in its `formalArgs`; the first context that declares the symbol answers with its known flag and the walk stops there. Stopping at the first declaration is what makes shadowing right: an inner unhinted `s` masks an outer hinted one, and a closure `(fn [^String s] (fn [] (.length s)))` finds the hinted parameter in the parent. Closed-over cells need no separate store because the declaration is always reachable through `parent`.

This changes only the warning, not dispatch. The tag is still not attached to the local and the call still goes through dynamic member lookup. That is stated in the PR description because it is the point the maintainer may want to weigh: the warning stops claiming "not statically known" for a target the author did declare. If upstream prefers to keep the warning until real type-directed dispatch exists, the fallback is on the HoneySQL side (guard the five `set!` lines with `:lg`), and the lgx plan's final verification step accounts for that.

### Testing

Task 1 is tested in `pkg/resolver/resolver_test.go`, which already has the pattern: `t.TempDir()`, write files, `NewNSResolver(ctx, []string{dir})`, require. Capture warnings with `rt.SetReflectionWarningWriter` and `rt.ResetReflectionWarnings` as `pkg/compiler/reflection_warning_test.go` does. Task 2 extends `reflection_warning_test.go`, which compiles snippets with the flag bound true and counts `reflection warning` lines.

## File Structure

- Modify: `pkg/rt/file_var.go` — push the two extra bindings.
- Test: `pkg/resolver/resolver_test.go` — leak regression.
- Modify: `pkg/compiler/compiler.go` — known-locals scope stack, method form of `hostTargetStaticallyKnown`, capture at fn params and let/loop bindings.
- Test: `pkg/compiler/reflection_warning_test.go` — hinted and constructor-bound cases.
- Modify: `docs/known-divergences.md` — only if it lists the leak or the hint behaviour; a grep today finds neither, so expect no change.

## Tasks

### Task 1: Bind `*warn-on-reflection*` and `*unchecked-math*` per file load

**Files:**
- Modify: `pkg/rt/file_var.go`
- Test: `pkg/resolver/resolver_test.go`

- [ ] **Step 1: Branch**
  `git checkout main && git pull --ff-only upstream main && git checkout -b fix/warn-on-reflection-per-load`

- [ ] **Step 2: Write the failing test**
  In `pkg/resolver/resolver_test.go`, add `TestRequireScopesWarnOnReflectionToTheLoadedFile`. In a temp dir write `lib/setter.lg` containing `(ns lib.setter)` and `(set! *warn-on-reflection* true)`, and `lib/later.lg` containing `(ns lib.later)` and `(defn f [s] (.length s))`. Install a resolver over the dir, capture warnings into a buffer, reset the dedupe set, then require `lib.setter` followed by `lib.later` (mirror how the existing require tests drive the loader). Assert the buffer contains no `reflection warning` line, and assert `*warn-on-reflection*` derefs to false afterwards. Add three more cases in the same test:
  - a file that both sets the flag and contains `(defn g [s] (.length s))` produces exactly one warning naming that file, so the fix does not disable the feature;
  - with the flag bound true around the require (push a root binding as the compiler test does), a plain file still warns: the per-load binding inherits the current value rather than resetting it;
  - a file that sets the flag and then fails to compile (an unbalanced form after the `set!`) leaves the flag false afterwards: the pop runs on the error path too.
  Add a sibling `TestRequireScopesUncheckedMathToTheLoadedFile` with the setter/later shape for `*unchecked-math*`, asserting the var is false after the loads.

- [ ] **Step 3: Run the test to verify it fails**
  Run: `go test ./pkg/resolver -run TestRequireScopesWarnOnReflectionToTheLoadedFile -count=1`
  Expected: FAIL, with a `reflection warning` line pointing at `later.lg`.

- [ ] **Step 4: Implement**
  In `WithFile`, after binding `*file*`, look up `*warn-on-reflection*` and `*unchecked-math*` in the core namespace the same way `*file*` is found. For each var present, push a binding whose value is the var's current value as seen from the root context (the same read `reflectionWarningsEnabled` performs), and defer the pop. Keep the nil checks so an embedder that has not installed those vars is unaffected. Update the doc comment: `WithFile` now establishes the per-load compile-time bindings Clojure's `load` establishes, not only `*file*`.

- [ ] **Step 5: Run the test to verify it passes**
  Run: `go test ./pkg/resolver -run TestRequireScopesWarnOnReflectionToTheLoadedFile -count=1`
  Expected: PASS.

- [ ] **Step 6: Run the suites and lint**
  Run: `make test && go test -short ./... -skip TestClojureTestSuite && make lint`
  Expected: all green. `make test` includes the `.lg` runner and the gogen diff gate; if the gate reports a change, that is unexpected for this task, stop and investigate.

- [ ] **Step 7: End-to-end check against the real consumer**
  Build with `make build`, then from `~/Projects/lgx/examples/web-app`, with Go on PATH:
  ```
  PORT=18080 DB_PATH=/tmp/t.db LGX_LETGO_REPLACE=$HOME/Projects/let-go timeout 120 ~/Projects/lgx/bin/lgx run > /tmp/webapp.out 2>&1
  grep -q '^Listening' /tmp/webapp.out && echo started
  grep 'reflection warning' /tmp/webapp.out | grep -v honeysql | wc -l
  ```
  Expected: `started` (the run must reach the server, otherwise a count of `0` means nothing) and `0`. The HoneySQL lines remain until Task 2. The first run with a replace builds a runtime, so allow the timeout to be generous.

- [ ] **Step 8: Commit and open the PR**
  `git commit -am "rt: bind *warn-on-reflection* and *unchecked-math* per file load, as Clojure's load does"`
  `git push -u origin fix/warn-on-reflection-per-load`
  `gh pr create -R nooga/let-go --fill` with a body that states the Clojure semantics, the leak, the two-file reproduction, and that `*unchecked-math*` is included for the same reason.

### Task 2: Treat hinted and constructor-bound locals as statically known host targets

**Files:**
- Modify: `pkg/compiler/compiler.go`
- Test: `pkg/compiler/reflection_warning_test.go`

- [ ] **Step 1: Branch**
  `git checkout main && git checkout -b feat/reflection-warning-known-locals`
  Independent of Task 1's branch; do not stack them.

- [ ] **Step 2: Write the failing tests**
  In `reflection_warning_test.go`, add `TestReflectionWarningHonoursHintedAndConstructorBoundLocals`, using the same binding and capture setup as the existing dynamic-binding test. Compile these snippets and assert on the count and source line of warnings:
  - `(fn [^String s] (.length s))` — 0 warnings.
  - `(fn [s] (.length s))` — 1 warning (control).
  - `(fn [] (let [sb (StringBuilder.)] (.append sb "x")))` — 0 warnings.
  - `(fn [] (let [^Object o (identity 1)] (.toString o)))` — 0 warnings.
  - `(fn [^String s] (let [s (identity s)] (.length s)))` — 1 warning, on the inner call: rebinding without a hint masks the outer hint.
  - `(fn [^String s] (fn [] (.length s)))` — 0 warnings: the hinted parameter is found through the parent context.
  - `(fn [^String s] (fn [s] (.length s)))` — 1 warning: the inner unhinted parameter shadows the outer hinted one.
  - `(fn [^String s] (.. s toString (toUpperCase)))` — 0 warnings from the inner `(. s toString)`; whether the outer call warns is out of scope, so assert only that no warning points at the `s` target's column. If the test harness cannot separate them by column, drop this case rather than weaken the others.

- [ ] **Step 3: Run the tests to verify they fail**
  Run: `go test ./pkg/compiler -run TestReflectionWarningHonoursHintedAndConstructorBoundLocals -count=1`
  Expected: FAIL on the hinted and constructor cases.

- [ ] **Step 4: Implement**
  Add two fields to `Context`: `knownArgs map[vm.Symbol]bool`, initialised in `enterFn` beside `formalArgs`, and `knownLocals []map[vm.Symbol]bool`, pushed and popped in `pushLocals` and `popLocals` (around lines 1187 and 1192) beside `locals` and `localSlotCounts`, and initialised wherever `locals` is (the constructor and `enterFn` around line 410). In `enterFn` (around line 420) the loop that strips a `with-meta` wrapper from a parameter currently discards it; record `knownArgs[s] = true` when the wrapper's map has a `:tag` key, at the point where `formalArgs[s]` is set so `&` and rest handling stay untouched. At the let/loop binding site (around line 1696) do the same into the innermost `knownLocals` map right after `addLocal`, marking the name known when the wrapper carried `:tag` or when the init form satisfies the static-target check. Convert `hostTargetStaticallyKnown` into a `Context` method: the non-symbol logic is unchanged; for a symbol, walk contexts from `c` through `parent` as described in Design (locals innermost-first, then `formalArgs`, stop at the first context that declares the symbol) and return that declaration's flag, false if no context declares it. Update the single call site. Keep the comment near the strip explaining that the tag is still not attached to the local; only the warning consults it.

- [ ] **Step 5: Run the tests to verify they pass**
  Run: `go test ./pkg/compiler -run 'TestReflectionWarning' -count=1`
  Expected: PASS, including the three pre-existing reflection-warning tests.

- [ ] **Step 6: Run the suites and lint**
  Run: `make test && go test -short ./... -skip TestClojureTestSuite && make lint`
  Expected: all green.

- [ ] **Step 7: End-to-end check**
  `make build`, then the same bounded, captured run as Task 1 Step 7, counting all `reflection warning` lines: `grep -c 'reflection warning' /tmp/webapp.out` after confirming `started`.
  Expected: `0` with Task 1 also applied locally (merge both branches into a scratch branch for this check), or exactly the 14 non-HoneySQL lines without it. Note the count in the PR.

- [ ] **Step 8: Commit and open the PR**
  `git commit -am "compiler: hinted and constructor-bound locals are statically known host targets for the reflection warning"`
  `git push -u origin feat/reflection-warning-known-locals`
  `gh pr create -R nooga/let-go --fill`. The body must say: this changes the warning only, dispatch is unchanged; the motivation is HoneySQL, which is reflection-clean on the JVM and warned at 33 sites; and the alternative if this is declined is a `:lg` guard on HoneySQL's `set!` lines.

### Task 3: After merge

- [ ] **Step 1: Note the release**
  When upstream tags a release containing Task 1 (and Task 2 if accepted), record the version in the lgx sibling plan's blocked step and in `~/Projects/lgx/docs/issues/` per that plan. Nothing to do in this repo.
