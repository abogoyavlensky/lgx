# Landing Page Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-contained `index.html` landing page at the repo root that presents lgx as a polished, modern dev tool.

**Tech Stack:** Single HTML file; Tailwind CSS v4 browser build from CDN (`https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4`); Google Fonts (Inter, JetBrains Mono); a few lines of vanilla JS for copy buttons; inline SVG icons.

---

## Design

Light theme on white/near-white, emerald-teal accent, generous
whitespace, `rounded-xl`/`rounded-2xl` shapes, subtle `gray-200` borders
instead of heavy shadows. Quality comes from a realistic terminal mock
and tight typography, not decoration. Reference feel: bun.sh / vite.dev
front pages, but light and calmer.

Sections, top to bottom:

1. **Nav** — `lgx` wordmark in mono font; links to Features, Install,
   and a GitHub button. Sticky, white, subtle bottom border.
2. **Hero** — headline "The package and project manager for let-go";
   subhead "Git deps, runner, build tool, test runner, scaffolder, and
   task runner — in one binary"; copy-paste pill with
   `brew install abogoyavlensky/lgx/lgx` and a copy button; secondary
   "GitHub →" link.
3. **Terminal demo** — macOS-style terminal window showing the
   quickstart (`lgx new hello`, `cd hello`, `lgx run`) with plausible
   colored output. Static, no animation.
4. **Feature grid** — six cards: Git-based deps, Run & REPL, Standalone
   binaries (`lgx build`), Test runner, Project scaffolding (`lgx new`
   templates), Custom tasks & contexts. Each card: inline SVG icon,
   title, two-sentence description, tiny code snippet where it helps
   (e.g. a 4-line `lgx.edn` in the deps card).
5. **Install section** — three cards: Homebrew, mise, curl script, each
   with its command and a copy button. Note that `lg` (let-go) is
   required, linking to nooga/let-go.
6. **Footer** — MIT license, GitHub link, "built for let-go" link.

All commands, feature claims, and snippets must match the README — no
invented flags or output.

**Error handling:** none needed beyond the copy button silently
no-op'ing if the Clipboard API is unavailable.

**Testing:** open the file in a browser (agent-browser skill),
screenshot at desktop (~1440px) and mobile (~390px) widths, fix
anything broken. No automated tests.

## File Structure

- Create: `index.html` — the entire landing page (markup, Tailwind CDN
  script, copy-button JS).

## Implementation Steps

### Task 1: Build index.html

**Files:**
- Create: `index.html`

- [ ] **Step 1: Write the page skeleton**
  HTML5 document with meta description, title ("lgx — package and
  project manager for let-go"), Tailwind v4 browser-build CDN script,
  Google Fonts (Inter, JetBrains Mono), and the six sections from the
  design as empty landmarks (nav, header/hero, terminal demo, features,
  install, footer).

- [ ] **Step 2: Implement nav and hero**
  Sticky nav with mono `lgx` wordmark, anchor links to #features and
  #install, GitHub button linking to
  `https://github.com/abogoyavlensky/lgx`. Hero with headline, subhead,
  brew-install pill with copy button, secondary GitHub link.

- [ ] **Step 3: Implement the terminal demo**
  Rounded dark terminal card (the one dark element on the light page)
  with traffic-light dots, mono font, showing `lgx new hello` /
  `cd hello` / `lgx run` and plausible output consistent with the
  README (e.g. green `=>` status headers).

- [ ] **Step 4: Implement the feature grid**
  Six cards in a responsive grid (1 col mobile, 2 cols md, 3 cols lg)
  per the design list. Keep snippets accurate to the README.

- [ ] **Step 5: Implement install section and footer**
  Three install cards (Homebrew, mise, curl script) with exact commands
  from the README and copy buttons; the `lg` requirement note linking
  to `https://github.com/nooga/let-go`. Footer with MIT license,
  GitHub, and let-go links.

- [ ] **Step 6: Add copy-to-clipboard JS**
  One small script: every copy button copies its associated command via
  `navigator.clipboard.writeText`, swaps to a checkmark briefly, and
  does nothing if the API is missing.

### Task 2: Verify in a browser

**Files:**
- Modify: `index.html` (fixes only)

- [ ] **Step 1: Screenshot desktop**
  Open `index.html` via agent-browser at ~1440px width, screenshot the
  full page.
  Expected: all sections render, no overflow, terminal and cards look
  intentional.

- [ ] **Step 2: Screenshot mobile**
  Re-screenshot at ~390px width.
  Expected: nav collapses gracefully (links may hide; GitHub button
  stays), grid stacks to one column, commands wrap or scroll without
  breaking layout.

- [ ] **Step 3: Test copy buttons and fix issues**
  Click a copy button; confirm the checkmark feedback. Fix any layout
  or behavior problems found, then re-screenshot.
  Expected: clean page at both widths, working copy buttons.
