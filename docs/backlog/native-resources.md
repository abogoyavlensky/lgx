# `:target :native` does not embed `:resource-paths`

**Status: done**

Landed in `lgx build`: `:resource-paths` are staged into the native build's
module as an `-import`ed `lgxresources` package, whose `init()` installs them
as the resource provider
(docs/plans/2026-10-24-2005-native-project-lowering-and-resources.md). The
upstream mechanism is still tracked as nooga/let-go#1099
(docs/issues/letgo-compile-embed-resources.md).

`lg compile` has no `-resource-paths` flag, so a native executable carries no
resources: `io/resource` finds nothing unless the app supplies its own path.
`build-native!` warns when the basis has resource paths. Needs an upstream
flag (or env var) for `lg compile`, the counterpart of nooga/let-go#999 for
`lg -w`.
