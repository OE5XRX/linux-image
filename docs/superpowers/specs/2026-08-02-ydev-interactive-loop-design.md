# `ydev` — Interactive Yocto Dev Loop (Tier 2: build + QEMU + flash, local + remote)

**Datum:** 2026-08-02
**Branch:** `feat/ydev-interactive-loop` (off `origin/main`)
**Roadmap:** Spec 2 (der User-Teil). Baut auf **Spec 1** (shared sstate/downloads-Mirror, `main`, warm bewiesen: 99% Reuse, 5½ min statt 1¾ h). Cleanup/Pruning/shared-Hashserv → Spec 3.
**Verwandt:** PR #55 (`feat/fast-dev-loop`, offen) = **Tier 0** (Agent-Python-Live-Mount + Dev-Image + Prod-Safety-Guard). Diese Spec ist **Tier 2** (Image bauen/testen/flashen). Reihenfolge (User-Entscheid): **Spec 2 zuerst, PR #55 rebast danach obendrauf** (§9).

## 1. Ziel & Scope

Ein schneller, interaktiver **Tier-2**-Loop für Änderungen, die einen Yocto-**Build** brauchen (Kernel, Bootloader, Partition, Rootfs-Pakete): editieren → bauen (warm, gegen den Mirror) → in QEMU booten oder aufs Gerät flashen. Ein `just`-Kommando-Surface, **zwei Backends**:
- **Lokal (default)** — M920q baut gegen den warmen Mirror + lokales QEMU. Der Alltags-Loop.
- **Remote (Eskalation)** — on-demand Hetzner-CCX43 für schwere/kalte Builds oder um den M920q nicht zu blockieren, mit Auto-Teardown.

**Claude läuft lokal**, editiert lokale Sources, ruft `just`-Rezepte (die lokal bauen oder per SSH remote). Kein Remote-Auth für Claude.

