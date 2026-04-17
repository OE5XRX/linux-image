# Security policy

## Supported versions

The `main` branch is the single supported version. Once a tagged
release line ages out (next major release tagged), the prior major
line is end-of-life — please upgrade.

## Reporting a vulnerability

**Please do not open public issues for security problems.**

Report privately via GitHub's Security Advisories feature:
<https://github.com/OE5XRX/linux-image/security/advisories/new>

or email the OE5XRX club at <oe5xrx@oevsv.at> with the subject line
`[SECURITY] linux-image: <short summary>`.

We try to respond within **7 days** and ship a fix within **30 days**
for anything exploitable remotely. Internal hardening issues (read-only
rootfs gaps, missing permission checks) may take longer.

## Scope

In scope:

- The Yocto image produced by this repo (`qemux86-64` and
  `raspberrypi4-64` targets)
- The build workflows and any scripts in `scripts/`
- Integration points with the
  [station-manager](https://github.com/OE5XRX/station-manager) server
  and the `station-agent` delivered via this image

Out of scope (report upstream):

- Linux kernel vulnerabilities → <https://lore.kernel.org/security/>
- Yocto / OpenEmbedded layer vulnerabilities → the relevant upstream
  project

## Release signing

Release artifacts (`*.wic`, `*.wic.bz2`) are signed with
[cosign keyless signatures](https://docs.sigstore.dev/cosign/overview/)
using the GitHub Actions OIDC identity of this repository. Each release
ships a `.sha256` checksum file and a `.bundle` cosign bundle alongside
the image.

Verify a downloaded image:

```bash
cosign verify-blob \
  --bundle image.wic.bundle \
  --certificate-identity-regexp 'https://github.com/OE5XRX/linux-image/\.github/workflows/release\.yml@refs/tags/v.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  image.wic
```

A matching checksum + a valid signature together prove the image was
built by our CI from this repo at the tagged commit, and hasn't been
modified since.
