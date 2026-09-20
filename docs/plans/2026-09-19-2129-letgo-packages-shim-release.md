# letgo-packages Shim Release Implementation Plan

**Status: completed 2026-09-19.**

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag the two Go shims in letgo-packages as versioned nested Go modules, switch their `lgx.edn` coords from `:go/local` to `:go/version`, tag the lgx-level packages, re-pin lgx's examples to those tags, and write the release guide into the letgo-packages README — so `lgx run` on a project using these packages reuses the cached runtime instead of re-driving the Go toolchain on every invocation.

**Tech Stack:** git tags, Go modules (nested-module tagging, MVS, proxy.golang.org), lgx `:go/*` coords, lgx `:git/tag` deps.

**Repos:**
- letgo-packages: `~/Projects/letgo-packages` (branch `master`, remote `https://github.com/abogoyavlensky/letgo-packages.git`, currently at `2167c99`, no tags).
- lgx: `~/Projects/lgx` (branch `web-app-ragtime`; commits land there).

---

## Design

### Why

`lgx run` on `examples/web-app` takes ~2 s on every invocation even though the custom runtime is cached at `~/.lgx/runtimes/<hash>/lg`. `ensure-runtime!` (`lgx/gobuild.lg:620`) reuses the cached binary only when `live?` is false, and `live?` is true whenever any `:go/local` coord is in play (`lgx/gobuild.lg:596-598`) — the working tree behind such a coord is not in the runtime hash, so lgx rebuilds defensively. The web-app declares no `:go/local` itself; it inherits `github.com/abogoyavlensky/letgo-packages/sql/shim {:go/local "shim"}` transitively from `sql/lgx.edn` in letgo-packages. That shim lives in an immutable sha-pinned gitlibs checkout, but lgx cannot tell. `wails/lgx.edn` has the identical pattern (`wails/shim {:go/local "shim"}`), and `postgres` inherits the sql one.

Both coords carry the same comment: *":go/local while the wrapper is unreleased; becomes `{:go/version "vX.Y.Z"}` when it is tagged."* This plan does exactly that. Once the coords are `:go/version`, no local path is involved, `live?` is false, and every run after the first is a cache hit — no lgx code change needed. (Making lgx itself treat gitlibs-resident `:go/local` as immutable is a separate, later fix; out of scope here.)

### The two-tag model

Two independent tag namespaces coexist in the letgo-packages repo:

| Tag | Form | Who reads it | Points at |
|---|---|---|---|
| Go module tag | `sql/shim/v0.1.0`, `wails/shim/v0.1.0` | `go get` via proxy.golang.org. Go requires a nested module's tag to be `<subdir>/vX.Y.Z`. | the commit *before* the coord flip |
| lgx package tag | `sql-v0.1.0`, `sqlite-v0.1.0`, `postgres-v0.1.0`, `wails-v0.1.0` | lgx `:git/tag` deps (`git clone --branch <tag> --depth 1`). Free-form; Go ignores non-semver tags, and lgx maps `/`→`_` for cache dirs, so the namespaces cannot collide. | the commit *after* the coord flip |

