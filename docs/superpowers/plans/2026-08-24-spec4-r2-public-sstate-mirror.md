# Spec 4 — Public R2 sstate/downloads Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sshfs-mounted Hetzner Storage Box shared Yocto cache with a public, anonymous, read-only Cloudflare R2 HTTP mirror (`sstate.oe5xrx.org`); trusted builders publish via the S3 API.

**Architecture:** R2 becomes the single cache. CI + the on-demand build server **write** new sstate/downloads objects to an R2 bucket via `rclone` (S3, credentialed); everyone — including the public — **reads** anonymously over HTTPS via `SSTATE_MIRRORS`/`SOURCE_MIRROR_URL`. Each builder keeps a *local* `SSTATE_DIR`/`DL_DIR`; there is no shared filesystem and no FUSE mount. This is the standard BitBake mirror pattern.

**Tech Stack:** Cloudflare R2 (S3-compatible) + `cloudflare_r2_*` Terraform resources (provider `~> 5.0`), BitBake `SSTATE_MIRRORS`/`SOURCE_MIRROR_URL`/`own-mirrors`, `rclone`, GitHub Actions, kas, Bitwarden `bws`, sshfs (removed).

**Spec:** `docs/superpowers/specs/2026-08-24-spec4-r2-public-sstate-mirror-design.md`

## Two repos, three PRs — read first

This plan spans **two repositories** and executes as **three coordinated PRs in strict order**. An SDD executor works one repo/worktree at a time; do the phases in order, each as its own PR:

- **Phase A → repo `servers`** (`~/OE5XRX/servers`): stand up R2 (bucket + public custom domain + lifecycle + write creds). The Storage Box stays alive.
- **Phase B → repo `linux-image`** (`~/OE5XRX/linux-image`): cut the build over to R2; remove sshfs; retire the Spec-3 prune. Ends in a **[HUMAN] build gate**.
- **Phase C → repo `servers`**: retire the Storage Box — **only after Phase B is proven on `main`**.

Each task is tagged `(servers)` or `(linux-image)`. Never delete the Box (Phase C) before a green R2 build exists (Phase B gate).

## Global Constraints

