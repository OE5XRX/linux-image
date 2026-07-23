FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# One :append so all fragments are always applied: ext4 (boot.cmd ext4load's
# the kernel from the rootfs), watchdog (u-boot arms the SoC wdt), and env
# (redundant U-Boot environment in the raw uboot_env/uboot_envr partitions,
# matching fw_env.config so fw_setenv commits reach the same env U-Boot reads).
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg file://oe5xrx-wdt.cfg file://oe5xrx-env.cfg"
