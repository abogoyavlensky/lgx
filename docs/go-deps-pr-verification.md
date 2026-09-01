---
status: temporary
---

# Verifying the go-deps stack (lgx + let-go + letgo-packages)

**This file is scaffolding.** The `:go/*` dependency support in lgx depends
on let-go changes that are still open pull requests, so verifying it means
building a patched `lg` yourself. Delete this doc once the PRs below are
merged and `lgx` can run against a released `lg`.

## The moving parts

| Repo | Role |
|---|---|
| `lgx` (`go-deps` branch) | `:go/*` coords, the runtime cache, cross-builds, `lgx clean` |
| `let-go` (several PR branches) | the runtime changes the above needs |
| `letgo-packages` | `sql` / `sqlite` / `postgres` wrapper packages, the realistic consumer |

### Open let-go PRs, by group

**go-deps proper** (needed for `:go/*` to work at all):

| PR | Branch | What it gives lgx |
|---|---|---|
| [#773](https://github.com/nooga/let-go/pull/773) | `interop/p1-out-of-tree-lginterop` | self-contained interop packages, importable `pkg/cli` |
| [#776](https://github.com/nooga/let-go/pull/776) | `interop/p3-reflect-multireturn` | multi-return Go funcs box as vectors |
| [#778](https://github.com/nooga/let-go/pull/778) | `fix/vm-boxing-symmetry` | `[]any` crosses the boundary as native values |

**Clojure-library compat** (not required for `:go/*`, but needed for the
examples and for HoneySQL):

| PR | Branch |
|---|---|
| [#754](https://github.com/nooga/let-go/pull/754) | `fix/test-thrown` |
| [#756](https://github.com/nooga/let-go/pull/756) | `fix/private-var-quote` |
| [#758](https://github.com/nooga/let-go/pull/758) | `fix/symbol-invoke` |
| [#760](https://github.com/nooga/let-go/pull/760) | `fix/variadic-min-arity` |
| [#762](https://github.com/nooga/let-go/pull/762) | `fix/reify-object` |
| [#764](https://github.com/nooga/let-go/pull/764) | `feat/ordered-maps` |
| [#787](https://github.com/nooga/let-go/pull/787) | `host-compat/string-and-builder` |

## Building a combined `lg`

No single PR branch is enough; the stack needs them merged together.

**A prebuilt branch exists.** All ten PRs below are merged, with generated
artifacts refreshed, on
[`abogoyavlensky/let-go@go-deps-combined`](https://github.com/abogoyavlensky/let-go/tree/go-deps-combined)
(`3913860`, pushed 2026-09-01). `make test`, `check-generated` and the sqlite
end-to-end check were green on that commit. Unless you need a different PR
set, skip the merge dance:

```bash
git clone https://github.com/abogoyavlensky/let-go.git
cd let-go && git checkout go-deps-combined
make build SMOKE-BOOT-BUDGET-MS=40
```

It is a throwaway integration branch: never open a PR from it, and rebuild it
from scratch rather than rebasing when the underlying PRs move.

### Rebuilding it from the PR branches

Build a throwaway integration branch and never open a PR from it:

```bash
cd ../let-go
git fetch upstream main && git checkout main && git merge --ff-only upstream/main
make install-hooks          # once per clone, see "generated artifacts" below
git checkout -b go-deps-combined main
for b in interop/p1-out-of-tree-lginterop \
         interop/p3-reflect-multireturn \
         fix/vm-boxing-symmetry \
         host-compat/string-and-builder; do
  git merge --no-edit "origin/$b" || {
    go generate ./... && git add -A && git commit --no-edit
  }
done
go run ./cmd/check-generated || { go generate ./... && git add -A && git commit -m "Refresh generated artifacts"; }
make build SMOKE-BOOT-BUDGET-MS=40
```

Add the six compat branches on top of that if you also want the Clojure
examples or the HoneySQL suite.

### Quirk: the boot-budget smoke gate

`make build` promotes `build/lg` to `bin/lg` only after a smoke test whose
boot budget is 8ms, calibrated on an idle M3. On slower or loaded machines the
median lands at 9-15ms and the build fails **after** producing a perfectly good
binary. Raise the budget rather than skipping the gate, so the correctness
assertions still run:

```bash
make build SMOKE-BOOT-BUDGET-MS=40
```

### Quirk: generated artifacts conflict on every merge

`pkg/rt/core_compiled.lgb`, `pkg/rt/generated.manifest`, and
`pkg/rt/generated.sums` are committed, so *any* two branches that touch the
runtime conflict there. Two things help:

- `make install-hooks` registers the `lgb` and `sums` merge drivers. They live
  in `.git/config`, so each clone needs it once, and they only fire on the
  plain-git merge path (not jj).
- When a conflict slips through anyway, do not hand-edit. Take either side,
  regenerate, and commit:

  ```bash
  git checkout --ours -- pkg/rt/generated.sums && git add pkg/rt/generated.sums
  go generate ./... && git add -A && git commit --no-edit
  ```

- `make test` does **not** run the manifest gate, and it does **not** run lint.
  The full pre-push sequence, in order, is:

  ```bash
  make generate SMOKE-BOOT-BUDGET-MS=40   # refresh bundle + manifest
  make test SMOKE-BOOT-BUDGET-MS=40
  go run ./cmd/check-generated
  make lint GO=$(command -v go)
  ```

### Quirk: `go generate` is not `make generate`

`go generate ./...` rebuilds the bundle but does not refresh the manifest's
output-readiness records, and a local `check-generated` can still pass because
the gitignored `pkg/rt/core_go_lowered/` tree exists on your machine. CI starts
without it and fails the `build` and `generated-artifacts` jobs with
`dependency manifest stale for 2 output(s)`. Always use `make generate`.

Note also which edits stale the manifest: **not just `.lg` files**. Most of
`pkg/vm/*.go`, plus `pkg/compiler/` and `pkg/bytecode/`, are registered bundle
generators, so a one-line Go change there requires `make generate` and a
manifest commit exactly like an `.lg` edit does.

### Quirk: `make lint` needs GO passed explicitly

`$(GO)` is only defined when the Makefile auto-installs a toolchain, which it
skips when `go` is already on PATH. `make lint` then shells out to coreutils
`install` and fails with `install: missing destination file operand`. Run
`make lint GO=$(command -v go)`.

Lint is a separate CI job, so a green `make test` says nothing about it. One
trap worth knowing: the `sync/atomic` wrapper types (`atomic.Bool`,
`atomic.Int32`, ...) embed `noCopy`, so putting one in a struct that is ever
copied by value trips govet's `copylocks`. Use a bare `uint32` with
`atomic.CompareAndSwapUint32` instead.

## Pointing lgx at the patched runtime

Two env vars, and picking the wrong one silently does nothing useful:

| Var | Use when | Effect |
|---|---|---|
| `LGX_LG` | the project has **no** `:go/*` deps | overrides the `lg` used for user scripts |
| `LGX_LETGO_REPLACE` | the project **has** `:go/*` deps | points the custom-runtime build at a let-go checkout |

For a `:go/*` project `LGX_LG` is the wrong lever: lgx builds its own runtime
and ignores it. See
[`knowledge-base/lgx-go-runtimes.md`](knowledge-base/lgx-go-runtimes.md).

Build lgx itself with the patched `lg`:

```bash
cd lgx && make build LG=/path/to/let-go/bin/lg
```

### Quirk: the runtime cache does not notice a rebuilt let-go

`runtime-hash` folds in `replace:<abs-path>` when `LGX_LETGO_REPLACE` is set,
**not** the contents of that checkout. Rebuild let-go and lgx will happily
reuse the previously built runtime. After changing let-go, force a rebuild:

```bash
rm -rf "$LGX_HOME/runtimes"      # or ~/.lgx/runtimes
```

Use a throwaway cache root so experiments never touch the real one:

```bash
export LGX_HOME=/tmp/lgx-test-home
```

## Verification matrix

Run these in order; each one exercises a layer the next depends on.

**1. The runtime itself**

```bash
cd ../let-go && make test SMOKE-BOOT-BUDGET-MS=40 && go run ./cmd/check-generated
```

**2. The Go-deps pipeline end to end** (`:go/*` coords, generated bindings, a
Go shim, a custom runtime build). This is the highest-value single check:

```bash
cd ../letgo-packages/sqlite/example
LGX_HOME=/tmp/lgx-test-home LGX_LETGO_REPLACE=/path/to/let-go \
  /path/to/lgx/bin/lgx run
```

Expect `all checks passed` after 19 ticked assertions. They cover type
round-trips both ways, which is exactly what #778 and #776 are about: a text
column must arrive as a native string (`(= "Ada" (:name row))`), NULL as
`nil`, and a multi-return Go call as a vector.

**3. The driver-agnostic layer's own suite**

```bash
cd ../letgo-packages/sql
LGX_HOME=/tmp/lgx-test-home LGX_LETGO_REPLACE=/path/to/let-go \
  /path/to/lgx/bin/lgx test
```

Expect `14 tests, 26 assertions, 0 failures`.

**4. lgx's own tests**

```bash
cd lgx && bash tests/run.sh
```

**5. The Clojure-library examples** (needs the compat branches merged in)

```bash
cd examples/clojure-libs/with-honeysql
LGX_HOME=/tmp/lgx-test-home LGX_LG=/path/to/let-go/bin/lg /path/to/lgx/bin/lgx run
```

## HoneySQL verification

HoneySQL is the most demanding Clojure library in the set: it has no runtime
dependencies but leans hard on JVM host interop in its `:clj` branches, so it
is a good proxy for "does let-go behave like Clojure". The gaps it exposed are
catalogued in
[`issues/honeysql-letgo-compat.md`](issues/honeysql-letgo-compat.md).

### Smoke test

```bash
cd ../let-go
LG_READ_CLJ=1 ./bin/lg -source-paths /tmp/honeysql/src -e \
  "(require '[honey.sql :as sql])
   (println (sql/format {:select [:a :b] :from [:t] :where [:= :id 1]}))"
```

Expect `["SELECT a, b FROM t WHERE id = ?" 1]`. `LG_READ_CLJ=1` is mandatory
when invoking `lg` directly: it makes `.clj` files resolve and `:clj` reader
conditionals match. lgx sets it for you.

### Running HoneySQL's own test suite

The strongest available check. Clone the library and write a throwaway runner
(`.tmp/` is gitignored):

```bash
git clone --branch v2.7.1437 --depth 1 \
  https://github.com/seancorfield/honeysql.git /tmp/honeysql

cat > .tmp/honeysql-suite.lg <<'EOF'
(require 'test)
(doseq [n '[honey.sql-test honey.sql.helpers-test honey.sql.pg-ops-test
            honey.ops-test honey.union-test honey.util-test]]
  (try (require n)
       (catch Throwable e (println "LOAD FAIL" n (ex-message e)))))
(test/run-tests)
EOF

cd ../let-go
LG_READ_CLJ=1 ./bin/lg -source-paths "/tmp/honeysql/src:/tmp/honeysql/test" \
  /path/to/lgx/.tmp/honeysql-suite.lg 2>&1 | grep -v 'reflection warning'
```

The `try`/`catch` around each `require` matters: a namespace that fails to
compile otherwise takes the whole run down, and `require` failures are quiet
enough to miss. Judge the result from the printed
`Tests: … Pass: … Fail: … Error: …` summary, not the exit code. Note also that
`(apply test/run-tests nss)` is broken upstream, hence the no-arg form.

### Expected results

With **all** compat branches plus #787 merged in:

```
Tests: 134  Pass: 706  Fail: 8  Error: 0
```

The 8 failures are **not** let-go bugs. They are HoneySQL's own `:lg`
reader-conditional branch: `inline-str` substitutes a plain `"'"` for the
`#"(?<!\\)'"` lookbehind regex that Go's re2 cannot express, so already-escaped
quotes get doubled. They surface only under `{:dialect :mysql}` or
`{:standard-conforming-strings false}`. Fixing that belongs upstream in
HoneySQL, not in let-go.

Two related upstream items, if you want the suite fully green:

- `issue-495-formatv` is gated `#?(:clj …)`, but `formatv` is `:lg`-disabled in
  the source, so the test needs an `:lg` gate too.
- a lookbehind-free `inline-str` (swap `\'` for a sentinel before doubling)
  would fix the 8 failures.

### Interpreting a drop in that number

Roughly what each group buys you, useful for bisecting a regression:

- ~13 tests / 108 assertions: baseline, most test namespaces fail to load.
- +#756 (private vars across namespaces): `honey.sql.helpers-test` loads.
- +#787 (`clojure-version`, Locale, URLEncoder): `honey.sql-test` loads, which
  is most of the suite.
- +#754 (`thrown?`), #758, #760, #762, #764: the remaining assertions.

## Push and PR quirks

- The fork's `main` goes stale, and a branch based on a fresh `main` carries
  workflow-file commits. Pushing those needs a PAT with `workflow` scope; a
  fine-grained token without it is rejected, **including** through the
  server-side "Sync fork" API. Workaround: click **Sync fork** on the fork's
  `main` in the web UI, then push.
- A fine-grained PAT scoped to your fork cannot comment on or open PRs against
  `nooga/let-go`. Those steps are manual.
- Keep PR branches free of the combined branch: `go-deps-combined` exists only
  to build a runtime and must never be pushed as a PR.

## Known overlap between the PRs

Only one, worth remembering at merge time: **#787 and #760 edit the same line**
of `pkg/rt/core/core.lg` (the kwargs binding in `fn-expand`). #787's
`seq-to-map-for-destructuring` supersedes #760's `(if rest-sym …)` because it
also binds `nil` for an empty rest, and adds Clojure 1.11 trailing-map support
on top. Whichever merges second, keep the `seq-to-map-for-destructuring`
version and drop the other line. #760's real content (multi-arity dispatch in
`pkg/vm/func.go`) is unaffected and still needed.

Everything else is additive: no other pair of these PRs touches the same lines.

> **Verify against:** `Makefile` and `pkg/rt/generated.*` in
> [nooga/let-go](https://github.com/nooga/let-go); `lgx.cache` / `lgx.gobuild`
> in this repo; `docs/knowledge-base/lgx-go-runtimes.md` and
> `docs/knowledge-base/lgx-dev-workflow.md`;
> `docs/issues/honeysql-letgo-compat.md`; and `sqlite/example/main.lg` in
> [letgo-packages](https://github.com/abogoyavlensky/letgo-packages).
