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

### Task 0: Preflight — land on the right branch ✅

The let-go checkout is normally left on `go-deps-combined`, a throwaway integration branch. Committing there would put this work somewhere that must never become a PR.

- [x] **Step 1: Check out the PR branch**
  Run: `cd ../let-go && git checkout fix/vm-boxing-symmetry && git status --short`
  Expected: the branch is `fix/vm-boxing-symmetry` and the tree is clean.

- [x] **Step 2: Confirm the baseline builds**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS. Establishes that later failures are yours.

---

### Task 1: Boxing — a Go map arrives as a let-go map of native values ✅

**Files:**
- Modify: `../let-go/pkg/vm/value.go`
- Test: `../let-go/pkg/vm/box_value_map_test.go`

- [x] **Step 1: Write the failing test**
  Create `box_value_map_test.go`. Assert `BoxValue` on a `map[string]any{"name": "Ada", "age": 36, "ok": true, "none": nil}` yields a let-go map whose values are `String`, `Int`, `Boolean` and `NIL` — compared with `Equals`, not by type name, since that is what caught the slice bug. Add a nil map (expect `NIL`), an empty map (expect an empty let-go map, not `NIL`), a `map[string]any` holding a nested `map[string]any`, and a `map[string]any` holding a `[]any`.

- [x] **Step 2: Run the test to verify it fails**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestBoxValueMap -v`
  Expected: FAIL — values come back as `*vm.Boxed` rather than native values.

- [x] **Step 3: Implement**
  In `BoxValue`'s `reflect.Map` branch, apply the same dynamic-type unwrapping the slice branch uses: for an interface-kind key or value that is not nil, unwrap with `Elem()` when `dynamicBoxSafe` allows it, and fall back to boxing wrapped if the unwrapped box errors. The nil-interface test is load-bearing for the same reason it is in the slice branch — `Elem()` on a nil interface yields an invalid `reflect.Value`, which `BoxValue` reports as an error rather than `NIL`.
  Extend `dynamicBoxSafe` with a `reflect.Map` case admitting exactly `map[string]any`:
  ```go
  case reflect.Map:
      return t.Key().Kind() == reflect.String && t.Key().PkgPath() == "" &&
          t.Elem().Kind() == reflect.Interface && t.Elem().NumMethod() == 0
  ```
  Keep the allowlist rationale in the docstring intact and extend it to say why maps are admitted.

- [x] **Step 4: Run the test to verify it passes**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestBoxValueMap -v`
  Expected: PASS

- [x] **Step 5: Run the full vm suite for regressions**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS

- [x] **Step 6: Commit**
  `git commit -m "fix(vm): box map keys and values by their dynamic type"`

---

> Deviation: the plan pinned assertions on `Equals`, but `Equals` is not a method on the `vm.Value` interface and `vm.ValueEquals` is only wired up by `pkg/rt` at init, so it is nil in a `pkg/vm` test. Assertions instead compare values directly with `!=` plus an explicit `*vm.Boxed` rejection — the same idiom the sibling `box_value_slice_test.go` uses, and stricter than `Equals` since it also pins the dynamic type.
>
> Deviation: rather than duplicating #778's unwrap-with-fallback logic in the map branch, it was extracted into one `boxByDynamicType` helper in `value.go` that both the slice and map branches call. Same logic, same comments, one implementation for a reviewer to check.

### Task 2: Unboxing — a let-go map converts into a Go map ✅

**Files:**
- Modify: `../let-go/pkg/vm/struct_mapping.go`, `../let-go/pkg/vm/native_func.go`
- Test: `../let-go/pkg/vm/unbox_map_test.go`

- [x] **Step 1: Write the failing test**
  Create `unbox_map_test.go`. Drive the real path, as `unbox_any_slice_test.go` does: box a Go func taking `map[string]any` with `vm.MustBox`, then `Invoke` it with a let-go map. Cover keyword keys, string keys, a `nil` value, an empty map, and a `map[string]string` target. A map nested inside a `[]any` belongs to Task 3, not here: it reaches Go through an `any` element, which does not convert until then. Add a case asserting a numeric key into a `map[string]any` **errors** rather than producing a rune-converted key.