- **Cloudflare account/R2 endpoint (servers):** account ID `cef6b7278fa23b4970442ce3a1dfcb32`, EU jurisdiction, S3 endpoint `https://cef6b7278fa23b4970442ce3a1dfcb32.eu.r2.cloudflarestorage.com`. TF providers: `cloudflare/cloudflare ~> 5.0`, `terraform >= 1.8.0`.
- **Bucket + domain names:** bucket `oe5xrx-yocto-sstate`, public custom domain `sstate.oe5xrx.org`, zone via `var.cloudflare_zone_id`, account via `var.cloudflare_account_id`.
- **Lifecycle retention: 365 days** (age-based `delete_objects_transition`, builds are infrequent).
- **Bitwarden:** reuse the existing project `oe5xrx-yocto-cache`. New R2 write secrets `R2_SSTATE_KEY` + `R2_SSTATE_SECRET` (S3 access-key + secret from a dashboard-created R2 API token, scoped Object Read & Write on this one bucket). Secret keys match `^[A-Z][A-Z0-9_]*$`. Machine account (`BWS_ACCESS_TOKEN`) keeps **read**. The old `STORAGE_BOX_*` secrets stay until Phase C.
- **Read config (linux-image):** `SSTATE_MIRRORS = "file://.* https://sstate.oe5xrx.org/sstate/PATH;downloadfilename=PATH"`; `SOURCE_MIRROR_URL = "https://sstate.oe5xrx.org/downloads/"` with `INHERIT += "own-mirrors"`; `DL_DIR`/`SSTATE_DIR` local. Keep `BB_HASHSERVE = ""`, `BB_SIGNATURE_HANDLER = "OEBasicHash"`, `BB_GIT_SHALLOW = "1"` unchanged.
- **Publish object layout:** local `sstate-cache/` → R2 `sstate/`; local `downloads/` → R2 `downloads/`. One bucket, two prefixes.
- **Secret handling:** R2 creds via `bws` → job `env:` only, never CLI args or logs; mask before writing to `$GITHUB_ENV`; validate single-line. (Mirrors restic's `RESTIC_R2_*` → `AWS_*` pattern.)
- **Conventions:** commit subjects imperative ≤72 chars; end every commit with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; squash-merge; one PR per repo. `servers` gates: tf-plan replace-guard, `production` environment reviewers, Copilot loop. `linux-image` gates: CI (yamllint/shellcheck/validate/sim-harness) green + Copilot loop.
- **`servers` cardinal rule:** no manual VM/infra changes outside Terraform/workflows/cloud-init. All R2 infra is Terraform; the only hand steps are the dashboard R2-token creation + Bitwarden entry, captured in a runbook.

---

## PHASE A — `servers`: stand up R2 (Box stays alive)

### Task A1: Operator runbook — R2 token perms + write creds in Bitwarden (servers)

The Terraform `cloudflare_r2_*` resources need the CF API token to carry R2 edit rights, and the build-side push needs an S3 access-key/secret. Both are one-time dashboard actions; capture them in a runbook so they are reproducible and done **before** the first apply of Task A2.

**Files:**
- Create: `docs/yocto-cache-r2-mirror.md`

- [ ] **Step 1: Write the bootstrap runbook**

Create `docs/yocto-cache-r2-mirror.md` with exactly these operator steps:

```markdown
# Public R2 sstate Mirror — Bootstrap Runbook

One-time operator steps BEFORE the first `terraform apply` of the R2 mirror
(Spec 4). Mirrors the Storage Box runbook's style.

## 1. Cloudflare API token (Terraform) — add R2 edit
The Terraform token (`CLOUDFLARE_API_TOKEN` GH secret / `var.cloudflare_api_token`)
must include **Account › Workers R2 Storage › Edit**. Cloudflare dashboard →
My Profile → API Tokens → edit the oe5xrx Terraform token → add that permission.
Without it, `terraform apply` fails creating the bucket/custom-domain/lifecycle.

## 2. R2 write token (build-side push, S3 creds)
Cloudflare dashboard → R2 → Manage R2 API Tokens → Create API token:
- Permissions: **Object Read & Write**
- Scope: **only** bucket `oe5xrx-yocto-sstate` (create it first in Task A2, or
  scope to the account and tighten later).
- Copy the **Access Key ID** and **Secret Access Key** (shown once).

## 3. Bitwarden (project `oe5xrx-yocto-cache`, reused)
Add two secrets to the existing project:
- `R2_SSTATE_KEY`    = the R2 token Access Key ID
- `R2_SSTATE_SECRET` = the R2 token Secret Access Key
The machine account (`BWS_ACCESS_TOKEN`) already has read on this project.
Leave the `STORAGE_BOX_*` secrets in place until Phase C (Box teardown).

## 4. Public read
No secret. Public anonymous read is served by the R2 **custom domain**
`sstate.oe5xrx.org` (Task A2). The bucket itself stays private to the S3 API.
```

- [ ] **Step 2: Commit**

```bash
git add docs/yocto-cache-r2-mirror.md
git commit -m "docs(yocto-cache): R2 mirror bootstrap runbook (token + bws)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 3: Human handoff note**

This task's deliverable is the runbook; the operator performs steps 1–3 before Task A2's apply lands. The reviewer confirms the runbook is complete and matches the secret names used in Task A2/B2 (`R2_SSTATE_KEY`, `R2_SSTATE_SECRET`).

---

### Task A2: Terraform — R2 bucket + public custom domain + lifecycle (servers)

Create the bucket, bind the public custom domain, and set 365-day age expiry — all as Terraform, mirroring the repo's existing Cloudflare provider wiring.

**Files:**
- Create: `terraform/r2_sstate.tf`
- Reference (do not edit): `terraform/versions.tf` (provider `~> 5.0`), `terraform/main.tf` (`provider "cloudflare"`), `terraform/variables.tf` (`cloudflare_account_id`, `cloudflare_zone_id`)

**Interfaces:**
- Consumes: `var.cloudflare_account_id`, `var.cloudflare_zone_id` (already defined).
- Produces: bucket `oe5xrx-yocto-sstate` reachable read-only at `https://sstate.oe5xrx.org/` (consumed by Phase B's `SSTATE_MIRRORS`).

- [ ] **Step 1: Confirm the exact v5 resource schemas**

The provider is `cloudflare/cloudflare ~> 5.0`. Confirm the argument names before writing HCL (custom-domain arg names in particular):

```bash
cd terraform
terraform init -upgrade
terraform providers schema -json \
  | jq '.provider_schemas[].resource_schemas
        | {b: .cloudflare_r2_bucket.block.attributes|keys,
           d: .cloudflare_r2_custom_domain.block.attributes|keys,
           l: .cloudflare_r2_bucket_lifecycle.block.attributes|keys}'
```
Expected: `cloudflare_r2_bucket` → `account_id,name,location,storage_class`; `cloudflare_r2_custom_domain` → includes `account_id,bucket_name,domain,zone_id,enabled` (± `min_tls`); `cloudflare_r2_bucket_lifecycle` → `account_id,bucket_name,rules`. If a name differs, use the schema's name in Step 2.

- [ ] **Step 2: Write `terraform/r2_sstate.tf`**

```hcl
# Public, read-only Yocto sstate/downloads mirror on Cloudflare R2 (Spec 4).
# Trusted builders (linux-image CI + the on-demand build server) write via the
# S3 API with an R2 token (Bitwarden oe5xrx-yocto-cache: R2_SSTATE_KEY/SECRET).
# The public reads anonymously over HTTPS at the custom domain below — that
# custom domain IS the public-read path; the bucket stays private to the S3 API.
# Spec: linux-image/docs/superpowers/specs/2026-08-24-spec4-r2-public-sstate-mirror-design.md

resource "cloudflare_r2_bucket" "yocto_sstate" {
  account_id    = var.cloudflare_account_id
  name          = "oe5xrx-yocto-sstate"
  location      = "eeur" # EU jurisdiction, matches the tfstate/backup buckets
  storage_class = "Standard"
}

# Binding a custom domain publishes the bucket read-only at that hostname and
# creates the proxied DNS record in the zone. This is the anonymous public URL.
resource "cloudflare_r2_custom_domain" "yocto_sstate" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.yocto_sstate.name
  domain      = "sstate.oe5xrx.org"
  zone_id     = var.cloudflare_zone_id
  enabled     = true
}

# Age-based expiry: 365 days. Builds are infrequent; storage is cheap and R2
# egress is free, so retention is long. An expired-but-still-current object is
# simply re-uploaded on the next build.
resource "cloudflare_r2_bucket_lifecycle" "yocto_sstate" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.yocto_sstate.name

  rules = [{
    id      = "expire-after-365d"
    enabled = true
    conditions = { prefix = "" }
    delete_objects_transition = {
      condition = { type = "Age", max_age = 31536000 } # 365 * 24 * 3600
    }
  }]
}
```
If Step 1 showed different attribute names/shapes (e.g. `rules` as blocks not a list), adapt to the schema output — the values (names, `eeur`, 365d=31536000s, `enabled=true`) stay.

- [ ] **Step 3: Validate + plan**

```bash
cd terraform && terraform validate && echo "validate OK"
```
Expected: `Success! The configuration is valid.` A full `terraform plan` runs in CI with creds; locally `validate` is the gate (apply is CI-only, per repo convention).

- [ ] **Step 4: Commit**

```bash
git add terraform/r2_sstate.tf
git commit -m "feat(terraform): public R2 sstate mirror bucket + domain + lifecycle

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: (post-merge, operator) confirm public read**

After the PR merges and CI applies, verify the domain serves (empty bucket → 404 is fine, TLS must be valid):
```bash
curl -sSI https://sstate.oe5xrx.org/ | head -3   # expect an HTTP response + valid cert
```

---

### Task A3: Seed the existing cache Box → R2 (servers)

One-time copy so the first post-cutover build is warm, not cold. Runs from an operator machine (or the build server) that can reach both the Storage Box (SFTP) and R2 (S3). Documented + scripted; not a recurring workflow.

**Files:**
- Create: `scripts/seed-sstate-r2.sh`

- [ ] **Step 1: Write the seed helper**

```bash
#!/usr/bin/env bash
# One-time seed of the shared Yocto cache from the Storage Box to R2 (Spec 4).
# Reads Box over SFTP, writes R2 over S3 (rclone). Idempotent (rclone copy skips
# equal objects) — safe to re-run. Requires rclone + the two remotes configured
# via env (no config file needed).
set -euo pipefail

: "${BOX_HOST:?set BOX_HOST (STORAGE_BOX_HOST)}"
: "${BOX_USER:?set BOX_USER (STORAGE_BOX_USER)}"
: "${BOX_KEY:?set BOX_KEY (path to the Storage Box private key)}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"
: "${R2_KEY:?set R2_KEY (R2_SSTATE_KEY)}"
: "${R2_SECRET:?set R2_SECRET (R2_SSTATE_SECRET)}"
BUCKET="${BUCKET:-oe5xrx-yocto-sstate}"

export RCLONE_CONFIG_BOX_TYPE=sftp
export RCLONE_CONFIG_BOX_HOST="$BOX_HOST"
export RCLONE_CONFIG_BOX_USER="$BOX_USER"
export RCLONE_CONFIG_BOX_PORT=23
export RCLONE_CONFIG_BOX_KEY_FILE="$BOX_KEY"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_KEY"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_REGION=auto

echo "== seeding sstate =="
rclone copy --transfers 16 --checkers 32 box:sstate     "R2:${BUCKET}/sstate"
echo "== seeding downloads =="
rclone copy --transfers 16 --checkers 32 box:downloads  "R2:${BUCKET}/downloads"
echo "seed complete"
```

- [ ] **Step 2: Shellcheck**

```bash
shellcheck -e SC1091 scripts/seed-sstate-r2.sh && echo "shellcheck OK"
```
Expected: OK.

- [ ] **Step 3: Commit**

```bash
git add scripts/seed-sstate-r2.sh
git commit -m "feat(scripts): one-time Storage Box -> R2 cache seed helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Human handoff**

The operator runs `scripts/seed-sstate-r2.sh` once (Box creds + `R2_SSTATE_*` from Bitwarden) after Task A2 is applied and before Phase B's build gate. Reviewer confirms the script references the agreed bucket/prefix layout (`sstate/`, `downloads/`).

> **Phase A gate:** bucket live, `https://sstate.oe5xrx.org/` responds with a valid cert, seed run complete. The Storage Box is untouched. Proceed to Phase B.

---

## PHASE B — `linux-image`: cut over to R2 (+ [HUMAN] build gate)

### Task B1: Point `oe5xrx.yml` at the R2 mirror (linux-image)

Swap the mount-conditional `file://` mirror for the public HTTPS mirror; make `DL_DIR` local and add a read-only source mirror. Determinism knobs stay.

**Files:**
- Modify: `oe5xrx.yml:50-74` (the shared build cache block)

- [ ] **Step 1: Replace the cache block**

Replace lines 50–74 (from the `# Shared build cache` comment through `BB_GIT_SHALLOW = "1"`) with:

```
    # Public read-only build cache on Cloudflare R2 (Spec 4:
    # 2026-08-24-spec4-r2-public-sstate-mirror). Anyone reads anonymously over
    # HTTPS; trusted builders (CI + build server) publish new objects via the
    # S3 API after the build (see build.yml / ydev remote-build). No shared
    # filesystem, no sshfs — SSTATE_DIR/DL_DIR are LOCAL.
    DL_DIR ?= "${TOPDIR}/downloads"
    SSTATE_DIR ?= "${TOPDIR}/sstate-cache"
    SSTATE_MIRRORS ?= "file://.* https://sstate.oe5xrx.org/sstate/PATH;downloadfilename=PATH"
    # Read-only public source premirror; own-mirrors keeps upstream as fallback.
    INHERIT += "own-mirrors"
    SOURCE_MIRROR_URL ?= "https://sstate.oe5xrx.org/downloads/"
    # Deterministic task hashes so mirror objects match ACROSS builds. Default
    # hash-equivalence (BB_HASHSERVE "auto") computes per-build unihashes that
    # never line up with a mirror populated by another build. A shared hashserv
    # was evaluated and deferred (marginal benefit vs always-on cost).
    BB_HASHSERVE = ""
    BB_SIGNATURE_HANDLER = "OEBasicHash"
    # Shallow git fetch: only the lockfile-pinned commit, not full history.
    BB_GIT_SHALLOW = "1"
```

- [ ] **Step 2: Verify both kas configs still parse**

```bash
source ~/OE5XRX/.kas-venv/bin/activate
kas dump qemux86-64.yml >/dev/null && echo "x86 parse OK"
kas dump raspberrypi4-64.yml >/dev/null && echo "rpi parse OK"
grep -q 'sstate.oe5xrx.org/sstate' oe5xrx.yml && echo "mirror set OK"
! grep -q '/mnt/yocto-shared' oe5xrx.yml && echo "mount refs gone OK"
```
Expected: all four OK lines.

- [ ] **Step 3: Commit**

```bash
git add oe5xrx.yml
git commit -m "feat(cache): read sstate/downloads from public R2 mirror

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B2: CI build.yml — drop sshfs, add R2 publish (linux-image)

Remove the Storage Box cred-fetch + sshfs mount + cache-wipe, and replace the rsync-to-box push with an `rclone` push to R2. Reads now come from `oe5xrx.yml`'s HTTPS mirror; only the *publish* needs creds.

**Files:**
- Modify: `.github/workflows/build.yml` — remove lines 148–183 (bws Storage Box fetch), 222–286 (sshfs mount + wipe), 353–367 (rsync push); add an R2 publish step.

**Interfaces:**
- Consumes: Bitwarden `oe5xrx-yocto-cache` secrets `R2_SSTATE_KEY`, `R2_SSTATE_SECRET` (Task A1); build output dirs `build/sstate-cache/` + `build/downloads/`.
- Produces: objects under `sstate/` and `downloads/` in R2.

- [ ] **Step 1: Remove the Storage Box cred-fetch + sshfs mount + wipe steps**

Delete these three step-blocks (identified in the Spec-4 exploration):
- "Fetch Storage Box creds from Bitwarden" (`build.yml:148-183`)
- "Mount shared Yocto cache (Storage Box) on build server" (`build.yml:222-264`)
- the conditional sstate wipe (`build.yml:266-286`)

Local `SSTATE_DIR`/`DL_DIR` now come from `oe5xrx.yml` — no mount needed. If the build server needs `rclone`, install it in the build step's provisioning (Step 2 adds it in the publish step).

- [ ] **Step 2: Replace the rsync push with an R2 publish step**

Replace the "Push sstate delta to shared mirror" step (`build.yml:353-367`) with a publish step that fetches R2 creds via `bws` and pushes both prefixes. Use the repo's existing bws-install pattern; keep secrets in `env:` only:

```yaml
      - name: Publish sstate + downloads to R2 mirror
        if: always()
        env:
          BWS_ACCESS_TOKEN: ${{ secrets.BWS_ACCESS_TOKEN }}
          BWS_SERVER_URL: ${{ secrets.BWS_SERVER_URL }}
          R2_ACCOUNT_ID: cef6b7278fa23b4970442ce3a1dfcb32
        run: |
          set -euo pipefail
          export BWS_SERVER_URL="${BWS_SERVER_URL:-https://vault.bitwarden.eu}"
          PID=$(bws project list -o json | jq -r '.[]|select(.name=="oe5xrx-yocto-cache")|.id')
          [ -n "$PID" ] || { echo "::error::bws project oe5xrx-yocto-cache not found"; exit 1; }
          S=$(bws secret list -p "$PID" -o json)
          R2_KEY=$(jq -r '.[]|select(.key=="R2_SSTATE_KEY")|.value' <<<"$S")
          R2_SECRET=$(jq -r '.[]|select(.key=="R2_SSTATE_SECRET")|.value' <<<"$S")
          [ -n "$R2_KEY" ] && [ -n "$R2_SECRET" ] || { echo "::error::R2_SSTATE_* missing"; exit 1; }
          echo "::add-mask::$R2_KEY"; echo "::add-mask::$R2_SECRET"
          command -v rclone >/dev/null || { curl -fsSL https://rclone.org/install.sh | sudo bash; }
          export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare
          export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_KEY"
          export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET"
          export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com"
          export RCLONE_CONFIG_R2_REGION=auto
          rclone copy --transfers 16 --checkers 32 build/sstate-cache/ R2:oe5xrx-yocto-sstate/sstate  || echo "::warning::sstate publish failed"
          rclone copy --transfers 16 --checkers 32 build/downloads/    R2:oe5xrx-yocto-sstate/downloads || echo "::warning::downloads publish failed"
```
(`rclone copy` uploads only new/changed objects — the read-only-public bucket is never a build blocker: a failed publish warns, it does not fail the build.)

- [ ] **Step 3: Lint the workflow**

```bash
yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable, comments-indentation: disable, indentation: {check-multi-line-strings: false}}}' .github/workflows/build.yml && echo "yamllint OK"
```
Expected: OK. (If `actionlint` is available in CI, ensure no `${{ }}` appears inside `run:` bash comments — repo gotcha.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "feat(ci): publish cache to R2, drop sshfs Storage Box mount

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B3: ydev — strip sshfs, publish to R2 (linux-image)

The ydev dev-loop (Spec 2) mounts the Box on the laptop and on the on-demand build server, and pushes via rsync. Remove all sshfs; the remote build publishes to R2 (like CI); local dev just reads the public mirror (no mount, no creds).

**Files (all under repo root):**
- Modify: `scripts/ydev/remote-up.sh` (remove bws fetch + sshfs mount, lines ~75-96)
- Modify: `scripts/ydev/remote-build.sh` (replace rsync push, lines 26-27, with R2 `rclone copy`)
- Modify: `scripts/ydev/remote-status.sh` (drop the mount check, line 9)
- Modify: `scripts/ydev/local-build.sh` (remove `mirror_mounted` guard, line 7)
- Modify: `scripts/ydev/doctor.sh` (drop sshfs + STORAGE_BOX_* checks, lines 11,15-19; optionally add an R2 reachability check)
- Modify: `scripts/ydev/lib.sh` (remove `MIRROR_MNT` + `mirror_mounted()`, lines 4,21-24)
- Modify: `scripts/ydev/init.sh` (drop Storage Box instruction, line 10)
- Modify: `.env.example` (remove `STORAGE_BOX_*`, lines 3-5)
- Modify: `local.just` (remove `mount`/`umount` recipes, lines 4-10)
- Delete: `scripts/ydev/local-mount.sh`, `scripts/ydev/local-umount.sh`
- Delete: `tests/ydev/test_local_mount.sh`

- [ ] **Step 1: Replace the remote-build push with R2 publish**

In `scripts/ydev/remote-build.sh`, replace the rsync push (lines 26-27):
```bash
sudo -u yocto rsync -a --no-owner --no-group --no-perms --ignore-existing \
  /home/yocto/src/build/sstate-cache/ /mnt/yocto-shared/sstate/ || true
