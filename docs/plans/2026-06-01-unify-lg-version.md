# Unify the `lg` Build Version Implementation Plan

> **Status: Completed (2026-06-01).** See the Implementation Summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.mise.toml` the single source of truth for the let-go (`lg`) version used to build `lgx` itself, so local dev and CI (all target platforms) can never drift.

**Tech Stack:** mise, GNU Make, GitHub Actions (composite action), let-go `lg -b` bundling

---

## Design

### Problem

The `lg` version that bundles `lgx` is declared in four places that have already
drifted:

| Where | Value | Purpose |
|---|---|---|
| `.mise.toml` `[tools] lg` | `1.9.0` | local dev — mise puts `lg` on PATH; `Makefile` uses `LG ?= lg` |
| `.github/workflows/test.yml:16` | `2.0.2` | CI test job |
| `.github/workflows/release.yml:16` | `2.0.2` | CI test job (release pipeline) |
| `.github/workflows/release.yml:40` | `2.0.2` | CI release job (host `lg` + per-target `-bundle-base`) |

Because `lgx` is bundled with `lg -b`, the bundle embeds a let-go runtime at build
time. A local `make build` and a CI release therefore embedded *different* let-go
versions — the source of the repeated surprises (e.g. broken error coloring in a
shipped bundle while local builds were fine).

### Approach

`.mise.toml` `[tools] lg` becomes the **single source of truth**, pinned to
**`1.9.0`**.

- **Local dev** already derives from it: mise activates `lg` on PATH and the
  `Makefile` uses `LG ?= lg`. No change required.
- **CI** stops hardcoding `LG_VERSION`. A new composite action reads the version
  from `.mise.toml`, exports it as `LG_VERSION`, and installs the host `lg`. All
  three CI spots call the action.

### Components

**New composite action `.github/actions/setup-lg/action.yml`** — the one place CI
reads `.mise.toml`:

1. **Read version** — section-aware awk that extracts `[tools] lg`, deliberately
   skipping the duplicate `lg` key under `[tool_alias]`. Fail loudly if empty.
   Export `LG_VERSION=<v>` to `$GITHUB_ENV` so later steps in the job see it.
2. **Install host `lg`** — the existing curl flow (download
   `let-go_${LG_VERSION}_linux_amd64.tar.gz` + `lg-checksums.txt`, verify with
   `sha256sum -c`, extract, `sudo mv lg /usr/local/bin/lg`, `lg -v`). Leave
   `lg-checksums.txt` in the workspace so the release loop can reuse it.

Reference parse (controlled file, dependency-free):

```sh
V=$(awk -F= '
  /^\[tools\]/      {f=1; next}
  /^\[/             {f=0}
  f && $1 ~ /^[[:space:]]*lg[[:space:]]*$/ { gsub(/[" ]/,"",$2); print $2; exit }
' .mise.toml)
test -n "$V" || { echo "could not read lg version from .mise.toml"; exit 1; }
echo "LG_VERSION=$V" >> "$GITHUB_ENV"
```

### Data flow

```
.mise.toml [tools] lg = "1.9.0"
        │
        ├── local: mise → PATH → Makefile (LG ?= lg) → lg -b
        │
        └── CI: ./.github/actions/setup-lg
                  ├── awk → $GITHUB_ENV LG_VERSION
                  └── curl host lg (+ leaves lg-checksums.txt)
                        │
                        ├── test jobs: make test
                        └── release job: per-target curl bases + lg -b -bundle-base
```

### Error handling

- Empty/unparseable version → action exits non-zero with a clear message
  (prevents a silent fallback to a wrong/blank version).
- Checksum mismatch on any tarball → existing `sha256sum -c` fails the job.

### Testing strategy

Config/wiring change — no unit tests. Verify by: (1) running the awk locally and
asserting it prints `1.9.0`; (2) YAML-validating the new action; (3) end-to-end,
the next tagged build produces a bundle whose bytes contain `\x1b[1;31m` (ESC
present = fixed coloring), confirming the embedded let-go is the intended one.

## File Structure

- Create: `.github/actions/setup-lg/action.yml` — composite action: read version from `.mise.toml` → `LG_VERSION`, install host `lg`.
- Modify: `.github/workflows/test.yml` — replace hardcoded version + install step with the action.
- Modify: `.github/workflows/release.yml` — replace hardcoded version + install/fetch steps with the action in both jobs.
- No change: `.mise.toml` — already `lg = "1.9.0"`; it becomes the canonical source.

## Implementation Steps

### Task 1: Create the composite action

**Files:**
- Create: `.github/actions/setup-lg/action.yml`

- [x] **Step 1: Author the action**
  `runs: using: "composite"`. Two `shell: bash` steps:
  (a) the reference awk parse above, exporting `LG_VERSION` to `$GITHUB_ENV`
  with the non-empty guard;
  (b) host `lg` install via curl using `$LG_VERSION`
  (`let-go_${LG_VERSION}_linux_amd64.tar.gz` + `lg-checksums.txt`,
  `sha256sum -c`, extract, `sudo mv lg /usr/local/bin/lg`, `lg -v`), leaving
  `lg-checksums.txt` in the workspace.

- [x] **Step 2: Verify the parse in isolation**
  Run: `awk -F= '/^\[tools\]/{f=1;next} /^\[/{f=0} f && $1 ~ /^[[:space:]]*lg[[:space:]]*$/ {gsub(/[" ]/,"",$2);print $2;exit}' .mise.toml`
  Expected: `1.9.0`

### Task 2: Wire `test.yml`

**Files:**
- Modify: `.github/workflows/test.yml`

- [x] **Step 1: Use the action**
  In the `test` job, remove `env: LG_VERSION: 2.0.2` and the inline
  "Install let-go (lg)" step. After `actions/checkout@v4`, add
  `- uses: ./.github/actions/setup-lg`. Leave `make test` unchanged.

- [x] **Step 2: Validate YAML**
  Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/test.yml'))" && echo OK`
  Expected: `OK`

### Task 3: Wire `release.yml` (both jobs)

**Files:**
- Modify: `.github/workflows/release.yml`

- [x] **Step 1: Use the action in the `test` job**
  Remove `env: LG_VERSION` and the inline "Install let-go (lg)" step; add
  `- uses: ./.github/actions/setup-lg` after checkout.

- [x] **Step 2: Use the action in the `release` job**
  Remove `env: LG_VERSION`, the "Fetch let-go checksums" step, and the
  "Install host let-go (lg)" step; add `- uses: ./.github/actions/setup-lg`
  after checkout. Keep the "Build bundles for all targets" step as-is — it now
  reads `$LG_VERSION` from the action and reuses the `lg-checksums.txt` the
  action left in the workspace.

- [x] **Step 3: Validate YAML**
  Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo OK`
  Expected: `OK`

### Task 4: End-to-end verification

**Files:**
- (none — verification only)

- [x] **Step 1: Confirm no stray hardcoded versions remain**
  Run: `grep -rn "LG_VERSION:\s*[0-9]" .github/workflows/ || echo "none"`
  Expected: `none`

- [x] **Step 2: Prove the local bundle embeds the intended let-go**
  Run: `LG=$(command -v lg); "$LG" -b /tmp/lgx-verify lgx.lg && grep -c -a $'\x1b\[1;31m' /tmp/lgx-verify`
  Expected: a non-zero count (ESC-prefixed sequence present = correct coloring).
  Note: the authoritative CI proof is the next tagged release bundle; this local
  check confirms the source/bundling path.

## Implementation Summary

Done on branch `unify-lg-version`.

- **Created `.github/actions/setup-lg/action.yml`** — composite action with two
  bash steps: (1) section-aware awk reads `[tools] lg` from `.mise.toml` (skips
  the duplicate `lg` key under `[tool_alias]`), fails loudly if empty, exports
  `LG_VERSION` via `$GITHUB_ENV`; (2) curl-installs host `lg`
  (`linux_amd64`), verifies via `sha256sum -c`, leaves `lg-checksums.txt` in the
  workspace for the release loop.
- **`test.yml`** — `test` job now uses `./.github/actions/setup-lg`; hardcoded
  `LG_VERSION: 2.0.2` and the inline install step removed.
- **`release.yml`** — both `test` and `release` jobs use the action; the release
  job's separate "Fetch checksums" + "Install host let-go" steps were folded into
  the action. The "Build bundles for all targets" loop is unchanged and now reads
  `$LG_VERSION` (from the action) and reuses the action's `lg-checksums.txt`.
- **`.mise.toml`** — unchanged; `lg = "1.9.0"` is now the single source of truth.

**Verification:** awk parse returns `1.9.0`; all three YAML files parse; no
`LG_VERSION:` literals remain in `.github/workflows/`; a local bundle built with
mise `lg 1.9.0` contains `\x1b[1;31m` ×2 (0 bare) — correct, ESC-prefixed coloring.

**Second opinion:** `review-with-codex` (scope: uncommitted) reported no blocking
correctness issues.

**Notes / follow-ups:**
- No drift-check step was needed: with `.mise.toml` as the only declaration, there
  is nothing left to drift against.
- The authoritative end-to-end proof is the next tagged release; the local bundle
  check stands in for it here.
