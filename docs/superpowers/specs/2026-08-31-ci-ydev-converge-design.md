# CI Build-Server: Konvergenz auf den ydev-Pfad

- **Datum:** 2026-08-31
- **Status:** Draft (Design, zur Review)
- **Repo:** `linux-image`
- **Betroffene Files:** `.github/workflows/build.yml`, `.github/workflows/boot-ota-pr.yml`, `.github/workflows/release.yml`, `scripts/ydev/remote-up.sh`, `scripts/ydev/remote-lib.sh` (minimal), `.env.example`

## 1. Problem / Motivation

Der CI-Yocto-Build zieht heute pro Run über `build.yml` eine on-demand Hetzner-Box hoch. In PR #55 hat sich das aufgehängt: eine Box lief weiter, obwohl keine mehr laufen sollte, und ein neuer Run knallte in einen **Namenskonflikt**. Die `gh run list`-History zeigt einen `boot-ota-pr`-Run mit ~17 h Wall-Time — ein verwaister Box-Orphan, der durchgehend Geld (und CPU-Kontingent) frisst.

### Root Causes

1. **Fixe Namen.** `build.yml` benennt Server *und* GitHub-Runner konstant pro Maschine (`oe5xrx-yocto-builder-<machine>`). Jede Kollision — alter Server lebt noch, oder zwei Runs gleichzeitig — bricht bei `hcloud server create --name …` bzw. bei `config.sh` (Runner-Name schon vergeben).
2. **Concurrency erlaubt Parallelität.** Die Gruppe ist `yocto-build-<machine>-<prNumber|release>`. Zwei *verschiedene* PRs auf dieselbe Maschine haben verschiedene Gruppen → laufen gleichzeitig → beide wollen denselben fixen Namen.
3. **Cleanup nicht garantiert.** Der `cleanup`-Job läuft `if: always()`, wird aber bei **Cancellation** (neuer Push cancelt via `cancel-in-progress`) oft gar nicht erst gestartet → verwaister Server. Ein hängender Build bis zum 180-min-Timeout verschärft das.
4. **Fragiles imperatives Provisioning.** `build.yml` provisioniert die Box *nach* dem Boot über mehrstufiges SSH (SSH-Wait → `apt-get` → Runner-Install). Genau dieser Nach-dem-Boot-Tanz ist die „hängt sich auf"-Fläche.

### Zwei Infra-Idiome nebeneinander

Der `linux-image`-CI-Build (`build.yml`) ist ad-hoc bash+hcloud+SSH und **predates** das `ydev`-System. Das laptop-seitige `ydev` (`scripts/ydev/`, `just remote …`) löst dieselbe Aufgabe bereits **robust** und in Produktion:

- **Self-Teardown, dreifach abgesichert** (cloud-init, unabhängig von jeder externen Instanz):
  - Idle-Watchdog (`ydev-idle.timer`, alle 5 min) → self-delete nach `YDEV_IDLE_MINUTES`, wenn kein `bitbake`/SSH/Login läuft.
  - Max-Life (`systemd-run --on-active=${MAX_HOURS}h`) → harter self-delete, egal was.
  - Self-Heal → installiert `hcloud` nach, falls der Boot-Install scheiterte.
- **Label-scoped Cleanup** (`--label managed-by=ydev`, `just remote clean`) — räumt Verwaiste, fasst CI-Fremdes nie an.
- Kommentar in `remote-up.sh` wörtlich: *„a half-provisioned box can never linger and bill."* Genau die PR55-Klasse — schon gelöst, nur nicht in CI.

## 2. Goals / Non-Goals

**Goals**

