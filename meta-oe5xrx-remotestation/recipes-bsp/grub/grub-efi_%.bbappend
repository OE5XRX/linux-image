# Fix the embedded config that gets compiled into bootx64.efi.
#
# Yocto's default cfg does: configfile ${cmdpath}/EFI/BOOT/grub.cfg
# But $cmdpath is already (hd0,gpt1)/EFI/BOOT, so it doubles to
# ((hd0,gpt1)/EFI/BOOT)/EFI/BOOT/grub.cfg → "no such device".
#
# Our cfg does: configfile ${cmdpath}/grub.cfg
# → (hd0,gpt1)/EFI/BOOT/grub.cfg → correct path on the ESP.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Modules compiled into bootx64.efi (one :append so all are guaranteed present):
#  - echo: print A/B boot status from our grub.cfg
#  - ext2 (reads ext4) + part_gpt + search/search_label: locate the active
#    root_${boot_part} partition and load /boot/bzImage from inside it.
#  - reboot: the grub.cfg fail-fast path calls `reboot` when the kernel/FS
#    can't be loaded (without this module grub errors "can't find command reboot").
GRUB_BUILDIN:append = " echo ext2 part_gpt search search_label search_fs_uuid reboot"
