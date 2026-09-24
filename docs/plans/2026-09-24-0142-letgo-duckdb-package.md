# letgo-packages `duckdb` Package + `with-duckdb` Example Implementation Plan

**Status: completed 2026-09-24.**

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `duckdb` driver package in letgo-packages, built on the shared `sql` layer, that returns DuckDB values as plain let-go values. Then add `examples/with-duckdb/` to lgx, consuming the tagged package.

**Tech Stack:** let-go 1.13.0, lgx 0.3.2 (`:lg-runtime :built`), Go 1.27 with cgo, `github.com/duckdb/duckdb-go/v2 v2.10505.0` (DuckDB 1.5.5), letgo-packages `sql` layer.

**Repos:**
- letgo-packages: `~/Projects/letgo-packages`, remote `https://github.com/abogoyavlensky/letgo-packages.git`. Work on a new branch `duckdb` off `master` (currently `e470cf0`).
- lgx: `~/Projects/lgx`, branch `duckdb-discussion` (off `master` at `ba9e5b3`). This plan and the example commit here.

**Outward-facing steps need the user's go-ahead:** pushing branches, opening PRs, merging, and above all pushing tags. proxy.golang.org records a Go module tag permanently, and the README forbids moving a pushed tag. Stop and ask before each of these steps.

---

## Design

### Background: what the spike showed

A throwaway spike (since deleted) ran DuckDB through the existing `sql` layer with no Go code. The only additions were `github.com/duckdb/duckdb-go/v2 {:go/version ...}` and `(sql/Open "duckdb" "")`. Findings:

- Analytics SQL works through `sql.core`: `count(distinct …)`, `quantile_cont`, `approx_count_distinct`, `date_trunc`. So do concurrent writers (8 futures) and a file-backed database that is closed and reopened.
- `lgx build` works. The binary is 90 MB against 16 MB for stock `lg`, and it links `libstdc++` and glibc dynamically. The first runtime build took about 39 s. A cross target (`--target linux/arm64`) fails at build time with `build constraints exclude all Go files in …/duckdb-go-bindings/lib/linux-arm64`, because lgx forces `CGO_ENABLED=0` for cross builds.
- Ingest: 2000 single-row autocommit inserts took 1494 ms; 2000 rows in 200-row `VALUES` batches took 107 ms.
- **Many values come back as opaque boxes or wrong values:**

  | DuckDB type | What `sql.shim/ScanRow` + let-go boxing returns |
  |---|---|
  | HUGEINT, including **`sum()` over INTEGER/BIGINT** | boxed `*big.Int` |
  | UBIGINT above int64 max | wraps to `-1`: let-go `BoxValue` does `Int(v.Uint())` |
  | DECIMAL | boxed `duckdb.Decimal` |
  | DATE / TIMESTAMP / TIMESTAMPTZ | boxed `time.Time` |
  | UUID | 16 raw bytes as a let-go string (the driver returns `[]byte`) |
  | INTERVAL | boxed `duckdb.Interval` |
  | MAP | boxed `duckdb.OrderedMap` |
  | STRUCT | let-go map with **string** keys |
  | LIST | vector (fine) |

  Integers, doubles, varchar, boolean, ENUM, NULL, `count(*)` and `avg` were already fine.

### Approach

1. **A `duckdb/` package** shaped like `postgres/`: `duckdb.core` with `open` and `close!` plus re-exports of `sql.core`. It also has a small Go shim, `duckdb/shim`, whose `ScanRow` converts DuckDB's Go types into plain let-go values.
2. **A scanner hook in `sql.core`** so a driver package can supply its own row scanner. It is needed because `sql.core` hard-codes `shim/ScanRow` today (`sql/src/sql/core.lg:108,125`).
3. **`examples/with-duckdb/` in lgx**, added after `duckdb-v0.1.0` is tagged. It consumes the package through a git coord.

### Key decisions

