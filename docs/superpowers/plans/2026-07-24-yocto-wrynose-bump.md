# Yocto Wrynose Bump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `linux-image` from Yocto Scarthgap (5.0) to Wrynose (6.0 LTS) with kernel 6.18, so the CM4 USB CDC path works.

**Architecture:** Wrynose replaces the monolithic `poky` combo-repo with split repos (`bitbake` + `openembedded-core` + `meta-yocto`). We repoint the kas config, bump every layer branch to `wrynose`, pin both kernels to `6.18.%`, mark our layer `wrynose`-compatible, then fix the recipe breakage the 3-cycle jump surfaces — iteratively, using a fast x86 build loop, then the RPi build.

**Tech Stack:** Yocto/OpenEmbedded (kas + kas-container/Docker), meta-raspberrypi, bitbake 2.16, linux-yocto/linux-raspberrypi 6.18.

## Global Constraints

- **Yocto release:** Wrynose (6.0 LTS). `LAYERSERIES_COMPAT` / `LAYERSERIES_CORENAMES` = `wrynose`.
- **Split repos** (poky is deprecated): `bitbake` (branch `2.16`), `openembedded-core` (`wrynose`), `meta-yocto` (`wrynose`).
- **Layer branches** all `wrynose`: `meta-openembedded`, `meta-raspberrypi`.
- **Kernel pin:** `PREFERRED_VERSION_linux-yocto = "6.18.%"` AND `PREFERRED_VERSION_linux-raspberrypi = "6.18.%"` (no 6.6 recipe exists on wrynose — old pin fails parsing).
- **`distro: poky` stays** (poky distro comes from `meta-poky` inside `meta-yocto`).
- **Build tool:** `kas-container` (Docker present); kas configs are `qemux86-64.yml` / `raspberrypi4-64.yml` (both `include: oe5xrx.yml`).
- **Commit trailer:** end every commit with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Scope:** version bump + what's needed to build/boot only. No agent health-gate (#106), no unrelated refactoring.

---

### Task 1: Repoint kas config + layer to Wrynose

**Files:**
- Modify: `oe5xrx.yml` (repos block + PREFERRED_VERSION lines)
- Modify: `include/raspberrypi.yml` (meta-raspberrypi branch)
- Modify: `meta-oe5xrx-remotestation/conf/layer.conf` (LAYERSERIES_COMPAT)

**Interfaces:**
- Produces: a kas config whose layers all resolve to `wrynose` and whose kernels resolve to 6.18. Later tasks build against this.

- [ ] **Step 1: Rewrite the `repos:` block in `oe5xrx.yml`**

Replace the single `poky:` repo entry (lines 6–13) so the `repos:` block reads:

```yaml
repos:
  bitbake:
    url: https://git.openembedded.org/bitbake
    branch: "2.16"

  openembedded-core:
    url: https://git.openembedded.org/openembedded-core
    branch: wrynose
    layers:
      meta:

  meta-yocto:
    url: https://git.yoctoproject.org/meta-yocto
    branch: wrynose
    layers:
      meta-poky:
      meta-yocto-bsp:

  meta-openembedded:
    url: https://git.openembedded.org/meta-openembedded
    branch: wrynose
    layers:
      meta-oe:
      meta-python:
      meta-networking:

  meta-oe5xrx-remotestation:
    layers:
      meta-oe5xrx-remotestation:
```

(`distro: poky` above the block stays unchanged.)

- [ ] **Step 2: Bump the kernel pins in `oe5xrx.yml`**

In `local_conf_header.base`, change both lines:

```
    PREFERRED_VERSION_linux-yocto = "6.18.%"
    PREFERRED_VERSION_linux-raspberrypi = "6.18.%"
```

- [ ] **Step 3: Bump meta-raspberrypi branch in `include/raspberrypi.yml`**

Change line 7 `branch: scarthgap` → `branch: wrynose`.

- [ ] **Step 4: Mark our layer wrynose-compatible**

In `meta-oe5xrx-remotestation/conf/layer.conf`, change the last line:

```
LAYERSERIES_COMPAT_meta-oe5xrx-remotestation = "wrynose"
```

- [ ] **Step 5: Sanity — no stray `scarthgap` / `6.6.%` left**

