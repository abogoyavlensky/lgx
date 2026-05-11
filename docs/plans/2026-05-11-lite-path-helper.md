# Portable path helpers (`lgx.path/join`, `lgx.path/parent`)

## Context

lgx hardcodes `/` as the filesystem separator everywhere it builds or
walks paths: `cache.lg` (cache-dir layout, parent-dir extraction,
`:deps/root` joins), `config.lg` (`parent-dir`, `lgx.edn` path), and
`lgx.lg` (project-relative `:paths` joins). On Unix this works because
`/` is the native separator. On Windows it does not. let-go itself runs
on Go and is cross-platform; lgx is not.

let-go's stdlib (see
[knowledge base](../knowledge-base/let-go-stdlib-quick-ref.md)) exposes
`os/file-separator` (per-platform path-component separator) and
`os/path-separator` (PATH-list separator, already used in `runner.lg`).
It does not ship a higher-level `filepath/join` helper.

Introduce a tiny `lgx.path` namespace and convert all filesystem-path
joins and parent walks to use it. Out of scope: changing how user-
supplied paths are written in `lgx.edn` (those stay forward-slash by
convention, matching `tools.deps`), URL parsing in `cache.lg` (URLs are
always `/`), or wider portability work like Windows drive-letter
handling.

## API

New file `lgx/path.lg`:

```clojure
(ns lgx.path
  (:require [string :as str]))

(defn join
  "Join one or more path segments with the platform's file separator.
   Each segment may itself contain '/'; those are split and rejoined.
   Empty segments are dropped. Leading '/' on the first segment is
   preserved (absolute paths)."
  [& segments]
  (let [sep       os/file-separator
        parts     (mapcat #(str/split % "/") segments)
        absolute? (and (seq segments)
                       (str/starts-with? (first segments) "/"))
        cleaned   (filter #(not (str/blank? %)) parts)
        joined    (str/join sep cleaned)]
    (if absolute? (str sep joined) joined)))

(defn parent
  "Return the parent directory of path, or nil if path has no parent.
   Filesystem root returns nil. Trailing separator is ignored."
  [path]
  (let [sep     os/file-separator
        trimmed (if (and (> (count path) 1) (str/ends-with? path sep))
                  (subs path 0 (dec (count path)))
                  path)
        i       (str/last-index-of trimmed sep)]
    (cond
      (nil? i)  nil
      (zero? i) (when (> (count trimmed) 1) sep)
      :else     (subs trimmed 0 i))))
```

Design choices:

- **Variadic `join`**: vector form works via `apply` for free.
- **Smart split**: each argument is split on `/` before joining. Lets
  callers write `(path/join project "src/main/clojure")` without
  pre-splitting; on Windows it converts the embedded forward-slashes
  to backslashes.
- **Absolute preservation**: a leading `/` on the first segment stays.
  Windows drive letters are not handled — lgx never builds those.
- **`parent` returns `nil` at root**: mirrors `config.lg`'s current
  `parent-dir` semantics so `find-project!` halts the walk identically.

## Call-site conversion

Every file below adds `(:require [lgx.path :as path])` to its `ns`
form.

### `lgx/config.lg`

- Remove the private `parent-dir` helper (lines 7-12). Replace its only
  caller `(recur (parent-dir dir))` in `find-project!` with
  `(recur (path/parent dir))`.
- `(str dir "/" config-name)` (line 23) → `(path/join dir config-name)`.
- `(str project "/" config-name)` in `coords` (line 83) and `paths`
  (line 90) → `(path/join project config-name)`.
- Validation in `validate-rel-path!` (lines 37, 39) stays as-is. Add a
  short comment noting that `:deps/root` and `:paths` values use
  forward-slash by lgx convention, matching `tools.deps`.

### `lgx/cache.lg`

- `(str (os/getenv "HOME") "/.lgx")` (line 17) →
  `(path/join (os/getenv "HOME") ".lgx")`.
- `(str (home-dir) "/gitlibs")` (line 21) →
  `(path/join (home-dir) "gitlibs")`.
