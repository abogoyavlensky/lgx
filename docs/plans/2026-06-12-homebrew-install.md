# Homebrew Installation Implementation Plan

> **Status: COMPLETED** (2026-06-12). See summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make lgx installable with a single command — `brew install abogoyavlensky/lgx/lgx` — on macOS and Linux, with the tap formula updated automatically on every release.

**Tech Stack:** Homebrew formula (Ruby), bash, GitHub Actions.

---

## Design

### Context

- lgx releases already attach prebuilt tarballs for all four targets
  (`darwin_amd64`, `darwin_arm64`, `linux_amd64`, `linux_arm64`) plus
  `checksums.txt` to each GitHub Release. Tarball name:
  `lgx_<version>_<target>.tar.gz`, containing a single `lgx` binary at
  the archive root. Latest release: `v0.1.0-rc1`.
- The tap repo `abogoyavlensky/homebrew-lgx` exists (local checkout at
  `/Users/andrew/Projects/homebrew-lgx`) and contains only a stub
  `README.md`. It follows the `homebrew-<name>` convention, so
  `brew install abogoyavlensky/lgx/lgx` auto-taps it.
- **No let-go dependency.** lgx requires `lg` >= 1.10.0 on PATH at
  runtime, but nooga ships let-go as a *cask* inside the main
  `nooga/let-go` repo (non-conventional tap name, not auto-tappable;
  formulae can't depend on casks; casks don't work on Linux). Decision:
  the formula surfaces the requirement via `caveats` only. If nooga
  later publishes a proper formula tap, `lgx.rb` can add a real
  cross-tap `depends_on`.

### Components

**1. Formula (`Formula/lgx.rb` in homebrew-lgx)** — a binary formula:
no compilation, downloads the release tarball for the user's
OS/architecture. Shape:

```ruby
class Lgx < Formula
  desc "Package and project manager for the let-go Clojure dialect"
  homepage "https://github.com/abogoyavlensky/lgx"
  license "MIT"
  version "0.1.0-rc1"

  on_macos do
    on_intel do
      url "https://github.com/abogoyavlensky/lgx/releases/download/v#{version}/lgx_#{version}_darwin_amd64.tar.gz"
      sha256 "<sha256 of darwin_amd64 tarball>"
    end
    on_arm do
      # darwin_arm64 url + sha256
    end
  end

  on_linux do
    on_intel do
      # linux_amd64 url + sha256
    end
    on_arm do
      # linux_arm64 url + sha256
    end
  end

  livecheck do
    skip "Formula is updated by lgx release CI"
  end

  def install
    bin.install "lgx"
  end

  def caveats
    <<~EOS
      lgx requires the let-go compiler (lg >= 1.10.0) on PATH.
      On macOS:
        brew tap nooga/let-go https://github.com/nooga/let-go && brew install let-go
      On Linux (and other options): https://github.com/abogoyavlensky/lgx#requirements
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/lgx --version")
  end
end
```

`lgx --version` prints `lgx <version>` and works without `lg` installed
(`lgx.lg:523`), so the `test do` block is self-contained.

**2. Generator script (`scripts/generate-formula.sh` in lgx)** — single
source of truth for the formula text. Takes a version (no `v` prefix)
and a path to a release `checksums.txt`, prints the complete formula to
stdout. Lives in the lgx repo so formula generation is versioned with
the release pipeline and runnable locally. `checksums.txt` format is
`sha256sum` output, e.g.:

```
0a2279d72e7b...  lgx_0.1.0-rc1_darwin_amd64.tar.gz
```

The script fails (non-zero exit, message to stderr) if any of the four
target checksums is missing from the file.

**3. CI auto-update (new `homebrew` job in `.github/workflows/release.yml`)** —
runs after the `release` job on every tag push:

1. `gh release download "$TAG" -p checksums.txt` from the just-published
   release.
2. `bash scripts/generate-formula.sh "${TAG#v}" checksums.txt > lgx.rb`.
3. Clone `abogoyavlensky/homebrew-lgx` using a PAT, write
   `Formula/lgx.rb`, commit `lgx <version>`, push. Skip the commit if
   the formula is unchanged (idempotent re-runs).

The tap updates on **every** tag, including `-rc`/`-alpha` — matching
how releases are published today (rc1 is marked Latest).

**4. Auth (manual step)** — a fine-grained PAT scoped to only the
`homebrew-lgx` repo with Contents read/write, stored as the
`HOMEBREW_TAP_TOKEN` secret in the lgx repo.

### Error handling

- Generator: exits non-zero with a clear message on missing args,
  missing checksums file, or a missing target line.
- CI job: `set -euo pipefail`; a missing `HOMEBREW_TAP_TOKEN` or failed
  push fails the `homebrew` job visibly without affecting the published
  release (job runs after `release`).
- Formula: Homebrew verifies sha256 on download; `caveats` covers the
  missing-`lg` case.

### Testing strategy

