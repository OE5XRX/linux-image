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
# Build on the session box (reads from public R2 sstate mirror, publishes new entries; fails if no box).
# `just remote build qemux86-64 dev` builds the dev-image (cheap sstate delta).
build machine="qemux86-64" variant="":
    scripts/ydev/remote-build.sh {{machine}} {{variant}}
# Download the built images from the box to dist/<machine>/
download machine="qemux86-64":
    scripts/ydev/remote-download.sh {{machine}}
# Boot the box's built qemux86-64 image, serial over SSH
qemu:
    scripts/ydev/remote-qemu.sh
# Interactive shell on the session box
shell:
    scripts/ydev/remote-shell.sh