- CI-Builds können sich weder aufhängen noch verwaisen: die Box **beendet sich immer selbst** (Skript-`down` als Happy-Path, cloud-init self-teardown als Notfallnetz).
- Keine Namenskonflikte, auch bei parallelen Runs mehrerer PRs.
- Kostensenkung durch günstigeren Server-Typ (CPX statt CCX) + Orphan-Eliminierung.
- **Ein Provisioning-Codepfad** für Laptop und CI (DRY) — CI nutzt die bewährten `just remote`-Skripte.
- Reusable-Workflow-Schnittstelle von `build.yml` (Inputs `machine`, `release_tag`, `dev_image`; Artifact-Name `yocto-image-<machine>`) bleibt **unverändert**, damit Caller (`boot-ota-pr.yml`, `release.yml`) nicht brechen.

**Non-Goals (bewusst geparkt)**

- **Proxmox-Konsolidierung / dedizierter Auktions-Server.** Durchgerechnet und verworfen: Hetzner-Auktionspreise (nach Juni-2026-Erhöhung) starten für eine passende Box bei ~€74/mo (NVMe — der Warm-Build-Speed-Vorteil wäre also real) — gegen ~€15–30/mo für ephemeral-CPX. Der Ausschluss läuft rein über **Kosten** (~€45–60/mo teurer; Break-even ~14× aktuelles Build-Volumen), nicht über die Disk. Konsolidierung ist eine spätere **Kapazitäts**-Entscheidung, keine Kosten-Entscheidung; sie verdient ein eigenes Dokument, falls warme Build-Speed je zum Engpass wird.
- **Terraform-managed ephemeral Boxen.** State-pro-Run + TF im Hot-Path jedes Builds — Missbrauch von Terraforms Stärke (das ist für langlebige „Pets" wie die `servers`-Prod-VM, nicht für wegwerfbare „Cattle").
- **15-min-Reaper-Cron.** Explizit abgelehnt (Rauschen + Actions-Minuten). Der cloud-init self-teardown ersetzt ihn event-frei.

## 3. Entscheidungs-Record (verglichene Optionen)

| Option | Behebt PR55 | €/Monat (real) | Ops-Fläche | Verdikt |
|---|---|---|---|---|
| Status quo | ❌ | ~44–59 (mit Orphans) | ad-hoc, 2 Idiome | Bug |
| Imperativ härten (unique names + workflow_run cleanup) | ✅ | ~8–30 var. | extern-cleanup kann ausfallen | schlägt DRY-Chance aus |
| **ydev-converge (gewählt)** | ✅✅ | **~15–30 var.** | **1 Pfad, Box besitzt eigenen Tod** | **✓** |
| Terraform ephemeral | ✅ | ~8–30 var. | TF im Hot-Path, State-Ceremony | over-engineered |
| Robot-Auktion / Proxmox-Konsolidierung | ✅ | ~74+ flat, NVMe | Host-Pet, DR-Rework, phys. SPOF | teurer (Break-even ~14×) |

**Gewählt: ydev-converge.** Billigste Option, behebt alle vier Root Causes an der Wurzel, nutzt produktiv-bewährten Code, keine neue Infra. Nicht Wegwerf-Arbeit selbst falls später doch konsolidiert wird: der ephemeral-Pfad bleibt dann die **Burst-Kapazität** neben einer warmen Baseline-VM.

## 4. Design

### 4.1 Kern-Codeeingriff: Box-Name parametrisieren (klein)

Der **einzige** geteilte Namensraum bei parallelen CI-Runs ist Hetzner (`--name`). Die lokale `.ydev-session`-Datei kollidiert nicht, weil jeder GH-Runner sein eigenes Dateisystem hat.

- `scripts/ydev/remote-up.sh`: hartcodiertes `NAME="ydev-session"` → `NAME="${YDEV_SESSION_NAME:-ydev-session}"`.
- Nichts sonst hängt am Namen:
  - Self-Teardown nutzt die Metadata-`instance-id`, nicht den Namen.
  - `remote-clean.sh` filtert per Label (`managed-by==ydev`), nicht per Namen.
  - `remote-down.sh` / `remote-status.sh` lesen die `session_id` aus dem State-File.
