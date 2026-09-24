# Built `lg` runtimes keep their symbol table and DWARF, about 18 MB per binary

**Status: open**

## Problem

Under `:lg-runtime :built`, lgx builds the custom `lg` with a bare
`go build -o <out> .` (`lgx/gobuild.lg:571`). It passes no `-ldflags`, so
every built runtime keeps the Go symbol table and DWARF debug info. So does
every binary `lgx build` bundles from it, because `lg -b` uses the runtime as
its base. let-go's own release build strips both
(`-ldflags="-s -w -X main.commit=..."`, let-go `Makefile:200`), which is why a
stock `lg` 1.13.0 is 15.8 MB and `strip` finds nothing to remove from it.

Measured on 2026-09-24 (linux/amd64, let-go 1.13.0, duckdb-go v2.10505.0):

| Binary | Size |
|---|---|
| `examples/with-duckdb` via `lgx build` | 90.7 MB |
| the same binary, `strip`ped | 72.9 MB |
| pure Go: open DuckDB, one query | 73.0 MB |
| pure Go, `-ldflags "-s -w"` | 60.0 MB |
| stock `lg` 1.13.0 release | 15.8 MB |

So about 18 MB of every built binary is debug information lgx never asked for.
The rest of the gap to pure Go, about 13 MB, is let-go itself: the VM,
compiler, core library and generated bindings. That part is inherent.

It affects every project with Go deps (sqlite, postgres, duckdb, wails), not
only duckdb, though duckdb's already large binary is where it was noticed.

**Users cannot work around it after the fact.** `lg -b` appends the bundled
program to the base binary, and `strip` drops that payload without an error.
The stripped `with-duckdb` binary started a bare let-go REPL instead of the
app. Stripping has to happen at `go build` time.

## Fix

Pass `-ldflags=-s -w` on the final runtime build only:

```clojure
(go! (target-env-args target) ["-C" dir "build" "-ldflags=-s -w" "-o" out "."]
     "go build" verbose?)
```

Leave the `lginterop-tool` build (`lgx/gobuild.lg:525`) alone. It runs on the
build machine and never ships. Leave out `-trimpath` too, since let-go's own
release build does not use it.

Add a constant line such as `"build|stripped"` to the body `runtime-hash`
hashes (`lgx/gobuild.lg:135`). Without it, every runtime already in
`$LGX_HOME/runtimes/` keeps being reused unstripped until someone runs
`lgx clean --runtimes`, with nothing to tell them why their binary did not
shrink. The cost is one rebuild per project after upgrading lgx.

Notes for whoever picks this up:

- The `runtime-hash` docstring promises that native builds keep the cache
  entries they had before targets existed. That stops being true, so reword
  it. The test `runtime-hash-nil-target-keeps-todays-inputs`
  (`test/lgx/gobuild_test.lg`) only compares the one-arity call with the nil
  target, so it keeps passing, but its name and comment go stale; rename them.
  Add a test that a new line in the hash body changes the hash, if the other
  `runtime-hash-changes-with-*` tests do not already cover that shape.
- No opt-out is needed to start with. Stripped Go binaries still print
  function names and line numbers on a panic (the pclntab survives `-s -w`);
  only delve loses out, and anyone debugging let-go itself goes through
  `LGX_LETGO_REPLACE` and can build their own.
- Update `docs/knowledge-base/lgx-go-runtimes.md`: step 6 of "The build steps"
  (`go build -o ../lg .`) and the "What the hash covers" list.
- Measure `examples/with-duckdb` and `examples/web-app` before and after. The
  expected results are about 73 MB and about 18 MB less respectively.
- After an lgx release ships this, update the size figures in the letgo-packages
  `duckdb/README.md` ("about 90 MB against 16 MB for a stock `lg`").

About two lines of code in `lgx/gobuild.lg`, a docstring, one or two tests,
and the doc update.

## Origin

Came out of a discussion on 2026-09-24, after shipping the letgo-packages
`duckdb` package and `examples/with-duckdb`
(`docs/plans/2026-09-24-0142-letgo-duckdb-package.md`): would the same
program be the same size in pure Go? The measurements above were taken then,
in a throwaway module outside the repo. Deferred rather than done in that PR
because it changes the runtime cache key for every `:built` project, which
deserves its own change and release note.