Run:
```bash
grep -rnE 'scarthgap|6\.6\.%' oe5xrx.yml include/ meta-oe5xrx-remotestation/conf/ qemux86-64.yml raspberrypi4-64.yml
```
Expected: no matches (empty). Fix any stragglers.

- [ ] **Step 6: Commit**

```bash
git add oe5xrx.yml include/raspberrypi.yml meta-oe5xrx-remotestation/conf/layer.conf
git commit -m "chore(yocto): repoint kas config + layer to Wrynose (6.0 LTS), kernel 6.18

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Local build environment (kas-container)

**Files:** none (environment only).

**Interfaces:**
- Produces: a working `kas-container` (or `kas`) invocation for later build tasks.

- [ ] **Step 1: Install kas**

```bash
pip3 install --user kas || pipx install kas
kas --version
```
Expected: prints a kas version (4.x). If `kas-container` is preferred (no host deps), it ships with the kas pip package as `kas-container`.

- [ ] **Step 2: Confirm Docker works (kas-container backend)**

```bash
docker run --rm hello-world >/dev/null 2>&1 && echo "docker ok" || echo "docker NOT usable"
```
Expected: `docker ok`. (If not, fall back to native `kas build` after installing the Yocto host deps — but Docker was detected, so prefer kas-container.)

- [ ] **Step 3: Point the build cache at a persistent local dir (optional but saves re-downloads)**

The kas config already falls back to `${TOPDIR}/downloads` + `${TOPDIR}/sstate-cache` when `/mnt/yocto-cache` is absent (local dev). No action needed; just be aware the first build is cold (hours).

---

### Task 3: x86 build shakedown loop (recipe migration)

**Files:** iterative — our `.bb` / `.bbappend` / `.bbclass` / `.cfg` under `meta-oe5xrx-remotestation/` as breakage surfaces.

**Interfaces:**
- Consumes: the Wrynose kas config from Task 1.
- Produces: a `qemux86-64` image that builds clean and boots in QEMU — proving the recipe migration is complete for the shared (non-RPi) recipes.

This is a **loop**, not pre-scripted code: the exact breakages are unknown until bitbake runs. Work the loop until the build is green.

- [ ] **Step 1: Kick off the x86 build**

```bash
cd /home/pbuchegger/OE5XRX/linux-image
kas-container build qemux86-64.yml
```
(Run in background if long; capture logs.) Expected first outcome: FAILURE — either a bitbake-version mismatch (adjust the `bitbake` branch in `oe5xrx.yml`, e.g. `2.18`, and rebuild) or a recipe/parse error.

- [ ] **Step 2: Diagnose each failure and fix at the source**

For each error, read the bitbake log, identify the recipe/class, and apply the minimal Wrynose-correct fix. Common scarthgap→wrynose breakage classes to expect in OUR recipes (`station-agent`, `ab-layout`, `oe5xrx-slot-udev`, `oe5xrx-fm-firmware`, `oe5xrx-boot-robustness`, `u-boot-ab`, the image recipe, the kernel bbappend):
  - **LICENSE / LIC_FILES_CHKSUM** SPDX-name changes; `LICENSE = "MIT"` still ok, but checksums or names may need updating.
  - **Removed/renamed bbclasses** or `inherit` targets; class-scope split (`inherit foo` → `inherit foo` may now need `-native`/`-nativesdk` variant).
  - **`do_install`/`FILES`/`bindir`** path or override syntax (`:append`/`:${PN}` — already OE 4.x, likely fine, but verify).
  - **Python API** in inline `python()` funcs (`d.getVar`/`bb.utils` are stable; watch for deprecations).
  - **systemd/`SYSTEMD_*`**, `useradd`, `overlayfs-etc`, `read-only-rootfs` option renames.
  - **`WKS_FILE` / wic plugin** changes (bootimg-efi / u-boot).
  - Consult the Yocto migration guides per release (styhead, walnascar, wrynose) at docs.yoctoproject.org/migration-guides for the authoritative list.

Fix one class of error, rebuild, repeat. Keep fixes minimal and Wrynose-correct.

- [ ] **Step 3: Build green**

```bash
kas-container build qemux86-64.yml
```
Expected: build completes; a `.wic`/`.wic.bz2` for `qemux86-64` is produced under `build/tmp*/deploy/images/qemux86-64/`.

- [ ] **Step 4: Boot the x86 image in QEMU (functional check)**

```bash
kas-container shell qemux86-64.yml -c "runqemu qemux86-64 nographic slirp"
```
Expected: kernel `6.18` boots, systemd reaches multi-user, login works. Confirm `uname -r` shows 6.18 and the station-agent service is present (`systemctl status station-agent`). Exit QEMU (`Ctrl-A X`).

- [ ] **Step 5: Commit the accumulated migration fixes**

```bash
git add -A
git commit -m "fix(yocto): recipe migration fixes for Wrynose (x86 builds + boots)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: raspberrypi4-64 build (kernel 6.18)

