## Cache `:git/tag` deps by tag name, not resolved SHA

Status: Completed on 2026-05-12.

## Context

Today, `lgx install` always calls `git ls-remote` for `:git/tag` coords —
even when the lib is already in the gitlibs cache. `ensure-lib!` resolves
the tag to a SHA first, then uses the SHA as the cache key, then checks
whether that directory exists. So tag-pinned deps make a network round
trip on every install, regardless of cache state.

The proposed change: use the tag itself as the cache key. If the cache
directory exists, return it; never hit the network. New installs use
`git clone --branch <tag>` and skip the separate `ls-remote` entirely.

Tradeoff: a re-pushed (force-updated) tag won't be picked up
automatically — users would need to delete the cache dir to refresh. In
practice semver release tags are immutable by convention, and other
package managers (clj/tools.deps included) cache once and pin forever,
so the auto-refresh was arguably a misfeature.

## Cache layout

```
~/.lgx/gitlibs/<host>/<owner>/<repo>/<ref>/
```

`<ref>` is:

- the SHA, for `:git/sha` coords (unchanged)
- the tag, with `/` replaced by `_`, for `:git/tag` coords

Examples:

| Coord                              | Cache leaf       |
| ---------------------------------- | ---------------- |
| `:git/sha "abc123…"`               | `abc123…`        |
| `:git/tag "v1.0.0"`                | `v1.0.0`         |
| `:git/tag "release/1.0"`           | `release_1.0`    |

SHA and tag entries coexist — 40-hex SHAs don't collide with realistic
tag names. If a tag happens to look like a SHA, it lives in its own
directory anyway; the content is identical so there's no correctness
issue, only minor disk duplication.

### Sanitization

Single rule: `(str/replace tag "/" "_")`. Applied at the one place we
build the cache leaf.

Git already disallows most path-hostile chars in tag names (`..`, `~`,
`^`, `:`, control chars, leading `.`, trailing `.lock`, `@{`), so after
the `/` swap the result is path-safe on macOS/Linux. If a pathological
tag turns up in the wild, we tighten the rule then.

## New `ensure-lib!` flow

```
git case:
  ref = (:git/sha coord) OR sanitize(:git/tag coord)
  dir = coord-dir(url, ref)
  if (file-exists? dir):
    return {:path …, :installed? false}        ; zero network calls
  else:
    if :git/sha:  git clone url tmp; git -C tmp checkout sha
    if :git/tag:  git clone --branch <tag> --depth 1 url tmp
    finalize tmp -> dir
```

Key shift: the cache-existence check happens before any `git`
invocation. For `:git/tag` we drop `ls-remote` entirely — one `git
clone --branch <tag>` does the right thing for new installs.

Tag-pinned deps: zero network calls when cached, one `git clone` when
not (down from two: `ls-remote` + `clone`). SHA-pinned deps: unchanged.

## Implementation

### `lgx/cache.lg`

- Delete `resolve-tag->sha`.
- Add `(defn- tag->ref [tag] (str/replace tag "/" "_"))`.
- Rework `ensure-lib!` git branch so `ref` is computed first, then
  `dir`, then existence check, then clone-on-miss.
- Update `clone-and-checkout!` to take a coord shape (or two arities)
  so the SHA path keeps `clone` + `checkout` and the tag path uses
  `clone --branch <tag> --depth 1`. Both end with the same
  `.git`-removal and atomic rename.

Sketch:

```clojure
(defn- tag->ref [tag]
  (str/replace tag "/" "_"))

(defn- clone-tag! [url tag dest]
  ;; git clone --branch <tag> --depth 1 url tmp; finalize.
  …)

(defn- clone-sha! [url sha dest]
  ;; existing clone + checkout body, factored out.
  …)

(defn ensure-lib! [coord project]
  (let [root  (:deps/root coord)
        local (:local/root coord)]
    (if local
      …  ; unchanged
      (let [url        (:git/url coord)
            sha        (:git/sha coord)
            tag        (:git/tag coord)
            ref        (or sha (tag->ref tag))
            dir        (coord-dir url ref)
            installed? (not (file-exists? dir))]
        (when installed?
          (if sha
            (clone-sha! url sha dir)
            (clone-tag! url tag dir)))
        {:path (resolve-source-path dir root url ref)
         :installed? installed?}))))
```

