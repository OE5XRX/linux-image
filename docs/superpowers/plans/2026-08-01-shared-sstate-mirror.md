# Shared sstate/downloads Mirror (linux-image) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Yocto CI build read from a shared Hetzner Storage Box (sstate mirror + shared downloads) and push its sstate delta back, dropping the per-machine block volume entirely.

**Architecture:** kas points `SSTATE_MIRRORS` + `DL_DIR` at the mounted Storage Box (`/mnt/yocto-shared`) while `SSTATE_DIR` stays local/fast on the runner; after each build the runner rsyncs its sstate delta up to the box. `build.yml`'s `create-runner` job pulls the box creds from Bitwarden (`sm-action`) and SSHFS-mounts the box on the build server; the block-volume attach/detach/mount steps are removed. `build/tmp` lives on the CCX43 local NVMe.

**Tech Stack:** Yocto/kas (poky wrynose), GitHub Actions, `bitwarden/sm-action@v3`, sshfs, rsync, Hetzner Storage Box (SSH/SFTP external port 23).

**Spec:** `docs/superpowers/specs/2026-08-01-shared-sstate-mirror-design.md`. This is the `linux-image` half (PR B). **PR A (`servers`) must be merged + applied first** — the box must exist and `yocto-cache-storage-box-host`/`-user` must be in Bitwarden before PR B's first build run.

## Global Constraints

- **SRCREV/prod untouched:** this plan changes only kas cache config + `build.yml` + docs. No recipe, image, or `station-agent` SRCREV changes. The AUTOREV preflight and prod-safety guards stay green.
- **`SSTATE_DIR` stays LOCAL** (`${TOPDIR}/sstate-cache`) on every builder — never on the network mount (network TMPDIR/sstate writes are brutally slow). The box is a **read mirror** (`SSTATE_MIRRORS`) + **shared downloads** (`DL_DIR`); new sstate is pushed up by rsync post-build.
- Mount path is `/mnt/yocto-shared`; box layout is `/sstate` + `/downloads`. Hetzner Storage Box SSH/SFTP uses **external port 23** (not 22).
- Access is **key-only**: SSHFS + rsync use the box SSH key pulled from Bitwarden. No password login.
- New GitHub Secret in this repo: `BWS_ACCESS_TOKEN` (+ existing `BWS_SERVER_URL` if used by sm-action `base_url`), plus the three Bitwarden secret-UUID references (`BWS_ID_STORAGE_BOX_HOST`, `BWS_ID_STORAGE_BOX_USER`, `BWS_ID_STORAGE_BOX_SSH_KEY`).
- CI must stay green: `kas dump qemux86-64.yml > /dev/null`, `yamllint *.yml .github/workflows/`. One logical change per PR; squash-merge on `main`.
- Commit subject imperative ≤72 chars, body explains *why*. End commits with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## One-Time Bootstrap (prerequisite)

Before PR B's first CI run:
1. PR A merged + applied (box exists; host/user in Bitwarden).
2. Put the Storage Box **SSH private key** into Bitwarden (same project as PR A); note its UUID.
3. Add GitHub Secrets to `linux-image`: `BWS_ACCESS_TOKEN`, `BWS_SERVER_URL`, `BWS_ID_STORAGE_BOX_HOST`, `BWS_ID_STORAGE_BOX_USER`, `BWS_ID_STORAGE_BOX_SSH_KEY`.

---

### Task 1: kas — read-mirror + shared downloads, local sstate

**Files:**
- Modify: `oe5xrx.yml:52-53` (the `local_conf_header.base` cache lines)

**Interfaces:**
- Produces: `DL_DIR`, `SSTATE_DIR`, `SSTATE_MIRRORS` values keyed off the `/mnt/yocto-shared` mount, with a clean local-dev fallback (no mount → local dirs, no mirror).

- [ ] **Step 1: Replace the two cache lines in `oe5xrx.yml`**

Current (lines 50-53):

```yaml
    # Persistent cache on Hetzner Volume (mounted at /mnt/yocto-cache in CI).
    # Falls back to build/ local dirs if the mount doesn't exist (local dev).
    DL_DIR ?= "${@'/mnt/yocto-cache/downloads' if os.path.isdir('/mnt/yocto-cache') else '${TOPDIR}/downloads'}"
    SSTATE_DIR ?= "${@'/mnt/yocto-cache/sstate-cache' if os.path.isdir('/mnt/yocto-cache') else '${TOPDIR}/sstate-cache'}"
```

