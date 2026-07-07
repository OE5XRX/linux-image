# OTA Kernel-in-Rootfs A/B + Boot Robustness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OTA update the kernel atomically with its rootfs by moving the kernel into each rootfs `/boot` and having the bootloader load it from the active `root_${slot}` partition, plus add fail-fast + watchdog boot robustness — all without any `station-manager`/agent change.

**Architecture:** Kernel + DTB + modules ship inside each rootfs. On x86, GRUB-EFI does `search --label root_${boot_part}` then `linux /boot/bzImage`; on RPi, u-boot `ext4load`s `/boot/Image` + dtb from the slot's rootfs. The existing rootfs-only OTA now inherently carries the kernel. Bootloaders reboot on any load failure; kernel cmdline + systemd + a hardware watchdog turn panics *and* hangs into reboots that the existing `bootcount` machinery rolls back.

**Tech Stack:** Yocto (scarthgap, kas), GRUB-EFI, u-boot, wic, systemd, linux-yocto.

**Spec:** `docs/superpowers/specs/2026-07-07-ota-kernel-in-rootfs-ab-design.md`

## Global Constraints

- **Unified kernel cmdline (identical on both platforms; only the console devices differ):**
  - Common tail: `root=PARTLABEL=root_${slot} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1`
  - x86 consoles: `console=tty0 console=ttyS0,115200`
  - RPi consoles: `console=tty1 console=serial0,115200`
- **`${slot}` / `${boot_part}`** is `a` or `b`, resolved from the A/B env — never hard-coded.
- **No changes** to `station-manager` or `station_agent`. The OTA artifact stays "the whole `root_a` partition, bz2". Do not touch `apps/**` or `station_agent/**`.
- **Keep the two bootloader scripts line-for-line mirrors** where syntax allows (same var names, same order, same comments).
- **Kernel is pinned** — no `AUTOREV`/floating; version bumps are deliberate.
- **Read-only rootfs** — the kernel in `/boot` is read at boot by the bootloader before mount; never written at runtime.
- **Measured headroom:** `root_a` uses 229 MB / 1024 MB (22%). Adding the kernel (~12 MB) stays far under. Do **not** resize partitions.
- **Verification reality:** there is no unit-test harness; each task's "test" is a `bitbake -e`/`kas`/file-inspection check, or a QEMU boot via `scripts/run-qemu.sh`. Full image builds run on CI (self-hosted runner) — a local `kas build qemux86-64.yml` is the gold standard when the environment allows it; otherwise push and let CI build, and state verification status explicitly.

---

## Phase A — x86 / GRUB-EFI: load kernel from rootfs

### Task A1: GRUB can read ext4 + search by label

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/grub/grub-efi_%.bbappend`

**Interfaces:**
- Produces: a `bootx64.efi` whose built-in modules include `ext2`, `part_gpt`, `search`, `search_label` so `grub.cfg` can `search --label` an ext4 partition and `linux` a file from it.

- [ ] **Step 1: Add the fs/search modules to GRUB_BUILDIN**

In `grub-efi_%.bbappend`, extend the existing `GRUB_BUILDIN:append` line (currently `" echo"`):

```
# ext2 reads ext4; part_gpt + search/search_label let grub.cfg locate the
# active root_${boot_part} partition and load /boot/bzImage from inside it.
GRUB_BUILDIN:append = " echo ext2 part_gpt search search_label search_fs_uuid"
```

- [ ] **Step 2: Verify the recipe still parses**

Run: `kas shell oe5xrx.yml:qemux86-64.yml -c "bitbake -e grub-efi | grep '^GRUB_BUILDIN='"` (or, if no build env, `grep GRUB_BUILDIN meta-oe5xrx-remotestation/recipes-bsp/grub/grub-efi_%.bbappend`)
Expected: the value contains `ext2 part_gpt search search_label`.

- [ ] **Step 3: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/grub/grub-efi_%.bbappend
git commit -m "grub-efi: build in ext2/search modules so grub can load kernel from rootfs"
```

### Task A2: grub.cfg loads the kernel from the active rootfs slot (fail-fast)