**Why two rounds.** The flip commit writes `{:go/version "v0.1.0"}`; that line only works if the Go tag already exists on GitHub, because `go get` fetches from the remote, not the working tree. So the Go tags are pushed *before* the flip commit is made (they point at the pre-flip commit; the shim's Go code is identical), which lets the flip be verified locally before it is pushed. The lgx package tags then go on the post-flip commit, because a consumer pulling `sqlite-v0.1.0` must receive the `lgx.edn` that says `:go/version`, not `:go/local`. (Tagging the flip commit itself and pushing commit and tags together would also work, but only by pushing the flip unverified.)

### Key decisions

1. **Also cut lgx-level package tags** (`sql-v0.1.0`, `sqlite-v0.1.0`, `postgres-v0.1.0`, `wails-v0.1.0`). It is the format the root README and package READMEs already advertise, and lgx's examples pin to them.
2. **Keep `require github.com/nooga/let-go v0.0.0` in both shim `go.mod`s.** Verified from a throwaway module (2026-09-19): `go get …/sql/shim@<commit>` through the proxy, `go mod tidy`, and a full `go build` all succeed; `go.sum` never needs a `v0.0.0` entry. MVS resolves the floating require to whatever the runtime module pins, so the consumer's `:lg-version` stays the truth. A real pin (e.g. `v1.13.0` once released) would set a floor that silently bumps a consumer's older pin via MVS. Cost, stated in the guide: `shim/` is not buildable standalone (`go vet ./...` inside it needs a `replace` or `go.work`); it compiles only through the runtime module lgx generates. The guide documents "known to work from let-go `f26eb497299760e93ce430302f13ab3a954eab64`" as the human-readable floor.
3. **Package `example/` dirs keep `:local/root ".."`.** After the flip they build against the *tagged* shim from the proxy, i.e. they test the release. A shim author's inner loop is: flip the coord back to `{:go/local "shim"}` locally, iterate (lgx's live rebuild does its job), and do not commit the flip-back.
4. **Immutability rules.** Never move or delete a pushed tag: proxy.golang.org and sum.golang.org cache Go module tags permanently, and lgx's gitlibs cache keys on the tag name. Fix forward with a new version. Bump the shim tag whenever `shim/` changes; a shim bump always implies a package bump because `lgx.edn` changes with it. Package tags may bump on their own (`.lg`-only changes).
5. **Version `v0.1.0` everywhere**, matching the existing README snippets.
6. **Ordering per step is strict**: Go tags pushed → verified from a probe module → coord flip + docs committed and pushed → package tags pushed → lgx re-pin.
7. **Outward-facing actions** (every `git push`) are explicit steps; the executor confirms with the user before each push.

### Verification strategy

- Round 1: a probe module in `/tmp` does `go get …/sql/shim@v0.1.0` and must report exactly `v0.1.0` (not a pseudo-version), then builds. For `wails/shim`, `go get` + `go mod download` only — this Linux box has no webkit2gtk, so wails cannot build here.
- After the flip: `sqlite/example` — `lgx --verbose run` twice. The first prints `=> Building custom lg runtime...`; the second prints **no** such line and finishes in well under a second. That second run is the point of the whole plan.
- After the re-pin: `examples/web-app` — `lgx install` fetches `sqlite-v0.1.0`; `lgx test` passes; the two-run check again. `examples/wails-desktop` — `lgx info` resolves the tag; the actual window run is a manual macOS step flagged to the user.

`lgx` throughout means `~/Projects/lgx/bin/lgx` (0.2.1, built from this checkout).

## File Structure

letgo-packages (`~/Projects/letgo-packages`):
- Modify `sql/lgx.edn` — shim coord `{:go/local "shim"}` → `{:go/version "v0.1.0"}`; update the comment.
- Modify `wails/lgx.edn` — same flip, same comment update.
- Modify `README.md` — replace the "Tagging status" section with a "Releasing" guide.
- Modify `sqlite/README.md` — "Development" section: drop the stale unreleased-state paragraph, point at the guide, keep the `LGX_LETGO_REPLACE` note; fix the `:lg-version "1.11.1"` snippet.
- Modify `wails/README.md` — "Development" section likewise; fix the `:lg-version "1.11.1"` snippet; layout comment `(:go/local)` → `(:go/version)`.
- Modify `sql/README.md` — layout comment `(:go/local)` → `(:go/version)`.
- Not modified: `sql/shim/go.mod`, `wails/shim/go.mod` (the `v0.0.0` require stays, by decision 2), `sqlite/lgx.edn`, `postgres/lgx.edn`, any `example/lgx.edn`.

lgx (`~/Projects/lgx`):
- Modify `examples/web-app/lgx.edn` — `:git/sha "690ecc28…"` → `:git/tag "sqlite-v0.1.0"`.
- Modify `examples/wails-desktop/lgx.edn` — `:git/sha "f4beb9b9…"` → `:git/tag "wails-v0.1.0"`.
- Modify `docs/knowledge-base/lgx-go-wrappers.md` — the consumer snippet (`:git/sha "..."` → `:git/tag "sqlite-v0.1.0"`) and the "Nothing in `letgo-packages` is tagged yet" bullet.

