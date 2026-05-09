# Clojure libraries — compatibility survey

Real Clojure libraries don't load on let-go yet. lgx-side everything
works (fetch, cache, `src/` convention, `-source-paths`); the failures
are all on the let-go runtime/reader/compiler side.

| Lib | Subdir | Fails at |
|---|---|---|
| [medley](https://github.com/weavejester/medley) v1.10.0 | [medley/](./medley) | runtime (`:default` JVM class ref) |
| [babashka/cli](https://github.com/babashka/cli) v0.8.67 | [babashka-cli/](./babashka-cli) | reader (`^ClassName` metadata) |
| [ruuter](https://git.nmm.ee/asko/ruuter) (master) | [ruuter/](./ruuter) | compiler (`def` with docstring) |
| [hiccup](https://github.com/weavejester/hiccup) v2.0.0 | — | resolver (all `.clj`, no `.cljc`) |

Each subdir has a runnable `lgx.edn` + `main.lg` that triggers the
failure. The four gaps are documented together in
[../../docs/issues/clojure-lib-compat.md](../../docs/issues/clojure-lib-compat.md)
for upstream filing once the `-source-paths` PR lands.

For an example of lib install actually working end-to-end, see
[../with-lib/](../with-lib).
