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
skip() { echo "  SKIP: $1"; }

supports_source_paths() {
    local lg_bin="${LGX_LG:-lg}"
    "$lg_bin" -source-paths "" -e '(println :ok)' >/dev/null 2>&1
}

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

assert_not_contains() {
    local haystack="$1"; local needle="$2"; local label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "---- output ----" >&2
        echo "$haystack" >&2
        echo "---- expected not to contain: $needle ----" >&2
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

# Seed a bare git repo with one commit containing src/test/fib.lg and
# a `v0.1.0` tag pointing at it. Echoes the resolved sha.
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
    git -C "$work" tag v0.1.0
    git -C "$work" push --quiet origin master 2>/dev/null \
        || git -C "$work" push --quiet origin main
    git -C "$work" push --quiet origin v0.1.0
    local sha
    sha="$(git -C "$work" rev-parse HEAD)"
    rm -rf "$work"
    echo "$sha"
}

# Write an lgx.edn into $1 pinning to a tag instead of a sha.
make_project_tag() {
    local proj="$1"; local url="$2"; local tag="$3"
    mkdir -p "$proj"
    cat > "$proj/lgx.edn" <<EOF
{:deps
 {test/lib {:git/url "$url"
            :git/tag "$tag"}}}
EOF
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

make_local_project() {
    local root="$1"
    local proj="$root/project"
    local lib="$root/mylib"
    mkdir -p "$proj" "$lib/src"
    cat > "$proj/lgx.edn" <<'EOF'
{:deps {my/lib {:local/root "../mylib"}}}
EOF
    cat > "$proj/main.lg" <<'EOF'
(ns local.main
  (:require [mylib :as mylib]))

(println (mylib/message))
EOF
    cat > "$lib/src/mylib.lg" <<'EOF'
(ns mylib)

(defn message [] "local one")
EOF
}

# ---------------------------------------------------------------------------
echo "==> Scenario 1: lgx version"
out="$("$LGX" version)"
assert_contains "$out" "lgx " "version prints version line"
out="$("$LGX" -v)"
assert_contains "$out" "lgx " "-v prints version line"
out="$("$LGX" --version)"
assert_contains "$out" "lgx " "--version prints version line"

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
assert_contains "$out" "lgx: 'nope' is not a lgx command. See 'lgx --help'." "unknown command message"

# ---------------------------------------------------------------------------
echo "==> Scenario 4: install with empty :deps"
proj="$(mktemp -d)"
echo '{:deps {}}' > "$proj/lgx.edn"
home="$(mktemp -d)"
out="$(cd "$proj" && LGX_HOME="$home" "$LGX" install)"
assert_eq "$out" "no deps in lgx.edn" "empty :deps prints expected line"
rm -rf "$proj" "$home"

# ---------------------------------------------------------------------------
echo "==> Scenario 5: local dep install and run"
root_local="$(mktemp -d)"
make_local_project "$root_local"
home_local="$(mktemp -d)"
out="$(cd "$root_local/project" && LGX_HOME="$home_local" "$LGX" install)"
assert_eq "$out" "all deps up to date" "local-only install prints up to date"
if supports_source_paths; then
    out="$(cd "$root_local/project" && LGX_HOME="$home_local" "$LGX" run main.lg)"
    assert_eq "$out" "local one" "local dep namespace is on source path"
    cat > "$root_local/mylib/src/mylib.lg" <<'EOF'
(ns mylib)

(defn message [] "local two")
EOF
    out="$(cd "$root_local/project" && LGX_HOME="$home_local" "$LGX" run main.lg)"
    assert_eq "$out" "local two" "local dep changes are picked up on next run"
else
    skip "local dep run requires lg with -source-paths support"
fi
rm -rf "$root_local" "$home_local"

# ---------------------------------------------------------------------------
echo "==> Scenario 6: mixed local and git install output"
root_mixed="$(mktemp -d)"
make_local_project "$root_mixed"
home_mixed="$(mktemp -d)"
bare_mixed="$home_mixed/_fixtures/test-repo.git"
mkdir -p "$(dirname "$bare_mixed")"
sha_mixed="$(make_bare_repo "$bare_mixed")"
cat > "$root_mixed/project/lgx.edn" <<EOF
{:deps
 {test/lib {:git/url "file://$bare_mixed"
            :git/sha "$sha_mixed"}
  my/lib {:local/root "../mylib"}}}
EOF
out="$(cd "$root_mixed/project" && LGX_HOME="$home_mixed" "$LGX" install)"
assert_contains "$out" "installing 1 dep(s)..." "mixed: header counts only git dep"
assert_contains "$out" "test/lib ->" "mixed: git dep line is printed"
assert_not_contains "$out" "my/lib ->" "mixed: local dep line is not printed"
rm -rf "$root_mixed" "$home_mixed"

# ---------------------------------------------------------------------------
echo "==> Scenarios 7 & 8: install fresh, then cached"
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
echo "==> Scenario 9: install walks up to find lgx.edn"
nested="$proj/a/b/c"
mkdir -p "$nested"
out="$(cd "$nested" && LGX_HOME="$home" "$LGX" install)"
assert_eq "$out" "all deps up to date" "walk-up finds lgx.edn"

# ---------------------------------------------------------------------------
echo "==> Scenario 10: install via :git/tag caches by tag name"
home_tag="$(mktemp -d)"
bare_tag="$home_tag/_fixtures/test-repo.git"
mkdir -p "$(dirname "$bare_tag")"
make_bare_repo "$bare_tag" >/dev/null
proj_tag="$(mktemp -d)"
make_project_tag "$proj_tag" "file://$bare_tag" "v0.1.0"

out="$(cd "$proj_tag" && LGX_HOME="$home_tag" "$LGX" install)"
assert_contains "$out" "installing 1 dep(s)..." "tag: install header"
assert_contains "$out" "test/lib ->" "tag: per-lib line"
[[ -d "$home_tag/gitlibs/_local/_/test-repo/v0.1.0" ]] \
    || fail "tag: expected cache dir at <home>/gitlibs/_local/_/test-repo/v0.1.0"
pass "tag: cache dir uses tag name"

fake_path="$home_tag/no-git-bin"
mkdir -p "$fake_path"
cat > "$fake_path/git" <<EOF
#!/bin/sh
echo "git should not be called on cached tag install" >&2
exit 77
EOF
chmod +x "$fake_path/git"
out="$(cd "$proj_tag" && PATH="$fake_path" LGX_HOME="$home_tag" "$LGX" install)"
assert_eq "$out" "all deps up to date" "tag: cached install does not invoke git"

rm -rf "$proj_tag" "$home_tag"

# ---------------------------------------------------------------------------
echo "==> Scenario 11: lgx run cold cache prints install block"
home2="$(mktemp -d)"
set +e
out="$(cd "$proj" && LGX_HOME="$home2" "$LGX" run -e '(println :ok)' 2>&1)"
set -e
assert_contains "$out" "installing 1 dep(s)..." "run cold: install header before script"
assert_contains "$out" "done" "run cold: install done before script"
rm -rf "$home2"

# ---------------------------------------------------------------------------
echo "==> Scenario 12: lgx --verbose run prints lg invocation to stderr"
home_verbose="$(mktemp -d)"
set +e
# Capture stderr only — the trace line goes there.
out_verbose="$(cd "$proj" && LGX_HOME="$home_verbose" "$LGX" --verbose run -e '(println :ok)' 2>&1 >/dev/null)"
set -e
assert_contains "$out_verbose" "+ " "verbose: trace line has + prefix"
assert_contains "$out_verbose" "-source-paths" "verbose: trace includes -source-paths"
assert_contains "$out_verbose" "(println :ok)" "verbose: trace includes forwarded args"

# Without --verbose, no line should start with the trace prefix "+ ".
home_verbose2="$(mktemp -d)"
set +e
out_quiet="$(cd "$proj" && LGX_HOME="$home_verbose2" "$LGX" run -e '(println :ok)' 2>&1 >/dev/null)"
set -e
if echo "$out_quiet" | grep -q '^+ '; then
    echo "---- stderr ----" >&2
    echo "$out_quiet" >&2
    fail "no verbose: trace line appeared without --verbose"
fi
pass "no verbose: no trace line on stderr"
rm -rf "$home_verbose" "$home_verbose2"

# Cleanup
rm -rf "$proj" "$home"

echo
echo "All $PASS_COUNT e2e assertions passed."
