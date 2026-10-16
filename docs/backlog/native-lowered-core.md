# `:target :native` binaries run core functions as bytecode

**Status: open**

Lowered application code still calls `clojure.core` and `clojure.string`
through their vars, which run on the bytecode VM: the lowered core
(`pkg/rt/core_go_lowered`) is a gitignored `make lowered` artifact in no
published module, and `clojure.string` has no lowered package at all.
Measured on an HTTP app, linking it by hand gave 1.3-1.45x on top of
`lg compile`. Waits on nooga/let-go#1067 and #940; then `build-native!` can
blank-import the lowered core packages into the staged module.
