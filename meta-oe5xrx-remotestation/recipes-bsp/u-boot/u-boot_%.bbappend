FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# One :append so all fragments are always applied: ext4 (boot.cmd ext4load's
# the kernel from the rootfs), watchdog (u-boot arms the SoC wdt), env
# (redundant U-Boot environment in the raw uboot_env/uboot_envr partitions,
# matching fw_env.config so fw_setenv commits reach the same env U-Boot reads),
# and fdt-overlay (boot stage 2 `fdt apply`s the slot's DT overlays).
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg file://oe5xrx-wdt.cfg file://oe5xrx-env.cfg file://oe5xrx-fdt-overlay.cfg"

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
    # Assert the EXACT offsets, not just presence: a wrong value would still be
    # "set" but ship a broken env location (fw_setenv/U-Boot would address the
    # wrong sectors and could clobber a neighbouring partition). These must
    # match the uboot_env/uboot_envr partition starts in the wks.
    if ! grep -q '^CONFIG_ENV_OFFSET=0x4005000$' "${B}/.config"; then
        bbfatal "CONFIG_ENV_OFFSET != 0x4005000 in built .config — must match the uboot_env partition start (see the .wks)."
    fi
    if ! grep -q '^CONFIG_ENV_OFFSET_REDUND=0x4105000$' "${B}/.config"; then
        bbfatal "CONFIG_ENV_OFFSET_REDUND != 0x4105000 in built .config — must match the uboot_envr partition start (see the .wks)."
    fi
    # Boot stage 2 needs `fdt apply` for the slot's DT overlays. Without it
    # every boot would fall back to "no overlays" (oe5xrx.overlays=failed) and
    # the station-agent would roll back every OTA trial — fail the build instead.
    if ! grep -q '^CONFIG_OF_LIBFDT_OVERLAY=y' "${B}/.config"; then
        bbfatal "CONFIG_OF_LIBFDT_OVERLAY not enabled in built .config — fdt-overlay fragment did not land (see oe5xrx-fdt-overlay.cfg)."
    fi
    if ! grep -q '^CONFIG_CMD_FDT=y' "${B}/.config"; then
        bbfatal "CONFIG_CMD_FDT not enabled in built .config — fdt-overlay fragment did not land (see oe5xrx-fdt-overlay.cfg)."
    fi
}
