# Shared sstate/downloads Mirror — Yocto Build Cache (Hetzner Storage Box)

**Datum:** 2026-08-01
**Branch:** `feat/shared-sstate-mirror` (off `origin/main`)
**Cross-Repo:** Terraform-Hälfte in `servers`, Build-/CI-Hälfte in `linux-image` — zwei PRs (siehe §9).
**Verwandt:** PR #55 (`feat/fast-dev-loop`) ist die *komplementäre* Tier-0-Ebene (Agent-Live-Mount). Diese Spec ist die Tier-2-Ebene (voller Build). Kein Overlap, sie stapeln (siehe §2).

## 1. Problem

Der volle Yocto-Build läuft heute auf einem on-demand Hetzner-Runner (`linux-image/.github/workflows/build.yml`, CCX43) mit einem **per-Machine Block-Volume** als sstate/downloads-Cache (`oe5xrx-yocto-cache-<machine>`). Reale Timings (warme, inkrementelle Builds): `create-runner` ~2 min, `build` ~5–6 min; cold nach Yocto-Bump ~1h35–1h42.

Drei Schwächen dieses Cache-Modells:
1. **Block-Volume ist attach-once.** Es kann nur an *einen* Server. Eine interaktive Build-Session (Spec 2) und ein CI-Build können denselben Cache nicht gleichzeitig nutzen. Schlimmer: `create-runner` hat einen Step *„Detach leftover cache volume (safety)"*, der das Volume **bedingungslos** abzieht — würde einer laufenden Session das Volume unterm Prozess wegreißen → Corruption.
2. **Cache ist nicht geteilt.** Der lokale Dev-Rechner (M920q) profitiert nicht vom CI-Cache und müsste alles selbst kompilieren — auf 8 GB RAM praktisch unbrauchbar.
3. **Kein warmer Start über Consumer hinweg.** Jeder Consumer (CI, zukünftige interaktive Box, lokal) hält seinen eigenen kalten/halbwarmen Zustand.

## 2. Verhältnis zur bestehenden Arbeit (Tiers)

