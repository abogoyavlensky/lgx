# Notes for coding agents

Source code is the source of truth. The docs below are supplementary -
read them only when relevant. Do not preload.

## When to consult what

- Changing a component boundary, data flow, or adding a subcommand →
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- Hitting a let-go runtime surprise (silent require failure, double
  execution, missing fn, AOT-time side effects) →
  [`docs/knowledge-base/let-go-gotchas.md`](docs/knowledge-base/let-go-gotchas.md).
- Looking for a let-go stdlib fn before grepping →
  [`docs/knowledge-base/let-go-stdlib-quick-ref.md`](docs/knowledge-base/let-go-stdlib-quick-ref.md).
- Touching `lg -b` / AOT / `*compiling-aot*` →
  [`docs/knowledge-base/let-go-bundling.md`](docs/knowledge-base/let-go-bundling.md).
- Touching `(:require)` resolution, `.cljc` discovery, ns layout →
  [`docs/knowledge-base/let-go-resolver.md`](docs/knowledge-base/let-go-resolver.md).
- Touching `:go/*` coords, the custom `lg` runtime cache, or the
  `go`/lginterop subprocess pipeline →
  [`docs/knowledge-base/lgx-go-runtimes.md`](docs/knowledge-base/lgx-go-runtimes.md).
- Setting up a dev iteration loop (`LGX_LG`, cache management) →
  [`docs/knowledge-base/lgx-dev-workflow.md`](docs/knowledge-base/lgx-dev-workflow.md).
- Wrapping a framework-shaped Go library, or anything desktop/Wails →
  [`docs/knowledge-base/lgx-wails-desktop.md`](docs/knowledge-base/lgx-wails-desktop.md)
  (why `:go/interop` cannot carry struct-literal or generic APIs, and what
  a `:go/local` shim looks like instead).
- Verifying `:go/*` support while its let-go PRs are still open (building a
  combined `lg`, the sqlite/HoneySQL checks) →
  [`docs/go-deps-pr-verification.md`](docs/go-deps-pr-verification.md)
  (temporary; delete once the PRs merge).
- Filing or referencing upstream let-go work →
  [`docs/issues/`](docs/issues/).

## Keeping these in sync

Notes drift. Two rules:

1. **Same-PR updates.** When changing something a doc describes,
   update the doc in the same commit. Each knowledge-base file ends
   with a `Verify against:` footer naming the source files it claims
   to describe - use it to spot-check.
2. **Drift > silence.** If you spot a stale claim, fix or delete it
   rather than leave it. A missing note is better than a wrong one.
