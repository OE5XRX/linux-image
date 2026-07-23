# CM4 A/B Boot Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every built `raspberrypi4-64` image boot via our A/B `boot.scr` and store a redundant U-Boot environment in the raw `uboot_env`/`uboot_envr` partitions, so OTA commit/rollback actually works.

**Architecture:** Two BitBake-layer changes. (A) Deploy our compiled `boot.scr` to `DEPLOY_DIR_IMAGE` and route it onto the firmware FAT partition via `IMAGE_BOOT_FILES`, replacing the generic script meta-raspberrypi installs — mirroring the working x86 `grub-ab`/`grubenv` pattern. (B) Add a U-Boot Kconfig fragment relocating the environment from FAT to redundant raw MMC at offsets matching the wks partition layout, so U-Boot and userspace `fw_setenv` share one env.

**Tech Stack:** Yocto/OpenEmbedded (scarthgap), BitBake recipes/bbappends, U-Boot Kconfig fragments, wic, meta-raspberrypi.

## Global Constraints

- **Machine scope:** All changes are `raspberrypi4-64`-only. Do NOT alter x86
  (`qemux86-64`) behaviour. Use `:raspberrypi4-64` overrides.
- **U-Boot version:** scarthgap's U-Boot (2024.01). Kconfig symbol names below
  are version-sensitive; the exact redundant-env symbol is confirmed at build
  time (see Risk note in Task 2).
- **Env size single source of truth:** `CONFIG_ENV_SIZE` (U-Boot) MUST equal the
  env_size column in `fw_env.config` — currently `0x10000`. Keep both at
  `0x10000`.
- **Env offsets single source of truth:** the wks partition layout. U-Boot env
  offsets are absolute device byte offsets that MUST match the `uboot_env` /
  `uboot_envr` partition start sectors. Observed:
  `uboot_env` = sector 131112 = `0x4005000`, `uboot_envr` = sector 133160 =
  `0x4105000`.
- **Verification is code-review only.** No `bitbake`, no flashing, no HIL in
  this task. Each task's "verify" step is a static review; the user builds,
  flashes, and tests on the CM4 afterward. Build-time confirmation points are
  called out explicitly.
- **Reference pattern:** x86 `grub-ab_1.0.bb` (deploy) +
  `oe5xrx-remotestation-image.bb` `IMAGE_EFI_BOOT_FILES`/`WKS_FILE_DEPENDS`
  (qemux86-64) is the proven analog for Fix A. Match its structure.

---

## File Structure

Files created or modified:

- `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb` — **modify**:
  add `deploy` inherit + `do_deploy` task that stages our `boot.scr` for wic;
  resolve the `FIXME(u-boot-env-partition)` comment (env is now real).
- `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`
  — **modify**: route our deployed `boot.scr` onto the FAT partition
  (`IMAGE_BOOT_FILES`), depend on `u-boot-ab` for wic ordering (RPi only).
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg` —
  **create**: U-Boot Kconfig fragment, redundant raw MMC env.
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend` — **modify**:
  add the new fragment to `SRC_URI:append:raspberrypi4-64`.
- `meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in` — **modify**:
  coupling comment on the env partitions (offsets are the source of truth).

Task 1 owns Fix A (boot.scr routing). Task 2 owns Fix B (redundant env). They
touch `u-boot-ab_1.0.bb` in different sections (Task 1: tasks/inherit; Task 2:
the FIXME comment), so they are independently reviewable.

---

## Task 1: Route our A/B `boot.scr` onto the FAT partition (Fix A)

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb` (RPi section, ~lines 70–82)

**Interfaces:**
- Consumes: `${WORKDIR}/boot.scr` produced by the recipe's existing `do_compile`
  (mkimage-wrapped `boot.cmd`).
- Produces: a deploy artifact `${DEPLOY_DIR_IMAGE}/oe5xrx-boot.scr` that wic
  installs onto the firmware FAT partition as `boot.scr`.

- [ ] **Step 1: Add `deploy` inherit and `do_deploy` to `u-boot-ab_1.0.bb`**

Change the inherit line from:

```bitbake
inherit allarch
```

to:

```bitbake
inherit allarch deploy
```

Then add this task immediately after the existing `do_install() { ... }` block
(mirrors `grub-ab_1.0.bb`'s deploy). Deploy under a distinct basename so it does
not collide with the generic `boot.scr` other recipes deploy:

```bitbake
do_deploy() {
    # Stage the A/B boot script for wic. Named oe5xrx-boot.scr (not boot.scr)
    # to avoid a DEPLOY_DIR_IMAGE filename clash with meta-raspberrypi's
    # rpi-u-boot-scr. The image recipe installs it onto the FAT partition as
    # boot.scr via IMAGE_BOOT_FILES. Mirrors grub-ab's grubenv deploy.
    install -m 0644 ${WORKDIR}/boot.scr ${DEPLOYDIR}/oe5xrx-boot.scr
}
addtask deploy after do_compile before do_build
```

- [ ] **Step 2: Route the deployed script onto the FAT partition in the image recipe**

In `oe5xrx-remotestation-image.bb`, in the `# ---- Raspberry Pi: U-Boot A/B`
section, directly after the existing line:

