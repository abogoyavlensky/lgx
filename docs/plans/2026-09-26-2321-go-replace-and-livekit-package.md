# `:go/replace` and the `livekit` package Implementation Plan

**Status: completed, including the Task 11 release (lgx v0.4.1, livekit/shim/v0.1.0, livekit-v0.1.0).**

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Go coord carry module `replace` directives so lgx can link libraries that only compile against forks (`:go/replace`), then ship a `livekit` package in letgo-packages that embeds the LiveKit SFU in a let-go binary as an integrant component, with join-token minting and webhook verification.

**Tech Stack:** let-go (`.lg`), Go 1.26+ toolchain, livekit-server v1.13.7, integrant, bash e2e harness (`tests/e2e.sh`).

**Repos:** part 1 is in this repo (`/home/agent/Projects/lgx`). Part 2 is in `/home/agent/Projects/letgo-packages`. Part 2 needs part 1 built as `bin/lgx`.

---

## Design

### Why

livekit-server's `go.mod` replaces three pion modules (`webrtc/v4`, `dtls/v3`, `ice/v4`) with LiveKit's forks. Without those lines it does not compile (verified: `se.EnableSped undefined`). Go honours `replace` only in the **main** module, which is the runtime module lgx generates in `$LGX_HOME/runtimes/<hash>/src/go.mod`. lgx renders that file itself and offers no way to add a replace, so no wrapper of livekit-server can build today. This is a general gap: any Go library that depends on a fork is unreachable.

Everything else needed for the package was verified in a throwaway Go module on 2026-09-26: the server starts from a config string with a `nil` CLI command, its config parser is yaml.v3 and accepts a JSON document, `prometheus.Init` is idempotent (safe for integrant halt/init cycles), it builds under `CGO_ENABLED=0` on linux/amd64 (71 MB, 7s warm), and the Twirp JSON API answers a plain HTTP POST carrying an HS256 JWT.

### Part 1: `:go/replace` in lgx

**Shape.** A new key on an external Go coord, next to `:go/version` or `:go/local`:

```clojure
github.com/abogoyavlensky/letgo-packages/livekit/shim
{:go/version "v0.1.0"
 :go/replace {"github.com/pion/webrtc/v4" "github.com/livekit/webrtc-pion/v4@v4.2.18-warp.1"
              "github.com/pion/dtls/v3"   "github.com/livekit/dtls/v3@v3.1.5-warp.1"
              "github.com/pion/ice/v4"    "github.com/livekit/ice/v4@v4.4.0-warp.2"}}
```

The value is a map of module path to `<module>@<version>`, the same form `go mod edit -replace old=new@v` takes. Each entry renders as `replace old => new v` in the generated go.mod. Only module-to-module replacement is supported: a directory replacement is what `:go/local` already is.

**Why per-coord and not top-level.** The coord that needs the forks is the one that must carry them, and a consumer must inherit them without knowing: a wrapper package's `lgx.edn` is what declares the shim coord, and Go coords already flow up from a dep's `lgx.edn` through `split-go-coords`. A top-level key would need a new propagation channel, because lgx ignores a dep's top-level keys. Per-coord rides the existing one unchanged.

**Validation** (`config/coord-errors`, per-coord):
- allowed only with `:go/version` or `:go/local` (a stdlib coord already fails the "`:go/interop` only" rule);
- a non-empty map; every key a non-blank string whose first path segment has a dot (a module path, not stdlib); every value a non-blank string of the form `<path>@<version>` with both sides non-blank.

Error messages follow the existing `at-key` style and the "allowed: ..." list in the unknown-key message gains `:go/replace`.

**Hashing.** `coord-line` appends a fifth slot `replace:old=>new@v,old2=>...` (entries sorted by old path) **only when the coord has replaces**. Appending an empty slot to every line would change every existing cache key and force a rebuild for all users; keeping the old four-slot form for coords without replaces leaves existing runtimes valid.

**Merging across the tree.** Replaces are global to the go.mod, so two coords that replace the same module with different targets cannot both be honoured. A pure `gobuild/merged-replaces` takes the `go-pairs` and a set of *reserved* module paths, and returns `{:replaces {old "new@v"} :conflicts [{:module old :a [lib target] :b [lib target]}] :reserved [{:module old :lib lib}]}`. Identical entries from two coords dedupe silently. `ensure-runtime!` calls it first, before `runtime-paths` (which may run `go list` for a mutable let-go ref) and before any file is written, and `die!`s on any conflict, naming the module and both libs; the merged map is then passed down to `write-module!`. The reserved set's local module paths come from `module-path-at`, a file read that `ensure-runtime!` can do up front. Go's MVS cannot settle this, unlike version skew, so it is an error rather than a warning.

The reserved set closes the two collisions the rendered file already creates its own replace lines for: `github.com/nooga/let-go` (its pin is `:lg-version`, and under `LGX_LETGO_REPLACE` a second directive for it would make `go` reject the file) and every `:go/local` module path in the tree (already replaced by a directory). A `:go/replace` naming either is an error: `:go/replace for <module> from <lib> collides with <the :lg-version pin | the :go/local coord <lib2>>`. Go refuses duplicate replace directives outright, so this only turns a toolchain error into a config error, but it names the cause.

