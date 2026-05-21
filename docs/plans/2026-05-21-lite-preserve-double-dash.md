# Preserve `--` in lg invocation; respect explicit user scripts

## Status: planned

## Context

The previous `--`-separator plan strips `--` from forward-args before
exec'ing `lg`. That works for arg routing but creates two problems
visible from the user's project:

1. **`-source-paths` leaks into `os/args`.** `lg` doesn't strip its own
   flags from the process argv, so a CLI parser inside `:main`
   processing `(rest os/args)` sees `-source-paths <X> main.lg`,
   parses `-source-paths` as the short flag `-s` plus garbage, and
   errors with `Unknown option: -s`. Hit by `tiny-cli`, `babashka/cli`,
   anything POSIX-shaped.
2. **Explicit-script + `--` is broken.** `lgx run foo.lg -- bar`
   currently triggers the inject path: pre = `[foo.lg]`, post = `[bar]`,
   result = `[foo.lg main.lg bar]` — two `.lg` files; `lg` errors.

## Behavior

Keep `--` in the outgoing args and detect an explicit script in the
pre-`--` slice. New matrix:

| Input                          | Output to `lg`                          |
| ------------------------------ | --------------------------------------- |
| `lgx run`                      | `lg <X> main.lg`                        |
| `lgx run --`                   | `lg <X> main.lg --`                     |
| `lgx run -- foo`               | `lg <X> main.lg -- foo`                 |
| `lgx run -r -- foo`            | `lg <X> -r main.lg -- foo`              |
| `lgx run foo.lg`               | `lg <X> foo.lg` (unchanged)             |
| `lgx run foo.lg -- bar`        | `lg <X> foo.lg -- bar` (no inject)      |
| `lgx run foo.cljc -- bar`      | `lg <X> foo.cljc -- bar` (no inject)    |
| `lgx run foo.clj -- bar`       | `lg <X> foo.clj -- bar` (no inject)     |
| `lgx run -e '(...)'`           | `lg <X> -e '(...)'` (unchanged)         |
| `lgx run -- foo` (no `:main`)  | error: `-- requires :main`              |

User script contract: the app finds its args by slicing `os/args`
past `--`:

```clojure
(def app-args
  (vec (rest (drop-while #(not= "--" %) os/args))))
```

`-source-paths` and the script path live *before* `--`; the app's CLI
parser only sees `app-args` and is shielded from lg's flags.

**Script-detection heuristic.** A pre-`--` token is treated as an
explicit script if its filename ends in `.lg`, `.cljc`, or `.clj`. The
same suffix check is already used in `user-args` for dev-vs-bundle
detection (`.lg` only); this extends it to the Clojure family.

## Implementation

`lgx.lg` — replace `cmd-run`'s cond body:

```clojure
(def ^:private script-exts #{".lg" ".cljc" ".clj"})

(defn- script-arg? [s]
  (some #(str/ends-with? s %) script-exts))

(defn- has-script? [args]
  (some script-arg? args))

(defn- cmd-run [forward-args verbose?]
  (let [project (config/find-project!)
        {:keys [results paths]} (project-basis project)
        main-script (config/main project)
        dd (index-of forward-args "--")
        args (cond
               (and (empty? forward-args) main-script)
               [(resolve-main-script! project main-script)]

               (neg? dd)
               forward-args

               :else
               (let [pre (vec (take dd forward-args))
                     post (vec (drop (inc dd) forward-args))]
                 (if (has-script? pre)
                   ;; user provided their own script; pass -- through
                   forward-args
                   (do (require-main-for-double-dash! main-script)
                       (let [script (resolve-main-script! project main-script)]
                         (vec (concat pre [script "--"] post)))))))]
    (print-installs! results)
    (runner/exec-lg! paths args verbose?)))
```

Two structural changes vs. today:

- **Stop stripping `--`.** When we inject, the new shape is
  `pre ++ [main "--"] ++ post`, not `pre ++ [main] ++ post`.
- **Skip inject when pre-args already include a script.** The `--`
  flows through unchanged, no `:main` requirement.

`script-exts` lives in `lgx.main` (private). No config or runner
changes; no behavior change for `cmd-build`, `cmd-task`, or `cmd-run`'s
no-arg path.

## Tests

`tests/e2e.sh` — adjust the existing `--` scenarios and add coverage
for the new cases.

- **31 (existing).** `lgx run -- list` — assert `os/args` of the
  script contains both `main.lg` and `--` and `list` (so `--` is
  preserved in the outgoing argv).
- **32 (existing).** `lgx run -- -v` — same shape, `-v` reaches main
  via post-`--` slice.
- **33 (existing).** `lgx --verbose run -r -- foo` — trace now reads
  `... -r main.lg -- foo` (note `--` between main and foo).
- **34 (existing).** `lgx run --` — trace reads `... main.lg --`.
- **35 (existing).** `lgx run -- foo` without `:main` → unchanged
  error.
- **36 (new).** `lgx run foo.lg -- bar` with `:main` set → no
  injection, lg runs `foo.lg`, script sees `bar` after `--`. Assert
  output reflects the explicit script, not `:main`.
- **37 (new).** `lgx run foo.lg -- bar` with `:main` *unset* → still
  works (no `:main` required since user gave an explicit script).
- **38 (new).** `lgx run foo.cljc -- bar` — heuristic recognizes
  `.cljc` suffix. Use a fixture file with a `.cljc` suffix that
  prints something distinctive; assert output.

`tests/config_test.lg` — no change.

## Docs

- `README.md`: rewrite the `:main` paragraph and example to show the
  new outgoing shape. Add a one-liner about the user-script idiom for
  finding args after `--`.
- `docs/ARCHITECTURE.md`: update the three-rule list under `lgx run`
  to reflect that `--` is preserved and that pre-`--` script
  detection skips injection. Mention the `.lg`/`.cljc`/`.clj` suffix
  set.

## Out of scope (YAGNI)

- Switching `-source-paths` to `LG_SOURCE_PATHS` env var. The `--`
  contract already shields user CLI parsers; saving the env-var
  switch as a separate option in case it's needed for other reasons
  later.
- Per-script-extension routing (`.clj` files invoking the Clojure
  reader differently). `lg` already loads `.cljc` via its existing
  resolver path.
- Detecting flag-with-value pairs in pre-args (`-bundle-base /path/lg`
  where the value ends in `lg`). The check is on `.lg`/`.cljc`/`.clj`
  full-suffix, not bare `lg`; false positives are unlikely.

## Verification

- `cd ../wtr && lgx run` produces no `Unknown option: -s` (tiny-cli
  parses only the post-`--` slice).
- `lgx run -- list` with `:main "main.lg"` → main runs and finds
  `list` after `--`.
- `lgx run -r -- foo` → verbose trace reads `-r main.lg -- foo`.
- `lgx run foo.lg -- bar` (with or without `:main`) → `foo.lg` runs,
  no `:main script not found` error.
- `make test` passes; `cljfmt check` clean.
