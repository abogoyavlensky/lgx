# let-go stdlib quick reference

Pieces we relied on for lgx, grouped by namespace. Not exhaustive — see
[`pkg/rt/`](https://github.com/nooga/let-go/tree/main/pkg/rt) for the
full surface. Use this as a starting point.

## `core` (no prefix)

- File I/O: `slurp`, `spit`, `file-exists?`, `delete-file`, `mkdir`
  (recursive — wraps `os.MkdirAll`).
- Reading: `read-string` (full Clojure reader; handles maps, sets,
  metadata, line comments).
- Numbers: `parse-int`, `parse-long`, `parse-double`, `parse-boolean`.
- Regex: `re-find`, `re-pattern`, `re-matches`, `re-seq`, `re-groups`.
  `re-seq` returns `nil` when nothing matches. In all four matching fns, an
  optional group that did not participate is `nil`; a participating group
  that matched zero characters is `""`. Note `re-groups` takes
  `(re-groups regex str)` and returns all matches — not Clojure's
  matcher-based signature.
- Functions: `fn` and `defn` support Clojure `:pre` and `:post` condition
  maps, including the `%` result binding in postconditions.
- Sequences: `partition` supports `(partition n coll)`,
  `(partition n step coll)`, and `(partition n step pad coll)`.
- Macros: `case`, `cond`, `cond->`, `cond->>`, `when`, `when-not`,
  `when-let`, `loop`/`recur`, `doseq`, `binding` (dynamic Vars only),
  `try`/`catch`.
- Errors: `ex-info`, `throw`.
- Exceptions (let-go branches `clojure-exception-classes`,
  `fix-finally-abnormal-exit`, `typed-catch-dispatch`; pending upstream
  merge): java.lang.* class hierarchy rooted at `Throwable` with real
  constructors (`(Exception. msg)`, `(IllegalArgumentException. msg cause)`,
  ...); typed catch clauses dispatch by class in source order and rethrow on
  no match; `(catch Throwable e ...)` catches anything thrown, including
  plain values; an unmodeled JVM class in a catch never matches instead of
  failing compilation; `finally` runs on all abnormal exits; `assert` throws
  `AssertionError`; VM runtime errors are `java.lang.Exception`, no longer
  `ExceptionInfo`. Not yet in a released `lg`.

## Vars / multimethods

- `find-var` — a namespace-qualified symbol → the interned var (`nil` if the
  namespace or name is absent). Pair with `var-get`.
- `get-method` — `(get-method multifn dispatch-val)` → the method fn that value
  selects (exact match, else the `:default` method, else `nil`). let-go
  multimethods dispatch on exact value + default, not the `isa?` hierarchy.

## Records / protocols / queues

- `defrecord` with inline protocol methods: bare field references in method
  bodies resolve to the field (like `deftype`). `case` test-constants that
  share a field name stay literal — only field *reads* are rewritten.
- `clojure.lang.PersistentQueue` is a real immutable FIFO queue:
  `conj`/`into` (enqueue), `peek` (front), `pop` (dequeue), `seq`, `count`,
  `empty?`. `clojure.lang.PersistentQueue/EMPTY` is the empty queue; `(type q)`
  and `(instance? clojure.lang.PersistentQueue q)` both resolve through
  `QueueType`, and a queue is `=` to any sequential collection with the same
  elements.

## JVM interop shims (Clojure-lib compat)

Motivated by metosin/malli; general and available to any library.

- Predicates/fns: `indexed?` (positional collections), `class` (alias of `type`),
  `uri?` (always `false` — no `java.net.URI`). `monitor-enter`/`monitor-exit` are
  no-ops (no object monitors).
- JVM collection-interface `.`-methods dispatch on the value's let-go interface,
  so they work on any collection: `.valAt` (ILookup), `.iterator` +
  `.hasNext`/`.next` (Iterable/Iterator), `.assoc`, `.cons` (append/prepend per
  type), `.nth`, `.count`, `.hashCode`, `.longValue`.
- Mutable shims: `(java.util.HashMap.)` (`.putAll`/`.get`) and
  `(java.util.ArrayDeque.)` (`.push`/`.pop`/`.peek`/`.isEmpty`) — real mutable
  types for libs that use JVM mutable collections internally.
- `(instance? Class x)` markers: `java.util.Map`, `CharSequence`, bare `Pattern`.
- Static factories: `LazilyPersistentVector/createOwning`,
  `PersistentArrayMap/createWithCheck`, `System/arraycopy`, `Array/newInstance`,
  `Util/hash`/`hashCombine`, `Murmur3/hashLong`; number parses
  `Long/parseLong`/`Integer/parseInt`/`Float/parseFloat`/`Double/parseDouble`;
  bare `UUID/fromString`.
- Degraded (loud stubs / pass-through): java.time date coercion,
  `BigDecimal.`/`URI.` coercion, the `FutureTask.`/`Thread.` timeout path.

## `os`

- Process: `os/sh` (buffered — see gotchas), `os/exec*` (child inherits
  the parent's stdin/stdout/stderr, returns exit code — use for streaming
  or interactive children; lg >= 1.10.0), `os/exec` (returns `*exec.Cmd`;
  `Run`/`Wait` are not exposed), `os/exit`, `os/args` (value, not fn).
- Filesystem: `os/cwd`, `os/ls`, `os/stat`, `os/temp-dir`.
- Env: `os/getenv`, `os/setenv`.
- Platform: `os/os-name`, `os/arch`, `os/file-separator`,
  `os/path-separator`, `os/line-separator`.

## `string`

`string/split`, `string/join`, `string/index-of`,
`string/last-index-of`, `string/trim`, `string/triml`, `string/trimr`,
`string/upper-case`, `string/lower-case`, `string/starts-with?`,
`string/ends-with?`, `string/includes?`, `string/blank?`,
`string/replace`, `string/reverse`, `string/capitalize`, `subs`.

## `edn`

- `edn/read-string` — delegates to `core/read-string`. Handles `;`
  comments inside maps and other Clojure-syntax niceties. Suitable for
  `lgx.edn`-style configs without a separate parser.
- `edn/write-string` — wraps `pr-str`.

## `io` (the let-go ns)

Mostly thin wrappers. `io/slurp-lines` is the only convenience worth
calling out. The base `slurp`/`spit`/`mkdir`/`file-exists?` etc. live
in core, not `io`.

## What's missing or hidden

- No `filepath/join` equivalent. lgx provides its own at
  `lgx/path.lg`.
- `os/exec` returns a Go `*exec.Cmd` but exposes only `with-stdin`. You
  can't reach `Stdout`/`Stderr` fields or call `Run`/`Wait` from let-go.
- `syscall/exec` (process replacement) exists on Linux only.

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> [`pkg/rt/lang.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/lang.go)
> (core fns, regex, parse-*, slurp/spit),
> [`pkg/rt/core/core.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/core.lg)
> (core macros and sequence fns, including `fn`/`defn` conditions and
> `partition`),
> [`pkg/rt/iort.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/iort.go)
> (mkdir, file-exists?, write!, IOHandle),
> [`pkg/rt/os.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/os.go)
> (entire `os` ns),
> [`pkg/rt/core/string.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/string.lg)
> (string ns),
> [`pkg/rt/core/edn.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/edn.lg)
> (edn ns),
> [`pkg/rt/core/io.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/io.lg)
> (io ns),
> and the JVM interop shims in `pkg/rt/host_hashmap.go`, `host_arraydeque.go`,
> `host_iterator.go`, `host_malli_compat.go`, plus `invokeMethodFallback` in
> `lang.go` and `System/arraycopy` in `pkg/rt/system.go`.
