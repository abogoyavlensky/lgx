# `:target :wasm` cannot carry resources (Go deps done)

**Status: open**

## Problem

GitHub issue #61 asks `lgx build` to produce a browser WASM app that keeps
the project's Go deps, packages its resources, and fits the rest of the
build lifecycle. The first phase
(`docs/plans/2026-10-01-1303-wasm-build-target.md`) ships only a thin
`:target :wasm`: `lgx build` runs `lg -w` for projects without Go deps and
warns that resources are not embedded. The rest needs let-go changes.

Checked on lg 1.13.0 and let-go main `4e769212` (2026-10-01).

## Go deps (done)

Done in `docs/plans/2026-10-15-1550-wasm-go-deps.md`. let-go `main` gained
`lg -w -w-module <dir> -import <pkg>` (#1016, #1037, after 1.13.0), and
`:target :wasm` now links Go deps under `:lg-runtime :built` through a
js/wasm runtime's module, staged in a temp dir. It needs a let-go pin that
has `-w-module`; a dep must compile for `js/wasm` without cgo.

Upstream: nooga/let-go#998 ([`docs/issues/letgo-wasm-extra-go-imports.md`](../issues/letgo-wasm-extra-go-imports.md)).

## Resources

The WASM builder embeds `program.lgb` and nothing else. `-b` collects
`-resource-paths` into an archive and installs an embedded resource provider
at startup; `-w` does neither, so `io/resource` finds nothing in the
browser.

Upstream: nooga/let-go#999 ([`docs/issues/letgo-wasm-embed-resources.md`](../issues/letgo-wasm-embed-resources.md)).

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
