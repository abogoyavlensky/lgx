#!/usr/bin/env bash
# Top-level test runner: build bundle, run unit tests, then e2e.
#
# Run with: bash tests/run.sh  (or `make test`)

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# Pin lg to the repo's mise-resolved binary (absolute path). The e2e cd's into
# throwaway dirs outside the repo, where mise's cwd-based shim would otherwise
# fall back to the *global* lg version. Resolving once here keeps every step --
# build, unit tests, e2e -- on the version pinned in .mise.toml. An explicit
# LGX_LG from the caller still wins.
: "${LGX_LG:="$(mise which lg 2>/dev/null || command -v lg)"}"
export LGX_LG

# An lg carrying let-go's clojure.test port (nooga/let-go#863) runs the
# harness's other variant. Point LGX_LG_NEW at one (e.g. an lg built from
# let-go main) to cover it; unset, those e2e scenarios are skipped.
export LGX_LG_NEW="${LGX_LG_NEW:-}"
[[ -n "$LGX_LG_NEW" ]] || echo "note: LGX_LG_NEW unset - the clojure.test-port scenarios will be skipped"

echo "==> Bundling lgx..."
make build LG="$LGX_LG" >/dev/null

echo
echo "==> Unit tests..."
"$ROOT/bin/lgx" test

echo
echo "==> E2E tests..."
bash tests/e2e.sh

echo
echo "All tests passed."
