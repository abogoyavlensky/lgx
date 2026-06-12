#!/usr/bin/env bash
# Install lgx from GitHub Releases on Linux or macOS.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
#
# Env:
#   LGX_VERSION      tag to install (default: latest stable, e.g. 0.1.0)
#   LGX_INSTALL_DIR  install path (default: ~/.local/bin)

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

REPO="abogoyavlensky/lgx"
INSTALL_DIR="${LGX_INSTALL_DIR:-$HOME/.local/bin}"

err() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '> %s\n' "$*"; }

command -v curl >/dev/null 2>&1 || err "curl is required"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)

case "$os" in
  linux|darwin) ;;
  *) err "unsupported OS: $os (try mise: https://mise.jdx.dev)" ;;
esac

case "$arch" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) err "unsupported arch: $arch (try mise or build from source)" ;;
esac

target="${os}_${arch}"

if [ -n "${LGX_VERSION:-}" ]; then
  version="${LGX_VERSION#v}"
else
  log "resolving latest release..."
  url=$(curl -sSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest")
  case "$url" in
    */releases/tag/v*) version="${url##*/tag/v}" ;;
    */releases/tag/*)  version="${url##*/tag/}"  ;;
    *) err "no published release found; set LGX_VERSION (e.g. LGX_VERSION=0.1.0)" ;;
  esac
fi

archive="lgx_${version}_${target}.tar.gz"
base="https://github.com/${REPO}/releases/download/v${version}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "downloading lgx ${version} for ${os}/${arch}..."
curl -fsL -o "$tmp/$archive" "$base/$archive" \
  || err "version ${version} not found (asset ${archive})"
curl -fsL -o "$tmp/checksums.txt" "$base/checksums.txt" \
  || err "could not fetch checksums.txt for ${version}"

log "verifying checksum..."
(cd "$tmp" && grep " ${archive}\$" checksums.txt | shasum -a 256 -c -) \
  >/dev/null \
  || err "checksum verification failed for ${archive}"

tar -xzf "$tmp/$archive" -C "$tmp"

mkdir -p "$INSTALL_DIR" \
  || err "cannot create ${INSTALL_DIR}; set LGX_INSTALL_DIR to a writable path"
install -m 0755 "$tmp/lgx" "$INSTALL_DIR/lgx" \
  || err "cannot write to ${INSTALL_DIR}; set LGX_INSTALL_DIR to a writable path"

log "installed: ${INSTALL_DIR}/lgx"

case ":${PATH}:" in
  *:"${INSTALL_DIR}":*) ;;
  *)
    printf '\nnote: %s is not on PATH. add to your shell rc:\n' "$INSTALL_DIR"
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
    ;;
esac

cat <<EOF

\`lgx run\` also requires \`lg\` on PATH. install it via:
  mise:     mise use -g github:nooga/let-go
  Homebrew: brew tap nooga/let-go https://github.com/nooga/let-go && brew install let-go
  manual:   https://github.com/nooga/let-go/releases
EOF