**Rendering.** `render-go-mod` gains a `replaces` argument (the merged map) and emits one `replace` line per entry after the local-module replaces, sorted by old path so the file is deterministic. Ordering with the build steps already works: `write-module!` writes go.mod before `go get` runs, so the replaces are in force when Go resolves the coord (this is the order the probe used).

**`lgx info`.** `go-dep-label` stays one line; each replace is printed as an `info-continuation` line `replace <old> => <new@v>` under its coord so a user can see what the runtime will link.

### Part 2: the `livekit` package

Layout follows `lgx-go-wrappers.md` and mirrors `wails/`:

```
livekit/
├── README.md
├── lgx.edn                :paths ["src"], the shim coord with :go/replace, integrant deps
├── shim/
│   ├── go.mod             module github.com/abogoyavlensky/letgo-packages/livekit/shim
│   └── shim.go            server lifecycle, token, webhook verify; registers ns livekit.shim
├── src/livekit/
│   ├── core.lg            start!, stop!, running?, http-port, token, verify-webhook
│   └── integrant.lg       :livekit/server init-key / halt-key!
├── test/livekit/core_test.lg
└── example/
    ├── lgx.edn            {:local/root ".."}
    └── main.lg
```

**Shape B, nothing generated.** Every server entry point takes a struct (`*config.Config`) or wires through `google/wire`; the token API takes `*auth.VideoGrant`. Nothing here is reachable through `:go/interop`.

**Shim API** (all registered in `init()` on namespace `livekit.shim`, exactly as `wails/shim/shim.go` does):

