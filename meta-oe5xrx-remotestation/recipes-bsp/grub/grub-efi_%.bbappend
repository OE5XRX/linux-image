# Fix the embedded config that gets compiled into bootx64.efi.
#
# Yocto's default cfg does: configfile ${cmdpath}/EFI/BOOT/grub.cfg
# But $cmdpath is already (hd0,gpt1)/EFI/BOOT, so it doubles to
# ((hd0,gpt1)/EFI/BOOT)/EFI/BOOT/grub.cfg → "no such device".
#
# Our cfg does: configfile ${cmdpath}/grub.cfg
# → (hd0,gpt1)/EFI/BOOT/grub.cfg → correct path on the ESP.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Add 'echo' to the modules compiled into bootx64.efi so our grub.cfg
# can print A/B boot status messages.
GRUB_BUILDIN:append = " echo"
