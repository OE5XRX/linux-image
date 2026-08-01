# Shared sstate/downloads Mirror (linux-image) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Yocto CI build read from a shared Hetzner Storage Box (sstate mirror + shared downloads) and push its sstate delta back, dropping the per-machine block volume entirely.

**Architecture:** kas points `SSTATE_MIRRORS` + `DL_DIR` at the mounted Storage Box (`/mnt/yocto-shared`) while `SSTATE_DIR` stays local/fast on the runner; after each build the runner rsyncs its sstate delta up to the box. `build.yml`'s `create-runner` job pulls the box creds from Bitwarden **via the `bws` CLI (by name, like `servers`)** and SSHFS-mounts the box on the build server; the block-volume attach/detach/mount steps are removed. `build/tmp` lives on the CCX43 local NVMe.

**Tech Stack:** Yocto/kas (poky wrynose), GitHub Actions, `bws` CLI + `jq`, sshfs, rsync, Hetzner Storage Box (SSH/SFTP external port 23).

**Spec:** `docs/superpowers/specs/2026-08-01-shared-sstate-mirror-design.md` (Variant Y, §6). This is the `linux-image` half (PR B). **PR A (`servers`) is merged + applied** — the box exists; its `STORAGE_BOX_HOST`/`STORAGE_BOX_USER`/`STORAGE_BOX_SSH_PRIVKEY` are in the Bitwarden project `oe5xrx-yocto-cache`.

## Global Constraints

- **SRCREV/prod untouched:** this plan changes only kas cache config + `build.yml` + docs. No recipe, image, or `station-agent` SRCREV changes. The AUTOREV preflight and prod-safety guards stay green.
- **`SSTATE_DIR` stays LOCAL** (`${TOPDIR}/sstate-cache`) on every builder — never on the network mount (network TMPDIR/sstate writes are brutally slow). The box is a **read mirror** (`SSTATE_MIRRORS`) + **shared downloads** (`DL_DIR`); new sstate is pushed up by rsync post-build.
- Mount path is `/mnt/yocto-shared`; box layout is `/sstate` + `/downloads`. Hetzner Storage Box SSH/SFTP uses **external port 23** (not 22).
- Access is **key-only**: SSHFS + rsync use the box SSH key pulled from Bitwarden. No password login.
- **Secrets via `bws` CLI, by NAME** (like `servers/scripts/materialize-service-env.sh`): read `STORAGE_BOX_HOST`/`STORAGE_BOX_USER`/`STORAGE_BOX_SSH_PRIVKEY` from BW project `oe5xrx-yocto-cache`. GitHub Secrets needed: only `BWS_ACCESS_TOKEN` (`BWS_SERVER_URL` is OPTIONAL — the fetch defaults to `https://vault.bitwarden.eu` when unset). **No secret UUIDs, no `sm-action`.**
- **The SSH private key is multi-line (PEM).** Do NOT route it through `::add-mask::`/`$GITHUB_ENV` as one value (mask only covers the first line → leak/injection). Write it directly to a mode-600 file on the runner and pass THAT to the build box.
- CI must stay green: `kas dump qemux86-64.yml > /dev/null`, `yamllint *.yml .github/workflows/`. One logical change per PR; squash-merge on `main`.
- Commit subject imperative ≤72 chars, body explains *why*. End commits with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## One-Time Bootstrap (prerequisite)

Done (confirmed by the operator):
1. PR A merged + applied (box exists; `STORAGE_BOX_HOST=u644097.your-storagebox.de`, `STORAGE_BOX_USER=u644097` in BW project `oe5xrx-yocto-cache`).
2. `STORAGE_BOX_SSH_PRIVKEY` is in the same BW project.
3. `BWS_ACCESS_TOKEN` is set as a GitHub Secret in `linux-image`. `BWS_SERVER_URL` intentionally omitted → the fetch uses the `https://vault.bitwarden.eu` default.

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
- Modify: `.github/workflows/build.yml` (env block L46-50; remove steps L104-115, L163-167, L181-194; add bws-fetch + mount steps in `create-runner`)

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

- [ ] **Step 3: Install bws + fetch box creds from Bitwarden (new step in `create-runner`, after "Create Hetzner server", before "Wait for SSH")**

