# `just local <recipe>` — build/boot/flash on THIS machine.
set dotenv-load := true

# Mount the shared Storage Box mirror at /mnt/yocto-shared (idempotent)
mount:
    scripts/ydev/local-mount.sh

# Unmount the shared mirror
umount:
    scripts/ydev/local-umount.sh

# Build an image locally against the warm mirror (fails if not mounted)
build machine="qemux86-64":
    scripts/ydev/local-build.sh {{machine}}

# Boot the built qemux86-64 image locally in QEMU (serial in this terminal)
qemu:
    scripts/run-qemu.sh