---

### Task 1: Push the Go module tags (round 1)

**Files:** none (git tags only, repo `~/Projects/letgo-packages`).

- [x] **Step 1: Confirm a clean starting point**
  Run: `git -C ~/Projects/letgo-packages status --short && git -C ~/Projects/letgo-packages log --oneline -1 && git -C ~/Projects/letgo-packages tag`
  Expected: no status lines, HEAD is `2167c99`, and no tags listed. If `master` has moved past `2167c99`, that is fine as long as the tree is clean — the tags go on HEAD.

- [x] **Step 2: Create the two annotated Go module tags on HEAD**
  Run:
  ```
  git -C ~/Projects/letgo-packages tag -a sql/shim/v0.1.0 -m "sql/shim v0.1.0"
  git -C ~/Projects/letgo-packages tag -a wails/shim/v0.1.0 -m "wails/shim v0.1.0"
  git -C ~/Projects/letgo-packages tag
  ```
  Expected: both tags listed. The `<subdir>/vX.Y.Z` form is what Go requires for a module whose `go.mod` sits in a subdirectory (`sql/shim/go.mod`, `wails/shim/go.mod`).

- [x] **Step 3: Push the tags (outward-facing — confirm with the user first)**
  Run: `git -C ~/Projects/letgo-packages push origin sql/shim/v0.1.0 wails/shim/v0.1.0`
  Expected: two `[new tag]` lines. Pushed Go tags are permanent once the proxy sees them; do not delete or move them after this point.

### Task 2: Verify the tags resolve through the module proxy

**Files:** a throwaway module under `/tmp` (nothing in either repo).

- [x] **Step 1: Probe `sql/shim@v0.1.0`**
  In a fresh `mktemp -d` directory: write a `main.go` that imports `_ "github.com/abogoyavlensky/letgo-packages/sql/shim"` and `"github.com/nooga/let-go/pkg/cli"` and calls `os.Exit(cli.Main("x","y"))`; then
  ```
  go mod init probe
  go get github.com/nooga/let-go@f26eb497299760e93ce430302f13ab3a954eab64
  go get github.com/abogoyavlensky/letgo-packages/sql/shim@v0.1.0
  go mod tidy
  go build -o /dev/null .
  grep letgo-packages go.mod
  ```
  Expected: the `go get` line reports `added github.com/abogoyavlensky/letgo-packages/sql/shim v0.1.0` (a plain `v0.1.0`, **not** `v0.0.0-2026…-<sha>`); build succeeds; `go.mod` requires the shim at `v0.1.0`. Order matters: let-go must be required before the shim so MVS has a real version to beat the shim's `v0.0.0` placeholder — lgx's pipeline does the same (`letgo-get-args` runs before `go-get-args`, and the rendered `go.mod` already carries the let-go require).
  If the proxy has not indexed the tag yet, retry once after a minute, or run the `go get` with `GOPROXY=direct`.

- [x] **Step 2: Probe `wails/shim@v0.1.0` (resolution only)**
  In another fresh temp module: `go mod init probe2`, `go get github.com/nooga/let-go@f26eb497299760e93ce430302f13ab3a954eab64`, `go get github.com/abogoyavlensky/letgo-packages/wails/shim@v0.1.0`, `go mod download`.
  Expected: `added github.com/abogoyavlensky/letgo-packages/wails/shim v0.1.0` and `go mod download` exits 0. Do not `go build` — wails needs webkit2gtk, absent on this machine.

### Task 3: Flip the coords and write the release guide (letgo-packages)

**Files:**
- Modify: `~/Projects/letgo-packages/sql/lgx.edn`
- Modify: `~/Projects/letgo-packages/wails/lgx.edn`
- Modify: `~/Projects/letgo-packages/README.md`
- Modify: `~/Projects/letgo-packages/sqlite/README.md`
- Modify: `~/Projects/letgo-packages/wails/README.md`
- Modify: `~/Projects/letgo-packages/sql/README.md`

