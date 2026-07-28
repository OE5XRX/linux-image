# Fast-Dev-Loop (linux-image) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Den `station-agent` im **Dev-Image** aus einem Live-Mount vom Host laufen lassen (sshfs), mit garantiertem Fallback auf den gebackenen Agent, plus QEMU-Integration, host-seitige Mount/Loop-Scripts (just) und einen Prod-Safety-Guard.

**Architecture:** Ein neues **dev-only** Recipe `oe5xrx-dev-agent-mount` liefert (a) einen systemd-Drop-in, der `station-agent.service` auf einen Wrapper umbiegt, und (b) den Wrapper `station-agent-dev-launch`, der zur Startzeit die Quelle wählt: `/mnt/dev/station_agent` wenn gemountet, sonst der gebackene Agent (nie gebrickt). sshfs/fuse und dieses Recipe landen **ausschließlich** im `-dev-image` (das `require`t das Prod-Image, Einbahn — kann nie in Prod leaken). Ein statischer CI-Lint erzwingt die Trennung. Host-seitig mountet `dev-mount.sh` das Repo per sshfs aufs Gerät; `run-qemu.sh --dev-agent` und ein justfile bündeln den Loop.

**Tech Stack:** Yocto/BitBake (poky), systemd Drop-ins, sshfs-fuse/fuse (meta-openembedded/meta-filesystems), QEMU user-net, bash, just.

## Global Constraints

- Dev-only Artefakte (sshfs-fuse, fuse, `oe5xrx-dev-agent-mount`, `dev-override.conf`) dürfen **niemals** ins Prod-Image. Das Dev-Image `require`t das Prod-Image (Einbahn) — dev-Zusätze via `IMAGE_INSTALL +=` im Dev-Recipe.
- **Active-Slot/Prod-Pfad unangetastet:** SRCREV-Pin der `station-agent`-Recipe bleibt; das Prod-Image `oe5xrx-remotestation-image.bb` wird **nicht** modifiziert.
- `qemux86-64` ist auch ein Prod-Target (Proxmox-Sim-Station) — der Dev-Loop hängt nur am `-dev-image`, `run-qemu.sh --dev-agent` bootet explizit das Dev-Image.
- sshfs/fuse existieren im Tree: `meta-openembedded/meta-filesystems/recipes-filesystems/sshfs-fuse/` und `.../recipes-support/fuse/fuse_2.9.9.bb`.
- Commit-Messages enden mit `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Branch: `feat/fast-dev-loop` (existiert, Spec committed).

---

### Task 1: Dev-only Recipe `oe5xrx-dev-agent-mount` (Wrapper + Drop-in) + ins Dev-Image

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/dev-agent-mount/oe5xrx-dev-agent-mount_1.0.bb`
- Create: `meta-oe5xrx-remotestation/recipes-core/dev-agent-mount/files/station-agent-dev-launch`
- Create: `meta-oe5xrx-remotestation/recipes-core/dev-agent-mount/files/dev-override.conf`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb:15-19`

**Interfaces:**
- Produces: Paket `oe5xrx-dev-agent-mount` installiert `/usr/bin/station-agent-dev-launch` (0755), `/etc/systemd/system/station-agent.service.d/dev-override.conf`, und legt `/mnt/dev` an.
- Consumes: bestehende `station-agent.service` (aus der `station-agent`-Recipe).

- [ ] **Step 1: Create the launch wrapper (with a dry-run hook for testing)**

```sh
# .../dev-agent-mount/files/station-agent-dev-launch
#!/bin/sh
# Fast-Dev-Loop launcher: läuft der Agent aus dem Host-Live-Mount, wenn vorhanden;
# sonst Fallback auf den gebackenen Agent. Garantiert bootfähig ohne Mount/Netz.
# Testbar: STATION_AGENT_DEV_BASE überschreibt /mnt/dev, STATION_AGENT_DEV_DRYRUN=1
# druckt die gewählte Quelle statt zu exec'en.
set -eu

DEV_BASE="${STATION_AGENT_DEV_BASE:-/mnt/dev}"
DEV_SRC="${DEV_BASE}/station_agent"

if [ -d "${DEV_SRC}" ] && [ -f "${DEV_SRC}/__main__.py" ]; then
    if [ "${STATION_AGENT_DEV_DRYRUN:-0}" = "1" ]; then echo "mount:${DEV_SRC}"; exit 0; fi
    exec env PYTHONPATH="${DEV_BASE}" /usr/bin/python3 -m station_agent
fi