- [x] **Step 2: Run the test to verify it fails**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMap -v`
  Expected: FAIL with `reflect: Call using *vm.PersistentMap as type map[string]interface {}`

- [x] **Step 3: Implement `unboxMapInto`**
  Add to `struct_mapping.go`, mirroring `unboxSliceInto`. Signature, which Task 3 also depends on:
  ```go
  func unboxMapInto(target reflect.Value, val Value) error
  ```
  Identify the source with an explicit type switch on `Map`, `*PersistentMap` and `*SortedMap` — not by inspecting the first element, because every map type yields `EmptyList` when empty and would be indistinguishable from an empty vector. Allocate with `reflect.MakeMap`, then for each `MapEntry` from `Seq()` allocate fresh key and value targets with `reflect.New(...).Elem()` and recurse through `unboxInto`. Reject a numeric key into a string-kind key target before delegating, since `unboxInto`'s fallback would rune-convert it.

- [x] **Step 4: Wire both call sites**
  Add a `reflect.Map` case to `unboxInto` that delegates to `unboxMapInto`, so a map nested in a struct field or slice element converts. Add a `reflect.Map` target branch to `boxArgForReflect` in `native_func.go`, mirroring its slice branch: attempt `unboxMapInto` into a fresh target and use the result when it succeeds, falling through to the existing behaviour when it does not.

- [x] **Step 5: Run the test to verify it passes**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMap -v`
  Expected: PASS

- [x] **Step 6: Run the full vm suite for regressions**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS

- [x] **Step 7: Commit**
  `git commit -m "fix(vm): convert a let-go map into a Go map parameter"`

---

> Deviation: the numeric-key rejection is implemented as `unboxesToInteger` — it rejects a key whose `Unbox()` yields an integer kind — rather than as an allowlist of `String`/`Keyword`. Same outcome for the case the plan names, but it does not also reject a `Symbol` key, which unboxes to a plain string and converts correctly.
>
> Deviation: `unboxInto`'s new `reflect.Map` case is guarded by the same type switch `unboxMapInto` uses, mirroring how the `reflect.Slice` case is guarded by `Sequable`. A non-map value (a `*Boxed` already holding a Go map) therefore still reaches the assignability fallback rather than erroring.
>
> Deviation: a rejected map conversion leaves `boxArgForReflect` on its existing `Unbox()` fallback, so `reflect.Call` reports `reflect: Call using *vm.PersistentMap as type map[string]interface {}`. The numeric-key test asserts the callee never ran rather than matching an error string, since the rejection surfaces as that existing failure mode.
>
> Codex review round 1 raised two P1s. The unhashable-key one was real and fixed in a follow-up commit (`9640bb0`): a `map[any]any` target accepts any dynamic key type, and a let-go vector key unboxes to a `[]vm.Value`, which `SetMapIndex` panics on — `unboxMapInto` now rejects a non-comparable key as a conversion failure. The other, "propagate the conversion failure instead of falling back", was **not** taken: `boxArgForReflect` returns a `reflect.Value` with no error channel, the plan specifies the fall-through explicitly, and it mirrors the pre-existing slice branch. The resulting `reflect.Call` panic is contained by `RecoverPanic` in `NativeFn.Invoke` and by the VM's own recover, so it surfaces as an error rather than a crash — the message is just less precise than the conversion error would be. Round 2 then found that `reflect.Type.Comparable` is not enough — a `struct{ X any }` holding a slice reports comparable and still panics when hashed — so the guard became a value-level one (`cfb6da2`): the insert is attempted behind a localized recover. Round 3 was clean.

### Task 3: Nesting — collections inside `any` convert rather than leak ✅

Kept as its own commit so it can be dropped without losing Tasks 1 and 2 if the behaviour is contested in review.

**Files:**
- Modify: `../let-go/pkg/vm/struct_mapping.go`
- Test: `../let-go/pkg/vm/unbox_map_test.go`

