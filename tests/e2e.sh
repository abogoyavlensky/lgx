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

supports_resource_paths() {
    local lg_bin="${LGX_LG:-lg}"
    "$lg_bin" -resource-paths "" -e '(println :ok)' >/dev/null 2>&1
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
assert_contains "$out_verbose" "+ env " "verbose: env line has + env prefix"
assert_contains "$out_verbose" "LG_READ_CLJ=1" "verbose: env line includes LG_READ_CLJ=1"
assert_contains "$out_verbose" "LGX_RUN=1" "verbose: env line includes LGX_RUN=1 on run path"

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

# ---------------------------------------------------------------------------
echo "==> Scenario 13: project task with :sh step"
proj_t="$(mktemp -d)"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {hello {:doc "Say hi"
          :do [{:sh "echo hi from task"}]}}}
EOF
home_t="$(mktemp -d)"
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" hello)"
assert_eq "$out" "hi from task" "task: single :sh step runs"

# ---------------------------------------------------------------------------
echo "==> Scenario 14: multi-step task runs steps sequentially"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {ci {:doc "Run multiple steps"
       :do [{:sh "echo step1"}
            {:sh "echo step2"}
            {:sh "echo step3"}]}}}
EOF
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" ci)"
assert_eq "$out" "step1
step2
step3" "task: multi-step output streamed in order"

# ---------------------------------------------------------------------------
echo "==> Scenario 15: vector :sh form is joined with spaces"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {greet {:do [{:sh ["echo" "hello" "world"]}]}}}
EOF
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" greet)"
assert_eq "$out" "hello world" "task: vector :sh form joins items"

# ---------------------------------------------------------------------------
echo "==> Scenario 16: failing step stops chain with its exit code"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {fail {:do [{:sh "echo before"}
              {:sh "exit 7"}
              {:sh "echo after"}]}}}
EOF
set +e
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" fail)"; rc=$?
set -e
[[ $rc -eq 7 ]] || fail "task fail: expected exit 7, got $rc"
pass "task: failing step propagates exit code 7"
assert_contains "$out" "before" "task fail: first step printed"
assert_not_contains "$out" "after" "task fail: later step did not run"

# ---------------------------------------------------------------------------
echo "==> Scenario 17: unknown command in a project with tasks"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {hello {:do [{:sh "echo hi"}]}}}
EOF
set +e
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" nope 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "unknown task: expected exit 1, got $rc"
assert_contains "$out" "'nope' is not a lgx command" "unknown task: error message"

# ---------------------------------------------------------------------------
echo "==> Scenario 18: lgx help lists project tasks"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {fmt   {:doc "Format sources" :do [{:sh "echo fmt"}]}
  check {:doc "Run checks"     :do [{:sh "echo check"}]}}}
EOF
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" help)"
assert_contains "$out" "Usage: lgx [options] <command> [args...]" "help: usage synopsis"
assert_contains "$out" "Built-in commands:" "help: shows built-in commands title"
assert_contains "$out" "Project tasks:" "help: shows project tasks block"
assert_contains "$out" "lgx fmt" "help: task row uses lgx prefix"
assert_contains "$out" "Format sources" "help: shows :doc string"
assert_contains "$out" "Run checks" "help: shows check :doc"
# Options section comes after Project tasks (tasks continue the commands).
pt_line="$(printf '%s\n' "$out" | grep -n '^Project tasks:' | head -1 | cut -d: -f1)"
op_line="$(printf '%s\n' "$out" | grep -n '^Options:' | head -1 | cut -d: -f1)"
{ [[ -n "$pt_line" && -n "$op_line" && "$op_line" -gt "$pt_line" ]]; } \
    || fail "help: Options should follow Project tasks (pt=$pt_line op=$op_line)"
pass "help: Options appears after Project tasks"
# Help is plain text — color is a runtime-only signal, never used in help.
assert_not_contains "$out" $'\e[' "help: output is plain (no color)"

# ---------------------------------------------------------------------------
echo "==> Scenario 19: task name conflicting with built-in command is rejected"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {run {:doc "Bad" :do [{:sh "echo nope"}]}}}
EOF
set +e
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" install 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "reserved-name: expected non-zero exit"
assert_contains "$out" "conflicts with built-in command" "reserved-name: error message"

rm -rf "$proj_t" "$home_t"

# ---------------------------------------------------------------------------
echo "==> Scenario 20: :run task step uses project basis"
if supports_source_paths; then
    proj_run="$(mktemp -d)"
    home_run="$(mktemp -d)"
    mkdir -p "$proj_run/src" "$proj_run/scripts"
    cat > "$proj_run/src/util.lg" <<'EOF'
(ns util)
(defn greet [] "hello-from-util")
EOF
    cat > "$proj_run/scripts/hi.lg" <<'EOF'
(ns hi (:require [util]))
(println (util/greet))
EOF
    cat > "$proj_run/lgx.edn" <<'EOF'
{:paths ["src"]
 :tasks
 {say {:doc "Run via :run step"
        :do [{:run "scripts/hi.lg"}]}}}
EOF
    out="$(cd "$proj_run" && LGX_HOME="$home_run" "$LGX" say)"
    assert_eq "$out" "hello-from-util" "task: :run step resolves project :paths"
    rm -rf "$proj_run" "$home_run"
else
    skip ":run task step requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
# Scenarios 21, 22, 24 use no :paths or :deps so `-source-paths` is never
# added — they don't need supports_source_paths gating.
echo "==> Scenario 21: :main runs default script when no args"
proj_main="$(mktemp -d)"
home_main="$(mktemp -d)"
cat > "$proj_main/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
# main.lg also prints whether `--` lands in os/args, so we can verify
# the universal-parser convention works for the bare `lgx run` case.
cat > "$proj_main/main.lg" <<'EOF'
(when-not *compiling-aot*
  (println :hello-from-main)
  (println (str "argv=" (vec os/args))))
EOF
out="$(cd "$proj_main" && LGX_HOME="$home_main" "$LGX" run)"
assert_contains "$out" ":hello-from-main" "main: bare run uses :main script"
assert_contains "$out" '"--"' "main: bare run appends -- so universal parser works"
rm -rf "$proj_main" "$home_main"

# ---------------------------------------------------------------------------
echo "==> Scenario 22: explicit script overrides :main"
proj_main2="$(mktemp -d)"
home_main2="$(mktemp -d)"
cat > "$proj_main2/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
cat > "$proj_main2/main.lg" <<'EOF'
(println :should-not-run)
EOF
cat > "$proj_main2/other.lg" <<'EOF'
(println :other-script)
EOF
out="$(cd "$proj_main2" && LGX_HOME="$home_main2" "$LGX" run other.lg)"
assert_eq "$out" ":other-script" "main: explicit script skips :main fallback"
rm -rf "$proj_main2" "$home_main2"

# ---------------------------------------------------------------------------
echo "==> Scenario 23: :main script missing on disk errors"
proj_main3="$(mktemp -d)"
home_main3="$(mktemp -d)"
cat > "$proj_main3/lgx.edn" <<'EOF'
{:main "missing.lg"}
EOF
set +e
out="$(cd "$proj_main3" && LGX_HOME="$home_main3" "$LGX" run 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "missing :main: expected non-zero exit, got $rc"
assert_contains "$out" "lgx: :main script not found: missing.lg" \
    "missing :main: clear error on stderr"
rm -rf "$proj_main3" "$home_main3"

# ---------------------------------------------------------------------------
echo "==> Scenario 24: any args disable :main fallback"
proj_main4="$(mktemp -d)"
home_main4="$(mktemp -d)"
cat > "$proj_main4/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
cat > "$proj_main4/main.lg" <<'EOF'
(println :should-not-run)
EOF
out="$(cd "$proj_main4" && LGX_HOME="$home_main4" "$LGX" run -e '(println :inline)')"
assert_contains "$out" ":inline" "main: -e form runs, :main is not injected"
assert_not_contains "$out" ":should-not-run" "main: :main script does not execute"
rm -rf "$proj_main4" "$home_main4"

# ---------------------------------------------------------------------------
echo "==> Scenario 25: lgx build happy path"
proj_b="$(mktemp -d)"
home_b="$(mktemp -d)"
cat > "$proj_b/lgx.edn" <<'EOF'
{:main "main.lg"
 :targets {:bin {:out "bin/myapp"}}}
EOF
cat > "$proj_b/main.lg" <<'EOF'
(when-not *compiling-aot*
  (println :hello-from-myapp))
EOF
out="$(cd "$proj_b" && LGX_HOME="$home_b" "$LGX" build 2>&1)"
[[ -x "$proj_b/bin/myapp" ]] || fail "build: expected bin/myapp to exist and be executable"
pass "build: produces executable at :out"
assert_contains "$out" "built $proj_b/bin/myapp" "build: prints success line with abs out path"
out_run="$("$proj_b/bin/myapp")"
assert_eq "$out_run" ":hello-from-myapp" "build: produced binary runs and prints expected output"
rm -rf "$proj_b" "$home_b"

# ---------------------------------------------------------------------------
echo "==> Scenario 26: lgx build auto-creates missing parent dir"
proj_b2="$(mktemp -d)"
home_b2="$(mktemp -d)"
cat > "$proj_b2/lgx.edn" <<'EOF'
{:main "main.lg"
 :targets {:bin {:out "out/nested/myapp"}}}
EOF
cat > "$proj_b2/main.lg" <<'EOF'
(when-not *compiling-aot* (println :nested))
EOF
(cd "$proj_b2" && LGX_HOME="$home_b2" "$LGX" build >/dev/null 2>&1)
[[ -d "$proj_b2/out/nested" ]] || fail "build: expected out/nested/ to be auto-created"
[[ -x "$proj_b2/out/nested/myapp" ]] || fail "build: expected nested binary"
pass "build: auto-creates missing parent directory"
rm -rf "$proj_b2" "$home_b2"

# ---------------------------------------------------------------------------
echo "==> Scenario 27: lgx build without :main errors"
proj_b3="$(mktemp -d)"
home_b3="$(mktemp -d)"
cat > "$proj_b3/lgx.edn" <<'EOF'
{:targets {:bin {:out "bin/myapp"}}}
EOF
set +e
out="$(cd "$proj_b3" && LGX_HOME="$home_b3" "$LGX" build 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "build no :main: expected non-zero exit"
assert_contains "$out" "lgx: :main is required for build" \
    "build no :main: clear error"
rm -rf "$proj_b3" "$home_b3"

# ---------------------------------------------------------------------------
echo "==> Scenario 28: lgx build without :targets/:bin errors"
proj_b4="$(mktemp -d)"
home_b4="$(mktemp -d)"
cat > "$proj_b4/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
cat > "$proj_b4/main.lg" <<'EOF'
(println :hi)
EOF
set +e
out="$(cd "$proj_b4" && LGX_HOME="$home_b4" "$LGX" build 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "build no :targets/:bin: expected non-zero exit"
assert_contains "$out" "lgx: :targets/:bin is required for build" \
    "build no :targets/:bin: clear error"
rm -rf "$proj_b4" "$home_b4"

# ---------------------------------------------------------------------------
echo "==> Scenario 29: lgx build with missing :main script errors"
proj_b5="$(mktemp -d)"
home_b5="$(mktemp -d)"
cat > "$proj_b5/lgx.edn" <<'EOF'
{:main "missing.lg"
 :targets {:bin {:out "bin/myapp"}}}
EOF
set +e
out="$(cd "$proj_b5" && LGX_HOME="$home_b5" "$LGX" build 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "build missing :main: expected non-zero exit"
assert_contains "$out" "lgx: :main script not found: missing.lg" \
    "build missing :main: clear error"
rm -rf "$proj_b5" "$home_b5"

# ---------------------------------------------------------------------------
echo "==> Scenario 30: lgx --verbose build prints lg trace"
proj_b6="$(mktemp -d)"
home_b6="$(mktemp -d)"
cat > "$proj_b6/lgx.edn" <<'EOF'
{:main "main.lg"
 :targets {:bin {:out "bin/myapp"}}}
EOF
cat > "$proj_b6/main.lg" <<'EOF'
(when-not *compiling-aot* (println :ok))
EOF
set +e
err="$(cd "$proj_b6" && LGX_HOME="$home_b6" "$LGX" --verbose build 2>&1 >/dev/null)"
set -e
assert_contains "$err" "+ " "verbose build: trace line has + prefix"
assert_contains "$err" "-b" "verbose build: trace includes -b flag"
assert_contains "$err" "bin/myapp" "verbose build: trace includes :out path"
assert_contains "$err" "+ env LG_READ_CLJ=1" "verbose build: env line includes LG_READ_CLJ=1"
assert_not_contains "$err" "LGX_RUN" "verbose build: env line omits LGX_RUN (not a run path)"
rm -rf "$proj_b6" "$home_b6"

