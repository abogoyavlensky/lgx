# Upstream issues

Issues filed (or to be filed) against
[nooga/let-go](https://github.com/nooga/let-go).

| File | Subject | Status |
|---|---|---|
| [source-paths-flag.md](./source-paths-flag.md) | `-source-paths` flag and `LG_SOURCE_PATHS` env var | done |
| [inherit-stdio-runner.md](./inherit-stdio-runner.md) | `os/run` so `lgx run -r` REPL can work | draft |
| [def-docstring.md](./def-docstring.md) | `def` rejects 3-arg form `(def name "doc" init)` | draft (fixed on master, awaiting release) |
| [clojure-lib-compat.md](./clojure-lib-compat.md) | Reader/compiler/resolver gaps blocking real Clojure libs | draft |
| [error-color-missing-esc.md](./error-color-missing-esc.md) | Error formatter emits ANSI codes without `\x1b` ESC byte | draft (fix on `fix-colored-output`) |
| [load-failure-silent.md](./load-failure-silent.md) | `(:require)` of a file with a compile error returns nil and prints to stderr only — exit 0, missing tests hidden | draft |
