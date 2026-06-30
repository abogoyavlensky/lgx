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