1. **The README's "Pure Go only" driver rule gets an explicit DuckDB exception.** No pure-Go DuckDB exists. The exception is worded like the existing wails paragraph: a C toolchain is required, builds are native only, and cross builds fail at build time. `duckdb/README.md` states this in its first section.
2. **The hook is a connectable key, `:sql/scan-row`.** It is not an `:sql/opts` entry, because it is driver behaviour, not a per-call user preference. Contract: a fn of one `*sql.Rows` (already advanced with `.Next`) that returns the current row's values in column order, as anything `zipmap` accepts. If absent, `sql.shim/ScanRow` is used. `begin-tx` copies it onto the tx connectable so transactions, and ragtime on top of them, keep the conversion. A bare handle has no hook. This changes only `.lg` code, so `sql` needs a package tag (`sql-v0.2.0`) and no shim release. sqlite and postgres are unaffected.
3. **Conversion runs in Go, in one boundary crossing per row.** `duckdb.shim/ScanRow` scans into `[]any`, reads `rows.ColumnTypes()` for the DuckDB type names, converts each value, and returns a let-go vector (`vm.Value`). Building let-go values directly is the only way to get keyword keys for STRUCT, and it sidesteps the UBIGINT wrap in `BoxValue`.
4. **The conversion table.** This is the contract that the tests assert:

   | Go value from the driver (top-level column type) | let-go value |
   |---|---|
   | `nil` | `nil` |
   | `bool`, `string`, int/uint kinds that fit in int64, `float32/64` | native boolean / string / int / float |
   | `uint64` above int64 max | decimal string |
   | `*big.Int` (HUGEINT, UHUGEINT, `sum()`, BIGNUM) | int when `IsInt64()`, else decimal string |
   | `duckdb.Decimal` | exact string via `Decimal.String()`, e.g. `"12.34"` (postgres returns `numeric` the same way) |
   | `time.Time`, column `DATE` | `"2006-01-02"` |
   | `time.Time`, column `TIME` | `"15:04:05.999999"` (trailing fractional zeros trimmed) |
   | `time.Time`, column `TIMETZ` | `"15:04:05.999999Z07:00"` |
   | `time.Time`, column `TIMESTAMP`, `TIMESTAMP_S/MS/NS` | `"2006-01-02T15:04:05.999999999"` (no zone; the value is naive) |
   | `time.Time`, column `TIMESTAMPTZ` | UTC, `time.RFC3339Nano`, e.g. `"2026-09-23T08:11:12Z"` |
   | `time.Time` nested inside LIST/STRUCT/MAP (no column type) | UTC, `time.RFC3339Nano` |
   | `[]byte`, column `UUID` | canonical `8-4-4-4-12` lowercase string |
   | `[]byte`, any other column (BLOB, …) | let-go string of the raw bytes (what boxing does today) |
   | `duckdb.Interval` | `{:months m :days d :micros u}` |
   | `[]any` (LIST, ARRAY) | vector, elements converted recursively |
   | `map[string]any` (STRUCT, JSON object) | map with **keyword** keys, values converted recursively |
   | `duckdb.OrderedMap` (MAP) | let-go map, keys and values converted recursively |
   | JSON column | the driver already decodes it to Go values, which are converted as above (numbers arrive as `float64`) |
   | anything else (`duckdb.Union`, `duckdb.Bit`, …) | `vm.BoxValue` fallback, the same opaque box as today |

   Strings for dates and times: they are JSON-safe, sort correctly, and don't depend on let-go having a date type.
5. **Driver version is pinned in two places, kept equal.** `duckdb/lgx.edn` names `github.com/duckdb/duckdb-go/v2 {:go/version "v2.10505.0"}` so the pin is visible, following sqlite and postgres. The shim's `go.mod` requires the same version, because the shim imports the driver's types. MVS takes the higher of the two, so a consumer can still bump the driver with their own coord.
6. **Release order follows the existing README "Releasing" section.** Develop with `duckdb/shim {:go/local "shim"}`. After the PR merges: tag `duckdb/shim/v0.1.0`, flip the coord to `{:go/version "v0.1.0"}`, then tag `duckdb-v0.1.0` and `sql-v0.2.0` on the flip commit.
7. **CI's shim override becomes generic.** `.github/workflows/test.yml` has a `sql/shim/`-only step that swaps the released shim for the checked-out one. It becomes a loop over every `<pkg>/shim/` path that changed. `changed-packages.sh` needs no change: `duckdb/` has `test/`, a change to `sql/` already tests every package, and ubuntu runners have gcc.
8. **`with-duckdb` lives at `lgx/examples/with-duckdb/`**, not under `examples/clojure-libs/` (that directory is for Clojure libraries). It is one small, assertive `main.lg` in an analytics style: in-memory database, batched ingest of synthetic page views, three analytics queries. It has no HoneySQL and no web server, since web-app already covers those.

### Components

- `sql/src/sql/core.lg`: `read-rows!` and `read-one-row!` take the scan fn; `execute*` resolves it from the connectable; `begin-tx` copies it.
- `duckdb/shim/shim.go`: `ScanRow` plus the conversion, registered as the `duckdb.shim` namespace. Uses the same `init` pattern as `sql/shim/shim.go`, including the comment on why it avoids `rt.RegisterInstaller`.
- `duckdb/src/duckdb/core.lg`: `open`, `close!` and the re-exports. `open` returns `{:sql/handle h :sql/opts (merge {:keys :unqualified} opts) :sql/scan-row shim/ScanRow}`.
- `duckdb/test/duckdb/core_test.lg`: the conversion table as tests, plus a transaction test.
- `duckdb/example/main.lg`: a ✓/✗ end-to-end tour in the style of `sqlite/example/main.lg`.

### Testing strategy