```bitbake
WKS_FILE:raspberrypi4-64 = "oe5xrx-remotestation-ab.wks.in"
```

add:

```bitbake
# Our A/B boot.scr must land on the firmware FAT partition, replacing the
# generic script meta-raspberrypi's rpi-u-boot-scr adds via RPI_USE_U_BOOT.
# u-boot-ab deploys it as oe5xrx-boot.scr; drop the generic entry and install
# ours as boot.scr. Mirrors the x86 grubenv deploy routing above.
IMAGE_BOOT_FILES:remove:raspberrypi4-64 = "boot.scr"
IMAGE_BOOT_FILES:append:raspberrypi4-64 = " oe5xrx-boot.scr;boot.scr"
WKS_FILE_DEPENDS:append:raspberrypi4-64 = " u-boot-ab"
```

- [ ] **Step 3: Static verification (code review)**

Confirm by inspection — no build in this task:

1. `do_deploy` structurally matches `grub-ab_1.0.bb`'s (`inherit ... deploy`,
   `install ... ${DEPLOYDIR}/`, `addtask deploy after do_compile before
   do_build`). Diff the two recipes side by side.
2. The deploy basename `oe5xrx-boot.scr` is distinct from `boot.scr` (no deploy
   collision) and the `IMAGE_BOOT_FILES` entry maps `oe5xrx-boot.scr;boot.scr`
   (source;dest) so it lands as `boot.scr` on FAT.
3. `WKS_FILE_DEPENDS:append:raspberrypi4-64 = " u-boot-ab"` mirrors the
   qemux86-64 `grub-ab` dependency, guaranteeing the deploy exists before wic.

   **Build-time confirmation point (user, later):** After a build, verify wic
   used our script — mount the built `.wic`'s FAT partition and check
   `boot.scr` is 4051 bytes (our A/B script), not ~262 bytes (generic). If the
   `:remove` did not strip meta-raspberrypi's token (its exact form may be
   `boot.scr` or `boot.scr;boot.scr`), the appended entry still wins by
   ordering; only if wic errors on a duplicate destination, drop the
   `:remove` line and rely on ordering alone.

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb \
        meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "fix(cm4-boot): install A/B boot.scr on FAT partition

