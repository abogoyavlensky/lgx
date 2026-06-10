# Upstream issues

Issues filed (or to be filed) against
[nooga/let-go](https://github.com/nooga/let-go).

| File | Subject | Status |
|---|---|---|
| [source-paths-flag.md](./source-paths-flag.md) | `-source-paths` flag and `LG_SOURCE_PATHS` env var | done |
| [inherit-stdio-runner.md](./inherit-stdio-runner.md) | `os/run` so `lgx run -r` REPL can work | resolved (`os/exec*` in 1.10.0) |
| [letgo-clj-support.md](./letgo-clj-support.md) | Native `.clj` library support — three small diffs | draft |
| [clojure-lib-compat.md](./clojure-lib-compat.md) | Reader/compiler/resolver gaps blocking real Clojure libs | draft |
| [error-color-missing-esc.md](./error-color-missing-esc.md) | Error formatter emits ANSI codes without `\x1b` ESC byte | draft (fix on `fix-colored-output`) |
| [load-failure-silent.md](./load-failure-silent.md) | `(:require)` of a file with a compile error returns nil and prints to stderr only — exit 0, missing tests hidden | draft |
| [nrepl-port-zero.md](./nrepl-port-zero.md) | `-p 0` should bind an OS-assigned nREPL port and report the real one | draft |
