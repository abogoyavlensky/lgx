#!/usr/bin/env bash
# Top-level test runner: build bundle, run unit tests, then e2e.
#
# Run with: bash tests/run.sh  (or `make test`)

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

echo "==> Bundling lgx..."
make build >/dev/null

echo
echo "==> Unit tests..."
lg tests/path_test.lg
lg tests/config_test.lg
lg tests/cache_test.lg
lg tests/test_runner_test.lg

echo
echo "==> E2E tests..."
bash tests/e2e.sh

echo
echo "All tests passed."
