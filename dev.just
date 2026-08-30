# `just dev <recipe>` — Fast-Dev-Loop: run the station_agent live from a host
# mount instead of the ~30-min image-build cycle (dev-image only).
#
# Boot a dev-image target FIRST, then attach the live loop:
#   local QEMU:  `just local qemu dev`   (blocks with the serial console)
#   real CM4:    it is already running
# then, in another terminal, `just dev qemu` / `just dev cm4` / `just dev attach ...`.
set dotenv-load := true

cm4_host := env_var_or_default("CM4_HOST", "cm4-dev.local")
cm4_host_addr := env_var_or_default("HOST_ADDR", "192.168.1.10")
qemu_ssh_port := env_var_or_default("SSH_PORT", "2222")
sm_repo := env_var_or_default("SM_REPO", justfile_directory() + "/../station-manager")

# Attach the loop to any running dev-image target: mount + restart + follow logs. target=ssh dest (CM4 IP / localhost:2222); host-addr=how the target reaches this host (CM4 laptop LAN IP / QEMU 10.0.2.2)
attach target host_addr repo=sm_repo:
    scripts/dev-attach.sh {{target}} {{host_addr}} {{repo}}

# Attach to a locally-booted QEMU dev-image (boot it first: `just local qemu dev`).
qemu:
    scripts/dev-attach.sh localhost:{{qemu_ssh_port}} 10.0.2.2 {{sm_repo}}

# Attach to a real CM4 that is already running the dev-image.
cm4 host=cm4_host:
    scripts/dev-attach.sh {{host}} {{cm4_host_addr}} {{sm_repo}}
