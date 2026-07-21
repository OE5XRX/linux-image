# FW-Release-Pin: Single-Source-of-Truth

**Datum:** 2026-07-21
**Repo:** linux-image
**Kontext:** Folgt auf PR #40 (native_sim + SA818-Emulator auf FW-Release 26.07.21-01 gepinnt). Wird in denselben PR gefaltet.

## Problem

Ein FW-Release-Tag steckt aktuell an ~8 Stellen über 5 Files. Ein „schneller" Bump verlangt: 2 Recipes umbenennen (`_PV.bb`), je PV/DESCRIPTION/Kommentar/URL editieren, die `release.yml`-Gate-Liste, den Harness-Test und die Doku anfassen. Eine vergessene Stelle → stiller Mismatch zwischen Recipe-Name, URL und sha, der das System durcheinanderbringt.

Gegenbeweis im selben Repo: `station-agent` pinnt seinen FW-Stand mit **einer** `SRCREV`-Zeile. Die FM-Asset-Pins sind nur umständlicher gemacht als nötig.

## Zielbild

Pro Release ändern sich genau **zwei** Arten von Werten:
1. **Der Tag** — eine Zeile in einem gemeinsamen Include.
2. **Die sha256-Hashes** — je Asset einer (Integritätsgrenze, unvermeidbar), aber **automatisch** vom Bump-Skript generiert, nie von Hand.

Alles andere (Dateiname, PV, DESCRIPTION, Kommentar, Gate, Test, Doku) interpoliert aus der einen Variable oder ist Prosa ohne Literal.

## Zwei Tags, kein einer

`oe5xrx-fm-firmware` (echte DFU-`.bin`) geht via `IMAGE_INSTALL:append` ins **Basis-Image (auch echte RPi-HW)**; native_sim + sa818-sim nur ins Sim-Packagegroup (qemux86-64). Die reale Firmware darf sich **nicht** automatisch mit einem Sim-Bump mitbewegen — sie wird erst nach On-Hardware-Validierung angehoben. Deshalb zwei Tags in einem Include:

- `FW_RELEASE_SIM_TAG` — native_sim ELF + SA818-Emulator (Dev/Sim-Pfad)
- `FW_RELEASE_FW_TAG` — reale `fm-sa818-2m.bin` (DFU)

Die meiste Zeit sind beide gleich; die Entkopplung modelliert eine reale Anforderung (der User hat fm-firmware bewusst auf 26.07.04 gelassen, während der Sim auf 26.07.21 ging).

## Komponenten

### 1. Include `meta-oe5xrx-remotestation/conf/oe5xrx-fw-release.inc`
```
FW_RELEASE_URL_BASE ?= "https://github.com/OE5XRX/FW-RemoteStation/releases/download"
FW_RELEASE_SIM_TAG  ?= "26.07.21-01"   # native_sim + SA818 emulator (sim/dev)
FW_RELEASE_FW_TAG   ?= "26.07.04-01"   # real fm-sa818-2m.bin (DFU) — bump only after HW validation
```
Liegt unter `conf/` → via `require conf/oe5xrx-fw-release.inc` von jedem Consumer auflösbar (`BBPATH .= ":${LAYERDIR}"`).

### 2. Recipes — statische Dateinamen, Tag interpoliert
- `oe5xrx-native-sim-fm.bb` (kein `_PV` mehr): `require` den Include, `SRC_URI = "${FW_RELEASE_URL_BASE}/${FW_RELEASE_SIM_TAG}/fm-sa818-2m.native_sim;downloadfilename=..."`, `PV = "${@d.getVar('FW_RELEASE_SIM_TAG').split('-')[0]}"`, `SRC_URI[sha256sum]` bleibt (vom Skript geschrieben).
- `oe5xrx-fm-firmware.bb`: dito mit `FW_RELEASE_FW_TAG`.
- `oe5xrx-sim-harness_1.0.bb`: die eine `https`-Zeile nutzt `${FW_RELEASE_URL_BASE}/${FW_RELEASE_SIM_TAG}/fm-sa818-2m.sa818-sim.py`, `SRC_URI[sa818sim.sha256sum]` bleibt.

Statische Namen ⇒ `release.yml`-Gate-Liste und der Test referenzieren Pfade, die sich **nie** ändern.

### 3. Skript `scripts/bump-fw-release.sh` (ersetzt `pin-fw-artifact.sh`)
Modi:
- `--sim <tag>`: schreibt `FW_RELEASE_SIM_TAG` in den Include; fetch + cosign-verify + sha für native_sim **und** sa818-sim; schreibt beide shas in die Recipes.
- `--fw <tag>`: dito für `FW_RELEASE_FW_TAG` + die `.bin`.
- `--check`: liest aktuelle Tags + shas, re-fetcht, cosign-verifiziert, prüft dass die aufgezeichneten shas noch matchen. **Kein** Rewrite. Wird vom Release-Gate aufgerufen.

Wiederverwendet den cosign-Identity/Issuer-Contract aus `pin-fw-artifact.sh` (Identity-Regexp `…/release.yml@refs/heads/main`, Issuer `token.actions.githubusercontent.com`).

### 4. Consumer angepasst
- `release.yml`: der handgeschriebene Verify-Block wird durch `scripts/bump-fw-release.sh --check` ersetzt (eine Quelle für die Verify-Logik). cosign-Installer-Step bleibt.
- `tests/sim-harness/test_sim_harness.sh`: Base + `FW_RELEASE_SIM_TAG` aus dem Include lesen, URLs rekonstruieren, shas aus den Recipes; statt hartcodierter Recipe-Pfade mit Version.
- `ci.yml`: shellcheck-Liste `pin-fw-artifact.sh` → `bump-fw-release.sh`.
- Doku (`sim-station.md`): Prosa referenziert den Include, kein Tag-Literal.

## Bump-Workflow danach
```
scripts/bump-fw-release.sh --sim 26.08.03-01     # Sim-Assets
scripts/bump-fw-release.sh --fw  26.08.03-01     # (separat, nach HW-Test) reale Firmware
```
→ editiert 1 Tag-Zeile + die betroffenen shas, cosign-verifiziert. Kein Rename, kein Gate/Test/URL-Edit.

## Verifikation
- `tests/sim-harness/test_sim_harness.sh` grün gegen die echten gepinnten Assets (rekonstruiert URLs aus dem Include → beweist den Interpolationspfad end-to-end).
- `bump-fw-release.sh --check` grün (cosign + sha für alle drei Assets).
- shellcheck sauber auf das neue Skript + Harness + Test.
- `--sim`/`--fw` idempotent: Re-Run mit demselben Tag ändert nichts (sha bereits geschrieben).

## Bewusst außerhalb Scope
- fm-firmware-Bump auf 26.07.21 (separate HW-Entscheidung des Users).
- Der Include hält nur FW-RemoteStation-Pins; `station-agent`-SRCREV bleibt wie es ist (schon single-source).