Use /writing-clearly for the prose.

- [x] **Step 1: Flip `sql/lgx.edn`**
  Replace `github.com/abogoyavlensky/letgo-packages/sql/shim {:go/local "shim"}` with `github.com/abogoyavlensky/letgo-packages/sql/shim {:go/version "v0.1.0"}`. Rewrite the two comment lines above it: the shim is released as the nested Go module tagged `sql/shim/vX.Y.Z`; to work on it locally, flip this line to `{:go/local "shim"}` and do not commit that (see README "Releasing").

- [x] **Step 2: Flip `wails/lgx.edn`**
  Same edit for `github.com/abogoyavlensky/letgo-packages/wails/shim`; keep the existing sentence about Wails arriving through the shim's own `go.mod` and no `:go/interop`.

- [x] **Step 3: Replace the README "Tagging status" section with a "Releasing" guide**
  In `README.md`, delete the whole `## Tagging status` section (its "nothing is tagged" / "what remains is a let-go release" claims are now false) and write `## Releasing` covering, in this order and tightly:
  1. *Two kinds of tags.* The table from the Design section: Go module tags `<pkg>/shim/vX.Y.Z` (form dictated by Go for a nested module; read by `go get`) and lgx package tags `<pkg>-vX.Y.Z` (read by `:git/tag`; Go ignores them). Which packages have a shim: `sql`, `wails`. `sqlite` and `postgres` have none — they inherit `sql`'s.
  2. *Order of operations* when a shim changed, as a numbered list: (a) tag `<pkg>/shim/vX.Y.Z` on the commit containing the shim change and push the tag; (b) verify from a throwaway module that `go get github.com/abogoyavlensky/letgo-packages/<pkg>/shim@vX.Y.Z` reports plain `vX.Y.Z` — requiring let-go first; (c) set `<pkg>/lgx.edn` to `{:go/version "vX.Y.Z"}` and commit; (d) tag the packages `<pkg>-vX.Y.Z` on that commit and push. State the reason for the order in one sentence: the coord references a tag that `go get` fetches from GitHub, so the Go tag must predate the commit that references it, and the package tag must follow it so consumers get the flipped `lgx.edn`. When only `.lg` files changed, skip (a)–(c).
  3. *The `v0.0.0` let-go require* in `sql/shim/go.mod` and `wails/shim/go.mod` is deliberate: the shim has no let-go version of its own; MVS resolves the placeholder to the consumer's `:lg-version`, so the project's pin stays authoritative. A real version would set a floor and silently bump older pins. The cost: `shim/` does not build standalone (needs a `replace` or `go.work`); it compiles through the runtime module lgx generates. Known to work from let-go `f26eb497299760e93ce430302f13ab3a954eab64` (the first commit carrying the merged interop work); consumers pin that or newer with `:lg-runtime :built`.
  4. *Never retag.* proxy.golang.org and sum.golang.org record a Go tag permanently, and lgx caches a `:git/tag` checkout under the tag name. Fix forward with a new version.
  5. *Working on a shim.* Flip `<pkg>/lgx.edn` back to `{:go/local "shim"}` locally; lgx then rebuilds the runtime on every command (incremental, about a second) so edits to `shim.go` take effect. Each `example/` uses `:local/root ".."` and picks this up. Do not commit the flip-back; release per the steps above instead. `LGX_LETGO_REPLACE=/path/to/let-go` is the separate lever for an uncommitted let-go change.
  Keep the existing consumer snippet near the top of the README as is (`:git/tag "sqlite-v0.1.0"` — now real).

