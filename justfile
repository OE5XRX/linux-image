# justfile — linux-image. `just --list` zeigt alle Recipes.
set dotenv-load := true

cm4_host := env_var_or_default("CM4_HOST", "cm4-dev.local")
host_addr := env_var_or_default("HOST_ADDR", "192.168.1.10")
sm_repo := env_var_or_default("SM_REPO", justfile_directory() + "/../station-manager")

# QEMU mit Dev-Image booten (Live-Mount danach separat)
dev-qemu:
    scripts/run-qemu.sh --dev-agent

# CM4-Loop: Mount sicherstellen → Agent neu starten → Logs folgen
dev-cm4 host=cm4_host:
    scripts/dev-mount.sh {{host}} {{host_addr}} {{sm_repo}}
    ssh root@{{host}} 'systemctl restart station-agent && journalctl -u station-agent -f'

# Image bauen
build machine="qemux86-64":
    kas build {{machine}}.yml

# Prod-Safety-Lint (Task 4)
lint-dev-isolation:
    scripts/l0-dev-packages-lint.sh