Der Iterations-Weg hat zwei Tiers (Begriff aus PR #55):
- **Tier 0 — Agent-Python-Änderung:** kein Build nötig. PR #55 löst das über sshfs-Live-Mount des `station_agent` ins Dev-Image mit Fallback auf den gebackenen Agent.
- **Tier 2 — Kernel / Bootloader / Partition / Rootfs-Pakete:** braucht den vollen Build+Reflash. **Diese Spec** macht *diesen* Pfad schnell und teilbar.

Beide Ebenen sind unabhängig und ergänzen sich. Diese Spec berührt **weder** das Dev-Image, **noch** den Agent-Live-Mount, **noch** `run-qemu.sh`.

## 3. Ziel & Scope

Ein **geteilter, warmer** Yocto-Cache (sstate + downloads) auf einer **Hetzner Storage Box**, aus dem **CI, die spätere interaktive Build-Box (Spec 2) und der lokale M920q** alle lesen. Modell: **Read-Mirror + Push** — lesen aus dem Mirror, lokal bauen, sstate-Delta hochpushen. Das per-Machine Block-Volume entfällt komplett; damit verschwindet die Attach-once-Konflikt- und Corruption-Klasse.

**In Scope:** Storage-Box-Provisioning (Terraform), Bitwarden-Secret-Flow, Umbau `build.yml`, kas-Config (`SSTATE_MIRRORS`/`DL_DIR`), lokale M920q-Doku.
**Nicht in Scope:** siehe §12.

## 4. Architektur

### 4.1 Was geteilt wird — und was nicht
- **`build/tmp` (Werkbank)** → **lokale, schnelle Disk** pro Builder (CCX43 hat ~360 GB lokale NVMe; reicht für ein Image-`tmp`). Netzwerk-gemountetes TMPDIR ist bei Yocto brutal langsam. `build/tmp` ist ephemer (aus sstate rekonstruierbar).
- **`sstate-cache` + `downloads`** → **geteilt** auf der Storage Box. Read-heavy, latenz-tolerant, concurrent-safe — genau das Zielprofil von `SSTATE_MIRRORS`/`PREMIRRORS`.

### 4.2 Mount + Read/Write-Fluss
- **Mount:** SSHFS an `/mnt/yocto-shared` (SSH-Key-Auth, wiederverwendet das bestehende Hetzner-SSH-Key-Muster — eine Credential, kein Passwort-SSH). Storage Box unterstützt SSHFS nativ.
- **Read (sstate):** `SSTATE_MIRRORS` zeigt auf `file:///mnt/yocto-shared/sstate/...`. BitBake zieht prebuilt Artefakte statt neu zu kompilieren.
- **Write (sstate):** `SSTATE_DIR` bleibt **lokal** (schnell) auf dem Builder. Nach dem Build ein `rsync --ignore-existing` des sstate-Deltas → `/mnt/yocto-shared/sstate/`. So kein Concurrency-Wettlauf bei Writes.
- **downloads:** `DL_DIR = /mnt/yocto-shared/downloads`, shared-writable (BitBake lockt pro Download-File).

```
Storage Box (/mnt/yocto-shared)         gemountet per SSHFS
   sstate/     ◄── read via SSTATE_MIRRORS ──┐   ┌── rsync push (Delta) ──►
   downloads/  ◄── read+write (DL_DIR) ───────┼───┤
                                              │   │
   Builder:  SSTATE_DIR (lokal, schnell) ─────┘   │  build/tmp (lokale NVMe, ephemer)
   Consumers: CI-Runner · interaktive Box (Spec 2) · lokaler M920q
```

### 4.3 Block-Volume entfällt
Das per-Machine Block-Volume (`oe5xrx-yocto-cache-<machine>`) und der gesamte Attach/Detach/„Detach leftover"-Tanz in `build.yml` werden **entfernt**. `build/tmp` lebt auf der lokalen Disk des Runners, der Cache kommt aus dem Mirror. Nettovereinfachung + die Corruption-Gefahrenklasse ist weg.

## 5. Provisioning via Terraform (`servers` repo)

- Neu `servers/terraform/storage_box.tf`:
  ```hcl
  resource "hcloud_storage_box" "yocto_cache" {
    name             = "oe5xrx-yocto-cache"
    storage_box_type = "bx11"        # 1 TB — reicht für sstate+downloads deutlich
    location         = "fsn1"        # co-located mit dem CI-Build-Server (build.yml --location fsn1)
    password         = var.storage_box_password       # aus Bitwarden via bws-CLI (TF_VAR_*); Pflichtfeld, NICHT für Zugriff
    ssh_keys         = [var.storage_box_ssh_pubkey]    # Public-Key aus Bitwarden via bws-CLI
    access_settings = {
      ssh_enabled          = true
      reachable_externally = true    # Cross-Project-Mount über öffentlichen FQDN + SSH-Key
      samba_enabled        = false
      webdav_enabled       = false
      zfs_enabled          = false   # key-only
    }
  }
  ```
- **Provider-Bump:** nur `hetznercloud/hcloud` `~> 1.48` → `~> 1.60` (Storage-Box-Resource stable seit v1.60.0) in `versions.tf` + Lock-File. **Kein** neuer Terraform-Provider — Secrets kommen per `bws`-CLI (§6, Variante Y).
- **Outputs:** `storage_box_host` (= `.server`, FQDN zum Mounten), `storage_box_user` (= `.username`).
- Läuft durch die bestehende `servers`-Terraform-Pipeline (R2-State, Plan auf PR / Apply auf main).

### 5.1 Projekt-Zuordnung (2-Projekt-Setup bleibt)
Die zwei Hetzner-Projekte (1 = Foundation/`servers`-TF, 2 = ephemere Build-Runner) **bleiben** — Token-Isolation, Kostenübersicht (variable Runner-Stunden isoliert in Projekt 2) und Blast-Radius sind valide Gründe.

Die Storage Box liegt in **Projekt 1 (Foundation)**, gemanaged von der bestehenden `servers`-Terraform (ein Token, bestehender `hcloud`-Provider):
- Die Box ist **persistent und geteilt** (CI + interaktive Box + lokaler M920q) → semantisch Foundation, nicht ephemeres Runner-Projekt.
- **Cross-Project-Mount funktioniert:** SSHFS/rsync gehen über den öffentlichen FQDN (`reachable_externally = true`) + SSH-Key, nicht über Hetzner-Privatnetz. Die Projektgrenze blockt das nicht. Der Runner in Projekt 2 mountet die Box in Projekt 1 über SSH.
- **Kostenübersicht intakt:** die Box ist ~€3,8/Mo **fix**; das Variable (Runner) bleibt in Projekt 2 sichtbar.

## 6. Secret-Flow — Bitwarden via `bws`-CLI (Variante Y)

**Kein** neuer Terraform-Provider, **keine** neuen GitHub-Secrets. Es wird die **bestehende `bws`-CLI** genutzt (wie `servers/scripts/materialize-service-env.sh`): die Org kommt aus dem Access-Token, Secrets werden **per Name** referenziert. Der TF-Provider-Ansatz brauchte UUIDs/org_id — die CLI nicht.

```
Bitwarden-Projekt `oe5xrx-yocto-cache`  (Secrets per NAME, UPPERCASE-Keys)
   STORAGE_BOX_PASSWORD ─┐   servers/CI: bws holt PW+PUBKEY → TF_VAR_* → terraform apply
   STORAGE_BOX_SSH_PUBKEY┘
   STORAGE_BOX_SSH_PRIVKEY ─► linux-image/CI: bws holt HOST/USER/PRIVKEY → SSHFS-Mount
   STORAGE_BOX_HOST / _USER ◄─ nach 1. Apply von Hand eingetragen (statisch)
```

- **Du legst in Bitwarden ab (Projekt `oe5xrx-yocto-cache`, von Hand):** `STORAGE_BOX_PASSWORD`, `STORAGE_BOX_SSH_PUBKEY`, `STORAGE_BOX_SSH_PRIVKEY`.
- **`servers`-CI:** ein Step (Muster `materialize-service-env.sh`) holt PW+PUBKEY per `bws` → `TF_VAR_storage_box_password`/`_ssh_pubkey`; Terraform hat nur schlichte `sensitive`-Variablen, **keinen** BW-Provider.
- **host/user:** Terraform-**Outputs**; nach dem 1. Apply einmalig von Hand als `STORAGE_BOX_HOST`/`_USER` ins selbe Projekt eingetragen (statisch) → hält den Token read-only, kein CI-Write-back.
- **`linux-image`-CI (PR B):** holt `STORAGE_BOX_HOST`/`_USER`/`_SSH_PRIVKEY` **ebenfalls per `bws`** (nicht sm-action) → SSHFS-Mount. Auth key-only.

### 6.1 Einmaliger Bootstrap (manuell)
- **`servers`-Repo:** **keine neuen** GitHub-Secrets (`BWS_ACCESS_TOKEN` + `BWS_SERVER_URL` existieren bereits).
- **`linux-image`-Repo:** braucht `BWS_ACCESS_TOKEN` + `BWS_SERVER_URL` (derselbe eine Token, kein neues Secret-Material) — für PR B.
- Bitwarden: Projekt `oe5xrx-yocto-cache`, Machine-Account Read-Zugriff, die drei Secrets anlegen; nach 1. Apply host/user nachtragen.

## 7. CI-Änderungen (`linux-image/.github/workflows/build.yml`)

- `create-runner`: `sshfs` + `bws` installieren; **`bws`-CLI** zieht `STORAGE_BOX_HOST`/`_USER`/`_SSH_PRIVKEY` aus dem Projekt `oe5xrx-yocto-cache` (per Name, wie servers-CI); SSH-Private-Key **auf die Build-Box** kopieren (für den SSHFS-Mount *von dort* zur Box) und Box nach `/mnt/yocto-shared` mounten. Der bestehende „Detach leftover cache volume"-Step und die Block-Volume-Attach/Mount-Steps **entfallen**.
- Kas / `local.conf`: `SSTATE_MIRRORS` + `DL_DIR` setzen (via Env, analog zum bestehenden `OE5XRX_RELEASE_TAG`-Passthrough).
- `build`-Job: nach dem Build ein rsync-Push-Step (sstate-Delta → Box).
- `cleanup`-Job (`if: always()`): bleibt (Server-Delete, Runner-Deregister). Kein Volume-Detach mehr nötig.

## 8. Lokaler M920q

Dokumentierter Einzeiler (kein Automatismus nötig): Storage Box per SSHFS mounten (`BWS_ACCESS_TOKEN` lokal oder Key aus BW) + `SSTATE_MIRRORS`/`DL_DIR` in die lokale `local.conf`. Damit zieht auch die 8-GB-Kiste warmen sstate und muss kaum echt kompilieren — löst das lokale RAM-Problem für Iteration.

## 9. Cross-Repo — zwei PRs, Reihenfolge

Spec berührt zwei Repos → zwei PRs (eure PR-Granularität: ein PR pro Feature-Branch pro Repo):
- **PR A (`servers`):** `storage_box.tf` (bws-gefüttert) + `hcloud ~> 1.60`-Bump + `bws`-Fetch-Step in den TF-Jobs + Outputs. **Zuerst mergen** (Box muss existieren); danach host/user von Hand in BW eintragen. Keine neuen GitHub-Secrets.
- **PR B (`linux-image`, dieser Branch):** `build.yml`-Umbau (bws-Fetch + SSHFS-Mount) + kas-Config + lokale M920q-Doku. Braucht `BWS_ACCESS_TOKEN` + `BWS_SERVER_URL` im `linux-image`-Repo.

Dazwischen: der einmalige Bootstrap aus §6.1.

## 10. Rollout & Risiken

- **Erster Build nach Umstellung ist kalt** (~1,5 h): das alte Block-Volume-sstate wird aufgegeben, der Mirror ist leer und wird erstmalig befüllt. Danach warm. Bewusst in Kauf genommen (einmalig).
- **Concurrency:** sstate-Writes lokal + rsync-Delta → kein Wettlauf. downloads über BitBake-Locking safe.
- **SSHFS-Robustheit:** nur der kleine sstate/downloads-Read-Pfad läuft über den Mount, nicht `build/tmp` → tolerierbar. Bei Mount-Ausfall failt der Build hart (kein stiller Fallback auf „alles neu kompilieren" ohne Warnung — akzeptabel, seltener Fall).
- **sstate-Supply-Chain:** Mirror ist CI-beschreibbar und von allen lesbar → trusted-internal. Box strikt key-only (kein Passwort-SSH). sstate ist hash-adressiert; ein manipuliertes Objekt mit falschem Hash wird von BitBake nicht verwendet.

## 11. Testing

- **TF-Plan (`servers`):** `terraform plan` zeigt die Box + BW-Secrets sauber; kein Drift bei Re-Apply (Idempotenz).
- **CI-Smoke:** ein `workflow_dispatch`-Build nach PR B baut grün, Runner mountet die Box, rsync-Push landet Artefakte auf der Box (df/ls-Assertion im Job).
- **Warm-Beweis:** zweiter Build zieht sstate aus dem Mirror (Log zeigt `sstate` reuse statt `do_compile` für unveränderte Tasks); Build-Zeit deutlich < cold.
- **Secret-Isolation:** `sm-action` maskiert Creds im Log (keine Klartext-Leaks).
- **Bestehende Tests unberührt:** OTA-Integrationstests (`tests/ota-integration/`), CI-`validate` — diese Spec ändert keine Recipes/Images.

## 12. Bewusst NICHT in dieser Spec (YAGNI / Folge-Schritte)

Vereinbarte Roadmap: **Spec 1** = diese Cache-Foundation (Server/CI + lokaler Mount). **Spec 2** = der User-Teil (justfiles, interaktiver `ydev`-Loop, lokaler Helfer). **Spec 3** = Cleanup (Pruning etc.).

- **Interaktives `ydev`-Remote-Session-Tool + justfiles → Spec 2.** (Claude lokal / Ausführung remote, Idle-Watchdog + Nacht-Cron-Teardown, QEMU co-located. Nutzt diesen Mirror read-only als warmen Start.)
- **sstate-Pruning** (`sstate-cache-management.sh`, periodisch) → **Spec 3**. Der Cache wächst sonst unbegrenzt; bewusst später.
- **Hash-Equivalence-Server** (`BB_HASHSERVE`) — mehr sstate-Reuse, aber eigener Dienst; später wenn's zwickt (Spec 3).
- **SSH-Key-Konsolidierung bestehender Secrets nach Bitwarden** — diese Spec legt das *Storage-Box-Keypair* in BW ab und liest es dort (TF Public, CI Private). Das bestehende Runner-SSH-Secret (`HCLOUD_SSH_PRIVATE_KEY`, GitHub-Secret für den SSH-Zugang zur Build-Box) bleibt vorerst wie es ist; eine breitere Migration aller Repo-Secrets nach BW ist ein eigenes Thema.

### 12.1 Considered & deferred (bewusst verworfen/verschoben)

- **Bitwarden komplett auf den TF-Provider umstellen — verworfen.** Grenze bleibt: TF-Provider **nur** für Infra-Provisioning-Secrets (Box-PW/-Key, host/user), die `bws`-CLI (`servers/scripts/materialize-service-env.sh`) für Runtime-`.env`-Secrets auf der VM. Konsolidierung würde *alle* Service-Secrets in den (R2-)TF-State ziehen (Security-Downgrade) und TF kann `.env` eh nicht sauber auf der VM materialisieren. Beide Mechanismen behalten.
- **Build auf GitHub-hosted Runner umstellen — verworfen (als Primär-Builder).** Disk ist das K.o.: `build/tmp` will 50–100+ GB, Standard-Runner haben ~14–75 GB; der warme Cache spart *Compute*, nicht den Disk-Footprint. Cold-/Versions-Dump-Builds (geteilte vCPU) wären zudem drastisch langsamer als die ~1,5 h auf dem dedizierten CCX43. Der self-hosted on-demand CCX43 (dedizierte Kerne, 360 GB lokale NVMe, Auto-Teardown) bleibt der Primär-Builder; der Shared-Cache macht ihn warm.
