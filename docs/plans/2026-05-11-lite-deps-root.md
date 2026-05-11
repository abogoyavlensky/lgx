# `:deps/root` coord option [COMPLETED 2026-05-11]

## Context

`cache/ensure-lib!` returns `<sha>/src/` when that subdir exists, else
`<sha>/`. That covers `tools.deps`-style libs whose namespaces live
under `src/`, but breaks for libs that ship sources elsewhere —
`org.clojure/tools.cli`, for example, keeps its namespace under
`src/main/clojure/clojure/tools/cli.cljc`.

Add an optional `:deps/root` key to coords in `lgx.edn`, mirroring the
`tools.deps` name. Semantics are direct: lgx joins it onto the cache
leaf and uses the result as the source path, with no further probing.

```clojure
{:deps {org.clojure/tools.cli {:git/url "https://github.com/clojure/tools.cli"
                               :git/sha "<sha>"
                               :deps/root "src/main/clojure"}}}
```

→ source path: `<sha>/src/main/clojure`

`:deps/root` is non-transitive: lgx does not read anything from inside
the cloned lib, consistent with the "Not transitive" stance in
[ARCHITECTURE.md](../ARCHITECTURE.md).

## Behavior

| Coord shape                  | Resolved source path                                   |
| ---------------------------- | ------------------------------------------------------ |
| no `:deps/root`              | `<sha>/src` if it exists, else `<sha>` (unchanged)     |
| `:deps/root "src/main/clj"`  | `<sha>/src/main/clj`                                   |
| `:deps/root` points nowhere  | hard error: `:deps/root <root> not found in <url>`     |

The existence check runs on every `ensure-lib!` call, not only on fresh
clones, so a misconfigured `:deps/root` is caught even when the dep is
already cached.

`:deps/root` is normalized by trimming a single trailing `/`, so
`"src/main/clj"` and `"src/main/clj/"` are equivalent.

## Implementation

### `lgx/config.lg`

Extend `validate-coord!` to accept an optional `:deps/root`:

```clojure
(defn- validate-coord! [lib coord]
  ;; ...existing url/sha/tag checks...
  (when-let [root (:deps/root coord)]
    (when-not (string? root)
      (bad! (str lib " :deps/root must be a string") {:lib lib}))
    (when (str/blank? root)
      (bad! (str lib " :deps/root must be non-blank") {:lib lib}))
    (when (str/starts-with? root "/")
      (bad! (str lib " :deps/root must be relative (no leading /)") {:lib lib}))
    (when (some #(= ".." %) (str/split root "/"))
      (bad! (str lib " :deps/root must not contain .. segments") {:lib lib})))
  coord)
```

No other schema changes; no new top-level keys.

### `lgx/cache.lg`

Extract a private helper and wire it into `ensure-lib!`:

```clojure
(defn- trim-trailing-slash [s]
  (if (and (> (count s) 1) (str/ends-with? s "/"))
    (subs s 0 (dec (count s)))
    s))

(defn- resolve-source-path [dir root url sha]
  (if root
    (let [normalized (trim-trailing-slash root)
          resolved   (str dir "/" normalized)]
      (when-not (file-exists? resolved)
        (throw (ex-info (str ":deps/root " normalized " not found in " url)
                        {:url url :sha sha :root normalized :resolved resolved})))
      resolved)
    (let [src (str dir "/src")]
      (if (file-exists? src) src dir))))

(defn ensure-lib! [coord]
  (let [url        (:git/url coord)
        root       (:deps/root coord)
        sha        (or (:git/sha coord)
                       (resolve-tag->sha url (:git/tag coord)))
        dir        (coord-dir url sha)
        installed? (not (file-exists? dir))]
    (when installed?
      (clone-and-checkout! url sha dir))
    {:path (resolve-source-path dir root url sha)
     :installed? installed?}))
```

No changes to `lgx.lg` or `runner.lg`.

### Tests

`tests/config_test.lg`:
- `validate-config-accepts-deps-root` — `:deps/root "src/main/clojure"` passes.
- `validate-config-rejects-blank-deps-root` — `""` and `"   "` throw.
- `validate-config-rejects-non-string-deps-root` — `:deps/root 5` throws.
- `validate-config-rejects-absolute-deps-root` — `"/src"` throws.
- `validate-config-rejects-parent-traversal` — `".."` and `"src/../etc"` throw.

`tests/cache_test.lg`:
- `ensure-lib-uses-deps-root-when-set` — pre-populate a cache dir with a
  `lib/core/` subdir; pass coord with `:deps/root "lib/core"`; assert
  `:path` ends with `/lib/core` and `:installed?` is false.
- `ensure-lib-throws-when-deps-root-missing` — pre-populate cache without
  the subdir; expect throw.
- `ensure-lib-normalizes-trailing-slash` — `:deps/root "lib/core/"` and
  `"lib/core"` resolve identically.

Existing `ensure-lib` tests (default `src/` probe, no-`:deps/root` path)
keep covering the unchanged branch.

### Docs

`docs/ARCHITECTURE.md`:
- Cache layout section: replace the `src/`-probe paragraph with two
  paragraphs — default behavior, then `:deps/root` override with the
  `tools.cli` example.
- `lgx install` step 2 schema line: add the optional `:deps/root` key
  to the coord shape.

### Optional example

If it slots in cleanly, add an `examples/clojure-libs/tools-cli/`
subdir with an `lgx.edn` using `:deps/root "src/main/clojure"`. Skip if
let-go can't actually load `tools.cli` — the test coverage above is
enough to demonstrate the lgx-side path resolution.

## Out of scope (YAGNI)

- Multiple paths per coord (`:paths` vector). One root covers tools.cli
  and most Clojure libs.
- Reading the lib's own `deps.edn` for paths. Stays consistent with
  lgx's non-transitive stance.
- A `:deps/root` field for the project itself — different concept, not
  requested.

## Verification

- `lgx install` with a coord using `:deps/root "src/main/clojure"` →
  installs to the right cache leaf, `lgx run` resolves namespaces under
  that path.
- `lgx install` with a coord whose `:deps/root` doesn't exist → fails
  with a clear `:deps/root ... not found in ...` error.
- Existing examples in `examples/with-lib/` and `examples/clojure-libs/`
  continue to work without modification — no `:deps/root` means the
  current `src/` probe applies.

## Outcome

Implemented in commit `28b58d0` (`Add :deps/root coord option`). Changes:

- `lgx/config.lg` — `validate-coord!` accepts optional `:deps/root` with
  type/blank/relative/`..`-segment checks. Uses `(contains? coord :deps/root)`
  so explicit `nil` is also rejected.
- `lgx/cache.lg` — new private helpers `trim-trailing-slash` and
  `resolve-source-path`; `ensure-lib!` reads `:deps/root` and routes
  through the helper. Missing-on-disk throws an `ex-info` with the URL,
  sha, root, and resolved path.
- `tests/config_test.lg` — 5 new validation tests.
- `tests/cache_test.lg` — 3 new tests covering happy path, missing-dir
  error, and trailing-slash normalization.
- `docs/ARCHITECTURE.md` — cache-layout paragraph and schema mention
  updated.

All 38 unit assertions and 19 e2e assertions pass.

The optional `examples/clojure-libs/tools-cli/` example was skipped:
let-go can't yet load real Clojure libs (per
`examples/clojure-libs/README.md`), so a runnable demo would have hit
the same reader/compiler gaps the other clojure-libs entries already
document. Test coverage is sufficient to demonstrate the lgx-side path
resolution.
