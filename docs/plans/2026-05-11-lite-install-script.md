# `scripts/install.sh` — curl|bash installer for lgx

## Context

lgx ships binaries on every GitHub Release (four targets: linux/darwin
× amd64/arm64) plus a `checksums.txt`. Today the only "no mise" install
path is a hand-written `curl | tar | mv` snippet in the README. We want
the classic one-liner that deno/bun/rustup ship — fewer instructions
for the user, one URL to remember.

Scope is deliberately narrow: install lgx only (lg has its own
distribution paths), no in-script PATH editing, no `--upgrade` flag,
no extras beyond a working binary in `$LGX_INSTALL_DIR`.

## UX

Published one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
```

Env knobs (both optional):

| Var               | Default                          |
|-------------------|----------------------------------|
| `LGX_VERSION`     | latest stable (redirect-resolved)|
| `LGX_INSTALL_DIR` | `~/.local/bin`                   |

Pre-release case (current state — only `v0.1.0-alpha1` exists):
`LGX_VERSION=0.1.0-alpha1 curl -fsSL ... | bash`.

Re-running the script with the same `LGX_INSTALL_DIR` overwrites the
binary in place — that's the upgrade/downgrade path. Same model as
deno/bun.

## Script anatomy

`scripts/install.sh`, `bash`-targeted, `set -euo pipefail`. ~80 lines.

1. **Re-exec under bash** if invoked as `sh install.sh`.
2. **Detect OS/arch** with `uname`. Normalize to `linux_amd64`,
   `linux_arm64`, `darwin_amd64`, `darwin_arm64`. Anything else →
   exit 1 with a hint pointing at mise or "build from source".
3. **Resolve version.** `LGX_VERSION` wins; otherwise `curl -sIL
   https://github.com/abogoyavlensky/lgx/releases/latest` and parse
   the final `location:` header for `…/releases/tag/v<X.Y.Z>`.
   No GitHub API call, no token, no rate limit. If the redirect
   doesn't land on a tag (no stable release yet) → error suggesting
   `LGX_VERSION=…`.
4. **Download** archive + `checksums.txt` into `mktemp -d`. Trap
   `EXIT` to clean up.
5. **Verify** with `shasum -a 256 -c` (portable across macOS and
   Linux). Abort on mismatch.
6. **Install** with `install -m 0755 lgx "$LGX_INSTALL_DIR/lgx"`.
   Atomic + perm-setting in one step; safe to overwrite a running
   binary on Unix.
7. **PATH advisory.** If `$LGX_INSTALL_DIR` isn't on `$PATH`, print
   the exact `export PATH=...` line. Never edit dotfiles.
8. **lg hint** at the end: let-go releases page, mise
   (`mise use github:nooga/let-go`), and Homebrew
   (`brew install --formula https://raw.githubusercontent.com/nooga/let-go/main/HomebrewFormula/let-go.rb`).

## Edge cases

- Missing `curl` → fail early with a clear message.
- Unsupported platform (windows/musl/armv7/i386) → error with
  pointer to mise / build-from-source.
- 404 on the archive URL (typo'd `LGX_VERSION`) → "version X not
  found".
- Checksum mismatch → show expected/actual, exit 1.
- Non-writable `$LGX_INSTALL_DIR` → suggest overriding it.

## README changes

Replace the body of `### Manual download` with three blocks:

1. The one-liner.
2. The same one-liner using `bash -c "$(...)"` to show env-var
   override syntax.
3. The existing portable `curl | tar | install` snippet, framed as
   "if you'd rather not pipe shell".

Embed the lg-install hint between (2) and (3): mise + Homebrew
+ releases page.

## Testing

- Manual: run on Linux (host machine) — happy path + bad
  `LGX_VERSION`.
- `shellcheck scripts/install.sh` clean.
- No CI job; the script is small enough that drift will be obvious
  on review.

## Out of scope

- `lg` installation.
- Auto-upgrade / `lgx upgrade` subcommand (re-running install.sh
  covers it).
- Editing user shell rc files.
- Windows / musl / 32-bit support.
- `LGX_INSTALL_DIR` defaulting to anywhere other than `~/.local/bin`.