```
with an rclone publish using the same R2 env the remote box already receives from `remote-up.sh` (see Step 2):
```bash
sudo -u yocto env \
  RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_SSTATE_KEY" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SSTATE_SECRET" \
  RCLONE_CONFIG_R2_ENDPOINT="https://cef6b7278fa23b4970442ce3a1dfcb32.eu.r2.cloudflarestorage.com" \
  RCLONE_CONFIG_R2_REGION=auto \
  rclone copy --transfers 16 --checkers 32 \
    /home/yocto/src/build/sstate-cache/ R2:oe5xrx-yocto-sstate/sstate || true
```

- [ ] **Step 2: Rework `remote-up.sh`**

In `scripts/ydev/remote-up.sh`: remove the `sshfs` install + mount + write-test (lines ~86-96) and the Box `scp` of the key. Change the Bitwarden fetch (lines ~75-83) to pull `R2_SSTATE_KEY`/`R2_SSTATE_SECRET` (instead of `STORAGE_BOX_*`), install `rclone` on the box (`curl -fsSL https://rclone.org/install.sh | sudo bash`), and export the two R2 vars into the remote build env consumed by Step 1. No FUSE, no `/mnt/yocto-shared`.

- [ ] **Step 3: Strip the remaining sshfs references**

Apply these concrete removals:
- `scripts/ydev/remote-status.sh:9` — delete the `mountpoint -q /mnt/yocto-shared` line.
- `scripts/ydev/local-build.sh:7` — delete the `mirror_mounted || die_hint …` guard (local builds read the public mirror directly).
- `scripts/ydev/lib.sh` — delete `MIRROR_MNT=...` (line 4) and the `mirror_mounted()` function (lines 21-24).
- `scripts/ydev/doctor.sh` — delete the `sshfs`, `STORAGE_BOX_HOST`, `STORAGE_BOX_USER`, `box key` checks (lines 11,15-19).
- `scripts/ydev/init.sh:10` — replace the Storage Box message with: `echo "ydev: wrote .env — local builds read the public R2 mirror; run: just doctor"`.
- `.env.example:3-5` — delete the three `STORAGE_BOX_*` lines.
- `local.just:4-10` — delete the `mount` and `umount` recipes.
- `git rm scripts/ydev/local-mount.sh scripts/ydev/local-umount.sh tests/ydev/test_local_mount.sh`

