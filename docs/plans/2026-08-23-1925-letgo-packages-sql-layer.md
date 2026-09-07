# letgo-packages SQL Layer Implementation Plan

> **STATUS: COMPLETE** — see the summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single-driver sqlite wrapper into a driver-agnostic SQL layer for let-go — a shared `sql/` package with a next.jdbc-shaped API, plus thin `sqlite/` and `postgres/` drivers — so a let-go web app can talk to either database through one interface.

**Tech Stack:** let-go (`.lg`), Go (`database/sql` + a small shim module), `modernc.org/sqlite` v1.57.0 (pure Go), `github.com/jackc/pgx/v5` v5.10.0 (pure Go, via its `stdlib` adapter), driven by lgx's `:go/*` coord family.

---

## Design

### Where this starts

`/Users/andrew/Projects/letgo-packages/sqlite/` currently holds a working but sqlite-only wrapper: `lgx.edn`, `src/sqlite/core.lg` (`open` / `close!` / `query` / `execute!`), `shim/` (a Go module with `ScanRow`, `Query`, `Exec`), and `example/`. It is verified end to end but nothing is tagged, so every signature is still free to change. That is the reason to do this now: after the first tag, changing `query`'s parameter type is a breaking change.

### The split

Three packages in the monorepo, driver-agnostic core plus thin drivers:

```
sql/        the shim (Go) + the veneer (.lg) + database/sql bindings
            :deps {database/sql {:go/interop "sql"}}
sqlite/     :deps {abogoyavlensky/letgo-sql {:local/root "../sql"}
                   modernc.org/sqlite {:go/version "v1.57.0"}}
postgres/   :deps {abogoyavlensky/letgo-sql {:local/root "../sql"}
                   github.com/jackc/pgx/v5/stdlib {:go/version "v5.10.0"}}
```

lgx's transitive `:go/*` collection makes this work with no extra machinery: depending on `postgres/` pulls `sql/`'s `database/sql` interop coord up automatically, and the custom runtime links the driver and generates the bindings in one build.

Note `github.com/jackc/pgx/v5/stdlib` is a *package* path whose *module* is `github.com/jackc/pgx/v5`. lgx never hand-writes a require for `:go/version` coords precisely so `go get` can resolve the owning module itself, so this needs no special handling — but it is the first real dep exercising that path, so verify it.

Both drivers are pure Go. That is a requirement, not a coincidence: cgo would break the cross-compilation story (see the lgx cross-compilation plan) and force a C toolchain on every user. Record this as a rule in the repo README.

### The API

next.jdbc's shape, because it is what Clojure developers already know and it ports cleanly onto `database/sql`:

```clojure
(sql/execute!     connectable [sql & params])       ; => [{...} ...]   all rows
(sql/execute!     connectable [sql & params] opts)
(sql/execute-one! connectable [sql & params])       ; => {...} or nil  first row
(sql/execute-one! connectable [sql & params] opts)
(sql/query        connectable [sql & params])       ; sugar for execute!
(sql/with-transaction [tx connectable] body...)     ; macro
```

`execute!` runs anything. A SELECT returns a vector of row maps; DML returns `[{:sql/update-count 1}]`. `execute-one!` returns the first row or `nil`, and `{:sql/update-count 1}` for DML.

**How `execute!` decides which it is.** next.jdbc gets this free from JDBC's `execute()`, which reports whether a result set exists. `database/sql` has no equivalent, and the two paths are mutually exclusive: `Query` cannot produce `RowsAffected`, `Exec` discards rows, and running `Exec` then `Query` would execute the statement twice. So the decision has to be made *before* execution, from the statement itself:

- Strip leading whitespace and SQL comments, then match the first keyword case-insensitively. `SELECT`, `WITH`, `VALUES`, `TABLE`, `SHOW`, and `EXPLAIN` take the rows path.
- Otherwise, if the statement ends in a `RETURNING` clause, take the rows path — `INSERT ... RETURNING` is idiomatic Postgres and callers will hit it immediately.
- Otherwise take the update-count path.

This is a heuristic and is documented as one. `{:returns :rows}` or `{:returns :update-count}` in opts overrides it outright, which is the answer for anything the keyword match gets wrong (a `WITH ... INSERT` CTE, a stored-procedure call). The override is not an escape hatch bolted on later — it is what makes the heuristic acceptable, so it ships in the same task and gets its own tests.

