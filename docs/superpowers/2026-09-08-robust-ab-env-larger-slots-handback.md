# Handback — Robust A/B U-Boot Env + 2.5 GB Slots + data-grow

Date: 2026-09-08
Branch: `feat/robust-ab-env-larger-slots`
Spec: `docs/superpowers/specs/2026-09-08-robust-ab-env-larger-slots-design.md`
Plan: `docs/superpowers/plans/2026-09-08-robust-ab-env-larger-slots.md`

## Root cause (proven)

Every CM4 (u-boot) OTA failed at trial-boot **arming**: the rootfs write to the
inactive slot succeeded, then `set_upgrade_pending()` → `fw_setenv` failed with
*"Cannot read environment, using default"*, surfaced to the operator as the
generic *"Failed to write firmware to inactive partition"*.

The on-device u-boot env was **single-format** (`[CRC32][data]`) while
`/etc/fw_env.config` declared **redundant** (two partitions → tools expect a
1-byte flags field → CRC computed over the wrong range → refuse to read/write).
Proven by CRC math on the raw `uboot_env` partition and by `fw_printenv -c`
reading fine with a single-line config.

Why redundant never took effect: **u-boot 2026.01 renamed the Kconfig symbol
`SYS_REDUNDAND_ENVIRONMENT` → `ENV_REDUNDANT`.** The fragment set the old name,
which `merge_config` silently dropped (`Enable redundant environment support
(ENV_REDUNDANT) [N/y/?] n`). Latent + fleet-wide; CI never caught it because the
boot-OTA test runs on qemux86-64 (GRUB), not u-boot.

## What changed (branch commits)

1. **`build(u-boot)` guard** — `do_configure:append:raspberrypi4-64` fails the
   build unless `CONFIG_ENV_REDUNDANT=y` + `CONFIG_ENV_OFFSET_REDUND` are in the
   built `.config`. Self-enforcing against regression.
2. **`fix(u-boot)`** — `oe5xrx-env.cfg` now sets `CONFIG_ENV_REDUNDANT=y`
   (correct name). Built `.config` verified: `CONFIG_ENV_REDUNDANT=y`,
   `CONFIG_ENV_OFFSET_REDUND=0x4105000`, `CONFIG_ENV_IS_IN_MMC=y`.
3. **`feat(wic)` rpi + x64** — `root_a`/`root_b` 1024 → **2560 MiB**, `data`
   2048 → **512 MiB** (grows on first boot). Verified in both built wics; the
   `uboot_env`/`uboot_envr` partitions stayed at their absolute offsets
   (0x4005000 / 0x4105000) so the u-boot env offsets remain valid.
4. **`feat(ab-layout)` data-grow** — new `data-grow.service` + `data-grow.sh`,
   plus `run-qemu.sh --disk-size N`.

## Deviations from the written plan (both are improvements)

- **data-grow is sentinel-free, offline, pre-mount** (plan sketched a run-once
  sentinel after mount). The sentinel version would stamp itself even on a
  no-op first boot, so a *later* medium resize (the standard Proxmox
  `qm importdisk` small → `qm resize` bigger flow) would never grow. The final
  design runs `Before=mnt-data.mount`, is **free-space-gated + idempotent** (no
  sentinel), grows fully offline (no mounted-partition resize / partprobe
  issue), and self-heals after any later resize. `sgdisk -e` relocates the GPT
  backup header first; `parted resizepart` + `e2fsck -pf` + `resize2fs`; all
  timeout-guarded, robust-fail. `gptfdisk` added to `RDEPENDS`.
- **OTA test asserts durability via a post-commit reboot** (plan sketched
  parsing grubenv). After the agent commits, the money-test power-cycles and
  asserts slot B / the new tag comes up again — directly proving the trial
  flags were cleared (no rollback). Plus a standalone `test_partition_layout.py`
  asserting the 2.5 GiB slots.

## Verification done

- Guard RED on the unfixed tree, GREEN after the fix (real builds on the ydev box).
- rpi + x64 wics: `sgdisk -p` confirms 2.5 GiB slots, env partitions unmoved.
- data-grow logic tested offline against loopback copies of the built qemux86-64 wic:
  - wic-sized disk → *"no free space … nothing to do"* (no-op, no sentinel).
  - 8 GB disk → `data` 512 MiB → ~2.87 GiB (fills the rest after efi+2×2.5 GiB), fs mounts clean.
- Full A/B OTA-cycle + slot-size assertions run in the PR **boot-ota CI**
  (qemux86-64, TCG).

## OPERATOR ACTION — one-time reflash

Larger slots cannot be delivered by OTA (a 2.5 GB image will not fit an existing
1 GB slot). **Every station must be reflashed once** with a build off this
branch. A correctly-built redundant u-boot self-initializes its redundant env on
first boot, so there is no separate env migration. Station `192.168.88.211` (the
live single-mode-patched dev box) is reflashed too; its temporary patch becomes
moot.

## PENDING — CM4 HIL gate (Task 7, do at the device)

Not automatable; required before merge (honesty rule). On a real CM4 after reflash:
- `fw_printenv` reads with the shipped two-line redundant `fw_env.config`
  (no "Cannot read environment"); raw `uboot_env` shows CRC(4)+flags byte.
- Full OTA cycle from the server: arm → trial → commit (`upgrade_available=0`,
  `bootcount=0`) → durable; a forced-fail trial rolls back after `bootlimit`.
- `data` filled the eMMC after first boot (`df -h /mnt/data`).

Record results here when done.
