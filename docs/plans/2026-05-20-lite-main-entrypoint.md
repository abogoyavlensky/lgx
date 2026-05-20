# Top-level `:main` entrypoint for `lgx run`

## Status: planned

## Context

Today `lgx run` always requires the user to spell out the script path:

```
lgx run main.lg
lgx run -e '(...)'
```

For projects with a stable entrypoint that is repeatedly invoked, that
extra path is just noise. Add an optional top-level `:main` key to
`lgx.edn` that supplies a default script when `lgx run` is invoked with
zero forwarded arguments:

```edn
{:paths ["src"]
 :main  "main.lg"
 :deps  {...}}
```

```
lgx run             # runs main.lg
lgx run foo.lg      # runs foo.lg
lgx run -r          # runs lg -r (no script)
```

The rule is intentionally strict: any args at all — positional *or*
flag — disable the fallback. If you want to pass args, spell out the
script. Keeps the substitution logic and mental model tiny.

`:main` is opt-in. Absence means `lgx run` with no args keeps today's
behavior (passes no script to `lg`).

## Behavior

| Invocation         | `:main` set        | `:main` unset                |
| ------------------ | ------------------ | ---------------------------- |
| `lgx run`          | runs `:main`       | passes no script to `lg`     |
| `lgx run foo.lg`   | runs `foo.lg`      | runs `foo.lg`                |
| `lgx run -r`       | runs `lg -r`       | runs `lg -r`                 |
| `lgx run -e '...'` | runs `lg -e '...'` | runs `lg -e '...'`           |

Validation: `:main` must be a non-blank string, no leading `/`, no `..`
segments. Same shape rule already applied to `:paths` entries — reuse
`validate-rel-path!`.

Existence: not checked at parse time. When `:main` is being injected
and the resolved file does not exist, lgx exits non-zero with:

```
lgx: :main script not found: main.lg
```

User-supplied scripts (`lgx run foo.lg`) are not pre-checked — `lg`
already handles that and it preserves current behavior.

## Implementation

### `lgx/config.lg`

Extend `allowed-top-level` to `#{:deps :paths :tasks :main}`.

Add `validate-main!` and wire into `validate-config!`:

```clojure
(defn- validate-main! [value]
  (validate-rel-path! ":main" value {:value value}))

;; in validate-config!
(when (contains? cfg :main)
  (validate-main! (:main cfg)))
```

Add a reader fn beside `paths`/`tasks`:

```clojure
(defn main
  "Return the project's :main entrypoint string from lgx.edn, or nil if absent."
  [project]
  (let [config-path (path/join project config-name)
        cfg (validate-config! (edn/read-string (slurp config-path)))]
    (:main cfg)))
```

### `lgx.lg`

Update `cmd-run` to inject `:main` when no args were forwarded, and
to pre-check the file exists when it does:

```clojure
(defn- cmd-run [forward-args verbose?]
  (let [project (config/find-project!)
        {:keys [results paths]} (project-basis project)
        main-script (config/main project)
        args (if (and (empty? forward-args) main-script)
               (let [abs (path/join project main-script)]
                 (when-not (file-exists? abs)
                   (write! *err* (str "lgx: :main script not found: "
                                      main-script "\n"))
                   (os/exit 1))
                 [main-script])
               forward-args)]
    (print-installs! results)
    (runner/exec-lg! paths args verbose?)))
```

The relative path is passed to `lg` (not the absolute one) so trace
output and any error messages stay readable.

Update `base-usage`:

```
  lgx run [script] [args...]   Run a script via `lg` with deps on the source path
                               (uses :main from lgx.edn when script is omitted)
```

### Tests

`tests/config_test.lg` — validation:
- `validate-config-accepts-main` — `{:main "main.lg"}` round-trips.
- `validate-config-accepts-nested-main` — `{:main "scripts/dev.lg"}`.
- `validate-config-rejects-non-string-main` — `{:main 5}` throws.
- `validate-config-rejects-blank-main` — `{:main ""}` and `{:main "   "}` throw.
- `validate-config-rejects-absolute-main` — `{:main "/abs/main.lg"}` throws.
- `validate-config-rejects-parent-traversal-main` — `{:main "../main.lg"}` throws.
- `main-returns-nil-when-absent` — `(config/main ...)` on a fixture without
  `:main` returns `nil`.
- `main-reads-fixture` — add `:main "main.lg"` to
  `tests/fixtures/sample-project/lgx.edn`, assert `(config/main ...)`
  returns `"main.lg"`. Existing fixture-backed tests must keep passing.

`tests/e2e.sh` — new scenarios:
- Scenario 21 (`supports_source_paths`): `:main` set, `lgx run` with no
  args executes the main script and prints its output.
- Scenario 22 (`supports_source_paths`): `:main` set, `lgx run other.lg`
  still runs `other.lg`.
- Scenario 23 (no `supports_source_paths` gate): `:main` set but file
  missing, `lgx run` exits non-zero with
  `lgx: :main script not found:` on stderr.
- Scenario 24: `:main` unset, `lgx run` with no args keeps today's
  behavior (no script injected — exits with whatever `lg` does on bare
  invocation).

### Docs

`docs/ARCHITECTURE.md`:
- Update the schema line in `lgx install` step 2 to include `:main`.
- Under `lgx run` data-flow, add a short note: when `forward-args` is
  empty and the project sets `:main`, lgx substitutes that path before
  exec; any args at all disable the substitution.

`README.md`:
- Add `:main "main.lg"` to the `lgx.edn` sample.
- New paragraph after the `:paths` paragraph explaining `:main` and the
  strict "any args → no fallback" rule.
- Swap the `lgx run [args...]` Commands line for `lgx run [script]
  [args...]` and mention the `:main` fallback.

## Out of scope (YAGNI)

- Per-context `:main` (would belong in a future contexts feature, like
  `:tasks` extras).
- `:main` as a vector of scripts. One entrypoint, one path.
- Smart flag/positional parsing (option 3 from the design discussion).
  Strict rule is simpler and matches user intent.
- Auto-discovery of `main.lg` when `:main` is absent.

## Verification

- `lgx.edn` with `:main "main.lg"` and a `main.lg` printing `:ok`;
  `lgx run` prints `:ok`.
- Same config, `lgx run -e '(println :other)'`; the `-e` form runs, not
  `main.lg`.
- `:main "missing.lg"` not on disk; `lgx run` exits non-zero with the
  `:main script not found:` error.
- `lgx.edn` without `:main`; `lgx run` behaves exactly as before
  (passes no script).
- `lgx install` is unchanged regardless of `:main`.
