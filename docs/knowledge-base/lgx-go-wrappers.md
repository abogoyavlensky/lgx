# Wrapping a Go library for let-go

`:go/*` support is merged. This note is the workflow: which let-go you need,
where wrapper packages live, which of two shapes to build, and how to verify
one. For the machinery underneath - coord kinds, the runtime cache, the build
steps - see [`lgx-go-runtimes.md`](./lgx-go-runtimes.md).

## Which let-go you need

**Not a release, yet.** The `:go/*` stack needs `pkg/cli` and the boxing work
([#773], [#776], [#778]); the newest release, `v1.12.2` from July, predates all
of it. Pin a commit instead - `:lg-version` is passed to `go get`, so a full
sha or a branch name works exactly like a semver:

```clojure
{:lg-version "f26eb497299760e93ce430302f13ab3a954eab64"}   ; reproducible
{:lg-version "main"}                                        ; tracks tip
```

A sha is the better default: a mutable pin costs one network call per
invocation to resolve, and the cache key names whatever it pointed at.

Verified: the sqlite example builds and passes end to end from a sha pin with
**no let-go checkout and no `LGX_LETGO_REPLACE`**. Reach for
`LGX_LETGO_REPLACE` only when developing against uncommitted let-go changes.

Switch to a semver pin once a release carries the merged work.

[#773]: https://github.com/nooga/let-go/pull/773
[#776]: https://github.com/nooga/let-go/pull/776
[#778]: https://github.com/nooga/let-go/pull/778

## Where wrappers live

[`letgo-packages`](https://github.com/abogoyavlensky/letgo-packages) - one repo,
one directory per package, each tagged independently. A consumer depends on one
with `:deps/root`:

```clojure
{:deps {abogoyavlensky/letgo-sqlite
        {:git/url "https://github.com/abogoyavlensky/letgo-packages"
         :git/sha "..."
         :deps/root "sqlite"}}}
```

Package layout, which every package follows:

```
<pkg>/
├── README.md      what it is, the API, known limits
├── lgx.edn        :paths ["src"] + the :go/* coords
├── shim/          hand-written Go, when generation cannot reach the API
├── src/<ns>/      the let-go veneer
└── example/       a runnable app that exercises the whole stack
```

`example/` uses `{:local/root ".."}` so it tests the working tree. Consumers
outside the repo use a git coord plus `:deps/root`.

## Two shapes, and how to choose

The single most important decision, made before writing anything.

**Shape A - generated bindings plus a thin shim.** Fits a flat,
function-oriented API. `lginterop` generates a namespace from the package, and
the shim covers only what generation cannot express.

`sqlite`/`sql` is the worked case. `database/sql` generates cleanly; the shim
(`sql/shim/shim.go`, ~70 lines) exists for three specific reasons, each
documented in its header: `Scan` writes through caller-allocated pointers,
methods are not first-class so a variadic one cannot be `apply`-ed, and
`*sql.DB`/`*sql.Tx` share no declared interface.

**Shape B - a shim and nothing generated.** Fits a framework: anything
configured by struct literals, parameterised by generics, or driven by
callbacks the caller supplies.

`wails` is the worked case, and it declares no `:go/interop` at all. Two
properties put the API out of reach: lgx always passes `-opaque-structs`, so no
struct constructors are emitted and let-go cannot build an
`application.Options`; and `lginterop` skips generic exports **silently**, so
`application.NewService[T]` - the whole backend - would vanish with no
diagnostic. See [`lgx-wails-desktop.md`](./lgx-wails-desktop.md).

**Callbacks only cross the boundary one way.** A Go func *returned* by a
package boxes into a let-go fn (`pkg/vm/value.go:200`, `reflect.Func` ->
`NativeFnType.Box`), but nothing converts a let-go fn into a Go func: let-go's
`pkg/` calls `reflect.MakeFunc` nowhere. So a generated binding for a parameter
of func type is emitted and then uncallable - there is nothing to hand it. This
is the most common of the three triggers in Go, where "pass me a closure" is
the idiomatic API for transactions, iteration and comparators. buntdb is the
clean illustration: every operation lives inside `db.Update(func(tx *Tx) error)`
and `tx.Ascend(index, func(k, v string) bool)`, so generation buys nothing.

A shim can do what generation cannot: hold the let-go fn and `Invoke` it from
Go. `pkg/rt/http.go:48,102` is the pattern - a struct field of type `vm.Fn`,
called with `h.fn.Invoke([]vm.Value{req})` from inside a Go callback.

**Pick by asking how the library is configured and driven.** Function calls
with scalar arguments generate well. Struct literals, generics and func-typed
parameters do not, and no amount of work on the interop side changes that - go
straight to a `:go/local` shim.

## Building one

1. **Check it is worth wrapping.** [`../GO-ECOSYSTEM.md`](../GO-ECOSYSTEM.md)
   has the filter: wrap Go where Clojure's answer is JVM-bound. Do not wrap
   what let-go or a pure Clojure library already covers.
2. **Scaffold** `<pkg>/` in `letgo-packages` on the layout above.
3. **Try Shape A first** unless the API is obviously framework-shaped. A
   `:go/interop` coord costs one line; if the generated namespace comes out
   missing most of the API, that is your answer.
4. **Write the shim** for what is left. Give a `:go/local` module a dotted
   module path (`example.com/...`) or lgx rejects it as standard-library.
5. **Write the veneer** in `src/`, giving the API idiomatic let-go names.
6. **Write `example/`** as a runnable app that asserts, not just prints. Both
   existing examples fail loudly on a bad assertion.

## Verifying

Run these; each exercises a layer the next depends on.

```bash
cd <pkg>/example && lgx run          # the whole stack, cold
cd <pkg> && lgx test                 # the package's own suite, if it has one
cd <pkg>/example && lgx build && ./bin/app   # the AOT/bundling path
```

`lgx build` is worth running even when you do not ship a binary: it is the only
check on the AOT path, where **top-level forms execute at compile time**. Guard
entry points with `(when-not *compiling-aot* (-main))`, and put anything with
an effect inside the fn - guarding only the last call still runs the
construction above it.

Then confirm you have not regressed the consumers:

```bash
cd letgo-packages/sqlite/example && lgx run    # and sql: lgx test
cd lgx && bash tests/run.sh                    # 314 e2e assertions
```

## If wrapping turns up a let-go gap

It will - both existing wrappers did, and both produced upstream PRs. Build
let-go from a checkout, point lgx at it with `LGX_LETGO_REPLACE=/abs/path`, and
note these, none of which are obvious:

- **`make generate`, never `go generate ./...`.** The latter rebuilds the
  bundle but leaves the manifest's output-readiness records stale, and a local
  `check-generated` can still pass because of a gitignored tree. CI then fails
  with `dependency manifest stale`. Most of `pkg/vm/`, `pkg/compiler/` and
  `pkg/bytecode/` are registered bundle generators, so a one-line Go edit there
  needs it just like a `.lg` edit.
- **`make test` runs neither the manifest gate nor lint.** The full sequence is
  `make generate` → `make test` → `go run ./cmd/check-generated` →
  `make lint GO=$(command -v go)`. The `GO=` is required: without it lint
  shells out to coreutils `install` and fails.
- **`make build` promotes only after an 8ms boot-budget smoke test**, calibrated
  on an idle M3. On a loaded machine it fails *after* producing a good binary.
  Raise it rather than skipping: `make build SMOKE-BOOT-BUDGET-MS=40`.
- **Committed generated artifacts conflict on every merge.**
  `make install-hooks` registers merge drivers for `core_compiled.lgb` and
  `generated.sums`; `generated.manifest` has none and is the one that conflicts
  locally. GitHub runs no custom drivers at all, so it reports a conflict the
  drivers hide from you - which is why every refresh must be an author-side
  merge plus `make generate` plus a push, and why "Update branch" cannot help.
- **The runtime cache does not notice a rebuilt let-go.** `runtime-hash` folds
  in the replace *path*, not the checkout contents. After changing let-go,
  `rm -rf "$LGX_HOME/runtimes"`, or use a throwaway `LGX_HOME`.

## Known limits

- **No cross-compilation for a cgo dep.** `lgx build --target` forces
  `CGO_ENABLED=0`. Pure-Go deps cross-build fine; the wails stack does not.
- **Mobile targets are not supported** and fail confusingly - see
  [`../issues/lgx-mobile-targets-buildmode.md`](../issues/lgx-mobile-targets-buildmode.md).
- **No `:go/build-tags`.** Use the `GOFLAGS` environment variable
  ([`../issues/lgx-no-go-build-tags.md`](../issues/lgx-no-go-build-tags.md)).
- **Nothing in `letgo-packages` is tagged yet.** Both original blockers are
  cleared - lgx reads a package's `lgx.edn` from `:deps/root`, and the boxing
  fix is merged - so tagging waits only on a let-go release to pin
  `shim/go.mod` against.

---

> **Verify against (in this repo):**
> [`lgx-go-runtimes.md`](./lgx-go-runtimes.md),
> [`lgx-wails-desktop.md`](./lgx-wails-desktop.md),
> [`../GO-ECOSYSTEM.md`](../GO-ECOSYSTEM.md),
> [`examples/wails-desktop/`](../../examples/wails-desktop).
>
> **In [letgo-packages](https://github.com/abogoyavlensky/letgo-packages):**
> `sql/shim/shim.go` (Shape A), `wails/shim/shim.go` (Shape B),
> each package's `README.md` and `example/`.
>
> **In [let-go](https://github.com/nooga/let-go):** `pkg/vm/value.go`
> (`reflect.Func` boxing, Go -> let-go only), `pkg/rt/http.go` (the
> `vm.Fn` field a Go callback invokes), `cmd/lginterop/lginterop.lg`
> (`simple-type?`, `smartable?`, `generic?`).
