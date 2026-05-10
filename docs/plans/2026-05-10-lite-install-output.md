# Quieter `lgx install` / `lgx run` output for already-cached deps

## Context

`lgx install` always prints `installing N dep(s)...`, then a per-dep line
for every coord, then `done` — even when every dep is already in the
gitlibs cache and nothing is fetched. `lgx run` calls the same
`ensure-all!` path but silently, so the user gets no signal when a `run`
triggers a clone.

Two changes:

1. `lgx install` should log only deps that were actually fetched. When
   everything is cached, print one line: `all deps up to date`.
2. `lgx run` should print the same install block as `lgx install` when
   it triggers fetches, then run the script. When nothing was fetched,
   it stays silent.

The signal users want is "did this command do network work?" — phrased
identically across both commands.

## Behavior

### `lgx install`

Three terminal states:

| Case                              | Output                                                                                  |
| --------------------------------- | --------------------------------------------------------------------------------------- |
| `lgx.edn` has no deps             | `no deps in lgx.edn` (unchanged)                                                        |
| Deps exist, all already cached    | `all deps up to date` (new)                                                             |
| Some deps fetched (N new of M)    | `installing N dep(s)...` + one `  <lib> -> <path>` line per **new** dep + `done`        |

The header count and per-line list reflect newly-installed deps only —
already-cached deps are not mentioned.

### `lgx run [args...]`

- All deps cached → silent, script runs immediately.
- Some deps need fetching → identical install block to `lgx install`
  (`installing N dep(s)...` + new-only lines + `done`), then the script
  runs.
- No deps in `lgx.edn` → script runs with no `--source-paths` flag, as
  today.

`lgx run` never prints `all deps up to date`; that line is install-only
noise from a script-running perspective.

## Implementation

### `lgx/cache.lg`

Change `ensure-lib!` to return a map instead of a bare path:

```clojure
{:path "<src dir or repo root>"
 :installed? <true if this call did the clone, false if dir already existed>}
```

Determine `:installed?` from the existing `(file-exists? dir)` check —
no extra network calls, no second stat. The path-resolution tail (src
subdir vs repo root) is unchanged.

### `lgx.lg`

`ensure-all!` returns the new shape per dep:

```clojure
(defn- ensure-all! [coords]
  (mapv (fn [[lib c]]
          (let [{:keys [path installed?]} (cache/ensure-lib! c)]
            {:lib lib :path path :installed? installed?}))
        coords))
```

New private helper, used by both subcommands:

```clojure
(defn- print-installs! [results]
  (let [new-installs (filter :installed? results)]
    (when (seq new-installs)
      (println "installing" (count new-installs) "dep(s)...")
      (doseq [{:keys [lib path]} new-installs]
        (println " " lib "->" path))
      (println "done"))))
```

Silent when nothing was fetched — the caller decides what to print in
that case.

`cmd-install` gains the all-cached branch:

```clojure
(defn- cmd-install []
  (let [project (config/find-project!)
        coords  (config/coords project)]
    (if (empty? coords)
      (println "no deps in lgx.edn")
      (let [results (ensure-all! coords)]
        (if (some :installed? results)
          (print-installs! results)
          (println "all deps up to date"))))))
```

`cmd-run` reuses the helper and keeps moving:

```clojure
(defn- cmd-run [forward-args]
  (let [project (config/find-project!)
        coords  (config/coords project)
        results (ensure-all! coords)
        paths   (mapv :path results)]
    (print-installs! results)
    (runner/exec-lg! paths forward-args)))
```

No changes to `runner.lg` or `config.lg`.

## Verification

- `lgx install` with empty cache and N coords → header says `N`, lists
  N lines, ends in `done`.
- `lgx install` again, no edn changes → `all deps up to date`.
- Add one new coord to `lgx.edn`, `lgx install` → header says `1`, lists
  only the new lib, ends in `done`. Existing libs are not mentioned.
- `lgx install` with empty `:deps` → `no deps in lgx.edn` (regression
  check).
- `lgx run -e '(println :ok)'` with all deps cached → prints only `:ok`.
- Same with one missing dep → install block first, then `:ok`.
