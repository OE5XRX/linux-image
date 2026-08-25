# Yocto shared cache — public R2 mirror

Builds read warm sstate and source downloads anonymously over HTTPS from the
public mirror at `https://sstate.oe5xrx.org`. `SSTATE_DIR` and `DL_DIR` remain
**local**; only the read path goes over the wire. No mounts, no credentials
needed for local builds.

## How it works

`oe5xrx.yml` sets:

```yaml
SSTATE_MIRRORS: "file://.* https://sstate.oe5xrx.org/sstate/PATH;downloadfilename=PATH"
SOURCE_MIRROR_URL: "https://sstate.oe5xrx.org/downloads/"
```

`kas build qemux86-64.yml` (or `raspberrypi4-64.yml`) picks these up
automatically. Your build compiles only what is not already in the mirror; the
rest is fetched straight from HTTPS.

## Who writes to the mirror

Only trusted builders publish new objects. Two machines write:

- **CI** (`build.yml`) — runs on the self-hosted Hetzner CX43 build server.
- **ydev** — the remote build server used for interactive development.

Both upload to the R2 bucket `oe5xrx-yocto-sstate` (prefixes `sstate/` and
`downloads/`) via `rclone`, authenticating with `R2_SSTATE_KEY` /
`R2_SSTATE_SECRET` from the Bitwarden project `oe5xrx-yocto-cache` (stored
under the machine accounts `yocto-linux-image-readonly` and `yocto-runner`).

Local developer builds do **not** push back — the mirror stays a clean,
CI-produced artifact. If you want your local sstate to seed the bucket, upload
it manually (ensure `RCLONE_CONFIG_R2_*` env vars are exported first, as the
build scripts do):

```bash
rclone copy build/sstate-cache/ R2:oe5xrx-yocto-sstate/sstate/
```

## Cache pruning

An R2 lifecycle rule expires objects older than 365 days. No cron job or manual
prune script is needed.

## Cache hardening: lockfiles, shallow fetch, and determinism

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
to seconds and saves multi-GB on a cold fetch. The shared `DL_DIR` is local;
only the pinned commit is downloaded.

### Hash determinism

`BB_HASHSERVE = ""` and `BB_SIGNATURE_HANDLER = "OEBasicHash"` are set in
`oe5xrx.yml`. This keeps task-hash computation reproducible across machines and
ensures sstate hits are not invalidated by hashserver drift.

### Kept deliberate pins

The `station-agent` `SRCREV` is pinned by project rule (never `AUTOREV`) and
stays locked. Kernel version parity pins (`PREFERRED_VERSION_linux-yocto`
and `PREFERRED_VERSION_linux-raspberrypi` set to `"6.18.%"`) ensure qemu and
RPi builds track the same kernel series.