- [ ] **Step 4: Verify no sshfs/box refs remain in ydev**

```bash
! grep -rnE 'sshfs|/mnt/yocto-shared|STORAGE_BOX|mirror_mounted' scripts/ydev local.just remote.just .env.example tests/ydev 2>/dev/null && echo "ydev clean OK"
bash -n scripts/ydev/*.sh && echo "syntax OK"
shellcheck -e SC1091 -e SC2039 scripts/ydev/*.sh && echo "shellcheck OK"
```
Expected: `ydev clean OK`, `syntax OK`, `shellcheck OK`.

- [ ] **Step 5: Commit**

```bash
git add -A scripts/ydev local.just remote.just .env.example tests/ydev
git commit -m "feat(ydev): read/publish via R2, remove sshfs Storage Box path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B4: Retire the Spec-3 sshfs prune (linux-image)

R2 lifecycle rules (Task A2) replace the cron prune. Remove the sshfs prune script + workflow and drop it from the shellcheck list.

**Files:**
- Delete: `scripts/cache-prune.sh`, `.github/workflows/cache-prune.yml`
- Modify: `.github/workflows/ci.yml:46` (remove `scripts/cache-prune.sh` from the shellcheck list)

- [ ] **Step 1: Remove the script + workflow**

```bash
git rm scripts/cache-prune.sh .github/workflows/cache-prune.yml
```

- [ ] **Step 2: Drop it from the shellcheck list**

In `.github/workflows/ci.yml`, delete the `scripts/cache-prune.sh \` line from the "Lint shell scripts" step (line 46). Ensure the preceding line's trailing `\` still forms a valid command (the line before `cache-prune.sh` becomes the last argument, no trailing backslash).

- [ ] **Step 3: Verify ci.yml lints clean**

```bash
yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable, comments-indentation: disable, indentation: {check-multi-line-strings: false}}}' .github/workflows/ci.yml && echo "yamllint OK"
! grep -q 'cache-prune' .github/workflows/ci.yml && echo "prune ref gone OK"
```
Expected: both OK.

- [ ] **Step 4: Commit**

```bash
git add -A .github/workflows/ci.yml
git commit -m "chore(cache): retire sshfs prune (R2 lifecycle replaces it)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B5: Docs — rewrite the shared-cache guide for R2 (linux-image)

