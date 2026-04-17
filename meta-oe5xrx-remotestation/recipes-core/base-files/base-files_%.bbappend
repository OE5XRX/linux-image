# Rewrite meta-raspberrypi's /boot/firmware fstab line from /dev/mmcblk0p1
# to PARTLABEL=firmware. Works across eMMC (real CM4) and SD (QEMU raspi4b).
#
# Layer priority must be higher than meta-raspberrypi (9) so our append
# runs AFTER theirs — see meta-oe5xrx-remotestation/conf/layer.conf.

do_install:append() {
    if [ -f "${D}${sysconfdir}/fstab" ]; then
        sed -i 's|^/dev/mmcblk0p1\([[:space:]]\+/boot/firmware\)|PARTLABEL=firmware\1|' \
            ${D}${sysconfdir}/fstab
    fi
}
