SUMMARY = "OE5XRX Remote Station Development Image"
DESCRIPTION = "Development image with debug tools and root access"
LICENSE = "MIT"

inherit core-image
require oe5xrx-remotestation-image.bb
# This is the development variant — overrides the prod default so the baked
# VARIANT_ID marker is unfalsifiable at build time.
OE5XRX_IMAGE_VARIANT = "dev"

IMAGE_FEATURES += " \
    ssh-server-openssh \
    allow-empty-password \
    allow-root-login \
    empty-root-password \
    tools-debug \
"

IMAGE_INSTALL += " \
    vim \
    curl \
    sshfs-fuse \
    fuse3 \
    oe5xrx-dev-agent-mount \
"
