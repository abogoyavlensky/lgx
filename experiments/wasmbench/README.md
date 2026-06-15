# wasmbench — WASM vs native SQLite micro-benchmark

A throwaway-turned-kept perf spike comparing **WASM SQLite**
(`ncruces/go-sqlite3` = [wazero](https://github.com/tetratelabs/wazero) +
SQLite-wasm) against **native pure-Go SQLite**
(`modernc.org/sqlite`), both `CGO_ENABLED=0`.

It backs the performance section of
[`../../docs/DYNAMIC_NATIVE_LOADING.md`](../../docs/DYNAMIC_NATIVE_LOADING.md)
(§5.5) — the question of whether the wazero "load wasm libs at runtime"
approach erodes let-go's fast startup. (Spoiler: it doesn't.)

This is a **standalone Go module**, independent of the let-go/lgx build.
lgx itself needs no Go toolchain — this experiment does.

## Requirements

- Go ≥ 1.26 on `PATH`. lgx's `.mise.toml` intentionally omits `go`
  (let-go dev needs no Go), so install it separately if you use mise:
  `mise use -g go@1.26`.

## Files (selected by build tag)

| Tag | File | What it does |
|---|---|---|
| `bench` | `main.go` | throughput: 50k insert + full scan, for modernc and ncruces (twice, to show in-process module reuse) |
| `base` | `base.go` | empty `main` — Go-runtime baseline for startup/size |
| `mo` | `mo.go` | open native modernc + `create table` — startup/size probe |
| `nc` | `nc.go` | open wasm ncruces + `create table` — startup/size probe |

## Run

```sh
# throughput (:memory:)
CGO_ENABLED=0 go run -tags bench .

# startup + binary size probes
CGO_ENABLED=0 go build -tags base -ldflags="-s -w" -o /tmp/p_base .
CGO_ENABLED=0 go build -tags mo   -ldflags="-s -w" -o /tmp/p_mo .
CGO_ENABLED=0 go build -tags nc   -ldflags="-s -w" -o /tmp/p_nc .
ls -l /tmp/p_base /tmp/p_mo /tmp/p_nc                       # size
for f in /tmp/p_base /tmp/p_mo /tmp/p_nc; do /usr/bin/time -f '%e s' "$f"; done  # startup
```

## Results snapshot (linux/arm64, Go 1.26.3, `:memory:`)

| | startup (cold → warm) | insert 50k | scan 50k | binary (`-s -w`) |
|---|---|---|---|---|
| native modernc | 3.8 → 2.7 ms | 50.2 ms | 25.3 ms | 6.03 MB |
| wasm (wazero) | 5.8 → 2.0 ms | 48.7 ms | 24.6 ms | 7.93 MB |
| *(Go baseline)* | 1.7 ms | — | — | 1.25 MB |

Takeaways: wasm startup overhead is ~1–4 ms (negligible); throughput
ties native pure-Go; the wasm binary is ~1.8 MiB larger (carries the
wazero runtime + the `sqlite.wasm` blob). Full analysis and caveats in
the doc.
