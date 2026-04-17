SUMMARY = "OE5XRX A/B boot state (grubenv) for GRUB-EFI"
DESCRIPTION = "Deploys a seed grubenv with A/B boot defaults to DEPLOY_DIR_IMAGE \
so wic's bootimg-efi plugin picks it up via IMAGE_EFI_BOOT_FILES."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

S = "${WORKDIR}"

inherit allarch deploy

RDEPENDS:${PN} = "grub-editenv"

do_compile() {
    # Create grubenv with A/B defaults (1024-byte grub env block format).
    {
        printf '# GRUB Environment Block\n'
        printf 'boot_part=a\n'
        printf 'bootcount=0\n'
        printf 'upgrade_available=0\n'
        printf 'bootlimit=3\n'
    } > ${WORKDIR}/grubenv.tmp

    python3 -c "
data = open('${WORKDIR}/grubenv.tmp', 'rb').read()
pad = b'#' * (1024 - len(data))
with open('${WORKDIR}/grubenv', 'wb') as f:
    f.write(data + pad)
"
    rm -f ${WORKDIR}/grubenv.tmp
}

do_install() {
    # Install to rootfs for runtime access by grub-editenv.
    install -d ${D}/boot/EFI/BOOT
    install -m 0644 ${WORKDIR}/grubenv ${D}/boot/EFI/BOOT/grubenv
}

do_deploy() {
    # Deploy to DEPLOY_DIR_IMAGE so IMAGE_EFI_BOOT_FILES can pick it up.
    install -m 0644 ${WORKDIR}/grubenv ${DEPLOYDIR}/grubenv
}
addtask deploy after do_compile before do_build

FILES:${PN} = "/boot/EFI/BOOT/grubenv"
