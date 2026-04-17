SUMMARY = "OE5XRX Remote Station Development Image"
DESCRIPTION = "Development image with debug tools and root access"
LICENSE = "MIT"

inherit core-image
require oe5xrx-remotestation-image.bb

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
"