**Files:**
- Modify: `meta-oe5xrx-remotestation/wic/oe5xrx-grub.cfg`

**Interfaces:**
- Consumes: ext2/search modules from Task A1; a `/boot/bzImage` inside each rootfs (Task A3).
- Produces: a boot that runs the kernel from `root_${boot_part}` with the unified x86 cmdline and never sits at a prompt.

- [ ] **Step 1: Replace the kernel-load tail of `oe5xrx-grub.cfg`**

Change the final block (currently `set root_label=...` / `linux /bzImage ...` / `boot`) to:

```
# Load the kernel from INSIDE the active slot's rootfs, so the kernel always
# matches its /lib/modules and ext4 (OTA writes the whole rootfs atomically).
search --no-floppy --label root_${boot_part} --set=root || reboot
linux /boot/bzImage root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 console=tty0 console=ttyS0,115200
boot

# Fail-fast: if search or boot ever falls through (kernel/FS unreadable),
# reboot instead of dropping to a prompt. bootcount was already incremented
# and saved above, so this progresses toward A/B rollback.
reboot
```

- [ ] **Step 2: Force non-interactive/fail-fast timeout**

Near the top of `oe5xrx-grub.cfg`, ensure `set timeout=0` (change the existing `set timeout=3`). A hung/failed load must not wait for a human.

- [ ] **Step 3: Static syntax sanity check**

Run: `grep -nE 'search --label|linux /boot/bzImage|reboot|timeout=0' meta-oe5xrx-remotestation/wic/oe5xrx-grub.cfg`
Expected: the new `search`, `linux /boot/bzImage`, trailing `reboot`, and `timeout=0` are all present; no stale `linux /bzImage`.

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/wic/oe5xrx-grub.cfg
git commit -m "grub: load kernel from active rootfs slot + fail-fast reboot"
```

### Task A3: ensure the kernel is in the rootfs; stop relying on the ESP copy

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`

**Interfaces:**
- Consumes: nothing.
- Produces: `/boot/bzImage` (+ `/lib/modules/<ver>`) present in the rootfs so Task A2's `linux /boot/bzImage` resolves.

- [ ] **Step 1: Install the kernel image + modules into the rootfs**

After the base `IMAGE_INSTALL` block, add:

```
# Kernel-in-rootfs A/B: the bootloader loads /boot/bzImage (x86) / /boot/Image
# (RPi) from the ACTIVE root_${slot}, so kernel + modules must live in the
# rootfs and travel with it through OTA (one artifact, atomic per slot).
IMAGE_INSTALL:append = " kernel-image kernel-modules"
```

- [ ] **Step 2: Verify a stable /boot kernel symlink exists after build**

Run (in a build env): `kas shell oe5xrx.yml:qemux86-64.yml -c "ls -l tmp/work/qemux86-64*/oe5xrx-remotestation-image/*/rootfs/boot/ | grep -i bzimage"`
Expected: a `/boot/bzImage` (symlink to `bzImage-<version>`). If only the versioned file exists, add a `ROOTFS_POSTPROCESS_COMMAND` to symlink `/boot/bzImage -> bzImage-<ver>`; document the exact name found.
If no build env: note this as a build-time verification gate for Task A4.

- [ ] **Step 3: Drop / neutralize the stale ESP kernel (best-effort)**