if [ "${STATION_AGENT_DEV_DRYRUN:-0}" = "1" ]; then echo "baked"; exit 0; fi
exec /usr/bin/python3 -m station_agent
```

- [ ] **Step 2: Create the systemd drop-in**

```ini
# .../dev-agent-mount/files/dev-override.conf
# Dev-Image only: biegt den Agent auf den Live-Mount-Wrapper um.
# Leeres ExecStart= löscht die gebackene Zeile, bevor die neue gesetzt wird.
[Service]
ExecStart=
ExecStart=/usr/bin/station-agent-dev-launch
```

- [ ] **Step 3: Create the recipe**

```bitbake
# .../dev-agent-mount/oe5xrx-dev-agent-mount_1.0.bb
SUMMARY = "OE5XRX Fast-Dev-Loop: live-mount launcher + station-agent drop-in (DEV ONLY)"
DESCRIPTION = "Ships a launcher that runs the station-agent from a host sshfs \
mount when present, else the baked agent. Installed only into the dev image."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://station-agent-dev-launch \
    file://dev-override.conf \
"

S = "${UNPACKDIR}"

inherit allarch

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/station-agent-dev-launch ${D}${bindir}/station-agent-dev-launch

    install -d ${D}${sysconfdir}/systemd/system/station-agent.service.d
    install -m 0644 ${UNPACKDIR}/dev-override.conf \
        ${D}${sysconfdir}/systemd/system/station-agent.service.d/dev-override.conf

    install -d ${D}/mnt/dev
}

FILES:${PN} += " \
    ${bindir}/station-agent-dev-launch \
    ${sysconfdir}/systemd/system/station-agent.service.d/dev-override.conf \
    /mnt/dev \
"
```

- [ ] **Step 4: Add sshfs + fuse + the recipe to the DEV image only**

In `oe5xrx-remotestation-dev-image.bb`, den bestehenden `IMAGE_INSTALL += "…"`-Block erweitern:

```bitbake
IMAGE_INSTALL += " \
    vim \
    curl \
    sshfs-fuse \
    fuse \
    oe5xrx-dev-agent-mount \
"
```

- [ ] **Step 5: Verify the recipes parse**

Run: `kas shell qemux86-64.yml -c "bitbake -p"`
Expected: parse ohne Fehler (kein „nothing provides oe5xrx-dev-agent-mount").
(Falls kein Yocto-Env verfügbar: `bitbake-layers show-recipes oe5xrx-dev-agent-mount` in der Build-Umgebung.)

- [ ] **Step 6: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/dev-agent-mount/ meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb
git commit -m "feat(dev-image): live-mount launcher + drop-in + sshfs (dev-image only)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Wrapper-Auswahllogik testen (Fallback-Garantie)

**Files:**
- Create: `tests/dev-loop/test_dev_launch.sh`

**Interfaces:**
- Consumes: `station-agent-dev-launch` mit `STATION_AGENT_DEV_BASE` + `STATION_AGENT_DEV_DRYRUN=1`.
- Produces: Nachweis, dass Mount-vorhanden → `mount:<src>`, Mount-fehlt → `baked`. Das ist die Fallback-Garantie ohne vollen QEMU-Boot.

- [ ] **Step 1: Write the failing test**

```bash
# tests/dev-loop/test_dev_launch.sh
#!/usr/bin/env bash
set -euo pipefail
LAUNCH="meta-oe5xrx-remotestation/recipes-core/dev-agent-mount/files/station-agent-dev-launch"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Case 1: mount present (station_agent/__main__.py exists) → picks mount
mkdir -p "$tmp/station_agent"
touch "$tmp/station_agent/__main__.py"
out=$(STATION_AGENT_DEV_BASE="$tmp" STATION_AGENT_DEV_DRYRUN=1 sh "$LAUNCH")
[ "$out" = "mount:$tmp/station_agent" ] || { echo "FAIL mount-case: got '$out'"; exit 1; }

# Case 2: mount absent → falls back to baked
rm -rf "$tmp/station_agent"
out=$(STATION_AGENT_DEV_BASE="$tmp" STATION_AGENT_DEV_DRYRUN=1 sh "$LAUNCH")
[ "$out" = "baked" ] || { echo "FAIL baked-case: got '$out'"; exit 1; }

echo "PASS: dev-launch selection logic"
```

Dann: `chmod +x tests/dev-loop/test_dev_launch.sh`.

- [ ] **Step 2: Run test — should pass against the wrapper from Task 1**

Run: `bash tests/dev-loop/test_dev_launch.sh`
Expected: `PASS: dev-launch selection logic`. (Falls FAIL: Wrapper aus Task 1 korrigieren, bis grün.)

- [ ] **Step 3: Commit**

```bash
git add tests/dev-loop/test_dev_launch.sh
git commit -m "test(dev-loop): dev-launch fallback selection (mount vs baked)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Host-seitig — `dev-mount.sh`, `run-qemu.sh --dev-agent`, justfile

