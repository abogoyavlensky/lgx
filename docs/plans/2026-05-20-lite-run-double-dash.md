# `--` separator for `lgx run` with auto-injected `:main`

## Status: planned

## Context

The current `:main` rule for `lgx run` is strict: any args at all
disable the fallback. That works for explicit scripts but breaks the
common "my project is a CLI tool" pattern:

```
lgx run list        # today: lg looks for a script file named "list"
lgx run -v          # today: lg interprets -v as its own flag
```

Both should let the user invoke their `:main` script with `list` /
`-v` as *application* args. The natural shape is `--`, the same
separator npm, cargo, deno, and pnpm use to mean "everything after
this is for the script, not the runner."

## Behavior

Three rules for `cmd-run`. Order matters — first match wins.

1. **No forwarded args + `:main` set** → inject `:main`. (Unchanged.)
2. **`--` appears in forwarded args** → split at the *first* `--`,
   always inject `:main`. Left side becomes `lg` flags, right side
   becomes user args. The `--` itself is stripped. Final command:
   `lg <lg-flags...> -source-paths <X> <main> <user-args...>`. If
   `:main` is unset → exit 1 with
   `lgx: -- requires :main to be set in lgx.edn`.
3. **Anything else** → strict; no inject. (Unchanged.)

Matrix:

| Invocation                  | With `:main "main.lg"`        |
| --------------------------- | ----------------------------- |
| `lgx run`                   | `lg <X> main.lg`              |
| `lgx run --`                | `lg <X> main.lg`              |
| `lgx run -- list`           | `lg <X> main.lg list`         |
| `lgx run -- -v`             | `lg <X> main.lg -v`           |
| `lgx run -r --`             | `lg <X> -r main.lg`           |
| `lgx run -r -- foo`         | `lg <X> -r main.lg foo`       |
| `lgx run foo.lg`            | `lg <X> foo.lg` (unchanged)   |
| `lgx run foo.lg bar`        | `lg <X> foo.lg bar` (unchanged) |
| `lgx run -e '(...)'`        | `lg <X> -e '(...)'` (unchanged) |

Without `:main`:

| Invocation                  | Effect                                |
| --------------------------- | ------------------------------------- |
| `lgx run -- list`           | error: `-- requires :main`            |
| `lgx run foo.lg bar`        | `lg <X> foo.lg bar` (unchanged)       |

**Mixing explicit script with `--`** (`lgx run main.lg -- list`):
we don't detect this. The split still happens, both arms are
concatenated with `:main` between them, and `lg` ends up with two
script paths and will error. Users should pick one form or the other;
the README will document the supported shapes.

**Multiple `--` tokens.** Only the first `--` is the separator; any
later `--` is a literal arg passed to the script. Matches the standard
getopt behavior.

## Implementation

`lgx.lg` — replace the current `cmd-run`:

```clojure
(defn- split-on-double-dash [args]
  (let [i (.indexOf args "--")]  ; helper below
    (if (neg? i)
      [args nil]
      [(vec (take i args)) (vec (drop (inc i) args))])))
```

let-go doesn't expose `.indexOf` for vectors; implement with a tiny
loop or `(first (keep-indexed #(when (= "--" %2) %1) args))`.

```clojure
(defn- index-of [v x]
  (loop [i 0 xs (seq v)]
    (cond
      (nil? xs) -1
      (= x (first xs)) i
      :else (recur (inc i) (next xs)))))

(defn- cmd-run [forward-args verbose?]
  (let [project (config/find-project!)
        {:keys [results paths]} (project-basis project)
        main-script (config/main project)
        dd (index-of forward-args "--")
        args (cond
               (and (empty? forward-args) main-script)
               [(resolve-main-script! project main-script)]

               (not (neg? dd))
               (do (when (nil? main-script)
                     (write! *err* "lgx: -- requires :main to be set in lgx.edn\n")
                     (os/exit 1))
                   (let [pre (vec (take dd forward-args))
                         post (vec (drop (inc dd) forward-args))
                         script (resolve-main-script! project main-script)]
                     (vec (concat pre [script] post))))

               :else
               forward-args)]
    (print-installs! results)
    (runner/exec-lg! paths args verbose?)))
```

No config-shape changes; no new validation; `resolve-main-script!` is
reused for both inject paths.

## Tests

`tests/e2e.sh` — new scenarios. None need `supports_source_paths`
gating; the test projects below have no deps/paths.

- **31.** `lgx run -- list` with `:main` set → `main` runs, sees arg
  `list`. Assert main's printed output contains `list`.
- **32.** `lgx run -- -v` → main runs and sees `-v` as an app arg
  (proves we shield single-dash flags from lg).
- **33.** `lgx run -r -- foo` → asserts the `-r` flag reaches lg
  (via `--verbose` trace, since interactive REPL can't be exercised
  in CI).
- **34.** `lgx run --` (just the separator) → equivalent to bare
  `lgx run`; injects `:main` with no user args.
- **35.** `lgx run -- foo` when `:main` is unset → exits 1 with
  `lgx: -- requires :main to be set in lgx.edn`.

Two-arm assertion for #33: use `--verbose` and grep the stderr trace
for `-r` appearing before the main script path.

`tests/config_test.lg` — no change (config schema is unchanged).

## Docs

- `README.md`: update the `:main` paragraph to mention the `--`
  separator and one example (`lgx run -- list`).
- `docs/ARCHITECTURE.md`: under `lgx run`, replace the "any args at
  all disable the substitution" sentence with the three-rule list
  above.

## Out of scope (YAGNI)

- Detecting/erroring on mixed explicit-script + `--`. Let `lg` complain.
- Smart positional-vs-flag parsing.
- Supporting `--` for `lgx build` (build doesn't take user args; the
  injected `<main>` is the script, no runtime args).

## Verification

- `lgx run -- list` from a project with `:main "main.lg"` and a main
  that prints its args → prints `list`.
- `lgx run -- -v` → main sees `-v` (not lg).
- `lgx --verbose run -r -- foo` → trace contains `-r main.lg foo`.
- `lgx run --` → same as `lgx run` (injects `:main`).
- `lgx run -- foo` without `:main` → clear error.
- Existing `lgx run`, `lgx run foo.lg`, `lgx run -e '...'` cases
  unchanged.
- `make test` passes.
