# Exactly ONE system-wide PipeWire daemon: ours (oe5xrx-pipewire.service, from
# oe5xrx-audio-system). Upstream's "systemd-system-service" installs and enables
# pipewire.service + pipewire.socket + pipewire-manager.socket, which listen on
# the SAME /run/pipewire/pipewire-0 socket and run as the same 'pipewire' user.
# Both daemons started at boot and raced for /run/pipewire/pipewire-0.lock:
# the loser exited 245 ("maybe another daemon is running"), WirePlumber lost its
# connection, and which daemon served the socket was left to chance.
#
# Not building the units (instead of masking them in the image) means there is
# nothing for systemd presets or socket activation to bring back. The per-user
# units go too: the station is headless with no user sessions, and a root SSH
# login would otherwise socket-activate a second, per-user PipeWire that grabs
# the module ALSA cards away from the system daemon.
# Guarded by scripts/l5-pipewire-single-daemon-lint.sh.
PACKAGECONFIG:remove = "systemd-system-service systemd-user-service"