Deploy u-boot-ab's compiled boot.scr to DEPLOY_DIR_IMAGE and route it
onto the firmware partition via IMAGE_BOOT_FILES, replacing the generic
rpi-u-boot-scr script that caused a root=/dev/mmcblk0p2 panic loop.
Mirrors the x86 grubenv deploy pattern.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Redundant raw MMC U-Boot environment (Fix B)

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg`
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend`
- Modify: `meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in` (env partition comment)
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb` (resolve FIXME comment)

**Interfaces:**
- Consumes: the wks env partition offsets (Global Constraints) and the
  `0x10000` env size from `fw_env.config`.
- Produces: a U-Boot binary whose env lives in redundant raw MMC at the same
  bytes `fw_env.config` targets — so `boot.cmd`'s `saveenv` and the
  station-agent's `fw_setenv` read/write one shared, redundant env.

- [ ] **Step 1: Create the U-Boot env Kconfig fragment**

Create `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg`:

```
# U-Boot environment: redundant raw copies in the uboot_env / uboot_envr GPT
# partitions (see meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in).
#
# Offsets are ABSOLUTE byte offsets from the start of the SD/eMMC device and
# MUST match the wks partition start sectors. If the partition layout changes,
# update these AND fw_env.config:
#   uboot_env  = sector 131112 = 0x4005000  (primary)
#   uboot_envr = sector 133160 = 0x4105000  (redundant)
# CONFIG_ENV_SIZE MUST equal the env_size column in u-boot-ab's fw_env.config
# (0x10000) so U-Boot and fw_setenv address identical byte ranges.
CONFIG_ENV_IS_IN_FAT=n
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_DEV=0
CONFIG_ENV_SIZE=0x10000
CONFIG_ENV_OFFSET=0x4005000
CONFIG_SYS_REDUNDAND_ENVIRONMENT=y
CONFIG_ENV_OFFSET_REDUND=0x4105000
```

- [ ] **Step 2: Wire the fragment into the U-Boot bbappend**

In `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend`, change:

```bitbake
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg file://oe5xrx-wdt.cfg"
```

to:

```bitbake
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg file://oe5xrx-wdt.cfg file://oe5xrx-env.cfg"
```

Also extend the explanatory comment directly above that line so all three
fragments are described:

```bitbake
# One :append so all fragments are always applied: ext4 (boot.cmd ext4load's
# the kernel from the rootfs), watchdog (u-boot arms the SoC wdt), and env
# (redundant U-Boot environment in the raw uboot_env/uboot_envr partitions,
# matching fw_env.config so fw_setenv commits reach the same env U-Boot reads).
```

- [ ] **Step 3: Add the coupling comment to the wks env partitions**

In `meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in`, replace the
two env `part` lines:

```
part --ondisk mmcblk0 --fstype=none --label uboot_env --size 1 --align 4
part --ondisk mmcblk0 --fstype=none --label uboot_envr --size 1 --align 4
```

with the same two lines preceded by a coupling comment:

```
# U-Boot environment (raw). The U-Boot build stores its env at absolute byte
# offsets matching these partitions' start sectors — see recipes-bsp/u-boot/
# files/oe5xrx-env.cfg (CONFIG_ENV_OFFSET / CONFIG_ENV_OFFSET_REDUND) and
# recipes-bsp/u-boot-ab/files/fw_env.config. Changing the layout of these
# partitions REQUIRES updating those offsets in lockstep.
part --ondisk mmcblk0 --fstype=none --label uboot_env --size 1 --align 4
part --ondisk mmcblk0 --fstype=none --label uboot_envr --size 1 --align 4
```

- [ ] **Step 4: Resolve the FIXME in `u-boot-ab_1.0.bb`**

The `FIXME(u-boot-env-partition)` block (the multi-line comment ending
`... same offsets patched into fw_env.config.`) is now resolved by
`oe5xrx-env.cfg`. Replace that entire FIXME comment block with a resolved note:

```bitbake
# U-Boot stores its environment as redundant raw copies in the uboot_env /
# uboot_envr partitions, activated by recipes-bsp/u-boot/files/oe5xrx-env.cfg
# (CONFIG_ENV_IS_IN_MMC + redundant). The offsets there match this
# fw_env.config, so fw_printenv/fw_setenv and U-Boot share one env.
```

- [ ] **Step 5: Static verification (code review)**

Confirm by inspection — no build in this task:

1. **Offset arithmetic:** `0x4005000` == 131112 × 512 and `0x4105000` ==
   133160 × 512. Both start sectors are the `uboot_env`/`uboot_envr` starts in
   the wks-produced layout.
2. **Env size match:** `CONFIG_ENV_SIZE=0x10000` equals the env_size column in
   `recipes-bsp/u-boot-ab/files/fw_env.config` (both raw partition lines use
   `0x10000`). `fw_env.config` already lists both partitions at offset 0 → no
   `fw_env.config` change needed.
3. **Fits the partition:** `0x10000` (64 KiB) ≤ the 1 MiB (`--size 1`) env
   partitions.
4. **Machine scope:** the fragment is only pulled in via
   `SRC_URI:append:raspberrypi4-64`; x86 U-Boot is untouched.

   **Build-time confirmation point (user, later) — highest risk:** The exact
   Kconfig symbol for redundant env is version-sensitive. For scarthgap U-Boot
   (2024.01) it is `CONFIG_SYS_REDUNDAND_ENVIRONMENT` (note the upstream
   misspelling "REDUNDAND"). At build time, after U-Boot's `do_configure`,
   confirm the resolved `.config` shows `CONFIG_ENV_IS_IN_MMC=y`,
   `CONFIG_ENV_IS_IN_FAT` unset, and the redundant symbol + both offsets set. If
   a symbol name differs for this version, adjust the fragment. Then after a
   build+flash: on the target, `fw_printenv` should read back what `boot.cmd`'s
   `saveenv` wrote (e.g. a non-zero `bootcount` after a boot), and a
   `fw_setenv bootcount 0` from userspace must be visible to U-Boot on the next
   boot.

- [ ] **Step 6: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg \
        meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend \
        meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in \
        meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb
git commit -m "fix(cm4-boot): redundant U-Boot env in raw uboot_env/_envr partitions

Relocate the U-Boot environment from the FAT uboot.env to redundant raw
MMC copies at offsets matching the wks uboot_env/uboot_envr partitions
and fw_env.config. fw_setenv commits (OTA healthy-boot, rollback) now
reach the same env U-Boot reads. Resolves FIXME(u-boot-env-partition).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Spec Fix A (boot.scr on FAT, mirror grubenv deploy) → Task 1. ✓
- Spec Fix B (redundant raw MMC env, U-Boot fragment, offsets, env size match) →
  Task 2 Steps 1–2, 5. ✓
- Spec coupling note (documented in-tree at both sites) → Task 2 Steps 1
  (fragment comment) + 3 (wks comment). ✓
- Spec "resolve/delete FIXME(u-boot-env-partition)" → Task 2 Step 4. ✓
- Spec non-goals (no data-grow, no rollback-logic change, no build/flash) →
  honored; not in any task. ✓
- Spec verification (code review only, compare to x86, confirm offsets/size) →
  Task 1 Step 3, Task 2 Step 5. ✓

**Placeholder scan:** No TBD/TODO; every edit shows exact before/after text and
exact config values. Build-time confirmation points are explicit deferrals to
the user (chosen verification model), not plan placeholders. ✓

**Type/name consistency:** Deploy basename `oe5xrx-boot.scr` is used identically
in the `do_deploy` install target (Task 1 Step 1) and the `IMAGE_BOOT_FILES`
source (Task 1 Step 2). Env offsets `0x4005000` / `0x4105000` and size `0x10000`
are identical across the fragment (Task 2 Step 1), the wks comment (Step 3), and
both verification steps. ✓
