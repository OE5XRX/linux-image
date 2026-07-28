# Fast-Dev-Loop — linux-image (Dev-Image + Live-Mount + QEMU + Guard)

**Datum:** 2026-07-28
**Branch:** `feat/fast-dev-loop`
**Scope-Hälfte:** Image-, Mount-, QEMU- und Prod-Safety-Änderungen. Die Agent-/Server-/Sim-Hälfte liegt in `station-manager/docs/superpowers/specs/2026-07-28-fast-dev-loop-design.md` (gemeinsamer Branch-Name, ein PR pro Repo).

## Problem

Der `station-agent` ist heute als gepinnte Yocto-Recipe (SRCREV) **read-only ins Rootfs gebacken**. Jede Agent-Änderung erzwingt einen vollen Image-Build + Reflash (~30 Min), obwohl der Agent reiner Python-Code ist. Der Blast-Radius der Änderung (ein paar Python-Zeilen) steht in keinem Verhältnis zum Iterationsweg (kompletter Image-Bau).

## Wichtig: QEMU ist auch ein Prod-Target

`qemux86-64` ist **nicht** nur ein lokales Dev-Wegwerfziel — es läuft als **Produktions-Sim-Station auf einem Proxmox-Server** (`native_sim`-FM-Modul, siehe `docs/sim-station.md`). Es gibt damit zwei Produktions-Deployments: CM4 am Berg **und** QEMU-Sim-Station auf Proxmox. Beide fahren das **Prod-Image** und dürfen durch diese Arbeit nicht berührt werden.

Konsequenz für dieses Design: Der Fast-Dev-Loop hängt sich **ausschließlich ans `-dev-image`**, nie an „QEMU" pauschal. „QEMU" in dieser Spec meint immer *Dev-Image lokal auf QEMU*, nicht die Proxmox-Prod-Sim-Station. Die Trennung Dev-Image ↔ Prod-Image (inkl. CI-Guard, §5) ist damit doppelt kritisch: sie schützt nicht nur den CM4, sondern auch die QEMU-Prod-Station.

## Grundprinzip — Iterations-Tiers

Nur **Tier 2** (Kernel, Bootloader, Partition, Rootfs-Pakete) braucht den vollen Build+Reflash-Weg. Tier 0 (Agent-Python) wird über einen Live-Mount vom Host aus dem Build gelöst — auf dem **Dev-Image**, egal ob das lokal auf QEMU oder auf einem CM4 läuft. Details/Fehler-Klassen siehe station-manager-Spec.

## Kern-Entscheidung: Live-Mount via sshfs

Ein Protokoll für QEMU **und** CM4 — nicht mischen (sonst müsste man den Debug-Mechanismus selbst debuggen). sshfs gewählt, weil es die schon vorhandene SSH-Verbindung nutzt (kein Host-Daemon außer `sshd`, keine Export-Config, firewall-freundlich).

Der gebackene Agent im Rootfs bleibt **immer** lauffähig; der Mount ist nur ein Overlay obendrauf. Mount/Netz weg → Gerät fällt auf den gebackenen Agent zurück, nie gebrickt. Wichtig, weil „Agent verbindet nicht" selbst ein Netz-Bug sein kann.

## Komponenten (dieses Repo)

### 1. Dev-Image bekommt sshfs + fuse

In `oe5xrx-remotestation-dev-image.bb` (NUR dort, nie im Prod-Image):
- `sshfs-fuse` + `fuse` zu `IMAGE_INSTALL` hinzufügen.
- Ein Mount-Point-Verzeichnis `/mnt/dev` anlegen (auf der beschreibbaren `/mnt/data`-Overlay-Ebene bzw. tmpfs — nicht im read-only Rootfs).

### 2. sshfs-Mount des Host-Repos

Das Gerät mountet `station_agent/` vom Dev-Rechner nach `/mnt/dev/station_agent`:
- **CM4:** Host-LAN-IP.
- **QEMU:** Host über `10.0.2.2` (User-Net-Gateway; run-qemu nutzt bereits `-netdev user … hostfwd`).
- Host muss `sshd` laufen haben (Dev-Laptop). Auth via SSH-Key.
- Realisiert als Helfer-Script `scripts/dev-mount.sh <host> <host-repo-path>`, das per SSH aufs Gerät geht und dort den sshfs-Mount zurück zum Host aufsetzt (idempotent: erst prüfen ob schon gemountet).