A `WITH` statement whose final clause is an `INSERT` is the known false positive: it matches `WITH`, takes the rows path, and returns no update count. Document it next to the `:returns` option rather than trying to parse SQL properly.

Statements are `[sql-string & params]` vectors — the shape HoneySQL's `format` returns, so `(sql/execute! conn (honey/format q))` needs no glue.

Two deliberate departures from strict next.jdbc, both worth a second look at review time:

- **`query` is added as a thin alias for `execute!`.** next.jdbc has no `query` (that is `clojure.java.jdbc`), so this is added surface. It reads better at call sites and helps people arriving from either library; three lines. Drop it if the extra name is not worth it.
- **`plan` is not implemented.** next.jdbc's reducible streaming interface is real value for large result sets, but it needs a reduce protocol this layer does not have yet. YAGNI until someone hits a result set that does not fit in memory.

`{:sql/update-count n}` replaces the `{:rows-affected n}` the current sqlite veneer returns. Namespaced to match next.jdbc's `:next.jdbc/update-count` convention, which makes porting mechanical.

### Result keys

**Unqualified only.** This is a constraint, not a preference: Go's `sql.ColumnType` exposes `Name`, `DatabaseTypeName`, `ScanType`, `Nullable`, `Length`, and `DecimalSize` — and no table name. JDBC's `ResultSetMetaData.getTableName()` has no counterpart, so next.jdbc's `:people/name` is unobtainable through the portable API for *any* driver.

```clojure
(sql/execute! conn ["select id, name from people"])
;; => [{:id 1 :name "Ada"}]
```

The `:keys` option controls the transform:

- `:unqualified` (default) — column name to keyword, verbatim
- `:unqualified-lower` — lower-cased first, for Postgres's case folding
- any `String -> keyword` function — the escape hatch, standing in for next.jdbc's `:builder-fn`

`:qualified` stays a reserved name for a future per-driver implementation (pgx exposes field descriptors carrying table OIDs; SQLite has `sqlite3_column_table_name`, though whether modernc surfaces it is unchecked). Not in scope here.

Options are set on the connection at `open` and overridden per call, merged the way next.jdbc merges datasource opts with call opts.

**Where connection options live.** `sql/Open` returns a bare `*sql.DB`, which has nowhere to carry `:keys`. So `open` returns a let-go map — the *connectable* — rather than the raw handle:

```clojure
{:sql/handle <boxed *sql.DB or *sql.Tx>
 :sql/opts   {:keys :unqualified}}
```

Every API fn takes this map, merges per-call opts over `:sql/opts`, and passes `:sql/handle` to the shim. `with-transaction` binds a connectable of the same shape wrapping the `*sql.Tx`, carrying the parent's opts — which is what makes `execute!` behave identically inside and outside a transaction.

Accept a bare boxed handle too, treating it as `{:sql/handle h :sql/opts {}}`, so `sql/Open` output and anything obtained through raw method dispatch still work. Keep this normalization in one small fn every entry point calls.

### The `Connectable` interface — the load-bearing detail

`*sql.DB` and `*sql.Tx` are unrelated Go types, and `database/sql` declares no common interface. For `execute!` to work identically inside and outside a transaction — the property that makes `with-transaction` worth having — the shim declares one:

```go
type Connectable interface {
	Query(string, ...any) (*sql.Rows, error)
	Exec(string, ...any) (sql.Result, error)
}

func Query(c Connectable, q string, args []vm.Value) (*sql.Rows, error)
func Exec(c Connectable, q string, args []vm.Value) (sql.Result, error)
```

Both `*sql.DB` and `*sql.Tx` satisfy it.

**This is unproven and gets verified first.** No wrapped API in the let-go tree takes an interface parameter today. Unboxing a boxed `*sql.DB` yields a `*sql.DB`, which *is* assignable to `Connectable`, so `reflect.Call` should accept it — but "should" is not "does". Task 1 is a spike that answers this before any API is built on top. If it fails, the fallback is separate `QueryTx`/`ExecTx` shim functions plus a runtime type branch in the veneer: workable, uglier, and much cheaper to discover now.

### Shim value conversion

The shim converts at both boundaries, for reasons documented in the lgx go-runtimes knowledge base:

