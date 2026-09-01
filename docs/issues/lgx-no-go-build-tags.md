# Issue: lgx cannot pass Go build tags to the runtime build

**Repo:** this one (lgx)

**Status:** draft. Worked around with the `GOFLAGS` environment variable.

## Summary

`lgx.edn` has no way to say `-tags production`. The generated runtime is
always built with the toolchain's default tag set, so any Go dependency
whose behaviour is selected by build tags is out of reach except through
the environment.

Real cases, both from the Wails wrapper:

- **`-tags production`** is what Wails wants for a release build; without
  it the binary carries dev-mode asset serving and logging.
- **`-tags server`** builds Wails' cgo-free HTTP mode, which is the only
  way to exercise a Wails app on a machine (or CI runner) with no GTK.
  This is how `examples/wails-desktop` was verified at all.

## The workaround

`GOFLAGS` is inherited by the `go build` subprocess, so this works:

```sh
GOFLAGS=-tags=server lgx run
```

It is undiscoverable, it is not recorded in the project, and it applies
to `go get` and `go mod tidy` as well as the build.

## What a fix looks like

A `:go/build-tags` key beside `:lg-version`, folded into the runtime hash
so two tag sets do not share one cached binary:

```clojure
{:lg-version "1.11.1"
 :go/build-tags ["production"]
 :deps {...}}
```

`runtime-hash` in `lgx/gobuild.lg` already canonicalises the coord set and
the target platform; tags belong in the same key, since a binary built
with different tags is a different binary.

## Note: lginterop's `-build-tags` is a different thing

`cmd/lginterop` has a `-build-tags` flag, and it does not help here. It
only emits a `//go:build` constraint line into the *generated file*; the
scan itself selects files by `GOOS`/`GOARCH`/`CGO_ENABLED` read from the
environment at process start, and honours no tags. So a package whose API
is tag-selected cannot be scanned correctly at all — a separate gap, worth
filing upstream if anyone needs it. The Wails wrapper sidesteps it by
generating no bindings.
