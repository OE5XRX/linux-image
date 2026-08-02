# `just local <recipe>` — build/boot/flash on THIS machine.
set dotenv-load := true

# Mount the shared Storage Box mirror at /mnt/yocto-shared (idempotent)
mount:
    scripts/ydev/local-mount.sh

# Unmount the shared mirror
umount:
    scripts/ydev/local-umount.sh