`resolve-source-path` still receives the ref as its `sha` arg for error
messages — the param name is internal; renaming is optional cleanup.

### `lgx/config.lg`

No change. Validation already requires `:git/sha` or `:git/tag`.

### `lgx.lg`

No change.

## Tests

### `tests/cache_test.lg`

- `ensure-lib-caches-tag-by-name` — pre-populate
  `~/.lgx/gitlibs/host/owner/repo/v1.0.0/` with fixture content;
  `{:git/url "…/repo" :git/tag "v1.0.0"}` returns that path with
  `:installed? false` and makes zero `git` invocations (stub `os/sh`
  or assert via an integration shim).
- `ensure-lib-sanitizes-slash-in-tag` — `:git/tag "release/1.0"`
  resolves the cache dir to `release_1.0`.
- `ensure-lib-sha-path-unchanged` — existing SHA test still passes
  byte-for-byte; SHA leaf is the SHA.

### `tests/e2e.sh`

- Tag scenario: install a fixture lib pinned by tag; second `lgx
  install` makes no `git` invocations. Easiest assertion: run with a
  sentinel `PATH` where `git` is a script that records calls, or
  unplug network and confirm the second install succeeds.

Existing tag-install tests should keep passing — the externally
observable behavior on a fresh cache is unchanged (still ends up with
the right code at the right path).

## Docs

### `README.md`

Replace the current paragraph:

> Tags resolve to a sha at install time via `git ls-remote`. Sha-pinned
> coords are fully reproducible; tag-pinned coords re-resolve on each
> `lgx install`.

with:

> Tag-pinned coords cache under the tag name itself — no `git
> ls-remote` call when the lib is already cached, and no network use at
> all on cache hits. Sha-pinned coords cache under the sha. If a
> maintainer force-updates a tag upstream, `lgx install` will not pick
> up the new commit automatically; delete the cache directory
> (`rm -rf ~/.lgx/gitlibs/<host>/<owner>/<repo>/<tag>`) to refresh.

### `docs/ARCHITECTURE.md`

- "Cache layout" subsection: update the leaf description from "full
  sha" to "ref (sha or sanitized tag)".
- `lgx install` step list: drop the `ls-remote` step for tag coords;
  note `git clone --branch <tag>` for the new-install case.

### Knowledge base

No knowledge-base updates required — the change is internal to lgx,
not a let-go runtime detail.

## Out of scope (YAGNI)

- `lgx install --refresh` flag. Users can `rm -rf` the cache dir.
  Revisit if multiple users hit re-pushed tags in practice.
- Sidecar metadata recording which SHA a tag resolved to. Useful for
  audit but not needed for the cache to work.
- Lockfile / `lgx.lock` pinning tags to SHAs at install time.
  Separate, larger design.
- Tightening tag-char validation beyond the `/` swap. Wait for a real
  pathological case.

## Verification

- Fresh cache, `:git/tag "v1.0.0"` coord → one `git clone --branch
  v1.0.0` call; lib appears at `…/repo/v1.0.0/`.
- Warm cache, same coord → zero `git` invocations; same path returned;
  `:installed? false`.
- `:git/tag "release/1.0"` coord → cache leaf is `release_1.0`.
- `:git/sha` coord → unchanged behavior; cache leaf is the SHA.
- Unplugging the network after first install and re-running `lgx
  install` succeeds for tag-pinned deps.

## Execution summary

Completed on 2026-05-12.

- `lgx/cache.lg` now checks the gitlibs cache before any git invocation
  for tag coords, uses sanitized tag names as cache refs, and clones new
  tag deps with `git clone --branch <tag> --depth 1`.
- Cache unit tests cover tag-name cache hits and `/` to `_`
  sanitization. E2E coverage now verifies a warm tag cache works when
  `git` is unavailable on `PATH`.
- `README.md` and `docs/ARCHITECTURE.md` now describe the ref-based
  cache layout and tag refresh tradeoff.
- Verification run: `bash tests/run.sh` passed.