- **Box-Name-Constraint:** Hetzner erlaubt ≤63 Zeichen, RFC1123-ish. CI setzt `YDEV_SESSION_NAME=ci-${run_id}-${run_attempt}-${machine}` — deterministisch eindeutig pro Run *und* Re-Run (verhindert Kollision mit einer noch abbauenden Vorgänger-Box), klar unter 63 Zeichen.
- **Optional (nicht CI-kritisch):** State-File-Pfad ebenfalls override-bar machen (`YDEV_SESSION_FILE`), damit auch *lokal* parallele Sessions möglich werden. Nur wenn billig; sonst weglassen.

### 4.2 `build.yml` → dünner GH-hosted Wrapper

Die drei Jobs (`create-runner` self-hosted-Provisioning, `build` auf self-hosted Runner, `cleanup`) **kollabieren in einen einzigen `ubuntu-latest`-Job**, der die Box über SSH via `just remote` treibt:

```
checkout
install: just, hcloud CLI, bws, kas-nicht-nötig (läuft auf der Box)
just remote up            # cloud-init armt self-teardown; R2-creds gesetzt
just remote build <machine> [--dev]
just remote download <machine> [--dev]
upload-artifact yocto-image-<machine>
just remote down          # if: always()  ← Happy-Path-Teardown (NEU im CI-Flow)
```

- **`just remote down` als expliziter Teardown-Step mit `if: always()`.** Das Skript beendet die Box in *jedem* normalen Ausgang (Erfolg/Fehler/Timeout innerhalb des Jobs) selbst. Der cloud-init self-teardown (idle + max-life + self-heal) ist **nur noch das Notfallnetz** für den einen Fall, den `if: always()` nicht abdeckt: harte Run-Cancellation, bei der der Step nicht mehr startet.
- **Keine GitHub-Runner-Registrierung mehr.** Kein Registration-Token, kein `--ephemeral`, kein Deregister → die *Runner*-Namenskonflikt-Klasse verschwindet komplett (SSH-driven wie ydev).
- **Server-Typ** via `YDEV_SERVER_TYPE` (CPX-Gen2 statt `ccx43`) — reine CI-Env-Config, kein Code.
- **CI-getunte Teardown-Defaults:** `YDEV_IDLE_MINUTES` kurz (CI braucht kein 30-min-Idle; z.B. 10) und `YDEV_MAX_HOURS` als harter Backstop (z.B. 3, passend zum bisherigen 180-min-Timeout).
- **Concurrency** bleibt wie heute (per-PR-Gruppe, `cancel-in-progress`). Bei Cancellation greift das cloud-init-Notfallnetz.

### 4.3 Backstop-Cleanup (kein Cron)

- **Primär:** `just remote down` (Happy-Path).
- **Notfall 1:** cloud-init idle + max-life + self-heal auf der Box.
- **Notfall 2 (optional):** ein `just remote clean` (label-scoped) als **pre-run**-Schritt zu Beginn von `remote up` *oder* als seltener manueller/Wartungs-Aufruf. Bewusst **nicht** der abgelehnte 15-min-Cron. Da `remote clean` die *aktive* Session verschont (via `session_id`), müsste für CI-Nutzung geklärt werden, dass es nur *fremde* verwaiste Boxen killt (siehe Open Questions).

### 4.4 Secrets / Env-Mapping in CI

Der GH-hosted Job braucht (alle existieren bereits als Secrets):

| Env/Secret | Zweck |
|---|---|
| `HCLOUD_TOKEN` | Box create + (auf der Box) self-delete |
| `HCLOUD_SSH_KEY_NAME` | Hetzner-SSH-Key-Name für create |
| `HCLOUD_SSH_PRIVATE_KEY` | → in Datei schreiben, `HCLOUD_SSH_KEY` darauf zeigen lassen |
| `BWS_ACCESS_TOKEN` (+ `BWS_SERVER_URL`) | R2-Publish-Creds via bws holen |
| `YDEV_SERVER_TYPE`, `YDEV_SESSION_NAME`, `YDEV_IDLE_MINUTES`, `YDEV_MAX_HOURS` | CI-Config (env, keine Secrets) |

