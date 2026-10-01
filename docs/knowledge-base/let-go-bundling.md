# Bundling let-go programs

`lg -b script.lg out` produces a standalone executable: a copy of the
`lg` binary with the program's bytecode appended in the LGB format. The
output runs anywhere `lg` does, with no separate runtime install. About
~10 MB per bundle.

## What gets bundled

The bundler walks every `(:require …)` transitively at compile time.
Each loaded namespace's bytecode lands in the bundle in dependency
order, so `lg -b cli.lg out` automatically pulls in `cli.cljc`'s
requires (e.g. `lib.lg`, `net.lg`) and any of theirs. No manifest
needed.

`pkg/resolver/resolver.go` populates `LoadedChunks` and `LoadOrder`
during compilation; `bundleBinary` in `lg.go` writes them in order
ahead of the main chunk.

## Compile time vs run time

A bundled binary runs the embedded bytecode by entering a different
code path in `lg.go` (`checkBundledLGB`) before `flag.Parse`. Two
consequences worth knowing:

1. **`flag.Parse` does not run for bundled binaries.** CLI flags
   declared via `flag.StringVar` (in `lg.go` itself) are inert at
   bundle runtime. The bundle's user sees `os/args` as
   `["./out", ...args]`. Read env vars or parse `os/args` manually.

2. **Top-level forms run twice when bundled** — once during
   `CompileMultiple` at bundle build time, once when the bundled
   binary executes. Guard side-effecting entry calls with
   `*compiling-aot*`:

   ```clojure
   (when-not *compiling-aot* (main))
   ```

   `*compiling-aot*` defaults to `false` and is set to `true` in
   `lg.go` only when `-c`/`-b`/`-w` is invoked. The bundle execution
   path doesn't touch it, so the guard runs `(main)` exactly once at
   bundle startup.

## `-c` writes bytecode only

`lg -c out.lgb script.lg` writes the program and every namespace it
loads, and `lg out.lgb` runs it from any directory. Unlike `-b`, it does
not embed `-resource-paths`: `io/resource` returns nil when the `.lgb`
runs away from the resource dirs (verified on let-go main `a141e406`).
`lgx build` with `:target :lgb` warns about this.

## `-w` builds a browser app

`lg -w <dir> script.lg` compiles the program on the host (with
`*compiling-aot*` true, as `-b` and `-c` do), then writes a throwaway Go
module in a temp dir and runs `go build` for `js/wasm`. The module's
`go.mod` requires only let-go and its generated `main.go` imports only
runtime packages, so a custom `lg`'s extra Go packages never reach the
app. It embeds `program.lgb` and no resource archive. `<dir>` gets
`index.html` and `coi-serviceworker.js`; `-w-wasm external` adds
`main.wasm`, `-w-shell xterm|none|<template>` picks the page, and
`-w-host-eval` exposes `LetGoHost.eval`. Verified on lg 1.13.0 and let-go
main `4e769212`. `lgx build` with `:target :wasm` drives it.

## Cross-OS bundling

```
lg -b -bundle-base /path/to/target-os-lg out script.lg
```

Uses the target's `lg` binary as the base, so you can build a Linux
bundle on macOS as long as you have a Linux `lg` binary on hand.

## Output path collision

`lg -b foo lgx.lg` fails if a directory `foo/` exists in the working
directory. Bundle to a distinct path (`bin/lgx`, not `lgx`).

## Real-world examples

- [nooga/lgcr](https://github.com/nooga/lgcr) — multi-file container
  runtime; bundle.sh shows the production pattern.
- [nooga/xsofy](https://github.com/nooga/xsofy) — single ~6900-line
  source file; proves single-file scale works fine.

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> [`lg.go`](https://github.com/nooga/let-go/blob/main/lg.go)
> (`bundleBinary`, `checkBundledLGB`, `readBundledLGB`,
> `*compiling-aot*` setting),
> [`pkg/resolver/resolver.go`](https://github.com/nooga/let-go/blob/main/pkg/resolver/resolver.go)
> (`LoadedChunks`, `LoadOrder`),
> [`pkg/cli/wasm.go`](https://github.com/nooga/let-go/blob/main/pkg/cli/wasm.go)
> (`buildWasm`),
> [`pkg/rt/wasm/`](https://github.com/nooga/let-go/tree/main/pkg/rt/wasm)
> (`RenderMain`),
> [`pkg/rt/lang.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/lang.go)
> (`*compiling-aot*` Var def),
> [`pkg/bytecode/`](https://github.com/nooga/let-go/tree/main/pkg/bytecode)
> (LGB encode/decode).
