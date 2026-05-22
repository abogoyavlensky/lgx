# `:local/root` coord option

Status: Completed on 2026-05-12.

## Context

`lgx.edn` coords today must be git-pinned (`:git/url` plus `:git/sha`
or `:git/tag`). When iterating on a library alongside its consumer, the
only options are pushing to a branch and re-resolving, or symlinking
into the gitlibs cache. Both are friction.

`tools.deps` solves this with `:local/root`: a coord that points at a
directory on disk instead of fetching one. Add the same mechanism to
lgx. A coord with `:local/root` skips the cache entirely; lgx resolves
its source path the same way it does for git coords (`:deps/root` if
set, else `src/` if present, else the directory itself) and prepends it
to `lg -source-paths`.

## Coord shape

A coord is either a **git coord** or a **local coord** — never both.

| Coord                                                          | Verdict |
| -------------------------------------------------------------- | ------- |
| `{:git/url … :git/sha …}`                                      | git     |
| `{:git/url … :git/tag …}`                                      | git     |
| `{:local/root "../mylib"}`                                     | local   |
| `{:local/root "../mylib" :deps/root "src/main/clj"}`           | local   |
| `{:local/root "…" :git/url "…"}` or any `:local/*` + `:git/*` mix | error   |

### `:local/root` path forms

`:local/root` is a string and is interpreted as a filesystem path.
Unlike `:deps/root`, it allows the full path vocabulary:

| Form         | Example              | Resolves to                       |
| ------------ | -------------------- | --------------------------------- |
| Absolute     | `/abs/path/to/mylib` | `/abs/path/to/mylib` (used as-is) |
| Relative dot | `./libs/x`           | `<project>/libs/x`                |
| Bare         | `libs/x`             | `<project>/libs/x`                |
| With `..`    | `../mylib`           | `<project>/../mylib`              |

Validation rejects only: non-string, blank string. Tilde (`~`) is **not**
expanded — it's a literal segment. We don't canonicalize (`..` stays in
the path); the OS handles it.

## Resolution and errors

Once the base directory is determined (project-relative join or
absolute), the same probe used for git coords applies:

```
base = <project>/<:local/root>   (or :local/root itself if absolute)

with :deps/root:    source = base + :deps/root          (must exist)
without :deps/root: source = base/src   if base/src exists
                             base       otherwise
```

Two hard errors at `ensure-lib!` time:

1. **Base dir missing** — `":local/root <value> not found"`, ex-data
   `{:local <value> :resolved <absolute>}`.
2. **`:deps/root` subdir missing** — existing message, reused via the
   shared `resolve-source-path` helper.

Wrong local paths are configuration errors, not runtime quirks. No
warn-and-continue.

## Install / run output

Local deps are silent:

- They never appear in `installing N dep(s)...` — `:installed?` is
  always `false`.
- They don't bump the count.
- `all deps up to date` fires when no *git* dep needed cloning, even if
  locals are present.
- `lgx run` stays silent about locals; they just show up on
  `-source-paths`.

Rationale: locals aren't fetched, cached, or pinned. They're a
developer affordance; surfacing them on every run is noise.

`lgx install` with **only** local deps prints `all deps up to date`
(accurate — nothing needed installing). Empty `:deps` still prints
`no deps in lgx.edn`.

## Implementation

### `lgx/config.lg`

Rework `validate-coord!` to branch on coord kind. The `:local/root` and
git keysets are mutually exclusive; mixed coords are rejected up front.

```clojure
(def ^:private git-keys   #{:git/url :git/sha :git/tag})

(defn- validate-local-root! [lib value]
  (when-not (string? value)
    (bad! (str lib " :local/root must be a string") {:lib lib}))
  (when (str/blank? value)
    (bad! (str lib " :local/root must be non-blank") {:lib lib})))

(defn- validate-coord! [lib coord]
  (when-not (map? coord)
    (bad! (str lib " coord must be a map") {:lib lib}))
  (let [has-local? (contains? coord :local/root)
        has-git?   (some #(contains? coord %) git-keys)]
    (when (and has-local? has-git?)
      (bad! (str lib " coord cannot mix :local/root with :git/* keys")
            {:lib lib}))
    (if has-local?
      (validate-local-root! lib (:local/root coord))
      (validate-git-coord! lib coord)))         ; extracted from current body
  (when (contains? coord :deps/root)
    (validate-rel-path! (str lib " :deps/root")
                        (:deps/root coord) {:lib lib}))
  coord)
```