- `ScanRow` returns `[]vm.Value`, converting each column with `vm.ToLetGo`, because `vm.BoxValue` walks a slice by its *static* element type and a `[]any` would arrive as opaque boxes.
- `Query`/`Exec` take `[]vm.Value` and unbox them, because a let-go vector containing `nil` fails to convert to `[]any`.

If the let-go boxing-symmetry plan (`2026-08-23-1924-letgo-boxing-symmetry.md`) has landed by the time this runs, both conversions become unnecessary and the shim can use plain `[]any`. Task 2 checks which world it is in and picks accordingly — do not assume.

Driver-specific value quirks stay in the shim's conversion, not the veneer: SQLite returns TEXT as `[]byte`, and Postgres returns richer types (`time.Time`, numerics). Getting these right per driver is what the e2e tasks verify.

### Transactions

```clojure
(sql/with-transaction [tx conn]
  (sql/execute! tx ["insert into ..."])
  (sql/execute! tx ["update ..."]))
```

`.Begin` on the connection, run the body, `.Commit` on normal return, `.Rollback` on any throw, then rethrow. The macro returns the body's value.

**Commit and rollback errors need explicit handling.** Per the interop return-value rules, a Go function whose only result is `error` hands it back as an ordinary *value* and never throws — and `Commit`/`Rollback` are exactly that shape. A naive `(.Commit tx)` therefore discards a failed commit silently, which for a database layer is the worst kind of bug: the caller believes the write landed. So:

- A non-nil `Commit` error is raised as a throw carrying the error.
- A non-nil `Rollback` error must not mask the original exception that triggered the rollback — the body's failure is the useful one. Attach it as context or surface it separately; never let it replace the cause.

Confirm let-go's `try`/`finally` preserves the original throw through the rollback; if `finally` swallows or reorders it, use an explicit catch that rolls back and rethrows.

Nested `with-transaction` is out of scope: `database/sql` has no savepoint API, so nesting would silently open a second independent transaction rather than a savepoint. Detect a connectable already wrapping a `*sql.Tx` and throw a clear error rather than documenting the hazard and hoping.

### Verification

- **sqlite**: file and `:memory:` databases, verified in each package's `example/` and driven by `lgx run` and `lgx build`.
- **postgres**: a live server via `docker run --rm -e POSTGRES_PASSWORD=... -p 5432:5432 postgres:17`. The e2e task states the prereq and skips cleanly with a message if Docker is absent — it must not fake a pass. An abstraction validated by one driver is not validated; the whole point of building Postgres now is to find where the `sql/` split is sqlite-shaped while the API is still free to change.
- Round-trip types per driver: integer, float, text, boolean, NULL, and (Postgres) timestamp.

### Consumption caveat

External consumers depend on a package with `:deps/root`, e.g. `{:git/url ".../letgo-packages" :git/tag "sqlite-v0.1.0" :deps/root "sqlite"}`. lgx currently reads a dep's own `lgx.edn` from the *checkout root*, not from `:deps/root` — so a consumer would silently miss `sqlite/lgx.edn`'s Go coords and fail at require time. The fix is in the lgx cross-compilation plan (`2026-08-23-1926-lgx-cross-compilation.md`, Task 7). It does not block development here, because each `example/` uses `:local/root ".."`, which resolves correctly. **It does block tagging.** Do not tag any package in this repo until that fix has landed and is verified.

## File Structure

Repo: `/Users/andrew/Projects/letgo-packages`

- Create: `sql/lgx.edn`, `sql/README.md`
- Create: `sql/src/sql/core.lg` — the whole API: `execute!`, `execute-one!`, `query`, `with-transaction`, key transforms, opts merging
- Create: `sql/shim/go.mod`, `sql/shim/shim.go` — `Connectable`, `Query`, `Exec`, `ScanRow`
- Move: `sqlite/shim/` and the veneer's generic parts into `sql/` (git mv where possible, to keep history)
- Modify: `sqlite/lgx.edn`, `sqlite/README.md`; rewrite `sqlite/src/sqlite/core.lg` down to `open` plus re-exports
- Modify: `sqlite/example/main.lg` for the new API
- Create: `postgres/lgx.edn`, `postgres/README.md`, `postgres/src/postgres/core.lg`, `postgres/example/lgx.edn`, `postgres/example/main.lg`, `postgres/example/.gitignore`
- Modify: `README.md` — the package table, and the pure-Go-driver rule

