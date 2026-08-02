# `just remote <recipe>` — build on an on-demand Hetzner box (auto-teardown).
set dotenv-load := true

# Show the current session box (uptime ≈ cost, mount state)
status:
    scripts/ydev/remote-status.sh
# Delete the current session box now
down:
    scripts/ydev/remote-down.sh
# Delete ALL orphaned ydev boxes (label-scoped; never touches CI)
clean:
    scripts/ydev/remote-clean.sh
