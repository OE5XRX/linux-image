# Same reason as pipewire_%.bbappend: oe5xrx-wireplumber.service (from
# oe5xrx-audio-system) is the only session manager. Drop upstream's system and
# per-user wireplumber units so a second WirePlumber (and with it a second ALSA
# monitor) can never attach to the graph.
# Guarded by scripts/l5-pipewire-single-daemon-lint.sh.
PACKAGECONFIG:remove = "systemd-system-service systemd-user-service"
