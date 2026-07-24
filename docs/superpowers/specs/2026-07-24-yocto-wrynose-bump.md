# Yocto Scarthgap (5.0) → Wrynose (6.0 LTS) + Kernel 6.6 → 6.18 — Design

**Date:** 2026-07-24
**Status:** Approved (design), pending implementation plan
**Repo:** `linux-image`
**Tracks:** issue #2 (Wrynose upgrade), issue #46 (kernel pin). Promotes both from
"later" to "now" — driven by a concrete blocker.

## Problem

The CM4 cannot exchange USB CDC data with the full-speed FM module behind the
high-speed FE1.1s hub on our image — verified as a **kernel** issue, not
hardware: the identical hardware + firmware works under official Raspberry Pi OS
(kernel **6.18**), while our Yocto image (kernel **6.6.63**) stays silent (USB
control transfers to the FS-behind-HS-hub device time out; the module never sees
DTR and never sends). The dwc2/xHCI split-transaction handling for this topology
was fixed somewhere between 6.6 and 6.18. So the fix is a **kernel bump**, and the
clean, long-lived way to get 6.18 is the **Wrynose (Yocto 6.0 LTS)** upgrade.

## Goal

Build our image on Yocto **Wrynose (6.0 LTS)** with kernel **6.18** for both
machines, so the CM4 USB CDC path works (module reports to station-manager) and
we sit on an LTS supported to 2030.

## Design

Wrynose deprecates the monolithic `poky` combo-repo in favour of split repos
(`bitbake` + `openembedded-core` + `meta-yocto`). Verified upstream state:
- `openembedded-core` **wrynose** branch exists; `LAYERSERIES_CORENAMES = "wrynose"`;
  ships `linux-yocto_6.18.bb` (x86 kernel).
- `meta-yocto` **wrynose** exists (provides `meta-poky` + `meta-yocto-bsp`, the
  `poky` distro).
- `meta-openembedded` **wrynose** exists.
- `meta-raspberrypi` **wrynose** exists; `LAYERSERIES_COMPAT = "wrynose"`; default
  `PREFERRED_VERSION_linux-raspberrypi = "6.18.%"` (recipes for 6.6/6.12/6.18).
- `bitbake` uses version branches, not codenames; Wrynose-era = branch **2.16**
  (to be confirmed by the build's bitbake-version check; adjust if it complains).

### Coordinated changes

1. **`oe5xrx.yml`** — replace the single `poky` repo with three repos:
   - `bitbake` (url `https://git.openembedded.org/bitbake`, branch `2.16`)
   - `openembedded-core` (wrynose, layer `meta`)
   - `meta-yocto` (wrynose, layers `meta-poky` + `meta-yocto-bsp`)
   - `meta-openembedded`: `scarthgap` → `wrynose`
   - `PREFERRED_VERSION_linux-yocto` and `_linux-raspberrypi`: `6.6.%` → `6.18.%`
     (mandatory — no 6.6 recipe exists on wrynose, so keeping the old pin fails
     parsing).
   - `distro: poky` stays (poky distro comes from `meta-poky` in `meta-yocto`).
2. **`include/raspberrypi.yml`** — `meta-raspberrypi`: `scarthgap` → `wrynose`.
3. **`meta-oe5xrx-remotestation/conf/layer.conf`** —
   `LAYERSERIES_COMPAT_meta-oe5xrx-remotestation`: `scarthgap` → `wrynose`.
4. **Recipe migration** — fix breakage across our `.bb`/`.bbappend`/classes that
   3 release cycles (scarthgap → styhead → walnascar → wrynose) introduce.
   Unknown until the build runs; discovered and fixed iteratively. Consult the
   Yocto migration guides per release for the common classes (e.g. license
   syntax, deprecated bbclass, python API, systemd/initscript changes).

### Out of scope (YAGNI)

- Agent hardware-health gate (station-manager #106) — separate PR.
- Deeper OTA/DTB-decoupling policy (#46) — only kept in mind: a kernel bump ships
  a new FAT DTB, which OTA does not update, so applying this bump needs a
  **reflash** anyway (acceptable; the on-target USB verification is a reflash).
- No unrelated recipe refactoring.

## Verification

Iterative, machine by machine (x86 first — same host arch, faster to shake out
recipe breakage; RPi second — the one that matters for the USB fix):

1. **x86 (`qemux86-64`)** — `kas-container` build locally (Docker present). Must:
   build clean, boot in QEMU, A/B + station-agent sanity. This is the recipe-
   migration shakedown loop.
2. **`raspberrypi4-64`** — build clean (local or Hetzner). Confirm kernel `6.18`,
   the boot chain (Way-2 firmware DTB) still works.
3. **On-target (user, deferred)** — flash the RPi image, run the `module list`
   probe on `/dev/oe5xrx/slot3/control` → expect `MODULE-LIST {...}`; the FM
   module appears in station-manager. This is the acceptance test for the whole
   USB saga.

Code review only in-tree for the boot-critical bits; the real proof is the build
+ on-target USB test.

## Risks

- **Recipe breakage** across 3 Yocto cycles — the main effort, handled iteratively
  via the x86 build loop.
- **bitbake branch 2.16** is a best-guess for Wrynose; the build's version check
  will confirm or correct it.
- **Cold builds are slow** (hours, no sstate locally); expected.
- **DTB/kernel coupling** — 6.18 needs a matching FAT DTB (from the same build);
  fine since the bump requires a reflash anyway.

## Rollout

Requires a one-time **reflash** (new kernel + new FAT DTB). After that, normal
OTA resumes for rootfs/kernel updates within the Wrynose line.
