# Install script

One-liner - installs the latest release to `~/.local/bin/lgx`:

```sh
curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh | bash
```

## Options

Pin a version or change the install directory with env vars:

```sh
LGX_VERSION=0.1.0-alpha8 LGX_INSTALL_DIR=~/bin \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/abogoyavlensky/lgx/master/scripts/install.sh)"
```

Re-run the same command to upgrade in place. The script verifies each
archive against `checksums.txt`; read [`scripts/install.sh`](./scripts/install.sh)
before piping if you'd rather see what runs.

`lgx run` also needs `lg` on `PATH`. Install it via
[mise](https://mise.jdx.dev) (`mise use github:nooga/let-go`), Homebrew
(`brew install nooga/tap/let-go`), or grab a binary from
[let-go releases](https://github.com/nooga/let-go/releases).

## Homebrew formula generator

`generate-formula.sh` prints the Homebrew formula for a given release:

```sh
scripts/generate-formula.sh 0.1.0 checksums.txt > lgx.rb
```

It takes a version (no `v` prefix) and a release `checksums.txt`, and
fails if any of the four target checksums is missing. Release CI runs
it on every tag to update `Formula/lgx.rb` in
[homebrew-tap](https://github.com/abogoyavlensky/homebrew-tap) - don't
edit that file by hand.

## Or manually download latest release

If you'd rather skip the script entirely:

```sh
VERSION=0.1.0-alpha8
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o lgx.tar.gz \
  "https://github.com/abogoyavlensky/lgx/releases/download/v${VERSION}/lgx_${VERSION}_${OS}_${ARCH}.tar.gz"
tar -xzf lgx.tar.gz
install -m 0755 lgx ~/.local/bin/
```