| Go | Does |
|---|---|
| `Start(conf vm.Value) (*Server, error)` | let-go map → `ToGo` → `json.Marshal` → `config.NewConfig(json, true, nil, nil)`; `InitLoggerFromConfig`; `ValidateKeys`; `LoadTURNSecrets`; `routing.NewLocalNode`; `prometheus.Init`; `service.InitializeServer`; `go srv.Start()` with its error sent on a channel; poll up to 15s for `IsRunning()` or the error; return the handle or the error. See "Startup ownership" below |
| `Stop(s *Server, force bool)` | `srv.Stop(force)` |
| `Running(s *Server) bool` | `srv.IsRunning()` |
| `HTTPPort(s *Server) int` | `srv.HTTPPort()` |
| `Token(apiKey, secret string, opts vm.Value) (string, error)` | `auth.NewAccessToken` + `VideoGrant` from the option map |
| `VerifyWebhook(authHeader, body, apiKey, secret string) bool` | the check in `protocol/webhook/verifier.go` plus an issuer check: `auth.ParseAPIToken`, reject unless its `APIKey()` equals `apiKey` (upstream gets the secret from a provider keyed by the token's issuer, so the key match is implicit there and must be explicit here), `Verify(secret)`, then constant-time compare of the `sha256` claim to the base64 standard-encoded SHA-256 of the body. Returns plain `false` on any failure: a rejected webhook is not actionable beyond rejecting it, and a bool keeps the veneer free of try/catch |

`Server` is a small struct holding the `*service.LivekitServer` and the start-error channel; let-go holds it as an opaque boxed value, as it holds `*application.App` for wails.

**Startup ownership.** When `Start` returns an error, the caller never receives a handle, so the shim must own whatever the start goroutine leaves behind. Two cases:
- `srv.Start()` returned an error (port in use, bad config). Upstream `Start` (`pkg/service/server.go`) starts the router and IO service and opens its TCP listeners one bind address at a time before it flips `running`, and a later failure returns without closing what it already opened; `Stop` returns early while `running` is false, so the shim cannot reclaim that state either. The shim returns the error as is and treats a failed start as **fatal for the process**: the README says to restart rather than retry, and the integrant component lets the exception propagate so `ig/init` halts the system. Upstream's own CLI does the same (`os.Exit` on a start error).
- The 15s poll timed out with the goroutine still starting: `Start` returns a timeout error **and** leaves a reaper goroutine that keeps polling `IsRunning()` and calls `srv.Stop(true)` the moment it flips, or exits when the start goroutine reports an error. Without it, a server that finishes starting a moment later would run with no handle.

The test for this is the occupied-port case with a single bind address: start on 7890, start again on 7890, assert the second `start!` throws and the first is still `running?`, stop the first, then a fresh `start!` on 7890 succeeds. The retry assertion holds only because with one bind address the very first `net.Listen` is what fails, so nothing was opened; the test comment says so, and it must not be generalised into a retry guarantee. `ToGo`/`asMap` are copied from the wails shim: the shims are independent Go modules, so a shared helper would mean a third module and a release ordering nobody needs yet.

Config keys are LiveKit's YAML keys as strings or keywords (`ToGo` lowers keywords to their names), so `{:port 7880 :keys {"devkey" "..."} :rtc {:tcp_port 7881}}` works and the README says so.

**Token options** (let-go map, all optional except identity): `identity`, `name`, `room`, `ttl-seconds` (default 6h), and the grant booleans `room-join`, `room-create`, `room-list`, `room-admin`, `can-publish`, `can-subscribe`, `can-publish-data`. Unknown keys are ignored.

**Veneer** (`livekit.core`): `start!`, `stop!` (`[server]` and `[server force?]`), `running?`, `http-port`, `token`, `verify-webhook`. Docstrings carry the option keys.

**Integrant** (`livekit.integrant`): requires `integrant.core` and `livekit.core`; `(defmethod ig/init-key :livekit/server [_ {:keys [config]}] (lk/start! config))` and `halt-key!` stops with `force? false`. The package `lgx.edn` lists integrant and weavejester/dependency with the same coords `examples/web-app/lgx.edn` uses; a consumer that does not use integrant pays a small pure-Clojure fetch and never loads the namespace.

**Test and example assert, not print.** The test starts a server on port 7890 with a 32+ character secret, mints a `room-list` token, POSTs `{}` to `/twirp/livekit.RoomService/ListRooms` through let-go's `http/post` with an `Authorization: Bearer` header, asserts status 200 and a body containing `"rooms"`, then halts and asserts `running?` is false. The example does the same through the integrant system and additionally creates a room with a `room-create` token, throwing on any mismatch. Both run over the shim as `{:go/local "shim"}` until the release flips it.

**AOT.** The example guards its entry with `(when-not *compiling-aot* (-main))` and constructs nothing at top level, so `lgx build` does not start an SFU while bundling.

**Pins.** livekit-server `v1.13.7`; replaces copied from that tag's `go.mod`: `webrtc-pion/v4@v4.2.18-warp.1`, `dtls/v3@v3.1.5-warp.1`, `ice/v4@v4.4.0-warp.2`. The README states the rule: when bumping livekit-server, copy the replace block from the new tag's `go.mod` into `lgx.edn`. The shim `go.mod` keeps the `v0.0.0` let-go require like the other shims.

**Known limits, documented in the README:** a failed `start!` is fatal for the process (see "Startup ownership"); linux/amd64 and native macOS builds work; `lgx build --target darwin/*` from Linux fails because `hwstats` needs cgo on darwin; the runtime is ~95 MB; WebRTC still needs a public IP with the UDP range open or TURN enabled, embedded or not.

### Release ordering

Part 2's CI cannot pass on a released lgx until one carries `:go/replace`: `.mise.toml` in letgo-packages pins lgx 0.3.1. Locally, run everything with `LGX=/home/agent/Projects/lgx/bin/lgx`. The final task releases lgx and then the package, and is the user's call to trigger.

## File Structure

**lgx (modify):**
- `lgx/config.lg` — `go-key-set` gains `:go/replace`; new `go-replace-errors` used by `coord-errors`.
- `lgx/gobuild.lg` — `coord-line`, new `merged-replaces`, `render-go-mod` (new arg), `write-module!`/`ensure-runtime!` wiring.
- `lgx.lg` — `lgx info` replace continuation lines.
- `test/lgx/config_test.lg`, `test/lgx/gobuild_test.lg` — unit tests.
- `tests/e2e.sh` — validation scenario and an `info` scenario, neither invoking Go.
- `README.md`, `docs/knowledge-base/lgx-go-runtimes.md`, `docs/knowledge-base/lgx-go-wrappers.md`, `docs/ARCHITECTURE.md` — docs.

**letgo-packages (create):** the `livekit/` tree above. **Modify:** `README.md` (package list, releasing note), `.github/workflows/test.yml` (shim override for `livekit/shim/`).

---

### Task 1: Accept and validate `:go/replace` in config

**Files:**
- Modify: `lgx/config.lg`
- Test: `test/lgx/config_test.lg`

- [x] **Step 1: Write the failing tests** next to `load-rejects-unknown-go-key`. Cases: accepts `:go/replace` with `:go/version`; accepts it with `:go/local`; rejects it on a stdlib coord (`database/sql`); rejects an empty map; rejects a non-map; rejects a value without `@` (message names the key and the expected `<module>@<version>` form); rejects a key whose first segment has no dot; rejects it as the only `:go/*` key (existing "must specify :go/version" error still fires). Also update the unknown-key test's expected "allowed:" list.
- [x] **Step 2: Run them to see them fail.** Run: `bin/lgx test` from the repo root (build first with `make build` if `bin/lgx` is stale). Expected: the new tests FAIL, everything else passes.
- [x] **Step 3: Implement.** Add `:go/replace` to `go-key-set` (not to `go-value-keys`, whose entries are asserted non-blank strings). Add a private `go-replace-errors` returning `at-key`-style errors for the map shape, and call it from the `has-go?` branch of `coord-errors`. Extend the unknown-key message to `(allowed: :go/version, :go/interop, :go/local, :go/replace)`. Keep `go-coord?` as is: it keys off `go-key-set`, so a coord with only `:go/replace` is still a Go coord and fails the existing external-coord rule.
- [x] **Step 4: Run tests.** Run: `bin/lgx test`. Expected: PASS.
- [x] **Step 5: Commit.** `git commit -m "config: accept :go/replace on external Go coords"`

### Task 2: Hash, merge and render replaces

**Files:**
- Modify: `lgx/gobuild.lg`
- Test: `test/lgx/gobuild_test.lg`

- [x] **Step 1: Write the failing tests.**
  - `runtime-hash` changes when a replace is added, changes when a replace target changes, and is unchanged for a coord without replaces compared to the hash computed before this change (assert the literal 16-hex value the current code returns for `[sqlite]` and `"1.11.1"`, captured before editing).
  - `merged-replaces`: dedupes identical entries from two coords; reports a conflict with both libs when targets differ; returns an empty map for coords without replaces; reports `:reserved` when a replace names `github.com/nooga/let-go` or a module in the reserved set (the `:go/local` module paths).
  - `render-go-mod`: emits `replace github.com/pion/webrtc/v4 => github.com/livekit/webrtc-pion/v4 v4.2.18-warp.1` for a merged map, after the local-module replaces, sorted by old path; emits nothing extra for an empty map. Update existing `render-go-mod` calls for the new arity.
- [x] **Step 2: Run them to see them fail.** Run: `bin/lgx test`. Expected: the new tests FAIL.
- [x] **Step 3: Implement.** `coord-line` appends the replace slot only when `(:go/replace c)` is non-empty. `merged-replaces` is pure, in the "Rendering the generated module" section. `render-go-mod` takes `[go-pairs replace-path local-modules replaces]`; split each value on the last `@` when rendering. Thread the new arity through in the same commit: `write-module!` gains a `replaces` parameter, and `ensure-runtime!` computes the local module paths (`module-path-at`) and `(:replaces (merged-replaces go-pairs reserved))` before calling `runtime-paths`, so the tree builds and runs at this commit; the conflict `die!`s land in Task 3.
- [x] **Step 4: Run tests.** Run: `bin/lgx test`. Expected: PASS.
- [x] **Step 5: Commit.** `git commit -m "gobuild: hash, merge and render :go/replace directives"`
> Deviation: `ensure-runtime!` reads the `:go/local` module paths once and passes them to `write-module!` (which gained `locals` as well as `replaces`) instead of `write-module!` reading them again. `merged-replaces` takes `reserved` as a map `{module-path owning-lib}`, and each `:reserved` entry carries `:by` (the owning lib, nil for let-go) so the error message can name the colliding `:go/local` coord.

### Task 3: Wire replaces into the runtime build and prove it against livekit-server

**Files:**
- Modify: `lgx/gobuild.lg` (`write-module!`, `ensure-runtime!`)

- [x] **Step 1: Wire.** In `ensure-runtime!`, right after `merged-replaces` and before `runtime-paths`, `die!` on `:conflicts` with `:go/replace conflict for <module>: <lib-a> wants <target-a>, <lib-b> wants <target-b>`, and on `:reserved` with the collision message from the design. Both fire before any file is written and before Go is invoked, including the `go list` a mutable `:lg-version` triggers.
- [x] **Step 2: Build lgx.** Run: `make build`. Expected: `bin/lgx` rebuilt without errors.
- [x] **Step 3: Prove it end to end** with a throwaway project and cache. Create `/tmp/lgx-replace-probe/lgx.edn`:
  ```clojure
  {:paths ["."] :main "main.lg" :lg-runtime :built :lg-version "1.13.0"
   :deps {github.com/livekit/livekit-server/pkg/service
          {:go/version "v1.13.7"
           :go/replace {"github.com/pion/webrtc/v4" "github.com/livekit/webrtc-pion/v4@v4.2.18-warp.1"
                        "github.com/pion/dtls/v3" "github.com/livekit/dtls/v3@v3.1.5-warp.1"
                        "github.com/pion/ice/v4" "github.com/livekit/ice/v4@v4.4.0-warp.2"}}}}
  ```
  and `main.lg` containing `(println :linked)`. Run: `cd /tmp/lgx-replace-probe && LGX_HOME=/tmp/lgx-replace-home /home/agent/Projects/lgx/bin/lgx run --verbose`. Expected: the runtime builds (first build takes about a minute, more on a cold module cache), the generated `go.mod` under `/tmp/lgx-replace-home/runtimes/*/src/` contains the three replace lines, and the output ends with `:linked`. Then remove the replace map from the coord, use a fresh `LGX_HOME`, and confirm the build fails with `EnableSped undefined`, which proves the replaces are load-bearing.
- [x] **Step 4: Prove the conflict paths.** Add a second coord with the same webrtc key and a different target; `lgx run` must exit non-zero with the conflict message before invoking Go. Then replace that with a `:go/replace` keyed on `github.com/nooga/let-go`; expect the reserved-module message.
- [x] **Step 5: Commit.** `git commit -m "gobuild: render :go/replace into the runtime module"`
> Deviation: `--verbose` is a global lgx option, so the probe ran as `lgx --verbose run` (as written, `lgx run --verbose` forwards the flag to `lg`, which exits 2 after the runtime build). The conflict and reserved messages are rendered by a new pure `gobuild/merged-replace-errors`, which has its own unit tests, and all of them are reported in one `die!`. Probe results: runtime built in 1m12s (51 MB) with the three replace lines and printed `:linked`; without them, `se.EnableSped undefined`; both error paths exit 1 with no `go` invocation and no runtimes dir, including under a mutable `:lg-version "main"`.

### Task 4: `lgx info` and e2e coverage

**Files:**
- Modify: `lgx.lg`, `tests/e2e.sh`

- [x] **Step 1: info.** In the `deps` block of the info renderer, after each coord's label, add `info-continuation` lines `replace <old> => <new@v>` for that coord's replaces, sorted.
- [x] **Step 2: e2e scenarios** after the `:lg-runtime` validation block (around line 3119), in the same no-toolchain style:
  - a project whose coord has `:go/replace {"github.com/pion/webrtc/v4" "nope"}` → `lgx info` exits non-zero and the output contains `<module>@<version>`;
  - a project with a valid replace and `:lg-runtime :built` → `lgx info` exits zero and the output contains `replace github.com/pion/webrtc/v4 => github.com/livekit/webrtc-pion/v4@v4.2.18-warp.1` (info under `:built` reports the cache path without building).
- [x] **Step 3: Run the suites.** Run: `bash tests/run.sh`. Expected: unit tests PASS and e2e reports the new assertions passing with no failures.
- [x] **Step 4: Commit.** `git commit -m "info, e2e: show and check :go/replace"`
> Deviation: the replace lines are indented two extra spaces under their coord's label so they read as belonging to it. The e2e scenarios are numbered 160 and 161 (the next free numbers) and sit after Scenario 126, the `lgx info` block.

### Task 5: Documentation

**Files:**
- Modify: `README.md`, `docs/knowledge-base/lgx-go-runtimes.md`, `docs/knowledge-base/lgx-go-wrappers.md`, `docs/ARCHITECTURE.md`

- [x] **Step 1: README.** Add a `:go/replace` row to the Go deps rules table and one sentence under it: what it is for, the `<module>@<version>` form, and that it propagates from a dep's `lgx.edn` like any Go coord.
- [x] **Step 2: lgx-go-runtimes.md.** "What the hash covers": the replace slot, and that coords without replaces keep their old keys. "The build steps": replaces are in the rendered go.mod before `go get`. Add a gotcha: replaces are global, conflicts across the tree are an error, and a dep's own `go.mod` replaces are ignored by Go, which is why the key exists.
- [x] **Step 3: lgx-go-wrappers.md.** Under Shape B add a paragraph: a library that compiles only against forks needs `:go/replace` on its shim coord, copied from its `go.mod`; livekit is the worked case. Add `livekit/shim/shim.go` to the "Verify against" footer.
- [x] **Step 4: ARCHITECTURE.md.** In "Go deps", one paragraph on `:go/replace`: validated in `coord-errors`, merged by `gobuild/merged-replaces`, rendered by `render-go-mod`.
- [x] **Step 5: Commit.** `git commit -m "docs: :go/replace"`
> Deviation: the wrappers doc footer also names `livekit/lgx.edn` (where the replace block lives), and the ARCHITECTURE `lgx info` paragraph mentions the replace lines. Plan-doc progress is committed along with the docs.

### Task 6: livekit shim, server lifecycle

**Files (letgo-packages):**
- Create: `livekit/shim/go.mod`, `livekit/shim/shim.go`, `livekit/lgx.edn`

- [x] **Step 1: go.mod.** Module `github.com/abogoyavlensky/letgo-packages/livekit/shim`, `go 1.26`, requires `github.com/nooga/let-go v0.0.0` and `github.com/livekit/livekit-server v1.13.7` (plus `github.com/livekit/protocol v1.51.1-0.20260905133529-a4f4b5c0c23f`, the version livekit-server v1.13.7 requires, for the token API; `go mod tidy` will settle it either way). Copy the three replace lines from livekit-server v1.13.7's `go.mod` into it too, so `go vet` in a `go.work` can work later; they are inert for consumers, which is what `:go/replace` is for.
- [x] **Step 2: shim.go.** A header comment in the wails style explaining why nothing is generated. Implement `Server`, `Start`, `Stop`, `Running`, `HTTPPort` and the `ToGo`/`asMap` helpers per the design, and the `init()` registering `livekit.shim`. `Start` returns the error from the goroutine if `srv.Start()` fails before `IsRunning()` turns true, and a timeout error after 15s.
- [x] **Step 3: lgx.edn** with `:paths ["src"]`, `:lg-runtime :built`, `:lg-version "1.13.0"`, the shim coord as `{:go/local "shim" :go/replace {...}}` (the three forks), and the integrant plus dependency coords copied from `examples/web-app/lgx.edn`. A comment says the coord flips to `:go/version` at release, as in `wails/lgx.edn`.
- [x] **Step 4: Smoke it from the REPL-less path.** Create `livekit/example/lgx.edn` now (as in `wails/example/lgx.edn`: `{:local/root ".."}`, `:lg-runtime :built`, `:lg-version "1.13.0"`, `:targets {:bin {:out "bin/app"}}`) and a temporary `livekit/example/main.lg` that requires `livekit.shim` and calls `Start` with `{:port 7890 :bind_addresses ["127.0.0.1"] :rtc {:tcp_port 7891 :port_range_start 50000 :port_range_end 50100 :use_external_ip false} :keys {"devkey" "secretsecretsecretsecretsecretsecret"} :logging {:level "warn"}}`, prints `Running`, and `Stop`s. Run: `cd livekit/example && LGX_HOME=/tmp/lgx-livekit-home /home/agent/Projects/lgx/bin/lgx run`. Expected: `true` printed, clean exit. The first run surfaces any MVS conflict between let-go's and livekit's dependency trees; fix in the shim `go.mod` if one appears.
- [x] **Step 5: Commit.** `git commit -m "livekit: shim with the server lifecycle"`
> Deviation: Part 2 is committed on a new `livekit-package` branch in letgo-packages rather than on `master`. The shim `go.mod` lists only the three direct requires (no go.sum, like the other shims); the runtime's `go mod tidy` settles the rest and no MVS conflict surfaced. Smoke run: `true`, exit 0, 14.6s on a warm module cache.
> Review fixup (`livekit: keep empty config maps as objects`): codex found that `ToGo`, copied from wails, lowers an empty let-go map to `[]`, which breaks `:logging {}`. The livekit copy now recognises maps by their `MapType`/`SortedMapType` tag. The wails copy has the same latent bug but was left alone (out of scope).

### Task 7: Veneer, test and example

**Files (letgo-packages):**
- Create: `livekit/src/livekit/core.lg`, `livekit/test/livekit/core_test.lg`, `livekit/example/lgx.edn`, `livekit/example/main.lg`

- [x] **Step 1: core.lg** with `start!`, `stop!`, `running?`, `http-port`, docstrings listing the config keys that matter (`port`, `bind_addresses`, `rtc`, `keys`, `logging`) and pointing at LiveKit's config reference for the rest.
- [x] **Step 2: Write the test** per the design (start on 7890, `running?` true, stop, `running?` false), plus the occupied-port case from "Startup ownership". Token minting arrives in Task 8, so this first version asserts only the lifecycle and a 200 from `GET /` through `http/get`.
- [x] **Step 3: Run it.** Run: `cd livekit && LGX_HOME=/tmp/lgx-livekit-home /home/agent/Projects/lgx/bin/lgx test`. Expected: PASS.
- [x] **Step 4: Example.** `example/lgx.edn` exists from Task 6. Rewrite `main.lg` so it starts the server through `livekit.core`, asserts `running?`, stops, and is guarded with `*compiling-aot*`. Run: `cd livekit/example && LGX_HOME=/tmp/lgx-livekit-home /home/agent/Projects/lgx/bin/lgx run`. Expected: assertions pass, exit 0.
- [x] **Step 5: Commit.** `git commit -m "livekit: core veneer, test and example"`
> Deviation: in the occupied-port test the second server moves its RTC TCP port (7892). Observed: an identical config collides first on `listen tcp :7891` inside `InitializeServer` (mediatransportutil binds the RTC listeners while wiring), not on the HTTP port, so the plan's literal case never reaches the single-bind-address `net.Listen` the test comment is about. A fresh start after that RTC collision also succeeded. The example guards `-main` with `*compiling-aot*` from this task on.

### Task 8: Tokens and webhook verification

**Files (letgo-packages):**
- Modify: `livekit/shim/shim.go`, `livekit/src/livekit/core.lg`, `livekit/test/livekit/core_test.lg`, `livekit/example/main.lg`

- [x] **Step 1: Write the failing test.** Mint a `room-list` token for identity `admin`, POST `{}` to `http://127.0.0.1:7890/twirp/livekit.RoomService/ListRooms` with `(http/post url "{}" {:headers {"Authorization" (str "Bearer " tok)} :content-type "application/json"})` (let-go's `http/post` is `[url body opts]`; the response map has `:status`, `:headers`, `:body`), assert `:status` 200 and `"rooms"` in `:body`. Assert a token with no grants gets 401 on the same call. For webhooks: build a body string, sign it the way LiveKit does (a token whose `sha256` claim is the base64 digest of the body, minted through `Token` with a `sha256` option and `SetSha256`), and assert `verify-webhook` returns true for the genuine pair and false for each of: a tampered body, a token minted under a different API key, a token minted with a different secret, and an expired token. `Token` cannot mint an expired one: upstream `ToJWT` substitutes its default lifetime for any nonpositive duration, and `Verify` allows one minute of leeway. So the expired case is a **static fixture**: during this task, generate one JWT with a throwaway Go program for the test key, secret and body's `sha256` claim with `exp` set to 2020-09-13 (`1600000000`), and paste it into the test with a comment giving the inputs. HS256 over fixed inputs is deterministic, so it stays reproducible.
- [x] **Step 2: Run it to see it fail.** Run: `cd livekit && LGX_HOME=/tmp/lgx-livekit-home /home/agent/Projects/lgx/bin/lgx test`. Expected: FAIL on the missing fns.
- [x] **Step 3: Implement** `Token` and `VerifyWebhook` in the shim per the design (a `sha256` option on `Token` sets the claim, which is also what the webhook test needs), register them, and add `token` and `verify-webhook` to `core.lg` with the option keys in the docstring.
- [x] **Step 4: Run tests.** Expected: PASS.
- [x] **Step 5: Extend the example** to mint a `room-create` token, create a room named `demo`, and assert the response body contains `"demo"`. Run it. Expected: exit 0.
- [x] **Step 6: Commit.** `git commit -m "livekit: join tokens and webhook verification"`
> Deviation: `:identity` is optional in `token` rather than required. Webhook-style tokens have none, upstream `ToJWT` does not require one, and the docstring says joining needs one. The test pins the body's base64 SHA-256 as a constant because let-go's `hash/sha256` returns hex. `verify-webhook` tolerates a leading `Bearer ` on the header. The expired fixture was minted with golang-jwt v5 over fixed `iat`/`nbf`/`exp`/`sha256` claims, and two runs produced the same token.

### Task 9: Integrant component

**Files (letgo-packages):**
- Create: `livekit/src/livekit/integrant.lg`
- Modify: `livekit/example/main.lg`, `livekit/test/livekit/core_test.lg`

- [x] **Step 1: integrant.lg** per the design. The component's value is the server handle, so other components can `ig/ref` it and call `http-port`.
- [x] **Step 2: Test.** Add a test that runs `ig/init` on `{:livekit/server {:config <the test config>}}`, asserts `running?` on the value, `ig/halt!`, asserts not running, then inits again to confirm a second cycle works in one process.
- [x] **Step 3: Example** switches to the integrant system: a config map with `:livekit/server` and a stand-in `:app/handler` that refs it, then the same assertions. Run test and example. Expected: PASS, exit 0.
- [x] **Step 4: Commit.** `git commit -m "livekit: integrant component"`

### Task 10: README, CI and the build path

**Files (letgo-packages):**
- Create: `livekit/README.md`
- Modify: `README.md`, `.github/workflows/test.yml`

- [x] **Step 1: livekit/README.md** in the wails README's shape: what it is, status, requirements (lgx with `:go/replace`, Go on PATH, no cgo), use (the `lgx.edn` snippet for a consumer with `:git/tag "livekit-v0.1.0"` and `:deps/root "livekit"`), the API, the config-map note, the integrant snippet, the pin-bumping rule for replaces, and the known limits from the design.
- [x] **Step 2: Root README.** Add `livekit` to the package list and to the "Only `sql` and `wails` have a shim" sentence in Releasing.
- [x] **Step 3: CI.** In `test.yml`, next to the `sql/shim/` override, add the same `sed` for `livekit/shim/` flipping `livekit/shim {:go/version ...}` to `{:go/local "shim"}`. Note in a comment that the `:go/replace` map on that coord must survive the substitution (match only the version key).
- [x] **Step 4: Build path.** Run: `cd livekit/example && LGX_HOME=/tmp/lgx-livekit-home /home/agent/Projects/lgx/bin/lgx build && ./bin/app`. Expected: the bundle step does not start a server (no LiveKit log lines during `build`), the binary runs the example to exit 0. Record the binary size in the README status line.
- [x] **Step 5: Regression check on the other packages.** Run: `cd sqlite/example && lgx run` and `cd sql && lgx test` with the same `bin/lgx`. Expected: unchanged, PASS.
- [x] **Step 6: Commit.** `git commit -m "livekit: README, CI override, verified build path"`
> Deviation: the CI override is a single `sed` that rewrites only the `{:go/version "..."` opening (the file's one `:go/version`), so the `:go/replace` map survives. It was checked by round-tripping a simulated release `lgx.edn`. Added `livekit/example/.gitignore` (`bin/`), as wails has. The root README's Releasing step 3 now says to keep other coord keys. Measured: the example binary and the runtime are both 78 MiB (the plan estimated ~95 MB). `lgx build` printed no server output while bundling. The darwin/arm64 cross-build fails in `hwstats` (`undefined: cpu.Stats`), as predicted. Native macOS was not run, and the README says so rather than claiming it works. Regression: `sqlite/example` ran with all checks passing and `sql` tests passed (14/26) on the new `bin/lgx`.

### Task 11: Release (user-triggered)

Do not run this task without the user's go-ahead: it tags and pushes public repos.

- [x] **Step 1: lgx.** Bump `version` in `lgx.lg` to `0.5.0`, update the README's release notes if it has them, commit, tag `v0.5.0`, push. Wait for the release workflow to publish binaries.
- [x] **Step 2: letgo-packages `.mise.toml`.** Bump `lgx` to `0.5.0`. Commit.
- [x] **Step 3: Shim module.** Tag `livekit/shim/v0.1.0` on the commit holding the shim, push the tag, and verify from a throwaway module that `go get github.com/abogoyavlensky/letgo-packages/livekit/shim@v0.1.0` resolves to plain `v0.1.0` (require let-go first, per the root README).
- [x] **Step 4: Flip the coord.** Set `livekit/lgx.edn` to `{:go/version "v0.1.0" :go/replace {...}}`, commit, tag `livekit-v0.1.0`, push. Expected: CI runs the livekit package on lgx 0.5.0 and passes.
> Deviation (user's call): lgx was released as **0.4.1**, not 0.5.0, and the package tag is `livekit-v0.1.0` (the repo's `<pkg>-vX.Y.Z` form). letgo-packages `master` had moved on (duckdb, and sql pinned by tag) and had generalised the CI shim override into one loop. The merge folded livekit into that loop: its `sed` no longer requires the closing `}`, and livekit's coord opens on the lib's line, so its `:go/replace` map survives the flip. The standalone livekit block was dropped. `go get .../livekit/shim@v0.1.0` resolved to plain `v0.1.0`, and the package tests passed against the published shim on a fresh cache before `livekit-v0.1.0` was tagged.
> End-to-end after release: the downloaded lgx 0.4.1 (checksum verified) ran a fresh consumer project that depends only on `:git/tag "livekit-v0.1.0"`, with an empty `LGX_HOME`. `lgx info` listed the shim and its three replaces, inherited through the git dep. `lgx run` and the built 78 MiB binary both passed every check: integrant start, CreateRoom/ListRooms, a 401 for a grantless token, join-token minting, webhook rejection, and a clean halt. `lgx build` started no server.
> CI: letgo-packages `master` and the `livekit-v0.1.0` tag run both passed on lgx 0.4.1 via mise (livekit: 10 tests, 0 failures).

---

## Completion summary

**Implemented.**
- lgx (branch `livekit-wrapper-assessment`): `:go/replace` is accepted and validated on external Go coords (`config/go-replace-errors`). It is hashed only for coords that carry it, so existing cache keys are unchanged (pinned by a literal-hash test). `gobuild/merged-replaces` merges it across the tree with dedupe, conflicts and reserved modules, and `gobuild/merged-replace-errors` turns the result into messages. `ensure-runtime!` rejects bad merges before Go runs or a file is written, `render-go-mod` renders the merged block, and `lgx info` lists it. Also e2e Scenarios 160-161, README, and three docs.
- letgo-packages (branch `livekit-package`): the `livekit` package. It has a shim (lifecycle with startup ownership and a reaper, `Token`, `VerifyWebhook`), the `livekit.core` veneer, the `:livekit/server` integrant component, 10 tests on a real server, an asserting integrant example, a README, a CI shim override, and root README updates.
- Verification: lgx 825 unit and 528 e2e passing. The live probe linked livekit-server with the three forks, and failed with `EnableSped undefined` without them. livekit: 10 tests / 21 assertions pass, the example passes under `lgx run` and as a built 78 MiB binary, and the sqlite/sql regression checks pass.

**Issues encountered.**
- The plan's probe command put `--verbose` after `run`, where lgx forwards it to `lg`.
- Codex found one real bug: `ToGo`, copied from wails, turns an empty let-go map into a JSON array. It is fixed in livekit; wails has the same latent bug and was left alone.
- An identical second config collides on the RTC TCP port during wiring, not on the HTTP port, so the occupied-port test moves the RTC port to exercise the HTTP path.
- Codex's review runs could not execute the livekit tests, because the lgx on its PATH (0.2.0) predates `:go/replace`. They were run locally instead.

**Deviations** (details under each task):
1. `ensure-runtime!` reads the local module paths once and passes `locals` to `write-module!`. `merged-replaces` takes `reserved` as `{module lib}`, and `:reserved` entries carry `:by`.
2. Conflict and reserved messages come from a new pure `merged-replace-errors` and are reported in one `die!`. The probe used `lgx --verbose run`.
3. `lgx info` indents replace lines under their coord. The e2e scenarios are numbered 160-161.
4. The wrappers doc footer also names `livekit/lgx.edn`. Plan-doc progress is committed with the docs.
5. Part 2 lives on a `livekit-package` branch. The shim `go.mod` lists only the direct requires.
6. `ToGo` recognises maps by type tag (review fixup).
7. The occupied-port test moves the RTC TCP port.
8. `:identity` is optional in `token`. The body digest is a pinned constant, since `hash/sha256` returns hex. `verify-webhook` tolerates `Bearer `.
9. The CI override is a single version-only `sed`. Added `example/.gitignore`. The README does not claim native macOS works (it was not run), and records the measured 78 MiB size.

**What the plan could have specified better:** it should have checked its commands against the real CLI (`lgx --verbose run`) and the real runtime (where a same-config second start actually collides) instead of reasoning from upstream source. Both claims were cheap to run before the plan was written.