Kein `.env` nötig — `set dotenv-load` in `justfile` ist optional (just errored nicht bei fehlender `.env`); Config kommt über den Job-`env:`-Block. (Validierungs-Item: bestätigen, dass just ohne `.env` nicht bricht.)

### 4.5 Caller-Anpassung

`boot-ota-pr.yml` und `release.yml` rufen `build.yml` als reusable auf. Da die **Schnittstelle unverändert** bleibt (Inputs + Artifact-Name), sind idealerweise **keine** Caller-Änderungen nötig. Zu verifizieren im Plan.

## 5. Fidelity / Parität (nicht verlieren beim Umbau)

Das aktuelle `build.yml` hat Semantik, die der ydev-Pfad heute *nicht* 1:1 abbildet — muss im Plan geschlossen werden. **Verifiziert gegen den gemergten PR-#55-Stand (`main @ db8c911`)** — PR #55 hat genau diese dev-image-CI-Semantik eingeführt:

1. **Prod-only-Artifact.** `build.yml`'s „Collect artifacts" **excludet `oe5xrx-remotestation-dev-image-*`** — das Artifact (`yocto-image-<machine>`) speist `boot-ota-test`, das die *Prod*-Image booten muss. `remote-download.sh` zieht dagegen bewusst *alle* wics inkl. dev (Kommentar dort: „so `just local qemu --dev` can boot it"). → Download/Upload im CI muss die Prod-only-Semantik erhalten (dev-wic aus dem hochgeladenen Artifact ausschließen), **ohne** `remote-download.sh`'s Laptop-Verhalten zu ändern.
2. **`dev_image` baut BEIDE Targets.** `build.yml` mit `dev_image=true` baut `oe5xrx-remotestation-image` **und** `oe5xrx-remotestation-dev-image` in *einem* kas-Lauf (billiger sstate-Delta). `remote-build.sh --dev` baut aktuell **nur** das dev-Target. → `remote-build.sh` um einen „beide Targets"-Modus erweitern (neuer Flag, z.B. `--both`/`--ci`), nicht `--dev` umdefinieren (Laptop-Semantik „nur dev" bleibt). **`boot-ota-pr.yml` ruft `build.yml` mit `dev_image: true`** — dieser Pfad muss unverändert weiter funktionieren.
3. **`release_tag` / `OE5XRX_RELEASE_TAG`.** `build.yml` reicht den Release-Tag in bitbake (via `oe5xrx.yml` env). Der ydev-Build-Pfad muss denselben Env-Durchstich haben (Tag → Box → bitbake).
4. **Maschinen-Validierung.** `build.yml`'s „Validate machine input" (nur `qemux86-64`/`raspberrypi4-64`) beibehalten.
5. **`dev-image wic built`-Verify** (Existenz-Check) im dev-Fall erhalten.
6. **R2-Publish** passiert schon in `remote-build.sh` (identisch zur `build.yml`-Logik) — kein Verlust.

**Orthogonal (kein Handlungsbedarf):** PR #55 brachte den Fast-Dev-Loop (`dev.just`, `scripts/dev-attach.sh`, dev-image live-mount, sshfs) — ein Entwickler-Inner-Loop, der den `station_agent` live vom Host-Mount fährt. Das berührt den CI-Build-Box-Lifecycle **nicht**; `remote-up.sh`/`remote-lib.sh`/`box/*`/`remote-clean.sh`/`remote-down.sh` sind durch PR #55 unverändert. Der Konvergenz-Umbau hat mit dem Fast-Dev-Loop keine Interaktion.

## 6. Blast Radius / Risiken