**Files:**
- Modify: `docs/dev-shared-cache.md`

- [ ] **Step 1: Update the doc**

Rewrite the shared-cache doc to describe the R2 model: public read via `SSTATE_MIRRORS`/`SOURCE_MIRROR_URL` at `https://sstate.oe5xrx.org`; local `SSTATE_DIR`/`DL_DIR`; publish via `rclone` in CI + ydev remote-build with `R2_SSTATE_*` from Bitwarden `oe5xrx-yocto-cache`; 365-day R2 lifecycle (no more `cache-prune.sh`); no sshfs, no Storage Box. Remove Storage Box / sshfs / `cache-prune` sections. Note the retained Spec-3 pieces (per-machine lockfiles, bump-bot, `BB_GIT_SHALLOW`).

- [ ] **Step 2: Sanity-check references**

```bash
! grep -nE 'sshfs|/mnt/yocto-shared|cache-prune|Storage Box' docs/dev-shared-cache.md && echo "doc clean OK"
grep -q 'sstate.oe5xrx.org' docs/dev-shared-cache.md && echo "R2 documented OK"
```
Expected: both OK.

- [ ] **Step 3: Commit**

```bash
git add docs/dev-shared-cache.md
git commit -m "docs(cache): document the public R2 mirror model

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B6: [HUMAN] Build-validate off R2 — GATE (linux-image)

**Not a subagent task.** A human runs real builds; the controller pauses here. This proves R2 read + publish work end-to-end before the Box can be retired (Phase C). Config-parse checks (B1) don't catch mirror-fetch or publish failures.

- [ ] **Step 1: Confirm public read works**

```bash
curl -sSI https://sstate.oe5xrx.org/ | head -3   # valid TLS, HTTP response
```

- [ ] **Step 2: x86 build reads the mirror + publishes**

Trigger `gh workflow run build.yml -f machine=qemux86-64` (or `just local build`). Expected: the build pulls sstate objects over `https://sstate.oe5xrx.org/sstate/...` (watch the log for setscene mirror hits, not full rebuilds); the "Publish … to R2" step uploads new objects (no fatal error); QEMU boots to login. Record the `linux-yocto` version (should still be a 6.18.x).