- [x] **Step 4: Update `sqlite/README.md`**
  In the consumer snippet (around line 20), replace `:lg-version "1.11.1"` with `:lg-version "f26eb497299760e93ce430302f13ab3a954eab64"` — `1.11.1` predates the interop work and cannot build this package. In `## Development` (around line 128), delete the paragraph starting "While the packages are unreleased" through "scanned values arrive as opaque boxes." and replace it with two sentences: the shim ships as the tagged Go module `sql/shim/vX.Y.Z` that `sql/lgx.edn` pins; to edit it, see "Releasing" in the root README (flip to `:go/local` locally). Keep the `LGX_LETGO_REPLACE` block that follows.

- [x] **Step 5: Update `wails/README.md`**
  Same snippet fix (`:lg-version "1.11.1"` → the sha, around line 40). In `## Development` (around line 176), replace the "While the packages are unreleased … `replace` governs." sentences with the same two-sentence pointer (module `wails/shim/vX.Y.Z`, pinned by `wails/lgx.edn`); keep the `LGX_LETGO_REPLACE` block and the dev-loop timing paragraph, but qualify the "about 1.4s after a Go edit to the shim" figure with "with the coord flipped to `:go/local`". In the layout tree (around line 123) change `deps: the shim (:go/local)` to `deps: the shim (:go/version)`.

- [x] **Step 6: Update `sql/README.md` layout comment**
  Around line 97: `:go/interop for database/sql + the shim (:go/local)` → `… + the shim (:go/version)`.

- [x] **Step 7: Verify the flipped sqlite example is a cache hit on the second run**
  Run:
  ```
  cd ~/Projects/letgo-packages/sqlite/example
  ~/Projects/lgx/bin/lgx --verbose run > /tmp/run1.log 2>&1; echo "exit $?"
  grep -E "Building custom|shim@v0.1.0" /tmp/run1.log
  time ~/Projects/lgx/bin/lgx --verbose run > /tmp/run2.log 2>&1; echo "exit $?"
  grep -c "Building custom" /tmp/run2.log
  ```
  Expected: both runs exit 0 (check this before reading the greps — a `0` count from a failed run proves nothing). The first log contains `=> Building custom lg runtime...` and a `go -C … get github.com/abogoyavlensky/letgo-packages/sql/shim@v0.1.0` line (new hash, one build). The second log has a `0` count and `real` well under 1 s. If the second run still shows `Building custom`, the coord is still `:go/local` somewhere — check `~/Projects/lgx/bin/lgx info` for a `local` entry under `go-deps`.

- [x] **Step 8: Verify the wails package still resolves (no build possible here)**
  Run: `cd ~/Projects/letgo-packages/wails/example && ~/Projects/lgx/bin/lgx info; echo "exit $?"`
  Expected: exit 0; `go-deps` lists `github.com/abogoyavlensky/letgo-packages/wails/shim v0.1.0 (via abogoyavlensky/letgo-wails)` — a version, not a `local` path. Exit 0.

- [x] **Step 9: Commit and push (outward-facing — confirm with the user before the push)**
  Run: `git -C ~/Projects/letgo-packages add -A && git -C ~/Projects/letgo-packages commit -m "Release sql/shim and wails/shim v0.1.0: pin by :go/version, add release guide" && git -C ~/Projects/letgo-packages push origin master`
  Expected: one commit on `master`, pushed.

> Deviation (Task 3): two more stale "unreleased" mentions were fixed beyond the plan's list — `sql/README.md` (pointed at the deleted "tagging notes") and `wails/README.md` Requirements (said lgx and let-go were both unreleased). Both now point at the sha pin / "Releasing". Measured: sqlite/example second run 0.05 s, zero build lines. Commit `78315df`, pushed.

### Task 4: Push the lgx package tags (round 2)

**Files:** none (git tags only, repo `~/Projects/letgo-packages`).

- [x] **Step 1: Tag the four packages on the flip commit**
  Run:
  ```
  cd ~/Projects/letgo-packages
  for p in sql sqlite postgres wails; do git tag -a "$p-v0.1.0" -m "$p v0.1.0"; done
  git tag --points-at HEAD
  ```
  Expected: `postgres-v0.1.0 sql-v0.1.0 sqlite-v0.1.0 wails-v0.1.0` all pointing at the Task 3 commit (and *not* at the round-1 commit).

