#!/usr/bin/env bash
# E2E tests for lgx public commands. Drives the bundled bin/lgx against
# throwaway LGX_HOME dirs and a file:// bare repo seeded under each
# test's tmp area. Hermetic — no network.
#
# Run with: bash tests/e2e.sh   (from project root)

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LGX="$ROOT/bin/lgx"

# Git identity so seed commits work without global config (matters in CI).
export GIT_AUTHOR_NAME=lgx-test
export GIT_AUTHOR_EMAIL=lgx@test.invalid
export GIT_COMMITTER_NAME=lgx-test
export GIT_COMMITTER_EMAIL=lgx@test.invalid

PASS_COUNT=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }

assert_contains() {
    local haystack="$1"; local needle="$2"; local label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "---- output ----" >&2
        echo "$haystack" >&2
        echo "---- expected to contain: $needle ----" >&2
        fail "$label"
    fi
    pass "$label"
}

assert_eq() {
    local actual="$1"; local expected="$2"; local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "---- actual ----" >&2
        echo "$actual" >&2
        echo "---- expected ----" >&2
        echo "$expected" >&2
        fail "$label"
    fi
    pass "$label"
}

# Seed a bare git repo with one commit containing src/test/fib.lg.
# Echoes the resolved sha.
make_bare_repo() {
    local bare="$1"
    local work
    work="$(mktemp -d)"
    git init --quiet --bare "$bare"
    git clone --quiet "$bare" "$work" 2>/dev/null
    mkdir -p "$work/src/test"
    cat > "$work/src/test/fib.lg" <<'EOF'
(ns test.fib)
(defn fib [n]
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
EOF
    git -C "$work" add .
    git -C "$work" commit --quiet -m "seed"
    git -C "$work" push --quiet origin master 2>/dev/null \
        || git -C "$work" push --quiet origin main
    local sha
    sha="$(git -C "$work" rev-parse HEAD)"
    rm -rf "$work"
    echo "$sha"
}

# Write an lgx.edn into $1 with a single dep pointing at $2 (file:// url) @ $3 (sha).
make_project() {
    local proj="$1"; local url="$2"; local sha="$3"
    mkdir -p "$proj"
    cat > "$proj/lgx.edn" <<EOF
{:deps
 {test/lib {:git/url "$url"
            :git/sha "$sha"}}}
EOF
}

# ---------------------------------------------------------------------------
echo "==> Scenario 1: lgx version"
out="$("$LGX" version)"
assert_contains "$out" "lgx 0.1.0-dev" "version prints version line"
out="$("$LGX" -v)"
assert_contains "$out" "lgx 0.1.0-dev" "-v prints version line"
out="$("$LGX" --version)"
assert_contains "$out" "lgx 0.1.0-dev" "--version prints version line"

# ---------------------------------------------------------------------------
echo "==> Scenario 2: lgx help"
out="$("$LGX" help)"
assert_contains "$out" "Usage:" "help prints usage"
assert_contains "$out" "lgx install" "help lists install"
assert_contains "$out" "lgx run" "help lists run"

# ---------------------------------------------------------------------------
echo "==> Scenario 3: unknown command"
set +e
out="$("$LGX" nope 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "unknown command should exit 1 (got $rc)"
assert_contains "$out" "unknown command: nope" "unknown command message"

# ---------------------------------------------------------------------------
echo "==> Scenario 4: install with empty :deps"
proj="$(mktemp -d)"
echo '{:deps {}}' > "$proj/lgx.edn"
home="$(mktemp -d)"
out="$(cd "$proj" && LGX_HOME="$home" "$LGX" install)"
assert_eq "$out" "no deps in lgx.edn" "empty :deps prints expected line"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenarios 5 & 6: install fresh, then cached"
home="$(mktemp -d)"
bare="$home/_fixtures/test-repo.git"
mkdir -p "$(dirname "$bare")"
sha="$(make_bare_repo "$bare")"
proj="$(mktemp -d)"
make_project "$proj" "file://$bare" "$sha"

out="$(cd "$proj" && LGX_HOME="$home" "$LGX" install)"
assert_contains "$out" "installing 1 dep(s)..." "fresh: header"
assert_contains "$out" "test/lib ->" "fresh: per-lib line"
assert_contains "$out" "done" "fresh: trailing done"

cache_dir="$home/gitlibs/_local/_/test-repo/$sha"
[[ -d "$cache_dir" ]] || fail "expected cache dir to exist at $cache_dir"
pass "cache dir created"

# Cached re-run
out="$(cd "$proj" && LGX_HOME="$home" "$LGX" install)"
assert_eq "$out" "all deps up to date" "cached: all deps up to date"

# ---------------------------------------------------------------------------
echo "==> Scenario 7: install walks up to find lgx.edn"
nested="$proj/a/b/c"
mkdir -p "$nested"
out="$(cd "$nested" && LGX_HOME="$home" "$LGX" install)"
assert_eq "$out" "all deps up to date" "walk-up finds lgx.edn"

# ---------------------------------------------------------------------------
echo "==> Scenario 8: lgx run cold cache prints install block"
home2="$(mktemp -d)"
set +e
out="$(cd "$proj" && LGX_HOME="$home2" "$LGX" run -e '(println :ok)' 2>&1)"
set -e
assert_contains "$out" "installing 1 dep(s)..." "run cold: install header before script"
assert_contains "$out" "done" "run cold: install done before script"
rm -rf "$home2"

# Cleanup
rm -rf "$proj" "$home"

echo
echo "All $PASS_COUNT e2e assertions passed."
