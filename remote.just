# `just remote <recipe>` — build on an on-demand Hetzner box (auto-teardown).
set dotenv-load := true

# Provision an on-demand build box + mount the shared mirror (idempotent)
up:
    scripts/ydev/remote-up.sh
# Show the current session box (uptime ≈ cost, mount state)
status:
    scripts/ydev/remote-status.sh
# Delete the current session box now
down:
    scripts/ydev/remote-down.sh
# Delete ALL orphaned ydev boxes (label-scoped; never touches CI)
clean:
    scripts/ydev/remote-clean.sh
# Build on the session box against the mirror (fails if no box)
build machine="qemux86-64":
    scripts/ydev/remote-build.sh {{machine}}
# Download the built images from the box to dist/<machine>/
download machine="qemux86-64":
    scripts/ydev/remote-download.sh {{machine}}
