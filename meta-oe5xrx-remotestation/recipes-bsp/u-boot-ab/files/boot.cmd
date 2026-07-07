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

# Kernel + dtb now live INSIDE the slot's rootfs (ext4), so they always match
# /lib/modules and travel with the rootfs through OTA.
part number mmc 0 root_${boot_part} root_partnum
if test -z "${root_partnum}"; then
    echo "  ERROR: root_${boot_part} partition not found — resetting"
    reset
fi

echo "  Loading kernel + dtb from rootfs mmc 0:${root_partnum} (/boot)"
if ext4load mmc 0:${root_partnum} ${kernel_addr_r} /boot/Image; then
    # KERNEL_DEVICETREE = "broadcom/bcm2711-rpi-cm4.dtb" installs the dtb under
    # /boot/broadcom/ in the rootfs; try that first, then fall back to a flat
    # /boot/ path so we boot regardless of how the build lays the dtb out.
    setenv fdt_ok 0
    if ext4load mmc 0:${root_partnum} ${fdt_addr_r} /boot/broadcom/bcm2711-rpi-cm4.dtb; then setenv fdt_ok 1; fi
    if test "${fdt_ok}" = 0; then
        if ext4load mmc 0:${root_partnum} ${fdt_addr_r} /boot/bcm2711-rpi-cm4.dtb; then setenv fdt_ok 1; fi
    fi
    if test "${fdt_ok}" = 1; then
        setenv bootargs "root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 console=tty1 console=serial0,115200"
        booti ${kernel_addr_r} - ${fdt_addr_r}
    fi
fi

# Fail-fast: any load failure or a returned booti falls through to reset.
# bootcount was already incremented+saved, so this progresses to rollback.
echo "  Kernel/dtb load failed — resetting"
reset
