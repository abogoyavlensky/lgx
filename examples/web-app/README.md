# web-app example

A small todo app: a JSON API over sqlite with a one-page
[Alpine.js](https://alpinejs.dev) UI on top. [HoneySQL](https://github.com/seancorfield/honeysql)
builds the queries, [integrant](https://github.com/weavejester/integrant)
wires the database connection, the handler and the http server, and
[ruuter](https://git.nmm.ee/asko/ruuter) routes requests. The sqlite driver
is a Go package, so the project sets `:lg-runtime :built` and lgx builds
the `lg` it runs on (needs the Go toolchain on `PATH`; the first run takes
a minute, every run after that is a cache hit).

## Running

```
lgx run                       # http://localhost:8080, todos.db in the cwd
PORT=9000 DB_PATH=/tmp/t.db lgx run
```

Open http://localhost:8080 for the UI, or drive the API directly:

```
curl -d '{"title":"write docs"}' localhost:8080/todos
curl localhost:8080/todos
curl -X POST localhost:8080/todos/1/complete
curl localhost:8080/todos/1
curl -X DELETE localhost:8080/todos/1
```

`lgx test` runs two suites against a throwaway database: the handler as a
plain function, and the whole system on a free port with real requests
through the server. `lgx build` produces `bin/web-app`, a single binary
with the driver linked in and `resources/` embedded, so the UI ships
inside it. `lgx info` shows the runtime decision and every Go dep the
sqlite package pulls in.

## Layout

```
src/app/db.lg       ::conn component (open + schema), HoneySQL queries
src/app/routes.lg   ::handler component: the JSON API plus / and /static/:file
resources/public/   index.html (Alpine over the API) and alpine.min.js
src/app/server.lg   ::http component: http/start on init, http/stop on halt
src/app/system.lg   the integrant config, start!/stop!
main.lg             starts the system and http/wait-s on the server
test/app/routes_test.lg   the handler over a temp db, no server
test/app/system_test.lg   the full system on 127.0.0.1:0, over http
```

The three components form a chain (`server -> handler -> db`), so
integrant starts the db first and halts it last: `ig/halt!` stops the
server before the connection it serves from is closed. The server
component holds the record `http/start` returns; its `:port` is the bound
one, which is how the system test runs on `":0"` and finds out where it
landed.

## let-go version

The pin in `lgx.edn` is a sha on let-go `main` rather than a release:
the stoppable server (`http/start`, `http/stop`, `http/wait`), the
`:headers {}` fix and the `[x & more]` destructuring fix that lets
integrant handle a three-component chain landed in
[nooga/let-go#898](https://github.com/nooga/let-go/pull/898) and are not
in a tagged release yet. Move the pin to a tag once one includes it.
