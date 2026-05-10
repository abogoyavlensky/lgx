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
- Macros: `case`, `cond`, `cond->`, `cond->>`, `when`, `when-not`,
  `when-let`, `loop`/`recur`, `doseq`, `binding` (dynamic Vars only),
  `try`/`catch`.
- Errors: `ex-info`, `throw`.

## `os`

- Process: `os/sh` (buffered — see gotchas), `os/exec` (returns
  `*exec.Cmd`; `Run`/`Wait` are not exposed), `os/exit`, `os/args`
  (value, not fn).
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

- No way from let-go to wire a subprocess's stdio to the parent's.
- `os/exec` returns a Go `*exec.Cmd` but exposes only `with-stdin`. You
  can't reach `Stdout`/`Stderr` fields or call `Run`/`Wait` from let-go.
- `syscall/exec` (process replacement) exists on Linux only.

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> [`pkg/rt/lang.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/lang.go)
> (core fns, regex, parse-*, slurp/spit),
> [`pkg/rt/iort.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/iort.go)
> (mkdir, file-exists?, write!, IOHandle),
> [`pkg/rt/os.go`](https://github.com/nooga/let-go/blob/main/pkg/rt/os.go)
> (entire `os` ns),
> [`pkg/rt/core/string.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/string.lg)
> (string ns),
> [`pkg/rt/core/edn.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/edn.lg)
> (edn ns),
> [`pkg/rt/core/io.lg`](https://github.com/nooga/let-go/blob/main/pkg/rt/core/io.lg)
> (io ns).