# ---------------------------------------------------------------------------
# Scenarios 31-38 cover `--` as the script/user-args separator for `lgx run`.
# `--` is preserved in the outgoing argv; pre-`--` script suffixes
# (.lg/.cljc/.clj) skip the :main injection. No `supports_source_paths`
# gating needed — minimal projects have no deps/paths.
echo "==> Scenario 31: lgx run -- <arg> forwards arg to :main"
proj_dd="$(mktemp -d)"
home_dd="$(mktemp -d)"
cat > "$proj_dd/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
# main.lg prints both the full os/args and the post-`--` slice so we
# can assert both that `--` survives in os/args and that the slice is
# what an app would actually consume.
cat > "$proj_dd/main.lg" <<'EOF'
(when-not *compiling-aot*
  (let [argv (vec os/args)
        i (loop [k 0 xs (seq argv)]
            (cond (nil? xs) -1
                  (= "--" (first xs)) k
                  :else (recur (inc k) (next xs))))
        post (if (neg? i) [] (vec (drop (inc i) argv)))]
    (println (str "all=" argv))
    (println (str "post=" post))))
EOF
out="$(cd "$proj_dd" && LGX_HOME="$home_dd" "$LGX" run -- list)"
assert_contains "$out" "main.lg" "run -- list: os/args includes injected script"
assert_contains "$out" "all=" "run -- list: full argv printed"
assert_contains "$out" '"--"' "run -- list: -- preserved in os/args"
assert_contains "$out" 'post=["list"]' "run -- list: post-slice is exactly [list]"

# ---------------------------------------------------------------------------
echo "==> Scenario 32: lgx run -- -v shields single-dash flag from lg"
out="$(cd "$proj_dd" && LGX_HOME="$home_dd" "$LGX" run -- -v)"
assert_contains "$out" 'post=["-v"]' "run -- -v: -v lands in post-slice, not consumed by lg"

# ---------------------------------------------------------------------------
echo "==> Scenario 33: lgx --verbose run -r -- foo trace shows -r main.lg -- foo"
# Stub LGX_LG to /usr/bin/true so the trace fires but no real lg runs
# (avoids the -r REPL hanging without a TTY).
set +e
err="$(cd "$proj_dd" && LGX_HOME="$home_dd" LGX_LG=/usr/bin/true \
    "$LGX" --verbose run -r -- foo 2>&1 >/dev/null)"
set -e
if echo "$err" | grep -qE '\-r .*main\.lg -- foo'; then
    pass "run -r -- foo: trace reads '-r ... main.lg -- foo' ('-' before main, '--' after)"
else
    echo "---- stderr ----" >&2
    echo "$err" >&2
    fail "run -r -- foo: did not find '-r ... main.lg -- foo' in trace"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 34: lgx run -- (bare separator) injects :main, keeps --"
out="$(cd "$proj_dd" && LGX_HOME="$home_dd" "$LGX" run --)"
assert_contains "$out" "main.lg" "run -- (bare): injects :main"
assert_contains "$out" '"--"' "run -- (bare): -- preserved in os/args"
assert_contains "$out" "post=[]" "run -- (bare): post-slice is empty"
rm -rf "$proj_dd" "$home_dd"

# ---------------------------------------------------------------------------
echo "==> Scenario 35: lgx run -- foo errors without :main"
proj_dd2="$(mktemp -d)"
home_dd2="$(mktemp -d)"
cat > "$proj_dd2/lgx.edn" <<'EOF'
{}
EOF
set +e
out="$(cd "$proj_dd2" && LGX_HOME="$home_dd2" "$LGX" run -- foo 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "run -- without :main: expected non-zero exit"
assert_contains "$out" "lgx: -- requires :main to be set in lgx.edn" \
    "run -- without :main: clear error"
rm -rf "$proj_dd2" "$home_dd2"

# ---------------------------------------------------------------------------
echo "==> Scenario 36: explicit foo.lg -- bar skips :main injection"
proj_dd3="$(mktemp -d)"
home_dd3="$(mktemp -d)"
cat > "$proj_dd3/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
cat > "$proj_dd3/main.lg" <<'EOF'
(when-not *compiling-aot* (println :main-ran))
EOF
cat > "$proj_dd3/other.lg" <<'EOF'
(when-not *compiling-aot* (println :other-ran (rest os/args)))
EOF
out="$(cd "$proj_dd3" && LGX_HOME="$home_dd3" "$LGX" run other.lg -- bar)"
assert_contains "$out" ":other-ran" "explicit script + --: explicit script runs"
assert_not_contains "$out" ":main-ran" "explicit script + --: :main is NOT injected"
assert_contains "$out" "bar" "explicit script + --: bar reaches the script"
rm -rf "$proj_dd3" "$home_dd3"

# ---------------------------------------------------------------------------
echo "==> Scenario 37: explicit foo.lg -- bar works without :main set"
proj_dd4="$(mktemp -d)"
home_dd4="$(mktemp -d)"
cat > "$proj_dd4/lgx.edn" <<'EOF'
{}
EOF
cat > "$proj_dd4/other.lg" <<'EOF'
(when-not *compiling-aot* (println :ran (rest os/args)))
EOF
out="$(cd "$proj_dd4" && LGX_HOME="$home_dd4" "$LGX" run other.lg -- bar)"
assert_contains "$out" ":ran" "explicit script + -- (no :main): script runs"
assert_contains "$out" "bar" "explicit script + -- (no :main): bar reaches the script"
rm -rf "$proj_dd4" "$home_dd4"

# ---------------------------------------------------------------------------
echo "==> Scenario 38: .cljc suffix is recognized as an explicit script"
proj_dd5="$(mktemp -d)"
home_dd5="$(mktemp -d)"
cat > "$proj_dd5/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
cat > "$proj_dd5/main.lg" <<'EOF'
(when-not *compiling-aot* (println :main-ran))
EOF
cat > "$proj_dd5/other.cljc" <<'EOF'
(when-not *compiling-aot* (println :cljc-ran (rest os/args)))
EOF
out="$(cd "$proj_dd5" && LGX_HOME="$home_dd5" "$LGX" run other.cljc -- baz)"
assert_contains "$out" ":cljc-ran" "explicit .cljc + --: .cljc script runs"
assert_not_contains "$out" ":main-ran" "explicit .cljc + --: :main NOT injected"
assert_contains "$out" "baz" "explicit .cljc + --: baz reaches the script"
rm -rf "$proj_dd5" "$home_dd5"

# ---------------------------------------------------------------------------
# Scenarios 39-44 cover `lgx test`. The command always passes -source-paths
# (test/ is appended to the project basis), so the system `lg` must support
# that flag — gate every scenario behind supports_source_paths.
echo "==> Scenario 39: lgx test happy path"
if supports_source_paths; then
    proj_t1="$(mktemp -d)"
    home_t1="$(mktemp -d)"
    cat > "$proj_t1/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_t1/test"
    cat > "$proj_t1/test/foo_test.lg" <<'EOF'
(ns foo-test
  (:require [test :refer [deftest is testing]]))

(deftest pass-1
  (testing "first assertion passes"
    (is (= 1 1))))

(deftest pass-2
  (is (= 2 2)))
EOF
    set +e
    out="$(cd "$proj_t1" && LGX_HOME="$home_t1" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "test happy: expected exit 0, got $rc (output: $out)"
    pass "test happy: exits 0"
    assert_contains "$out" "=> Running tests in test/" \
        "test happy: green lgx header (stderr) replaces the harness banner"
    assert_contains "$out" "test/foo_test.lg" "test happy: file header printed"
    assert_contains "$out" "pass-1" "test happy: pass-1 row printed"
    assert_contains "$out" "pass-2" "test happy: pass-2 row printed"
    assert_contains "$out" "first assertion passes" \
        "test happy: testing context printed"
    assert_not_contains "$out" "PASS (= 1 1)" \
        "test happy: passing assertion form suppressed"
    assert_contains "$out" $'\e[38;5;35m2 tests, 2 assertions, 0 failures\e[0m' \
        "test happy: summary line printed in green"
    # ✓ = U+2713; check both deftests show the mark.
    pass_marks="$(printf '%s\n' "$out" | grep -c $'\xe2\x9c\x93' || true)"
    [[ "$pass_marks" -ge 2 ]] \
        || fail "test happy: expected >=2 ✓ marks, got $pass_marks (output: $out)"
    pass "test happy: ✓ printed for each passing deftest"
    rm -rf "$proj_t1" "$home_t1"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 40: lgx test failure path"
if supports_source_paths; then
    proj_t2="$(mktemp -d)"
    home_t2="$(mktemp -d)"
    cat > "$proj_t2/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_t2/test"
    cat > "$proj_t2/test/foo_test.lg" <<'EOF'
(ns foo-test
  (:require [test :refer [deftest is testing]]))

(deftest pass-1
  (is (= 1 1)))

(deftest fail-1
  (testing "failing assertion is explained"
    (is (= 1 2))))
EOF
    set +e
    out="$(cd "$proj_t2" && LGX_HOME="$home_t2" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 1 ]] || fail "test fail: expected exit 1, got $rc (output: $out)"
    pass "test fail: exits 1"
    assert_contains "$out" "test/foo_test.lg" "test fail: file header printed"
    assert_contains "$out" "pass-1" "test fail: pass-1 row printed"
    assert_contains "$out" "fail-1" "test fail: fail-1 row printed"
    assert_contains "$out" "failing assertion is explained" \
        "test fail: testing context printed"
    assert_contains "$out" $'\e[38;5;1mFAIL\e[0m (= 1 2)' \
        "test fail: failing assertion detail prints red FAIL"
    assert_contains "$out" $'\e[38;5;1m2 tests, 2 assertions, 1 failures\e[0m' \
        "test fail: summary line printed in red"
    assert_not_contains "$out" "PASS (= 1 1)" \
        "test fail: passing assertion form suppressed"
    # ✗ = U+2717
    if ! printf '%s\n' "$out" | grep -q $'\xe2\x9c\x97'; then
        echo "---- output ----" >&2
        echo "$out" >&2
        fail "test fail: expected ✗ mark for failing test"
    fi
    pass "test fail: ✗ printed for failing deftest"
    rm -rf "$proj_t2" "$home_t2"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 41: lgx test with empty test/ directory"
proj_t3="$(mktemp -d)"
home_t3="$(mktemp -d)"
cat > "$proj_t3/lgx.edn" <<'EOF'
{}
EOF
mkdir -p "$proj_t3/test"
set +e
out="$(cd "$proj_t3" && LGX_HOME="$home_t3" "$LGX" test 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "test empty: expected exit 0, got $rc (output: $out)"
pass "test empty: exits 0"
assert_contains "$out" "No tests found in test/" "test empty: friendly message"
rm -rf "$proj_t3" "$home_t3"

# ---------------------------------------------------------------------------
echo "==> Scenario 42: lgx test with no test/ directory"
proj_t4="$(mktemp -d)"
home_t4="$(mktemp -d)"
cat > "$proj_t4/lgx.edn" <<'EOF'
{}
EOF
set +e
out="$(cd "$proj_t4" && LGX_HOME="$home_t4" "$LGX" test 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "test missing: expected exit 1, got $rc (output: $out)"
pass "test missing: exits 1"
assert_contains "$out" "lgx: no test/ directory in project" \
    "test missing: friendly error"
rm -rf "$proj_t4" "$home_t4"

# ---------------------------------------------------------------------------
echo "==> Scenario 43: lgx test nested layout"
if supports_source_paths; then
    proj_t5="$(mktemp -d)"
    home_t5="$(mktemp -d)"
    cat > "$proj_t5/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_t5/test/foo"
    cat > "$proj_t5/test/foo/bar_test.lg" <<'EOF'
(ns foo.bar-test
  (:require [test :refer [deftest is]]))

(deftest nested-pass
  (is (= :ok :ok)))
EOF
    set +e
    out="$(cd "$proj_t5" && LGX_HOME="$home_t5" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "test nested: expected exit 0, got $rc (output: $out)"
    pass "test nested: exits 0"
    assert_contains "$out" "test/foo/bar_test.lg" "test nested: file header printed"
    assert_contains "$out" "nested-pass" "test nested: deftest row printed"
    rm -rf "$proj_t5" "$home_t5"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 44: lgx --verbose test prints harness path on stderr"
if supports_source_paths; then
    proj_t6="$(mktemp -d)"
    home_t6="$(mktemp -d)"
    cat > "$proj_t6/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_t6/test"
    cat > "$proj_t6/test/foo_test.lg" <<'EOF'
(ns foo-test
  (:require [test :refer [deftest is]]))

(deftest pass-1
  (is (= 1 1)))
EOF
    set +e
    err="$(cd "$proj_t6" && LGX_HOME="$home_t6" "$LGX" --verbose test 2>&1 >/dev/null)"
    set -e
    version="$(awk -F '"' '/def[[:space:]]+version[[:space:]]+"/ { print $2; exit }' "$ROOT/lgx.lg")"
    harness="$home_t6/tmp/lgx-test-$version.lg"
    assert_contains "$err" "+ " "verbose test: trace line has + prefix"
    assert_contains "$err" "$harness" "verbose test: LGX_HOME harness path mentioned"
    assert_contains "$err" "-source-paths" "verbose test: trace includes -source-paths"
    [[ -f "$harness" ]] || fail "verbose test: expected harness file at $harness"
    pass "verbose test: harness file written under LGX_HOME/tmp"
    rm -rf "$proj_t6" "$home_t6"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 45: lgx test <file> happy path"
