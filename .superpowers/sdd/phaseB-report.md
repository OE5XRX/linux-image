# Phase B Implementation Report — RPi / u-boot kernel-in-rootfs

Date: 2026-07-08
Branch: feat/kernel-in-rootfs-ab
Implementer: Forge (build systems agent)

---

## Task B1: u-boot can read ext4

**Files created:**
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-ext4.cfg`
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend`

**Static check (grep on created files):**
```
$ grep -n "oe5xrx-ext4.cfg\|FILESEXTRAPATHS\|SRC_URI" meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend
1:FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
2:SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg"
---
CONFIG_FS_EXT4=y
CONFIG_CMD_EXT4=y
CONFIG_CMD_FS_GENERIC=y
```

**Commit:** `8d6c075`

**Build-time gates / uncertainties:**

1. **CRITICAL GATE — u-boot recipe name:** The plan specifies `u-boot_%.bbappend` as the filename "per the actual u-boot recipe in the RPi layer." The `meta-raspberrypi` layer was NOT locally available (`kas` not run); no `PN=` from `bitbake -e virtual/bootloader` was possible. The bbappend uses `u-boot_%` (wildcard), which will match any `u-boot_<version>` recipe. If `meta-raspberrypi` uses a different PN (e.g. `u-boot-raspberrypi`), the bbappend will not apply and u-boot will not receive the fragment. **CI build gate:** confirm `bitbake -e virtual/bootloader | grep '^PN='` returns a `u-boot_...`-named recipe.

2. **GATE — CONFIG_FS_EXT4 already in defconfig:** If the RPi CM4's u-boot defconfig already includes `CONFIG_FS_EXT4=y`, the fragment is a no-op but harmless. If absent, this fragment adds it. Either way correct. Confirmed at build time via `bitbake -e virtual/bootloader | grep FS_EXT4`.

3. **GATE — SRC_URI:append machine name:** The machine name used here is `raspberrypi4-64` (from `raspberrypi4-64.yml` → `machine: raspberrypi4-64`). This matches the COMPATIBLE_MACHINE in `u-boot-ab_1.0.bb` (`raspberrypi.*`). Verify that BitBake's `MACHINEOVERRIDES` also includes `raspberrypi4-64` so the `SRC_URI:append:raspberrypi4-64` fires.

---

## Task B2: boot.cmd loads kernel + dtb from the rootfs slot (fail-fast)