- `lgx test` in `duckdb/` asserts the conversion table and hook propagation. The `sql` package cannot test the hook alone, because its test runtime links no driver and `*sql.Rows` cannot be faked. So the hook is covered through duckdb, and regressions through `sqlite/example` and `ragtime` (which tests over sqlite).
- `lgx run` and `lgx build && ./bin/app` in `duckdb/example`. The build is the check on the AOT path.
- `lgx run` and `lgx build` in `lgx/examples/with-duckdb`, against the pushed tag.

### Out of scope

- DuckDB's Appender API (bulk insert via `sql.Conn.Raw`). Batched multi-row `VALUES` is fast enough for a lightweight app.
- Converting nested UUID and DATE values using the child type: nested values carry no column type, so they get the generic rules above.
- Fixing let-go's `BoxValue` uint64 wrap upstream. The shim works around it; Task 11 records it.

---

## File Structure

**letgo-packages**

| File | Action | Responsibility |
|---|---|---|
| `sql/src/sql/core.lg` | Modify | `:sql/scan-row` hook: resolve, use, carry into tx |
| `sql/README.md` | Modify | Document the hook under "The API", for driver authors |
| `duckdb/lgx.edn` | Create | `../sql` dep, driver coord, shim coord (`:go/local` while developing) |
| `duckdb/shim/go.mod` | Create | Module `github.com/abogoyavlensky/letgo-packages/duckdb/shim`; requires let-go `v0.0.0` and duckdb-go `v2.10505.0` |
| `duckdb/shim/shim.go` | Create | `ScanRow` + conversion, `duckdb.shim` ns registration |
| `duckdb/src/duckdb/core.lg` | Create | `open` / `close!` / re-exports |
| `duckdb/test/duckdb/core_test.lg` | Create | Conversion table + tx propagation tests |
| `duckdb/example/lgx.edn` | Create | `{:local/root ".."}`, `:built`, `1.13.0` |
| `duckdb/example/main.lg` | Create | Assertive end-to-end tour |
| `duckdb/README.md` | Create | Usage, cgo requirements, value table, known limits |
| `README.md` | Modify | Package table row; "Rules for driver packages" exception; shim list in "Releasing" |
| `.github/workflows/test.yml` | Modify | Generic `<pkg>/shim/` override |

**lgx**

| File | Action | Responsibility |
|---|---|---|
| `examples/with-duckdb/lgx.edn` | Create | Git coord on `duckdb-v0.1.0`, `:built`, `1.13.0`, `:paths []` |
| `examples/with-duckdb/.mise.toml` | Create | Copy of `examples/web-app/.mise.toml` (go 1.27.1, lgx 0.3.2) |
| `examples/with-duckdb/main.lg` | Create | Batched ingest + analytics queries with assertions |
| `examples/with-duckdb/README.md` | Create | What it shows, how to run it, the cgo note |
| `README.md` | Modify | "Examples" list entry |
| `docs/GO-ECOSYSTEM.md` | Modify | "Where we are": the shipped package list |
| `docs/knowledge-base/lgx-go-wrappers.md` | Modify | "Known limits": name duckdb next to wails as a cgo package |
| `docs/issues/boxvalue-uint64-wrap.md` (+ `docs/issues/README.md` index) | Create / Modify | Record the let-go uint64 boxing wrap |

---

## Environment notes for the executor

- Tools come from mise. In a directory without `.mise.toml`, run `eval "$(mise env -s bash)"` from a directory that has one (for example `examples/web-app` in lgx), or run `mise install` first if versions are missing. `go` is not on the bare `PATH`.
- Use a throwaway `LGX_HOME` for a guaranteed-cold runtime only when a step asks for it. Otherwise the default `~/.lgx` cache is fine.
- The duckdb runtime build takes about 40 s cold. With the shim as `:go/local` every command re-runs the incremental build (about 1 s or more), which is expected.

---

### Task 1: Branch letgo-packages and prove the shim mechanics

This is the riskiest assumption, so it goes first: a `:go/local` shim that returns a let-go vector built with `vm` constructors, including keyword-keyed maps, reaches let-go intact.

**Files:**
- Create: `duckdb/lgx.edn`, `duckdb/shim/go.mod`, `duckdb/shim/shim.go` (minimal version)
- Create (temporary, not committed): `duckdb/example/main.lg` with a smoke check

- [x] **Step 1: Branch**
  Run: `cd ~/Projects/letgo-packages && git checkout master && git pull && git checkout -b duckdb`

