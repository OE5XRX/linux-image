# `just remote <recipe>` — build on an on-demand Hetzner box (auto-teardown).
set dotenv-load := true

# Provision an on-demand build box and write R2 credentials (idempotent)
up:
    scripts/ydev/remote-up.sh
# Show the current session box (uptime ≈ cost)
status:
    scripts/ydev/remote-status.sh
# Delete the current session box now
down:
    scripts/ydev/remote-down.sh
# Delete ALL orphaned ydev boxes (label-scoped; never touches CI)
clean:
    scripts/ydev/remote-clean.sh
# Build on the session box (R2 sstate mirror; publishes; fails if no box). Args any order: [machine] [--dev].
# e.g. `just remote build --dev` (qemux86-64 dev-image, cheap sstate delta).
build *args:
    scripts/ydev/remote-build.sh {{args}}
# Download the built images from the box to dist/<machine>/. Args: [machine] [--dev].
download *args:
    scripts/ydev/remote-download.sh {{args}}
# Boot the box's built qemux86-64 image, serial over SSH
qemu:
    scripts/ydev/remote-qemu.sh
# Interactive shell on the session box
shell:
    scripts/ydev/remote-shell.sh
