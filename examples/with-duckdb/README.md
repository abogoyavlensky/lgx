# with-duckdb example

Web analytics in-process: 1000 synthetic page views go into an in-memory
[DuckDB](https://duckdb.org), then the app asks the questions a dashboard
asks - daily views and unique visitors, top pages with p50/p95 time on
page, and site-wide totals - and checks the answers.

It uses the [`duckdb`](https://github.com/abogoyavlensky/letgo-packages/tree/master/duckdb)
package from letgo-packages, which runs DuckDB over the shared `sql` layer
and hands values back as plain let-go values: `sum()` is an int, dates are
ISO strings, no casts needed.

## Running

```
lgx run
lgx build && ./bin/with-duckdb
```

The driver is a Go package, so the project sets `:lg-runtime :built` and
lgx builds the `lg` it runs on. It is also **cgo**: that build needs a C
compiler as well as the Go toolchain, takes about 40 s the first time
(every run after that is a cache hit), and only works for the host
platform - `lgx build --target` cannot cross-compile it. See the package
README for the full list.

## Why the batched insert

`insert-batch!` writes 200 events per `insert ... values (...), (...)`
statement. One statement per event costs a round trip each; batching was
about 14x faster when measured. A real tracker would buffer hits in
memory and flush them the same way.
