# medley example

A real-world fetch test: pulls
[`weavejester/medley`](https://github.com/weavejester/medley) v1.10.0 from
GitHub via lgx and tries to use a few of its core fns.

## Running

```
LGX_LG=/path/to/lg ../../bin/lgx install
LGX_LG=/path/to/lg ../../bin/lgx run main.lg
```

`LGX_LG` should point to an `lg` build that supports `-source-paths` (i.e., a
build of [nooga/let-go#feat-source-paths](https://github.com/nooga/let-go) or
later).

## Status

**lgx side:** works end-to-end. The lib clones into
`~/.lgx/gitlibs/github.com/weavejester/medley/<sha>/`, lgx adds `<sha>/src/`
to `-source-paths`, and `lg` opens `medley/core.cljc`.

**let-go side:** fails to compile. medley's `editable?` helper uses
`(instance? clojure.lang.IEditableCollection coll)` in the `:default`
reader-conditional branch, and the let-go runtime does not define
`clojure.lang.IEditableCollection`. The same is likely true for any Clojure
library that touches JVM interop — even via reader conditionals.

This example is kept as-is to document the current state: lgx is ready for
real Clojure libraries, but the let-go runtime needs a story for
JVM-interop-adjacent code (stubs, alternate reader-conditional tag, or
similar) before pure-Clojure libs like medley can load directly.