**Files:** iterative — any RPi-specific recipe breakage (`u-boot-ab`, `oe5xrx-fm-firmware`, `oe5xrx-slot-udev`, the RPi kernel bbappend, boot.cmd deploy).

**Interfaces:**
- Consumes: the migrated recipes from Task 3.
- Produces: a `raspberrypi4-64` `.wic.bz2` on kernel 6.18 with the Way-2 boot chain intact.

- [ ] **Step 1: Build the RPi image**

```bash
kas-container build raspberrypi4-64.yml
```
Expected: may surface RPi-only breakage (u-boot recipe, kernel bbappend, wic). Fix minimally as in Task 3, rebuild until green.

- [ ] **Step 2: Confirm kernel version + boot artifacts**

```bash
ls build/tmp*/deploy/images/raspberrypi4-64/ | grep -E 'oe5xrx-remotestation-image.*\.wic\.bz2|Image|bcm2711-rpi-cm4.dtb'
grep -rE 'linux-raspberrypi' build/tmp*/deploy/images/raspberrypi4-64/*.manifest 2>/dev/null | head
```
Expected: image + kernel `Image` + `bcm2711-rpi-cm4.dtb` present; manifest shows linux-raspberrypi 6.18.

- [ ] **Step 3: Confirm the Way-2 boot bits survived the bump**

```bash
grep -n 'fdt_addr' meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd
grep -n 'otg_mode' raspberrypi4-64.yml
```
Expected: `${fdt_addr}` firmware-DTB boot + `otg_mode=1` still present (untouched by this bump).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "fix(yocto): raspberrypi4-64 builds on Wrynose kernel 6.18

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: On-target USB acceptance (deferred to user)

**Files:** none (hardware verification).

**Interfaces:**
- Consumes: the `raspberrypi4-64` image from Task 4.

This is the acceptance test for the whole USB saga; it needs a **reflash** (new kernel + new FAT DTB; OTA does not update FAT).

- [ ] **Step 1: Flash + boot the new image on the CM4** (user).

- [ ] **Step 2: Verify kernel + USB CDC**

```bash
uname -r    # expect 6.18.x
python3 -c "
import os,termios,tty,time,select
fd=os.open('/dev/oe5xrx/slot3/control',os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
s=termios.tcgetattr(fd); tty.setraw(fd)
os.write(fd,b'module list\r\n')
end=time.time()+3; b=b''
while time.time()<end:
 r,_,_=select.select([fd],[],[],0.3)
 if r:b+=os.read(fd,4096)
 if b'MODULE-LIST' in b:break
termios.tcsetattr(fd,termios.TCSANOW,s); os.close(fd)
print('RESP',repr(b))"
```
Expected: `RESP` contains `MODULE-LIST {...}`; the FM module appears in station-manager. **That closes the USB saga.**

---

## Self-Review

**Spec coverage:**
- Spec "Coordinated changes" 1–4 → Task 1 (config) + Tasks 3/4 (recipe migration). ✓
- Spec "Verification" x86 → Task 3; RPi → Task 4; on-target → Task 5. ✓
- Spec "Out of scope" (agent gate, DTB-policy, refactoring) → Global Constraints + not present in tasks. ✓
- Spec risk "bitbake 2.16 best-guess" → Task 3 Step 1 (adjust branch if version-check fails). ✓
- Spec risk "DTB/kernel coupling → reflash" → Task 5 preamble. ✓

**Placeholder scan:** The iterative build-fix (Tasks 3/4) is intentionally a loop with a documented process + concrete breakage-class checklist + exact build/boot commands — not a "TODO". Config steps (Task 1) contain exact final YAML. No forbidden placeholders.

**Consistency:** `wrynose`, `6.18.%`, `bitbake 2.16`, `kas-container build <machine>.yml`, and the file paths are used identically across Global Constraints and all tasks.
