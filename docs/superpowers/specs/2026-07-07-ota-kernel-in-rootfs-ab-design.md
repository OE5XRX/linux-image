# OTA Kernel Updates via Kernel-in-Rootfs (A/B) + Boot Robustness

**Status:** Design approved (brainstorming), pending implementation plan
**Date:** 2026-07-07
**Repos touched:** `linux-image` (all code changes). `station-manager` and `station_agent` are **verified unchanged** (see §7).
**Supersedes / closes the gap behind:** the D2 OTA boot failure (release `2026.07.05-08`), where a trial slot hung at boot because the frozen ESP kernel did not match the freshly-OTA'd rootfs.

---

## 1. Problem

On the A/B remote-station images, OTA only rewrites the rootfs partition
(`station_agent/ota.py::install_to_slot` stream-decompresses the rootfs `.bz2`
block-level into `/dev/disk/by-partlabel/root_${slot}`). The **kernel is not part
of that write**:

- **x86-64 / GRUB-EFI:** `/bzImage` lives on the shared **ESP**; `grub.cfg` does
  `linux /bzImage`. The ESP is written once at flash time and never updated by OTA.
- **RPi / u-boot:** `boot.cmd` loads `Image` + `dtb` from per-slot **`boot_a`/`boot_b`
  FAT partitions**, but OTA never writes those either.

The kernel is also **unpinned** (no `PREFERRED_VERSION_linux-yocto`), so every rebuild
can float the kernel version and rebuild the ext4 with newer tooling. Result: an OTA
delivers a rootfs whose `/lib/modules/<ver>` and ext4 format no longer match the
frozen bootloader-side kernel → the trial slot cannot boot.