**File modified:**
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`

**What changed:**
- Removed: `part number mmc 0 boot_${boot_part} active_boot_part` + old `load mmc 0:${active_boot_part} ...` + old cmdline (no panic/softlockup).
- Added: `part number mmc 0 root_${boot_part} root_partnum` + `ext4load` of `/boot/Image` and `/boot/bcm2711-rpi-cm4.dtb` + unified RPi cmdline with `panic=5 softlockup_panic=1` + fail-fast `reset` on any load failure.

**Static check (B2 Step 2):**
```
$ grep -nE 'ext4load|root_partnum|panic=5|softlockup_panic=1|reset' boot.cmd
45:part number mmc 0 root_${boot_part} root_partnum
46:if test -z "${root_partnum}"; then
47:    echo "  ERROR: root_${boot_part} partition not found — resetting"
48:    reset
51:echo "  Loading kernel + dtb from rootfs mmc 0:${root_partnum} (/boot)"
52:if ext4load mmc 0:${root_partnum} ${kernel_addr_r} /boot/Image; then
53:    if ext4load mmc 0:${root_partnum} ${fdt_addr_r} /boot/bcm2711-rpi-cm4.dtb; then
54:        setenv bootargs "root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 console=tty1 console=serial0,115200"
59:# Fail-fast: any load failure or a returned booti falls through to reset.
61:echo "  Kernel/dtb load failed — resetting"
62:reset
```

Stale `active_boot_part` / `load mmc 0:${active_boot_part}`: confirmed absent.

**Commit:** `973fc46`

**Build-time gates / uncertainties:**

1. **GATE — `part number` command availability:** The u-boot `part number mmc 0 <label> <varname>` command requires `CONFIG_CMD_PART`. Verify this is enabled in the RPi u-boot (either default defconfig or needs adding to `oe5xrx-ext4.cfg`). If absent, `root_partnum` will stay empty → `reset` is triggered → boot loop. Action: add `CONFIG_CMD_PART=y` to the fragment if CI build shows it missing.

2. **GATE — dtb filename in rootfs:** The script loads `/boot/bcm2711-rpi-cm4.dtb`. The `raspberrypi4-64.yml` sets `KERNEL_DEVICETREE = "broadcom/bcm2711-rpi-cm4.dtb"`. Yocto's kernel-devicetree package typically strips the leading subdirectory and installs as `/boot/bcm2711-rpi-cm4.dtb`. Verify with `ls tmp/work/raspberrypi4*/oe5xrx-remotestation-image/*/rootfs/boot/` on first CI build.

3. **GATE — `kernel_addr_r` / `fdt_addr_r` defined:** These are standard u-boot environment variables set by the RPi u-boot's board initialization. Verify they are defined for the CM4 target; if not, explicit `setenv` lines need to be added.

---

## Task B3: drop boot_a/boot_b from the RPi wks

**File modified:**
- `meta-oe5xrx-remotestation/wic/oe5xrx-remotestation-ab.wks.in`

**What changed:**
- Removed two `part` lines: `--label boot_a --fixed-size 64` and `--label boot_b --fixed-size 64` (both FAT vfat).
- Updated layout comment block: 8 partitions → 6 partitions, renumbered (firmware 1, uboot_env 2, uboot_envr 3, root_a 4, root_b 5, data 6).
- Added explanatory comment about the removal.

**Static check (B3 Step 2):**
```
$ grep -nE 'boot_a|boot_b' wic/oe5xrx-remotestation-ab.wks.in recipes-bsp/u-boot-ab/files/boot.cmd
wic/oe5xrx-remotestation-ab.wks.in:15:# boot_a/boot_b FAT partitions removed: u-boot now ext4loads /boot/Image and
```

The single match is a comment documenting the removal — no active partition definitions or boot.cmd references remain. Clean.

**Commit:** `8213bfd`

**No additional build-time gates.** The wks change is purely declarative; wic validation is syntax-only and will surface at `kas build` time if a label reference is missed. The only runtime risk is `fw_env.config` referencing partition offsets by number — the existing FIXME comment in `u-boot-ab_1.0.bb` already notes that env partition config is unresolved; the partition renumbering (root_a was 6, now 4) does not affect fw_env.config which references `uboot_env`/`uboot_envr` by offset, not by root_a number.

---

## Task B4: RPi kernel image + dtb in the rootfs

**File modified:**
- `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`

**What changed:**
- Added `IMAGE_INSTALL:append:raspberrypi4-64 = " kernel-devicetree"` under the RPi section (line 71).

**Static check:**
```
$ grep -n "kernel-devicetree\|kernel-image\|kernel-modules" oe5xrx-remotestation-image.bb
24:IMAGE_INSTALL:append = " kernel-image kernel-modules"
71:IMAGE_INSTALL:append:raspberrypi4-64 = " kernel-devicetree"
```

**Overlap note:** `include/raspberrypi.yml` (a kas include applied for all RPi builds) already has `IMAGE_INSTALL:append = " kernel-image kernel-devicetree"`. This means `kernel-devicetree` is doubly-appended for RPi builds — this is harmless in Yocto (duplicate entries in IMAGE_INSTALL are deduplicated at package selection time). The explicit entry in the image recipe makes the intent self-documenting and independent of kas includes.

**Commit:** `2f32143`

**Build-time gates / uncertainties:**

1. **GATE — dtb name in rootfs `/boot`:** As noted in B2, verify that `kernel-devicetree` installs `bcm2711-rpi-cm4.dtb` directly in `/boot/` (not in a subdirectory like `/boot/broadcom/`). If the Yocto kernel package places it in a subdirectory, the `boot.cmd` ext4load path `/boot/bcm2711-rpi-cm4.dtb` will fail. Fix would be either a ROOTFS_POSTPROCESS_COMMAND to create a symlink or updating boot.cmd to use the actual path.

2. **INFO — `kernel-image` for RPi:** The global `IMAGE_INSTALL:append = " kernel-image kernel-modules"` (from Task A3, line 24) installs the kernel image. On RPi, `KERNEL_IMAGETYPE` defaults to `Image` (not `bzImage`). The `kernel-image` package installs `Image` + unversioned `Image` symlink into `/boot`. Verify the symlink is `Image` not `Image-<ver>` only.

---

## Summary

All four Phase B tasks implemented and committed. No local build available — all verification is by static grep. Build-time gates documented above must be confirmed on first CI build of the RPi target.

| Task | Commit | Status |
|------|--------|--------|
| B1: u-boot ext4 fragment | 8d6c075 | DONE (CI gate: recipe PN + CONFIG_FS_EXT4 verification) |
| B2: boot.cmd ext4load | 973fc46 | DONE (CI gate: CONFIG_CMD_PART, dtb path, addr vars) |
| B3: wks drop boot_a/b | 8213bfd | DONE (clean static check) |
| B4: image kernel-devicetree | 2f32143 | DONE (CI gate: dtb install path) |