- [x] **Step 2: Write `duckdb/lgx.edn`**
  `:paths ["src"]`, `:lg-runtime :built`, `:lg-version "1.13.0"` (for the package's own `lgx test`, matching `sql/lgx.edn`), and three `:deps`:
  `abogoyavlensky/letgo-sql {:local/root "../sql"}`, `github.com/duckdb/duckdb-go/v2 {:go/version "v2.10505.0"}`, and `github.com/abogoyavlensky/letgo-packages/duckdb/shim {:go/local "shim"}`. Comment each one in the style of `postgres/lgx.edn`. The driver comment must say it is cgo, not pure Go.

- [x] **Step 3: Write `duckdb/shim/go.mod`**
  Model it on `sql/shim/go.mod`: the module path above, `go 1.26`, `require github.com/nooga/let-go v0.0.0` (the deliberate placeholder) and `require github.com/duckdb/duckdb-go/v2 v2.10505.0`.

- [x] **Step 4: Write a minimal `duckdb/shim/shim.go`**
  Package `shim`, with `ScanRow(rows *sql.Rows) (vm.Value, error)`. It scans into `[]any` like `sql/shim/shim.go` and returns a vector built with `vm.NewArrayVector` (`let-go/pkg/vm/vector.go:353`). For now, convert only `map[string]any` into a map with keyword keys, and fall back to `vm.BoxValue(reflect.ValueOf(v))` for everything else. Register `duckdb.shim` in `init` exactly as `sql/shim/shim.go` does. Look up the right keyword and map constructors in `let-go/pkg/vm/keyword.go` and `persistent_map.go` / `map.go`, and use whatever let-go's own code uses to build a keyword-keyed map.

- [x] **Step 5: Smoke check**
  Create a temporary `duckdb/example/lgx.edn` (`:paths []`, `:main "main.lg"`, `:lg-runtime :built`, `:lg-version "1.13.0"`, `:deps {abogoyavlensky/letgo-duckdb {:local/root ".."}}`). Create a `main.lg` that opens `(sql/Open "duckdb" "")` directly, runs `select {'a': 1, 'b': 'x'} as s, 42 as n`, calls `(duckdb.shim/ScanRow rows)` after `(.Next rows)`, and prints `(pr-str row)` and `(vector? row)`.
  Run: `cd duckdb/example && lgx run`
  Expected: `[{:a 1, :b "x"} 42]` and `true`. If the vector or the keywords do not survive, stop and rethink decision 3 before building on it.

- [x] **Step 6: No commit yet.** The smoke files are replaced in Task 5.

> Deviation: The driver returns STRUCT as an unordered Go `map[string]any`, so the shim sorts its keys before building the keyword map (deterministic output); maps are built with `vm.NewArrayMap`.

### Task 2: The `:sql/scan-row` hook in `sql.core`

**Files:**
- Modify: `sql/src/sql/core.lg`
- Modify: `sql/README.md`

- [x] **Step 1: Implement**
  - `read-rows!` and `read-one-row!` take a third argument, `scan`, and call `(scan rows)` where they call `(shim/ScanRow rows)` today.
  - `execute*` passes `(or (:sql/scan-row conn) shim/ScanRow)` into the reader.
  - `begin-tx` adds `:sql/scan-row (:sql/scan-row conn)` to the tx map. nil falls back to the default.
  - Update the namespace header comment that describes the connectable shape (`core.lg:19-20`) to mention the optional key.

- [x] **Step 2: Document**
  In `sql/README.md`, add a short "Driver hook: `:sql/scan-row`" subsection under "The API". Cover the contract from decision 2 (input `*sql.Rows` positioned on a row; output values in column order), the default, tx propagation, and that duckdb is the user.

- [x] **Step 3: Regression-check the existing consumers**
  Run: `cd sql && lgx test`. Expected: all `returns-rows?` tests pass.
  Run: `cd sqlite/example && lgx run`. Expected: `all checks passed`.
  Run: `cd ragtime && lgx test`. Expected: pass.
  (`postgres/example` needs a live database. Run it only if `$DATABASE_URL` or a local postgres is available; otherwise note it as skipped.)

- [x] **Step 4: Commit**
  `git add sql && git commit -m "sql: let a driver supply its row scanner via :sql/scan-row"`

> Deviation: postgres/example skipped: no database available locally.

### Task 3: Conversion tests (failing)

**Files:**
- Create: `duckdb/src/duckdb/core.lg` (the veneer; needed so tests can open a connection)
- Create: `duckdb/test/duckdb/core_test.lg`

- [x] **Step 1: Write `duckdb/src/duckdb/core.lg`**
  Mirror `postgres/src/postgres/core.lg`: header comment, `(def ^:private driver "duckdb")`, `open [path]` / `[path opts]` (docstring: `""` or `":memory:"` for in-memory, otherwise a file path; one process holds the file lock), `close!`, and the re-exports of `execute!`, `execute-one!`, `query` and `with-transaction`. `open` returns the map from the Design "Components" section, with `:sql/scan-row` set to `duckdb.shim/ScanRow` (require `[duckdb.shim :as shim]`).

- [x] **Step 2: Write the tests**
  Follow `sql/test/sql/core_test.lg` for ns and require style. Use one shared in-memory connection and a helper `(v expr)` that runs `(str "select " expr " as v")` through `execute-one!` and returns `:v`. For expressions with their own `FROM`, write the alias in the expression and call `execute-one!` directly. One `deftest` per row:

  | Expression | Expected |
  |---|---|
  | `42::INTEGER` | `42` |
  | `42::UBIGINT` | `42` |
  | `18446744073709551615::UBIGINT` | `"18446744073709551615"` |
  | `sum(x) as v from (values (1::INTEGER), (2)) t(x)` | `3` |
  | `170141183460469231731687303715884105727::HUGEINT` | `"170141183460469231731687303715884105727"` |
  | `1.5::DOUBLE` | `1.5` |
  | `12.34::DECIMAL(10,2)` | `"12.34"` |
  | `'hello'` / `true` / `NULL` / `'b'::ENUM('a','b')` | `"hello"` / `true` / `nil` / `"b"` |
  | `DATE '2026-09-23'` | `"2026-09-23"` |
  | `TIME '10:11:12'` | `"10:11:12"` |
  | `TIMESTAMP '2026-09-23 10:11:12'` | `"2026-09-23T10:11:12"` |
  | `TIMESTAMP '2026-09-23 10:11:12.5'` | `"2026-09-23T10:11:12.5"` |
  | `TIMESTAMPTZ '2026-09-23 10:11:12+02'` | `"2026-09-23T08:11:12Z"` |
  | `'4b5c0e53-7a3f-4a8e-9a55-1f1d0c7f4e11'::UUID` | `"4b5c0e53-7a3f-4a8e-9a55-1f1d0c7f4e11"` |
  | `INTERVAL 90 MINUTE` | `{:months 0 :days 0 :micros 5400000000}` |
  | `[1, 2, 3]` | `[1 2 3]` |
  | `{'a': 1, 'b': [1, 2]}` | `{:a 1 :b [1 2]}` |
  | `MAP {'k1': 1, 'k2': 2}` | `{"k1" 1 "k2" 2}` |
  | `[TIMESTAMP '2026-09-23 10:11:12']` | `["2026-09-23T10:11:12Z"]` (nested rule) |
  | `'{"a": 1}'::JSON` | `{:a 1.0}` |
  | `[1, 2]::INTEGER[2]` (ARRAY) | `[1 2]` |
  | `TIMETZ '10:11:12+02'` | `"10:11:12+02:00"` |
  | `TIMESTAMP_NS '2026-09-23 10:11:12.123456789'` | `"2026-09-23T10:11:12.123456789"` |
  | `'\xAA\xBB'::BLOB` | a 2-character string (`(count v)` = 2); raw bytes, documented, not converted |
  | `340282366920938463463374607431768211455::UHUGEINT` | `"340282366920938463463374607431768211455"` |

  Plus two hook tests:
  - `with-transaction` over the connection, running the `sum()` query on `tx`, asserts `3`. This proves `begin-tx` carries `:sql/scan-row`.
  - `query` returning multiple rows asserts `[{:n 3}]`-shaped maps with converted values, which covers `read-rows!` as well as `read-one-row!`.

- [x] **Step 3: Run the tests to see them fail**
  Run: `cd duckdb && lgx test`
  Expected: the build succeeds; conversion tests FAIL on opaque values (for example `<go.*big.Int 3>`, `<go.time.Time …>`); plain scalar tests pass. If the runner cannot find `test/`, check how `sql/` runs its suite and match it.

> Deviation: Test names avoid shadowing clojure.core fns (`list`, `double`, ... got a descriptive suffix) after the first run broke on the shadowed `list`.

### Task 4: Implement the conversion

**Files:**
- Modify: `duckdb/shim/shim.go`

- [x] **Step 1: Implement `ScanRow` and a `convert(v any, colType string) vm.Value`**
  - `ScanRow` reads `rows.ColumnTypes()` once per call, takes `DatabaseTypeName()` per column, scans, and converts each value with its column's type name. Nested values recurse with `colType == ""`.
  - Implement the Design table (decision 4) exactly. DuckDB type names come from `typeToStringMap` in duckdb-go `type.go` (`"DATE"`, `"TIME"`, `"TIMETZ"`, `"TIMESTAMP"`, `"TIMESTAMP_S"`, `"TIMESTAMP_MS"`, `"TIMESTAMP_NS"`, `"TIMESTAMPTZ"`, `"UUID"`, …); DECIMAL arrives as `"DECIMAL(w,s)"`.
  - To trim trailing fractional zeros, use Go layouts with `.999999` / `.999999999`.
  - UUID: format the 16 bytes as `%x` groups 4-2-2-2-6 bytes.
  - `duckdb.OrderedMap`: iterate `Keys()` and `Values()`.
  - Header doc comment: explain *why* each conversion exists (the spike's findings: `sum()` returning `*big.Int`, the UBIGINT wrap, opaque time) in the voice of `sql/shim/shim.go`.

- [x] **Step 2: Vet**
  The shim cannot build standalone (let-go `v0.0.0`). Rely on the runtime build: `cd duckdb && lgx test` compiles it. For quicker iteration, a `go.work` in `.tmp/` pointing at the shim and a let-go checkout (`~/Projects/let-go`) is fine. Do not commit it.

- [x] **Step 3: Run tests to verify they pass**
  Run: `cd duckdb && lgx test`
  Expected: all pass. If a row's expectation proves wrong because of driver behaviour (for example `TIME` arriving with a zone), fix the shim if the table's intent is achievable. Otherwise update the table **and** the README value table together, and say so in the task report.

- [x] **Step 4: Commit**
  `git add duckdb/lgx.edn duckdb/shim duckdb/src duckdb/test && git commit -m "duckdb: driver package with a value-converting shim"`

> Deviation: Codex fixup: TIMETZ offsets with seconds keep them (`+02:00:30`). Nested UUIDs still arrive as raw bytes (Codex P2): out of scope per the plan, documented as a known limit.

### Task 5: `duckdb/example`

**Files:**
- Create: `duckdb/example/lgx.edn` (keep from Task 1, with the require of `sqlite.core` swapped for `duckdb.core`)
- Create: `duckdb/example/main.lg` (replace the smoke check)

- [x] **Step 1: Write the example**
  Follow `sqlite/example/main.lg` (`check` helper, ✓/✗, throw on failure, `(when-not *compiling-aot* (-main))`, `try`/`finally close!`). Cover:
  - DDL, parameterized inserts and `{:sql/update-count n}`;
  - `query` and `execute-one!`, including nil on an empty result;
  - `with-transaction` commit and rollback;
  - `:keys :unqualified-lower`;
  - one analytics query (`date_trunc` + `count(distinct …)` + `sum()`) asserting plain ints and date strings;
  - a file-backed database at `/tmp/lgx-duckdb-example.duckdb` (removed at start), written, closed and reopened.

- [x] **Step 2: Run it**
  Run: `cd duckdb/example && lgx run`
  Expected: all ✓, `all checks passed`.

- [x] **Step 3: AOT path**
  Run: `cd duckdb/example && lgx build && ./bin/app`
  Expected: same output. The build does not execute `-main`.

- [x] **Step 4: Commit**
  `git add duckdb/example && git commit -m "duckdb: end-to-end example"`

> Deviation: Added `duckdb/example/.gitignore` (`bin/`), matching the other examples - the repo root ignores only `.tmp/`.

### Task 6: README, CI, and the pure-Go rule

**Files:**
- Create: `duckdb/README.md`
- Modify: `README.md`, `.github/workflows/test.yml`

- [x] **Step 1: `duckdb/README.md`**
  Model it on `postgres/README.md`:
  - a usage snippet;
  - a **Requirements** section up front: cgo and a C toolchain (gcc/clang, Xcode CLT on macOS); native builds only; `lgx build --target` fails at build time; the binary grows by about 75 MB and links `libstdc++`/glibc dynamically (use debian-slim, not alpine or scratch); the first runtime build takes about 40 s;
  - **Value types**: the decision 4 table;
  - **Ingest tip**: batch multi-row `VALUES`, with the spike numbers;
  - **Known limits**: nested UUID/DATE, BLOB as a raw-byte string, UNION/BIT boxed, no Appender, single-process file lock.

- [x] **Step 2: Root `README.md`**
  - Add a `duckdb/` row to the package table.
  - Rewrite "Rules for driver packages" so pure Go stays the rule, and DuckDB is named as the one exception with the reason (no pure-Go implementation exists) and the price, parallel to the wails paragraph.
  - In "Releasing", change "Only `sql` and `wails` have a shim" to include `duckdb`, and add `duckdb/shim/go.mod` to the paragraph about the `v0.0.0` let-go require.

- [x] **Step 3: CI shim override**
  In `.github/workflows/test.yml`, replace the `sql/shim/`-specific `if grep …; sed …` block with a loop. The loop must be a no-op, not a failure, under the step's `set -euo pipefail` when `$CHANGED_PATHS_FILE` does not exist (on a package-tag run `changed-packages.sh` exits before writing it) or when no `<pkg>/shim/` path matches. Guard with `[ -f "$CHANGED_PATHS_FILE" ]`, and keep the `grep` inside a construct where a no-match exit status is tolerated (for example `grep … || true`). For each distinct `<pkg>` where `^<pkg>/shim/` appears in `$CHANGED_PATHS_FILE`, run the same `sed` on `<pkg>/lgx.edn`, turning `<pkg>/shim {:go/version "…"}` into `{:go/local "shim"}`. Echo what was flipped. Keep the comment explaining why.
  Verify locally by simulation, running the loop under `bash -euo pipefail` against scratch copies of the `lgx.edn` files in three cases: a paths file listing `duckdb/shim/shim.go` and `sql/shim/shim.go` (only `:go/version` coords flip); a paths file with no shim paths (nothing flips, exit 0); and `CHANGED_PATHS_FILE` pointing at a missing file (nothing flips, exit 0). (duckdb's coord is still `:go/local` at this point, so it is a no-op there, which is fine.)

- [x] **Step 4: Commit**
  `git add duckdb/README.md README.md .github/workflows/test.yml && git commit -m "duckdb: README, driver-rule exception, generic CI shim override"`

### Task 7: Review, push, PR (ask first)

- [x] **Step 1: Review** with /code-review or /review-with-codex on the `duckdb` branch against `master`. Fix what is real.
- [x] **Step 2: Full regression pass**
  `cd sql && lgx test`, `cd duckdb && lgx test`, `cd duckdb/example && lgx run`, `cd sqlite/example && lgx run`, `cd ragtime && lgx test`. All green.
- [x] **Step 3: Ask the user** before `git push -u origin duckdb` and `gh pr create`. When the PR exists, register it with `link_pull_request`.
- [x] **Step 4: Wait for CI.** It should test every package, because `sql/` changed. The user merges.

> Deviation: Merged as letgo-packages#3 (squash, `72615bd`) after green CI, which ran the duckdb suite (27 tests) on the ubuntu runner.

### Task 8: Release (ask before every tag push)

Follows letgo-packages README "Releasing"; run on `master` after the merge.

- [x] **Step 1: Tag the shim.** `git checkout master && git pull`, then `git tag duckdb/shim/v0.1.0` on the merge commit. **Ask**, then `git push origin duckdb/shim/v0.1.0`.
- [x] **Step 2: Verify through the proxy.** In a throwaway module under `.tmp/`: `go mod init x && go get github.com/nooga/let-go@v1.13.0 && go get github.com/abogoyavlensky/letgo-packages/duckdb/shim@v0.1.0`. It must report plain `v0.1.0`, not a pseudo-version.
- [x] **Step 3: Flip the coord.** In `duckdb/lgx.edn`, set the shim to `{:go/version "v0.1.0"}` and reword its comment to match `sql/lgx.edn`. Run `cd duckdb && lgx test` and `cd duckdb/example && lgx run`: green, and a second run is a runtime cache hit (no rebuild line).
- [x] **Step 4: Commit and land the flip.** `git commit -am "duckdb: pin the released shim v0.1.0"`. **Ask** whether to push directly to `master` or through a small PR.
- [x] **Step 5: Package tags.** On the flip commit: `git tag duckdb-v0.1.0 && git tag sql-v0.2.0`. **Ask**, then push both. CI runs on the tags (`tags: ['*-v*']`); confirm green.

> Deviation: The coord switch (`6014d8c`) went straight to `master`, as the earlier shim release did. Tag CI results are recorded in the summary.

### Task 9: `examples/with-duckdb` in lgx

**Files:**
- Create: `examples/with-duckdb/{lgx.edn,.mise.toml,main.lg,README.md}`

- [x] **Step 1: `lgx.edn`**
  `:paths []`, `:main "main.lg"`, `:lg-runtime :built`, `:lg-version "1.13.0"`, `:targets {:bin {:out "bin/with-duckdb"}}`, and `:deps {abogoyavlensky/letgo-duckdb {:git/url "https://github.com/abogoyavlensky/letgo-packages" :git/tag "duckdb-v0.1.0" :deps/root "duckdb"}}`. Add a comment in the style of `examples/web-app/lgx.edn` explaining `:built` and cgo.
  Copy `.mise.toml` from `examples/web-app/`.

- [x] **Step 2: `main.lg`**
  - In-memory `(db/open "")`, then an `events` table (`ts TIMESTAMP, visitor VARCHAR, path VARCHAR, referrer VARCHAR, duration_ms INTEGER`).
  - A small `insert-batch!` that builds one multi-row `VALUES` statement for a seq of event vectors, and an ingest of 1000 deterministic synthetic events in batches of 200 (timestamps as strings cast with `?::TIMESTAMP`).
  - Three queries, each printed as a small table: daily views and uniques (`date_trunc('day', ts)::DATE` gives `"2026-09-01"` strings); top pages with `quantile_cont` p50/p95; total time on site via `sum(duration_ms)`, a plain int with no cast.
  - Assertions on known totals: 1000 events, 7 days, the exact `sum`, and `(string? day)`. Throw with a clear message on mismatch.
  - `(when-not *compiling-aot* (-main))`.
  Keep it well under 100 lines, with comments explaining the batching choice and the no-cast `sum()`.

- [x] **Step 3: Run it**
  Run: `cd examples/with-duckdb && mise install && lgx run`
  Expected: the three tables print and assertions pass. Then `lgx build && ./bin/with-duckdb` gives the same output.

- [x] **Step 4: `README.md`**
  A few lines: what it shows, `lgx run`, the cgo/native-only note linking to the package README, and why batching.

- [x] **Step 5: Commit**
  `git add examples/with-duckdb && git commit -m "examples: with-duckdb, analytics over the letgo-packages duckdb package"`

> Deviation: Done before the release (Tasks 7-8), at the user's request. `lgx.edn` carries the final `duckdb-v0.1.0` git coord; it was verified (`lgx run`, `lgx build` + binary) with that coord temporarily swapped for `{:local/root ".../letgo-packages/duckdb"}`, then restored. The example cannot resolve for others until the tag is pushed, so the lgx PR must not merge before Task 8. Quantiles are `round`ed in SQL to keep float noise out of the output.

### Task 10: lgx docs (same-PR rule)

**Files:**
- Modify: `README.md` (Examples list), `docs/GO-ECOSYSTEM.md` ("Where we are"), `docs/knowledge-base/lgx-go-wrappers.md` ("Known limits")

- [x] **Step 1: Edit**
  - README Examples: add `examples/with-duckdb/`, an in-process analytics database via the letgo-packages `duckdb` package (cgo, native builds).
  - GO-ECOSYSTEM "Where we are": add `duckdb` to the shipped list, with one clause noting it is the one cgo driver.
  - lgx-go-wrappers "Known limits", the cgo bullet: name duckdb alongside wails.

- [x] **Step 2: Commit**
  `git add README.md docs && git commit -m "docs: the duckdb package and with-duckdb example"`

### Task 11: Record the let-go uint64 boxing wrap

**Files:**
- Create: `docs/issues/boxvalue-uint64-wrap.md`; Modify: `docs/issues/README.md`

- [x] **Step 1: Write the issue**
  Follow the format of the existing `docs/issues/*.md` files. Cover:
  - where: `let-go/pkg/vm/value.go:192-193`, where `Int(v.Uint())` wraps any `uint64` above `math.MaxInt64`;
  - repro: DuckDB `18446744073709551615::UBIGINT` returns `-1`;
  - workaround: convert in a shim, as `duckdb/shim` does;
  - possible fixes: box to a big integer or string, or error.

  Add it to the index in `docs/issues/README.md`.

- [x] **Step 2: Commit**
  `git add docs/issues && git commit -m "docs(issues): let-go BoxValue wraps uint64 above MaxInt64"`

> Deviation: The issue proposes boxing to let-go's existing `vm.BigInt` (found while writing it) rather than only an error.

### Task 12: lgx PR (ask first)

- [x] **Step 1:** Mark this plan `**Status: completed YYYY-MM-DD.**` under the title, and commit, so the PR includes it.
- [x] **Step 2:** Rename the branch if the user wants something clearer (`git branch -m with-duckdb`). **Ask**, then push and `gh pr create`, and register it with `link_pull_request`.

> Deviation: Branch renamed from `duckdb-discussion` to `with-duckdb` before pushing; it had never been pushed.

---

## Completion summary

**Implemented.**
- letgo-packages: the `duckdb` package (veneer, value-converting Go shim, 27 tests, end-to-end example, README), the `:sql/scan-row` hook in `sql.core`, the README exception to the pure-Go driver rule, and a CI shim override that works for any package.
- Merged as letgo-packages#3 and released as `duckdb/shim/v0.1.0`, `duckdb-v0.1.0` and `sql-v0.2.0`. The shim resolves through the Go module proxy as plain `v0.1.0`.
- lgx: `examples/with-duckdb` (checked against the published tag with `lgx run` and `lgx build` + binary), README/GO-ECOSYSTEM/lgx-go-wrappers updates, and the upstream issue `docs/issues/boxvalue-uint64-wrap.md`. lgx's own suite passes (380 e2e assertions).

**Issues found along the way.**
- Codex's only must-fix was that TIMETZ offsets with seconds were truncated; fixed.
- Codex's P2 on nested UUIDs is a documented limit with a SQL cast workaround.
- Running `strip` on a finished `lg -b` binary silently removes the bundled program and leaves a bare REPL. Found while measuring binary size; it motivates stripping during lgx's runtime build instead (a separate follow-up).
- let-go has `vm.BigInt`, which the shim could return instead of decimal strings for integers past int64. This was not taken up here; strings match how postgres returns `numeric`.

**All deviations.**
- Task 1: STRUCT keys are sorted, because Go maps are unordered.
- Task 2: postgres/example skipped (no database available).
- Task 3: test names renamed so they don't shadow `clojure.core` fns.
- Task 4: TIMETZ offset-seconds fixup; nested UUID left as a documented limit.
- Task 5: added `example/.gitignore`.
- Task 7: squash merge.
- Task 8: the coord switch pushed straight to `master`.
- Task 9: the example was written before the release, at the user's request, and verified through a temporary `:local/root`.
- Task 11: the issue proposes `vm.BigInt`.
- Task 12: branch renamed.

**What the plan could have specified better:** it should have noted that the lgx example could be built and verified against a temporary `:local/root` before the tag existed, rather than ordering it strictly after the release.