The `bootimg-efi` wic plugin copies `${KERNEL_IMAGETYPE}` onto the ESP. Since grub.cfg no longer loads it, it is dead weight. During the Task A4 build, inspect the ESP; if the plugin still copies `bzImage`, leave it (harmless on the 128 MB ESP) **and add a comment** in the image recipe noting the ESP `bzImage` is unused (kernel is loaded from the rootfs). Only remove it if the plugin exposes a clean switch — do not fight the plugin.

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "image: install kernel-image + modules into rootfs for kernel-in-rootfs A/B"
```

### Task A4: build x86 + QEMU boot + rollback verification

**Files:**
- Test only (no source changes unless a gate above surfaced one).

- [ ] **Step 1: Build the x86 image**

Run: `kas build oe5xrx.yml:qemux86-64.yml`
Expected: build succeeds; a `*.rootfs.wic` under `build/tmp/deploy/images/qemux86-64/`.

- [ ] **Step 2: Boot and confirm the kernel loads from the rootfs**

Run: `timeout 120 scripts/run-qemu.sh < /dev/null | tee /tmp/bootA.log; grep -E "OE5XRX: slot=|Kernel .* on an x86_64|login:" /tmp/bootA.log`
Expected: GRUB prints the A/B status line, the kernel boots, and a `login:` prompt appears — i.e. the kernel came from `/boot/bzImage` in `root_a`.

- [ ] **Step 3: Prove A/B kernel rollback**

Boot once, then from inside the guest corrupt the trial slot's kernel and arm a trial:
```
# In guest:
grub-editenv /boot/EFI/BOOT/grubenv set boot_part=b upgrade_available=1 bootcount=0
# root_b has an empty/again-unbootable kernel -> trial must fail 3x -> rollback to a
reboot
```
Expected (watch serial): slot=b attempts climb to `>bootlimit`, GRUB prints "rolling back", next boot is `slot=a` and reaches `login:`. Capture the log.

- [ ] **Step 4: Commit the evidence note**

```bash
git commit --allow-empty -m "test(x86): kernel-in-rootfs boots + A/B kernel rollback verified in QEMU"
```

---

## Phase B — RPi / u-boot: load kernel from rootfs

### Task B1: u-boot can read ext4

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend` (path/name per the actual u-boot recipe in the RPi layer — verify with `bitbake -e virtual/bootloader | grep ^PN=`)
- Create: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-ext4.cfg`

**Interfaces:**
- Produces: a u-boot with `CONFIG_FS_EXT4` + `CONFIG_CMD_EXT4` so `boot.cmd` can `ext4load`.

- [ ] **Step 1: Add a config fragment**

`oe5xrx-ext4.cfg`:
```
CONFIG_FS_EXT4=y
CONFIG_CMD_EXT4=y
CONFIG_CMD_FS_GENERIC=y
```

`u-boot_%.bbappend`:
```
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg"
```

- [ ] **Step 2: Verify the fragment is picked up**

Run: `kas shell oe5xrx.yml:raspberrypi4.yml -c "bitbake -e virtual/bootloader | grep -i 'FS_EXT4\|SRC_URI'"` (adjust the machine yml to the actual RPi config).
Expected: `oe5xrx-ext4.cfg` appears in SRC_URI. (If the RPi u-boot already has `CONFIG_FS_EXT4=y` in defconfig, keep the fragment as an explicit guarantee and note it.)

- [ ] **Step 3: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot/
git commit -m "u-boot: enable ext4 fs support so boot.cmd can load kernel from rootfs"
```

### Task B2: boot.cmd loads kernel + dtb from the rootfs slot (fail-fast)

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`

**Interfaces:**
- Consumes: ext4 support (B1); `/boot/Image` + `/boot/bcm2711-rpi-cm4.dtb` in each rootfs (B4).
- Produces: an RPi boot that runs the slot's own kernel with the unified RPi cmdline, resetting on any load failure.

- [ ] **Step 1: Map slot -> rootfs partition number and ext4load from it**

Replace the current `part number ... boot_${boot_part}` + `load mmc 0:${active_boot_part} ... Image/dtb` block. The wks (after Task B3) is: `1 firmware  2 uboot_env  3 uboot_envr  4 root_a  5 root_b  6 data`. Resolve the rootfs partition by label to avoid hard-coding numbers:

```
# Kernel + dtb now live INSIDE the slot's rootfs (ext4), so they always match
# /lib/modules and travel with the rootfs through OTA.
part number mmc 0 root_${boot_part} root_partnum
if test -z "${root_partnum}"; then
    echo "  ERROR: root_${boot_part} partition not found — resetting"
    reset
fi

echo "  Loading kernel + dtb from rootfs mmc 0:${root_partnum} (/boot)"
if ext4load mmc 0:${root_partnum} ${kernel_addr_r} /boot/Image; then
    if ext4load mmc 0:${root_partnum} ${fdt_addr_r} /boot/bcm2711-rpi-cm4.dtb; then
        setenv bootargs "root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 console=tty1 console=serial0,115200"
        booti ${kernel_addr_r} - ${fdt_addr_r}
    fi
