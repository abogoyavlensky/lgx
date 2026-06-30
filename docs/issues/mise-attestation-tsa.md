# Issue: attestation verification fails on GitHub's rotated TSA cert

**Repo:** [jdx/mise](https://github.com/jdx/mise)

**Status:** open; worked around in this repo via `.mise.toml`
(`[settings] github_attestations = false`)

## Summary

`mise install` fails GitHub artifact-attestation verification for `lg`
1.11.0 and later, aborting the install with:

```
GitHub artifact attestations verification error ...: Sigstore error:
Verification error: TSA timestamp verification failed: Failed to verify
timestamp signature: no certificate matches issuer and serial number
```

GitHub rotated its internal timestamp-authority (TSA) certificate in late
June 2026. mise's bundled Sigstore trusted root predates the rotation, so it
lacks the new certificate and cannot verify any attestation timestamped after
that date. This is a stale verifier, not a bad release.

## Why this is not a let-go problem

let-go's release pipeline defines no signing or attestation config - none in
`.goreleaser.yml`, none in the release workflow, none in its history. The
attestations come from GitHub **immutable releases** (every let-go release
reports `immutable: true`), which attach build-provenance attestations
automatically. The maintainer neither configures nor signs them.

Each attestation carries an RFC 3161 timestamp from GitHub's TSA
(`O=GitHub, Inc., CN=TSA intermediate`). The timestamp token embeds no
certificate, so the verifier must already hold the TSA leaf certificate in its
trusted root and match it by issuer and serial. When the serial is missing, the
verifier reports "no certificate matches issuer and serial number".

## Evidence

Two let-go releases, installed on the same machine with the same mise. Only the
TSA serial that signed the timestamp differs:

| Release | Date       | TSA leaf serial                            | Result   |
|---------|------------|--------------------------------------------|----------|
| 1.10.0  | 2026-06-08 | `1E2963486F4DC7F41FFE03E997B575932461FE36` | verifies |
| 1.11.0  | 2026-06-28 | (rotated)                                  | fails    |
| 1.11.1  | 2026-06-29 | `1733DBD6E9FE0EFA1FA853F3017881E6C9473352` | fails    |

mise 2026.6.14 shipped on 2026-06-25, three days before the rotated TSA first
appeared (1.11.0, 2026-06-28). Its trusted root holds the first serial but not
the second, so every release timestamped after the rotation fails.

## Reproduction

```
mise install lg@1.10.0 --force   # verifies
mise install lg@1.11.1 --force   # fails with the error above
```

Read the TSA serial straight from a release's attestation:

```
gh release download v1.11.1 --repo nooga/let-go \
  --pattern '*linux_arm64.tar.gz' -O art.tgz
dig="sha256:$(sha256sum art.tgz | cut -d' ' -f1)"
gh api repos/nooga/let-go/attestations/$dig \
  | jq -r '.attestations[0].bundle.verificationMaterial
           .timestampVerificationData.rfc3161Timestamps[0].signedTimestamp' \
  | base64 -d | openssl asn1parse -inform DER | grep -A2 'TSA intermediate'
```

## Expected

mise should verify attestations signed by GitHub's current TSA: refresh the
Sigstore trusted root from TUF at verification time, or ship an updated bundled
root. A newer mise built after the rotation should resolve this on its own.

## Workaround (applied here)

Disable only the GitHub attestation check. Checksum and SLSA provenance still
run, so artifact integrity stays verified:

```toml
# .mise.toml
[settings]
github_attestations = false
```

Per-command equivalent: `MISE_GITHUB_ATTESTATIONS=0 mise install`.

Remove the setting once a newer mise ships a trusted root that includes the
rotated TSA certificate.
