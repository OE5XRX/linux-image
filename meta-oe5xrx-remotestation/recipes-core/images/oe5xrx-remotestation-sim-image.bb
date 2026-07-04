# Dev-only sim image: dev image + co-located module simulation stack.
# native_sim lives ONLY in this variant, never in prod or the plain dev image.
require oe5xrx-remotestation-dev-image.bb

SUMMARY = "OE5XRX RemoteStation dev image with co-located module simulation (native_sim FM)"

IMAGE_INSTALL:append = " packagegroup-oe5xrx-sim"