**Explizit NICHT in Spec 2** (bleibt PR-#55-Territorium, §9): Dev-Image, Prod-Safety-Guard, Agent-Live-Mount, File-Watch/Auto-Sync, `dev-cm4`/`dev-qemu`.

## 2. Prinzipien

- **Ein Befehl = eine Sache.** Kein Rezept macht versteckt ein anderes Intent mit (z.B. `remote build` macht **kein** `up`). Fehlt eine Vorbedingung → **Fehler mit klarem Hinweis**, was zu tun ist.
- **Symmetrie lokal ↔ remote:** vorbereiten `just mount` ↔ `just remote up` · bauen `just build` ↔ `just remote build` · booten `just qemu` ↔ `just remote qemu` · abbauen `just umount` ↔ `just remote down`.
- **Eindeutig:** alles unter `remote …` ist remote, top-level ist lokal.
- **Kosten idiotensicher:** Remote-Boxen räumen sich selbst weg (Dreifach-Netz, §6) — man muss nie ans Abdrehen denken.

## 3. Struktur

Eure Konvention (justfile dünn, Logik in Scripts):
- `justfile` (Repo-Root): lokale/common-Rezepte + `mod remote`. Bare `just` → `just --list` (Default-Rezept). `set dotenv-load := true` (lädt `.env`).
- `remote.just`: das Remote-Modul (`just remote <recipe>`). Braucht `just` ≥ 1.31 (Module stabil).
- `scripts/ydev/*.sh`: die echte Logik (jedes Rezept ruft ein kleines Script). `bash`, `set -euo pipefail`.
- `.env` (git-ignored) + `.env.example` (getrackt). `just init` scaffoldet `.env`.
- `dist/` (git-ignored): Ziel für `remote download`.

## 4. Command-Surface (final)

### Setup / Health
- **`just init`** — `.env` aus `.env.example` scaffolden; sagt, welche Vars noch fehlen. Legt nichts Geheimes an.
- **`just doctor`** — Preflight, sagt in einem Blick was fehlt: `just` ≥ 1.31, `kas`, `sshfs`, lokaler Box-Key `~/.ssh/storagebox`, Mirror mountbar; für remote zusätzlich `hcloud`-Auth, `bws` erreichbar, `.env`-Vars gesetzt.

### Lokal (default)
- **`just mount`** — Shared-Mirror lokal nach `/mnt/yocto-shared` mounten (idempotent: skip wenn schon gemountet). Nutzt den **lokal abgelegten Box-Key** (`~/.ssh/storagebox`), Host/User aus `.env` — **kein BW-Token auf dem Laptop nötig**.
- **`just umount`** — aushängen.
- **`just build [machine=qemux86-64]`** — **failt mit Hinweis** (`just mount`) wenn `/mnt/yocto-shared` nicht gemountet; sonst `kas build <machine>.yml` (warm aus dem Mirror).
- **`just qemu`** — bootet das gebaute qemux86-64-Image lokal via `scripts/run-qemu.sh` (serielle Konsole im Terminal).
- **`just flash <device>`** — schreibt das **raspberrypi4-64**-`.wic` (aus `build/tmp/deploy/images/raspberrypi4-64/`, oder `dist/` nach `remote download`) auf `<device>`. **Safety:** Device-Pfad Pflicht; verweigert System-/Root-Disk + Nicht-Block-Devices; zeigt Device-Info + verlangt Bestätigung. Ohne `<device>` → listet removable-Kandidaten + Hinweis. (qemu wird **nicht** geflasht — dafür `just qemu`; das x86-`.wic` als Proxmox-VM-Disk zu importieren ist ein manueller Sonderfall, kein Rezept.)

### Remote (`mod remote`)
- **`just remote up`** — CCX43 (Projekt 2, ephemer) hoch → Deps → **bws-Fetch** der Box-Creds → Mirror mounten → Idle-Watchdog + Max-Lifetime-Timer installieren → Session-State lokal in `.ydev-session` (server-id/ip) merken. Idempotent: wenn schon eine Session-Box läuft, nur verbinden.
- **`just remote build [machine=qemux86-64]`** — **failt mit Hinweis** (`just remote up`) wenn keine Session-Box; sonst Source hochsyncen (`rsync`, ohne `build/`) → `ssh … kas build` remote (warm).
- **`just remote qemu`** — QEMU **auf der Box** starten, Serial über SSH ins lokale Terminal. Failt mit Hinweis wenn keine Box / kein gebautes Image.
- **`just remote download [machine=qemux86-64]`** — `rsync` der Deploy-Artefakte (rootfs `.ext4`/`.wic`, kernel, `.dtb`, `.qemuboot.conf` — derselbe Satz wie build.yml „Collect artifacts") von der Box → `dist/<machine>/`. Failt mit Hinweis wenn keine Box.
- **`just remote shell`** — SSH auf die Session-Box (Rumpoken / manuelles bitbake). Failt wenn keine Box.
- **`just remote status`** — läuft eine Session-Box? Uptime (≈ Kosten)? Mirror gemountet? Idle-Restzeit?
- **`just remote down`** — Session-Box jetzt löschen + `.ydev-session` weg.
- **`just remote clean`** — alle `ydev`-Session-Boxen (per Hetzner-Label) auflisten + killen (verwaiste aufräumen).

## 5. Creds & `.env`

- **Lokal = lokaler Key.** Persistente Maschine → Box-Private-Key einmalig in `~/.ssh/storagebox`. Kein BW-Token auf dem Laptop.
- **Remote = bws.** Ephemere Boxen holen die Box-Creds frisch via `bws` (Muster wie `servers/scripts/materialize-service-env.sh`, Projekt `oe5xrx-yocto-cache`), nichts persistiert auf der Box.
- **`.env`** (git-ignored), `just init`-scaffolded:
  - `HCLOUD_TOKEN` — Projekt 2 (ephemere Session-Box). **Delete-scoped Variante** wird auf die Box gelegt (für Self-Delete, §6).
  - `BWS_ACCESS_TOKEN` + `BWS_SERVER_URL` — Box-Creds-Fetch auf der Session-Box.
  - `HCLOUD_SSH_KEY_NAME` — bestehender Hetzner-Key.
  - `STORAGE_BOX_HOST` / `STORAGE_BOX_USER` — für den lokalen Mount (nicht geheim).
  - `YDEV_SERVER_TYPE` (default `ccx43`), `YDEV_LOCATION` (default `fsn1`, co-located mit der Box), `YDEV_IDLE_MINUTES` (default 30), `YDEV_MAX_HOURS` (default 4).

## 6. Auto-Teardown (Dreifach-Netz)

Damit man **nie ans Abdrehen denken muss** (Hetzner berechnet Server, solange sie *existieren* — Stoppen reicht nicht, es muss **gelöscht** werden):
1. **Idle-Watchdog** (systemd-Timer auf der Box, alle paar Minuten): keine aktive SSH-Session **und** kein `bitbake`-Prozess **und** CPU niedrig seit `YDEV_IDLE_MINUTES` → Box **löscht sich selbst** (delete-scoped `HCLOUD_TOKEN` auf der Box). Volume/Mirror bleibt (liegt in Projekt 1, wird nur gemountet).
2. **Harte Max-Laufzeit** (`YDEV_MAX_HOURS`) → self-delete egal was (Schutz gegen hängende Sessions).
3. **Nacht-Cron-Backstop** — ein Cron auf dem M920q ruft `just remote clean` → killt jede übriggebliebene `ydev`-Box. Gürtel + Hosenträger.

Worst Case: ~30 min Leerlauf bezahlt, nie mehr. Session-Boxen sind per Hetzner-**Label** (`ydev-session`) auffindbar.

## 7. Remote-Provisioning & Datenfluss

Laptop-getrieben via `hcloud`-CLI (kein GitHub-Workflow — das ist der Unterschied zu build.yml, das denselben bws→sshfs→kas-Bau kann, aber CI-getrieben):
```
just remote up   → hcloud server create ccx43 (Projekt 2, Label ydev-session)
                   → Deps + bws-Fetch Box-Creds → sshfs-Mount Mirror → Watchdog/Max-Lifetime
just remote build→ rsync <repo, ohne build/> → ssh: kas build   (warm aus Mirror)
just remote qemu → ssh: run-qemu   → Serial über SSH
just remote download → rsync deploy-images ← Box → dist/
just remote down → hcloud server delete
```
`build/tmp` liegt auf der lokalen NVMe der Session-Box (ephemer). Mirror-Read via `SSTATE_MIRRORS`, wie Spec 1. Cross-Project-Mount (Projekt 2 → Box in Projekt 1) über öffentlichen FQDN — in Spec 1 bewiesen.

## 8. Fehlerbehandlung

- Jedes Rezept prüft seine Vorbedingungen (Mount da? Session-Box da? `.env` vollständig? Image gebaut?) und **failt früh mit einem umsetzbaren Hinweis** statt still das Falsche zu tun.
- `just doctor` bündelt die Diagnose (die Nacht der Shared-FS-Fallen hat gezeigt: klare Preflight-Meldungen sparen Stunden).
- Flash-Guards (§4) verhindern das Überschreiben der falschen Disk.

## 9. Koexistenz mit PR #55 & Reihenfolge

Spec 2 **legt an**: `justfile` (+ `mod remote`/`remote.just`), `scripts/ydev/`, `.env.example`, und **erweitert** `scripts/run-qemu.sh` nicht destruktiv. Es bleibt **raus** aus: Dev-Image, Prod-Safety-Guard, Agent-Live-Mount.

PR #55 (Tier 0) **rebast danach obendrauf**: fügt dem justfile `dev-qemu`/`dev-cm4`/`lint-dev-isolation` hinzu, bringt das Dev-Image + den Guard, und **nutzt Spec 2s generisches `just flash` wieder** (statt eines zweiten `flash-sd`). Ein justfile, klare Schichtung Tier 2 (Spec 2) → Tier 0 (PR #55).

## 10. Testing

- **Rezept-Logik unit-testbar** (wie PR #55s `test_dev_launch.sh`): Vorbedingungs-Checks + Hinweis-Ausgaben via Dry-Run-Hooks (`YDEV_DRYRUN=1` druckt die geplante Aktion statt sie auszuführen) — testet „failt-mit-Hinweis" ohne echte Hetzner-Box.
- **Flash-Safety**: negativer Test (System-Disk / Nicht-Block-Device → refuse).
- **Lokaler Loop** manuell: `just mount` → `just build` (warm, Minuten) → `just qemu` bootet.
- **Remote-Loop** manuell/gated: `just remote up` → `build` → `qemu`/`download` → `down`; `remote status`/`clean` prüfen; Idle-Watchdog verifizieren (Box verschwindet nach `YDEV_IDLE_MINUTES`).
- `just --list` zeigt den vollen Surface; `yamllint`/`shellcheck` auf justfile-Scripts.

## 11. Bewusst NICHT / später (YAGNI)

- **File-Watch/Auto-Sync (mutagen)** → derselbe sshfs-Live-Mount wie PR #55s Agent-Loop; kommt mit PR #55, nicht Spec 2.
- **Proxmox-VM-Disk-Import** des x86-`.wic` (`qm importdisk`) → seltener manueller Sonderfall.
- **Mirror-Observability** (`just mirror-status`), **Shell-Completion**, **`just nuke`** (build/tmp wipen) → später wenn's zwickt.
- **sstate-Pruning / shared Hashserv** → Spec 3.