fi

# Fail-fast: any load failure or a returned booti falls through to reset.
# bootcount was already incremented+saved, so this progresses to rollback.
echo "  Kernel/dtb load failed — resetting"
reset
```

- [ ] **Step 2: Static check**

Run: `grep -nE 'ext4load|root_partnum|panic=5|softlockup_panic=1|reset' meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`
Expected: `ext4load` from `root_${boot_part}`, unified cmdline, and the trailing `reset` are present; no stale `load mmc 0:${active_boot_part} ... Image`.

- [ ] **Step 3: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd
git commit -m "boot.cmd: ext4load kernel+dtb from rootfs slot + fail-fast reset"
```

### Task B3: drop boot_a/boot_b from the RPi wks

**Files:**
- Modify: `meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in`

- [ ] **Step 1: Remove the two boot_* partition lines**

Delete:
```
part --ondisk mmcblk0 --fstype=vfat --label boot_a --fixed-size 64 --align 4
part --ondisk mmcblk0 --fstype=vfat --label boot_b --fixed-size 64 --align 4
```
Update the layout comment block accordingly (partitions renumber: firmware 1, uboot_env 2, uboot_envr 3, root_a 4, root_b 5, data 6).

- [ ] **Step 2: Check consistency with boot.cmd**

Run: `grep -nE 'boot_a|boot_b' meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`
Expected: no matches (both platforms now key off `root_${slot}` only).

- [ ] **Step 3: Commit**

```bash
git add meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in
git commit -m "wks(rpi): drop unused boot_a/boot_b — kernel loads from rootfs now"
```

### Task B4: RPi kernel image + dtb in the rootfs

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`

- [ ] **Step 1: Add the devicetree to the rootfs for RPi**

`kernel-image`/`kernel-modules` (Task A3) are machine-agnostic; add the dtb for RPi:
```
# RPi: u-boot ext4load's /boot/Image + the CM4 dtb from the rootfs slot.
IMAGE_INSTALL:append:raspberrypi4-64 = " kernel-devicetree"
```

- [ ] **Step 2: Verify (build env) the dtb + Image land in the rootfs /boot**

Run: `kas shell oe5xrx.yml:raspberrypi4.yml -c "ls tmp/work/raspberrypi4*/oe5xrx-remotestation-image/*/rootfs/boot/ | grep -E 'Image|bcm2711-rpi-cm4.dtb'"`
Expected: both `Image` and `bcm2711-rpi-cm4.dtb` present. If the dtb name differs, update `boot.cmd` (Task B2) to match; document the exact name.

- [ ] **Step 3: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "image(rpi): install kernel-devicetree into rootfs for u-boot ext4load"
```

---

## Phase C — Boot robustness (shared)

### Task C1: hung-task panic sysctl (both platforms)

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/oe5xrx-boot-robustness_1.0.bb`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/50-oe5xrx-panic.conf`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`

**Interfaces:**
- Produces: a package `oe5xrx-boot-robustness` that drops a sysctl.d file turning hung tasks into panics (complements the cmdline `panic=5 softlockup_panic=1`).

- [ ] **Step 1: sysctl drop-in**

`50-oe5xrx-panic.conf`:
```
# Turn silent kernel hangs into panics so panic=5 reboots the box and the
# A/B bootcount machinery rolls back. Pairs with cmdline softlockup_panic=1.
kernel.hung_task_panic = 1
kernel.hung_task_timeout_secs = 60
```

- [ ] **Step 2: recipe**

`oe5xrx-boot-robustness_1.0.bb`:
```
SUMMARY = "OE5XRX boot robustness: hung-task panic sysctl + watchdog glue"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://50-oe5xrx-panic.conf"
S = "${WORKDIR}"
inherit allarch
do_install() {
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${WORKDIR}/50-oe5xrx-panic.conf ${D}${sysconfdir}/sysctl.d/
}
FILES:${PN} = "${sysconfdir}/sysctl.d/50-oe5xrx-panic.conf"
```

- [ ] **Step 3: install into image**

Add to base `IMAGE_INSTALL`:
```
IMAGE_INSTALL:append = " oe5xrx-boot-robustness"
```

- [ ] **Step 4: Verify parse + commit**

Run: `bitbake -e oe5xrx-boot-robustness | grep '^FILES' || grep -r hung_task meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness`
Expected: the sysctl file is packaged.
```bash
git add meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "boot-robustness: hung_task_panic sysctl drop-in"
```

### Task C2: systemd runtime watchdog (both platforms)

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/watchdog.conf`
- Modify: `oe5xrx-boot-robustness_1.0.bb`