**Files:**
- Create: `scripts/dev-mount.sh`
- Modify: `scripts/run-qemu.sh:134-158` (arg parsing) + Boot-Ziel
- Create: `justfile`
- Modify: `.gitignore` (`.env`)

**Interfaces:**
- Produces: `scripts/dev-mount.sh <device-host> <host-addr> <repo-path>` mountet `<host-addr>:<repo-path>/station_agent` per sshfs nach `/mnt/dev/station_agent` auf dem Gerät (idempotent). `run-qemu.sh --dev-agent` bootet das Dev-Image. `just dev-qemu`, `just dev-cm4 host=…`.

- [ ] **Step 1: Create the sshfs mount helper**

```bash
# scripts/dev-mount.sh
#!/usr/bin/env bash
# Mountet das Host-Repo per sshfs aufs Gerät (Fast-Dev-Loop, Tier 0).
# Das GERÄT ist sshfs-Client und verbindet zurück zum Host (Host braucht sshd).
#   <device-host>  ssh-Ziel des Geräts (CM4-LAN-IP oder localhost:2222 für QEMU)
#   <host-addr>    Host-Adresse AUS SICHT DES GERÄTS (CM4: LAN-IP des Laptops; QEMU: 10.0.2.2)
#   <repo-path>    absoluter Pfad des station-manager-Repos auf dem Host
#   HOST_USER      env, default = $USER
set -euo pipefail
dev_host="${1:?usage: dev-mount.sh <device-host> <host-addr> <repo-path>}"
host_addr="${2:?missing host-addr}"
repo="${3:?missing repo-path}"
host_user="${HOST_USER:-$USER}"

ssh "root@${dev_host}" "mkdir -p /mnt/dev && \
  if mountpoint -q /mnt/dev/station_agent; then echo 'already mounted'; else \
    sshfs -o reconnect,ServerAliveInterval=15,StrictHostKeyChecking=accept-new \
      ${host_user}@${host_addr}:${repo}/station_agent /mnt/dev/station_agent && \
    echo 'mounted'; fi"
```

Dann: `chmod +x scripts/dev-mount.sh`.

- [ ] **Step 2: Add `--dev-agent` to run-qemu.sh arg parsing**

In `scripts/run-qemu.sh` die `while/case`-Schleife um einen Arm erweitern (vor `-h|--help`):

```bash
        --dev-agent)
            DEV_AGENT=1
            echo "==> Dev-Agent-Modus: bootet das Dev-Image; nach Boot mounten mit:" >&2
            echo "    scripts/dev-mount.sh localhost:${SSH_PORT} 10.0.2.2 \$(cd .. && pwd)/station-manager" >&2
            shift
            ;;
```

Und oben bei den Defaults (`SSH_PORT=…`) ergänzen: `DEV_AGENT="${DEV_AGENT:-0}"`.
(Der Dev-Image-Boot selbst hängt vom Build-Target ab — der Hinweis oben leitet den nächsten Schritt an; die sshfs-Verbindung Gast→Host läuft über `10.0.2.2`, kein zusätzliches `hostfwd` nötig.)

- [ ] **Step 3: Create the justfile**

```make
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
```

- [ ] **Step 4: Update .gitignore**

An `.gitignore` anhängen: `.env`.

- [ ] **Step 5: Verify scripts + justfile**

Run: `bash -n scripts/dev-mount.sh && bash -n scripts/run-qemu.sh && just --list`
Expected: keine Syntaxfehler; `just --list` zeigt `dev-qemu`, `dev-cm4`, `build`, `lint-dev-isolation`.

- [ ] **Step 6: Commit**

```bash
git add scripts/dev-mount.sh scripts/run-qemu.sh justfile .gitignore
git commit -m "feat(dev): sshfs mount helper + run-qemu --dev-agent + justfile

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Prod-Safety-Guard (statischer Lint + CI)

**Files:**
- Create: `scripts/l0-dev-packages-lint.sh`
- Create: `.github/workflows/dev-isolation.yml` (oder Job in bestehender CI)
- Test: der Lint ist selbst-testend (Step 2 führt ihn aus).

**Interfaces:**
- Produces: `scripts/l0-dev-packages-lint.sh` — exit 1 wenn `sshfs-fuse`, `fuse` oder `oe5xrx-dev-agent-mount` im **Prod**-Image-Recipe (oder dessen Includes) auftauchen; exit 0 sonst. Muster: der bestehende `.github/workflows/preflight.yml` AUTOREV-Guard.

- [ ] **Step 1: Write the lint script**

```bash
# scripts/l0-dev-packages-lint.sh
#!/usr/bin/env bash
# Prod-Safety: Dev-only Pakete dürfen NIE im Prod-Image landen. Das Dev-Image
# require't das Prod-Image (Einbahn), also darf das Prod-Recipe die Dev-Pakete
# nicht referenzieren. Schützt CM4 UND die QEMU-Prod-Sim-Station auf Proxmox.
set -euo pipefail

