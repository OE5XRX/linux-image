# Persistent SSH host keys.
#
# The rootfs is read-only, so openssh's readonly config keeps the host keys in
# /var/run/ssh (tmpfs) and they are regenerated on every boot — clients see a
# changed host key after each reboot/OTA. /var is the persistent data partition
# (shared by both A/B slots), so keep the keys in /var/lib/ssh instead:
# generated once by sshdgenkeys.service (sshd_check_keys skips existing keys),
# then stable across reboot + OTA.
#
# The upstream recipe derives the HostKey lines of sshd_config_readonly from
# OPENSSH_HOST_KEY_DIR_READONLY_CONFIG, and sshd_check_keys generates whatever
# sshd_config_readonly lists, so no further patching is needed.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

OPENSSH_HOST_KEY_DIR_READONLY_CONFIG = "${localstatedir}/lib/ssh"

# ecdsa is the upstream default; add ed25519 as well.
PACKAGECONFIG:append = " hostkey-ed25519"

SRC_URI += "file://sshdgenkeys-hostkey-dir.conf"

do_install:append() {
    # Key dir must be root-only; sshd_check_keys would create it as 0755.
    install -d ${D}${systemd_system_unitdir}/sshdgenkeys.service.d
    install -m 0644 ${UNPACKDIR}/sshdgenkeys-hostkey-dir.conf \
        ${D}${systemd_system_unitdir}/sshdgenkeys.service.d/10-oe5xrx-hostkey-dir.conf
}

FILES:${PN}-sshd += "${systemd_system_unitdir}/sshdgenkeys.service.d"

# The drop-in's ExecStartPre uses /usr/bin/install (coreutils; busybox here has no install).
RDEPENDS:${PN}-sshd += "coreutils"
