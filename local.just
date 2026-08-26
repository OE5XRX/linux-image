# `just local <recipe>` — build/boot/flash on THIS machine.
set dotenv-load := true

# Build an image locally (reads sstate from the public R2 mirror via oe5xrx.yml)
build machine="qemux86-64":
    scripts/ydev/local-build.sh {{machine}}

# Boot the built qemux86-64 image locally in QEMU (serial in this terminal)
qemu:
    scripts/run-qemu.sh

# Write the raspberrypi4-64 .wic to an SD/device (guarded). No device -> lists candidates.
flash device="":
    scripts/ydev/local-flash.sh {{device}}