if supports_source_paths; then
    proj_s1="$(mktemp -d)"
    home_s1="$(mktemp -d)"
    cat > "$proj_s1/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_s1/test"
    cat > "$proj_s1/test/foo_test.lg" <<'EOF'
(ns foo-test
  (:require [test :refer [deftest is]]))

(deftest pass-foo
  (is (= 1 1)))
EOF
    cat > "$proj_s1/test/bar_test.lg" <<'EOF'
(ns bar-test
  (:require [test :refer [deftest is]]))

(deftest pass-bar
  (is (= 2 2)))
EOF
    set +e
    out="$(cd "$proj_s1" && LGX_HOME="$home_s1" "$LGX" test test/foo_test.lg 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "test single: expected exit 0, got $rc (output: $out)"
    pass "test single: exits 0"
    assert_contains "$out" "Running tests in test/foo_test.lg" \
        "test single: header reflects per-file display"
    assert_contains "$out" "pass-foo" "test single: pass-foo printed"
    assert_not_contains "$out" "pass-bar" \
        "test single: bar_test.lg not loaded (discovery bypassed)"
    rm -rf "$proj_s1" "$home_s1"
else
    skip "lgx test <file> requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 46: lgx test <file> missing file"
proj_s2="$(mktemp -d)"
home_s2="$(mktemp -d)"
cat > "$proj_s2/lgx.edn" <<'EOF'
{}
EOF
mkdir -p "$proj_s2/test"
set +e
out="$(cd "$proj_s2" && LGX_HOME="$home_s2" "$LGX" test test/nope.lg 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "test missing-file: expected exit 1, got $rc"
assert_contains "$out" "lgx: test file not found: test/nope.lg" \
    "test missing-file: clear error"
rm -rf "$proj_s2" "$home_s2"

# ---------------------------------------------------------------------------
echo "==> Scenario 47: lgx test <file> wrong extension"
proj_s3="$(mktemp -d)"
home_s3="$(mktemp -d)"
cat > "$proj_s3/lgx.edn" <<'EOF'
{}
EOF
mkdir -p "$proj_s3/test"
touch "$proj_s3/test/foo.txt"
set +e
out="$(cd "$proj_s3" && LGX_HOME="$home_s3" "$LGX" test test/foo.txt 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "test bad-ext: expected exit 1, got $rc"
assert_contains "$out" "lgx: not a test file (expected .lg, .cljc, or .clj): test/foo.txt" \
    "test bad-ext: clear error"
rm -rf "$proj_s3" "$home_s3"

# ---------------------------------------------------------------------------
echo "==> Scenario 48: lgx test <file> outside test/"
proj_s4="$(mktemp -d)"
home_s4="$(mktemp -d)"
cat > "$proj_s4/lgx.edn" <<'EOF'
{}
EOF
mkdir -p "$proj_s4/test" "$proj_s4/src"
touch "$proj_s4/src/foo.lg"
set +e
out="$(cd "$proj_s4" && LGX_HOME="$home_s4" "$LGX" test src/foo.lg 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "test outside: expected exit 1, got $rc"
assert_contains "$out" "lgx: test file must be under test/: src/foo.lg" \
    "test outside: clear error"
rm -rf "$proj_s4" "$home_s4"

# ---------------------------------------------------------------------------
echo "==> Scenario 49: lgx test rejects multiple args"
proj_s5="$(mktemp -d)"
home_s5="$(mktemp -d)"
cat > "$proj_s5/lgx.edn" <<'EOF'
{}
EOF
mkdir -p "$proj_s5/test"
set +e
out="$(cd "$proj_s5" && LGX_HOME="$home_s5" "$LGX" test a.lg b.lg 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "test too-many: expected exit 1, got $rc"
assert_contains "$out" "lgx: test takes at most one argument" \
    "test too-many: clear error"
rm -rf "$proj_s5" "$home_s5"

# Seed a template fixture repo for `lgx new` tests. Sets FIXTURE_REPO_URL
# (a file:// URL) and FIXTURE_REPO_SHA. The repo mirrors lgx-template-base
# structure with the `projectname` placeholder so substitution can be
# observed end-to-end.
setup_template_fixture() {
    FIXTURE_REPO_DIR="$(mktemp -d)"
    git init --quiet -b master "$FIXTURE_REPO_DIR"
    mkdir -p "$FIXTURE_REPO_DIR/src/projectname"
    cat > "$FIXTURE_REPO_DIR/lgx.edn" <<'EOF'
{:paths ["src"]
 :main "main.lg"
 :targets {:bin {:out "bin/projectname"}}
 :deps {}}
EOF
    cat > "$FIXTURE_REPO_DIR/main.lg" <<'EOF'
(ns projectname.main
  (:require [projectname.greeter :as greeter]))
(defn- main [] (prn (greeter/greet "let-go")))
(when-not *compiling-aot* (main))
EOF
    cat > "$FIXTURE_REPO_DIR/src/projectname/greeter.lg" <<'EOF'
(ns projectname.greeter)
(defn greet [name] (str "Welcome to " name "!"))
EOF
    git -C "$FIXTURE_REPO_DIR" add -A
    git -C "$FIXTURE_REPO_DIR" commit --quiet -m fixture
    FIXTURE_REPO_URL="file://$FIXTURE_REPO_DIR"
    FIXTURE_REPO_SHA="$(git -C "$FIXTURE_REPO_DIR" rev-parse HEAD)"
    FIXTURE_REPO_BASENAME="$(basename "$FIXTURE_REPO_DIR")"
    export FIXTURE_REPO_URL FIXTURE_REPO_SHA FIXTURE_REPO_BASENAME
}
setup_template_fixture

echo "==> Scenario 50: lgx new happy path with hyphenated name"
work_s50="$(mktemp -d)"
home_s50="$(mktemp -d)"
set +e
out="$(cd "$work_s50" \
    && LGX_HOME="$home_s50" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new my-app 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "$out" >&2; fail "new hyphen: expected exit 0, got $rc"; }
assert_contains "$out" "Created my-app at" "new hyphen: success line"
assert_contains "$out" "=> Creating project my-app..." "new hyphen: green header on stderr"
[[ -f "$work_s50/my-app/main.lg" ]] || fail "new hyphen: main.lg missing"
[[ -f "$work_s50/my-app/src/my_app/greeter.lg" ]] \
    || fail "new hyphen: underscore path missing"
[[ ! -d "$work_s50/my-app/src/projectname" ]] \
    || fail "new hyphen: placeholder dir still present"
assert_contains "$(cat "$work_s50/my-app/main.lg")" "(ns my-app.main" \
    "new hyphen: ns substituted in main.lg"
assert_contains "$(cat "$work_s50/my-app/lgx.edn")" "bin/my-app" \
    "new hyphen: bin/ name substituted in lgx.edn"
if supports_source_paths; then
    set +e
    run_out="$(cd "$work_s50/my-app" && LGX_HOME="$home_s50" "$LGX" run 2>&1)"; run_rc=$?
    set -e
    [[ $run_rc -eq 0 ]] || { echo "$run_out" >&2; fail "new hyphen: lgx run failed"; }
    assert_contains "$run_out" "Welcome to let-go!" \
        "new hyphen: scaffolded project runs"
else
    skip "new hyphen: lgx run gated on -source-paths"
fi
rm -rf "$work_s50" "$home_s50"

echo "==> Scenario 51: lgx new happy path with non-hyphenated name"
work_s51="$(mktemp -d)"
home_s51="$(mktemp -d)"
set +e
out="$(cd "$work_s51" \
    && LGX_HOME="$home_s51" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new myapp 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "$out" >&2; fail "new nohy: expected exit 0, got $rc"; }
[[ -f "$work_s51/myapp/src/myapp/greeter.lg" ]] \
    || fail "new nohy: src/myapp/greeter.lg missing"
assert_contains "$(cat "$work_s51/myapp/main.lg")" "(ns myapp.main" \
    "new nohy: ns substituted"
assert_contains "$(cat "$work_s51/myapp/lgx.edn")" "bin/myapp" \
    "new nohy: bin/ name substituted"
rm -rf "$work_s51" "$home_s51"

echo "==> Scenario 52: lgx new rejects invalid name"
work_s52="$(mktemp -d)"
home_s52="$(mktemp -d)"
set +e
out="$(cd "$work_s52" \
    && LGX_HOME="$home_s52" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new Foo 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "new invalid-name: expected exit 1, got $rc"
assert_contains "$out" "lgx: invalid project name: Foo" \
    "new invalid-name: clear error"
assert_contains "$out" \
    "name must start with a letter and contain only lowercase letters" \
    "new invalid-name: rule description"
rm -rf "$work_s52" "$home_s52"

echo "==> Scenario 53: lgx new rejects existing non-empty target"
work_s53="$(mktemp -d)"
home_s53="$(mktemp -d)"
mkdir -p "$work_s53/foo"
touch "$work_s53/foo/existing-file"
set +e
out="$(cd "$work_s53" \
    && LGX_HOME="$home_s53" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new foo 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "new non-empty: expected exit 1, got $rc"
assert_contains "$out" "lgx: target directory already exists and is not empty" \
    "new non-empty: clear error"
rm -rf "$work_s53" "$home_s53"

echo "==> Scenario 54: lgx new reuses cache on subsequent calls"
work_s54="$(mktemp -d)"
home_s54="$(mktemp -d)"
cache_dir="$home_s54/templates/_local/_/$FIXTURE_REPO_BASENAME/$FIXTURE_REPO_SHA"
set +e
out="$(cd "$work_s54" \
    && LGX_HOME="$home_s54" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new alpha 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "$out" >&2; fail "new cache: first call failed"; }
[[ -d "$cache_dir" ]] || fail "new cache: cache dir not created"
# Drop a sentinel into the cache. A re-clone would wipe the dir, so the
# sentinel surviving the second call proves cache short-circuit.
echo sentinel > "$cache_dir/.cache-sentinel"
set +e
out2="$(cd "$work_s54" \
    && LGX_HOME="$home_s54" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new beta 2>&1)"; rc2=$?
set -e
[[ $rc2 -eq 0 ]] || { echo "$out2" >&2; fail "new cache: second call failed"; }
[[ -f "$cache_dir/.cache-sentinel" ]] \
    || fail "new cache: sentinel removed (cache was re-cloned)"
pass "new cache: sentinel survives second call (cache reused)"
rm -rf "$work_s54" "$home_s54"

echo "==> Scenario 55: lgx new cold cache clones fresh"
work_s55="$(mktemp -d)"
home_s55="$(mktemp -d)"
# Ensure LGX_HOME is empty so the cache path doesn't exist yet.
rm -rf "$home_s55/templates"
set +e
out="$(cd "$work_s55" \
    && LGX_HOME="$home_s55" \
       LGX_TEMPLATE_BASE_URL="$FIXTURE_REPO_URL" \
       LGX_TEMPLATE_BASE_SHA="$FIXTURE_REPO_SHA" \
       "$LGX" new gamma 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "$out" >&2; fail "new cold: expected exit 0, got $rc"; }
[[ -d "$home_s55/templates/_local/_/$FIXTURE_REPO_BASENAME/$FIXTURE_REPO_SHA" ]] \
    || fail "new cold: cache dir not created"
pass "new cold: cache dir created on first call"
rm -rf "$work_s55" "$home_s55"

echo "==> Scenario 105: lgx new -t <url> scaffolds from template HEAD"
work_s105="$(mktemp -d)"
home_s105="$(mktemp -d)"
set +e
out="$(cd "$work_s105" \
    && LGX_HOME="$home_s105" \
       "$LGX" new tpl-url -t "$FIXTURE_REPO_URL" 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "$out" >&2; fail "new -t url: expected exit 0, got $rc"; }
[[ -f "$work_s105/tpl-url/src/tpl_url/greeter.lg" ]] \
    || fail "new -t url: underscore path missing"
assert_contains "$(cat "$work_s105/tpl-url/main.lg")" "(ns tpl-url.main" \
    "new -t url: ns substituted in main.lg"
# HEAD was resolved to the fixture sha, so the cache lands sha-keyed.
[[ -d "$home_s105/templates/_local/_/$FIXTURE_REPO_BASENAME/$FIXTURE_REPO_SHA" ]] \
    || fail "new -t url: sha-keyed cache dir not created"
pass "new -t url: scaffolds from HEAD with sha-keyed cache"
rm -rf "$work_s105" "$home_s105"

echo "==> Scenario 106: lgx new -t rejects unknown built-in name"
work_s106="$(mktemp -d)"
home_s106="$(mktemp -d)"
set +e
out="$(cd "$work_s106" \
    && LGX_HOME="$home_s106" \
       "$LGX" new demo -t nope 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "new -t unknown: expected exit 1, got $rc"
