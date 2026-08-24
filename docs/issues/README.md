# Upstream issues

Issues filed (or to be filed) against
[nooga/let-go](https://github.com/nooga/let-go).

| File | Subject | Status |
|---|---|---|
| [source-paths-flag.md](./source-paths-flag.md) | `-source-paths` flag and `LG_SOURCE_PATHS` env var | done |
| [inherit-stdio-runner.md](./inherit-stdio-runner.md) | `os/run` so `lgx run -r` REPL can work | resolved (`os/exec*` in 1.10.0) |
| [letgo-clj-support.md](./letgo-clj-support.md) | Native `.clj` library support — three small diffs | draft |
| [clojure-lib-compat.md](./clojure-lib-compat.md) | Reader/compiler/resolver gaps blocking real Clojure libs | draft |
| [integrant-dependency-compat.md](./integrant-dependency-compat.md) | Run weavejester/dependency + integrant under let-go (defrecord field scope, real PersistentQueue, find-var/get-method, empty catch body) | implemented on `integrant-compat` |
| [tools-cli-compat.md](./tools-cli-compat.md) | Function, catch, constructor, sequence, and regex gaps found by tools.cli | resolved on `clojure-cli-compat` |
| [error-color-missing-esc.md](./error-color-missing-esc.md) | Error formatter emits ANSI codes without `\x1b` ESC byte | draft (fix on `fix-colored-output`) |
| [load-failure-silent.md](./load-failure-silent.md) | `(:require)` of a file with a compile error returns nil and prints to stderr only — exit 0, missing tests hidden | draft |
| [nrepl-port-zero.md](./nrepl-port-zero.md) | `-p 0` should bind an OS-assigned nREPL port and report the real one | draft |
| [http-request-method-string.md](./http-request-method-string.md) | `http` server delivers `:request-method` as a String, not a Keyword (breaks Ring routers) | draft |
| [interop-slice-boxing.md](./interop-slice-boxing.md) | `[]any` crosses the Go/let-go boundary as opaque boxes, and a vector containing `nil` fails to convert to `[]any` | implemented on `fix/vm-boxing-symmetry` |
| [aero-compat.md](./aero-compat.md) | Run juxt/aero under let-go — TaggedLiteral type + `edn/read` tag dispatch, static-field-in-call-position, syntax-quote qualification, namespaced `:keys`, seq metadata | prototyped (throwaway), not upstreamed |
| [windows-build-unix-only-term.md](./windows-build-unix-only-term.md) | `pkg/rt/term.go` uses `x/sys/unix` unguarded, so `GOOS=windows` builds fail — blocks windows targets in lgx cross-compilation | draft |
