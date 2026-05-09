# `-source-paths` flag and `LG_SOURCE_PATHS` env var

**Repo:** [nooga/let-go](https://github.com/nooga/let-go) ·
**Branch:** `feat-source-paths` (commit `b1065a0`) ·
**Design:** [../plans/2026-05-08-lite-source-paths-flag.md](../plans/2026-05-08-lite-source-paths-flag.md)

## Problem

`lg` hardcoded the namespace search path to `["."]`
([lg.go:432](https://github.com/nooga/let-go/blob/master/lg.go#L432)).
External tooling — package managers, monorepos, build systems — could not
point `lg` at additional directories without copying files into the project.

## Change

- New flag `-source-paths` (single dash, matches `-c` / `-b` / `-bundle-base`).
- Env fallback `LG_SOURCE_PATHS`. Flag wins; env is ignored when the flag is set.
- `.` is always prepended, so project code wins over cached libs.
- Separator is `os.PathListSeparator` (`:` on Unix, `;` on Windows).
- Applies to run, `-c`, `-b`, and `-w` modes; the resolver is shared.

```
lg -source-paths ~/.cache/libs/foo:~/.cache/libs/bar script.lg
```

Without this, lgx had no way to tell `lg` where to find cached libs, so the
package manager could not function at all.