PROD="meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb"
DEV="meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb"
DEV_PKGS="sshfs-fuse fuse oe5xrx-dev-agent-mount"

fail=0
for pkg in ${DEV_PKGS}; do
    if grep -Eq "(^|[[:space:]])${pkg}([[:space:]]|\"|$)" "${PROD}"; then
        echo "::error file=${PROD}::dev-only package '${pkg}' referenced in PROD image"
        fail=1
    fi
done

# Sicherstellen, dass das Dev-Image das Prod-Image require't (Einbahn-Invariante).
if ! grep -Eq '^\s*require\s+oe5xrx-remotestation-image\.bb' "${DEV}"; then
    echo "::error file=${DEV}::dev image must 'require oe5xrx-remotestation-image.bb'"
    fail=1
fi

[ "${fail}" -eq 0 ] && echo "OK — dev packages isolated from prod image"
exit "${fail}"
```

Dann: `chmod +x scripts/l0-dev-packages-lint.sh`.

- [ ] **Step 2: Run the lint — expect PASS on the current tree**

Run: `bash scripts/l0-dev-packages-lint.sh`
Expected: `OK — dev packages isolated from prod image` (exit 0).

- [ ] **Step 3: Prove the lint catches a violation (negative test)**

Temporär `sshfs-fuse` ins Prod-Recipe einfügen, Lint laufen lassen, muss failen, dann rückgängig:

```bash
sed -i 's/    ab-layout \\/    ab-layout \\\n    sshfs-fuse \\/' meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
! bash scripts/l0-dev-packages-lint.sh   # muss exit 1 liefern
git checkout meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
```

Expected: der `!`-Ausdruck ist erfolgreich (Lint hat exit 1 geliefert), danach ist das Prod-Recipe wiederhergestellt.

- [ ] **Step 4: Wire the lint into CI**

```yaml
# .github/workflows/dev-isolation.yml
name: Dev-Isolation
on:
  pull_request: {}
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  dev-isolation:
    name: Dev-only packages stay out of prod image
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Prod-safety lint
        run: bash scripts/l0-dev-packages-lint.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/l0-dev-packages-lint.sh .github/workflows/dev-isolation.yml
git commit -m "ci(dev): static guard that dev-only packages never enter the prod image

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Dev-Image bekommt sshfs+fuse (nur dev) → Task 1 ✓
- Live-Mount `/mnt/dev` via sshfs, ein Protokoll QEMU+CM4 → Task 3 (`dev-mount.sh`) ✓
- systemd-Drop-in mit Fallback-Wrapper (Mount weg → gebackener Agent) → Task 1 + verifiziert Task 2 ✓
- `run-qemu.sh --dev-agent` → Task 3 ✓
- CI-Prod-Safety-Guard → Task 4 ✓
- justfile → Task 3 ✓
- Prod-Image unangetastet, Einbahn-`require` erzwungen → Task 4 Lint ✓
- QEMU-ist-auch-Prod: Dev-Loop nur am Dev-Image, Guard schützt beide Prod-Deployments → Task 1/4 ✓

**Placeholder scan:** keine TBD/TODO; alle Steps enthalten echten Code. Fallback-Verifikation ohne vollen QEMU-Boot bewusst über die Wrapper-Auswahllogik (Task 2) — vollständiger Dev-Image-Boot-Test ist optionaler manueller Schritt (`just dev-qemu`), da die OTA-Integrationstests das Prod-Image bauen.

**Type consistency:** `station-agent-dev-launch` nutzt durchgängig `STATION_AGENT_DEV_BASE`/`STATION_AGENT_DEV_DRYRUN` (Task 1 ↔ Task 2). `dev-mount.sh`-Signatur `<device-host> <host-addr> <repo-path>` konsistent zwischen Task 3 Script und justfile-Aufruf. Dev-Paketliste `sshfs-fuse fuse oe5xrx-dev-agent-mount` identisch in Task 1 (Install) und Task 4 (Lint).
