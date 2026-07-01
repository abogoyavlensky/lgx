# Homebrew depends_on let-go Implementation Plan

> **Status: COMPLETED** (2026-07-01). See summary at the end.

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `brew install abogoyavlensky/tap/lgx` install let-go (`lg`) automatically via a cross-tap `depends_on`, and update every doc that told users to install let-go by hand.

**Tech Stack:** Homebrew formula (Ruby), bash, Markdown, static HTML.

---

## Design

### Context

When the tap was first set up (see `docs/plans/2026-06-12-homebrew-install.md`),
the lgx formula could not declare a dependency on let-go: nooga shipped
let-go as a **cask** in a non-conventional tap, and Homebrew formulae
can't depend on casks, which also don't work on Linux. So the formula
fell back to a `caveats` note telling users to install `lg` themselves.

That has changed. nooga now ships **`nooga/homebrew-tap` →
`Formula/let-go.rb`** — a real *formula* (class `LetGo`, installs the
`lg` binary, with `on_macos` and `on_linux` Intel/ARM blocks). Because
the tap follows the conventional `homebrew-<name>` name, `nooga/tap`
resolves to it and `brew install nooga/tap/let-go` works on both
platforms. That makes a cross-tap `depends_on "nooga/tap/let-go"` valid.

With the dependency in place, installing lgx via Homebrew pulls in
let-go automatically and puts `lg` on `PATH` — so the old "you still
need lg" caveat becomes false, and the manual install instructions can
be simplified to the single `brew install nooga/tap/let-go` command
wherever a *manual* let-go install is still relevant (mise / install
script / release binary users).

### Scope

**lgx repo only.** The tap's `Formula/lgx.rb` is generated output; it is
**not** edited by hand here. Release CI regenerates it from
`scripts/generate-formula.sh` on the next tagged release, and Andrey
verifies the full `brew install` integration from that release. This
plan changes the generator (the single source of truth) plus the docs.

### Key decisions

- **`depends_on "nooga/tap/let-go"`, plain string, no version pin.**
  Homebrew is rolling-release and does not support `>=` constraints on
  formula dependencies; the latest let-go clears the 1.11.0 floor.
  Homebrew auto-taps `nooga/tap` when resolving the dependency.
- **Remove the `caveats` block entirely.** The dependency guarantees
  `lg` is installed and on `PATH`, so the caveat is now inaccurate
  noise. The 1.11.0 floor stays documented in the README Requirements
  for non-Homebrew installs.
- **`depends_on` placement:** after the `livecheck` block, before
  `on_macos` — the standard Homebrew component order that
  `brew style` (`FormulaAudit/ComponentsOrder`) enforces.
- **Landing callout distinguishes Homebrew from the others.** The
  "Requires let-go" callout covers all three install methods, but only
  Homebrew auto-installs let-go. The rewrite says so explicitly instead
  of claiming auto-install globally.

### Verification strategy

`brew style` is the same gate the generator was validated against
originally. Generate the formula from a placeholder checksums fixture
into a temp `.rb` and run `brew style` on it — style checks Ruby
structure, not sha content, so placeholder shas are fine. Also confirm
by eye that the generated output contains `depends_on "nooga/tap/let-go"`
and no longer contains a `caveats` block.

### Out of scope / follow-up

- `homebrew-tap/README.md` still has a stale manual let-go line
  (`lg >= 1.10.0` + the old `brew tap … && brew install let-go`
  command). Leave it to the release flow; it can be fixed with a
  one-line commit to the tap repo post-release so its docs match the
  live formula. Not part of this plan.

## File Structure

All in `/Users/andrew/Projects/lgx`:

- Modify: `scripts/generate-formula.sh` — add `depends_on`, drop
  `caveats`. Single source of truth for the formula.
- Modify: `README.md` — Requirements + Homebrew install section.
- Modify: `scripts/README.md` — simplify the manual let-go command.
- Modify: `scripts/install.sh` — simplify the manual let-go command in
  the post-install help text.
- Modify: `landing/index.html` — rewrite the "Requires let-go" callout.

---

## Tasks

### Task 1: Add `depends_on` and drop `caveats` in the generator

**Files:**
- Modify: `scripts/generate-formula.sh`

- [x] **Step 1: Edit the formula heredoc**
  In the `cat <<EOF` formula template:
  - Between the `livecheck do … end` block and `on_macos do`, add a line:
    `  depends_on "nooga/tap/let-go"` (2-space indent, blank line above
    and below). NOTE: `brew style`'s `FormulaAudit/ComponentsOrder`
    requires `depends_on` *before* `on_macos`, not after `on_linux`.
  - Delete the entire `def caveats … end` block (currently between
    `def install … end` and `test do`), including the blank line that
    separated it.

- [x] **Step 2: Generate a formula from a placeholder fixture**
  Create a throwaway checksums file, then generate:
  ```sh
  scratch=$(mktemp -d)
  for t in darwin_amd64 darwin_arm64 linux_amd64 linux_arm64; do
    printf '%064d  lgx_9.9.9_%s.tar.gz\n' 0 "$t" >> "$scratch/checksums.txt"
  done
  bash scripts/generate-formula.sh 9.9.9 "$scratch/checksums.txt" > "$scratch/lgx.rb"
  cat "$scratch/lgx.rb"
  ```
  Expected: complete formula containing `depends_on "nooga/tap/let-go"`
  and **no** `def caveats`.

