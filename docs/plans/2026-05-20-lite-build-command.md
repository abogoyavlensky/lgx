# Built-in `lgx build` command and `:targets/:bin`

## Status: planned

## Context

Users today bundle a project binary by invoking `lg` directly:

```
lg -source-paths "<resolved>" -b bin/myapp main.lg
```

That's verbose, easy to mistype, and duplicates information already
available in `lgx.edn` (`:paths`, `:deps`, `:main`). Add a built-in
`lgx build` subcommand that reads the project config and translates to
that `lg -b` invocation.

```edn
{:paths   ["src"]
 :main    "main.lg"
 :targets {:bin {:out "bin/myapp"}}
 :deps    {...}}
```

```
lgx build                           # lg -source-paths X -b bin/myapp main.lg
lgx build -bundle-base /path/to/lg  # cross-OS bundle
```

Step 1 supports only the `:bin` target. The map shape leaves room for
`:wasm`, `:web`, and friends without breaking the config format.

## Behavior

`lgx build [args...]`:

| State                                | Effect                                                   |
| ------------------------------------ | -------------------------------------------------------- |
| `:main` unset                        | exits 1: `lgx: :main is required for build`              |
| `:targets/:bin` unset                | exits 1: `lgx: :targets/:bin is required for build`      |
| `:main` script missing on disk       | exits 1: `lgx: :main script not found: <path>`           |
| `:out` parent dir missing            | auto-created (recursive `mkdir`)                         |
| all good                             | exec `lg [args...] -source-paths <X> -b <abs-out> <main>` |

Extra args come *before* `-source-paths` so they extend `lg`'s flag
list (real example: `-bundle-base /path/to/lg` for cross-OS builds).

`:out` is resolved to an absolute path under the project root before
being handed to `lg -b`, so `lgx build` works from any subdirectory
of the project — same subdir robustness applied to `:main` in the
prior plan.

The reserved-name set in `lgx/config.lg` grows to include `"build"`;
defining `:tasks {:build ...}` is rejected at parse time, matching the
policy already in place for `run`, `install`, etc. Pre-alpha — accepted
breaking change.

## Implementation

### `lgx/config.lg`

Extend `allowed-top-level` to `#{:deps :paths :tasks :main :targets}`.

Add `"build"` to `reserved-task-names`.

Add `validate-targets!`:

```clojure
(def ^:private allowed-targets #{:bin})
(def ^:private allowed-bin-keys #{:out})

(defn- validate-bin-target! [bin]
  (when-not (map? bin)
    (bad! ":targets/:bin must be a map" {}))
  (doseq [k (keys bin)]
    (when-not (contains? allowed-bin-keys k)
      (bad! (str ":targets/:bin has unknown key " k
                 ".\nAllowed keys: :out.") {:key k})))
  (when-not (contains? bin :out)
    (bad! ":targets/:bin must contain :out" {}))
  (validate-rel-path! ":targets/:bin :out" (:out bin) {:value (:out bin)}))

(defn- validate-targets! [targets]
  (when-not (map? targets)
    (bad! ":targets must be a map" {}))
  (doseq [k (keys targets)]
    (when-not (contains? allowed-targets k)
      (bad! (str ":targets has unknown target " k
                 ".\nAllowed targets: :bin.") {:target k})))
  (when-let [bin (:bin targets)]
    (validate-bin-target! bin)))
```

Wire into `validate-config!`:

```clojure
(when (contains? cfg :targets)
  (validate-targets! (:targets cfg)))
```

Add reader fn beside `paths`/`tasks`/`main`:

```clojure
(defn targets
  "Return the project's :targets map from lgx.edn, or {} if absent."
  [project] ...)
```

### `lgx.lg`

Lift `resolve-main-script!` so both `cmd-run` and `cmd-build` use it.

Add `cmd-build`:

```clojure
(defn- ensure-out-dir! [project rel-out]
  (let [abs (path/join project rel-out)
        parent (path/parent abs)]
    (when parent (mkdir parent))
    abs))

(defn- cmd-build [forward-args verbose?]
  (let [project (config/find-project!)
        {:keys [results paths]} (project-basis project)
        main-script (config/main project)
        targets (config/targets project)
        bin (:bin targets)]
    (when (nil? main-script)
      (write! *err* "lgx: :main is required for build (set :main in lgx.edn)\n")
      (os/exit 1))
    (when (nil? bin)
      (write! *err* (str "lgx: :targets/:bin is required for build "
                         "(set :targets {:bin {:out \"...\"}} in lgx.edn)\n"))
      (os/exit 1))
    (resolve-main-script! project main-script)
    (let [abs-out (ensure-out-dir! project (:out bin))
          args (vec (concat forward-args
                            ["-b" abs-out main-script]))]
      (print-installs! results)
      (runner/exec-lg! paths args verbose?))))
```

