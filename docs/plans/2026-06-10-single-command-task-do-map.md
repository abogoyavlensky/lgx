# Single-Command Task :do Map Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow a custom task with one step to write `:do` as a single step map while keeping task execution on the existing vector shape.

**Tech Stack:** let-go (`.lg`), EDN config validation, bash e2e harness.

---

## Design

Use `lgx/config.lg` as the normalization boundary. A task's `:do` value may be either a vector of step maps or one step map. The map form is only syntax sugar for the one-step case.

`validate-task!` should validate both forms and return a normalized task map. For `:do {:sh "echo hi"}`, it validates that map with the same `validate-step!` path used for vector entries, at index `0`, then returns `{:do [{:sh "echo hi"}]}`. For the existing vector form, it preserves the current behavior: reject empty vectors, validate each step with its zero-based index, and keep the vector as the canonical runtime shape.

Because `validate-config!` currently returns the original config, the implementation must thread that normalized task value back into the config. `validate-tasks!` should return a normalized tasks map, and `validate-config!` should assoc it into `cfg` when `:tasks` is present. `config/tasks`, help lookup, and `tasks/run-task!` will then continue to see `:do` as a vector. `lgx/tasks.lg` should not grow dual-shape logic.

Error handling stays strict. Missing `:do` still fails. Empty vectors still fail. Strings, numbers, nil, and other non-map/non-vector values still fail, with the type message updated from "vector of steps" to "step map or vector of steps." Invalid single-step maps, such as `{}` or `{:sh "x" :run "y"}`, should reuse the existing step validation and error text at index `0`.

Docs should show the shorthand in the simple task example and keep the vector form for multi-step tasks. Architecture docs should mention that config validation normalizes single-step map form before execution walks `:do`.

## File Structure

- `lgx/config.lg` - modify task validation so `:do` accepts a single step map, normalizes it to a one-item vector, and returns normalized task config.
- `test/lgx/config_test.lg` - modify task validation tests for accepted and rejected single-step map form.
- `tests/e2e.sh` - modify with a new Scenario 93 proving a task declared with map-form `:do` runs through the bundled CLI.
- `README.md` - modify the Tasks section to document the shorthand.
- `docs/ARCHITECTURE.md` - modify the `lgx <task>` data-flow section to document normalization.

## Implementation Steps

### Task 1: Normalize map-form `:do` during config validation

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [ ] **Step 1: Write the focused unit tests**
  In `test/lgx/config_test.lg`, add tests near the existing `:tasks validation` block:
  - `validate-config-accepts-task-with-single-sh-step-map`: input `{:tasks {:fmt {:do {:sh "echo hi"}}}}`, expected result `{:tasks {:fmt {:do [{:sh "echo hi"}]}}}`.
  - `validate-config-accepts-task-with-single-run-step-map`: input `{:tasks {:check {:do {:run "scripts/test.lg"}}}}`, expected normalized `:do` vector.
  - `validate-config-rejects-single-step-map-with-no-action-key`: input `{:tasks {:fmt {:do {}}}}` throws.
  - `validate-config-rejects-single-step-map-with-multiple-action-keys`: input `{:tasks {:fmt {:do {:sh "echo a" :run "scripts/foo.lg"}}}}` throws.

- [ ] **Step 2: Run the focused unit tests and see the expected failure**
  Run: `bin/lgx test test/lgx/config_test.lg`
  Expected: the new acceptance tests fail because map-form `:do` is still rejected or returned unnormalized; existing tests keep their current behavior.

- [ ] **Step 3: Implement validation and normalization**
  In `lgx/config.lg`:
  - Add a private helper near `validate-step!`, for example `normalize-task-steps! [task-name steps]`.
  - For `steps` as a map, call `(validate-step! task-name 0 steps)` and return `[steps]`.
  - For `steps` as a vector, keep the current empty-vector check and per-step validation loop, then return `steps`.
  - For any other value, call `bad!` with a message that says `:do` must be a step map or vector of steps and still reports the received type.
  - Change `validate-task!` to return `(assoc task :do normalized-steps)` after validating `:doc`, `:extra-*`, and `:with`.
  - Change `validate-tasks!` to build and return a tasks map with each value returned from `validate-task!`.
  - Change `validate-config!` to assoc the normalized tasks map into `cfg` when `:tasks` is present.

- [ ] **Step 4: Run the focused unit tests again**
  Run: `bin/lgx test test/lgx/config_test.lg`
  Expected: all `config_test` assertions pass, including the new normalization checks.

### Task 2: Add bundled CLI coverage

**Files:**
- Modify: `tests/e2e.sh`

- [ ] **Step 1: Add Scenario 93**
  Append a scenario before the final `All $PASS_COUNT e2e assertions passed.` line:
  - Create a temp project with `lgx.edn` containing `{:tasks {:hello {:do {:sh "echo hi from map do"}}}}`.
  - Run `"$LGX" hello` with a temp `LGX_HOME`.
  - Assert stdout equals `hi from map do`.
  - Clean up temp dirs.

- [ ] **Step 2: Run the e2e suite against a rebuilt bundle**
  Run: `make build && bash tests/e2e.sh`
  Expected: Scenario 93 passes, and existing task scenarios still pass.

### Task 3: Document the shorthand

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update README task examples**
  In `README.md` `### Tasks (:tasks)`, show a simple one-step task using `:do {:sh "..."}`. Keep the multi-step `:ci` example as a vector. Add one short sentence after the example: when a task has one step, `:do` may be a single step map; multi-step tasks use a vector.

- [ ] **Step 2: Update architecture notes**
  In `docs/ARCHITECTURE.md` `### lgx <task>`, state that config validation accepts `:do` as either a single step map or a vector, then normalizes the single map to a one-item vector before execution walks it.

- [ ] **Step 3: Verify the docs mention both forms**
  Run: `rg -n ':do \\{|vector|single step map|one-item vector' README.md docs/ARCHITECTURE.md`
  Expected: README documents the user-facing shorthand, and ARCHITECTURE documents internal normalization.

### Task 4: Full verification

**Files:**
- Test: `tests/run.sh`

- [ ] **Step 1: Run the full test suite**
  Run: `bash tests/run.sh`
  Expected: bundle build succeeds, unit tests pass, and the full e2e suite passes.

- [ ] **Step 2: Review the diff**
  Run: `git diff --check && git diff --stat`
  Expected: no whitespace errors; the diff is limited to config validation, focused tests, e2e coverage, and docs.