- Generate the bootstrap formula from the real `v0.1.0-rc1`
  `checksums.txt` and check it contains the expected version, URLs, and
  all four sha256s.
- `brew style` the generated formula (brew is available locally).
- End-to-end on Linux: `brew install --formula ./Formula/lgx.rb`, then
  `lgx --version` and `brew test lgx`.
- macOS verification by Andrey after the tap is pushed:
  `brew install abogoyavlensky/lgx/lgx`.
- The CI path proves itself on the next tagged release.

## File Structure

In `/Users/andrew/Projects/lgx`:

- Create: `scripts/generate-formula.sh` — emits the formula from
  version + checksums.
- Modify: `.github/workflows/release.yml` — add `homebrew` job.
- Modify: `scripts/README.md` — document the generator script.
- Modify: `README.md` — add Homebrew to the Installation section.

In `/Users/andrew/Projects/homebrew-lgx`:

- Create: `Formula/lgx.rb` — bootstrap formula for `v0.1.0-rc1`.
- Modify: `README.md` — install instructions, lg note, how the tap is
  updated.

---

## Tasks

### Task 1: Formula generator script

**Files:**
- Create: `scripts/generate-formula.sh`
- Modify: `scripts/README.md`

- [x] **Step 1: Write the script**
  `scripts/generate-formula.sh VERSION CHECKSUMS_FILE` prints the
  formula (shape in Design §Components.1) to stdout. Follow
  `scripts/install.sh` style: `#!/usr/bin/env bash`, `set -euo
  pipefail`, `err()` helper, usage comment at top. Extract each
  target's sha256 with `awk '$2 == "lgx_'"$version"'_'"$target"'.tar.gz" { print $1 }'`;
  `err` if empty. Hardcode the four targets in order: darwin_amd64,
  darwin_arm64, linux_amd64, linux_arm64. Make it executable
  (`chmod +x`).

- [x] **Step 2: Run against real release checksums**
  Run:
  ```sh
  gh release download v0.1.0-rc1 -p checksums.txt -O /tmp/lgx-checksums.txt --clobber
  bash scripts/generate-formula.sh 0.1.0-rc1 /tmp/lgx-checksums.txt
  ```
  Expected: complete formula on stdout; contains `version "0.1.0-rc1"`,
  four download URLs, and these sha256s:
  `0a2279d72e7b791185d4b630c80fa613bfb8b562e0ffedfe2d1af5e8d1c3e3fe` (darwin_amd64),
  `029a8752c378048de18221466309b3ae3693caf82dcc0c0af7fef8f4827dde57` (darwin_arm64),
  `67aa759cd07de8949a5594fa8765db477ae9357c9ca6ccfaf57f7c5529b59aaf` (linux_amd64),
  `ae0cb79975e14be6ba941d1ce68127089093fbdcd636a91234914231291c926f` (linux_arm64).

- [x] **Step 3: Verify error handling**
  Run: `bash scripts/generate-formula.sh 9.9.9 /tmp/lgx-checksums.txt; echo "exit=$?"`
  Expected: non-zero exit, error naming the first missing target.
  Also run with no args; expected: non-zero exit, usage message.

- [x] **Step 4: Document in scripts/README.md**
  Add a short section: purpose, usage line, note that release CI runs
  it to update the tap.

- [x] **Step 5: Commit**
  `git commit -m "Add Homebrew formula generator script"`

### Task 2: Bootstrap the tap with the v0.1.0-rc1 formula

**Files (in `/Users/andrew/Projects/homebrew-lgx`):**
- Create: `Formula/lgx.rb`
- Modify: `README.md`

- [x] **Step 1: Generate the formula**
  Run from `/Users/andrew/Projects/lgx`:
  ```sh
  mkdir -p /Users/andrew/Projects/homebrew-lgx/Formula
  bash scripts/generate-formula.sh 0.1.0-rc1 /tmp/lgx-checksums.txt \
    > /Users/andrew/Projects/homebrew-lgx/Formula/lgx.rb
  ```

- [x] **Step 2: Style-check the formula**
  Run: `brew style /Users/andrew/Projects/homebrew-lgx/Formula/lgx.rb`
  Expected: no offenses. If brew flags style issues, fix them in the
  *generator script* (Task 1) and regenerate — the .rb file is build
  output.

- [x] **Step 3: Install end-to-end on Linux**
  Run:
  ```sh
  brew install --formula /Users/andrew/Projects/homebrew-lgx/Formula/lgx.rb
  lgx --version
  ```
  Expected: install succeeds with the lg caveat printed;
  `lgx --version` prints `lgx 0.1.0-rc1`. Then clean up:
  `brew uninstall lgx`.

- [x] **Step 4: Write the tap README**
  Replace the stub `README.md`: what the tap is, install command
  (`brew install abogoyavlensky/lgx/lgx`), the lg requirement with
  nooga's tap command, and a note that `Formula/lgx.rb` is
  auto-generated by lgx release CI (do not edit by hand). Use
  /writing-clearly.

