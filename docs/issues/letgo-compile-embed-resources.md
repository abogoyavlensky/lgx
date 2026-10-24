# `lg compile` does not embed `-resource-paths`

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1099](https://github.com/nooga/let-go/issues/1099)

Found while building Quel natively (`:target :native`), on let-go `main`
`18df3ad5` and lgx 0.5.1. Quel's frontend is a resource served through
`io/resource`.

## Summary

`lg -b` collects `-resource-paths` with `bundle.CollectResources` and
installs `rt.NewEmbeddedResourceProvider` at startup. `lg compile` embeds
only `program.lgb` and installs no provider, so `io/resource` returns nil in
a native binary. This is the `lg compile` counterpart of nooga/let-go#999
(`lg -w`).

## Concrete impact

A native Wails app shows Wails' "Page Not Found" instead of its frontend.

## lgx workaround

`lgx build` stages a `lgxresources` package into the module it passes to
`lg compile -module`. The package embeds copies of the collected resources
with `//go:embed all:files`, and its `init()` calls
`rt.SetResourceProvider(rt.NewEmbeddedResourceProvider(files))`. lgx passes
it with `-import lgx.local/runtime/lgxresources`. The native entry frame
never touches the provider, so the one installed in `init()` survives to run
time. When upstream gains a mechanism, lgx can switch to it.