**Interfaces:**
- Consumes: a `/dev/watchdog` device (RPi `bcm2835_wdt`, x86 `i6300esb` — Task C3/C4).
- Produces: systemd petting the watchdog so a hung userspace stops petting → hardware reset.

- [ ] **Step 1: systemd system.conf drop-in**

`watchdog.conf`:
```
# systemd pets /dev/watchdog every RuntimeWatchdogSec; if systemd or the box
# wedges, the hardware watchdog fires -> reset -> bootcount -> A/B rollback.
[Manager]
RuntimeWatchdogSec=30
ShutdownWatchdogSec=2min
```

- [ ] **Step 2: install it to `/etc/systemd/system.conf.d/`**

Extend the recipe `do_install`:
```
    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${WORKDIR}/watchdog.conf ${D}${sysconfdir}/systemd/system.conf.d/
```
Add to SRC_URI: `file://watchdog.conf`; add to FILES: `${sysconfdir}/systemd/system.conf.d/watchdog.conf`.

- [ ] **Step 3: Verify + commit**

Run: `grep -n 'RuntimeWatchdogSec' meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/watchdog.conf`
```bash
git add meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness
git commit -m "boot-robustness: systemd RuntimeWatchdogSec drop-in"
```

### Task C3: watchdog drivers in the kernel + RPi u-boot arming

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-kernel/linux/files/oe5xrx-watchdog.cfg`
- Create/Modify: `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend`
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-ext4.cfg` (rename to `oe5xrx.cfg`, add watchdog) or add a second fragment.

**Interfaces:**
- Produces: `bcm2835_wdt` + `i6300esb` built-in; RPi u-boot arms the SoC watchdog before booting the kernel.

- [ ] **Step 1: kernel watchdog config fragment**

`oe5xrx-watchdog.cfg`:
```
CONFIG_WATCHDOG=y
CONFIG_WATCHDOG_CORE=y
# RPi CM4 / BCM2711 SoC watchdog
CONFIG_BCM2835_WDT=y
# QEMU/Proxmox emulated watchdog (q35 / -watchdog i6300esb)
CONFIG_I6300ESB_WDT=y
```

`linux-yocto_%.bbappend`:
```
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"
```

- [ ] **Step 2: RPi u-boot arms the watchdog before booting**

In `boot.cmd`, right after the bootcount increment/save (before loading the kernel), add:
```
# Arm the SoC watchdog as early as possible so even a pre-systemd hang forces
# a reset. systemd (RuntimeWatchdogSec) takes over petting once userspace is up.
wdt dev watchdog@7e100000 || echo "  (no wdt device — continuing)"
wdt start 15000 || echo "  (wdt start failed — continuing)"
```
(Verify the RPi u-boot has `CONFIG_WDT`/`CONFIG_CMD_WDT`; if not, add to the u-boot fragment. The exact `wdt dev` name is verified on-target; the `|| echo` keeps boot working if the name differs — never let watchdog setup itself brick the boot.)

- [ ] **Step 3: enable CMD_WDT in u-boot fragment**

Append to the u-boot fragment:
```
CONFIG_WDT=y
CONFIG_CMD_WDT=y
CONFIG_WDT_BCM2835=y
```

- [ ] **Step 4: Verify + commit**

