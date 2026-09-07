# Go Ecosystem Strategy

Which Go libraries lgx projects should wrap, and why.

## The filter

Wrap Go where Clojure's answer is JVM-bound. let-go has no JVM, so those
categories have no Clojure option at all. That is a stronger claim than
convenience: it is the only route.

Do not wrap what let-go already does, or what a pure Clojure library
already covers. `examples/clojure-libs/` proves aero, integrant, malli,
hiccup, medley, tools.cli, bond and dependency.

## Where we are

`letgo-packages` ships `sql`, `sqlite` and `postgres`. The sql layer is
driver-agnostic, and postgres proves it: one added coord
(`jackc/pgx/v5/stdlib`) and no Go code. That is our strongest artifact
and it appears nowhere outside a README.

## Candidates

| Clojure | Java weight | Go |
|---|---|---|
| docjure | Apache POI | `qax-os/excelize` |
| clucie | Lucene | `blevesearch/bleve` |
| clj-jgit | JGit | `go-git/go-git` |
| clj-ssh | JSch | `x/crypto/ssh` |
| clj-test-containers | testcontainers-java | `testcontainers-go` |
| buddy | BouncyCastle | `x/crypto/bcrypt`, `crypto/*` |
| tools.logging | slf4j, logback | `log/slog` (stdlib) |
| sentry-clj | Sentry Java SDK | `getsentry/sentry-go` |
| jackdaw | Kafka Java client | `segmentio/kafka-go` |
| quartzite | Quartz | `robfig/cron` |
| clj-pdf | iText | `pdfcpu` |
| enlive | jsoup | `PuerkitoBio/goquery` |

Start with `log/slog`, `bcrypt` plus `crypto/rand`, and
`testcontainers-go`. Logging, auth and testing are what a reviewer checks
before calling a stack production-ready, and all three are missing today.

Lead the demos with `bleve` and `go-git`. Both are capabilities people do
not expect from a scripting language, and go-git suits lgx's CLI-tooling
audience. Skip the AWS SDK: large and generics-heavy.

## Constraints found

- **`http/serve` already speaks Ring.** It takes a let-go fn and reads
  `:status`, `:headers` and `:body` off the returned map
  (`pkg/rt/http.go:102-145`). Routing is the only gap, so reitit-core
  fits and chi does not.
- **reitit-core ships `Trie.java`.** let-go matches `:lg`, `:clj` and
  `:default`, never `:cljs` (`pkg/compiler/reader.go:1122-1125`), so its
  `.cljc` resolves toward the Java. Check whether `linear-router` avoids
  `reitit.trie` before committing.
- **lginterop skips generics silently.** `generic?` gates four emission
  sites in `cmd/lginterop/lginterop.lg`. Nothing warns and the guide
  never mentions it, so a package can lose half its API with no
  diagnostic.
- **Go calls let-go through `vm.Fn.Invoke`.** A shim implements the Go
  interface itself and invokes let-go directly, bypassing the
  single-return `reflect.MakeFunc` proxy (`pkg/vm/func.go:80`). This is
  what makes framework-shaped libraries such as bubbletea reachable.
- **No `time` namespace.** Postgres `timestamptz` arrives as a boxed
  `time.Time`. `:go/interop "time"` plus a thin veneer closes it.
- **`http/request` has no timeout.** A hung request cannot be
  interrupted.

## Open items

- Make lginterop report skipped generic exports.
- File the `http/request` timeout gap upstream.
- Decide whether `time` lands upstream or as a package.
- Tell the postgres story somewhere visible.