---

### Task 1: Spike — does an interface parameter survive the boxing boundary?

**Files:**
- Modify: `sqlite/shim/shim.go` (temporarily; this task is throwaway)

No unit tests — this is a capability probe whose entire output is a yes/no answer that shapes every task after it.

- [x] **Step 1: Add a probe function to the existing shim**
  Declare the `Connectable` interface from the Design, plus one function taking it:
  ```go
  func ProbeQuery(c Connectable, q string) (*sql.Rows, error) { return c.Query(q) }
  ```
  Register it in the shim's `init` alongside the existing definitions.

- [x] **Step 2: Call it with both a DB and a Tx**
  In `sqlite/example/`, run a script under
  `LGX_LETGO_REPLACE=/Users/andrew/Projects/let-go lgx run <script>`
  that opens a database, calls `ProbeQuery` with the connection, then calls `.Begin` and calls `ProbeQuery` with the resulting transaction.
  Expected: both succeed. A failure will surface as a reflect error about assignability.

- [x] **Step 3: Decide and record**
  If both work, the Design's `Connectable` shape is confirmed — continue as planned.
  If either fails, switch to the fallback: separate `QueryTx`/`ExecTx` shim functions plus a runtime branch in the veneer, and note the change under this task in this plan as a `> Deviation:` line before continuing. Do not attempt to work around it inside let-go.

  > Result: confirmed. Both the boxed `*sql.DB` and the boxed `*sql.Tx` passed
  > through `ProbeQuery`'s `Connectable` parameter and returned rows. The
  > Design's interface shape stands; no fallback needed.

- [x] **Step 4: Revert the probe**
  Remove `ProbeQuery`. The real interface lands in Task 2.

> Deviation (environment, applies to all tasks): the let-go checkout was on
> `fix/vm-boxing-symmetry`, which lacks `pkg/cli`; switched it to
> `integration/go-interop` (contains the boxing fix and is what lgx consumes).
> `lgx` on PATH is 0.1.0 and predates `:go/*` deps, so all commands use
> `/Users/andrew/Projects/lgx/bin/lgx` (0.1.2).

### Task 2: The `sql` package — shim

**Files:**
- Create: `sql/shim/go.mod`, `sql/shim/shim.go`
- Create: `sql/lgx.edn`

- [x] **Step 1: Move the shim**
  `git mv sqlite/shim sql/shim` to keep history. Update the module path in `go.mod` to `github.com/abogoyavlensky/letgo-packages/sql/shim`, and the package doc comment to describe a driver-agnostic seam rather than a sqlite one.

- [x] **Step 2: Rework the API onto `Connectable`**
  Change `Query` and `Exec` to take the `Connectable` interface from the Design instead of `*sql.DB`. Keep `ScanRow` as is. Keep the namespace registered as `sql.shim` (rename from `sqlite.shim`), with `vm.NewNamespace` + `vm.MustBox` + `rt.RegisterNS` in `init`, calling the installer directly rather than via `RegisterInstaller`.

