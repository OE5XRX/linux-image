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
`<box-user>`/`<box-host>` are the Bitwarden secrets `STORAGE_BOX_USER`/`STORAGE_BOX_HOST`
in the `oe5xrx-yocto-cache` project; `~/.ssh/storagebox` is `STORAGE_BOX_SSH_PRIVKEY`
from the same project.

## Build
`kas build qemux86-64.yml` — `oe5xrx.yml` auto-detects the mount and sets
`SSTATE_MIRRORS`/`DL_DIR` accordingly (`SSTATE_DIR` stays local under `build/`).
Your local build compiles only what changed; the rest comes from the mirror.

## Note
Local builds do NOT push sstate back (only CI does, to keep the mirror a clean
CI-produced artifact). If you want your local sstate to seed the box, rsync it
up manually: `rsync -a --ignore-existing build/sstate-cache/ /mnt/yocto-shared/sstate/`.

## Cache hardening: lockfiles, shallow fetch, and pruning

### Deterministic sources via kas lockfiles
Every machine target has a committed kas lockfile that pins every layer to an
exact commit. The per-machine locks are `qemux86-64.lock.yml` and
`raspberrypi4-64.lock.yml` (the RPi one also pins `meta-raspberrypi`). When you
run `kas build qemux86-64.yml` or `kas build raspberrypi4-64.yml`, kas
auto-loads the matching lockfile — builds are deterministic, and sstate is
matchable across machines with no "unsafe branch" warnings.

### Bumping lockfiles
A weekly scheduled workflow regenerates the locks and opens a PR on changes.
To bump manually: run `kas lock qemux86-64.yml` and `kas lock raspberrypi4-64.yml`,
then commit both updated lockfiles.

### Shallow git fetch
`BB_GIT_SHALLOW = "1"` in `oe5xrx.yml` fetches only the pinned commit from each
layer, not full history. For the kernel, this cuts clone time from ~85 minutes
to seconds and saves multi-GB on a shallow fetch box. The shared `DL_DIR` stays
on the Storage Box; only the pinned commit arrives locally.

### Cache pruning
The nightly `.github/workflows/cache-prune.yml` workflow (and manual
`workflow_dispatch`) mounts the Storage Box and runs `scripts/cache-prune.sh`:
pruned sstate keeps only the newest per object (`--remove-duplicated`), aged
downloads are discarded (default retention is 45 days via `DL_AGE_DAYS`,
never including current sources), and stale `.lock` / partial files are cleaned.
**Default is dry-run** (lists only); real deletion requires `workflow_dispatch`
with `dry_run=0`.

### Kept deliberate pins
The `station-agent` `SRCREV` is pinned by project rule (never `AUTOREV`) and
stays locked. Kernel version parity pins (`PREFERRED_VERSION_linux-yocto`
and `PREFERRED_VERSION_linux-raspberrypi` set to `"6.18.%"`) ensure qemu and
RPi builds track the same kernel series.