Wire dispatch in `dispatch`:

```clojure
"build" (cmd-build (vec rest-args) verbose?)
```

Update `base-usage`:

```
  lgx build [args...]          Bundle :main into :targets/:bin/:out via `lg -b`
                               (extra args forwarded to `lg` before -b)
```

### Tests

`tests/config_test.lg` — validation:
- `validate-config-accepts-targets-bin`
- `validate-config-rejects-targets-not-a-map`
- `validate-config-rejects-unknown-target` (e.g. `:wasm`)
- `validate-config-rejects-bin-not-a-map`
- `validate-config-rejects-bin-without-out`
- `validate-config-rejects-unknown-bin-key`
- `validate-config-rejects-blank-out`
- `validate-config-rejects-absolute-out`
- `validate-config-rejects-parent-traversal-out`
- `targets-returns-empty-when-absent`
- `targets-reads-fixture` — add `:targets {:bin {:out "bin/sample"}}` to
  `tests/fixtures/sample-project/lgx.edn`; assert
  `(config/targets ...)` returns `{:bin {:out "bin/sample"}}`.
- Extend the existing reserved-name doseq to confirm `"build"` is rejected.

`tests/e2e.sh` — new scenarios (no `supports_source_paths` gating
needed; the minimal projects below have no deps/paths):
- **25.** Happy path: `lgx build` produces `bin/myapp`; assert file
  exists and is executable.
- **26.** Auto-mkdir: `:out "out/nested/myapp"` succeeds and creates
  `out/nested/`.
- **27.** `:main` unset: exits non-zero with
  `lgx: :main is required for build` on stderr.
- **28.** `:targets/:bin` unset: exits non-zero with
  `lgx: :targets/:bin is required for build`.
- **29.** `:main` script missing: exits non-zero with
  `lgx: :main script not found:`.
- **30.** `lgx --verbose build`: trace line contains `-b` and resolved
  `:out`.

### Docs

`docs/ARCHITECTURE.md`:
- Update schema line in `lgx install` step 2 to include `:targets`.
- New "### `lgx build`" subsection under Data flow: resolve project
  basis → required-config checks → `mkdir` parent of `:out` → exec
  `lg [args] -source-paths X -b <abs-out> <main>`.

`README.md`:
- Add `:targets {:bin {:out "bin/myapp"}}` to the `lgx.edn` example.
- New paragraph after the `:main` paragraph documenting
  `:targets/:bin/:out` and the `lgx build` sugar shape. Mention
  forwarded args (cross-OS `-bundle-base` example).
- Add `lgx build [args...]` to the Commands list with the same
  description as the usage line.
- Flip the roadmap `lgx build` entry from `[ ]` to `[x]`.

## Out of scope (YAGNI)

- `:wasm`, `:web`, or any non-`:bin` target.
- Multi-target invocation (`lgx build` building several targets at once).
- Per-target `:main` override.
- A `:bundle-base` config key (CLI arg is fine; cross-OS is rare).
- Target selection arg (`lgx build wasm`) — only `:bin` exists.
- Pre-flight check for `lg -b` output-vs-source-dir collision (let `lg`
  complain; documented in `docs/knowledge-base/let-go-gotchas.md`).
- Per-subcommand help (`lgx build --help`); `lgx help` is the path
  today.

## Verification

- `lgx.edn` with `:main` and `:targets {:bin {:out "bin/myapp"}}` plus a
  `main.lg` printing `:ok`; `lgx build && ./bin/myapp` prints `:ok`.
- Same config from a subdir: `cd subdir && lgx build` still produces
  `<project>/bin/myapp`.
- `:out "out/nested/myapp"` with no `out/` on disk: `lgx build` creates
  the parent and produces the binary.
- `:targets {:bin {:out "bin/x"}}` without `:main`: clear error.
- `:main "main.lg"` without `:targets`: clear error.
- `:main "missing.lg"`: clear `:main script not found` error.
- `lgx --verbose build -bundle-base /path/to/lg`: trace shows
  `+ lg -bundle-base /path/to/lg -source-paths … -b /abs/bin/myapp main.lg`.
- Existing `lg tests/config_test.lg`, `make test`, `cljfmt check` all
  pass.