```yaml
      - name: Fetch Storage Box creds from Bitwarden
        env:
          BWS_ACCESS_TOKEN: ${{ secrets.BWS_ACCESS_TOKEN }}
          BWS_SERVER_URL: ${{ secrets.BWS_SERVER_URL }}
        run: |
          set -euo pipefail
          # Install bws (pinned + sha256, mirroring servers/cloud-init). jq is
          # preinstalled on ubuntu-latest.
          VER=0.5.0
          SHA=b9296341549d9ba6922da6692b24c4d81d14dc3992597d5a777692aee73b10b2
          curl -fsSL -o /tmp/bws.zip "https://github.com/bitwarden/sdk-sm/releases/download/bws-v${VER}/bws-x86_64-unknown-linux-gnu-${VER}.zip"
          echo "${SHA}  /tmp/bws.zip" | sha256sum -c -
          mkdir -p "$HOME/.local/bin"; unzip -o /tmp/bws.zip -d "$HOME/.local/bin"
          export PATH="$HOME/.local/bin:$PATH"
          export BWS_SERVER_URL="${BWS_SERVER_URL:-https://vault.bitwarden.eu}"
          PROJECT_ID=$(bws project list -o json | jq -r '.[] | select(.name=="oe5xrx-yocto-cache") | .id')
          [ -n "${PROJECT_ID}" ] || { echo "::error::Bitwarden project oe5xrx-yocto-cache not found"; exit 1; }
          SECRETS=$(bws secret list -p "${PROJECT_ID}" -o json)
          BOX_HOST=$(jq -r '.[]|select(.key=="STORAGE_BOX_HOST")|.value' <<<"${SECRETS}")
          BOX_USER=$(jq -r '.[]|select(.key=="STORAGE_BOX_USER")|.value' <<<"${SECRETS}")
          if [ -z "${BOX_HOST}" ] || [ -z "${BOX_USER}" ]; then
            echo "::error::STORAGE_BOX_HOST/USER missing in oe5xrx-yocto-cache"; exit 1
          fi
          if [[ "${BOX_HOST}" == *$'\n'* || "${BOX_USER}" == *$'\n'* ]]; then
            echo "::error::STORAGE_BOX_HOST/USER must be single-line"; exit 1
          fi
          echo "STORAGE_BOX_HOST=${BOX_HOST}" >> "${GITHUB_ENV}"
          echo "STORAGE_BOX_USER=${BOX_USER}" >> "${GITHUB_ENV}"
          # Private key is multi-line (PEM): write straight to a mode-600 file,
          # NEVER to $GITHUB_ENV or a :: command (masking only covers the first
          # line → leak/injection). $RUNNER_TEMP is auto-cleaned at job end.
          KEYFILE="${RUNNER_TEMP}/storagebox_key"
          ( umask 077; jq -r '.[]|select(.key=="STORAGE_BOX_SSH_PRIVKEY")|.value' <<<"${SECRETS}" > "${KEYFILE}" )
          [ -s "${KEYFILE}" ] || { echo "::error::STORAGE_BOX_SSH_PRIVKEY missing/empty in oe5xrx-yocto-cache"; exit 1; }
          echo "STORAGE_BOX_KEYFILE=${KEYFILE}" >> "${GITHUB_ENV}"
```

- [ ] **Step 4: Mount the box on the build server (replaces the old "Mount cache volume on server")**

Add after the "Create yocto build user" step (so `/mnt/yocto-shared` is owned correctly), before "Install and start GitHub Actions Runner":

```yaml
      - name: Mount shared Yocto cache (Storage Box) on build server
        env:
          STORAGE_BOX_HOST: ${{ env.STORAGE_BOX_HOST }}
          STORAGE_BOX_USER: ${{ env.STORAGE_BOX_USER }}
          STORAGE_BOX_KEYFILE: ${{ env.STORAGE_BOX_KEYFILE }}
        run: |
          # Ship the box private key (a file — never an env value) to the server
          # and SSHFS-mount it. sshfs daemonizes, so the mount survives this SSH
          # session. allow_other so the unprivileged `yocto` runner user reads it.
          ssh "root@${SERVER_IP}" 'install -d -m700 /root/.ssh'
          scp "${STORAGE_BOX_KEYFILE}" "root@${SERVER_IP}:/root/.ssh/storagebox"
          ssh "root@${SERVER_IP}" 'chmod 600 /root/.ssh/storagebox'
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
