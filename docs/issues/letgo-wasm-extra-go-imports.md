# `lg -w` cannot link a host's extra Go packages into the WASM app

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

Found while adding `:target :wasm` to `lgx build` (lgx #61), on let-go main
`4e769212` and lg 1.13.0.

## Summary

`buildWasm` (`pkg/cli/wasm.go`) builds the app in a fresh temp module:

- `go.mod` comes from `gomod.Generate` / `gomod.GenerateWithReplace` and
  requires only let-go (step 4 in `buildWasm`).
- `main.go` comes from `wasm.RenderMain` (`pkg/rt/wasm/rendermain.go`) and
  imports only `compiler`, `resolver`, `rt` and `vm`.

So a custom `lg` built with extra Go packages (lgx's `:lg-runtime :built`
with `:go/*` deps, or any host that blank-imports registered packages) can
*compile* a program that uses them, but the WASM artifact never links
them. The page then fails at load on the missing namespace.

## Concrete impact

lgx generates a Go module per project with the declared Go requires,
replaces and lginterop bindings. For `:target :wasm` it has to reject every
Go dep, because nothing it builds can reach the WASM module.

## Proposal

Held loosely; any of these would do:

1. **Extra requires and imports.** Flags (or an env/file) naming module
   requires, replaces and blank imports to add to the generated module.
2. **Build in an existing module.** `-w-module <dir>`: render `main.go`
   and `program.lgb` into the given module instead of a temp one, and
   build there with `GOOS=js GOARCH=wasm`.

Option 2 is the same question lgx #60 put to `lg compile` (let-go PR #977),
whose scaffolded module also requires only let-go. One mechanism could
serve both the native and the WASM builds.
