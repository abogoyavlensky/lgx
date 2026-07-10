# Issue: compatibility gaps found by clojure.tools.cli

**Repo:** [nooga/let-go](https://github.com/nooga/let-go)

**Status:** resolved on `clojure-cli-compat` (2026-07-10)

## Summary

Loading and calling
[`org.clojure/tools.cli` v1.4.256](https://github.com/clojure/tools.cli/tree/v1.4.256)
exposed five independent Clojure compatibility gaps in let-go. After the
fixes below, `parse-opts` handles required values, boolean flags, defaults,
validation, positional arguments, summaries, and errors under let-go.

The runnable example is
[`examples/clojure-libs/with-tools-cli/`](../../examples/clojure-libs/with-tools-cli).
Its coordinate needs `:deps/root "src/main/clojure"` because tools.cli does
not use the usual top-level `src` layout.

## Resolved gaps

### Function preconditions and postconditions

tools.cli uses `defn` postconditions with `%`. let-go now expands `:pre` and
`:post` condition maps for single- and multi-arity functions, evaluates the
body once, and binds `%` hygienically for postconditions. The reader also
keeps `%` as a normal symbol outside anonymous `#(...)` forms.

Fixed in let-go commits `b2bdc14` and `4490e4f`. Regression coverage lives in
`test/fn_prepost_test.lg` and `pkg/compiler/reader_test.go`.

### Empty typed catch bodies

tools.cli contains a valid typed `catch` clause with no body. Both the normal
compiler and the IR builder previously parsed the catch binding as a body form
when the exception type used the simple class form.

Fixed in let-go commits `188facd` and `648ee9b`. Regression coverage lives in
`test/catch_class_test.lg`.

### Compile-only `Exception` constructor

tools.cli references `(Exception. message)` on a path that should not run in
the successful parse. let-go now resolves `Exception.` through a compile-only
stub. Calling the stub fails loudly instead of fabricating a JVM exception.

Fixed in let-go commit `77d7534`. Regression coverage lives in
`test/clojure_compat_aliases_test.lg`.

### Regex result semantics

Two Go-to-Clojure result conversions affected option parsing:

- `re-seq` returned an empty list for no match. The list is truthy, so
  predicate use in tools.cli's `condp` chose a nonmatching option branch.
  It now returns `nil`.
- Go's string submatch helpers returned `""` for both an absent optional
  capture and a participating empty capture. `re-find` and `re-seq` now use
  Go's index results, mapping an absent group to `nil` and preserving `""`
  for a participating zero-length group.

Fixed in let-go commits `f0c78ce` and `6f27f51`. Regression coverage lives in
`test/builtins_test.lg` and `test/shuffle_reseq_test.lg`.

### Four-argument `partition`

tools.cli groups validation predicates and messages with
`(partition 2 2 (repeat nil) validate)`. let-go's `partition` supported only
two and three arguments. It now supports Clojure's padding arity, including
infinite padding, finite padding that leaves a short final group, skipped
input, and empty input.

Fixed in let-go commit `1619c31`. Regression coverage lives in
`test/seq_test.lg`.

## Verification

With a fresh local `lg`, this input:

```clojure
(cli/parse-opts ["--port" "8080" "-v" "input.txt"]
                [["-p" "--port PORT" "Port" :parse-fn parse-long]
                 ["-v" "--verbose" "Verbose"]])
```

returns port `8080`, verbose `true`, positional argument `"input.txt"`, a
formatted summary, and `:errors nil`. The full let-go test suite also passes.

---

> **Verify against (in [nooga/let-go](https://github.com/nooga/let-go)):**
> `pkg/rt/core/core.lg`, `pkg/compiler/reader.go`,
> `pkg/compiler/compiler.go`, `pkg/rt/core/ir/build.lg`,
> `pkg/rt/lang.go`, `pkg/vm/regex.go`, `test/fn_prepost_test.lg`,
> `test/catch_class_test.lg`, `test/clojure_compat_aliases_test.lg`,
> `test/builtins_test.lg`, `test/shuffle_reseq_test.lg`, and
> `test/seq_test.lg`.