- [x] **Step 1: Write the failing test**
  Add cases asserting that `{:a {:b 1}}` into a `map[string]any` parameter gives `map[string]any{"a": map[string]any{"b": int64(1)}}`, not a `*vm.PersistentMap` value; and that `[1 [2 3]]` into `[]any` gives a nested `[]any`, not `[]vm.Value`. Assert the concrete Go types, since the failure mode is a value that looks right when printed.

- [x] **Step 2: Run the test to verify it fails**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMapNested -v`
  Expected: FAIL — the nested value is a let-go type.

- [x] **Step 3: Implement**
  In `unboxInto`'s `reflect.Interface` case (added by #778), before falling back to `val.Unbox()`, convert a let-go collection into its natural Go shape: a map into `map[string]any` via `unboxMapInto`, a sequential collection into `[]any` via `unboxSliceInto`. Only for the empty interface — the existing `NumMethod() == 0` guard already scopes this. Fall back to the current `Unbox()` behaviour whenever the conversion fails, so nothing that works today regresses. Preserve the explicit zeroing for a nil `Unbox()`, which exists because `unboxInto` is shared with `RecordToStruct` and writes into existing struct fields.
  Note the ordering constraint: a map must be tested before the sequential case, because every map is also `Sequable`.

- [x] **Step 4: Run the test to verify it passes**
  Run: `cd ../let-go && go test ./pkg/vm/ -run TestUnboxMap -v`
  Expected: PASS

- [x] **Step 5: Run the full vm suite for regressions**
  Run: `cd ../let-go && go test ./pkg/vm/`
  Expected: PASS

- [x] **Step 6: Commit**
  `git commit -m "fix(vm): convert nested collections reaching an any target"`

---

> Deviation: the plan says a nested `{:b 1}` arrives as `int64(1)`. It arrives as `int(1)` — `vm.Int.Unbox()` returns `int`, which is existing behaviour the sibling slice test already pins. The tests assert `int`.
>
> Deviation (important): the sequential case is **not** keyed on `Sequable`, as the plan's wording implies. `Sequable` is far too broad — `String` implements it (a string would become a vector of characters) and so does `*Nil`, whose `Seq()` returns `NIL` itself and whose `First()` is `NIL`, giving unbounded recursion and a stack overflow. The first attempt did exactly that. The rule is instead keyed on what `Unbox()` already produces: convert when it yields a `[]Value` or a `Seq`, which is precisely the set of values that leak let-go types into Go today. Everything else takes the pre-existing path untouched.
>
> Codex then found that admitting a `Seq` reintroduced a hang: a `LazySeq` over an infinite range unboxes to a `Seq` today *without* being realized, and converting it would iterate forever. The rule was narrowed to `[]Value` only (`3df1046`), which is finite by construction because it is already materialized. A nested lazy seq therefore still reaches Go as a `Seq` — the status quo, and the honest trade. Codex round 2 then caught that the regression test was vacuous (`InfiniteRange.Unbox()` returns nil, so it never reached the branch); it now uses a `LazySeq` and was verified by reverting the fix and watching it fail (`9fc4df9`).

### Task 4: Regenerate artifacts and run the full gates ✅

`pkg/vm/*.go` files are registered bundle generators, so editing them stales the manifest. `make test` runs neither the manifest gate nor lint.

**Files:**
- Modify: `../let-go/pkg/rt/generated.manifest`, `../let-go/pkg/rt/generated.sums`, `../let-go/pkg/rt/core_compiled.lgb`

- [x] **Step 1: Regenerate**
  Run: `cd ../let-go && make generate SMOKE-BOOT-BUDGET-MS=40`
  Use `make generate`, never `go generate ./...` — the latter does not refresh the manifest's output-readiness records and CI fails with `dependency manifest stale`.

- [x] **Step 2: Full test suite**
  Run: `cd ../let-go && make test SMOKE-BOOT-BUDGET-MS=40`
  Expected: PASS

- [x] **Step 3: Generated-artifacts gate**
  Run: `cd ../let-go && go run ./cmd/check-generated`
  Expected: `check-generated: OK`

- [x] **Step 4: Lint**
  Run: `cd ../let-go && make lint GO=$(command -v go)`
  Expected: no findings. `GO=` is required: `$(GO)` is only set when the Makefile installs its own toolchain, and without it lint shells out to coreutils `install` and fails.

- [x] **Step 5: Commit**
  `git commit -m "chore: refresh generated artifacts"`

---

> Deviation: lint caught a gofmt violation in `struct_mapping.go`, and fixing it changed a generator input, which re-staled the manifest. The step order in practice is generate → test → check-generated → lint → **fix, regenerate, re-lint** → commit. Worth folding a `gofmt -l` check in before the first `make generate` next time.

### Task 5: End-to-end verification against the Wails wrapper ✅

Proves the fix removes real hand-written workarounds, the way #778 was proved against sqlite. The shim is **not** changed here.

**The PR branch alone cannot do this.** `fix/vm-boxing-symmetry` does not contain [#773](https://github.com/nooga/let-go/pull/773), so it has no `pkg/cli`, and lgx cannot build a custom runtime without it. Verification runs on a refreshed combined branch; nothing here is committed to the PR.

- [x] **Step 1: Refresh the combined branch**
  Run: `cd ../let-go && git checkout go-deps-combined && git merge --no-edit fix/vm-boxing-symmetry`
  Resolve any `pkg/rt/generated.*` conflict by taking either side and re-running `make generate SMOKE-BOOT-BUDGET-MS=40`; never hand-edit those files. See [`../go-deps-pr-verification.md`](../go-deps-pr-verification.md).

- [x] **Step 2: Build the runtime and lgx**
  Run: `cd ../let-go && make build SMOKE-BOOT-BUDGET-MS=40 && cd ../lgx && make build LG=../let-go/bin/lg`

- [x] **Step 3: Confirm the boundary directly**
  With `LGX_HOME=/tmp/lgx-mapbox LGX_LETGO_REPLACE=<abs path to let-go>`, run a scratch script through the wails example's basis that hands a let-go map to a shim function declaring `map[string]any`, and one that receives a Go `map[string]any` back.
  Expected: the parameter arrives as a native Go map; the returned map is usable from let-go with `(get m "name")`. Note **string**-key lookup, not `(:name m)` — a Go `map[string]any` boxes with string keys by design, so keyword lookup correctly does not match.

- [x] **Step 4: Confirm the example still works**
  Run the `examples/wails-desktop` example and exercise `stats`.
  Expected: `{"count":3,"items":["a","b","c"],"runtime":"let-go","ui":"wails v3"}` — a JSON object, unchanged.

- [x] **Step 5: Record what the shim could drop**
  Note in the PR description which parts of `wails/shim/shim.go` (`ToGo`'s map branch, `asMap`, the `vm.Value` options parameters) the fix makes unnecessary. Leave the simplification itself to a separate change.

- [x] **Step 6: Return to the PR branch**
  Run: `cd ../let-go && git checkout fix/vm-boxing-symmetry`
  `go-deps-combined` stays local and unpushed. Tasks 6 and 7 commit to the PR branch.

---

**Result.** Both directions confirmed on the refreshed `go-deps-combined`, through a scratch `:go/local` shim declaring plain Go signatures:

```
describe: name=lgx-wails-desktop width=800 nested=map[string]interface {}{"deep":[]interface {}{1, 2}}
stats: {nested {ok true}, runtime let-go, count 3, items [a b c]}
type: let-go.lang.Map
get runtime: let-go      get count: 3      get items: [a b c]      nested ok: true
keyword lookup (expected nil): nil
```

The nested map arrives as a native `map[string]any` holding a native `[]any`, and the returned Go map is a real let-go map read with string keys — keyword lookup correctly misses. The example still works: `stats` returns `{"count":3,"items":["a","b","c"],"runtime":"let-go","ui":"wails v3"}`, unchanged.

> Deviation: step 3 used a scratch `:go/local` probe shim rather than the wails shim itself, because the wails shim declares `vm.Value` for every options parameter — it has no `map[string]any` signature to exercise yet, which is the whole point. The probe runs through the identical lgx custom-runtime path.
>
> Deviation: step 4 ran headless. This box has no GTK4/WebKitGTK, so the example ran in Wails' server mode (`CGO_ENABLED=0 GOFLAGS=-tags=server`) and the handler was driven over the runtime's HTTP transport, per `docs/knowledge-base/lgx-wails-desktop.md`. The native window itself was not exercised.
>
> Deviation (step 5, narrower than the plan assumed): `asMap` and the `vm.Value` options parameters on `New`/`NewWindow` can go — they become `map[string]any` directly. **`ToGo` cannot.** `Bridge.Call` lowers `fn.Invoke`'s return value and `Emit` lowers its `data`, and neither crosses a reflect boundary, so no automatic conversion applies; let-go still exports no deep let-go→Go converter (only `vm.ToLetGo`, the other direction). Making `ToGo` unnecessary is a separate gap, not one this change closes.

### Task 6: Documentation ✅

**Files:**
- Modify: `../let-go/docs/guide/go-interop.md`
- Modify: `docs/issues/interop-map-boxing.md`, `docs/issues/README.md`, `docs/knowledge-base/lgx-go-runtimes.md` (lgx)

- [x] **Step 1: Extend the let-go guide**
  Extend the collections section #778 added rather than starting a new one. State what a map converts to in each direction, that keyword keys become string keys and do not come back as keywords, and that nesting works.

- [x] **Step 2: Update the lgx issue doc**
  In `docs/issues/interop-map-boxing.md`, move the status from draft to implemented on `fix/vm-boxing-symmetry`, matching how `interop-slice-boxing.md` reads. Replace the "Open question" section with the decision taken and its rationale. Update the matching row in `docs/issues/README.md`.

- [x] **Step 3: Update the lgx knowledge base**
  In `docs/knowledge-base/lgx-go-runtimes.md`, the map gotcha currently tells wrapper authors to take `vm.Value` and convert by hand. Say instead that the fix landed and what a shim can now declare directly.

- [x] **Step 4: Verify lgx docs still lint**
  Run: `cd <lgx> && mise exec -- cljfmt check`
  Expected: `All source files formatted correctly`

- [x] **Step 5: Commit both repos**
  Separate commits: the guide in let-go, the notes in lgx.

---

> Deviation: the guide's section heading changed from "How `[]any` crosses the boundary" to "How collections cross the boundary", with maps and nesting as subsections. Extending the existing section, as the plan asked, but the old title no longer described its contents. No inbound links to that anchor exist in the repo.
>
> Deviation: the issue doc's "what the shim can drop" section says `ToGo` stays — see the Task 5 note. The plan assumed it would go.

### Task 7: Update the pull request ⚠️ partially blocked

- [ ] **Step 1: Retitle #778**
  `[]any` no longer describes the change. Use:
  `fix(vm): make collections cross the Go/let-go boundary as native values`

- [ ] **Step 2: Rewrite the description**
  Cover both shapes and nesting as one thesis: values cross the boundary as native values, recursively, in both directions. Name the two wrappers that found the gaps (`database/sql`, Wails v3), keep #778's rationale for why `dynamicBoxSafe` is an allowlist, and state the key-coercion decision explicitly so a reviewer does not have to infer it.

- [x] **Step 3: Push**
  Run: `cd ../let-go && git push origin fix/vm-boxing-symmetry`
  Never force-push: existing commits stay as they are, and the new work reads as commits on top.

**Steps 1 and 2 are blocked, step 3 is done.** The nine commits are pushed to `abogoyavlensky/let-go@fix/vm-boxing-symmetry` — appended, never force-pushed, `9538c75` still the parent of the new work.

Retitling and rewriting the description failed: the PR lives on `nooga/let-go`, and the available token cannot edit it —

```
GraphQL: Resource not accessible by personal access token (updatePullRequest)
```

The prepared text is below; it needs a hand with write access to #778.

**Title:**

```
fix(vm): make collections cross the Go/let-go boundary as native values
```

**Description:**

<details>
<summary>PR body (click to expand)</summary>

Resolves: #777

Values cross the Go/let-go boundary as **native values, recursively, in both directions** — slices and maps alike. Two shapes of the same bug, found the same way: by building real wrappers. `[]any` came from a `database/sql` wrapper (#777); maps came from a [Wails v3](https://v3.wails.io) wrapper, whose every options parameter had to declare `vm.Value` and convert by hand.

Maps land as commits on top rather than a second PR, because the nesting fix edits code this PR itself introduces — reviewing that once in final form beats reviewing a patch to it in a second diff.

## What changes

**Boxing (Go to let-go).** `BoxValue` walked slices and maps by their *static* element type. For a `[]any` or a `map[string]any` that kind is `Interface`, so every element missed the scalar fast paths and became an opaque `vm.Boxed` — printing as `<go.string Ada>` and comparing equal to nothing. Elements are now boxed by their **dynamic** type.

**Unboxing (let-go to Go).** Converting a let-go vector into a `[]any` gave up when an element had no Go counterpart and handed the whole slice over as `[]vm.Value`; a let-go map had no map conversion at all:

```
reflect: Call using []vm.Value as type []interface {}
reflect: Call using *vm.PersistentMap as type map[string]interface {}
```

Conversion into `any` is now total, and a new `unboxMapInto` converts a let-go map into any Go map, wired into both `unboxInto` and `boxArgForReflect`.

**Nesting.** A collection reaching an `any` target converts into its natural Go shape instead of arriving as a let-go value. Without this the fix only worked one level deep and a wrapper author would still have written the recursive converter.

## Review this part: unwrapping is an allowlist, not an opt-out

It routes elements into `BoxValue` paths the wrapped form never reached, and three are hostile. The worst is `ChanType.Box`, which spawns a goroutine calling `Recv`; on a send-only channel that panics in another goroutine and kills the process, uncatchable at the call site. The paths recurse, so only a positive list is safe: predeclared scalars, `[]byte`/`[]int64`/`[]float64`, `[]any`, and now exactly `map[string]any` — a string key and the empty interface, nothing else. Everything else boxes as before.

## The key-coercion decision, stated rather than inferred

**Keyword keys become string keys, and do not come back as keywords.** `{:a 1}` round-trips as `{"a" 1}`.

Going to Go this is not a new rule: `unboxInto`'s `reflect.String` case already accepts a `Keyword`, and a keyword stores its name without the leading colon. Coming back, a Go string key boxes to a let-go **string**. Auto-keywordising would be wrong — Go map keys may hold spaces and dots, which do not make valid keywords. Lossy but predictable, and it matches `clojure.data.json` with no `:key-fn`.

One rejection follows from it: a **numeric key into a string-keyed Go map errors** rather than converting. Go reports `int64` as `ConvertibleTo` `string` and converts it to a rune, so the generic fallback would silently turn the let-go key `65` into the Go key `"A"`. The rejection is local to the map path.

## Three details that carried the map work

- **Maps are identified by type, not by duck-typing.** Every let-go map returns `EmptyList` from `Seq()` when empty, so an empty map and an empty vector are indistinguishable by inspecting the first element for a `MapEntry`. The switch is on `vm.Map`, `*vm.PersistentMap`, `*vm.SortedMap`.

- **Maps are tested before sequences**, because every let-go map is also `Sequable` and the sequential branch would otherwise turn a map into a vector of entries.

- **The nesting rule is keyed on what `Unbox()` already produces — a `[]Value` — not on `Sequable`.** `Sequable` is far too broad: `String` implements it, and so does `NIL`, whose `Seq()` returns itself and whose `First()` is itself, giving unbounded recursion. Keying on the `Unbox` result also excludes a `Seq`, which may be infinite: a `LazySeq` over an infinite range is handed over unrealized, as before, rather than iterated until memory runs out.

A Go map key must also be hashable, and `reflect.Type.Comparable` cannot decide it — a `struct{ X any }` holding a slice reports comparable and still panics when hashed. The insert runs behind a localized recover, so an unhashable key is a conversion error rather than a panic; that matters because `unboxMapInto` is reachable from `RecordToStruct`, which has no recover of its own.

## Verified

Against two real wrappers, same shim, runtimes differing only in this change.

**`database/sql` / sqlite.** Without it, #777's reflect error. With it, rows read native, `nil` inserts SQL NULL, a NULL column reads back `nil`.

**Wails v3.** A let-go map reaches a `map[string]any` parameter as a native Go map, with a nested map arriving as `map[string]any` holding a native `[]any`; a returned Go map is a real let-go map read with `(get m "runtime")` — string keys, so keyword lookup correctly misses. The example app is unchanged: its `stats` handler still returns `{"count":3,"items":["a","b","c"],"runtime":"let-go","ui":"wails v3"}`.

The shim's hand-written `asMap` and its `vm.Value` options parameters are no longer needed. Its `ToGo` still is — `Bridge.Call` lowers a return value outside any reflect boundary, and let-go exports no deep let-go→Go converter. That is a separate gap. The simplification itself is left to a change in the wrapper.

The guide's `database/sql` sketches are corrected here, and its collections section now covers maps and nesting, since they describe this behavior.

</details>

---

## Plan complete

**Implemented.** A let-go map now crosses into Go as a native Go map, a Go map arrives in let-go as a real map, and either works nested inside another collection — so a wrapper author never has to hand-write the recursive converter. Nine commits on `fix/vm-boxing-symmetry`, on top of the untouched `[]any` work:

| commit | what |
|---|---|
| `46ee6a9` … `cfb6da2` | box map keys/values by dynamic type; convert a let-go map into a Go map parameter; reject an unhashable key by value rather than by type |
| `6041229` … `9fc4df9` | convert nested collections reaching an `any` target, without realizing a lazy seq |
| `4a3c276` | regenerated artifacts |
| `cc60203`, `f044968` | the guide's collections section |

**Gates:** `make test` green (the two `FAIL (= 1 2)` lines in the log are the test framework's own self-tests asserting a failing case), `check-generated: OK`, lint 0 issues. Verified end to end through lgx's custom-runtime path in both directions, and the `examples/wails-desktop` `stats` handler is unchanged.

### Issues encountered

Codex review caught four real defects across the tasks, all fixed:

1. An unhashable let-go key (a vector into `map[any]any`) panicked in `SetMapIndex` instead of failing the conversion.
2. The first fix for that checked `reflect.Type.Comparable`, which a `struct{ X any }` holding a slice passes and still panics on. The guard became value-level.
3. Admitting a `Seq` to the nesting conversion would have hung on an infinite `LazySeq`. Narrowed to an already-materialized `[]Value`.
4. The regression test for (3) was vacuous — `InfiniteRange.Unbox()` returns nil, so it never reached the branch. Rewritten with a `LazySeq` and verified by reverting the fix and watching it fail.
5. The guide overstated nested map conversion: only exactly `map[string]any` unwraps out of an `any` slot, so a nested `map[string]string` stays opaque. Both the guide and the lgx knowledge base were corrected.

One thing the plan did not anticipate at all: keying the nesting rule on `Sequable`, which its wording implies, stack-overflows immediately — `NIL` is `Sequable` and its `Seq()`/`First()` are both itself.

### What the plan could have specified better

**The `Sequable` trap.** The plan wrote "a sequential collection into `[]any` via `unboxSliceInto`" and named only the map-before-sequence ordering constraint. The real hazard is that `Sequable` is not a collection predicate at all: `String` and `NIL` both implement it, and `NIL` self-recurses. A plan that had checked what actually implements `Sequable` would have specified the discriminator instead of leaving it to be discovered by stack overflow.

Two smaller ones. It pinned `int64(1)` for a nested value where `vm.Int.Unbox()` yields `int` — a detail its own sibling test already establishes. And it assumed the Wails shim's `ToGo` would become unnecessary; only `asMap` and the options parameters do, because `Bridge.Call` lowers a return value outside any reflect boundary and let-go exports no deep let-go→Go converter.

