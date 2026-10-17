#!/usr/bin/env bash
# Smoke-test the app headless, in Wails' server mode: the frontend is
# served, the handlers answer, and redefining a handler over the in-app
# nREPL changes the running app with no restart.
#
#   bash smoke.sh
#
# Needs the Go toolchain and python3. LGX picks the lgx binary (default:
# lgx on PATH); NREPL_CLIENT the tiny nREPL client from the letgo-packages
# nrepl package's tests (default: a letgo-packages checkout beside lgx).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LGX="${LGX:-lgx}"
NREPL_CLIENT="${NREPL_CLIENT:-$HERE/../../../letgo-packages/nrepl/test/nrepl/client.py}"
[[ -f "$NREPL_CLIENT" ]] || { echo "smoke: no nREPL client at $NREPL_CLIENT (set NREPL_CLIENT)" >&2; exit 1; }

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
db="$(mktemp -d)/tasks.db"
log="$(mktemp)"
base="http://localhost:$port"
bridge="github.com/abogoyavlensky/letgo-packages/wails/shim.Bridge.Call"

cd "$HERE"
rm -f .nrepl-port
# Server mode: no window, an HTTP server instead. Both vars are needed (a
# few Wails packages gate on `linux && cgo` without a `!server` guard).
# `set -m` runs the background job in its own process group (setsid is not
# on macOS), so cleanup can stop lgx and the lg it starts together.
set -m
CGO_ENABLED=0 GOFLAGS=-tags=server WAILS_SERVER_PORT="$port" TASKS_DB="$db" \
    "$LGX" run >"$log" 2>&1 &
pid=$!
set +m
cleanup() {
    kill -- -"$pid" 2>/dev/null || true
    rm -rf "$(dirname "$db")" "$log" .nrepl-port
}
trap cleanup EXIT

fail() { echo "smoke: FAIL: $1" >&2; tail -20 "$log" >&2; exit 1; }

# The first run builds the runtime, which takes minutes.
for _ in $(seq 1 300); do
    curl -fs -o /dev/null "$base/" && [[ -s .nrepl-port ]] && break
    kill -0 "$pid" 2>/dev/null || fail "the app exited"
    sleep 2
done
curl -fs -o /dev/null "$base/" || fail "the app never answered on $base"

call() {
    local id="smoke-$RANDOM"
    curl -fs -X POST "$base/wails/runtime" \
        -H 'Content-Type: application/json' -H 'x-wails-client-id: smoke' \
        -d "{\"object\":0,\"method\":0,\"args\":{\"call-id\":\"$id\",\"methodName\":\"$bridge\",\"args\":[\"$1\",$2]}}"
}

[[ "$(curl -fs -o /dev/null -w '%{http_code}' "$base/")" == 200 ]] || fail "/ is not served"
[[ "$(curl -fs -o /dev/null -w '%{http_code}' "$base/app.js")" == 200 ]] || fail "/app.js is not served"

call add-task '["smoke"]' >/dev/null || fail "add-task failed"
[[ "$(call list-tasks '[]')" == *'"title":"smoke"'* ]] || fail "list-tasks does not show the new task"

# Redefine a handler in the running app. It is registered by var, so the
# next call runs the new definition.
python3 "$NREPL_CLIENT" "$(cat .nrepl-port)" \
    "(alter-var-root #'tasks.api/list-tasks (constantly (fn [] [{:title \"redefined\"}])))" \
    >/dev/null || fail "the nREPL eval failed"
[[ "$(call list-tasks '[]')" == *'"title":"redefined"'* ]] || fail "the redefinition did not take effect"

echo "smoke: ok"
