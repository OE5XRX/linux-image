# Spec 4 — Public R2 sstate/downloads Mirror (retire the sshfs Storage Box)

**Status:** design draft, awaiting review
**Depends on:** Spec 1 (shared sstate/downloads mirror) + Spec 2 (ydev) + Spec 3 (cache hardening) — all merged to `main`.
**Spans two repos:** `linux-image` (build-side consumer) + `servers` (R2 bucket + Cloudflare infra, Terraform-managed).

## Goal

Replace the hand-rolled **sshfs-mounted Hetzner Storage Box** shared cache with a
**public, anonymous, read-only HTTP mirror on Cloudflare R2** (`sstate.oe5xrx.org`).
R2 becomes *the* cache: trusted builders (CI + the on-demand build server) **write**
via the S3 API with credentials; everyone — including external contributors and
Hackaday readers — **reads** anonymously over HTTPS. This kills the FUSE mount, the
network-write slowness, and the per-client SSH credentials, and moves us onto the
standard BitBake mirror pattern (`SSTATE_MIRRORS` + `SOURCE_MIRROR_URL`).

## Motivation

- **Public sharing is the explicit goal.** The Storage Box read path (sshfs, or its
  WebDAV) always needs Box credentials — you cannot hand that to the public. A public
  anonymous cache needs a credential-free HTTP(S) endpoint.
- **sshfs was the fiddly part** of Specs 1–3: FUSE mounts on every client, careful
  shared-write semantics, GB-clone-over-network incidents. A read-only HTTP mirror
  removes all of it. Writes are decoupled (few, trusted).
- **R2 is already core infra** (per `servers`): it holds the Terraform state backend
  **and** the restic backup target. Credentials, S3 tooling, and the Bitwarden secret
  pattern already exist. R2 is **not** a new vendor for us.
