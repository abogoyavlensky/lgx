# Issue: mobile targets need a build mode lgx cannot produce

**Repo:** this one (lgx)

**Status:** draft. Two separable parts: a cheap diagnostic fix, and a
structural gap that probably should not be fixed in lgx at all.

## Summary

`lgx build --target ios/arm64` is **accepted by validation and then fails**
with a toolchain error. `ios/amd64`, `ios/arm64` and the four `android/*`
pairs are all in `go-platform-pairs` (`lgx/config.lg`), because that list is
pasted verbatim from `go tool dist list`. Go can target those platforms;
lgx cannot build anything runnable for them.

The user gets a wall of compiler output rather than "iOS is not supported",
which is the same class of unhelpful diagnostic as
[`lgx-go-local-stdlib-heuristic.md`](./lgx-go-local-stdlib-heuristic.md).

## Why a mobile build is different

An iOS or Android app is not an executable the OS launches. The Go side is a
library linked into a platform project. Wails v3 builds it like this
(`internal/commands/build_assets/ios/Taskfile.yml`):

```sh
go build -buildmode=c-archive -overlay build/ios/xcode/overlay.json \
  -tags ios -o app.a
```

then generates an Xcode project, codesigns, and installs to the simulator
with `simctl`. Android is the same shape with `-buildmode=c-shared`.

Three things lgx would need, none of which it has:

1. **A build mode.** `gobuild.lg` ends with `go build -o <out> .`
   (`lgx/gobuild.lg:559`), hardcoded to produce an executable. There is no
   `-buildmode`, and no `:targets` key that could carry one.
2. **A different entry point.** The generated `main.go` is
   `os.Exit(cli.Main(version, commit))`. Under `-buildmode=c-archive`,
   `main()` is never invoked; the archive needs an exported symbol the
   platform project calls. Wails supplies that through a generated overlay.
3. **cgo, with SDK flags.** Cross-target builds force `CGO_ENABLED=0`
   (`lgx/gobuild.lg`), and both mobile platforms are entirely cgo. They also
   need clang flags lgx has no way to pass:
   `-isysroot <sdk> -target arm64-apple-ios15.0-simulator`.

Beyond the build there is a whole platform pipeline — Xcode project,
provisioning, codesign, `simctl` — that lgx would be reimplementing rather
than reusing.

## What is not the problem

let-go itself. `GOOS=ios GOARCH=arm64 go build ./pkg/...` succeeds on the
`go-deps-combined` tree, and the VM is a bytecode interpreter rather than a
JIT, so it does not need the executable memory iOS forbids. The gap is
entirely build plumbing.

## Suggested resolution

**Do the cheap half.** Reject a mobile target during the same preflight that
already validates `--target`, naming why:

```
error: target ios/arm64 is not supported - an iOS app is a c-archive linked
into an Xcode project, not an executable. See docs/issues/lgx-mobile-targets-buildmode.md
```

`ios/*` and `android/*` should come out of the accepted set, or be listed
separately as known-but-unsupported. Note this is different in kind from the
Windows gap
([`windows-build-unix-only-term.md`](./windows-build-unix-only-term.md)),
which is a bug upstream in let-go with a real fix behind it. Mobile is a
design boundary, and the message should say so rather than implying it is
coming.

**Probably do not do the other half.** Teaching lgx `-buildmode`, overlay
generation, Xcode projects and codesigning would duplicate `wails3` (and
`gomobile`) badly. The realistic path for anyone who wants a let-go mobile
app is to invert ownership: a normal `wails3` project whose Go side embeds
let-go as a library and runs an AOT-bundled `.lg`, with `wails3` driving the
build. That gives up "let-go drives everything", but it reuses the platform
machinery instead of reproducing it.

This generalises past mobile: lgx can drive the build only for frameworks
whose build is `go build`. Desktop Wails works precisely because
`wails3 build` is `go build` plus separable packaging steps. See
[`../knowledge-base/lgx-wails-desktop.md`](../knowledge-base/lgx-wails-desktop.md).
