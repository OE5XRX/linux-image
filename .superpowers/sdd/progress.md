# Progress: kernel-in-rootfs A/B + boot robustness
Branch: feat/kernel-in-rootfs-ab
Base (before impl): fe2c5fe924236fb5dc320b3d4893f2ef61bdcde1
Local build: UNAVAILABLE (no kas/bitbake) — build+boot tasks A4/C5 are CI-gated.

## Tasks
- [x] Phase A (A1 grub modules, A2 grub.cfg rootfs-load, A3 kernel-in-rootfs, A4 build/boot CI-pending)
- [x] Phase B (B1 uboot ext4, B2 boot.cmd ext4load, B3 wks drop boot_a/b, B4 rpi dtb)
- [ ] Phase C (C1 hung_task sysctl, C2 systemd wdt, C3 wdt drivers+uboot arm, C4 pin+qemu wdt, C5 verify CI-pending)

Task Phase A: complete (commits e0876ed..c8b58e5, review PASS/APPROVED).
  Open findings for final review:
  - F1 (Important, BUILD GATE): confirm /boot/bzImage unversioned symlink in rootfs on first CI build; else add ROOTFS_POSTPROCESS symlink.
  - F2/F3 fixed in follow-up commit.

Task Phase B: complete (commits 8d6c075..2f32143).
  CI gates to confirm on first RPi build:
  - B1: verify u-boot PN is u-boot_* (not u-boot-raspberrypi); verify CONFIG_FS_EXT4 picked up.
  - B2: verify CONFIG_CMD_PART available; verify /boot/bcm2711-rpi-cm4.dtb path exact.
  - B4: verify kernel-devicetree installs dtb directly to /boot/ (not /boot/broadcom/).
  See full gate list: .superpowers/sdd/phaseB-report.md