- [x] **Step 3: Decide the value-conversion shape**
  Check whether the boxing-symmetry plan has landed in the let-go checkout at `/Users/andrew/Projects/let-go` (look for interface-element handling in `BoxValue`'s slice branch in `pkg/vm/value.go`).
  - Landed: use plain `[]any` for both `ScanRow`'s return and the `args` parameters, and delete the conversion helpers.
  - Not landed: keep `[]vm.Value` on both sides with the existing `toValue`/`unbox` helpers.
  Record which branch was taken as a `> Deviation:` note under this task either way — the next reader needs to know.

  > Deviation: the boxing-symmetry plan HAS landed (let-go `integration/go-interop`,
  > commit 40ec3a9 "fix(vm): make []any cross the Go/let-go boundary as native
  > values"). The shim uses plain `[]any` on both sides; the `toValue`/`unbox`
  > helpers are deleted. sqlite TEXT-as-[]byte and NULL-as-nil are now handled
  > by the boxing layer's dynamic-type path, not shim conversion.

- [x] **Step 4: Write `sql/lgx.edn`**
  `:paths ["src"]`, and `:deps` with `database/sql {:go/interop "sql"}` plus the shim via `{:go/local "shim"}`. No driver — that is what makes this package driver-agnostic.

- [x] **Step 5: Verify it compiles**
  Run `gofmt -l sql/shim/` (expect no output) and `go vet ./...` inside `sql/shim/` with a temporary `replace` pointing at the let-go checkout. Full compilation is proven by Task 4's build.

- [x] **Step 6: Commit**
  `git commit -m "Move the shim into a driver-agnostic sql package"`

> Codex review (commit 291dca7): two P1s, both accepted without fixup.
> (1) sqlite/ references the deleted shim until Task 4 — intentional
> intermediate state in the plan's ordering. (2) the example's
> `:lg-version "1.11.1"` predates the []any boxing fix — no released let-go
> has it yet; dev runs use LGX_LETGO_REPLACE and tagging is already blocked
> on a release. README note lands in Task 5.

### Task 3: The `sql` package — veneer

**Files:**
- Create: `sql/src/sql/core.lg`

No unit test harness exists in this repo, and the API is inseparable from a live database, so verification is the driver e2e tasks (5 and 7). Keep the pure parts — key transforms, opts merging, statement destructuring — as separate small fns so they stay readable and could be tested later.

- [x] **Step 1: Implement the key transforms and opts merging**
  A `:keys` option resolving to a `String -> keyword` function: `:unqualified` (verbatim), `:unqualified-lower` (lower-cased), or a caller-supplied function passed through. Reject anything else with a clear error naming the accepted values. Opts merge connection-level defaults under per-call opts.

- [x] **Step 2: Implement `execute!` and `execute-one!`**
  Both take `[connectable statement]` or `[connectable statement opts]`. Destructure the statement into query string and parameter vector.

  Implement the dispatch from the Design: a pure `returns-rows?` predicate over the statement string, plus the `:returns` opt override taking precedence over it. Keep the predicate separate and small — it is the one genuinely testable pure fn in this package, so give it direct tests covering leading whitespace, a leading `--` comment, a `/* */` comment, mixed case, each rows-path keyword, a trailing `RETURNING`, `RETURNING` inside a string literal (must *not* match), and the known `WITH ... INSERT` false positive.
  Then: rows path calls `shim/Query`, update-count path calls `shim/Exec`. Document the heuristic in a docstring, since it is the one behavior a caller cannot predict from the signature.

  Rows are realized with `doall` before the cursor closes, inside a `try`/`finally`.

  **Check `.Err` after the cursor loop, before closing.** `(.Next rows)` returns false for both end-of-rows and a read failure, so a loop stopping on `Next` alone silently returns a partial result set on a mid-stream error — a truncated query that looks successful. Call `(.Err rows)` once iteration ends and throw if it is non-nil. Return shapes: `execute!` gives a vector of maps or `[{:sql/update-count n}]`; `execute-one!` gives the first map, `nil` for an empty result set, or `{:sql/update-count n}`.

- [x] **Step 3: Implement `query` as sugar**
  A thin alias for `execute!`, documented as such.

- [x] **Step 4: Implement `with-transaction`**
  A macro binding `tx` over the body: `.Begin`, run, `.Commit` on normal return, `.Rollback` and rethrow on a throw. Verify let-go's `try`/`finally` preserves the original exception through the rollback — if it does not, use an explicit catch that rolls back and rethrows. Document that nesting is unsupported.

- [x] **Step 5: Commit**
  `git commit -m "Add the sql veneer: execute!, execute-one!, query, with-transaction"`

> Notes: `returns-rows?` got 11 direct tests in `sql/test/sql/core_test.lg`,
> run green via `lgx test` in `sql/` (which also proved the package's custom
> runtime builds). Verified live that let-go's `try`/`finally` preserves the
> original throw, and typed `(catch Throwable e)` works on
> `integration/go-interop`; `with-transaction` rolls back only on body
> failure, so a failed commit throws without a misleading rollback attempt.
>
> Codex review round 1 (9250f77): two P2s, both fixed in 067aab8 —
> (1) `returning` inside a SQL comment took the rows path; the regex
> literal-stripping became a single-pass scrubber removing literals, quoted
> identifiers, and comments before any keyword match. (2) `execute-one!`
> realized the full result set; it now reads at most one row before closing
> the cursor. 13 predicate tests green.
>
> Codex round 2 (067aab8): P1 claiming `count` returns byte length was
> refuted by direct test — let-go's `count`/`subs`/`string/index-of` are all
> rune-indexed and consistent (added a non-ASCII test as a guard). P2
> (per-character `subs`/`str` making the scan quadratic) was real and fixed
> in 42ce78c: the scrubber now jumps between quote/comment tokens with
> `index-of`, copying spans whole. 14 tests green.
>
> Codex round 3 (42ce78c): P2 — let-go's `index-of` re-materializes the rune
> slice per call, so the token-jump scan was still quadratic (confirmed in
> `pkg/rt/lang.go`). Fixed in 25a664d by deleting the hand scanner: dispatch
> now uses two RE2 regexes (linear time) — a head-keyword match and a
> tokenizing alternation where literals/comments outcompete a bare
> `\breturning\b`. Net -36 lines; 14 tests green. Review rounds for this
> task: 3 (max).

### Task 4: `sqlite` becomes a thin driver package

**Files:**
- Modify: `sqlite/lgx.edn`, `sqlite/src/sqlite/core.lg`, `sqlite/README.md`

- [x] **Step 1: Rewrite `sqlite/lgx.edn`**
  `:paths ["src"]`; `:deps` with the `sql` package via `{:local/root "../sql"}` and `modernc.org/sqlite {:go/version "v1.57.0"}`. The `database/sql` interop coord and the shim now arrive transitively from `sql/` — do not repeat them.

- [x] **Step 2: Reduce `sqlite/src/sqlite/core.lg` to the driver-specific part**
  `open` (driver name `"sqlite"`, accepting a path or `":memory:"`, plus opts) and `close!`. Re-export `execute!`, `execute-one!`, `query`, and `with-transaction` from `sql.core` so a consumer needs one `require`.

- [x] **Step 3: Verify the transitive Go coords arrive**
  In `sqlite/example/`, run:
  `LGX_LETGO_REPLACE=/Users/andrew/Projects/let-go lgx --verbose install`
  Expected: the trace shows a runtime build whose lginterop `-packages` list includes `database/sql`, proving `sql/`'s coord flowed up through `:local/root`.

  > Note: `--verbose` did not surface the build commands, so the check was
  > made on the generated runtime module instead: `~/.lgx/runtimes/<hash>/src`
  > contains `interop/interop_sql.go`, a `replace` for `sql/shim`, and
  > `modernc.org/sqlite v1.57.0` — all three coords flowed up.

- [x] **Step 4: Commit**
  `git commit -m "Reduce sqlite to a thin driver over the sql package"`

### Task 5: sqlite end-to-end

**Files:**
- Modify: `sqlite/example/main.lg`
- Modify: `sqlite/README.md`

- [x] **Step 1: Rewrite the example for the new API**
  Exercise every entry point: `open`, `execute!` for DDL, `execute!` for parameterized inserts, `execute-one!`, `query`, `with-transaction` committing, and `with-transaction` rolling back on a throw with a follow-up read proving the rollback happened. Round-trip integer, float, text, boolean, and NULL, and assert the read-back values are native let-go values (`(= "Ada" (:name row))`, `(nil? (:notes row))`), not just that they print plausibly.

- [x] **Step 2: Run it**
  In `sqlite/example/`: `LGX_LETGO_REPLACE=/Users/andrew/Projects/let-go lgx run`
  Expected: every assertion passes.

- [x] **Step 3: Build and run standalone**
  Same env: `lgx build`, then run `bin/app` from a different directory.
  Expected: identical output.

- [x] **Step 4: Update `sqlite/README.md`** (use /writing-clearly)
  New API, the `:keys` option, the unqualified-keys constraint and why it exists, the layered structure, and the note that the shim's let-go require must be pinned to a real release before tagging.

- [x] **Step 5: Commit**
  `git commit -m "Verify sqlite end to end against the new sql API"`

> Notes: 19 checks, green under both `lgx run` and the built `bin/app` run
> from /tmp. Boolean round-trip is asserted as sqlite actually behaves
> (`true` reads back as `1`, `false` as `0` — no boolean storage class);
> noted in the README. The example's entry call gained a
> `(when-not *compiling-aot* ...)` guard so `lgx build` does not execute it
> at AOT time.

### Task 6: The `postgres` package

**Files:**
- Create: `postgres/lgx.edn`, `postgres/src/postgres/core.lg`, `postgres/README.md`

- [x] **Step 1: Write `postgres/lgx.edn`**
  `:paths ["src"]`; `:deps` with the `sql` package via `{:local/root "../sql"}` and `github.com/jackc/pgx/v5/stdlib {:go/version "v5.10.0"}`.
  Note this is the first coord whose package path differs from its module path (`github.com/jackc/pgx/v5`) — lgx resolves it via `go get`, which is exactly why it never hand-writes require lines. If the runtime build fails here, that is an lgx bug worth recording, not something to work around in this repo.

- [x] **Step 2: Implement `postgres/src/postgres/core.lg`**
  `open` taking a DSN or connection URL, with driver name `"pgx"` (the name `pgx/v5/stdlib` registers), plus `close!` and the same re-exports as sqlite. Default `:keys` to `:unqualified-lower`, since Postgres folds unquoted identifiers to lower case — document the choice.

- [x] **Step 3: Verify the runtime builds and the driver registers**
  Build a runtime for this package and confirm `sql/Open "pgx" ...` returns a connection object without a driver-not-found error. A live server is not needed for this step.

  > Verified with a throwaway probe under `postgres/example/` (whose
  > `lgx.edn` was created a task early to give the probe a project context —
  > Task 7 reuses it). The package-path coord resolved to module
  > `github.com/jackc/pgx/v5` via `go get` with no special handling, the
  > runtime built, and `open` returned a connectable. A minimal
  > `postgres/README.md` also landed here; Task 8 polishes it.

- [x] **Step 4: Commit**
  `git commit -m "Add the postgres driver package"`

### Task 7: postgres end-to-end against a live server

**Files:**
- Create: `postgres/example/lgx.edn`, `postgres/example/main.lg`, `postgres/example/.gitignore`

Prereq: Docker. If unavailable, stop and report — do not fake the verification or mark the task done.

- [x] **Step 1: Start a server**
  `docker run --rm -d --name letgo-pg -e POSTGRES_PASSWORD=letgo -p 5432:5432 postgres:17`
  Wait for readiness with `docker exec letgo-pg pg_isready` before proceeding.

- [x] **Step 2: Write the example**
  Mirror the sqlite example's coverage so the two are directly comparable, and add the types Postgres has that SQLite does not: `timestamptz` and `numeric`, both of which must round-trip for this task to pass.
  Also try a `text[]` array, but treat it as *exploratory*: `database/sql` has no portable array scanning, so a failure records an unsupported type in `postgres/README.md` rather than failing the task. Note which it turned out to be. Read the DSN from an env var with a localhost default.

- [x] **Step 3: Run it**
  In `postgres/example/`: `LGX_LETGO_REPLACE=/Users/andrew/Projects/let-go lgx run`
  Expected: every assertion passes.

- [x] **Step 4: Record where the abstraction leaked**
  This is the real deliverable of building a second driver. Note every place the `sql/` layer needed a driver-specific accommodation — value conversion, key casing, parameter placeholders (`?` for SQLite vs `$1` for Postgres, which callers will hit immediately), error shapes. If the leak is structural rather than cosmetic, fix `sql/` now while nothing is tagged, and record it as a `> Deviation:` note here.

  > Leak audit: no structural leaks — `sql/` needed zero changes for the
  > second driver. Cosmetic differences, all documented in the READMEs:
  > placeholders (`?` vs `$1`), key casing (postgres defaults
  > `:unqualified-lower`), and value conversion (booleans: sqlite `1`/`0` vs
  > postgres `true`/`false`; `timestamptz` arrives as a boxed `time.Time`
  > usable via methods like `.Unix`; `numeric` arrives as a decimal string;
  > `text[]` arrives as the array's text form `"{a,b}"` — recorded as
  > unsupported-as-native in `postgres/README.md`). 25 checks green against
  > postgres:17 in Docker, including `INSERT ... RETURNING` through the
  > heuristic and both timestamptz/numeric round-trips.
  >
  > Codex review (fb7d1c7): P1 — the DSN is configurable, so `drop table
  > people` against a user's server could destroy real data; the example now
  > uses `letgo_example_people`. P2 — the numeric claim wasn't actually
  > enforced (a float would also `str` to "12.34"); now asserted with
  > `string?`. Both fixed in 95a006b, re-verified green against a fresh
  > container.

- [x] **Step 5: Stop the server and commit**
  `docker stop letgo-pg`
  `git commit -m "Verify postgres end to end"`

### Task 8: Repo documentation

**Files:**
- Modify: `README.md`
- Create: `sql/README.md`
- Modify: `postgres/README.md`

- [x] **Step 1: Write the docs** (use /writing-clearly)
  Root `README.md`: the three-package table, how `:deps/root` consumption works, and a stated rule that driver packages must use pure-Go drivers — cgo breaks cross-compilation and forces a C toolchain on users. Note the tagging blocker from the Design (the lgx `:deps/root` fix).
  `sql/README.md`: the full API reference, the `:keys` option, the unqualified-keys constraint and its cause, the `Connectable` interface, and the parameter-placeholder difference between drivers.

- [x] **Step 2: Commit**
  `git commit -m "Document the sql layer and its three packages"`

---

## Completion summary (2026-08-23)

**Implemented.** Eleven commits in letgo-packages (291dca7..b8527bc): the
driver-agnostic `sql/` package (shim on the `Connectable` interface, plain
`[]any` at both boundaries, and the `sql.core` veneer — `execute!`,
`execute-one!`, `query`, `with-transaction`, `:keys` transforms, opts
merging, and the `returns-rows?` heuristic with a `:returns` override);
`sqlite/` reduced to `open`/`close!` plus re-exports; a new `postgres/`
package on pgx v5.10.0; examples for both drivers; and READMEs for all
three packages plus the repo root.

**Verification.** The Task 1 spike confirmed a boxed `*sql.DB`/`*sql.Tx`
passes into an interface-typed shim parameter. 14 predicate tests run via
`lgx test` in `sql/`. The sqlite example (19 checks) passes under `lgx run`
and as a built binary run from another directory. The postgres example
(26 checks) passes against postgres:17 in Docker, including
`INSERT ... RETURNING`, timestamptz (`.Unix` on the boxed `time.Time`), and
numeric-as-string round-trips; `text[]` arrives as its Postgres text form
and is documented as such. Final full pass (tests + both e2es) green.

**Abstraction leak audit (Task 7's deliverable).** No structural leaks;
`sql/` needed zero changes for the second driver. Cosmetic, documented
differences: placeholders (`?` vs `$1`), key casing (postgres defaults
`:unqualified-lower`), boolean shape (`1`/`0` vs `true`/`false`), and the
postgres-specific value types above.

**Deviations, gathered.**
- Environment: the let-go checkout was switched from `fix/vm-boxing-symmetry`
  to `integration/go-interop` (has `pkg/cli` and the boxing fix); all
  commands used `/Users/andrew/Projects/lgx/bin/lgx` (0.1.2), since the
  PATH lgx is 0.1.0.
- Task 2: boxing symmetry has landed, so the shim uses plain `[]any` both
  ways; the `toValue`/`unbox` helpers were deleted.
- Task 6: `postgres/example/lgx.edn` was created one task early to give the
  driver-registration probe a project context; a minimal `postgres/README.md`
  also landed there.
- Codex checkpoints drove five fixup commits: comment-aware RETURNING
  detection and single-row `execute-one!` (067aab8), two scanner performance
  rewrites ending in the linear regex tokenizer (42ce78c, 25a664d),
  example-table isolation plus a real numeric-type assertion (95a006b), and
  README claim qualifications (b8527bc). Two codex claims were refuted by
  direct test (rune-indexing "crash"; two intentional mid-sequence states)
  and accepted without change.
- Also fixed stale drift in `docs/knowledge-base/lgx-go-runtimes.md` (the
  `[]any` gotcha now describes the boxing-symmetry fix), per the repo's
  drift rule.

**Still blocking tagging** (unchanged from the Design): the lgx `:deps/root`
fix from the cross-compilation plan, and a let-go release carrying the
boxing fix to pin in `sql/shim/go.mod`.

**What the plan could have specified better:** the examples' assertions
against a *configurable* live server needed an isolation rule (codex caught
`drop table people` against a user-pointed DSN); and it could have said
what "round-trip boolean" means per driver — sqlite has no boolean storage
class, so the honest assertion is `1`/`0`, which the plan's wording left to
be discovered. Otherwise it held up: the spike-first ordering and the
leak-audit task both paid off directly.
