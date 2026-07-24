# OE5XRX A/B boot script (compiled to boot.scr by mkimage).
#
# State variables in the U-Boot environment:
#   boot_part          — "a" or "b", the slot we want to boot from
#   bootcount          — number of boot attempts on this slot since last commit
#   upgrade_available  — 1 after an OTA (we're in trial), 0 after commit
#
# Control flow:
#   1. Increment bootcount. Save env. If the kernel comes up and userspace is
#      healthy, the station-agent calls `fw_setenv bootcount 0 upgrade_available 0`
#      to commit (so we stop counting).
#   2. If upgrade_available=1 AND bootcount > bootlimit, userspace never got
#      healthy — swap boot_part and retry the old slot.
#   3. Otherwise, just boot from boot_part.

# Defaults — first boot or after env wipe.
if test -z "${boot_part}"; then setenv boot_part a; fi
if test -z "${bootcount}"; then setenv bootcount 0; fi
if test -z "${upgrade_available}"; then setenv upgrade_available 0; fi
if test -z "${bootlimit}"; then setenv bootlimit 3; fi

# Increment and persist BEFORE trying to boot.
setexpr bootcount ${bootcount} + 1
saveenv

# Arm the SoC watchdog as early as possible so even a pre-systemd hang forces
# a reset. systemd (RuntimeWatchdogSec) takes over petting once userspace is up.
# The `|| echo` fallthroughs mean a wrong device name or a failed start can
# never brick boot (we just continue unprotected).
#
# HIL GATE (validate on real CM4): the BCM2835/2711 hardware watchdog maxes out
# at ~15 s, so 15000 ms is the practical ceiling. The kernel bcm2835_wdt driver
# (built-in) + systemd must begin petting within that window after handover, or
# a slow boot could reset-loop. If HIL shows false resets, either confirm the
# u-boot->kernel watchdog handover keeps it fed, or drop this pre-arm and rely
# on the kernel+systemd watchdog (which still covers kernel-up and userspace hangs).
wdt dev watchdog@7e100000 || echo "  (no wdt device — continuing)"
wdt start 15000 || echo "  (wdt start failed — continuing)"

echo "=== OE5XRX A/B boot ==="
echo "  boot_part=${boot_part}  bootcount=${bootcount}/${bootlimit}  upgrade_available=${upgrade_available}"

# Rollback if in trial and limit exceeded.
if test ${upgrade_available} -gt 0 && test ${bootcount} -gt ${bootlimit}; then
    echo "  Trial boot failed ${bootlimit} times — rolling back."
    if test "${boot_part}" = "a"; then
        setenv boot_part b
    else
        setenv boot_part a
    fi
    setenv bootcount 1
    setenv upgrade_available 0
    saveenv
    echo "  Retrying from slot ${boot_part}"
fi

# The KERNEL still lives INSIDE the slot's rootfs (ext4) so it travels with the
# rootfs through OTA and matches /lib/modules. The DEVICETREE, however, is taken
# from the FIRMWARE: the RPi GPU firmware applies config.txt (incl. otg_mode=1 ->
# XHCI USB host — required for the full-speed FM module behind the FE1.1s hub) to
# the DTB it loads, and passes its address to u-boot in ${fdt_addr}. u-boot
# booting its own rootfs DTB would discard those config.txt patches (the standard
# RPi+u-boot pitfall), so we boot the firmware DTB instead.
# Trade-off: OTA updates the rootfs (kernel) but NOT the FAT firmware DTB, so a
# kernel bump that needs a new DTB requires a reflash. A userspace hardware-health
# gate guards regressions (station-manager #106). See
# docs/superpowers/specs/2026-07-24-cm4-usb-firmware-dtb.md and linux-image #46.
part number mmc 0 root_${boot_part} root_partnum
if test -z "${root_partnum}"; then
    echo "  ERROR: root_${boot_part} partition not found — resetting"
    reset
fi

echo "  Loading kernel from rootfs mmc 0:${root_partnum} (/boot/Image)"
if ext4load mmc 0:${root_partnum} ${kernel_addr_r} /boot/Image; then
    setenv bootargs "root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 console=tty1 console=serial0,115200"

    # Prefer the firmware-provided DTB (config.txt/otg_mode applied). booti only
    # returns if the DTB is rejected — then we fall through to the fallback.
    if test -n "${fdt_addr}"; then
        echo "  Booting with firmware DTB at ${fdt_addr}"
        booti ${kernel_addr_r} - ${fdt_addr}
    fi

    # Fallback — reached only if ${fdt_addr} is unset or the firmware-DTB boot
    # returned. Boots the rootfs DTB so we never brick; note that config.txt
    # effects (USB host!) are ABSENT on this degraded path.
    echo "  fdt_addr unusable — falling back to rootfs DTB (no config.txt effects)"
    setenv fdt_ok 0
    if ext4load mmc 0:${root_partnum} ${fdt_addr_r} /boot/broadcom/bcm2711-rpi-cm4.dtb; then setenv fdt_ok 1; fi
    if test "${fdt_ok}" = 0; then
        if ext4load mmc 0:${root_partnum} ${fdt_addr_r} /boot/bcm2711-rpi-cm4.dtb; then setenv fdt_ok 1; fi
    fi
    if test "${fdt_ok}" = 1; then
        booti ${kernel_addr_r} - ${fdt_addr_r}
    fi
fi

# Fail-fast: any load failure or a returned booti falls through to reset.
# bootcount was already incremented+saved, so this progresses to rollback.
echo "  Kernel/dtb load failed — resetting"
reset