assert_contains "$out" "lgx: unknown template: nope (built-in: base, cli)" \
    "new -t unknown: clear error with names list"
rm -rf "$work_s106" "$home_s106"

echo "==> Scenario 107: lgx new -t requires a value"
work_s107="$(mktemp -d)"
home_s107="$(mktemp -d)"
set +e
out="$(cd "$work_s107" \
    && LGX_HOME="$home_s107" \
       "$LGX" new demo -t 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "new -t no-value: expected exit 1, got $rc"
assert_contains "$out" "--template requires a value" \
    "new -t no-value: clear error"
rm -rf "$work_s107" "$home_s107"

rm -rf "$FIXTURE_REPO_DIR"

# ---------------------------------------------------------------------------
echo "==> Scenario 56: config-free commands work outside a project"
no_proj="$(mktemp -d)"
# Sanity check: the tmpdir really has no lgx.edn here or anywhere above it
# we could walk into. /tmp on macOS resolves under /private; either way the
# tmpdir itself starts empty.
[[ -e "$no_proj/lgx.edn" ]] && fail "no-project: tmpdir unexpectedly has lgx.edn"

set +e
out="$(cd "$no_proj" && "$LGX" help 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "no-project: 'lgx help' should exit 0 (got $rc)"
assert_contains "$out" "Usage:" "no-project: help prints usage"
assert_contains "$out" "lgx install" "no-project: help lists install"
assert_not_contains "$out" "no lgx.edn" "no-project: help does not print missing-config error"

set +e
out="$(cd "$no_proj" && "$LGX" --help 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "no-project: 'lgx --help' should exit 0 (got $rc)"
assert_contains "$out" "Usage:" "no-project: --help prints usage"

set +e
out="$(cd "$no_proj" && "$LGX" -h 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "no-project: 'lgx -h' should exit 0 (got $rc)"
assert_contains "$out" "Usage:" "no-project: -h prints usage"

set +e
out="$(cd "$no_proj" && "$LGX" 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "no-project: 'lgx' (no args) should exit 1 (got $rc)"
assert_contains "$out" "Usage:" "no-project: bare lgx prints usage"
assert_not_contains "$out" "no lgx.edn" "no-project: bare lgx does not print missing-config error"

set +e
out="$(cd "$no_proj" && "$LGX" nope 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "no-project: 'lgx nope' should exit 1 (got $rc)"
assert_contains "$out" "lgx: 'nope' is not a lgx command. See 'lgx --help'." \
    "no-project: unknown command message is shown"
assert_not_contains "$out" "no lgx.edn" "no-project: unknown command does not print missing-config error"

set +e
out="$(cd "$no_proj" && "$LGX" version 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "no-project: 'lgx version' should exit 0 (got $rc)"
assert_contains "$out" "lgx " "no-project: version prints version line"

rm -rf "$no_proj"

# ---------------------------------------------------------------------------
# Scenarios 57-58 and 61 below run the *.clj file through lg's resolver and
# require the upstream resolver patch (see docs/issues/letgo-clj-support.md).
# Gated behind LGX_CLJ_REQUIRE_E2E until that lands in a released lg.
echo "==> Scenario 57: lgx test discovers *_test.clj (gated on upstream resolver patch)"
if [[ -n "${LGX_CLJ_REQUIRE_E2E:-}" ]]; then
    if supports_source_paths; then
        proj_clj="$(mktemp -d)"
        home_clj="$(mktemp -d)"
        cat > "$proj_clj/lgx.edn" <<'EOF'
{}
EOF
        mkdir -p "$proj_clj/test"
        cat > "$proj_clj/test/foo_test.clj" <<'EOF'
(ns foo-test
  (:require [test :refer [deftest is]]))

(deftest pass-clj
  (is (= 1 1)))
EOF
        set +e
        out="$(cd "$proj_clj" && LGX_HOME="$home_clj" "$LGX" test 2>&1)"; rc=$?
        set -e
        [[ $rc -eq 0 ]] || fail "test .clj discovery: expected exit 0, got $rc (output: $out)"
        pass "test .clj discovery: exits 0"
        assert_contains "$out" "test/foo_test.clj" "test .clj discovery: file header printed"
        assert_contains "$out" "pass-clj" "test .clj discovery: deftest row printed"
        rm -rf "$proj_clj" "$home_clj"
    else
        skip "lgx test requires lg with -source-paths support"
    fi
else
    skip ".clj discovery gated on upstream resolver patch (set LGX_CLJ_REQUIRE_E2E=1 to run)"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 58: lgx test <file> accepts *_test.clj (gated on upstream resolver patch)"
if [[ -n "${LGX_CLJ_REQUIRE_E2E:-}" ]]; then
    if supports_source_paths; then
        proj_cljf="$(mktemp -d)"
        home_cljf="$(mktemp -d)"
        cat > "$proj_cljf/lgx.edn" <<'EOF'
{}
EOF
        mkdir -p "$proj_cljf/test"
        cat > "$proj_cljf/test/single_test.clj" <<'EOF'
(ns single-test
  (:require [test :refer [deftest is]]))

(deftest single-clj
  (is (= 42 42)))
EOF
        set +e
        out="$(cd "$proj_cljf" && LGX_HOME="$home_cljf" \
                "$LGX" test test/single_test.clj 2>&1)"; rc=$?
        set -e
        [[ $rc -eq 0 ]] || fail "test .clj single-file: expected exit 0, got $rc (output: $out)"
        pass "test .clj single-file: exits 0"
        assert_contains "$out" "single-clj" "test .clj single-file: deftest row printed"
        rm -rf "$proj_cljf" "$home_cljf"
    else
        skip "lgx test requires lg with -source-paths support"
    fi
else
    skip ".clj single-file gated on upstream resolver patch (set LGX_CLJ_REQUIRE_E2E=1 to run)"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 59: lgx test <file> wrong extension lists .clj"
proj_ext="$(mktemp -d)"
home_ext="$(mktemp -d)"
cat > "$proj_ext/lgx.edn" <<'EOF'
{}
EOF
mkdir -p "$proj_ext/test"
touch "$proj_ext/test/foo.txt"
set +e
out="$(cd "$proj_ext" && LGX_HOME="$home_ext" "$LGX" test test/foo.txt 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "test .clj ext error: expected exit 1, got $rc"
assert_contains "$out" ".clj" "test .clj ext error: message mentions .clj"
rm -rf "$proj_ext" "$home_ext"

# ---------------------------------------------------------------------------
echo "==> Scenario 60: lgx run exports LG_READ_CLJ=1 to child lg"
if supports_source_paths; then
    proj_env="$(mktemp -d)"
    home_env="$(mktemp -d)"
    cat > "$proj_env/lgx.edn" <<'EOF'
{}
EOF
    set +e
    # Capture child stdout only — lgx's run header goes to stderr and would
    # otherwise become the first line.
    out="$(cd "$proj_env" && LGX_HOME="$home_env" \
            "$LGX" run -e '(println (os/getenv "LG_READ_CLJ"))' 2>/dev/null)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "test LG_READ_CLJ: expected exit 0, got $rc (output: $out)"
    pass "test LG_READ_CLJ: exits 0"
    # `lg -e` prints the form's value (nil) after the println output. The
    # first line is what we set.
    first_line="$(printf '%s\n' "$out" | head -n 1)"
    assert_eq "$first_line" "1" "test LG_READ_CLJ: child sees value 1"
    rm -rf "$proj_env" "$home_env"
else
    skip "lgx run -e requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 61: .clj library require (gated on upstream resolver patch)"
if [[ -n "${LGX_CLJ_REQUIRE_E2E:-}" ]]; then
    if supports_source_paths; then
        proj_req="$(mktemp -d)"
        home_req="$(mktemp -d)"
        cat > "$proj_req/lgx.edn" <<'EOF'
{:paths ["src"]}
EOF
        mkdir -p "$proj_req/src"
        cat > "$proj_req/src/greeter.clj" <<'EOF'
(ns greeter)
(defn greet [n] (str "Hello, " n "!"))
EOF
        cat > "$proj_req/main.lg" <<'EOF'