- [x] **Step 2: Push the tags (outward-facing — confirm with the user first)**
  Run: `git -C ~/Projects/letgo-packages push origin sql-v0.1.0 sqlite-v0.1.0 postgres-v0.1.0 wails-v0.1.0`
  Expected: four `[new tag]` lines.

### Task 5: Re-pin lgx's examples and update the wrapper doc

**Files:**
- Modify: `~/Projects/lgx/examples/web-app/lgx.edn`
- Modify: `~/Projects/lgx/examples/wails-desktop/lgx.edn`
- Modify: `~/Projects/lgx/docs/knowledge-base/lgx-go-wrappers.md`

- [x] **Step 1: Re-pin web-app**
  In `examples/web-app/lgx.edn`, the `abogoyavlensky/letgo-sqlite` coord: replace `:git/sha "690ecc28a56c612ede7355dab205ed934892c063"` with `:git/tag "sqlite-v0.1.0"`. Leave `:deps/root "sqlite"` and the comment.

- [x] **Step 2: Re-pin wails-desktop**
  In `examples/wails-desktop/lgx.edn`: replace `:git/sha "f4beb9b9d2bf77a3408a4261469bd48922f89f82"` with `:git/tag "wails-v0.1.0"`.

- [x] **Step 3: Update `docs/knowledge-base/lgx-go-wrappers.md`**
  In the consumer snippet under "Where wrappers live" (around line 47) replace `:git/sha "..."` with `:git/tag "sqlite-v0.1.0"`. Replace the bullet starting "**Nothing in `letgo-packages` is tagged yet.**" (around line 185) with one that states the current model: packages are tagged `<pkg>-vX.Y.Z` for `:git/tag`, and a package with a Go shim additionally tags it `<pkg>/shim/vX.Y.Z` as a nested Go module that its `lgx.edn` pins with `:go/version`; the release order and the `v0.0.0` let-go require are documented in the letgo-packages README "Releasing" section. Keep the `Verify against` footer.

- [x] **Step 4: Verify web-app fetches the tag and is a cache hit on the second run**
  Run:
  ```
  cd ~/Projects/lgx/examples/web-app
  ~/Projects/lgx/bin/lgx install > /tmp/wa-install.log 2>&1; echo "exit $?"; grep -v warning /tmp/wa-install.log
  ~/Projects/lgx/bin/lgx --verbose run -e nil > /tmp/wa-run1.log 2>&1; echo "exit $?"; grep -c "Building custom" /tmp/wa-run1.log
  time ~/Projects/lgx/bin/lgx --verbose run -e nil > /tmp/wa-run2.log 2>&1; echo "exit $?"; grep -c "Building custom" /tmp/wa-run2.log
  ~/Projects/lgx/bin/lgx test; echo "exit $?"
  ```
  Expected: every command exits 0. `install` prints `installing 1 dep(s)...`, a `abogoyavlensky/letgo-sqlite -> …/letgo-packages/sqlite-v0.1.0/sqlite` line, and `done` (or `all deps up to date` if already fetched), and — since the coord line changed the runtime hash — `=> Building custom lg runtime...` once. The first `run` count may be `0` (install already built it) or `1`; the second run's count must be `0` and its `real` well under 1 s. `lgx test` reports all tests passing.

- [x] **Step 5: Verify wails-desktop resolves**
  Run: `cd ~/Projects/lgx/examples/wails-desktop && ~/Projects/lgx/bin/lgx info; echo "exit $?"`
  Expected: exit 0; dep fetched from `wails-v0.1.0`; `go-deps` shows `…/wails/shim v0.1.0`; exit 0. Tell the user the window itself must be checked on macOS (`lgx run` in this example) — it cannot build here.

- [x] **Step 6: Run the lgx test suite**
  Run: `cd ~/Projects/lgx && make test; echo "exit $?"`
  Expected: exit 0, passes as before this plan (nothing under `test/`/`tests/` references the example pins).