Because the failure happens before userspace, the station-agent never commits, so
`bootcount` runs up and the bootloader rolls back — but only after the box sits dead.
On x86 the kernel cmdline had `console=ttyS0` only, so on a graphical console (Proxmox
VNC) there was nothing but a blinking cursor, making it undebuggable.
(The `console=tty0` half is handled by the separate PR #29.)

## 2. Goal & Principles

1. **OTA must ship a kernel that always matches its rootfs.** Kernel/module mismatch
   must be impossible **by construction**, not by discipline.
2. **Fail as early as possible.** Any boot fault (kernel can't load, FS unreadable,
   kernel hangs) must lead to a **reboot** as early as possible, so the existing
   `bootcount` → rollback machinery recovers automatically with **no human**.
3. **RPi and x86 behave identically in logic.** "One boot logic, two bootloader
   dialects." Same env variables, same cmdline flag set, same failure handling, same
   watchdog semantics, same rollback. You should never have to think about *where*
   something lives per platform.
4. **Minimal blast radius.** No changes to `station-manager` or the agent's OTA
   artifact model.

## 3. Architecture — Kernel-in-Rootfs

**Core idea:** the kernel (+ DTB on RPi + `/lib/modules`) lives **inside every rootfs**
under `/boot`. The bootloader loads the kernel **from the active `root_${slot}`
partition**. Because the existing OTA already writes the whole rootfs partition as one
atomic block, the kernel is updated **atomically together with its modules** — one
artifact, one write, per slot.

Consequences:
- Kernel ↔ module ↔ ext4-format mismatch is **impossible** (same artifact).
- A/B **kernel** trial + rollback comes for free (a bad kernel is a bad slot).
- The **ESP** (x86) / **`firmware`** partition (RPi) become **fully static** — only the
  bootloader + its config live there; OTA never touches them.
- The OTA artifact (the extracted `root_a` partition, see §7) now inherently carries
  the kernel, flowing through the **existing** pipeline unchanged.

## 4. Per-Platform Bootloader Changes

### 4.1 x86-64 / GRUB-EFI
- `wic/oe5xrx-grub.cfg` (the ESP config, referenced by the wks `--configfile`):
  - Select the slot's rootfs and load the kernel from it:
    ```
    search --no-floppy --label root_${boot_part} --set=root
    linux /boot/bzImage root=PARTLABEL=root_${boot_part} <common cmdline>
    boot
    ```
  - **Fail-fast:** `set timeout=0`, no interactive menu; add a trailing `reboot` so if
    `boot` ever returns (kernel/FS load failed) GRUB reboots instead of dropping to a
    prompt. Guard the `search` so an unreadable/absent slot also reboots.
- `bzImage` is **removed from the ESP** — no longer copied via `IMAGE_EFI_BOOT_FILES`.
  ESP now holds only GRUB + `grub.cfg` + `grubenv`.
- Requires the **ext4 module** in the grub-efi image (verify `GRUB_MODULES`/build).
- A stable kernel filename `/boot/bzImage` must exist in the rootfs (symlink or
  `KERNEL_IMAGE_NAME`/link so GRUB has a fixed path).

### 4.2 RPi / u-boot
- `recipes-bsp/u-boot-ab/files/boot.cmd`:
  - Load kernel + dtb from the slot's rootfs (ext4) instead of `boot_${slot}` FAT:
    ```
    ext4load mmc 0:${root_partnum} ${kernel_addr_r} /boot/Image   || reset
    ext4load mmc 0:${root_partnum} ${fdt_addr_r}   /boot/<dtb>    || reset
    booti ${kernel_addr_r} - ${fdt_addr_r}
    reset                # fail-fast fallthrough
    ```
  - Resolve `root_partnum` from the slot label (matches the wks).
- **`boot_a`/`boot_b` partitions are removed** from the RPi wks (no longer used). The
  FAT `firmware` partition (GPU firmware + u-boot + its own dtb + `boot.scr`) stays.
- Requires **`CONFIG_FS_EXT4`** in the RPi u-boot (verify; enable via bbappend/frag if
  missing).

## 5. Build Changes (Yocto)

- Ensure the **kernel image + DTB + modules** are installed into the rootfs `/boot` and
  `/lib/modules` (`kernel-image kernel-modules kernel-devicetree`), with a **stable
  kernel path/name** for the bootloader.
- **Stop** copying `bzImage` into the ESP (x86) and remove the now-unused
  `boot_a`/`boot_b` partitions (RPi — they were reserved but never populated, so the
  current RPi image path was effectively non-bootable; this fixes it by loading from
  the rootfs).
- **wks updates:**
  - x86 (`oe5xrx-remotestation-ab-x64.wks.in`): partitions unchanged
    (`efi + root_a + root_b + data`); only ESP contents change.
  - RPi (`oe5xrx-remotestation-ab.wks.in`): remove `boot_a` + `boot_b`.
- **Rootfs size:** kernel+modules add ~10–20 MB. `root_a`/`root_b` are **fixed 1024 MB**;
  this must still fit — enforced by the Yocto build itself (build fails otherwise), not
  at runtime.
- **Pin the kernel** (`PREFERRED_VERSION_linux-yocto`) so version drift is deliberate,
  not silent. (Kernel-in-rootfs makes drift *safe*; the pin makes it *intentional*.)

## 6. Boot Robustness (Watchdog + panic) — "fail early, recover automatically"

Applied **identically** on both platforms except where the hardware differs.

### 6.1 Kernel cmdline (identical flag set on both)
```
root=PARTLABEL=root_${slot} ro rootwait fsck.repair=yes net.ifnames=0 \
    panic=5 softlockup_panic=1 console=<screen> console=<serial>
```
plus `kernel.hung_task_panic=1` (via sysctl or cmdline).
- `panic=5` → clean panics self-reboot after 5 s.
- `softlockup_panic=1` + `hung_task_panic=1` → soft lockups / hung tasks become panics
  → reboot, instead of a silent hang.
- `fsck.repair=yes` → repair a dirty rootfs at mount (RPi already had it; x86 gains it).
- `rootwait` stays (device may appear late); the watchdog turns "device never appears"
  into a reset.
- consoles: x86 `console=tty0 console=ttyS0,115200`; RPi `console=tty1 console=serial0,115200`.

### 6.2 systemd watchdog
- Ship a `system.conf` drop-in: `RuntimeWatchdogSec=` (pet `/dev/watchdog` during normal
  operation) and `ShutdownWatchdogSec=`. A healthy system keeps petting; a hung/unhealthy
  one stops → hardware reset.
- (Optional, later) `station-agent` can additionally feed a per-service watchdog via
  `sd_notify WATCHDOG=1` so "kernel alive but agent dead" is caught too. Not required for
  v1.

### 6.3 Hardware watchdog per platform
- **RPi:** u-boot **arms the `bcm2835` watchdog before `booti`** — earliest possible
  point, covering u-boot-stage, kernel-load, and pre-systemd hangs. systemd takes over
  petting once up. **Airtight.**
- **x86/Proxmox:** GRUB cannot arm a watchdog; earliest coverage is the **built-in
  `i6300esb` kernel driver** (armed early, no initramfs before it) + systemd petting.
  The VM must expose the `i6300esb` watchdog device with `action=reset` (documented
  Proxmox config). Residual: a tiny pre-kernel-driver window is covered only by
  `panic=5`; optionally Proxmox host-side reset as a backstop. **Very good, not airtight**
  — an accepted, documented asymmetry (x86 is a VM; the mismatch class that actually bit
  us is already eliminated by §3).

### 6.4 Bootloader fail-fast
Both bootloaders **reboot on any load/read failure** and never present an interactive
prompt (see §4). Since `bootcount` is incremented+persisted **before** each boot attempt,
a load-failure reboot progresses straight toward rollback.

## 7. Explicitly NOT Changing (verified in code)

`station-manager` deploy/import and the agent's OTA download mechanic are **untouched**:
- **Import** (`apps/images/extraction.py`): extracts the `root_a` partition by GPT
  **partition name** + ext4-magic sanity check, bz2-compresses it. It **never inspects
  rootfs contents** — a kernel in `/boot` is transparent to it.
- **Deploy** (`apps/deployments/api_views.py`): streams the **opaque** rootfs bytes
  (`rootfs_s3_key`, Range support). Content-agnostic.
- **Size:** the extracted artifact is the whole **fixed 1024 MB** `root_a` partition
  (empty space compresses away). The kernel just occupies previously-free space inside
  those 1024 MB → `rootfs_size_bytes` is unchanged, the slot write still fits exactly.
- The agent's `install_to_slot` already does the right thing (block-write the rootfs to
  the slot); it now inherently delivers the kernel too. No agent change.