`validate-git-coord!` is the current `:git/url` + `:git/sha`/`:git/tag`
block, extracted verbatim so the local branch can skip it.

### `lgx/cache.lg`

Two changes:

1. `ensure-lib!` takes a new `project` arg so local paths can be
   resolved relative to the project root.
2. A new `resolve-local-base` helper handles absolute vs. relative.

```clojure
(defn- resolve-local-base [project local]
  (if (str/starts-with? local "/")
    local
    (path/join project local)))

(defn ensure-lib! [coord project]
  (let [root  (:deps/root coord)
        local (:local/root coord)]
    (if local
      (let [dir (resolve-local-base project local)]
        (when-not (file-exists? dir)
          (throw (ex-info (str ":local/root " local " not found")
                          {:local local :resolved dir})))
        {:path (resolve-source-path dir root local nil)
         :installed? false})
      ;; existing git branch, unchanged
      (let [url        (:git/url coord)
            sha        (or (:git/sha coord)
                           (resolve-tag->sha url (:git/tag coord)))
            dir        (coord-dir url sha)
            installed? (not (file-exists? dir))]
        (when installed?
          (clone-and-checkout! url sha dir))
        {:path (resolve-source-path dir root url sha)
         :installed? installed?}))))
```

`resolve-source-path` already takes `url`/`sha` only for error
messages — passing the local-root string as `url` and `nil` as `sha`
yields a sensible `:deps/root <root> not found in ../mylib` message and
keeps the helper untouched.

### `lgx.lg`

Wire `project` through to `cache/ensure-lib!`. Both callers already
have it in scope.

```clojure
(defn- ensure-all! [project coords]
  (mapv (fn [[lib c]]
          (let [{:keys [path installed?]} (cache/ensure-lib! c project)]
            {:lib lib :path path :installed? installed?}))
        coords))
```

No changes to `runner.lg` or `path.lg`.

## Tests

### `tests/config_test.lg`

- `validate-config-accepts-local-root` — `{:local/root "../mylib"}` passes.
- `validate-config-accepts-local-root-with-deps-root` — combined coord passes.
- `validate-config-accepts-absolute-local-root` — `"/abs/path"` passes.
- `validate-config-accepts-local-root-with-dotdot` — `"../sibling"` passes.
- `validate-config-rejects-blank-local-root` — `""` and `"   "` throw.
- `validate-config-rejects-non-string-local-root` — `:local/root 5` throws.
- `validate-config-rejects-mixed-local-and-git` — `:local/root` paired with
  `:git/url`, `:git/sha`, or `:git/tag` all throw.

### `tests/cache_test.lg`

- `ensure-lib-resolves-relative-local-root` — `/tmp/proj/lib/src/` exists;
  coord `{:local/root "lib"}` against `/tmp/proj` → `/tmp/proj/lib/src`,
  `:installed? false`.
- `ensure-lib-resolves-absolute-local-root` — `{:local/root "/tmp/abs-lib"}`
  resolves to `/tmp/abs-lib` (or its `src/` if present).
- `ensure-lib-applies-deps-root-on-local` — `{:local/root "lib" :deps/root
  "src/main"}` resolves to `<proj>/lib/src/main`.
- `ensure-lib-local-throws-when-base-missing` — `{:local/root "./nope"}`
  throws `":local/root ./nope not found"`.
- `ensure-lib-local-throws-when-deps-root-missing` — base exists,
  `:deps/root` doesn't.
- `ensure-lib-local-uses-dir-when-no-src` — local base with no `src/`
  resolves to the base itself.

### `tests/e2e.sh`

Add a scenario: fixture project with `{:my/lib {:local/root "../mylib"}}`
and a sibling `mylib/src/mylib.lg` exporting one symbol. `lgx install`
prints `all deps up to date` (no count, no per-dep line). `lgx run
script.lg` requires `mylib` and prints the expected value, proving the
path made it onto `-source-paths`.

