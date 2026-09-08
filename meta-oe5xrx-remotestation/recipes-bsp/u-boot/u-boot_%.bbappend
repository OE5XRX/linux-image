FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# One :append so all fragments are always applied: ext4 (boot.cmd ext4load's
# the kernel from the rootfs), watchdog (u-boot arms the SoC wdt), and env
# (redundant U-Boot environment in the raw uboot_env/uboot_envr partitions,
# matching fw_env.config so fw_setenv commits reach the same env U-Boot reads).
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg file://oe5xrx-wdt.cfg file://oe5xrx-env.cfg"

# Guard: the redundant U-Boot environment MUST be compiled in. A Kconfig
# fragment can be silently dropped by merge_config when a dependency/choice
# is unmet — that regression previously made every CM4 OTA fail at fw_setenv
# trial-boot arming (single-format env vs. redundant fw_env.config). Fail the
# build here instead of shipping a station that can't arm/commit an OTA.
# See docs/superpowers/specs/2026-09-08-robust-ab-env-larger-slots-design.md.
do_configure:append:raspberrypi4-64() {
    # NB: u-boot 2026.01 spells it CONFIG_ENV_REDUNDANT (old name was
    # SYS_REDUNDAND_ENVIRONMENT). Check the name valid for the pinned u-boot.
    if ! grep -q '^CONFIG_ENV_REDUNDANT=y' "${B}/.config"; then
        bbfatal "CONFIG_ENV_REDUNDANT not enabled in built .config — redundant env fragment did not land (see oe5xrx-env.cfg)."
    fi
    if ! grep -q '^CONFIG_ENV_OFFSET_REDUND=' "${B}/.config"; then
        bbfatal "CONFIG_ENV_OFFSET_REDUND missing in built .config — redundant env offset not set."
    fi
}