## 8. A/B Trial Semantics (unchanged)

`bootcount` / commit / rollback logic in `boot.cmd` and `grub.cfg` (and the agent's
`commit_boot_local`) are **unchanged and already mirrored** across platforms. New: the
kernel now lives in the slot, so it is automatically part of the trial. Combined with §6,
**both panics and hangs** lead to a reboot → `bootcount` → automatic rollback.

## 9. Testing

- **x86 (QEMU, `scripts/run-qemu.sh`):**
  - Boot with kernel loaded from the rootfs (baseline).
  - Inject a broken kernel into the trial slot (`root_b`), set `boot_part=b
    upgrade_available=1 bootcount=0` → verify `bootcount` climbs and GRUB rolls back to
    `root_a`.
  - Hang test (e.g. a unit that wedges early) → verify watchdog reset → rollback.
  - Verify kernel log + panic now appear on **both** serial and screen.
- **RPi (HIL, later):** verify u-boot `ext4load` of kernel+dtb from `root_${slot}`,
  u-boot watchdog arming, and rollback. Gated on verifying `CONFIG_FS_EXT4` + `bcm2835`
  watchdog in the RPi u-boot/kernel.

## 10. Risks / To Verify During Implementation

| Risk | Mitigation / check |
|------|--------------------|
| grub-efi lacks the ext4 module | Verify `GRUB_MODULES`; add `ext2`/`part_gpt` if missing |
| RPi u-boot lacks `CONFIG_FS_EXT4` | Verify defconfig; enable via bbappend fragment |
| Kernel config lacks `i6300esb` / `bcm2835_wdt` (built-in) | Verify/enable in kernel config fragment |
| Rootfs + kernel exceeds 1024 MB | Yocto build fails loudly; bump partition if ever needed |
| Unstable kernel filename breaks GRUB path | Pin `/boot/bzImage` name/symlink |
| x86 pre-driver early-hang window | Accepted + documented; `panic=5` + optional host-side reset |
| cmdline overlaps PR #29 (`console=tty0`) | Trivial merge; unified cmdline here includes it |

## 11. Out of Scope (possible follow-ups)

- **u-boot for x86** (as EFI payload under OVMF) for full one-script symmetry + closing
  the x86 watchdog window — parked pending a de-risking spike (can u-boot arm the
  watchdog as an EFI app on Proxmox?).
- `station-agent` `sd_notify` per-service watchdog integration.
- Per-slot kernel signing / verified boot.