## Docs

### `docs/ARCHITECTURE.md`

- `lgx install` step 2: extend the schema line to show `:local/root` as
  an alternative to `:git/url` + sha/tag.
- New subsection under "Cache layout" — *Local deps*: explains that
  `:local/root` bypasses the cache, resolves project-relative or
  absolute, applies the same `src/` probe / `:deps/root` override as
  git coords, and is silent in install output.
- "What lgx is not" — unchanged. `:local/root` does not make lgx
  transitive: we still don't read the local lib's own `lgx.edn`.

### `README.md`

Update the `lgx.edn` example to include a local coord:

```edn
{:paths ["src" "resources"]
 :deps
 {some-user/let-go-async {:git/url "https://github.com/some-user/let-go-async"
                          :git/tag "v0.2.0"}
  org.clojure/tools.cli {:git/url "https://github.com/clojure/tools.cli"
                         :git/sha "0123456789abcdef0123456789abcdef01234567"
                         :deps/root "src/main/clojure"}
  my/lib {:local/root "../my-lib"}}}
```

Add a paragraph after the `:deps/root` one:

> Use `:local/root` instead of `:git/url` to point at a directory on
> disk — handy when iterating on a library alongside the project. The
> path may be relative to the project root (`../sibling`, `./libs/x`)
> or absolute (`/abs/path`). `:deps/root` still applies, so
> `{:local/root "../mylib" :deps/root "src/main/clojure"}` works the
> same as with a git coord. Local deps bypass the gitlibs cache
> entirely and don't appear in install output. A coord uses either
> `:local/root` or `:git/*` — mixing them is an error.

Update the roadmap with a checked entry next to `:deps/root`:

```markdown
- [x] **Per-coord `:local/root`.** Point a dep at a local directory
  instead of a git URL — matches tools.deps' `:local/root`.
```

## Example

Add `examples/local-dep/` mirroring `examples/with-lib/`:

- `project/lgx.edn` containing `{:deps {my/lib {:local/root "../mylib"}}}`
- `project/main.lg` requiring `my.lib` and calling one function
- `mylib/src/my/lib.lg` exporting that function
- `README.md` showing the `cd project && lgx run main.lg` invocation

## Out of scope (YAGNI)

- Reading the local lib's own `lgx.edn` — keeps lgx non-transitive.
- Tilde (`~`) expansion — explicitly literal. Users wanting
  `$HOME`-relative paths can give an absolute path.
- `:local/sha`-style sanity checks (e.g. "warn if local dir has
  uncommitted changes") — dev-time noise.
- Watching local dirs for change — `lgx run` re-stats on every
  invocation; that's enough.

## Verification

- `lgx install` with only local deps → `all deps up to date`. No
  per-dep lines.
- `lgx install` with mixed local + git → install output counts only the
  git deps that actually cloned.
- `lgx run` with a local dep → script can require namespaces from the
  local lib; modifying a file under the local dir is picked up on the
  next run (no cache invalidation needed).
- Bad `:local/root` (missing dir) → hard error with the path that was
  tried.
- Bad `:deps/root` under a good `:local/root` → existing `:deps/root`
  error fires, citing the local path as the source.
- Mixed `:local/root` + `:git/url` → config validation throws before
  any side effects.

## Completion summary

Implemented `:local/root` as a coord alternative to git coords. Config
validation now accepts local roots, rejects blank or non-string roots,
and rejects coords that mix `:local/root` with `:git/*` keys. Cache
resolution now handles project-relative and absolute local roots,
applies the existing `src/` probe and `:deps/root` override, and reports
locals as `:installed? false`.

Updated `lgx install` and `lgx run` to pass the project root through to
cache resolution. Added unit coverage for config and cache behavior,
e2e coverage for local-only install output and mixed local/git install
output, plus conditional local-run coverage when the available `lg`
supports `-source-paths`. Updated README, architecture docs, and added
`examples/local-dep/`.

Verification: `make test` passes. In this environment, the local-run e2e
branch is skipped because `lg 2.0.2` does not support `-source-paths`;
the test runs automatically when `LGX_LG` or `lg` points at a compatible
let-go binary.
