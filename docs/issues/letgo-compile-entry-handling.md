# lg compile: -main runs twice without an ns form or via apply, and a *.main namespace fails to build

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** draft, prefill link ready, not filed yet. lgx rejects cases 1 and 3 for `:main` in `:target :native` and documents case 2.

## Summary

Three ways `lg compile` builds a program that misbehaves, or fails to build, depending only on how the entry file is written. Seen at `d0108ba6`.

1. **No `ns` form: `-main` runs twice.**

   ```clojure
   (require '[app.util :as u])
   (defn -main [& _] (println "hi"))
   (-main)
   ```

   The binary prints `hi` twice. With `(ns app.core ...)` added, it prints once. `omitTopLevelEntryCall` does not drop the call when the entry file has no `ns`.

2. **`(apply -main *command-line-args*)` runs `-main` twice.** Only `(-main ...)`, optionally inside `do` or `(when-not *compiling-aot* ...)`, is recognized as the entry call.

3. **A namespace whose last segment is `main` fails to build.** `(ns myapp.main)` lowers to Go `package main`:

   ```
   main.go:11:2: import "lgprogram/myapp/main" is a program, not an importable package
   ```

   The same happens for any lowered input namespace named `*.main`, e.g. `task.main`.

## Suggestions

- 1 and 2: drop the entry call by resolved var rather than by spelling, or document the accepted forms in `lg compile -h`.
- 3: mangle a `main` package name (e.g. `main_`) in the gogen package-name rule.

Found while adding `:target :native` to lgx (abogoyavlensky/lgx#60).