Run: `grep -rn 'BCM2835_WDT\|I6300ESB_WDT\|wdt start' meta-oe5xrx-remotestation/recipes-kernel meta-oe5xrx-remotestation/recipes-bsp`
```bash
git add meta-oe5xrx-remotestation/recipes-kernel meta-oe5xrx-remotestation/recipes-bsp
git commit -m "watchdog: build in bcm2835/i6300esb drivers + arm SoC wdt in u-boot"
```

### Task C4: pin the kernel + document Proxmox watchdog

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend`
- Modify: `docs/` (a short operator note) and/or `scripts/run-qemu.sh` (add `-device i6300esb -action watchdog=reset` (the legacy `-watchdog` shorthand was removed in QEMU 9+) so the dev QEMU exercises it).

- [ ] **Step 1: Pin the kernel version**

Determine the current version: `bitbake -e virtual/kernel | grep '^PV='` (e.g. `6.6.142`). Add to the bbappend:
```
# Pin the kernel so version/ext4-format drift is deliberate, not silent.
# Kernel-in-rootfs makes drift safe; this makes it intentional.
PREFERRED_VERSION_linux-yocto = "6.6.%"
```
(Use the actual major.minor found; keep the `%` patch wildcard so security patches within the series still flow.)

- [ ] **Step 2: Make dev QEMU exercise the watchdog**

In `scripts/run-qemu.sh`, add to the `qemu-system-x86_64` args: `-device i6300esb -action watchdog=reset` (the legacy `-watchdog` shorthand was removed in QEMU 9+) (so a guest hang resets the VM in local testing, mirroring Proxmox). Add a one-line operator note in the run-qemu header + a `docs/` note that Proxmox VMs need a watchdog device with `action=reset`.

- [ ] **Step 3: Verify + commit**

Run: `grep -n 'PREFERRED_VERSION_linux-yocto\|watchdog i6300esb' meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend scripts/run-qemu.sh`
```bash
git add meta-oe5xrx-remotestation/recipes-kernel scripts/run-qemu.sh docs/
git commit -m "kernel: pin linux-yocto series; qemu+docs exercise the watchdog"
```

### Task C5: full-stack verification pass

- [ ] **Step 1: Rebuild x86 and re-run the QEMU boot + rollback checks (Task A4) with all robustness flags active**

Run: `kas build oe5xrx.yml:qemux86-64.yml && timeout 150 scripts/run-qemu.sh < /dev/null | tee /tmp/bootC.log`
Expected: boots to `login:`; `dmesg`/serial shows the watchdog driver bound (`i6300esb`), cmdline shows `panic=5 softlockup_panic=1 fsck.repair=yes console=tty0 console=ttyS0`.

- [ ] **Step 2: Hang test → watchdog reset → rollback**

Arm a trial on `root_b`, then from the guest wedge userspace (e.g. `echo c > /proc/sysrq-trigger` is a crash → panic path; for a true hang, mask the getty + spin). Expected: the box resets (not hangs), bootcount climbs, GRUB rolls back to `root_a`. Capture the log.

- [ ] **Step 3: Confirm no station-manager/agent files were touched**

Run: `git diff --name-only origin/main | grep -E '^apps/|station_agent/' || echo "clean: no server/agent changes"`
Expected: `clean: no server/agent changes`.

- [ ] **Step 4: Commit evidence**

```bash
git commit --allow-empty -m "test: full boot-robustness + rollback verified; no server/agent changes"
```

---

## Self-Review Notes (author)

- **Spec coverage:** §3 kernel-in-rootfs → A2/A3/B2/B4; §4.1 x86 grub → A1/A2; §4.2 RPi u-boot → B1/B2/B3; §5 build/pin → A3/B4/C4; §6.1 cmdline → A2/B2 (unified via Global Constraints); §6.2 systemd wdt → C2; §6.3 hw wdt → C3/C4; §6.4 fail-fast → A2/B2; §7 no server change → verified in C5-step3; §8 trial semantics → unchanged (A4/C5 rollback tests).
- **Verification honesty:** all QEMU/build steps are gated on a build environment; where unavailable, the task says push→CI. Do not claim boot-verified without a captured log.
- **Watchdog never bricks boot:** every watchdog setup step in u-boot uses `|| echo` fallthrough; the driver config is additive.