- **R2 has zero egress fees** + Cloudflare CDN edge caching — ideal for a read-mostly
  public blob store. Storage cost is ~$0.015/GB/mo (≈$0.30/mo at today's ~18 GB).
- This is the **standard Yocto pattern** — the Yocto Project itself publishes public
  sstate over HTTP. Shared-mutable-sstate over a network filesystem was the exotic bit.

## Key decisions

1. **R2 public bucket + custom domain** (`sstate.oe5xrx.org`), not an nginx server.
   No server to run/patch, no prod-VM disk pressure (the CX23 has only 40 GB), no
   network-mount in the serving path, fully Terraform-managed.
2. **Replace the Storage Box entirely** — do not keep it and mirror to R2. R2 is the
   single store. sshfs + `storage_box.tf` + the `oe5xrx-yocto-cache` Box secrets are
   retired (after R2 is proven — see Migration).
3. **Mirror both sstate and downloads** — public builders benefit from prebuilt
   objects *and* not having to re-hammer upstream source servers. Cost is negligible.
4. **Pruning via R2 lifecycle rules** (age-based expiry), replacing Spec 3's
   sshfs `cache-prune.sh`/`cache-prune.yml`. Accepted trade-off: an old-but-still-current
   sstate object may expire and be re-uploaded on the next build (cheap re-upload).
5. **Deferred, still: shared `bitbake-hashserv`.** Determinism stays as today
   (`BB_HASHSERVE = ""` + `BB_SIGNATURE_HANDLER = "OEBasicHash"`), which is what makes
   mirror objects match across builds. hashserv's marginal benefit does not justify an
   always-on server. Out of scope here too.

## Architecture

```
  CI (GH Actions) + CX43 build server              the world (anonymous)
        │  local SSTATE_DIR + DL_DIR                       │
        │  (no longer shared, no FUSE mount)               │
        │                                                  │
        ├── READ  ◄── SSTATE_MIRRORS / SOURCE_MIRROR_URL   │
        │            = https://sstate.oe5xrx.org/…  ───────┤ (R2 public,
        │                                                  │  CDN-cached)
        │                                                  ▲
        └── WRITE ──► rclone / aws s3 sync (R2 creds) ──► R2 bucket
                                                        oe5xrx-yocto-sstate
                                                        (public-read, custom domain)
```

- **No shared filesystem.** Each builder keeps its own local `SSTATE_DIR` and `DL_DIR`,
  reads misses read-only from R2, and a post-build publish step uploads new objects.
- **Read is credential-free.** `SSTATE_MIRRORS`/`SOURCE_MIRROR_URL` point at the public
  HTTPS URL; BitBake handles mirror misses gracefully (404 → build/fetch locally).
- **Write is credentialed and trusted-only.** Only CI + the build server hold the R2
  write token. The public cannot write (bucket is public-*read*).

## Components

### `linux-image` (build-side consumer)

**`oe5xrx.yml` `local_conf_header`** — the read config changes from a mount-conditional
`file://` mirror to a plain public HTTPS mirror. `SSTATE_DIR` is already local and stays.

*Today:*
```
DL_DIR ?= "${@'/mnt/yocto-shared/downloads' if os.path.ismount('/mnt/yocto-shared') else '${TOPDIR}/downloads'}"
SSTATE_DIR ?= "${TOPDIR}/sstate-cache"
SSTATE_MIRRORS ?= "${@'file://.* file:///mnt/yocto-shared/sstate/PATH;downloadfilename=PATH' if os.path.ismount('/mnt/yocto-shared') else ''}"
BB_HASHSERVE = ""
BB_SIGNATURE_HANDLER = "OEBasicHash"
BB_GIT_SHALLOW = "1"
```

*After:*
```
DL_DIR ?= "${TOPDIR}/downloads"
SSTATE_DIR ?= "${TOPDIR}/sstate-cache"
SSTATE_MIRRORS ?= "file://.* https://sstate.oe5xrx.org/sstate/PATH;downloadfilename=PATH"
# read-only public source mirror; own-mirrors keeps upstream as fallback
INHERIT += "own-mirrors"
SOURCE_MIRROR_URL ?= "https://sstate.oe5xrx.org/downloads/"
BB_HASHSERVE = ""              # unchanged — deterministic hashes = mirror matches
BB_SIGNATURE_HANDLER = "OEBasicHash"   # unchanged
BB_GIT_SHALLOW = "1"           # unchanged
```
No more `os.path.ismount` gymnastics — the mirror URL is always set; a miss is a miss.
Local dev with no network still builds (mirror misses fall through to upstream/local).

**Publish step (write path):** after a successful build, sync the local sstate +
downloads deltas to R2 via `rclone` (S3 backend) or `aws s3 sync`. Runs in:
- `build.yml` (CI), and
- the ydev on-demand build-server flow (Spec 2).

Credentials: an R2 access-key/secret from Bitwarden (mirroring restic's `RESTIC_R2_*`
→ `AWS_*` mapping in `servers`). Never in logs or CLI args; env-block only.

**Retire:** the sshfs mount steps in `build.yml`/ydev; the Spec 3 sshfs
`cache-prune.sh` + `cache-prune.yml` (replaced by R2 lifecycle, owned in `servers`).
The bump-bot + lockfiles (Spec 3) stay unchanged.

### `servers` (infrastructure, Terraform)

- **R2 bucket** `oe5xrx-yocto-sstate` with **public read** enabled.
- **Custom domain** `sstate.oe5xrx.org` bound to the bucket (Cloudflare R2 custom
  domain + DNS via the existing Terraform Cloudflare provider).
- **R2 API token** scoped to write this one bucket → stored in Bitwarden (new secret in
  a build-cache project) for CI + build-server pushes. Public read needs no token.
- **Lifecycle rule** — age-based object expiry (retention configurable, e.g. 60–90 d).
- **Retire** `terraform/storage_box.tf` and the `oe5xrx-yocto-cache` Storage Box
  secrets — *after* R2 is proven (see Migration).

All of this respects the `servers` cardinal rule (no manual VM changes — everything via
Terraform/workflows) and its gates (tf-plan replace-guard, `production` environment
reviewers, Copilot loop, squash-merge).

## Migration & sequencing (safety-critical)

The Storage Box must not be deleted until R2 is proven, or a bad cutover means cold
builds with no cache. Order:

1. **`servers` PR #1 — stand up R2 (Box stays alive):** create bucket, public custom
   domain, lifecycle rule, write token in Bitwarden. One-time **seed** the existing
   cache Box → R2 via `rclone` so the first post-cutover build is warm.
2. **`linux-image` PR — cut over to R2:** switch `oe5xrx.yml` to the HTTPS mirror,
   remove sshfs mounts, add the R2 publish step, retire the sshfs prune. Merge only
   after a green x86 + RPi build proves R2 read+write works end-to-end.
3. **`servers` PR #2 — remove the Box:** delete `storage_box.tf` + the Box secrets once
   `linux-image` `main` builds cleanly off R2. (Kept as a separate PR so the teardown is
   a deliberate, reviewed step, not coupled to the cutover.)

## Trust & security

- **Public sstate = consumers trust our prebuilt binaries** (opt-in, exactly as the
  Yocto Project's public sstate). For *us* there is no risk: the bucket is public-read,
  only our CI/build-server writes. A malicious downloader cannot poison the cache.
- **Write token** is least-privilege (single bucket, write) and lives only in Bitwarden
  → CI/build-server env. Losing it means cache writes, never state/backups (separate R2
  tokens, per `servers` namespacing rules).
- **No PII / secrets in sstate/downloads** — they are build artifacts and public source
  tarballs. Safe to expose. (Sanity check during implementation that no signing keys or
  tokens leak into DL_DIR — none expected.)

## Cost

- Storage: ~$0.015/GB/mo → ≈$0.30/mo now, grows with the cache; lifecycle caps growth.
- **Egress: $0** (R2). Public downloads are free.
- Class-A (write) + Class-B (read) operations: pennies; many small sstate objects mean
  many Class-B reads, still negligible and CDN-cached at the edge. Worth watching but not
  a blocker.
- Net: comparable to or cheaper than the Storage Box, and within the project's ~€4.30/mo
  ethos.

## Out of scope (deferred)

- Shared `bitbake-hashserv` (still not worth the always-on cost given determinism).
- CDN cache-tuning / signed URLs / access analytics.
- Mirroring for other repos' build artifacts — this is the Yocto image cache only.

## Open / to resolve during implementation

- **Exact `SSTATE_MIRRORS`/`SOURCE_MIRROR_URL` URL layout** and whether sstate and
  downloads share one bucket under `/sstate/` + `/downloads/` prefixes (assumed) or two
  buckets. One bucket + prefixes is the default.
- **Publish tool** — `rclone` (S3 remote to R2) vs `aws s3 sync`. Pick one; `rclone`
  handles many-small-objects well and is easy to pin.
- **Lifecycle retention window** (60 vs 90 days) and whether a light "keep newest per
  object" nicety is worth any scripting, or pure age-expiry is accepted (default: pure
  age).
- **Bitwarden project** for the R2 write creds — reuse/rename `oe5xrx-yocto-cache` vs a
  fresh `oe5xrx-yocto-sstate` project.
- **ydev interaction** — confirm the on-demand build-server publish step and the local
  dev "read public mirror, no push" path both behave.

## Cross-cutting

- **CI green** in both repos: `yamllint`/`shellcheck` (new scripts/workflows), Terraform
  validate/plan (servers). Commit subjects imperative ≤72 chars; end with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; squash-merge; **one PR per
  repo** (two total, plus the `servers` teardown follow-up = three coordinated PRs).
- **Docs:** update `linux-image/docs/dev-shared-cache.md` (R2 mirror, publish flow,
  lifecycle) and add an R2-cache note to `servers` docs.

## Implementation order (for the plan)

1. **`servers`** — R2 bucket + public custom domain + lifecycle + write token (Box stays).
   Seed Box → R2. *(Infra first; everything else reads/writes it.)*
2. **`linux-image`** — `oe5xrx.yml` mirror cutover + publish step + remove sshfs + retire
   sshfs prune; build-validate x86 + RPi off R2 (human gate, as in Spec 3).
3. **`servers`** — retire `storage_box.tf` + Box secrets once R2 is proven.
4. **Docs** in both repos.