(require '[greeter])
(println (greeter/greet "world"))
EOF
        set +e
        out="$(cd "$proj_req" && LGX_HOME="$home_req" \
                "$LGX" run main.lg 2>&1)"; rc=$?
        set -e
        [[ $rc -eq 0 ]] || fail "test .clj require: expected exit 0, got $rc (output: $out)"
        assert_contains "$out" "Hello, world!" "test .clj require: greeter output printed"
        rm -rf "$proj_req" "$home_req"
    else
        skip ".clj require requires lg with -source-paths support"
    fi
else
    skip ".clj require gated on upstream resolver patch (set LGX_CLJ_REQUIRE_E2E=1 to run)"
fi

# Scenarios 62-65 run projects with dependencies, so they need an lg that
# supports -source-paths.
if supports_source_paths; then

# ---------------------------------------------------------------------------
echo "==> Scenario 62: transitive deps are followed, nested relative paths resolve against the dep"
troot="$(mktemp -d)"
home_tr="$(mktemp -d)"
# leaf libB, nested next to libA (NOT next to the project)
mkdir -p "$troot/nested/libB/src/libb"
printf '(ns libb.core)\n(defn b [] :B)\n' > "$troot/nested/libB/src/libb/core.lg"
printf '{:deps {}}\n' > "$troot/nested/libB/lgx.edn"
# libA (nested) depends on libB via a path relative to libA itself
mkdir -p "$troot/nested/libA/src/liba"
printf '(ns liba.core (:require [libb.core :as b]))\n(defn a [] [:A (b/b)])\n' \
    > "$troot/nested/libA/src/liba/core.lg"
printf '{:deps {dev/libB {:local/root "../libB"}}}\n' > "$troot/nested/libA/lgx.edn"
# project depends on libA ONLY (libB is transitive). "../libB" must resolve
# relative to libA (-> nested/libB), not relative to the project root.
mkdir -p "$troot/proj"
printf '{:deps {dev/libA {:local/root "../nested/libA"}}}\n' > "$troot/proj/lgx.edn"
printf '(require (quote liba.core))\n(println (liba.core/a))\n' > "$troot/proj/main.lg"

out="$(cd "$troot/proj" && LGX_HOME="$home_tr" "$LGX" run main.lg 2>&1)"
# liba.core can only require libb.core if the transitive dep resolved correctly
assert_contains "$out" "[:A :B]" "transitive: nested libB resolved relative to libA"
rm -rf "$troot" "$home_tr"

# ---------------------------------------------------------------------------
echo "==> Scenario 63: transitive conflict resolves first-wins with a warning"
croot="$(mktemp -d)"
home_c="$(mktemp -d)"
# two versions of the same lib name `dev/dup`
mkdir -p "$croot/dupRoot/src/dup"
printf '(ns dup.core)\n(defn which [] :root)\n' > "$croot/dupRoot/src/dup/core.lg"
printf '{:deps {}}\n' > "$croot/dupRoot/lgx.edn"
mkdir -p "$croot/dupDeep/src/dup"
printf '(ns dup.core)\n(defn which [] :deep)\n' > "$croot/dupDeep/src/dup/core.lg"
printf '{:deps {}}\n' > "$croot/dupDeep/lgx.edn"
# libMid depends on the DEEP dup
mkdir -p "$croot/libMid/src/mid"
printf '(ns mid.core)\n' > "$croot/libMid/src/mid/core.lg"
printf '{:deps {dev/dup {:local/root "../dupDeep"}}}\n' > "$croot/libMid/lgx.edn"
# project lists dev/dup (root version) FIRST, then libMid (pulls deep dup)
mkdir -p "$croot/proj"
cat > "$croot/proj/lgx.edn" <<EOF
{:deps {dev/dup {:local/root "../dupRoot"}
        dev/libMid {:local/root "../libMid"}}}
EOF
printf '(require (quote dup.core))\n(println (dup.core/which))\n' > "$croot/proj/main.lg"

out="$(cd "$croot/proj" && LGX_HOME="$home_c" "$LGX" run main.lg 2>&1)"
# project's dup (root) is shallower, so first-wins keeps :root
assert_contains "$out" ":root" "conflict: shallower coord wins (first-wins)"
assert_contains "$out" "already resolved as" "conflict: prints a divergence warning"
rm -rf "$croot" "$home_c"

# ---------------------------------------------------------------------------
echo "==> Scenario 64: a dependency cycle terminates, and a repeated identical coord doesn't warn"
yroot="$(mktemp -d)"
home_y="$(mktemp -d)"
# cycA and cycB depend on EACH OTHER (deps cycle), but their code does not
# require circularly — so this exercises lgx's cycle handling, not let-go's.
mkdir -p "$yroot/cycA/src/cyca"
printf '(ns cyca.core)\n(defn v [] :A)\n' > "$yroot/cycA/src/cyca/core.lg"
printf '{:deps {dev/cycB {:local/root "../cycB"}}}\n' > "$yroot/cycA/lgx.edn"
mkdir -p "$yroot/cycB/src/cycb"
printf '(ns cycb.core)\n(defn v [] :B)\n' > "$yroot/cycB/src/cycb/core.lg"
printf '{:deps {dev/cycA {:local/root "../cycA"}}}\n' > "$yroot/cycB/lgx.edn"
mkdir -p "$yroot/proj"
printf '{:deps {dev/cycA {:local/root "../cycA"}}}\n' > "$yroot/proj/lgx.edn"
printf '(require (quote cyca.core) (quote cycb.core))\n(println [(cyca.core/v) (cycb.core/v)])\n' \
    > "$yroot/proj/main.lg"

# The walk re-reaches cycA via cycB with the SAME coord: it must stop (the seen
# set terminates the cycle) and must NOT warn (identical coord = silent dedup).
out="$(cd "$yroot/proj" && LGX_HOME="$home_y" timeout 30 "$LGX" run main.lg 2>&1)"
rc=$?
[[ $rc -ne 124 ]] || fail "cycle: lgx run timed out (cycle did not terminate)"
assert_contains "$out" "[:A :B]" "cycle: both cyclic deps resolved, walk terminated"
if printf '%s' "$out" | grep -q "already resolved as"; then
    fail "cycle: identical repeated coord must not warn (silent dedup)"
else
    pass "cycle: identical repeated coord is deduped silently"
fi
rm -rf "$yroot" "$home_y"

# ---------------------------------------------------------------------------
echo "==> Scenario 65: relative local conflicts compare resolved dirs"
rroot="$(mktemp -d)"
home_r="$(mktemp -d)"
# libA and libB both declare dev/shared with the same raw coord
# {:local/root "shared"}, but the base dirs differ.
mkdir -p "$rroot/libA/src/liba" "$rroot/libA/shared/src/shared"
printf '(ns liba.core)\n' > "$rroot/libA/src/liba/core.lg"
printf '(ns shared.core)\n(defn which [] :A)\n' > "$rroot/libA/shared/src/shared/core.lg"
printf '{:deps {}}\n' > "$rroot/libA/shared/lgx.edn"
printf '{:deps {dev/shared {:local/root "shared"}}}\n' > "$rroot/libA/lgx.edn"

mkdir -p "$rroot/libB/src/libb" "$rroot/libB/shared/src/shared"
printf '(ns libb.core)\n' > "$rroot/libB/src/libb/core.lg"
printf '(ns shared.core)\n(defn which [] :B)\n' > "$rroot/libB/shared/src/shared/core.lg"
printf '{:deps {}}\n' > "$rroot/libB/shared/lgx.edn"
printf '{:deps {dev/shared {:local/root "shared"}}}\n' > "$rroot/libB/lgx.edn"

mkdir -p "$rroot/proj"
cat > "$rroot/proj/lgx.edn" <<EOF
{:deps {dev/libA {:local/root "../libA"}
        dev/libB {:local/root "../libB"}}}
EOF
printf '(require (quote shared.core))\n(println (shared.core/which))\n' > "$rroot/proj/main.lg"

out="$(cd "$rroot/proj" && LGX_HOME="$home_r" "$LGX" run main.lg 2>&1)"
assert_contains "$out" ":A" "relative conflict: first resolved local dir wins"
assert_contains "$out" "already resolved as" "relative conflict: differing resolved dirs warn"
rm -rf "$rroot" "$home_r"

else
    skip "transitive deps require lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 66: lgx run sets LGX_RUN=1 for the spawned program"
proj_run="$(mktemp -d)"
home_run="$(mktemp -d)"
cat > "$proj_run/lgx.edn" <<'EOF'
{:main "main.lg"}
EOF
cat > "$proj_run/main.lg" <<'EOF'
(when-not *compiling-aot*
  (println (str "LGX_RUN=" (os/getenv "LGX_RUN"))))
EOF
out="$(cd "$proj_run" && LGX_HOME="$home_run" "$LGX" run)"
assert_contains "$out" "LGX_RUN=1" "run: LGX_RUN=1 is set in the spawned process"
rm -rf "$proj_run" "$home_run"

# ---------------------------------------------------------------------------
echo "==> Scenario 67: a task :run step also sets LGX_RUN=1"
proj_trun="$(mktemp -d)"
home_trun="$(mktemp -d)"
cat > "$proj_trun/lgx.edn" <<'EOF'
{:main "main.lg"
 :tasks {show {:do [{:run "main.lg"}]}}}
EOF
cat > "$proj_trun/main.lg" <<'EOF'
(when-not *compiling-aot*
  (println (str "LGX_RUN=" (os/getenv "LGX_RUN"))))
EOF
out="$(cd "$proj_trun" && LGX_HOME="$home_trun" "$LGX" show)"
assert_contains "$out" "LGX_RUN=1" "task :run: LGX_RUN=1 is set in the spawned process"
rm -rf "$proj_trun" "$home_trun"

# ---------------------------------------------------------------------------
echo "==> Scenario 68: lgx test fails when a test file does not compile"
if supports_source_paths; then
    proj_brk="$(mktemp -d)"
    home_brk="$(mktemp -d)"
    cat > "$proj_brk/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_brk/test"
    cat > "$proj_brk/test/ok_test.lg" <<'EOF'
(ns ok-test
  (:require [test :refer [deftest is]]))

(deftest pass-1
  (is (= 1 1)))
EOF
    # References an undefined symbol -> let-go's require prints
    # "error: failed to load ..." to stderr but does not throw or set a
    # non-zero exit. lgx must detect that and fail.
    cat > "$proj_brk/test/broken_test.lg" <<'EOF'
(ns broken-test
  (:require [test :refer [deftest is]]))

(deftest references-undefined
  (is (= 1 (totally-undefined-symbol 1))))
EOF
    set +e
    out="$(cd "$proj_brk" && LGX_HOME="$home_brk" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -ne 0 ]] || fail "broken test: expected non-zero exit, got $rc (output: $out)"
    pass "broken test: lgx test exits non-zero"
    assert_contains "$out" "error: failed to load" \
        "broken test: lg's load error is surfaced"
    assert_contains "$out" "a test file failed to load" \
        "broken test: lgx explains the failure"
    rm -rf "$proj_brk" "$home_brk"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 69: a passing test that prints the load-error phrase still passes"
if supports_source_paths; then
    proj_fp="$(mktemp -d)"
    home_fp="$(mktemp -d)"
    cat > "$proj_fp/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_fp/test"
    # Two lookalikes that must NOT trip detection: a top-level form writes a
    # phrase during load (before the harness marker) that starts like lg's
    # diagnostic but lacks the error-type tag, and a passing test writes the
    # phrase during execution (after the marker). The run must exit 0.
    cat > "$proj_fp/test/sneaky_test.lg" <<'EOF'
(ns sneaky-test
  (:require [test :refer [deftest is]]))

(write! *err* "error: failed to load preferences, using defaults\n")

(deftest passes-but-prints-scary-stderr
  (write! *err* "error: failed to load /not-real from a passing test\n")
  (is (= 1 1)))
EOF
    set +e
    out="$(cd "$proj_fp" && LGX_HOME="$home_fp" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "false positive: expected exit 0, got $rc (output: $out)"
    pass "false positive: passing test with scary stderr exits 0"
    assert_not_contains "$out" "lgx-test-harness-ready" \
        "false positive: harness marker is stripped from output"
    rm -rf "$proj_fp" "$home_fp"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 70: lgx test fails on a reader/syntax error (not just compile)"
if supports_source_paths; then
    proj_syn="$(mktemp -d)"
    home_syn="$(mktemp -d)"
    cat > "$proj_syn/lgx.edn" <<'EOF'
{}
EOF
    mkdir -p "$proj_syn/test"
    # `#` with no following macro is a reader error: lg emits
    # "error: failed to load ...: Syntax error reading source ..." (no
    # CompileError/ExecutionError tag) and still exits 0. Must be caught.
    cat > "$proj_syn/test/syn_test.lg" <<'EOF'
(ns syn-test
  (:require [test :refer [deftest is]]))

(def y #)

(deftest t (is (= 1 1)))
EOF
    set +e
    out="$(cd "$proj_syn" && LGX_HOME="$home_syn" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -ne 0 ]] || fail "syntax error: expected non-zero exit, got $rc (output: $out)"
    pass "syntax error: lgx test exits non-zero"
    assert_contains "$out" "Syntax error reading source" \
        "syntax error: lg's reader error is surfaced"
    assert_contains "$out" "a test file failed to load" \
        "syntax error: lgx explains the failure"
    rm -rf "$proj_syn" "$home_syn"
else
    skip "lgx test requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 71: task :extra-paths adds a source dir for the task's :run step"
if supports_source_paths; then
    proj_ep="$(mktemp -d)"
    home_ep="$(mktemp -d)"
    mkdir -p "$proj_ep/dev"
    cat > "$proj_ep/dev/devtool.lg" <<'EOF'
(ns devtool)
(defn banner [] "DEV-OK")
EOF
    cat > "$proj_ep/task-main.lg" <<'EOF'
(ns task.main
  (:require [devtool]))
(println (devtool/banner))
EOF
    cat > "$proj_ep/lgx.edn" <<'EOF'
{:tasks
 {devrun {:extra-paths ["dev"]
           :do [{:run "task-main.lg"}]}}}
EOF
    out="$(cd "$proj_ep" && LGX_HOME="$home_ep" "$LGX" devrun 2>&1)"
    assert_contains "$out" "DEV-OK" \
        "task extra-paths: :run step resolves ns from extra-paths dir"
    rm -rf "$proj_ep" "$home_ep"
else
    skip "task :extra-paths requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 72: task :extra-deps fetches a dep for the task's :run step"
if supports_source_paths; then
    home_ed="$(mktemp -d)"
    bare_ed="$home_ed/_fixtures/test-repo.git"
    mkdir -p "$(dirname "$bare_ed")"
    sha_ed="$(make_bare_repo "$bare_ed")"
    proj_ed="$(mktemp -d)"
    cat > "$proj_ed/fib-main.lg" <<'EOF'
(ns fib.main
  (:require [test.fib :as fib]))
(println (fib/fib 10))
EOF
    cat > "$proj_ed/lgx.edn" <<EOF
{:tasks
 {fibrun {:extra-deps {test/lib {:git/url "file://$bare_ed"
                                  :git/sha "$sha_ed"}}
           :do [{:run "fib-main.lg"}]}}}
EOF
    out="$(cd "$proj_ed" && LGX_HOME="$home_ed" "$LGX" fibrun 2>&1)"
    assert_contains "$out" "installing 1 dep(s)..." \
        "task extra-deps: cold fetch shows install block"
    assert_contains "$out" "55" \
        "task extra-deps: :run step resolves ns from extra-deps git lib"
    rm -rf "$proj_ed" "$home_ed"
else
    skip "task :extra-deps requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 73: --with applies a context's :extra-paths to run"
if supports_source_paths; then
    home_c1="$(mktemp -d)"
    proj_c1="$(mktemp -d)"
    mkdir -p "$proj_c1/dev"
    cat > "$proj_c1/dev/devtool.lg" <<'EOF'
(ns devtool)
(defn banner [] "DEV-OK")
EOF
    cat > "$proj_c1/m.lg" <<'EOF'
(ns m
  (:require [devtool]))
(println (devtool/banner))
EOF
    cat > "$proj_c1/lgx.edn" <<'EOF'
{:main "m.lg"
 :contexts {:dev {:extra-paths ["dev"]}}}
EOF
    out="$(cd "$proj_c1" && LGX_HOME="$home_c1" "$LGX" --with dev run 2>&1)"
    assert_contains "$out" "DEV-OK" \
        "--with extra-paths: run resolves ns from context dir"
    rm -rf "$proj_c1" "$home_c1"
else
    skip "--with :extra-paths requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 74: --with cold-fetches a context's :extra-deps git lib"
if supports_source_paths; then
    home_c2="$(mktemp -d)"
    bare_c2="$home_c2/_fixtures/test-repo.git"
    mkdir -p "$(dirname "$bare_c2")"
    sha_c2="$(make_bare_repo "$bare_c2")"
    proj_c2="$(mktemp -d)"
    cat > "$proj_c2/fib.lg" <<'EOF'
(ns fib
  (:require [test.fib :as f]))
(println (f/fib 10))
EOF
    cat > "$proj_c2/lgx.edn" <<EOF
{:main "fib.lg"
 :contexts {:lib {:extra-deps {test/lib {:git/url "file://$bare_c2"
                                         :git/sha "$sha_c2"}}}}}
EOF
    out="$(cd "$proj_c2" && LGX_HOME="$home_c2" "$LGX" --with lib run 2>&1)"
    assert_contains "$out" "installing 1 dep(s)..." \
        "--with extra-deps: cold fetch shows install block"
    assert_contains "$out" "55" \
        "--with extra-deps: run resolves ns from context git lib"
    rm -rf "$proj_c2" "$home_c2"
else
    skip "--with :extra-deps requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 75: task :with pulls in a context's :extra-paths"
if supports_source_paths; then
    home_c3="$(mktemp -d)"
    proj_c3="$(mktemp -d)"
    mkdir -p "$proj_c3/dev"
    cat > "$proj_c3/dev/devtool.lg" <<'EOF'
(ns devtool)
(defn banner [] "DEV-OK")
EOF
    cat > "$proj_c3/m.lg" <<'EOF'
(ns m
  (:require [devtool]))
(println (devtool/banner))
EOF
    cat > "$proj_c3/lgx.edn" <<'EOF'
{:contexts {:dev {:extra-paths ["dev"]}}
 :tasks {t {:with [:dev] :do [{:run "m.lg"}]}}}
EOF
    out="$(cd "$proj_c3" && LGX_HOME="$home_c3" "$LGX" t 2>&1)"
    assert_contains "$out" "DEV-OK" \
        "task :with: :run step resolves ns from context dir"
    rm -rf "$proj_c3" "$home_c3"
else
    skip "task :with requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 76: CLI --with unions with a task's :with"
if supports_source_paths; then
    home_c4="$(mktemp -d)"
    proj_c4="$(mktemp -d)"
    mkdir -p "$proj_c4/dir-a" "$proj_c4/dir-b"
    cat > "$proj_c4/dir-a/atool.lg" <<'EOF'
(ns atool)
(defn a [] "A-OK")
EOF
    cat > "$proj_c4/dir-b/btool.lg" <<'EOF'
(ns btool)
(defn b [] "B-OK")
EOF
    cat > "$proj_c4/m.lg" <<'EOF'
(ns m
  (:require [atool]
            [btool]))
(println (atool/a) (btool/b))
EOF
    cat > "$proj_c4/lgx.edn" <<'EOF'
{:contexts {:a {:extra-paths ["dir-a"]}
            :b {:extra-paths ["dir-b"]}}
 :tasks {t {:with [:a] :do [{:run "m.lg"}]}}}
EOF
    out="$(cd "$proj_c4" && LGX_HOME="$home_c4" "$LGX" --with b t 2>&1)"
    assert_contains "$out" "A-OK" \
        "union: task :with [:a] context applies"
    assert_contains "$out" "B-OK" \
        "union: CLI --with b context applies on top of task :with"
    rm -rf "$proj_c4" "$home_c4"
else
    skip "union :with requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 77: unknown context names fail loudly"
home_c5="$(mktemp -d)"
proj_c5="$(mktemp -d)"
cat > "$proj_c5/m.lg" <<'EOF'
(ns m)
(println :ok)
EOF
cat > "$proj_c5/lgx.edn" <<'EOF'
{:main "m.lg"
 :contexts {:dev {:extra-paths ["dev"]}}}
EOF
set +e
out="$(cd "$proj_c5" && LGX_HOME="$home_c5" "$LGX" --with typo run 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "unknown --with: expected non-zero exit"
assert_contains "$out" "lgx: unknown context :typo" \
    "unknown --with: runtime error names the context"
rm -rf "$proj_c5"

# Task :with referencing an unknown context fails at config validation,
# before any lg call (no -source-paths support needed).
proj_c6="$(mktemp -d)"
cat > "$proj_c6/lgx.edn" <<'EOF'
{:contexts {:dev {}}
 :tasks {t {:with [:nope] :do [{:sh "echo hi"}]}}}
EOF
set +e
out="$(cd "$proj_c6" && LGX_HOME="$home_c5" "$LGX" t 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "task :with unknown context: expected non-zero exit"
assert_contains "$out" "references unknown context :nope" \
    "task :with unknown context: config validation error"
rm -rf "$proj_c6" "$home_c5"

# ---------------------------------------------------------------------------
# Scenarios 78-82 cover :resource-paths / :extra-resource-paths -> lg's
# -resource-paths flag. The signal (some? (io/resource "x")) is true only when
# the root is on the resource path, which avoids depending on a resource-read
# API. Gated on supports_resource_paths (released lg lacks the flag).
echo "==> Scenario 78: top-level :resource-paths makes io/resource resolve on run"
if supports_resource_paths; then
    proj_rp="$(mktemp -d)"
    home_rp="$(mktemp -d)"
    mkdir -p "$proj_rp/resources"
    echo "hello-resource" > "$proj_rp/resources/greeting.txt"
    cat > "$proj_rp/m.lg" <<'EOF'
(ns m)
(println "found=" (some? (io/resource "greeting.txt")))
EOF
    cat > "$proj_rp/lgx.edn" <<'EOF'
{:main "m.lg"
 :resource-paths ["resources"]}
EOF
    out="$(cd "$proj_rp" && LGX_HOME="$home_rp" "$LGX" run 2>&1)"
    assert_contains "$out" "found= true" \
        "resource-paths: io/resource resolves under the declared root"
    # Same project without :resource-paths -> resource is not found.
    echo '{:main "m.lg"}' > "$proj_rp/lgx.edn"
    out="$(cd "$proj_rp" && LGX_HOME="$home_rp" "$LGX" run 2>&1)"
    assert_contains "$out" "found= false" \
        "resource-paths: io/resource absent without a declared root"
    rm -rf "$proj_rp" "$home_rp"
else
    skip "resource-paths requires lg with -resource-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 79: --with applies a context's :extra-resource-paths to run"
if supports_resource_paths; then
    proj_rc="$(mktemp -d)"
    home_rc="$(mktemp -d)"
    mkdir -p "$proj_rc/assets"
    echo "asset" > "$proj_rc/assets/greeting.txt"
    cat > "$proj_rc/m.lg" <<'EOF'
(ns m)
(println "found=" (some? (io/resource "greeting.txt")))
EOF
    cat > "$proj_rc/lgx.edn" <<'EOF'
{:main "m.lg"
 :contexts {:res {:extra-resource-paths ["assets"]}}}
EOF
    out="$(cd "$proj_rc" && LGX_HOME="$home_rc" "$LGX" --with res run 2>&1)"
    assert_contains "$out" "found= true" \
        "--with extra-resource-paths: context adds the resource root"
    out="$(cd "$proj_rc" && LGX_HOME="$home_rc" "$LGX" run 2>&1)"
    assert_contains "$out" "found= false" \
        "--with extra-resource-paths: root absent without --with"
    rm -rf "$proj_rc" "$home_rc"
else
    skip "context :extra-resource-paths requires lg with -resource-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 80: task :extra-resource-paths adds a resource root for :run"
if supports_resource_paths; then
    proj_rt="$(mktemp -d)"
    home_rt="$(mktemp -d)"
    mkdir -p "$proj_rt/assets"
    echo "asset" > "$proj_rt/assets/greeting.txt"
    cat > "$proj_rt/task-main.lg" <<'EOF'
(ns task.main)
(println "found=" (some? (io/resource "greeting.txt")))
EOF
    cat > "$proj_rt/lgx.edn" <<'EOF'
{:tasks
 {resrun {:extra-resource-paths ["assets"]
           :do [{:run "task-main.lg"}]}}}
EOF
    out="$(cd "$proj_rt" && LGX_HOME="$home_rt" "$LGX" resrun 2>&1)"
    assert_contains "$out" "found= true" \
        "task extra-resource-paths: :run step resolves the resource"
    rm -rf "$proj_rt" "$home_rt"
else
    skip "task :extra-resource-paths requires lg with -resource-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 81: lgx build embeds resources into the standalone binary"
if supports_resource_paths; then
    proj_rb="$(mktemp -d)"
    home_rb="$(mktemp -d)"
    mkdir -p "$proj_rb/resources"
    echo "embedded" > "$proj_rb/resources/greeting.txt"
    cat > "$proj_rb/app.lg" <<'EOF'
(ns app)
(when-not *compiling-aot*
  (println "found=" (some? (io/resource "greeting.txt"))))
EOF
    cat > "$proj_rb/lgx.edn" <<'EOF'
{:main "app.lg"
 :resource-paths ["resources"]
 :targets {:bin {:out "bin/app"}}}
EOF
    out="$(cd "$proj_rb" && LGX_HOME="$home_rb" "$LGX" build 2>&1)"
    [[ -x "$proj_rb/bin/app" ]] || fail "build embed: expected bin/app executable"
    # Run the binary from a clean dir with no resources/ nearby: a true result
    # proves the resource was embedded, not read off the filesystem.
    clean="$(mktemp -d)"
    cp "$proj_rb/bin/app" "$clean/app"
    out_run="$(cd "$clean" && ./app 2>&1)"
    assert_contains "$out_run" "found= true" \
        "build embed: bundled binary resolves io/resource from a clean dir"
    rm -rf "$proj_rb" "$home_rb" "$clean"
else
    skip "build embed requires lg with -resource-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 82: --verbose run trace includes -resource-paths when set"
if supports_resource_paths; then
    proj_rv="$(mktemp -d)"
    home_rv="$(mktemp -d)"
    mkdir -p "$proj_rv/resources"
    echo "x" > "$proj_rv/resources/greeting.txt"
    cat > "$proj_rv/m.lg" <<'EOF'
(ns m)
(println :ok)
EOF
    cat > "$proj_rv/lgx.edn" <<'EOF'
{:main "m.lg"
 :resource-paths ["resources"]}
EOF
    err="$(cd "$proj_rv" && LGX_HOME="$home_rv" "$LGX" --verbose run 2>&1 >/dev/null)"
    assert_contains "$err" "-resource-paths" \
        "verbose run: trace includes -resource-paths when :resource-paths is set"
    rm -rf "$proj_rv" "$home_rv"
else
    skip "verbose -resource-paths trace requires lg with -resource-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 83: install prints a green header on stderr, clean stdout"
proj_h="$(mktemp -d)"; home_h="$(mktemp -d)"
printf '{}\n' > "$proj_h/lgx.edn"
err="$(cd "$proj_h" && LGX_HOME="$home_h" LGX_NO_COLOR=1 "$LGX" install 2>&1 >/dev/null)"
out="$(cd "$proj_h" && LGX_HOME="$home_h" LGX_NO_COLOR=1 "$LGX" install 2>/dev/null)"
assert_contains "$err" "=> Installing dependencies..." "install header: on stderr"
assert_eq "$out" "no deps in lgx.edn" "install header: stdout unchanged"
assert_not_contains "$out" "=>" "install header: stdout has no header"
# Color on (no LGX_NO_COLOR): the header is green.
err_c="$(cd "$proj_h" && LGX_HOME="$home_h" "$LGX" install 2>&1 >/dev/null)"
assert_contains "$err_c" $'\e[38;5;35m=>' "install header: green when color enabled"
rm -rf "$proj_h" "$home_h"

# ---------------------------------------------------------------------------
echo "==> Scenario 84: run prints NO header (mirrors the built binary)"
proj_r="$(mktemp -d)"; home_r="$(mktemp -d)"
printf '{}\n' > "$proj_r/lgx.edn"
printf '(println :ran)\n' > "$proj_r/m.lg"
err="$(cd "$proj_r" && LGX_HOME="$home_r" "$LGX" run m.lg 2>&1 >/dev/null)"
out="$(cd "$proj_r" && LGX_HOME="$home_r" "$LGX" run m.lg 2>/dev/null)"
assert_not_contains "$err" "=>" "run: no status header on stderr"
assert_eq "$out" ":ran" "run: stdout is only the script output"
rm -rf "$proj_r" "$home_r"

# ---------------------------------------------------------------------------
echo "==> Scenario 85: build prints a green header on stderr"
proj_b="$(mktemp -d)"; home_b="$(mktemp -d)"
cat > "$proj_b/lgx.edn" <<'EOF'
{:main "m.lg" :targets {:bin {:out "bin/app"}}}
EOF
printf '(println :built)\n' > "$proj_b/m.lg"
err="$(cd "$proj_b" && LGX_HOME="$home_b" LGX_NO_COLOR=1 "$LGX" build 2>&1 >/dev/null)"
out="$(cd "$proj_b" && LGX_HOME="$home_b" LGX_NO_COLOR=1 "$LGX" build 2>/dev/null)"
assert_contains "$err" "=> Building bin/app..." "build header: on stderr"
assert_not_contains "$out" "=>" "build header: stdout has no header"
rm -rf "$proj_b" "$home_b"

# ---------------------------------------------------------------------------
echo "==> Scenario 86: task prints a purple header and \$ step lines on stderr"
proj_ts="$(mktemp -d)"; home_ts="$(mktemp -d)"
cat > "$proj_ts/lgx.edn" <<'EOF'
{:tasks {hello {:do [{:sh "echo hi from task"}]}}}
EOF
err="$(cd "$proj_ts" && LGX_HOME="$home_ts" LGX_NO_COLOR=1 "$LGX" hello 2>&1 >/dev/null)"
out="$(cd "$proj_ts" && LGX_HOME="$home_ts" LGX_NO_COLOR=1 "$LGX" hello 2>/dev/null)"
assert_contains "$err" "=> Running task hello..." "task output: purple header on stderr"
assert_contains "$err" '$ echo hi from task' "task output: \$ step line on stderr"
assert_eq "$out" "hi from task" "task output: stdout is only the step output"
rm -rf "$proj_ts" "$home_ts"

# ---------------------------------------------------------------------------
echo "==> Scenario 87: task :run step echoes 'lgx run' on stderr"
if supports_source_paths; then
    proj_tr2="$(mktemp -d)"; home_tr2="$(mktemp -d)"
    printf '(println :from-run-step)\n' > "$proj_tr2/r.lg"
    cat > "$proj_tr2/lgx.edn" <<'EOF'
{:tasks {go {:do [{:run "r.lg"}]}}}
EOF
    err="$(cd "$proj_tr2" && LGX_HOME="$home_tr2" LGX_NO_COLOR=1 "$LGX" go 2>&1 >/dev/null)"
    out="$(cd "$proj_tr2" && LGX_HOME="$home_tr2" LGX_NO_COLOR=1 "$LGX" go 2>/dev/null)"
    assert_contains "$err" '$ lgx run r.lg' "task :run: echoes lgx run on stderr"
    assert_eq "$out" ":from-run-step" "task :run: stdout is only the run output"
    rm -rf "$proj_tr2" "$home_tr2"
else
    skip "task :run step requires lg with -source-paths support"
fi

echo "==> Scenario 88: lgx run exports LG_SUPPRESS_SOURCE_PATHS_WARNING=1 and silences lg's source-paths notice"
if supports_source_paths; then
    proj_spw="$(mktemp -d)"; home_spw="$(mktemp -d)"
    # :paths must be non-empty so lgx actually emits -source-paths (an absolute
    # dir, never literal "."); otherwise lg has no reason to print the
    # transition notice and the warning assertion below would be vacuous.
    cat > "$proj_spw/lgx.edn" <<'EOF'
{:paths ["."]}
EOF
    set +e
    # Child stdout only — lgx's run header goes to stderr.
    out="$(cd "$proj_spw" && LGX_HOME="$home_spw" \
            "$LGX" run -e '(println (os/getenv "LG_SUPPRESS_SOURCE_PATHS_WARNING"))' 2>/dev/null)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "test LG_SUPPRESS_SOURCE_PATHS_WARNING: expected exit 0, got $rc (output: $out)"
    pass "test LG_SUPPRESS_SOURCE_PATHS_WARNING: exits 0"
    first_line="$(printf '%s\n' "$out" | head -n 1)"
    assert_eq "$first_line" "1" "test LG_SUPPRESS_SOURCE_PATHS_WARNING: child sees value 1"
    # lgx always passes an explicit -source-paths that omits ".", which would
    # trip lg's transition notice; the exported var must keep it off stderr.
    err="$(cd "$proj_spw" && LGX_HOME="$home_spw" LGX_NO_COLOR=1 \
            "$LGX" run -e '(println 1)' 2>&1 >/dev/null)"
    assert_not_contains "$err" "WARNING" "test LG_SUPPRESS_SOURCE_PATHS_WARNING: no source-paths warning on stderr"
    rm -rf "$proj_spw" "$home_spw"
else
    skip "lgx run -e requires lg with -source-paths support"
fi

echo "==> Scenario 89: bare lgx run without :main drops into an interactive REPL"
# No :main, no :paths/:deps — lgx forwards an empty argv and lg starts its
# REPL. The child inherits lgx's stdin (the pipe here), so the expression is
# evaluated and the REPL exits on EOF. Under the old captured runner (os/sh)
# the REPL had no stdin and this hung/banner-only.
proj_repl="$(mktemp -d)"; home_repl="$(mktemp -d)"
cat > "$proj_repl/lgx.edn" <<'EOF'
{}
EOF
set +e
out="$(cd "$proj_repl" && echo '(println (+ 1 2))' \
        | LGX_HOME="$home_repl" "$LGX" run 2>/dev/null)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "run repl: expected exit 0, got $rc (output: $out)"
pass "run repl: exits 0 on stdin EOF"
assert_contains "$out" "3" "run repl: evaluates piped expression"
rm -rf "$proj_repl" "$home_repl"

echo "==> Scenario 90: lgx nrepl --port starts nREPL on the given port"
# Port 56423: high and uncommon to dodge collisions. If something else holds
# it, lg degrades to "failed to run nREPL server on port" with exit 0 — the
# started-on-port assertion below is what catches that.
proj_nr="$(mktemp -d)"; home_nr="$(mktemp -d)"
cat > "$proj_nr/lgx.edn" <<'EOF'
{}
EOF
set +e
out="$(cd "$proj_nr" && echo '' \
        | LGX_HOME="$home_nr" "$LGX" nrepl --port 56423 2>/dev/null)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "nrepl: expected exit 0, got $rc (output: $out)"
pass "nrepl: exits 0 on stdin EOF"
assert_contains "$out" "nREPL server started on port 56423" \
    "nrepl: server starts on --port"
port_file="$(cat "$proj_nr/.nrepl-port" 2>/dev/null || true)"
assert_eq "$port_file" "56423" "nrepl: .nrepl-port records the port"
rm -f "$proj_nr/.nrepl-port"
rm -rf "$proj_nr" "$home_nr"

echo "==> Scenario 91: lgx nrepl without --port picks a random port"
proj_nr2="$(mktemp -d)"; home_nr2="$(mktemp -d)"
cat > "$proj_nr2/lgx.edn" <<'EOF'
{}
EOF
set +e
out="$(cd "$proj_nr2" && echo '' \
        | LGX_HOME="$home_nr2" "$LGX" nrepl 2>/dev/null)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "nrepl random: expected exit 0, got $rc (output: $out)"
pass "nrepl random: exits 0 on stdin EOF"
assert_contains "$out" "nREPL server started on port" \
    "nrepl random: server starts on a picked port"
rm -f "$proj_nr2/.nrepl-port"
rm -rf "$proj_nr2" "$home_nr2"

echo "==> Scenario 92: lgx nrepl --port rejects a non-integer"
proj_nr3="$(mktemp -d)"; home_nr3="$(mktemp -d)"
cat > "$proj_nr3/lgx.edn" <<'EOF'
{}
EOF
set +e
err="$(cd "$proj_nr3" && LGX_HOME="$home_nr3" "$LGX" nrepl --port abc 2>&1 >/dev/null)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "nrepl bad port: expected exit 1, got $rc (stderr: $err)"
pass "nrepl bad port: exits 1"
assert_contains "$err" "--port requires an integer" \
    "nrepl bad port: clear error on stderr"
rm -rf "$proj_nr3" "$home_nr3"

echo "==> Scenario 93: task with single-step map form :do runs through the bundled CLI"
proj_map="$(mktemp -d)"; home_map="$(mktemp -d)"
cat > "$proj_map/lgx.edn" <<'EOF'
{:tasks {hello {:do {:sh "echo hi from map do"}}}}
EOF
set +e
out="$(cd "$proj_map" && LGX_HOME="$home_map" "$LGX" hello 2>/dev/null)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "map-form :do: expected exit 0, got $rc (output: $out)"
pass "map-form :do: exits 0"
assert_eq "$out" "hi from map do" "map-form :do: task executes and prints correct output"
rm -rf "$proj_map" "$home_map"

# ---------------------------------------------------------------------------
echo "==> Scenario 94: invalid lgx.edn reports all errors, no stack trace"
proj_inv="$(mktemp -d)"; home_inv="$(mktemp -d)"
cat > "$proj_inv/lgx.edn" <<'EOF'
{:paths "src"
 :targets {:bin {}}
 :tasks {lint {:do [{:shh "x"}]}}}
EOF
set +e
out="$(cd "$proj_inv" && LGX_HOME="$home_inv" "$LGX" run 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "invalid config: expected non-zero exit"
pass "invalid config: exits non-zero"
assert_contains "$out" "lgx: invalid lgx.edn (3 errors)" \
    "invalid config: report header counts all errors"
assert_contains "$out" ':paths — must be a vector, got "src"' \
    "invalid config: :paths error line"
assert_contains "$out" ":targets :bin — missing required key :out" \
    "invalid config: :targets error line"
assert_contains "$out" ":tasks lint :do [0] — unknown key :shh (allowed: :sh, :run)" \
    "invalid config: step error line with path"
assert_not_contains "$out" "stack trace" \
    "invalid config: no stack trace leaks"

echo "==> Scenario 95: lgx help stays usable with an invalid lgx.edn"
set +e
out="$(cd "$proj_inv" && LGX_HOME="$home_inv" "$LGX" help 2>&1)"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "help on invalid config: expected exit 0, got $rc"
pass "help on invalid config: exits 0"
assert_contains "$out" "Built-in commands:" \
    "help on invalid config: built-in commands still listed"
assert_contains "$out" "(omitted — lgx.edn is invalid; run \`lgx install\` to see errors)" \
    "help on invalid config: tasks section shows warning"

echo "==> Scenario 96: unknown command with invalid lgx.edn shows the report"
set +e
out="$(cd "$proj_inv" && LGX_HOME="$home_inv" "$LGX" frobnicate 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "unknown cmd on invalid config: expected non-zero exit"
pass "unknown cmd on invalid config: exits non-zero"
assert_contains "$out" "lgx: invalid lgx.edn (3 errors)" \
    "unknown cmd on invalid config: validation report shown"
assert_not_contains "$out" "is not a lgx command" \
    "unknown cmd on invalid config: no misleading not-a-command error"
rm -rf "$proj_inv" "$home_inv"

echo "==> Scenario 97: unparseable lgx.edn reports a parse error"
proj_par="$(mktemp -d)"; home_par="$(mktemp -d)"
printf '{:paths [' > "$proj_par/lgx.edn"
set +e
out="$(cd "$proj_par" && LGX_HOME="$home_par" "$LGX" run 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "parse error: expected non-zero exit"
pass "parse error: exits non-zero"
assert_contains "$out" "lgx: invalid lgx.edn (1 error)" \
    "parse error: singular report header"
assert_contains "$out" "could not parse lgx.edn: " \
    "parse error: names the parse failure"
assert_not_contains "$out" "stack trace" \
    "parse error: no stack trace leaks"
rm -rf "$proj_par" "$home_par"

# ---------------------------------------------------------------------------
echo "==> Scenario 98: :dev context auto-applies to run"
if supports_source_paths; then
    proj_ac1="$(mktemp -d)"; home_ac1="$(mktemp -d)"
    mkdir -p "$proj_ac1/dev"
    cat > "$proj_ac1/dev/devtool.lg" <<'EOF'
(ns devtool)
(defn banner [] "AUTO-DEV-OK")
EOF
    cat > "$proj_ac1/m.lg" <<'EOF'
(ns m
  (:require [devtool]))
(println (devtool/banner))
EOF
    cat > "$proj_ac1/lgx.edn" <<'EOF'
{:main "m.lg"
 :contexts {:dev {:extra-paths ["dev"]}}}
EOF
    out="$(cd "$proj_ac1" && LGX_HOME="$home_ac1" "$LGX" run 2>&1)"
    assert_contains "$out" "AUTO-DEV-OK" \
        "auto :dev run: resolves ns from :dev context without --with"
    out="$(cd "$proj_ac1" && LGX_HOME="$home_ac1" "$LGX" --verbose run 2>&1)"
    assert_contains "$out" "+ auto context :dev" \
        "auto :dev run: --verbose names the auto context (stderr)"
    rm -rf "$proj_ac1" "$home_ac1"
else
    skip "auto :dev context requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 99: :test context auto-applies to test"
if supports_source_paths; then
    proj_ac2="$(mktemp -d)"; home_ac2="$(mktemp -d)"
    mkdir -p "$proj_ac2/test" "$proj_ac2/test-support"
    cat > "$proj_ac2/lgx.edn" <<'EOF'
{:contexts {:test {:extra-paths ["test-support"]}}}
EOF
    cat > "$proj_ac2/test-support/helper.lg" <<'EOF'
(ns helper)
(defn answer [] 42)
EOF
    cat > "$proj_ac2/test/x_test.lg" <<'EOF'
(ns x-test
  (:require [helper]
            [test :refer [deftest is]]))

(deftest helper-loads
  (is (= 42 (helper/answer))))
EOF
    set +e
    out="$(cd "$proj_ac2" && LGX_HOME="$home_ac2" "$LGX" test 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "auto :test: expected exit 0, got $rc (output: $out)"
    pass "auto :test: exits 0"
    assert_contains "$out" "0 failures" \
        "auto :test: helper ns from :test context resolves without --with"
    rm -rf "$proj_ac2" "$home_ac2"
else
    skip "auto :test context requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 100: --with stacks on top of the auto :dev context"
if supports_source_paths; then
    proj_ac3="$(mktemp -d)"; home_ac3="$(mktemp -d)"
    mkdir -p "$proj_ac3/dev" "$proj_ac3/extra"
    cat > "$proj_ac3/dev/devtool.lg" <<'EOF'
(ns devtool)
(defn banner [] "DEV-PART")
EOF
    cat > "$proj_ac3/extra/extratool.lg" <<'EOF'
(ns extratool)
(defn banner [] "EXTRA-PART")
EOF
    cat > "$proj_ac3/m.lg" <<'EOF'
(ns m
  (:require [devtool]
            [extratool]))
(println (devtool/banner) (extratool/banner))
EOF
    cat > "$proj_ac3/lgx.edn" <<'EOF'
{:main "m.lg"
 :contexts {:dev {:extra-paths ["dev"]}
            :extra {:extra-paths ["extra"]}}}
EOF
    out="$(cd "$proj_ac3" && LGX_HOME="$home_ac3" "$LGX" --with extra run 2>&1)"
    assert_contains "$out" "DEV-PART EXTRA-PART" \
        "--with over auto: both the auto :dev and --with dirs resolve"
    rm -rf "$proj_ac3" "$home_ac3"
else
    skip "--with over auto context requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 101: build ignores the :dev context"
if supports_source_paths; then
    home_ac4="$(mktemp -d)"
    bare_ac4="$home_ac4/_fixtures/test-repo.git"
    mkdir -p "$(dirname "$bare_ac4")"
    sha_ac4="$(make_bare_repo "$bare_ac4")"
    proj_ac4="$(mktemp -d)"
    cat > "$proj_ac4/main.lg" <<'EOF'
(when-not *compiling-aot*
  (println :built-ok))
EOF
    cat > "$proj_ac4/lgx.edn" <<EOF
{:main "main.lg"
 :targets {:bin {:out "bin/app"}}
 :contexts {:dev {:extra-deps {test/lib {:git/url "file://$bare_ac4"
                                         :git/sha "$sha_ac4"}}}}}
EOF
    set +e
    out="$(cd "$proj_ac4" && LGX_HOME="$home_ac4" "$LGX" build 2>&1)"; rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "build ignores :dev: expected exit 0, got $rc (output: $out)"
    pass "build ignores :dev: exits 0"
    assert_not_contains "$out" "installing" \
        "build ignores :dev: the :dev dep is not fetched"
    rm -rf "$proj_ac4" "$home_ac4"
else
    skip "build-ignores-:dev requires lg with -source-paths support"
fi

# ---------------------------------------------------------------------------
echo "==> Scenario 102: missing test/ errors before the :test context fetches deps"
home_ac5="$(mktemp -d)"
bare_ac5="$home_ac5/_fixtures/test-repo.git"
mkdir -p "$(dirname "$bare_ac5")"
sha_ac5="$(make_bare_repo "$bare_ac5")"
proj_ac5="$(mktemp -d)"
cat > "$proj_ac5/lgx.edn" <<EOF
{:contexts {:test {:extra-deps {test/lib {:git/url "file://$bare_ac5"
                                          :git/sha "$sha_ac5"}}}}}
EOF
set +e
out="$(cd "$proj_ac5" && LGX_HOME="$home_ac5" "$LGX" test 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "no test/ with :test context: expected non-zero exit"
pass "no test/ with :test context: exits non-zero"
assert_contains "$out" "lgx: no test/ directory in project" \
    "no test/ with :test context: deterministic error"
# The old flow fetched the dep but exited before print-installs!, so output
# alone can't prove the fix — assert the cache side effect is absent. A fetch
# would create gitlibs/<host>/<owner>/<repo>/<sha>/ under LGX_HOME.
fetched="$(find "$home_ac5/gitlibs" -type d -name "$sha_ac5" 2>/dev/null || true)"
[[ -z "$fetched" ]] \
    || fail "no test/ with :test context: dep was fetched into cache: $fetched"
pass "no test/ with :test context: the :test dep is not fetched into the cache"
rm -rf "$proj_ac5" "$home_ac5"

echo "==> Scenario 103: keyword task name reports the symbol migration hint"
proj_kw="$(mktemp -d)"; home_kw="$(mktemp -d)"
cat > "$proj_kw/lgx.edn" <<'EOF'
{:tasks {:ci {:do [{:sh "echo hi"}]}}}
EOF
set +e
out="$(cd "$proj_kw" && LGX_HOME="$home_kw" "$LGX" ci 2>&1)"; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "keyword task name: expected non-zero exit"
pass "keyword task name: exits non-zero"
assert_contains "$out" "task names are symbols; write ci instead of :ci" \
    "keyword task name: error states the symbol fix"
rm -rf "$proj_kw" "$home_kw"

echo "==> Scenario 104: namespaced task name runs and lists in help"
proj_ns="$(mktemp -d)"; home_ns="$(mktemp -d)"
cat > "$proj_ns/lgx.edn" <<'EOF'
{:tasks {foo/bar {:doc "Namespaced" :do [{:sh "echo hi from ns task"}]}}}
EOF
out="$(cd "$proj_ns" && LGX_HOME="$home_ns" "$LGX" foo/bar)"
assert_eq "$out" "hi from ns task" "namespaced task: runs by full name"
out="$(cd "$proj_ns" && LGX_HOME="$home_ns" "$LGX" help)"
assert_contains "$out" "lgx foo/bar" "namespaced task: help row keeps the namespace"
assert_contains "$out" "Namespaced" "namespaced task: help row keeps the doc"
rm -rf "$proj_ns" "$home_ns"

echo "==> Scenario 105: task :args bind and substitute into :sh and :run steps"
proj_args="$(mktemp -d)"; home_args="$(mktemp -d)"
cat > "$proj_args/lgx.edn" <<'EOF'
{:tasks
 {deploy {:doc "Deploy"
          :args [{:name :env :type [:enum "prod" "staging"]}
                 {:name :version :type :string :default "latest"}]
          :do [{:sh ["echo" "sh" :arg/env :arg/version]}
               {:run ["printer.lg" :arg/env]}]}}}
EOF
cat > "$proj_args/printer.lg" <<'EOF'
(when-not *compiling-aot*
  (println (str "run-env=" (last os/args))))
EOF
out="$(cd "$proj_args" && LGX_HOME="$home_args" "$LGX" deploy prod 1.2)"
assert_contains "$out" "sh prod 1.2" "task args: :sh substitutes both values"
assert_contains "$out" "run-env=prod" "task args: :run substitutes the arg"
out="$(cd "$proj_args" && LGX_HOME="$home_args" "$LGX" deploy staging)"
assert_contains "$out" "sh staging latest" \
    "task args: omitted optional fills its default"

echo "==> Scenario 106: bad arg value errors with the usage line"
set +e
out="$(cd "$proj_args" && LGX_HOME="$home_args" "$LGX" deploy qa 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "task args enum: expected exit 1, got $rc"
pass "task args enum: exits 1"
assert_contains "$out" 'must be one of: prod, staging, got "qa"' \
    "task args enum: error names the allowed values"
assert_contains "$out" "usage: lgx deploy <env> [version]" \
    "task args enum: usage line shows the signature"

echo "==> Scenario 107: args passed to a task without :args error"
proj_noargs="$(mktemp -d)"; home_noargs="$(mktemp -d)"
cat > "$proj_noargs/lgx.edn" <<'EOF'
{:tasks {fmt {:do [{:sh "echo hi"}]}}}
EOF
set +e
out="$(cd "$proj_noargs" && LGX_HOME="$home_noargs" "$LGX" fmt extra 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "argless task: expected exit 1, got $rc"
pass "argless task: exits 1 (args no longer silently dropped)"
assert_contains "$out" "task takes no arguments (got 1)" \
    "argless task: error states the arity"
assert_contains "$out" "usage: lgx fmt" "argless task: usage line printed"
rm -rf "$proj_noargs" "$home_noargs"

echo "==> Scenario 108: a hostile :sh arg value stays one quoted word"
proj_q="$(mktemp -d)"; home_q="$(mktemp -d)"
cat > "$proj_q/lgx.edn" <<'EOF'
{:tasks {greet {:args [{:name :msg}]
                :do [{:sh ["echo" :arg/msg]}]}}}
EOF
out="$(cd "$proj_q" && LGX_HOME="$home_q" "$LGX" greet 'a; echo pwned')"
assert_eq "$out" "a; echo pwned" \
    "task args quoting: value echoes literally, shell never interprets it"
rm -rf "$proj_q" "$home_q"

echo "==> Scenario 109: help shows the task arg signature"
out="$(cd "$proj_args" && LGX_HOME="$home_args" "$LGX" help)"
assert_contains "$out" "lgx deploy <env> [version]" \
    "task args help: signature rendered after the task name"
rm -rf "$proj_args" "$home_args"

echo "==> Scenario 110: required arg after a defaulted one is a config error"
proj_ta="$(mktemp -d)"; home_ta="$(mktemp -d)"
cat > "$proj_ta/lgx.edn" <<'EOF'
{:tasks {d {:args [{:name :version :default "latest"}
                   {:name :env}]
            :do [{:sh "echo hi"}]}}}
EOF
set +e
out="$(cd "$proj_ta" && LGX_HOME="$home_ta" "$LGX" install 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "trailing-optional: expected exit 1, got $rc"
pass "trailing-optional: exits 1"
assert_contains "$out" "required arg :env cannot follow an arg with :default" \
    "trailing-optional: error names the misordered arg"
rm -rf "$proj_ta" "$home_ta"

# ---------------------------------------------------------------------------
echo "==> Scenario 111: shell completion (completion + __complete)"
proj_comp="$(mktemp -d)"; home_comp="$(mktemp -d)"
cat > "$proj_comp/lgx.edn" <<'EOF'
{:tasks {fmt {:doc "Format" :do [{:sh "echo fmt"}]}
         deploy {:args [{:name :env :type [:enum "staging" "prod"]}]
                 :do [{:sh "echo {{env}}"}]}}}
EOF

out="$(cd "$proj_comp" && LGX_HOME="$home_comp" "$LGX" __complete "")"
assert_contains "$out" "run" "__complete: lists run"
assert_contains "$out" "build" "__complete: lists build"
assert_contains "$out" "fmt" "__complete: lists project task"
assert_not_contains "$out" "completion" "__complete: hidden command not offered"

out="$(cd "$proj_comp" && LGX_HOME="$home_comp" "$LGX" __complete fm)"
assert_eq "$out" "fmt" "__complete: prefix-filters to the task"

# A task arg's [:enum ...] values complete at that arg's position.
out="$(cd "$proj_comp" && LGX_HOME="$home_comp" "$LGX" __complete deploy "")"
assert_contains "$out" "staging" "__complete: offers enum value staging"
assert_contains "$out" "prod" "__complete: offers enum value prod"

out="$(cd "$proj_comp" && LGX_HOME="$home_comp" "$LGX" __complete deploy st)"
assert_eq "$out" "staging" "__complete: prefix-filters enum values"

# Outside any project: built-ins still complete, exit 0.
nowhere="$(mktemp -d)"
set +e
out="$(cd "$nowhere" && LGX_HOME="$home_comp" "$LGX" __complete "")"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "__complete outside project: expected exit 0, got $rc"
pass "__complete outside project: exits 0"
assert_contains "$out" "run" "__complete outside project: built-ins listed"
rm -rf "$nowhere"

# Invalid lgx.edn must not break completion: built-ins, exit 0.
echo '{:tasks' > "$proj_comp/lgx.edn"
set +e
out="$(cd "$proj_comp" && LGX_HOME="$home_comp" "$LGX" __complete "")"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "__complete invalid config: expected exit 0, got $rc"
pass "__complete invalid config: exits 0"
assert_contains "$out" "run" "__complete invalid config: built-ins listed"

out="$("$LGX" completion bash)"
assert_contains "$out" "__complete" "completion bash: script calls __complete"
set +e
out="$("$LGX" completion nope 2>&1)"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "completion nope: expected exit 1, got $rc"
assert_contains "$out" "lgx: unsupported shell: nope" "completion nope: clear error"

out="$("$LGX" help)"
assert_not_contains "$out" "completion" "help: completion stays hidden"

rm -rf "$proj_comp" "$home_comp"

# ---------------------------------------------------------------------------
echo "==> Scenario 112: {{name}} templates expand in task step strings"
proj_tpl="$(mktemp -d)"; home_tpl="$(mktemp -d)"
cat > "$proj_tpl/lgx.edn" <<'EOF'
{:tasks
 {deploy {:args [{:name :env}
                 {:name :version :default "latest"}]
          :do [{:sh "echo tag=v{{version}} env={{env}}"}
               {:sh ["echo" "item=v{{version}}" :arg/env]}
               {:sh "echo miss={{nope}}"}]}}}
EOF
out="$(cd "$proj_tpl" && LGX_HOME="$home_tpl" "$LGX" deploy prod 1.2)"
assert_contains "$out" "tag=v1.2 env=prod" \
    "template: string-form :sh expands tokens"
assert_contains "$out" "item=v1.2 prod" \
    "template: vector item expands alongside :arg keyword"
assert_contains "$out" "miss={{nope}}" \
    "template: unknown token passes through"
out="$(cd "$proj_tpl" && LGX_HOME="$home_tpl" "$LGX" deploy prod)"
assert_contains "$out" "tag=vlatest" "template: default fills the token"
rm -rf "$proj_tpl" "$home_tpl"

echo
echo "All $PASS_COUNT e2e assertions passed."
