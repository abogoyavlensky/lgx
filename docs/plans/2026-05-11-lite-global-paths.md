# Top-level `:paths` for project sources

## Status: completed

## Context

Today `lgx run` builds `-source-paths` from cached lib paths only. There
is no way to add the project's own source directories — users either
have to keep code in a location the let-go resolver finds by default
(rare for a real project) or invoke `lg` directly bypassing `lgx run`.

Add an optional top-level `:paths` key to `lgx.edn`: a vector of
relative path strings, resolved against the project root and prepended
to lib paths in the `-source-paths` flag.

```edn
{:paths ["src" "resources"]
 :deps  {some-org/util {:git/url "https://github.com/some-org/util"
                        :git/sha "abc..."}}}
```

Project paths come first so namespaces defined in the project shadow
any lib-side namespace of the same name. Matches `tools.deps`.

`:paths` is opt-in. Absence means no project paths prepended — no
implicit `["src"]` default.

This plan also catches up the README documentation for `:deps/root`,
which the earlier `:deps/root` plan deferred.

## Behavior

| `:paths` shape           | Effect on `-source-paths`                         |
| ------------------------ | ------------------------------------------------- |
| absent                   | nothing prepended (today's behavior)              |
| `[]`                     | nothing prepended                                 |
| `["src" "resources"]`    | `<project>/src` and `<project>/resources` prepended, in order |
| entry missing on disk    | warn to stderr, pass through anyway               |

Validation (mirrors `:deps/root`): each entry must be a non-blank
string, no leading `/`, no `..` segments. `:paths` itself must be a
vector.

`:paths` affects `lgx run` only. `lgx install` ignores it.

## Implementation

### `lgx/config.lg`

Extend `allowed-top-level` to `#{:deps :paths}`.

Lift the path-shape checks out of `validate-coord!` into a shared
private helper, since `:deps/root` and `:paths` entries share rules:

```clojure
(defn- validate-rel-path! [label value ctx]
  (when-not (string? value)
    (bad! (str label " must be a string") ctx))
  (when (str/blank? value)
    (bad! (str label " must be non-blank") ctx))
  (when (str/starts-with? value "/")
    (bad! (str label " must be relative (no leading /)") ctx))
  (when (some #(= ".." %) (str/split value "/"))
    (bad! (str label " must not contain .. segments") ctx)))
```

`validate-coord!` calls `(validate-rel-path! (str lib " :deps/root") root {:lib lib})`.

Add `validate-paths!`:

```clojure
(defn- validate-paths! [paths]
  (when-not (vector? paths)
    (bad! ":paths must be a vector" {}))
  (doseq [p paths]
    (validate-rel-path! ":paths entry" p {:value p})))
```

`validate-config!` calls `validate-paths!` when `:paths` is present.

Add public accessor:

```clojure
(defn paths
  "Return the project's :paths vector from lgx.edn, or [] if absent."
  [project]
  (let [path (str project "/" config-name)
        cfg  (validate-config! (edn/read-string (slurp path)))]
    (or (:paths cfg) [])))
```

Re-reads `lgx.edn`. Trivial cost for a small file — keep it symmetrical
with `coords`.

### `lgx.lg`

Add a private helper and wire it into `cmd-run`:

```clojure
(defn- resolve-project-paths [project paths]
  (mapv (fn [p]
          (let [abs (str project "/" p)]
            (when-not (file-exists? abs)
              (write! *err* (str "warning: :paths entry not found: " p "\n")))
            abs))
        paths))

(defn- cmd-run [forward-args]
  (let [project   (config/find-project!)
        coords    (config/coords project)
        results   (ensure-all! coords)
        own-paths (resolve-project-paths project (config/paths project))
        paths     (vec (concat own-paths (mapv :path results)))]
    (print-installs! results)
    (runner/exec-lg! paths forward-args)))
```

`cmd-install` is unchanged. `runner/exec-lg!` is unchanged — it already
takes a vector and joins with `os/path-separator`.

Path joining uses hardcoded `/`, matching the existing codebase
convention (cache.lg, config.lg). Switching to `os/file-separator` is
out of scope; would only matter as part of a wider portability pass.

### Tests

`tests/config_test.lg` — validation:
- `validate-config-accepts-paths` — `:paths ["src" "resources"]` passes.
- `validate-config-accepts-empty-paths` — `:paths []` passes.
- `validate-config-rejects-paths-not-a-vector` — `:paths "src"` throws.
- `validate-config-rejects-blank-paths-entry` — `:paths [""]` throws.
- `validate-config-rejects-non-string-paths-entry` — `:paths [5]` throws.
- `validate-config-rejects-absolute-paths-entry` — `:paths ["/abs"]` throws.
- `validate-config-rejects-parent-traversal-paths-entry` — `:paths ["../etc"]` throws.

`tests/config_test.lg` — accessor:
- `paths-returns-empty-when-absent` — pure call against
  `validate-config!`-validated map without `:paths` → `[]` (or use a
  fixture without `:paths` and call `config/paths`).
- `paths-reads-fixture` — add `:paths ["src" "test"]` to
  `tests/fixtures/sample-project/lgx.edn`, assert
  `(config/paths "tests/fixtures/sample-project")` returns `["src" "test"]`.
  Existing `coords-reads-and-parses-fixture` must keep passing.

E2E (`tests/e2e.sh`): skip. Exact warning text and project-tree setup
would add fragility; unit tests cover the helper.

### Docs

`docs/ARCHITECTURE.md`:
- Update the schema line in `lgx install` step 2 to include `:paths`:
  `{:paths [<rel-path> ...] :deps {<lib> {:git/url … :git/sha or :git/tag … :deps/root <opt>}}}`
- Under `lgx run` data-flow, before step 5, add a paragraph: project's
  `:paths` (project-root-relative) are resolved to absolute paths and
  prepended to lib paths before the join. Missing entries log a warning
  to stderr but are passed through.

`README.md`:
- In the `lgx.edn` section, expand the example to include both `:paths`
  and a `:deps/root` coord.
- Add a short paragraph documenting `:paths` (project paths, prepended,
  warn-but-continue on missing).
- Add a short paragraph documenting `:deps/root` (per-coord override of
  the default `<sha>/src` probe, with the `tools.cli` example).
- Trim the "current limitations" sentence — `:deps/root` and `:paths`
  are no longer absent. Leave only "HTTPS URLs only, no transitive deps".
- Remove the two retired roadmap entries: `:paths override` and
  `Per-coord :deps/root`.

## Out of scope (YAGNI)

- Implicit `:paths ["src"]` default when absent. Opt-in is simpler.
- Glob/wildcard support in `:paths`.
- Per-coord `:paths` vector (we already have `:deps/root`).
- Absolute paths in `:paths`. Re-evaluate if a real use case appears.
- Path-join refactor to use `os/file-separator` codebase-wide.

## Verification

- `lgx.edn` with `:paths ["src"]` and a `src/foo.lg` defining `foo`;
  `lgx run -e '(require (quote foo))'` succeeds.
- `lgx.edn` with `:paths ["nope"]`; `lgx run -e '(println :ok)'` prints
  the warning to stderr and `:ok` to stdout.
- `lgx.edn` without `:paths`; `lgx run` behaves exactly as before.
- `lgx install` with `:paths` set: silent w.r.t. `:paths`, unchanged
  output.

## Outcome

Implemented:

- `lgx/config.lg` accepts top-level `:paths`, shares relative-path
  validation with `:deps/root`, and exposes `config/paths`.
- `lgx.lg` resolves project paths against the project root, warns for
  missing entries, and prepends them to dependency source paths for
  `lgx run`.
- `tests/config_test.lg` covers valid and invalid `:paths` shapes plus
  fixture-backed `config/paths` reading.
- `README.md` and `docs/ARCHITECTURE.md` document `:paths` and
  `:deps/root`; retired roadmap items were removed.

Verification:

- `lg tests/config_test.lg` passes: 24 tests, 30 assertions.
- `make test` passes: config unit tests, cache unit tests, bundling, and
  19 existing e2e assertions.
- Manual checks with
  `LGX_LG=/Users/andrew/Projects/let-go/lg` confirm `lgx run` can
  require a namespace from project `:paths`, warns and continues for
  missing entries, behaves normally without `:paths`, and leaves
  `lgx install` silent with respect to `:paths`.
