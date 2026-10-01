# `lg -w` does not embed `-resource-paths`

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft

Found while adding `:target :wasm` to `lgx build` (lgx #61), on let-go main
`4e769212` and lg 1.13.0.

## Summary

`lg -b` embeds resources: it collects the `-resource-paths` roots with
`bundle.CollectResources`, appends an archive from
`rt.EncodeResourceArchive`, and at startup installs
`rt.NewEmbeddedResourceProvider` (`pkg/cli/cli.go`).

`lg -w` does neither. `buildWasm` (`pkg/cli/wasm.go`) embeds only
`program.lgb`, and the generated main (`pkg/rt/wasm/rendermain.go`) never
calls `rt.SetResourceProvider`. `-resource-paths` still works while the
program compiles, so a top-level `io/resource` read succeeds at build time
and returns nil in the browser.

## Concrete impact

`lgx build` with `:target :wasm` can only warn that resources are not
embedded.

## Proposal

Mirror `-b`: collect the resource roots into an archive, embed it beside
`program.lgb` (`//go:embed resources.bin`), and install an
`EmbeddedResourceProvider` in the generated main before the program runs.
