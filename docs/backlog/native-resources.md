# `:target :native` does not embed `:resource-paths`

**Status: open**

`lg compile` has no `-resource-paths` flag, so a native executable carries no
resources: `io/resource` finds nothing unless the app supplies its own path.
`build-native!` warns when the basis has resource paths. Needs an upstream
flag (or env var) for `lg compile`, the counterpart of nooga/let-go#999 for
`lg -w`.