- [x] **Step 3: Style-check the generated formula**
  Run: `brew style "$scratch/lgx.rb"`
  Expected: no offenses. Generate the file under a `Formula/`
  subdirectory (`$scratch/Formula/lgx.rb`) so `brew style` applies the
  formula ruleset — styling a bare `.rb` outside a tap fires spurious
  Sorbet/FrozenStringLiteral cops that don't apply to formulae. Passed
  with 0 offenses.

- [x] **Step 4: Clean up the scratch dir**
  Run: `rm -rf "$scratch"`

### Task 2: Update lgx repo docs

**Files:**
- Modify: `README.md`
- Modify: `scripts/README.md`
- Modify: `scripts/install.sh`

Use /writing-clearly for the prose edits.

- [x] **Step 1: README Requirements section**
  In the `## Requirements` `lg` bullet, replace the manual install line
  (`Install with brew tap nooga/let-go … && brew install let-go`) with
  wording that: notes installing lgx via Homebrew pulls let-go in
  automatically, and gives the simplified manual command
  `brew install nooga/tap/let-go` for other installs. Keep the
  `>= 1.11.0` floor and the `*command-line-args*` note.

- [x] **Step 2: README Homebrew install section**
  In `## Installation → ### Homebrew`, replace "This installs lgx only;
  `lg` still needs to be on `PATH` …" with one sentence stating brew
  pulls in let-go (`lg`) automatically as a dependency — nothing else to
  install.

- [x] **Step 3: scripts/README.md**
  In the "`lgx run` also needs `lg`" paragraph, replace the Homebrew
  command `brew tap nooga/let-go https://github.com/nooga/let-go &&
  brew install let-go` with `brew install nooga/tap/let-go`. Leave the
  mise and release-binary options unchanged.

- [x] **Step 4: scripts/install.sh help text**
  In the post-install `cat <<EOF` block, change the Homebrew line from
  `  Homebrew: brew tap nooga/let-go https://github.com/nooga/let-go && brew install let-go`
  to `  Homebrew: brew install nooga/tap/let-go`.

- [x] **Step 5: Verify no stale command remains in the lgx repo**
  Run: `grep -rn "brew tap nooga/let-go" README.md scripts/`
  Expected: no matches.

### Task 3: Rewrite the landing "Requires let-go" callout

**Files:**
- Modify: `landing/index.html`

- [x] **Step 1: Edit the callout paragraph**
  In the `#install` section's emerald callout (the `<p>` after the
  install-method grid), replace the inner text so it reads (keeping the
  existing `<a>` to let-go and the `<code>` tags):
  > **Requires let-go.** lgx drives the [lg] binary (≥ 1.11.0). Homebrew
  > installs it for you; with mise or the script, add `lg` to your
  > `PATH`. Plus `git`, for fetching deps.

  Keep the `<strong>`, the `lg` link, and `<code class="font-mono">`
  wrappers on `lg`, `PATH`, and `git`. Do not change the surrounding
  `<p>` classes or layout.

- [x] **Step 2: Sanity-check the markup**
  Run: `grep -n "Homebrew installs it for you" landing/index.html`
  Expected: one match; confirm the `<a>`/`<code>` tags are balanced by
  eye.

### Task 4: Review and commit

- [x] **Step 1: Review the full diff**
  Run: `git -C /Users/andrew/Projects/lgx diff --stat && git -C /Users/andrew/Projects/lgx diff`
  Expected: only the five files above; generator diff is exactly
  `+depends_on` and the removed `caveats` block. Confirmed. Also ran
  `review-with-codex` (uncommitted scope) — clean, no findings.

- [x] **Step 2: Branch and commit**
  Master is the default branch, so branch first:
  ```sh
  git switch -c homebrew-depends-on-let-go
  git add scripts/generate-formula.sh README.md scripts/README.md scripts/install.sh landing/index.html \
    docs/plans/2026-07-01-homebrew-depends-on-let-go.md
  git commit -m "Install let-go automatically via Homebrew depends_on"
  ```
  (The plan doc is included in the commit alongside the five source
  files, since its checkbox/summary updates are part of this work.)

---

## Completion summary (2026-07-01)

All four tasks done. `brew install abogoyavlensky/tap/lgx` will now install
let-go automatically once the change reaches the tap via the next release.

- **Generator** (`scripts/generate-formula.sh`): added
  `depends_on "nooga/tap/let-go"` and removed the `caveats` block. The
  generated formula passes `brew style` with 0 offenses.
- **Docs** (`README.md`, `scripts/README.md`, `scripts/install.sh`): brew
  now pulls in let-go automatically; the *manual* let-go command was
  simplified to `brew install nooga/tap/let-go` for mise/script/manual
  users. No `brew tap nooga/let-go …` string remains in the repo.
- **Landing** (`landing/index.html`): the "Requires let-go" callout now
  distinguishes Homebrew (auto) from mise/script (manual).

Deviation from the plan, found during execution:

- **`depends_on` placement.** The plan assumed *after* the `on_linux`
  block; `brew style`'s `FormulaAudit/ComponentsOrder` actually requires
  it *before* `on_macos` (after `livecheck`). Fixed and re-verified. The
  plan's Task 1 Step 1 and the Key-decisions note were corrected to match.
- **`brew style` context.** Styling a bare `.rb` outside a tap fires
  spurious `Sorbet`/`FrozenStringLiteral` cops; generating the file under
  a `Formula/` subdirectory applies the formula ruleset and yields 0
  offenses.

Left to the release flow (as planned): the tap's `Formula/lgx.rb` is
regenerated by release CI, and `homebrew-tap/README.md`'s stale manual
let-go line can be fixed with a one-line commit to the tap repo
post-release. Andrey will verify the full `brew install` integration from
the next release.
