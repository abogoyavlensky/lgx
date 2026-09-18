# web-app example

A small JSON API over sqlite: [HoneySQL](https://github.com/seancorfield/honeysql)
builds the queries, [integrant](https://github.com/weavejester/integrant)
wires the database connection and the http server, and
[ruuter](https://git.nmm.ee/asko/ruuter) routes requests. The sqlite driver
is a Go package, so the project sets `:lg-runtime :built` and lgx builds
the `lg` it runs on (needs the Go toolchain on `PATH`; the first run takes
a minute, every run after that is a cache hit).

## Running

```
lgx run                       # http://localhost:8080, todos.db in the cwd
PORT=9000 DB_PATH=/tmp/t.db lgx run
```

```
curl -d '{"title":"write docs"}' localhost:8080/todos
curl localhost:8080/todos
curl -X POST localhost:8080/todos/1/complete
curl localhost:8080/todos/1
curl -X DELETE localhost:8080/todos/1
```

`lgx test` runs the handler against a throwaway database with no server.
`lgx build` produces `bin/web-app`, a single binary with the driver
linked in. `lgx info` shows the runtime decision and every Go dep the
sqlite package pulls in.

## Layout

```
src/app/db.lg       ::conn component (open + schema), HoneySQL queries
src/app/routes.lg   the handler: a plain fn over a connection
src/app/server.lg   ::http component: http/serve in a future
src/app/system.lg   the integrant config, start!/stop!
main.lg             starts the system and blocks on the server
test/app/routes_test.lg
```

Two things are shaped by let-go as it stands today, not by preference:

- The handler is built by the server component rather than being a
  component of its own. A three-link chain (`server -> handler -> db`)
  hangs `ig/init`, because let-go's `[x & more]` destructuring binds
  `more` to `()` instead of `nil` and `weavejester/dependency`'s cycle
  check never terminates
  ([docs/issues/destructure-rest-empty-seq.md](../../docs/issues/destructure-rest-empty-seq.md)).
- The 204 response omits `:headers`: an empty headers map crashes the
  server
  ([docs/issues/http-empty-headers-panic.md](../../docs/issues/http-empty-headers-panic.md)).

`http/serve` has no shutdown API, so `halt-key!` for the server is a
no-op; the process exit ends it.