- `(str (gitlibs-root) "/" host "/" owner "/" repo "/" sha)` (line 49)
  → `(path/join (gitlibs-root) host owner repo sha)`.
- `(subs dest 0 (str/last-index-of dest "/"))` in
  `clone-and-checkout!` (line 75) → `(path/parent dest)`.
- `(str tmp "/.git")` (line 83) → `(path/join tmp ".git")`.
- `(str dir "/src")` in `resolve-source-path` (line 113) →
  `(path/join dir "src")`.
- `(str dir "/" normalized)` in `resolve-source-path` (line 106) →
  `(path/join dir root)` — pass the un-normalized `:deps/root` value
  directly; `path/join`'s smart split drops trailing slashes.
- **Remove `trim-trailing-slash`** (lines 96-99) and the binding of
  `normalized` (line 105). `path/join` subsumes the behavior.

### `lgx.lg`

- `(str project "/" p)` in `resolve-project-paths` (line 47) →
  `(path/join project p)`.

URL parsing in `cache.lg` (the `re-find #"^https?://..."` and
`str/last-index-of path "/"` against URL paths, lines 33-45) stays as
hardcoded `/`. URLs always use forward-slash regardless of OS.

`lgx/runner.lg` is untouched: it uses `os/path-separator`, which is
already correct.

## Tests

New `tests/path_test.lg`:

- **`join`**:
  - `join-two-segments` — `"a" "b"` → `(str "a" sep "b")`.
  - `join-variadic` — `"a" "b" "c"` → `(str "a" sep "b" sep "c")`.
  - `join-splits-embedded-slashes` — `"a" "b/c"` → `(str "a" sep "b" sep "c")`.
  - `join-preserves-absolute` — `"/a" "b"` → `(str sep "a" sep "b")`.
  - `join-drops-empty-segments` — `"a" "" "b"` → `(str "a" sep "b")`.
  - `join-drops-trailing-slash` — `"a" "b/"` → `(str "a" sep "b")`.
  - `join-single-segment` — `"a"` → `"a"`; `"/"` → `sep`.
- **`parent`**:
  - `parent-strips-last-component` — `"/a/b/c"` → `"/a/b"`.
  - `parent-root-returns-nil` — `"/"` → `nil`.
  - `parent-no-separator-returns-nil` — `"abc"` → `nil`.
  - `parent-trailing-separator` — `"/a/b/"` → `"/a"`.
  - `parent-one-level-from-root` — `"/abc"` → `"/"`.

All assertions use `os/file-separator` for the expected separator so
the tests pass on any platform.

`tests/run.sh`: add `tests/path_test.lg` to the lg invocations.

Existing tests (`cache_test.lg`, `config_test.lg`) keep their
hardcoded-`/` expected paths. They run on Unix CI and asserting
`path/join` output equality is the wrong layer — that's what
`path_test.lg` is for. `ensure-lib-normalizes-trailing-slash` keeps
passing because `path/join` handles the trailing slash.

## Docs

- `docs/ARCHITECTURE.md` — extend the "Components" listing with
  `lgx/path.lg     portable filesystem path helpers (join, parent)`.
- `docs/knowledge-base/let-go-stdlib-quick-ref.md` — append under
  "What's missing or hidden": "No `filepath/join` equivalent. lgx
  provides its own at `lgx/path.lg`."

No README change. The helper is internal.

## Out of scope (YAGNI)

- Windows drive-letter handling (`C:\`). lgx never builds those.
- Other path utilities (`basename`, `normalize`, `absolute?`). Add when
  a call site appears.
- Rewriting test fixtures' hardcoded-`/` expected paths.
- Changing the `lgx.edn` convention for user-supplied paths. They stay
  forward-slash on all platforms.

## Verification

- `make test` — all existing tests pass, plus the new `path_test.lg`
  suite.
- `grep -n '"/"\\|"/.*"' lgx/*.lg lgx.lg` — only matches in URL parsing
  and `validate-rel-path!` validation (forward-slash-by-convention).
- `lgx install` / `lgx run` against existing fixtures and examples on
  Unix continues to work identically.