- [ ] **Step 3: RPi build off R2**

Trigger `gh workflow run build.yml -f machine=raspberrypi4-64`. Expected: build succeeds reading/publishing via R2; `linux-raspberrypi` ~6.18.x; no version-selection failure.

- [ ] **Step 4: Confirm objects landed in R2**

After a build, spot-check the bucket has grown (via dashboard, or `rclone size R2:oe5xrx-yocto-sstate`). A second build should be faster (warm R2 reads).

- [ ] **Step 5: Decision gate**

- Read hits + publish + both builds boot/succeed → **pass.** Phase B PR merges to `linux-image` `main`. Proceed to Phase C.
- Mirror not read (all cold rebuilds), publish fails, or a build breaks → **stop**: fix before merge; do **not** start Phase C (the Box is still the live fallback).

---

## PHASE C — `servers`: retire the Storage Box (only after Phase B is proven)

### Task C1: Remove the Storage Box + its secrets (servers)

**Precondition:** `linux-image` `main` builds cleanly off R2 (Phase B gate passed). Removing `hcloud_storage_box` is destructive but safe — the cache now lives in R2; nothing mounts the Box.

**Files:**
- Delete: `terraform/storage_box.tf`
- Modify: `terraform/variables.tf` (remove `storage_box_password`, `storage_box_ssh_pubkey`, lines ~73-82)
- Modify: `terraform/outputs.tf` (remove `storage_box_host`, `storage_box_user`, lines ~27-35)
- Delete: `.github/actions/fetch-storage-box-secrets/action.yml`
- Modify: `.github/workflows/main.yml` (remove the two `fetch-storage-box-secrets` uses at ~180-184 and ~296-300)