Replace with:

```yaml
    # Shared build cache (Spec: 2026-08-01-shared-sstate-mirror). The mount at
    # /mnt/yocto-shared is a Hetzner Storage Box shared by CI, the interactive
    # build box (Spec 2) and local dev. Read-mirror + push model:
    #   - SSTATE_DIR stays LOCAL/fast (network sstate writes are brutally slow).
    #   - SSTATE_MIRRORS reads prebuilt artifacts from the box (when mounted).
    #   - DL_DIR is the shared downloads dir on the box (bitbake locks per file).
    # CI rsyncs the local sstate delta up to the box after each build.
    # No mount (local dev without the box) -> local dirs, no mirror.
    DL_DIR ?= "${@'/mnt/yocto-shared/downloads' if os.path.isdir('/mnt/yocto-shared') else '${TOPDIR}/downloads'}"
    SSTATE_DIR ?= "${TOPDIR}/sstate-cache"
    SSTATE_MIRRORS ?= "${@'file://.* file:///mnt/yocto-shared/sstate/PATH;downloadfilename=PATH' if os.path.isdir('/mnt/yocto-shared') else ''}"
```

- [ ] **Step 2: Verify kas parses**

Run: `kas dump qemux86-64.yml > /dev/null && kas dump raspberrypi4-64.yml > /dev/null`
Expected: both exit 0 (no parse error). If no kas locally: `yamllint oe5xrx.yml` at minimum.

- [ ] **Step 3: Verify the resolved values (mount-present simulation)**

Run:
```bash
mkdir -p /tmp/yocto-shared-probe && \
kas dump qemux86-64.yml 2>/dev/null | grep -E 'DL_DIR|SSTATE_DIR|SSTATE_MIRRORS' || \
echo "kas not available — inspect oe5xrx.yml manually"
```
Expected (where kas is available): `SSTATE_DIR` is `.../sstate-cache` under the build dir; `DL_DIR`/`SSTATE_MIRRORS` fall back to local/empty when `/mnt/yocto-shared` is absent. (Full mount-present behavior is exercised by the CI smoke build in Task 4.)

- [ ] **Step 4: Commit**

```bash
git add oe5xrx.yml
git commit -m "build: point cache at shared Storage Box mirror (/mnt/yocto-shared)

SSTATE_DIR stays local/fast; SSTATE_MIRRORS reads prebuilt artifacts from the
shared box, DL_DIR is the shared downloads dir. Replaces the per-machine block
volume path. Local dev without the mount falls back to build-local dirs.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: build.yml — drop block volume, mount the Storage Box via Bitwarden creds

**Files:**
- Modify: `.github/workflows/build.yml` (env block L46-50; remove steps L104-115, L163-167, L181-194; add sm-action + mount steps in `create-runner`)

**Interfaces:**
- Consumes: Bitwarden secrets (host/user via PR A, SSH key via bootstrap) + GitHub Secrets from Global Constraints.
- Produces: `/mnt/yocto-shared` mounted (SSHFS, `allow_other`) on the build server, readable/writable by the `yocto` runner user, before the `build` job runs.

- [ ] **Step 1: Remove `CACHE_VOLUME_NAME` from the workflow `env` block**

In the `env:` block (L46-50) delete the line:
```yaml
  CACHE_VOLUME_NAME: oe5xrx-yocto-cache-${{ inputs.machine }}
```
(Keep `KAS_MACHINE`, `OE5XRX_RELEASE_TAG`, `BUILDER_LABEL`.)

- [ ] **Step 2: Delete the three block-volume steps**

Remove entirely:
- `Detach leftover cache volume (safety)` (L104-115)
- `Attach cache volume` (L163-167)
- `Mount cache volume on server` (L181-194)

- [ ] **Step 3: Pull the box creds from Bitwarden (new step in `create-runner`, before "Wait for SSH")**

Add after the "Create Hetzner server (CCX43)" step:

```yaml
      - name: Pull Storage Box creds from Bitwarden
        uses: bitwarden/sm-action@v3
        with:
          access_token: ${{ secrets.BWS_ACCESS_TOKEN }}
          base_url: ${{ secrets.BWS_SERVER_URL }}
          secrets: |
            ${{ secrets.BWS_ID_STORAGE_BOX_HOST }} > STORAGE_BOX_HOST
            ${{ secrets.BWS_ID_STORAGE_BOX_USER }} > STORAGE_BOX_USER
            ${{ secrets.BWS_ID_STORAGE_BOX_SSH_KEY }} > STORAGE_BOX_SSH_KEY
