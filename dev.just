# `just dev <recipe>` — Fast-Dev-Loop: run the station_agent live from a host
# mount instead of the ~30-min image-build cycle (dev-image only).
set dotenv-load := true

cm4_host := env_var_or_default("CM4_HOST", "cm4-dev.local")
host_addr := env_var_or_default("HOST_ADDR", "192.168.1.10")
sm_repo := env_var_or_default("SM_REPO", justfile_directory() + "/../station-manager")

# Boot the dev-image in QEMU (mount the agent afterwards with the sshfs helper)
qemu:
    scripts/run-qemu.sh --dev-agent

# CM4 live loop: ensure the host sshfs mount → restart the agent → follow its logs
cm4 host=cm4_host:
    scripts/dev-mount.sh {{host}} {{host_addr}} {{sm_repo}}
    ssh root@{{host}} 'systemctl restart station-agent && journalctl -u station-agent -f'
