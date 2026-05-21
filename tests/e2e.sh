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

# ---------------------------------------------------------------------------
echo "==> Scenario 13: project task with :sh step"
proj_t="$(mktemp -d)"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {:hello {:doc "Say hi"
          :do [{:sh "echo hi from task"}]}}}
EOF
home_t="$(mktemp -d)"
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" hello)"
assert_eq "$out" "hi from task" "task: single :sh step runs"

# ---------------------------------------------------------------------------
echo "==> Scenario 14: multi-step task runs steps sequentially"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {:ci {:doc "Run multiple steps"
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
 {:greet {:do [{:sh ["echo" "hello" "world"]}]}}}
EOF
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" greet)"
assert_eq "$out" "hello world" "task: vector :sh form joins items"

# ---------------------------------------------------------------------------
echo "==> Scenario 16: failing step stops chain with its exit code"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {:fail {:do [{:sh "echo before"}
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
 {:hello {:do [{:sh "echo hi"}]}}}
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
 {:fmt  {:doc "Format sources" :do [{:sh "echo fmt"}]}
  :test {:doc "Run tests"      :do [{:sh "echo test"}]}}}
EOF
out="$(cd "$proj_t" && LGX_HOME="$home_t" "$LGX" help)"
assert_contains "$out" "Project tasks:" "help: shows project tasks block"
assert_contains "$out" "fmt" "help: lists fmt task"
assert_contains "$out" "Format sources" "help: shows :doc string"
assert_contains "$out" "Run tests" "help: shows test :doc"

# ---------------------------------------------------------------------------
echo "==> Scenario 19: task name conflicting with built-in command is rejected"
cat > "$proj_t/lgx.edn" <<'EOF'
{:tasks
 {:run {:doc "Bad" :do [{:sh "echo nope"}]}}}
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
 {:say {:doc "Run via :run step"
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

echo
echo "All $PASS_COUNT e2e assertions passed."