- [x] **Step 7: Commit**
  `git -C ~/Projects/lgx add examples/web-app/lgx.edn examples/wails-desktop/lgx.edn docs/knowledge-base/lgx-go-wrappers.md && git -C ~/Projects/lgx commit -m "examples: pin letgo-packages by tag now that the shims are released"`
  Do not push; the user decides when `web-app-ragtime` goes up.

> Deviation (Task 3, post-review): Codex flagged that "lgx 0.2 or newer" in `wails/README.md` (and the pre-existing line in `sqlite/README.md`) is wrong — `:lg-runtime` landed in lgx `ef329e0`, after the `v0.2.1` tag, so no released lgx accepts it. Fixed in fixup `b58115f` (pushed) before tagging, so the package tags point at `b58115f`, not `78315df`.

> Deviation (Task 5): no `Building custom lg runtime...` appeared at all — web-app's Go coord set is identical to sqlite/example's, so they share runtime hash `4c241fc6c1736ffa`, already built in Task 3. A stale `lgx run` from a previous session (serving `/tmp/web-app-rt`) held `bin/lgx` open and broke `make test` with "text file busy"; stopped it and re-ran: 380 e2e assertions passed.

### Task 6: Report

- [x] **Step 1: Summarize to the user**
  List: the six tags pushed and the commits they point at; the before/after timing of `lgx run` on `examples/web-app` (about 2 s → well under 1 s on the second run); the macOS manual check for wails-desktop; and the follow-up left open — an lgx-side fix so a `:go/local` inside `$LGX_HOME/gitlibs` is never treated as live (so future unreleased packages do not hit the same trap).

---

## Completion summary

**Implemented.** letgo-packages: Go module tags `sql/shim/v0.1.0` and `wails/shim/v0.1.0` on `2167c99`; coord flip + "Releasing" guide in `78315df`; lgx-version doc fixup `b58115f`; package tags `sql-v0.1.0`, `sqlite-v0.1.0`, `postgres-v0.1.0`, `wails-v0.1.0` on `b58115f`. All six tags and both commits pushed. lgx (`web-app-ragtime`): `0e98ef6` re-pins `examples/web-app` to `sqlite-v0.1.0` and `examples/wails-desktop` to `wails-v0.1.0`, and updates `lgx-go-wrappers.md`. Not pushed.

**Result.** `lgx run` on `examples/web-app`: ~2.0 s → 0.48 s (`-e nil`), with no Go toolchain invocation; `sqlite/example` second run 0.05 s. End-to-end: the web-app server starts in ~0.8 s, applies migrations, and serves POST/GET `/todos`. `make test`: 380 e2e assertions passed. Both shim tags resolve through proxy.golang.org as plain `v0.1.0`.

**Deviations** (also noted inline under the tasks):
- Task 3: fixed two extra stale "unreleased" mentions (`sql/README.md`, `wails/README.md` Requirements).
- Task 3 post-review: `:lg-runtime` is not in any lgx release (`ef329e0` follows `v0.2.1`); both READMEs now say to build lgx from `master`. Fixup `b58115f`; package tags point there.
- Task 5: no runtime build happened — web-app shares runtime hash `4c241fc6c1736ffa` with sqlite/example. A stale `lgx run` from a prior session held `bin/lgx` open; stopped it to let `make test` rebuild the binary.

**Open / manual.** `examples/wails-desktop` verified to `lgx info` only (no webkit2gtk here); run it on macOS. Follow-up not in this plan: make lgx treat a `:go/local` under `$LGX_HOME/gitlibs` as immutable so future unreleased packages do not hit the live rebuild. `lgx-go-wrappers.md:144` still claims `sql: lgx test` works, but `sql/lgx.edn` has no `:lg-runtime :built`, so it exits 1 — pre-existing drift, untouched.

**What the plan could have specified better:** it should have grepped both repos for every "unreleased"/"0.2 or newer" claim up front and checked which lgx release actually carries `:lg-runtime` — the review caught what a `git tag --contains` would have.
