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

# Resolve active slot → partition numbers (matches wks layout).
# Partition layout (mmc 0):
#   1 firmware   4 boot_a   5 boot_b   6 root_a   7 root_b   8 data
part number mmc 0 boot_${boot_part} active_boot_part
if test -z "${active_boot_part}"; then
    echo "  ERROR: could not find boot_${boot_part} partition"
    reset
fi

echo "  Loading kernel + dtb from mmc 0:${active_boot_part}"
load mmc 0:${active_boot_part} ${kernel_addr_r} Image
load mmc 0:${active_boot_part} ${fdt_addr_r} bcm2711-rpi-cm4.dtb

# Kernel cmdline: root from label so it follows A/B without more bookkeeping.
setenv bootargs "root=PARTLABEL=root_${boot_part} ro rootwait console=serial0,115200 console=tty1 fsck.repair=yes net.ifnames=0"

booti ${kernel_addr_r} - ${fdt_addr_r}
