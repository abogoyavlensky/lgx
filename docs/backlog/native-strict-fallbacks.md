# `:target :native` cannot fail a build on functions that did not lower

**Status: open**

`lg compile` prints a `WARNING: not lowered (...) for <fn>: <reason>` line for
each function that stays on bytecode and still succeeds, and it returns no
machine-readable report. lgx relays the output, so a build that silently runs
hot code on the VM looks the same as one that lowered everything. lgx issue
#60 asks for a report and for unapproved fallbacks to fail the build.

Blocked on nooga/let-go#660 (a per-function lowering report plus a strict
mode). Once it lands, lgx could add an option such as
`:native {:fallbacks :fail}` with an allow-list of approved functions.
