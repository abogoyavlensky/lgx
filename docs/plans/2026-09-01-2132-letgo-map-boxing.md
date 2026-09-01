# let-go Map Boxing Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a let-go map cross into Go as a native Go map and a Go map arrive in let-go as a real map, including when either is nested inside another collection, so a wrapper author never has to hand-write a recursive converter.

**Tech Stack:** Go, `pkg/vm` (let-go's boxing layer). Work happens in the **let-go** repo (`../let-go` relative to lgx), on the existing `fix/vm-boxing-symmetry` branch (PR [#778](https://github.com/nooga/let-go/pull/778)). This plan document lives in lgx, matching [`2026-08-23-1924-letgo-boxing-symmetry.md`](./2026-08-23-1924-letgo-boxing-symmetry.md).

---

## Design

### Context

[#778](https://github.com/nooga/let-go/pull/778) made `[]any` cross the boundary in both directions. Maps are the same bug with a different shape, found the same way: by building a real wrapper, this time over [Wails v3](https://v3.wails.io). The gap is catalogued in [`../issues/interop-map-boxing.md`](../issues/interop-map-boxing.md).

The work lands as **new commits on `fix/vm-boxing-symmetry`**, not a separate PR. #778 is unreviewed, so nothing is invalidated, and the nesting fix below edits code #778 itself introduces — reviewing that once in final form beats reviewing a patch to it in a second diff. Existing commits are never squashed or rewritten.

### The three gaps

**1. Unboxing a map (let-go → Go).** The reported failure:

```
reflect: Call using *vm.PersistentMap as type map[string]interface {}
```

`boxArgForReflect` (`pkg/vm/native_func.go:95`) special-cases slice/array targets and interface targets. A **map target falls through** to `reflect.ValueOf(v.Unbox())`, and `(*PersistentMap).Unbox()` returns the map itself. `unboxInto` (`pkg/vm/struct_mapping.go:285`) has no `reflect.Map` case either, so a map nested in a struct field or slice element fails the same way.

**2. Boxing a map (Go → let-go).** `BoxValue` already has a `reflect.Map` branch (`pkg/vm/value.go:282`) that builds a `*PersistentMap`. It boxes each key and value with plain `BoxValue`, which reproduces #778's static-type bug: for a `map[string]any`, `iter.Value()` has Kind `Interface`, misses every scalar fast path, hits the default branch and becomes an opaque `Boxed`. The fix is to apply the existing `dynamicBoxSafe` unwrapping, exactly as the slice branch does.

**3. Nesting, in both directions.** #778's `reflect.Interface` case in `unboxInto` uses `val.Unbox()`. `ArrayVector.Unbox()` returns `[]Value` and `(*PersistentMap).Unbox()` returns itself, so a collection nested inside an `any` target reaches Go as a let-go value:

```clojure
{:a {:b 1}}   ; → map[string]any{"a": *vm.PersistentMap{...}}   ← today
{:a {:b 1}}   ; → map[string]any{"a": map[string]any{"b": 1}}   ← wanted
```

That is the same opaque-value problem the issue is about, one level down, and it would leave wrapper authors writing the recursive converter anyway. `dynamicBoxSafe` needs the mirroring addition so a nested `map[string]any` unwraps on the way back.

### Key decisions

**Map key coercion is not a new rule.** `unboxInto`'s `reflect.String` case already accepts `Keyword` and calls `SetString(string(v))` (`struct_mapping.go:311`); a `Keyword` stores its name without the leading colon. So `{:a 1}` → `map[string]any{"a": 1}` falls out of recursing keys through `unboxInto`, following an existing convention rather than inventing one.

Going the other way, Go string keys box to let-go **strings**, not keywords, so `{:a 1}` round-trips as `{"a" 1}`. Lossy but predictable, and it matches `clojure.data.json` with no `:key-fn`. Auto-keywordising is wrong: Go map keys may contain spaces and dots, which do not make valid keywords.

**Maps need an explicit type switch, not duck-typing.** Every let-go map returns `EmptyList` from `Seq()` when empty, so an empty map and an empty vector are indistinguishable by inspecting the first element for a `MapEntry`. Identify maps by type: `Map`, `*PersistentMap`, `*SortedMap`. `TransientMap` is out of scope, being a builder rather than a value handed to Go.

**Reject numeric keys into string-kind targets.** Go's `ConvertibleTo` reports `int64` → `string` as true and converts to a rune, so the existing fallback would silently turn a let-go key `65` into the Go key `"A"`. Reject instead, kept local to the map path so no shared conversion behaviour changes.

**`dynamicBoxSafe` stays an allowlist.** #778's docstring explains why at length: several `BoxValue` paths assume an exact predeclared type, and `ChanType.Box` panics in another goroutine, which no local recover can contain. Adding maps means adding exactly `map[string]any` — a map whose key type is `string` and whose element type is the empty interface — and nothing else.

### Testing strategy

Mirror #778's two test files, which drive the real paths rather than calling the conversion helpers directly:

- `box_value_map_test.go` — `BoxValue` on Go maps, asserting native let-go values come out.
- `unbox_map_test.go` — a boxed Go func invoked through `boxArgForReflect`, which is the path that actually failed.

Cover, at minimum: `map[string]any` with mixed scalar values; a nil map; an empty map (distinct from an empty vector); a nested map; a map nested inside a `[]any`; a `nil` map value; keyword keys; string keys; a numeric key rejected rather than rune-converted; and a `*SortedMap` and plain `Map` alongside `*PersistentMap`.

### Verification

Beyond `make test`, prove it end to end the way #778 was proved against sqlite: the Wails shim's hand-written `ToGo` should become unnecessary. Demonstrate that, but leave the shim's actual simplification to a separate change — what its final shape should be is its own decision.

## File Structure

In the **let-go** repo:

| File | Responsibility |
|---|---|
| `pkg/vm/value.go` | Modify: `dynamicBoxSafe` gains `map[string]any`; `BoxValue`'s `reflect.Map` branch unwraps dynamic types for keys and values |
| `pkg/vm/struct_mapping.go` | Modify: new `unboxMapInto`; `reflect.Map` case in `unboxInto`; `reflect.Interface` case recurses into collections |
| `pkg/vm/native_func.go` | Modify: `reflect.Map` target branch in `boxArgForReflect`, mirroring the slice branch |
| `pkg/vm/box_value_map_test.go` | Create: boxing direction |
| `pkg/vm/unbox_map_test.go` | Create: unboxing direction, through the reflect proxy |
| `docs/guide/go-interop.md` | Modify: extend the existing collections section to cover maps |

In **lgx**:

| File | Responsibility |
|---|---|
| `docs/issues/interop-map-boxing.md` | Modify: status draft → implemented |
| `docs/issues/README.md` | Modify: the matching table row |
| `docs/knowledge-base/lgx-go-runtimes.md` | Modify: the map gotcha now names the fix |

---

### Task 0: Preflight — land on the right branch

The let-go checkout is normally left on `go-deps-combined`, a throwaway integration branch. Committing there would put this work somewhere that must never become a PR.

- [ ] **Step 1: Check out the PR branch**
  Run: `cd ../let-go && git checkout fix/vm-boxing-symmetry && git status --short`
  Expected: the branch is `fix/vm-boxing-symmetry` and the tree is clean.

- [ ] **Step 2: Confirm the baseline builds**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS. Establishes that later failures are yours.

---

### Task 1: Boxing — a Go map arrives as a let-go map of native values

**Files:**
- Modify: `../let-go/pkg/vm/value.go`
- Test: `../let-go/pkg/vm/box_value_map_test.go`

- [ ] **Step 1: Write the failing test**
  Create `box_value_map_test.go`. Assert `BoxValue` on a `map[string]any{"name": "Ada", "age": 36, "ok": true, "none": nil}` yields a let-go map whose values are `String`, `Int`, `Boolean` and `NIL` — compared with `Equals`, not by type name, since that is what caught the slice bug. Add a nil map (expect `NIL`), an empty map (expect an empty let-go map, not `NIL`), a `map[string]any` holding a nested `map[string]any`, and a `map[string]any` holding a `[]any`.

- [ ] **Step 2: Run the test to verify it fails**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestBoxValueMap -v`
  Expected: FAIL — values come back as `*vm.Boxed` rather than native values.

- [ ] **Step 3: Implement**
  In `BoxValue`'s `reflect.Map` branch, apply the same dynamic-type unwrapping the slice branch uses: for an interface-kind key or value that is not nil, unwrap with `Elem()` when `dynamicBoxSafe` allows it, and fall back to boxing wrapped if the unwrapped box errors. The nil-interface test is load-bearing for the same reason it is in the slice branch — `Elem()` on a nil interface yields an invalid `reflect.Value`, which `BoxValue` reports as an error rather than `NIL`.
  Extend `dynamicBoxSafe` with a `reflect.Map` case admitting exactly `map[string]any`:
  ```go
  case reflect.Map:
      return t.Key().Kind() == reflect.String && t.Key().PkgPath() == "" &&
          t.Elem().Kind() == reflect.Interface && t.Elem().NumMethod() == 0
  ```
  Keep the allowlist rationale in the docstring intact and extend it to say why maps are admitted.

- [ ] **Step 4: Run the test to verify it passes**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestBoxValueMap -v`
  Expected: PASS

- [ ] **Step 5: Run the full vm suite for regressions**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS

- [ ] **Step 6: Commit**
  `git commit -m "fix(vm): box map keys and values by their dynamic type"`

---

### Task 2: Unboxing — a let-go map converts into a Go map

**Files:**
- Modify: `../let-go/pkg/vm/struct_mapping.go`, `../let-go/pkg/vm/native_func.go`
- Test: `../let-go/pkg/vm/unbox_map_test.go`

- [ ] **Step 1: Write the failing test**
  Create `unbox_map_test.go`. Drive the real path, as `unbox_any_slice_test.go` does: box a Go func taking `map[string]any` with `vm.MustBox`, then `Invoke` it with a let-go map. Cover keyword keys, string keys, a `nil` value, an empty map, and a `map[string]string` target. A map nested inside a `[]any` belongs to Task 3, not here: it reaches Go through an `any` element, which does not convert until then. Add a case asserting a numeric key into a `map[string]any` **errors** rather than producing a rune-converted key.

- [ ] **Step 2: Run the test to verify it fails**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMap -v`
  Expected: FAIL with `reflect: Call using *vm.PersistentMap as type map[string]interface {}`

- [ ] **Step 3: Implement `unboxMapInto`**
  Add to `struct_mapping.go`, mirroring `unboxSliceInto`. Signature, which Task 3 also depends on:
  ```go
  func unboxMapInto(target reflect.Value, val Value) error
  ```
  Identify the source with an explicit type switch on `Map`, `*PersistentMap` and `*SortedMap` — not by inspecting the first element, because every map type yields `EmptyList` when empty and would be indistinguishable from an empty vector. Allocate with `reflect.MakeMap`, then for each `MapEntry` from `Seq()` allocate fresh key and value targets with `reflect.New(...).Elem()` and recurse through `unboxInto`. Reject a numeric key into a string-kind key target before delegating, since `unboxInto`'s fallback would rune-convert it.

- [ ] **Step 4: Wire both call sites**
  Add a `reflect.Map` case to `unboxInto` that delegates to `unboxMapInto`, so a map nested in a struct field or slice element converts. Add a `reflect.Map` target branch to `boxArgForReflect` in `native_func.go`, mirroring its slice branch: attempt `unboxMapInto` into a fresh target and use the result when it succeeds, falling through to the existing behaviour when it does not.

- [ ] **Step 5: Run the test to verify it passes**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMap -v`
  Expected: PASS

- [ ] **Step 6: Run the full vm suite for regressions**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS

- [ ] **Step 7: Commit**
  `git commit -m "fix(vm): convert a let-go map into a Go map parameter"`

---

### Task 3: Nesting — collections inside `any` convert rather than leak

Kept as its own commit so it can be dropped without losing Tasks 1 and 2 if the behaviour is contested in review.

**Files:**
- Modify: `../let-go/pkg/vm/struct_mapping.go`
- Test: `../let-go/pkg/vm/unbox_map_test.go`

- [ ] **Step 1: Write the failing test**
  Add cases asserting that `{:a {:b 1}}` into a `map[string]any` parameter gives `map[string]any{"a": map[string]any{"b": int64(1)}}`, not a `*vm.PersistentMap` value; and that `[1 [2 3]]` into `[]any` gives a nested `[]any`, not `[]vm.Value`. Assert the concrete Go types, since the failure mode is a value that looks right when printed.

- [ ] **Step 2: Run the test to verify it fails**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMapNested -v`
  Expected: FAIL — the nested value is a let-go type.

- [ ] **Step 3: Implement**
  In `unboxInto`'s `reflect.Interface` case (added by #778), before falling back to `val.Unbox()`, convert a let-go collection into its natural Go shape: a map into `map[string]any` via `unboxMapInto`, a sequential collection into `[]any` via `unboxSliceInto`. Only for the empty interface — the existing `NumMethod() == 0` guard already scopes this. Fall back to the current `Unbox()` behaviour whenever the conversion fails, so nothing that works today regresses. Preserve the explicit zeroing for a nil `Unbox()`, which exists because `unboxInto` is shared with `RecordToStruct` and writes into existing struct fields.
  Note the ordering constraint: a map must be tested before the sequential case, because every map is also `Sequable`.

- [ ] **Step 4: Run the test to verify it passes**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMap -v`
  Expected: PASS

- [ ] **Step 5: Run the full vm suite for regressions**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS

- [ ] **Step 6: Commit**
  `git commit -m "fix(vm): convert nested collections reaching an any target"`

---

### Task 4: Regenerate artifacts and run the full gates

`pkg/vm/*.go` files are registered bundle generators, so editing them stales the manifest. `make test` runs neither the manifest gate nor lint.

**Files:**
- Modify: `../let-go/pkg/rt/generated.manifest`, `../let-go/pkg/rt/generated.sums`, `../let-go/pkg/rt/core_compiled.lgb`

- [ ] **Step 1: Regenerate**
  Run: `cd ../let-go && make generate SMOKE-BOOT-BUDGET-MS=40`
  Use `make generate`, never `go generate ./...` — the latter does not refresh the manifest's output-readiness records and CI fails with `dependency manifest stale`.

- [ ] **Step 2: Full test suite**
  Run: `cd ../let-go && make test SMOKE-BOOT-BUDGET-MS=40`
  Expected: PASS

- [ ] **Step 3: Generated-artifacts gate**
  Run: `cd ../let-go && go run ./cmd/check-generated`
  Expected: `check-generated: OK`

- [ ] **Step 4: Lint**
  Run: `cd ../let-go && make lint GO=$(command -v go)`
  Expected: no findings. `GO=` is required: `$(GO)` is only set when the Makefile installs its own toolchain, and without it lint shells out to coreutils `install` and fails.

- [ ] **Step 5: Commit**
  `git commit -m "chore: refresh generated artifacts"`

---

### Task 5: End-to-end verification against the Wails wrapper

Proves the fix removes real hand-written workarounds, the way #778 was proved against sqlite. The shim is **not** changed here.

**The PR branch alone cannot do this.** `fix/vm-boxing-symmetry` does not contain [#773](https://github.com/nooga/let-go/pull/773), so it has no `pkg/cli`, and lgx cannot build a custom runtime without it. Verification runs on a refreshed combined branch; nothing here is committed to the PR.

- [ ] **Step 1: Refresh the combined branch**
  Run: `cd ../let-go && git checkout go-deps-combined && git merge --no-edit fix/vm-boxing-symmetry`
  Resolve any `pkg/rt/generated.*` conflict by taking either side and re-running `make generate SMOKE-BOOT-BUDGET-MS=40`; never hand-edit those files. See [`../go-deps-pr-verification.md`](../go-deps-pr-verification.md).

- [ ] **Step 2: Build the runtime and lgx**
  Run: `cd ../let-go && make build SMOKE-BOOT-BUDGET-MS=40 && cd ../lgx && make build LG=../let-go/bin/lg`

- [ ] **Step 3: Confirm the boundary directly**
  With `LGX_HOME=/tmp/lgx-mapbox LGX_LETGO_REPLACE=<abs path to let-go>`, run a scratch script through the wails example's basis that hands a let-go map to a shim function declaring `map[string]any`, and one that receives a Go `map[string]any` back.
  Expected: the parameter arrives as a native Go map; the returned map is usable from let-go with `(get m "name")`. Note **string**-key lookup, not `(:name m)` — a Go `map[string]any` boxes with string keys by design, so keyword lookup correctly does not match.

- [ ] **Step 4: Confirm the example still works**
  Run the `examples/wails-desktop` example and exercise `stats`.
  Expected: `{"count":3,"items":["a","b","c"],"runtime":"let-go","ui":"wails v3"}` — a JSON object, unchanged.

- [ ] **Step 5: Record what the shim could drop**
  Note in the PR description which parts of `wails/shim/shim.go` (`ToGo`'s map branch, `asMap`, the `vm.Value` options parameters) the fix makes unnecessary. Leave the simplification itself to a separate change.

- [ ] **Step 6: Return to the PR branch**
  Run: `cd ../let-go && git checkout fix/vm-boxing-symmetry`
  `go-deps-combined` stays local and unpushed. Tasks 6 and 7 commit to the PR branch.

---

### Task 6: Documentation

**Files:**
- Modify: `../let-go/docs/guide/go-interop.md`
- Modify: `docs/issues/interop-map-boxing.md`, `docs/issues/README.md`, `docs/knowledge-base/lgx-go-runtimes.md` (lgx)

- [ ] **Step 1: Extend the let-go guide**
  Extend the collections section #778 added rather than starting a new one. State what a map converts to in each direction, that keyword keys become string keys and do not come back as keywords, and that nesting works.

- [ ] **Step 2: Update the lgx issue doc**
  In `docs/issues/interop-map-boxing.md`, move the status from draft to implemented on `fix/vm-boxing-symmetry`, matching how `interop-slice-boxing.md` reads. Replace the "Open question" section with the decision taken and its rationale. Update the matching row in `docs/issues/README.md`.

- [ ] **Step 3: Update the lgx knowledge base**
  In `docs/knowledge-base/lgx-go-runtimes.md`, the map gotcha currently tells wrapper authors to take `vm.Value` and convert by hand. Say instead that the fix landed and what a shim can now declare directly.

- [ ] **Step 4: Verify lgx docs still lint**
  Run: `cd <lgx> && mise exec -- cljfmt check`
  Expected: `All source files formatted correctly`

- [ ] **Step 5: Commit both repos**
  Separate commits: the guide in let-go, the notes in lgx.

---

### Task 7: Update the pull request

- [ ] **Step 1: Retitle #778**
  `[]any` no longer describes the change. Use:
  `fix(vm): make collections cross the Go/let-go boundary as native values`

- [ ] **Step 2: Rewrite the description**
  Cover both shapes and nesting as one thesis: values cross the boundary as native values, recursively, in both directions. Name the two wrappers that found the gaps (`database/sql`, Wails v3), keep #778's rationale for why `dynamicBoxSafe` is an allowlist, and state the key-coercion decision explicitly so a reviewer does not have to infer it.

- [ ] **Step 3: Push**
  Run: `cd ../let-go && git push origin fix/vm-boxing-symmetry`
  Never force-push: existing commits stay as they are, and the new work reads as commits on top.