- [x] **Step 5: Commit and push the tap**
  In `/Users/andrew/Projects/homebrew-lgx`:
  ```sh
  git add Formula/lgx.rb README.md
  git commit -m "Add lgx formula for v0.1.0-rc1"
  git push origin master
  ```
  Expected: push succeeds. If push is rejected (auth), surface to
  Andrey rather than retrying.

### Task 3: Auto-update job in release workflow

**Files:**
- Modify: `.github/workflows/release.yml`

- [x] **Step 1: Add the `homebrew` job**
  After the `release` job, add:
  ```yaml
  homebrew:
    needs: [release]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Update Homebrew formula
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
          TAG: ${{ github.ref_name }}
        run: |
          set -euo pipefail
          version="${TAG#v}"
          gh release download "$TAG" --repo "$GITHUB_REPOSITORY" -p checksums.txt -O checksums.txt
          git clone "https://x-access-token:${TAP_TOKEN}@github.com/abogoyavlensky/homebrew-lgx.git" tap
          mkdir -p tap/Formula
          bash scripts/generate-formula.sh "$version" checksums.txt > tap/Formula/lgx.rb
          cd tap
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Formula/lgx.rb
          git diff --cached --quiet && { echo "formula unchanged"; exit 0; }
          git commit -m "lgx ${version}"
          git push
  ```

- [x] **Step 2: Validate workflow syntax**
  Run: `actionlint .github/workflows/release.yml` if available,
  otherwise check YAML parses:
  `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))"`.
  Expected: no errors.

- [x] **Step 3: Commit**
  `git commit -m "Update Homebrew tap formula on release"`

### Task 4: PAT secret (manual, Andrey)

**Files:** none.

- [x] **Step 1: Document and hand off**
  Tell Andrey to create a fine-grained PAT at
  https://github.com/settings/personal-access-tokens/new with:
  Resource owner `abogoyavlensky`, repository access **only**
  `abogoyavlensky/homebrew-lgx`, permission Contents: Read and write,
  expiration of his choice. Then store it:
  `gh secret set HOMEBREW_TAP_TOKEN --repo abogoyavlensky/lgx`.
  The `homebrew` CI job fails without it; everything else in this plan
  works regardless.

### Task 5: Document Homebrew install in lgx README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Add Homebrew subsection**
  In `## Installation`, add `### Homebrew` as the **first** method
  (before "Install script"):
  ```sh
  brew install abogoyavlensky/lgx/lgx
  ```
  One sentence: works on macOS and Linux; note that `lg` still needs to
  be installed (link to Requirements). Use /writing-clearly.

- [x] **Step 2: Commit**
  `git commit -m "Document Homebrew installation"`

### Task 6: Final verification

- [x] **Step 1: Install from the pushed tap on Linux**
  Run:
  ```sh
  brew install abogoyavlensky/lgx/lgx
  lgx --version
  brew test lgx
  ```
  Expected: auto-taps `abogoyavlensky/lgx`, installs, prints
  `lgx 0.1.0-rc1`, test passes.

- [x] **Step 2: Hand off macOS check to Andrey**
  Ask Andrey to run `brew install abogoyavlensky/lgx/lgx` on his Mac.
  The CI auto-update path gets proven on the next tagged release —
  no action needed now.

---

## Completion summary (2026-06-12)

All six tasks done. `brew install abogoyavlensky/lgx/lgx` verified
end-to-end on Linux against the pushed GitHub tap: auto-tap, install,
`lgx --version` -> `lgx 0.1.0-rc1`, `brew test` pass.

Deviations from the plan, found during execution:

- **Homebrew 6 rejects `brew install --formula <path>`** (formulae must
  live in a tap). Task 2 verification instead committed the formula in
  the tap repo and used `brew tap abogoyavlensky/lgx <local path>` +
  `brew trust`. Also needed `HOMEBREW_NO_SANDBOX_LINUX=1` in this
  environment (nested sandbox, no bubblewrap).
- **`brew style` requires `livecheck` before `on_macos`** - generator
  fixed (commit `a1b64aa`).
- **`brew audit` rejects an explicit `version` stanza** as redundant
  when the version is scannable from the URL. The generator now emits
  literal versioned URLs and no `version` stanza; brew infers
  `0.1.0-rc1` correctly (commit `aaa42e1`, tap commit `3864846`).
- Fixed a stale claim in `scripts/README.md` (`brew install
  nooga/let-go/let-go` doesn't work - non-conventional tap needs the
  explicit-URL `brew tap` form).

Outstanding (manual, Andrey):

- Create a fine-grained PAT (repo access: only
  `abogoyavlensky/homebrew-lgx`, Contents read/write) and store it:
  `gh secret set HOMEBREW_TAP_TOKEN --repo abogoyavlensky/lgx`.
  Without it the `homebrew` release job fails (release itself is
  unaffected).
- Verify `brew install abogoyavlensky/lgx/lgx` on macOS.
- The CI auto-update path proves itself on the next tagged release.
