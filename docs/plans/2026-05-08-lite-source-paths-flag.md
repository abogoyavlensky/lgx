# Add `-source-paths` flag and `LG_SOURCE_PATHS` env var to let-go

## Context

`lg` hardcodes the namespace search path to `["."]` (lg.go:432). Tools that
maintain a per-user cache of let-go libraries - package managers, monorepos,
build systems — have no way to point `lg` at additional directories without
copying files into the project.

Filed as an issue upstream; the maintainer accepted, asking that both a flag
and an env var be honored, and that `.lgb` format also be supported as a
stretch goal. Source-only is acceptable as a smaller PR. We ship source-only
and do not follow up with `.lgb` discovery.

Branch: `feat-source-paths` in nooga/let-go.

## Behavior

**Flag:** `-source-paths`. Single dash to match lg's existing flag style
(`-r`, `-c`, `-b`, `-bundle-base`, `-w`, `-version`). Go's `flag` package
accepts `--source-paths` interchangeably.

**Env var:** `LG_SOURCE_PATHS`.

**Separator:** `os.PathListSeparator` — `:` on Unix, `;` on Windows.

**Precedence:** flag wins. If `-source-paths` is set, the env var is ignored
entirely. No merging.

**Project root:** `.` is always prepended to whatever the user supplies, so
project code wins over a same-named cached lib.

**Empty entries dropped.** `~` expansion is not done (left to the shell).

**Modes covered:** `run`, `-c`, `-b`, `-w`. The resolver is shared.

```
lg -source-paths ~/.cache/libs/foo:~/.cache/libs/bar script.lg
# resolver path: [".", "~/.cache/libs/foo", "~/.cache/libs/bar"]

LG_SOURCE_PATHS=~/.cache/libs/foo lg script.lg
# resolver path: [".", "~/.cache/libs/foo"]
```

## Implementation

Three files.

### `pkg/resolver/resolver.go`

Add a small exported helper:

```go
// ParseSearchPaths splits a path-list string on os.PathListSeparator,
// dropping empty entries. Returns nil for empty input.
func ParseSearchPaths(raw string) []string { ... }
```

`NSResolver.path` and `Load` are unchanged — they already walk a `[]string`.

### `lg.go`

- Add `var sourcePaths string` package var.
- Register the flag in `init()` next to existing flags.
- In `main()`, before the resolver is built:

  ```go
  raw := sourcePaths
  if raw == "" {
      raw = os.Getenv("LG_SOURCE_PATHS")
  }
  paths := append([]string{"."}, resolver.ParseSearchPaths(raw)...)
  nsResolver := resolver.NewNSResolver(context, paths)
  ```

- Reuse `paths` in the bundled-binary path (lg.go:378) so all four modes see
  the same list.

### `test/source_paths_test.go`

Two tests:

1. `TestParseSearchPaths` — table-driven: empty, single, multi, consecutive
   separators, leading/trailing separators.
2. `TestResolverWithExtraPath` — create a temp dir with
   `foo.lg` (`(ns foo) (def x 42)`), build an `NSResolver` with `[".", tmpDir]`,
   call `Load("foo")`, assert non-nil namespace.

CLI flag wiring is too thin to test without a subprocess; manual smoke test
goes in the PR description:

```
mkdir -p /tmp/lgsp && echo '(ns util) (defn greet [] "hi")' > /tmp/lgsp/util.lg
lg -source-paths /tmp/lgsp -e "(require 'util) (println (util/greet))"
```

## Verification

- `go test ./test/... -run SourcePaths` passes.
- Manual smoke test prints `hi`.
- `go test ./...` stays green.
- `lg -e "(require 'util)"` (no flag, no env) still fails as before.