### 3. systemd-Drop-in mit garantiertem Fallback

`station-agent.service.d/dev-override.conf` (nur im Dev-Image installiert):
- Setzt `WorkingDirectory` + `PYTHONPATH` so, dass der Agent aus `/mnt/dev/station_agent` läuft **wenn gemountet**.
- **Fallback-Mechanismus:** Ein Wrapper (`ExecStart=/usr/bin/station-agent-dev-launch`) wählt zur Startzeit die Quelle: Mount vorhanden und importierbar → Mount; sonst → gebackener Agent. So bootet das Gerät auch ohne Host/Netz sauber mit dem gebackenen Agent.
- Kein `ConditionPathIsMountPoint` als harte Bedingung (die würde den Service bei fehlendem Mount ganz überspringen statt zurückzufallen).

### 4. `run-qemu.sh` → `--dev-agent`-Flag

Neues Flag: bootet das Dev-Image, richtet den Port-Forward/Route so ein, dass der Gast den Host per sshfs erreicht, mountet `station_agent`, startet den Service neu und folgt dem Log. Bestehende Flags (`--fetch`, `--release`) bleiben unangetastet.

### 5. Prod-Safety-Guard (CI)

Analog zum bestehenden AUTOREV-Preflight: ein CI-Check, der verifiziert, dass `sshfs-fuse`/`fuse` und das `dev-override`-Drop-in **nicht** im Produktions-Image-Manifest landen. Verhindert, dass der Live-Mount-Pfad je in Prod driftet (Anti-Divergenz).

### 6. justfile (linux-image)

Dünne Recipes, echte Logik in `scripts/*.sh`, Hosts/Secrets aus ungetrackter `.env` mit Env-Override:
- `dev-qemu` — `scripts/run-qemu.sh --dev-agent`
- `dev-cm4 host=$cm4_host` — Mount sicherstellen (`dev-mount.sh`) → `ssh root@{{host}} systemctl restart station-agent` → `journalctl -f` (+ Serial-Trace)
- `build machine=qemux86-64` — `kas build …`
- `flash-sd device=…` — Dev-Image auf SD schreiben (Tier-2-Reflash)

Der `dev-cm4`-Loop lebt hier, weil er primär Mount+Service-Restart (Image/Device-Belang) ist. Cross-Repo-Bündelung folgt später im Umbrella-Repo.

## Datenfluss

```
Host: sshd + station_agent/ (live editiert)
   ▲ sshfs
CM4/QEMU: /mnt/dev/station_agent ──(systemd dev-override wrapper)──► station-agent.service
                                          │ Mount fehlt? → gebackener Agent (Fallback)
```

## Testing

- Boot-Test: Dev-Image bootet **ohne** Mount sauber durch (Fallback auf gebackenen Agent) — verhindert Brick-Regression.
- Mount-Test: nach `dev-mount.sh` läuft der Agent nachweislich aus `/mnt/dev/station_agent` (z.B. Marker-Datei/Version im Log).
- CI-Guard-Test: Prod-Image-Manifest enthält kein sshfs/fuse/dev-override.
- Bestehende OTA-Integrationstests (`tests/ota-integration/`) bleiben unberührt.

## Bewusst NICHT in dieser Spec (YAGNI / Folge-Schritte)

- USB-flashbare SD, Container-on-device — verworfen.
- Serielle Konsole: das Design ist bereit (Trace-Bündelung im `dev-cm4`-Recipe), Hardware kommt später vom User — kein Blocker.
- `just doctor`, Umbrella-Repo — benannte Folge-Schritte.

## Prod-Sicherheit (zusammengefasst)

sshfs-Client + `dev-override` + `/mnt/dev` existieren **ausschließlich** im `-dev-image`. Prod behält die gepinnte SRCREV-Recipe unverändert. Der CI-Guard erzwingt die Trennung. Das schützt **beide** Produktions-Deployments gleichermaßen: CM4 am Berg und die QEMU-Sim-Station auf Proxmox. `run-qemu.sh --dev-agent` bootet explizit das Dev-Image und berührt den Prod-Image-Pfad nicht.