```
(`sm-action` exports the three values as masked env vars for later steps in this job.)

- [ ] **Step 4: Mount the box on the build server (new step, replacing the old "Mount cache volume on server")**

Add after the "Create yocto build user" step (so `/mnt/yocto-shared` is owned correctly), before "Install and start GitHub Actions Runner":

```yaml
      - name: Mount shared Yocto cache (Storage Box) on build server
        run: |
          # Ship the box SSH key to the server and SSHFS-mount it. sshfs
          # daemonizes, so the mount survives this SSH session. allow_other so
          # the unprivileged `yocto` runner user can read/write it.
          printf '%s\n' "${STORAGE_BOX_SSH_KEY}" | \
            ssh "root@${SERVER_IP}" "install -d -m700 /root/.ssh && cat > /root/.ssh/storagebox && chmod 600 /root/.ssh/storagebox"
          ssh "root@${SERVER_IP}" bash -s -- "${STORAGE_BOX_USER}" "${STORAGE_BOX_HOST}" << 'EOF'
            set -euo pipefail
            BOX_USER="$1"; BOX_HOST="$2"
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends sshfs
            grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
            mkdir -p /mnt/yocto-shared
            # Hetzner Storage Box SSH/SFTP is on port 23.
            sshfs -p 23 \
              -o IdentityFile=/root/.ssh/storagebox,StrictHostKeyChecking=accept-new \
              -o allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
              "${BOX_USER}@${BOX_HOST}:/" /mnt/yocto-shared
            mkdir -p /mnt/yocto-shared/sstate /mnt/yocto-shared/downloads
            chown yocto:yocto /mnt/yocto-shared/sstate /mnt/yocto-shared/downloads || true
            df -h /mnt/yocto-shared
          EOF
        env:
          STORAGE_BOX_HOST: ${{ env.STORAGE_BOX_HOST }}
          STORAGE_BOX_USER: ${{ env.STORAGE_BOX_USER }}
          STORAGE_BOX_SSH_KEY: ${{ env.STORAGE_BOX_SSH_KEY }}
```

- [ ] **Step 5: Lint the workflow**

Run: `yamllint .github/workflows/build.yml`
Expected: no errors. If `actionlint` is available, run it and expect no new findings.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(build): mount shared Storage Box cache, drop per-machine block volume

create-runner now pulls the box host/user/SSH-key from Bitwarden and SSHFS-
mounts it at /mnt/yocto-shared (key-only, port 23, allow_other). Removes the
block-volume attach/detach/mount steps and CACHE_VOLUME_NAME — build/tmp lives
on the runner's local NVMe, cache comes from the shared mirror. Kills the
attach-once volume conflict + the detach-safety corruption class.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: build.yml — push sstate delta to the mirror after the build

**Files:**
- Modify: `.github/workflows/build.yml` (the `build` job, after "Build with Kas")

**Interfaces:**
- Consumes: `/mnt/yocto-shared` mounted (Task 2); local `build/sstate-cache` produced by the build.
- Produces: new sstate artifacts uploaded to the shared box.

- [ ] **Step 1: Add the push step after "Build with Kas"**

Insert into the `build` job, immediately after the "Build with Kas" step and before "Collect artifacts":

```yaml
      - name: Push sstate delta to shared mirror
        if: always()
        run: |
          # Read-mirror + push: sync only NEW sstate objects this build produced
          # up to the shared box. --ignore-existing keeps it a cheap delta and
          # avoids reuploading what the mirror already served us.
          if mountpoint -q /mnt/yocto-shared; then
            rsync -a --ignore-existing build/sstate-cache/ /mnt/yocto-shared/sstate/
            echo "sstate delta pushed to shared mirror"
          else
            echo "::warning::/mnt/yocto-shared not mounted — skipping sstate push"
          fi
