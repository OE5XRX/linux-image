# CM4 A/B Boot Fix — Design

**Date:** 2026-07-23
**Status:** Approved (design), pending implementation plan
**Machine affected:** `raspberrypi4-64` (CM4). x86 (`qemux86-64`) already correct; untouched.

## Problem

The CM4 image did not boot in a loop, and its A/B/OTA state was not persisted
where the bootloader reads it. Two independent-but-related defects, both traced
by inspecting a flashed SD card:

### Defect A — wrong `boot.scr` on the firmware (FAT) partition

The firmware FAT partition carried the **generic** `boot.scr` from
meta-raspberrypi's `rpi-u-boot-scr` recipe, not our A/B boot script.

- `RPI_USE_U_BOOT = "1"` (`include/raspberrypi.yml`) makes meta-raspberrypi add
  `boot.scr` (from `rpi-u-boot-scr`) to `IMAGE_BOOT_FILES`; wic copies it onto
  the FAT partition (`--source bootimg-partition` in the wks).
- Our `u-boot-ab` recipe installs the correct A/B `boot.scr` into the **rootfs**
  at `/boot/firmware/boot.scr` — never onto the actual FAT partition that wic
  writes. At runtime that path is shadowed by the mounted FAT partition anyway.
- The generic script does `fatload mmc 0:1 Image` + takes `bootargs` from the
  DTB `/chosen` node → `root=/dev/mmcblk0p2`. That points at the raw
  `uboot_env` partition (no filesystem) → kernel cannot mount root → panic →
  reboot → loop. (Matches the observed "LEDs blink then reboot" symptom; not a
  watchdog.)

**Evidence:** card `boot.scr` was 262 bytes (generic) vs. our 4051-byte A/B
script; env `filesize=0x1a21a00` == the 27 MB `Image` on FAT; `root_a` ext4
mount count stayed 0 (kernel never mounted the real rootfs).

A one-off manual patch (copy the built A/B `boot.scr` from `root_a`'s
`/boot/firmware/` onto the FAT partition, delete the stale `uboot.env`) made the
board boot and the station-agent send heartbeats — confirming the diagnosis.
This spec makes every built image correct so the manual patch is unnecessary.

### Defect B — U-Boot environment stored where userspace does not write it

The U-Boot "environment" holds the A/B control variables (`boot_part`,
`bootcount`, `upgrade_available`, `bootlimit`). Two parties use it:

- **U-Boot** at boot (reads state, increments `bootcount`, `saveenv`).
- **station-agent** in userspace via `fw_setenv` (commits a healthy boot:
  `bootcount=0`, `upgrade_available=0`).

They currently disagree. U-Boot uses its default env location (a `uboot.env`
file on the FAT partition — `CONFIG_ENV_IS_IN_FAT`), while `fw_env.config`
points `fw_setenv` at the raw `uboot_env`/`uboot_envr` partitions. The commit
writes a note U-Boot never reads → OTA commit and rollback are silently
non-functional.

The wks intentionally created two raw 1 MB env partitions (`uboot_env` +
`uboot_envr`, the "r" = redundant) — the original intent was raw, redundant MMC
env. Only the U-Boot config to activate it was missing. This is the existing
`FIXME(u-boot-env-partition)` in `u-boot-ab_1.0.bb`.

## Goals

1. Every built `raspberrypi4-64` image boots via our A/B `boot.scr` (kernel +
   DTB `ext4load`ed from the active `root_<slot>`), with no manual card patch.
2. U-Boot and `fw_setenv` read/write the **same** environment, so OTA commit and
   A/B rollback work.
3. The environment is **redundant** (two copies) so a power loss during a write
   — which happens on nearly every boot via `saveenv` — cannot leave the board
   with a single corrupted, unbootable env. This is the robustness driver for an
   unattended remote station.

## Non-Goals (YAGNI)

- `data-grow.service` (the data partition staying at 2 GB). Separate concern,
  explicitly deferred by the user.
- Any change to A/B variable semantics or the rollback control flow in
  `boot.cmd` — the logic is correct; it simply never took effect.
- Rebuild / reflash / HIL as part of this task. Verification here is code review
  only; the user will build, flash, and test on the CM4 later.

## Design

### Fix A — deploy our `boot.scr` onto the FAT partition

Mirror the x86 `grub-ab` → `grubenv` pattern that already works:

- Add a `do_deploy` task to `u-boot-ab` that installs the compiled `boot.scr`
  into `DEPLOY_DIR_IMAGE` (exactly as `grub-ab` deploys `grubenv`).
- In the image recipe, add our `boot.scr` to `IMAGE_BOOT_FILES` for
  `raspberrypi4-64` so wic copies **our** script onto the FAT partition, taking
  precedence over the generic one from `rpi-u-boot-scr`.
- Keep the existing rootfs install of `boot.scr`/`boot.cmd` (harmless; useful as
  the on-device reference the manual recovery used).

Implementation detail deferred to the plan: whether precedence is achieved by
ordering within `IMAGE_BOOT_FILES` or by removing `rpi-u-boot-scr`'s
contribution. The plan will pick whichever wic actually honors deterministically
and document why.

### Fix B — redundant raw MMC environment

Only the U-Boot side is missing; `fw_env.config` already lists both raw
partitions at offset 0, which is correct for redundant raw access.

Add a U-Boot config fragment via the existing `u-boot_%.bbappend`
(`SRC_URI:append:raspberrypi4-64`, alongside `oe5xrx-ext4.cfg` /
`oe5xrx-wdt.cfg`):

- `CONFIG_ENV_IS_IN_MMC=y`, redundant environment enabled
  (`CONFIG_SYS_REDUNDAND_ENVIRONMENT` / the board's redundant-env symbol),
  `CONFIG_ENV_IS_IN_FAT` disabled.
- `CONFIG_ENV_OFFSET` = byte offset of `uboot_env`, `CONFIG_ENV_OFFSET_REDUND`
  = byte offset of `uboot_envr`. Derived from the wks partition layout
  (observed ≈ `0x4005000` and `0x4105000`); the plan recomputes these exactly
  from the wks and cross-checks against a freshly built image before trusting
  them.
- `CONFIG_ENV_SIZE=0x10000` to match the `0x10000` env size declared in
  `fw_env.config`, so U-Boot and `fw_setenv` address identical byte ranges.

Result: U-Boot and userspace share one redundant env. `boot.cmd`'s `saveenv`
and the station-agent's `fw_setenv` commit now land where both read.

### Coupling note (documented in-tree)

The U-Boot env offsets are hard constants that MUST match the wks partition
offsets. A comment at both sites (the U-Boot config fragment and the wks env
partitions) records this dependency so a future partition-layout change pulls
the offsets along. Resolve and delete the existing
`FIXME(u-boot-env-partition)` in `u-boot-ab_1.0.bb`.

## Affected files (anticipated)

- `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb` — add
  `do_deploy` for `boot.scr`; remove the resolved `FIXME`.
- `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`
  — `IMAGE_BOOT_FILES` (RPi) for our `boot.scr`.
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend` +
  a new `files/oe5xrx-env.cfg` fragment — redundant MMC env config.
- `meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in` — coupling
  comment on the env partitions (offsets are the source of truth).

## Verification (code review only)

- Compare Fix A against the working x86 `grub-ab`/`grubenv` deploy pattern for
  structural equivalence.
- Confirm the U-Boot env offsets against the wks layout arithmetic and against
  `fw_env.config`'s device lines and size.
- Confirm `CONFIG_ENV_SIZE` == `fw_env.config` env size.
- No build/flash/HIL in this task; the user validates on the CM4 afterward.
