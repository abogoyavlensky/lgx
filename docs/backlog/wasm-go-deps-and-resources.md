# `:target :wasm` cannot carry project Go deps or resources

**Status: open**

## Problem

GitHub issue #61 asks `lgx build` to produce a browser WASM app that keeps
the project's Go deps, packages its resources, and fits the rest of the
build lifecycle. The first phase
(`docs/plans/2026-10-01-1303-wasm-build-target.md`) ships only a thin
`:target :wasm`: `lgx build` runs `lg -w` for projects without Go deps and
warns that resources are not embedded. The rest needs let-go changes.

Checked on lg 1.13.0 and let-go main `4e769212` (2026-10-01).

## Go deps

`buildWasm` (let-go `pkg/cli/wasm.go`) writes a throwaway Go module in a
temp dir. Its `go.mod` requires only let-go, and its generated `main.go`
(`pkg/rt/wasm/rendermain.go`) imports only let-go runtime packages. lgx's
generated module, with the project's `:go/*` requires and lginterop
bindings, has no way in. The host would compile the program, but the app
would fail in the browser on the missing Go namespace, so lgx rejects Go
deps for `:target :wasm`.

Few Go deps compile for `js/wasm` anyway: anything with cgo (sqlite,
duckdb) is out. So the real need may be narrow.

Upstream draft: [`docs/issues/letgo-wasm-extra-go-imports.md`](../issues/letgo-wasm-extra-go-imports.md).

## Resources

The WASM builder embeds `program.lgb` and nothing else. `-b` collects
`-resource-paths` into an archive and installs an embedded resource provider
at startup; `-w` does neither, so `io/resource` finds nothing in the
browser.

Upstream draft: [`docs/issues/letgo-wasm-embed-resources.md`](../issues/letgo-wasm-embed-resources.md).

## Also deferred

- Application lowering for WASM. The generated main runs bytecode; the
  optional `gogen_ir` wireup covers let-go's own core packages only. Ties to
  [`native-build-target.md`](native-build-target.md).
- Cache keys for the WASM output. lgx does not cache it; `lg -w` rebuilds
  every time (about 23 s).
- A browser smoke test in CI (startup, a let-go dep, host eval).
- A `wasip1` target. WASI is a separate runtime contract.
- One artifact kind per `lgx.edn`. `:target` sits on the single `:bin` rule
  and a context cannot override `:targets`, so a project cannot declare both
  an executable and a web build.