```
(`if: always()` so a late build failure still contributes the sstate it built.)

- [ ] **Step 2: Lint**

Run: `yamllint .github/workflows/build.yml`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(build): rsync sstate delta to the shared mirror after build

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: CI smoke verification (warm-cache proof) + local dev doc

**Files:**
- Create: `docs/dev-shared-cache.md`

**Interfaces:**
- Produces: a runbook for pointing the local M920q at the shared mirror; plus a manual CI verification checklist (no code interface).

- [ ] **Step 1: Trigger a smoke build and verify the mount + push**

Run (after PR B's branch is pushed and the bootstrap secrets exist):
```bash
gh workflow run build.yml -f machine=qemux86-64
gh run watch
```
Expected: green build; the "Mount shared Yocto cache" step shows `df -h /mnt/yocto-shared` (box mounted); the "Push sstate delta" step reports objects pushed.

- [ ] **Step 2: Trigger a SECOND build and verify warm reuse**

Run: `gh workflow run build.yml -f machine=qemux86-64 && gh run watch`
Expected: build log shows sstate reuse (`Sstate summary ... reused`), wall-clock materially lower than a cold build. This proves the mirror is warm.

- [ ] **Step 3: Write the local-dev runbook `docs/dev-shared-cache.md`**

```markdown
# Local Yocto builds against the shared cache (M920q)

The CI shares its sstate/downloads via a Hetzner Storage Box. Point your local
build at the same box so you pull warm sstate instead of compiling everything
(essential on the 8 GB M920q).

## One-time: mount the box
```bash
# key-only; Hetzner Storage Box SSH/SFTP is on port 23.
mkdir -p /mnt/yocto-shared
sudo sshfs -p 23 \
  -o IdentityFile=$HOME/.ssh/storagebox,allow_other,reconnect,ServerAliveInterval=15 \
  <box-user>@<box-host>:/ /mnt/yocto-shared
```
`<box-user>`/`<box-host>` are the Bitwarden secrets `yocto-cache-storage-box-user`/`-host`;
`~/.ssh/storagebox` is the box private key from Bitwarden.

## Build
`kas build qemux86-64.yml` — `oe5xrx.yml` auto-detects the mount and sets
`SSTATE_MIRRORS`/`DL_DIR` accordingly (`SSTATE_DIR` stays local under `build/`).
Your local build compiles only what changed; the rest comes from the mirror.

## Note
Local builds do NOT push sstate back (only CI does, to keep the mirror a clean
CI-produced artifact). If you want your local sstate to seed the box, rsync it
up manually: `rsync -a --ignore-existing build/sstate-cache/ /mnt/yocto-shared/sstate/`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/dev-shared-cache.md
git commit -m "docs(dev): local M920q builds against the shared Storage Box cache

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Read-mirror + push, `SSTATE_DIR` local, `DL_DIR` shared → Task 1 ✓
- Block volume dropped, `build/tmp` local → Task 2 (removed steps + no CACHE_VOLUME_NAME) ✓
- SSHFS mount via Bitwarden creds, key-only, port 23, `allow_other` → Task 2 ✓
- sstate rsync push post-build → Task 3 ✓
- Warm-cache proof + local M920q doc → Task 4 ✓
- `cleanup` job unchanged (no volume detach needed) → left untouched ✓
- Cross-repo ordering (PR A before PR B) → stated in header + bootstrap ✓

**Placeholder scan:** `<box-user>`/`<box-host>` in the local-dev doc are user-substituted runtime values (documented as such), not plan gaps. sm-action secret IDs come from GitHub Secrets. No "TODO"/"handle appropriately".

**Type consistency:** mount path `/mnt/yocto-shared` and box dirs `/sstate`, `/downloads` are identical across Task 1 (kas), Task 2 (mount), Task 3 (rsync), Task 4 (doc). Env var names `STORAGE_BOX_HOST/USER/SSH_KEY` consistent between the sm-action step (Task 2 Step 3) and the mount step (Task 2 Step 4). `SSTATE_DIR = ${TOPDIR}/sstate-cache` (Task 1) matches the rsync source `build/sstate-cache/` (Task 3, since kas builds under `build/`).