| Risiko | Mitigation |
|---|---|
| Run-Cancellation → `down`-Step startet nicht | cloud-init idle + max-life self-teardown (Notfallnetz) |
| Box-Name > 63 Zeichen / ungültige Zeichen | `ci-<run_id>-<attempt>-<machine>` ist kurz + rein `[a-z0-9-]` |
| Parallele Runs | eigene Box je Run (unique name) + eigenes GH-Runner-FS; in-Box-Pfade (`/home/yocto/src`) pro Box isoliert |
| SSH-Host-Key (recycelte Hetzner-IPs) | per-Session `known_hosts` + `accept-new` (TOFU) — bereits in `remote-lib.sh` |
| Token auf der Box (HCLOUD_TOKEN in cloud-init) | Bereits akzeptierter Tradeoff in ydev (ephemeral, root-only, für Teardown-Garantie nötig) |
| `remote clean` killt aktive Fremd-Box | clean verschont nur die *lokale* Session; parallele CI-Boxen sind für einen anderen Run „fremd" → clean im CI mit Vorsicht (siehe Open Questions) |
| Build-Logs streamen über SSH statt native Actions-UI | akzeptiert; `run`/ssh gibt Live-Output; Timeouts über `YDEV_MAX_HOURS` + Job-`timeout-minutes` |

## 7. Testing

- **Dry-run-Pfade** existieren (`YDEV_DRYRUN=1`, `YDEV_DUMP_USERDATA=1`) — für Unit-artige Prüfung des generierten cloud-init + der hcloud-Aufrufe ohne echte Box.
- **Ein PR-Test-Build** (qemux86-64): verifizieren up→build→download→upload→down, Box danach in `hcloud server list` weg.
- **Parallel-Test:** zwei PRs auf qemux86-64 gleichzeitig → beide Boxen mit unterschiedlichem Namen, kein Konflikt, beide sauber weg.
- **Notfall-Test:** Run mitten im Build canceln → `down` startet nicht → verifizieren, dass die Box via cloud-init (idle/max-life) innerhalb der Frist verschwindet.
- **Parität:** `boot-ota-test` bekommt weiterhin die Prod-only-Artefakte und bootet erfolgreich.

## 8. Rollback

Rein Workflow-/Skript-Änderung, kein State. Rollback = Revert des PRs; die alte `build.yml` (self-hosted-Runner-Modell) ist sofort wieder aktiv. Keine Migration, keine Datenbewegung.

## 9. Open Questions (für den Plan)

1. **`remote clean` im CI** — nutzen wir es als pre-run-Sweep? Wenn ja, muss die „verschone aktive Session"-Logik so erweitert werden, dass sie parallele *fremde* CI-Boxen (die legitim laufen) nicht killt. Alternativ: clean nur manuell/Wartung, im CI weglassen und allein auf `down` + self-teardown vertrauen. **Tendenz:** im CI weglassen (self-teardown reicht), clean bleibt Laptop/Wartungs-Tool.
2. **Exakte CI-Defaults** für `YDEV_IDLE_MINUTES` / `YDEV_MAX_HOURS` / CPX-SKU (`YDEV_SERVER_TYPE`) — Feinjustierung.
3. **`dev_image`-Parität** — `remote-build.sh` erweitern vs. Wrapper baut zweimal (Design-Präferenz: ersteres).
4. **State-File-Override** (`YDEV_SESSION_FILE`) mit-implementieren (für lokale Parallelität) oder YAGNI?

## 10. Kosten-Appendix

- **Build-Aktivität** (30 Tage, `gh run list`): ~40 Box-Starts/Monat, ~25–35 legitime Box-Stunden (Orphan-Ausreißer 17 h herausgerechnet).
- **Ephemeral CPX:** ~€0,08–0,10/h → **~€3/mo warm, bis ~€10–15/mo kalt-lastig**; + CX23-Prod ~€6 → **~€15–30/mo gesamt**. Self-teardown cappt Orphan-Waste bei `MAX_HOURS` (~€0,4) statt heute 17 h ≈ €2+ pro Vorfall.
- **Heute real:** €44–59/mo (CCX43 + Orphans) — der Umstieg ist zugleich der Kosten-Fix.
- **Break-even Auktion (€74+):** ~14× aktuelles Build-Volumen nötig; selbst im DX-Camp-Crunch unrealistisch.
