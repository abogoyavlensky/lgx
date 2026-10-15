# vm: the global frame-pool mutex serializes bytecode calls across goroutines

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** filed as [nooga/let-go#1065](https://github.com/nooga/let-go/issues/1065).

Found while measuring let-go web-app performance (JSON APIs, DB-bound), on let-go main `d0108ba6`.

## Summary

`acquireFrame`/`releaseFrame` (`pkg/vm/vm.go`) share one `framePoolMu`, so every bytecode call on every goroutine takes the same global lock twice. Parallel bytecode work gets slower than running it sequentially.

Measured at `d0108ba6`, 5-core Linux VM.

## Repro

```clojure
(defn work [] (reduce + (map (fn [x] (inc x)) (range 200000))))
(defn timed [f] (let [t (System/nanoTime)] (f) (/ (- (System/nanoTime) t) 1e6)))
(work)
(let [s (timed #(dotimes [_ 8] (work)))
      p (timed #(doall (map deref (doall (for [_ (range 8)] (future (work)))))))]
  (println "speedup" (/ s p)))
```

Prints `speedup 0.64`–`0.72`; `GOMAXPROCS=1` gives 1.0.

An `http/serve` handler rendering an 8 KB page scales 1.4x on 5 cores. A mutex profile under load puts all of the contention in `acquireFrame`/`releaseFrame`.

## Swapping in sync.Pool

The comment above the pool says `sync.Pool` cost ~25% on `fib(30)`. Swapping it back in, as a quick check:

| | mutex stack | sync.Pool |
|---|---|---|
| `fib 28`, one goroutine | 157 ms | 170 ms (+8%) |
| repro above | 0.72x | 2.5–3.0x |
| `http/serve` page, 50 conns | 125 req/s | 290 req/s |

## Possible directions

- A pool per `ExecContext` or per goroutine: no lock and no `sync.Pool` pinning on the hot path.
- `sync.Pool`, accepting the single-goroutine cost.
- Keep the stack, but fall back to `sync.Pool` when `TryLock` fails.
