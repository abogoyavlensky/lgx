# Using WASM libraries

lgx can install and use **WebAssembly-backed libraries** — native functionality
(e.g. SQLite) that ships as a portable `.wasm` and runs in-process via let-go's
built-in `wasm` host (wazero). No cgo, no separate process, no per-user Go
toolchain.

This is the consumer-facing guide. For the why/how of the whole approach, see
[`DYNAMIC_NATIVE_LOADING.md`](./DYNAMIC_NATIVE_LOADING.md) and
[`GO_LIBS_INTEROP_OPTIONS.md`](./GO_LIBS_INTEROP_OPTIONS.md).

## Using one in your project

A WASM library is just a normal git dependency:

```clojure
;; lgx.edn
{:deps {sqlite {:git/url "https://github.com/abogoyavlensky/sqlite-lg"
                :git/sha "..."}}
 :main "main.lg"}
```

```clojure
;; main.lg
(require '[sqlite])
(let [db (sqlite/open ":memory:")]
  (sqlite/execute! db "create table t (x int)")
  (sqlite/execute! db "insert into t values (?)" 42)
  (println (sqlite/query db "select * from t")))   ; => [{:x 42}]
```

```sh
lgx install      # fetch the dep (its .wasm comes with it)
lgx run          # runs main; lgx puts the dep's .wasm on the resource path
lgx build        # standalone binary with the .wasm embedded — runs anywhere
```

You need a **wasm-capable `lg`** (one whose runtime has the `wasm` namespace).
If yours is too old, lgx tells you which dep needs what:

```
lgx: dependency sqlite requires lg >= 1.11.0, but the active lg is 1.10.0.
Upgrade lg, or point LGX_LG at a newer build.
```

## How it works

When lgx resolves a dependency, it reads the dep's own `lgx.edn` and, if the dep
opts in, contributes its resources to your build:

- **`:lgx/lib {:resources true}`** — lgx adds the dep's `:resource-paths` (its
  `.wasm` lives there) to `-resource-paths` for `run`/`repl`/`build`. Deps that
  don't opt in stay source-only, so nothing is pulled in unexpectedly.
- **`:lgx/min-lg-version "X.Y.Z"`** — lgx checks the active `lg` (`lg -v`) meets
  it and errors clearly otherwise. (Permissive on dev builds whose version can't
  be parsed.)

`lgx build` bundles everything under `-resource-paths` into the standalone
binary, so the embedded `.wasm` ships inside it — the result runs with no `lg`,
no `lgx`, and no network.

## Authoring a WASM library

A WASM library is a normal lgx project that also ships a `.wasm` and declares the
two keys above. See [`sqlite-lg`](https://github.com/abogoyavlensky/sqlite-lg)
for a worked example. Layout:

```
your-wasm-lib/
  lgx.edn            ; :paths ["src"] :resource-paths ["resources"]
                     ; :lgx/lib {:resources true}  :lgx/min-lg-version "1.11.0"
  src/your_lib.lg    ; the let-go API; calls the wasm/* host (instantiate/call/…)
  resources/your.wasm
```

The `.lg` glue marshals between let-go values and the module's linear memory
using the `wasm` host primitives (`wasm/instantiate`, `wasm/call`,
`wasm/read`/`wasm/read-string`/`wasm/read-cstring`, `wasm/write`, `wasm/close`).
