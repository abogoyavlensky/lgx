# let-go Boxing Symmetry Implementation Plan

> **STATUS: COMPLETE** — merged into `integration/go-interop`. See the summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make values cross the Go/let-go boundary as native let-go values in both directions, so a wrapped Go function returning `[]any` yields ordinary strings and ints rather than opaque boxes, and a let-go vector containing `nil` converts to `[]any` instead of failing.

**Tech Stack:** Go, `pkg/vm` (let-go's boxing layer). Work happens in the let-go repo (`/Users/andrew/Projects/let-go`), not lgx.

---

## Design

### The two gaps

Both live in `pkg/vm/value.go` and are mirror images of each other. Both were found by building the first real wrapper library over `database/sql`; neither is exercised by anything currently in the let-go tree, which is why they survived.

**Boxing (Go → let-go).** `BoxValue`'s slice branch switches on `v.Type().Elem().Kind()` — the slice's *static* element type. For a `[]any` that kind is `Interface`, so every element misses the string/int/float fast paths, falls through to the default, and becomes a `vm.Boxed`. In let-go those print as `<go.string Ada>` and compare equal to nothing:

```clojure
(= "Ada" (first (sql/ScanRow rows)))   ; => false, today
```

The fix is to look at the element's *dynamic* type: for an interface-kind element, box `v.Index(i).Elem()`, which reflect resolves to the concrete value inside.

One trap. `Elem()` on a *nil* interface returns the zero `reflect.Value`, and `BoxValue` returns an **error** for an invalid value (`value.go:170`), not `NIL`. The nil-interface guard at `value.go:177` only fires on the interface itself, before unwrapping. So the element must be tested with `IsNil()` first, or passed through unwrapped so that guard catches it — unwrapping unconditionally turns every NULL column into a boxing error.

**Unboxing (let-go → Go).** Converting a let-go vector to a Go `[]any` parameter gives up when an element has no Go counterpart and hands the whole slice over as `[]vm.Value`, which then fails the reflect call:

```
reflect: Call using []vm.Value as type []interface {}
```

A let-go `nil` is the common trigger, which makes every SQL NULL parameter fail. `[]any` can hold anything, including Go `nil`, so the conversion should always succeed for it.

### Why this is worth fixing upstream rather than working around

A wrapper library *can* work around both — the sqlite wrapper currently does, by returning `[]vm.Value` from its shim and unboxing parameters by hand. But that pushes boxing knowledge into every wrapper anyone writes, for a case that is not exotic: `[]any` is the natural Go return type for "a row of unknown column types", and `nil` is the natural let-go value for SQL NULL.

It also means the worked example in let-go's own `docs/guide/go-interop.md` does not work as written, which is the first thing a wrapper author copies.

### Scope boundary

Fix the interface-element case in both directions. Do **not** attempt to make Go methods first-class values in let-go — that is the other gap the guide's `(apply sql/Query db q params)` sketch assumes, it is a much larger change to the compiler and boxing layer, and the shim pattern (take a slice, spread it in Go) is a reasonable answer. This plan corrects the guide instead.

### Compatibility

This is a behavior change in a core boxing path, so it deserves care even though the blast radius looks small. Values affected are exactly those that today arrive as unusable `vm.Boxed` wrappers — code that depends on the current behavior would have to be reaching into a box it could not do anything useful with. The guard is the existing suite: `make test` plus `make clojure-compat-report` (6311 assertions).

### Delivery

One focused PR against `nooga/let-go`, matching the small-reviewable-PR convention used for the aero work, plus a `docs/issues/` entry in the lgx repo recording the finding. The guide fixes ride along in the same PR since they describe the same behavior.

**Branch hygiene matters here.** The working checkout at `/Users/andrew/Projects/let-go` sits on `integration/go-interop`, which carries unmerged interop commits. A PR opened from that branch would drag them along, defeating the point. So the change is developed on a branch cut from `upstream/main`, while verification (Task 3) needs the integration branch's `pkg/cli` — two different states of the tree at once. Use a second worktree rather than switching branches back and forth.

## File Structure

let-go repo (`/Users/andrew/Projects/let-go`):

- Modify: `pkg/vm/value.go` — `BoxValue`'s slice branch gains an interface-element case.
- Modify: `pkg/vm/struct_mapping.go` — `unboxSliceInto` (`:350`) is the sequence-to-Go-slice conversion; confirm against its caller in `pkg/vm/native_func.go` which path a `[]any` parameter actually takes before editing.
- Modify: `pkg/vm/value_test.go` (or the nearest existing boxing test file — check `pkg/vm/*_test.go` first) — round-trip tests for both directions.
- Modify: `docs/guide/go-interop.md` — correct the `ScanRow` and `(apply sql/Query ...)` sketches.

lgx repo (`/Users/andrew/Projects/lgx`):

- Create: `docs/issues/interop-slice-boxing.md` — the upstream issue record, following the format of the existing entries and registered in `docs/issues/README.md`.
- Modify: `docs/issues/README.md` — add the row.

---

### Task 1: Boxing — `[]any` elements reach let-go as native values

**Files:**
- Modify: `pkg/vm/value.go`
- Test: `pkg/vm/value_test.go` (confirm the actual file name first)

- [x] **Step 1: Write failing tests**
  Locate the existing boxing tests under `pkg/vm/*_test.go` and follow their style. Cover `BoxValue` on a `[]any` holding, in one slice: a `string`, an `int64`, a `float64`, a `bool`, a `nil`, and a `[]byte`. Assert each element arrives as the corresponding let-go type (`vm.String`, `vm.Int`, `vm.Float`, `vm.Boolean`, `vm.NIL`) rather than `vm.Boxed`. Add a case for a nested `[]any` inside a `[]any`. Keep the existing `[]byte`/`[]int64`/`[]float64` fast-path tests passing untouched — those specialize on concrete element types and must not change.

- [x] **Step 2: Run tests to verify they fail**
  Run: `go test ./pkg/vm/ -run TestBox -v` in `/Users/andrew/Projects/let-go`.
  Expected: FAIL, with the new cases reporting `vm.Boxed` where a native type was expected.

- [x] **Step 3: Implement**
  In `BoxValue`'s `case reflect.Slice, reflect.Array:` branch (`pkg/vm/value.go:227`), the generic per-element loop calls `BoxValue(v.Index(i))`. An element of a `[]any` has kind `Interface`, so unwrap it before boxing — but only when it is non-nil:

  ```go
  e := v.Index(i)
  if e.Kind() == reflect.Interface && !e.IsNil() {
      e = e.Elem()
  }
  mv, err := BoxValue(e)
  ```

  The `IsNil` test is load-bearing, not defensive. `Elem()` on a nil interface yields the zero `reflect.Value`, and `BoxValue` returns an error for an invalid value (`value.go:170`) rather than `NIL`. Leaving a nil element wrapped lets the existing guard at `value.go:177` return `NIL` correctly. Without this, every SQL NULL becomes a boxing error — the exact case this plan exists to fix.

- [x] **Step 4: Run tests to verify pass**
  Run: `go test ./pkg/vm/`
  Expected: PASS.

- [x] **Step 5: Full regression**
  Run: `make test` then `make clojure-compat-report` in `/Users/andrew/Projects/let-go`.
  Expected: both green; the compat report's assertion count unchanged from its pre-change value (record that number before starting).

- [x] **Step 6: Commit**
  `git add pkg/vm && git commit -m "fix(vm): box interface-typed slice elements by their dynamic type"`

### Task 2: Unboxing — a let-go vector containing nil converts to `[]any`

**Files:**
- Modify: `pkg/vm/value.go`
- Test: same test file as Task 1

- [x] **Step 1: Write failing tests**
  First locate the code path: find where a let-go sequence is converted into a Go slice argument for a reflect call. `unboxSliceInto` in `pkg/vm/struct_mapping.go:350` is one such path — determine whether the `[]any` parameter case goes through it or through a separate branch in the reflect proxy, and test the one that actually runs. Cover: a vector of mixed strings/ints converting to `[]any`; a vector containing `nil` converting to `[]any` with a Go `nil` in that position; an empty vector converting to an empty `[]any`, not nil.

- [x] **Step 2: Verify fail**
  Run: `go test ./pkg/vm/`
  Expected: FAIL on the nil case, reporting a conversion error or a `[]vm.Value`.

- [x] **Step 3: Implement**
  Make conversion to a slice whose element type is `any` (`interface{}`) total: every let-go value has an `Unbox() any`, and `nil`/`NIL` maps to Go `nil`. The key point is that `[]any` should never fall back to `[]vm.Value` — the fallback exists for element types that genuinely cannot hold arbitrary values, and `any` always can.

- [x] **Step 4: Verify pass**
  Run: `go test ./pkg/vm/` then `make test`
  Expected: PASS.

- [x] **Step 5: Commit**
  `git add pkg/vm && git commit -m "fix(vm): convert let-go sequences to []any totally, nil included"`

### Task 3: End-to-end check against the real wrapper

**Files:** none changed — this is verification.

Prereqs: `go` on PATH, and the sqlite wrapper at `/Users/andrew/Projects/letgo-packages/sqlite`. If absent, stop and report rather than skipping silently.

- [x] **Step 1: Rebuild the wrapper's runtime against this branch**
  In `/Users/andrew/Projects/letgo-packages/sqlite/example`, run:
  `LGX_LETGO_REPLACE=/Users/andrew/Projects/let-go lgx run`
  Expected: the example's rows print as before.

- [x] **Step 2: Prove the shim's workarounds are now unnecessary**
  Temporarily change `sqlite/shim/shim.go` so `ScanRow` returns `[]any` (the shape let-go's guide documents) instead of `[]vm.Value`, and so `Query`/`Exec` take `[]any` instead of `[]vm.Value`. Re-run the example, including a statement with a `nil` parameter and a NULL result column.
  Expected: identical output — native values, `nil` for NULL. This is the whole point of the change; if it does not hold, the fix is incomplete.
  Then revert the shim and confirm `git -C /Users/andrew/Projects/letgo-packages status` is clean — this task proves a capability and must leave no trace. Plan 2 decides the shim's final shape.

- [x] **Step 3: Record the finding**
  Note in the issue file (Task 4) whether the `[]any` form now works end to end.

### Task 4: Docs and the upstream issue record

**Files:**
- Modify: `/Users/andrew/Projects/let-go/docs/guide/go-interop.md`
- Create: `/Users/andrew/Projects/lgx/docs/issues/interop-slice-boxing.md`
- Modify: `/Users/andrew/Projects/lgx/docs/issues/README.md`

- [x] **Step 1: Fix the guide's two broken sketches** (use /writing-clearly)
  In `docs/guide/go-interop.md`:
  - The `ScanRow` example returning `([]any, error)` is correct once Task 1 lands — verify against Task 3 and leave it, adding a note that element conversion happens by dynamic type.
  - The veneer sketch uses `(apply sql/Query db q params)`. This never worked: `Query` is a *method* on `*sql.DB`, methods are not first-class values in let-go, and there is no way to spread a parameter vector into one. Replace it with the shim pattern — a Go function taking the parameters as a slice and spreading them — and say plainly why, so the next wrapper author does not rediscover it.
  - Add a short subsection on the boxing/unboxing rules for `[]any` in both directions.

- [x] **Step 2: Write the issue record**
  Create `docs/issues/interop-slice-boxing.md` in the lgx repo following the shape of the existing entries (see `aero-compat.md` for a good example): summary, what was found, how it was found (building the sqlite wrapper), the fix, and verification. Add its row to `docs/issues/README.md`.

- [x] **Step 3: Commit both repos**
  `git -C /Users/andrew/Projects/let-go commit -am "docs(guide): correct the database/sql wrapper sketches"`
  `git -C /Users/andrew/Projects/lgx add docs/issues && git -C /Users/andrew/Projects/lgx commit -m "docs(issues): record the interop slice-boxing gap"`

### Task 0: Set up a clean branch

**Files:** none — repository setup.

- [x] **Step 1: Cut a branch from upstream main**
  Fetch upstream and create the working branch from `upstream/main`, not from `integration/go-interop`. Confirm with `git log --oneline upstream/main..HEAD` that it is empty before any work starts.

- [x] **Step 2: Provide the integration tree for verification**
  Task 3 builds a runtime needing `pkg/cli`, which exists only on `integration/go-interop`. Add a second worktree pinned to that branch (`git worktree add <path> integration/go-interop`) and point `LGX_LETGO_REPLACE` at *that* path for the end-to-end check, while the PR branch stays clean.
  Note the consequence: Task 3 verifies the fix against the integration branch, so the fix must be applied in both trees, or the worktree rebased onto the PR branch, for the check to mean anything. Decide which and record it.

### Task 5: Open the upstream PR

- [x] **Step 1: Confirm the branch is clean and green**
  Re-check `git log --oneline upstream/main..HEAD` contains only this plan's commits and nothing from the interop work.
  Run `make test` and `make clojure-compat-report` one final time.
  Expected: both green.

- [x] **Step 2: Push and open the PR**
  Push the branch to the fork and open a PR against `nooga/let-go`. The description should lead with the user-visible symptom (`<go.string Ada>` comparing equal to nothing), name the two code paths, and point at the guide fix as evidence the current behavior contradicts documented intent. Keep it to one reviewable change — do not bundle unrelated work.

---

## Completion summary

Both gaps are fixed and merged into `integration/go-interop`, so the lgx go-deps
work has the feature. **No PR was opened** - consistent with the branches-only
call made for the interop work; `fix/vm-boxing-symmetry` is ready to become one.

| Branch | Head | Contents |
|---|---|---|
| `fix/vm-boxing-symmetry` | `885acb0` | 7 commits, cut from `upstream/main`, nothing from the interop work |
| `integration/go-interop` | `4e6c024` | the above merged in |

The lgx repo carries one separate commit, `f4a6491`, for the issue record.

### What was implemented

Boxing now looks at an interface element's dynamic type, and conversion into
`any` is total, so `nil` becomes Go `nil` instead of failing the call. The
guide's `database/sql` sketches were corrected to match.

### The verification that mattered

The sqlite wrapper's shim was temporarily rewritten to the plain `[]any` shapes
the guide documents, and run against two runtimes differing only in this fix:

| runtime | result |
|---|---|
| integration without the fix (`3e4cddc`) | `reflect: Call using []vm.Value as type []interface {}` |
| integration with the fix | rows native, `(= "Ada" (:name r))` true, `nil` param inserts SQL NULL, NULL column reads back `nil` |

That control run is what makes the claim "this change is what fixes it" rather
than "it works now". `letgo-packages` was reverted afterwards and is clean.

`make test` and the 6311-assertion compat report were green after every commit,
the count never moving off 6311.

### Deviations

- **No second worktree.** The plan wanted one because Task 3 needs `pkg/cli`,
  which lives only on the integration branch, and flagged that the fix would
  then have to exist in two trees. Merging into `integration/go-interop` first
  (which the user wanted anyway) and verifying there removes the problem: the
  thing verified is exactly the artifact lgx consumes. A throwaway worktree was
  still used, but for the pre-fix *control*, which the plan did not ask for.
- **`lgx` on PATH is 0.1.0** and its validator predates `:go/*` deps, so Task 3
  needs `/Users/andrew/Projects/lgx/bin/lgx` (0.1.2).
- **Three extra commits** beyond the plan's two, all from codex review: the
  regression guard, the allowlist rewrite, and clearing stale interface targets.
- **Fixed a second `(apply ...)` sketch** the plan did not name, at the guide's
  headline "the core of the wrapper is nearly free" claim. Same defect, more
  prominent than the one the plan pointed at.
- **New prose uses hyphens, not em-dashes**, per the `/writing-clearly` skill the
  plan invokes. The surrounding upstream text uses em-dashes, so there is a
  typographic seam; worth reconsidering before this goes upstream.

### What codex caught that the plan's design would have shipped

The plan's Step 3 snippet is correct as far as it goes, and it was implemented
verbatim. It is also incomplete, in a way worth recording:

1. Unwrapping routes elements into `BoxValue` paths the wrapped form never
   reached. Three of those are hostile: the slice/array case calls `IsNil`
   (invalid for arrays), the `[]byte`/`[]int64`/`[]float64` fast paths assert
   the exact slice type, and `ChanType.Box` spawns a goroutine calling `Recv`,
   which on a **send-only channel panics in another goroutine and kills the
   process**. That last one cannot be contained by any local recover, which is
   why the guard had to become an allowlist rather than an opt-out list.
2. The unsafe paths are reachable recursively, so a top-level type check is
   structurally insufficient - `[][1]int` panics on its element.
3. `unboxInto` is shared. Skipping the write for a nil `raw` is correct for
   `unboxSliceInto`, which allocates a fresh element, but `RecordToStruct`
   writes into an existing struct field and would keep stale data.

All three were inputs that boxed fine before the change, so each was a genuine
regression introduced mid-task and caught before landing.

### What the plan could have specified better

1. **It stated the fix as a code snippet rather than as a property.** The
   snippet is right for the target case and silent about everything else, so
   "what happens to `[]any` elements the boxing layer cannot handle natively"
   never got asked. Three of the four review findings live in that gap. A plan
   changing a core conversion path should state the invariant - here, "no input
   that boxes today may box worse" - and let the implementation derive the
   guard.
2. **It assumed `pkg/vm/value_test.go` exists.** It does not; the plan hedged
   ("check first"), which worked, but the File Structure section still lists a
   file that has never existed.
3. **Task 0 is printed last.** It is repository setup that must run first.
4. **It did not mention that `lgx` on PATH is too old** to parse the wrapper's
   own `lgx.edn`, which stops Task 3 at the first command with a validation
   error that looks like a problem with the wrapper rather than with the tool.