- [ ] **Step 1: Remove the Terraform resource, variables, outputs**

```bash
git rm terraform/storage_box.tf .github/actions/fetch-storage-box-secrets/action.yml
```
Then delete the `storage_box_password` + `storage_box_ssh_pubkey` variable blocks from `terraform/variables.tf` and the `storage_box_host` + `storage_box_user` output blocks from `terraform/outputs.tf`.

- [ ] **Step 2: Remove the fetch-secrets steps from main.yml**

In `.github/workflows/main.yml`, delete both `- uses: ./.github/actions/fetch-storage-box-secrets` step blocks (and the now-unused `install-bws` step ONLY if nothing else in that job uses `bws`; the R2/restic paths may still need it — check before removing).

- [ ] **Step 3: Validate + confirm the plan is a clean destroy**

```bash
cd terraform && terraform validate && echo "validate OK"
! grep -rq 'storage_box' terraform/ && echo "no storage_box refs OK"
```
Expected: both OK. In CI, the `tf-plan` job will show `hcloud_storage_box.yocto_cache` **destroy** — this is a bare-delete (not a replace), so it does NOT trigger the VM rebuild-chain (that guard requires delete+create on `hcloud_server.main`). The destroy applies via the normal `terraform` job under the `production` environment.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(terraform): retire Storage Box (cache moved to public R2)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: (operator) remove obsolete Bitwarden secrets**

After merge/apply, delete the now-unused `STORAGE_BOX_PASSWORD`, `STORAGE_BOX_SSH_PUBKEY`, `STORAGE_BOX_SSH_PRIVKEY`, `STORAGE_BOX_HOST`, `STORAGE_BOX_USER` secrets from the `oe5xrx-yocto-cache` Bitwarden project (keep `R2_SSTATE_KEY`/`R2_SSTATE_SECRET`). Documented in the runbook (Task A1).

---

## Spec coverage

- C1 spec (public R2 read) → B1 (oe5xrx.yml mirror), A2 (bucket+domain).
- Write/publish → B2 (CI), B3 (ydev remote-build), A1 (creds).
- Retire sshfs/Box → B2, B3, C1; retire Spec-3 prune → B4; lifecycle prune → A2.
- Seed/migration → A3. Trust/security → A1 (least-priv token), B2 (env-only secrets).
- Docs → B5 (linux-image), A1 (servers runbook). Build validation → B6 [HUMAN].
- Deferred (hashserv, CDN tuning) → out of scope, unchanged.
