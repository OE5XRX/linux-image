# FW-Release-Pin: Single-Source-of-Truth

**Datum:** 2026-07-21
**Repo:** linux-image
**Kontext:** Folgt auf PR #40 (native_sim + SA818-Emulator auf FW-Release 26.07.21-01 gepinnt). Wird in denselben PR gefaltet.

## Problem

Ein FW-Release-Tag steckt aktuell an ~8 Stellen über 5 Files. Ein „schneller" Bump verlangt: 2 Recipes umbenennen (`_PV.bb`), je PV/DESCRIPTION/Kommentar/URL editieren, die `release.yml`-Gate-Liste, den Harness-Test und die Doku anfassen. Eine vergessene Stelle → stiller Mismatch zwischen Recipe-Name, URL und sha, der das System durcheinanderbringt.

Gegenbeweis im selben Repo: `station-agent` pinnt seinen FW-Stand mit **einer** `SRCREV`-Zeile. Die FM-Asset-Pins sind nur umständlicher gemacht als nötig.

## Zielbild

**Ein** Tag für die ganze Layer. Die reale DFU-Firmware (`fm-sa818-2m.bin`), der `native_sim` ELF und der SA818-Emulator kommen aus **demselben** FW-Release — ein Image ist immer „FW-Release `<tag>`", Punkt. Sim und reale Firmware driften innerhalb einer Image-Version nie auseinander (Entscheidung des Users: getrennte Tags stiften mehr Verwirrung, nicht weniger).

Pro Release ändern sich genau **zwei** Arten von Werten:
1. **Der Tag** — eine Zeile in einem gemeinsamen Include.
2. **Die sha256-Hashes** — je Asset einer (Integritätsgrenze, unvermeidbar), aber **automatisch** vom Bump-Skript generiert, nie von Hand.

Alles andere (Dateiname, PV, DESCRIPTION, Kommentar, Gate, Test, Doku) interpoliert aus der einen Variable oder ist Prosa ohne Literal.

## Komponenten

### 1. Include `meta-oe5xrx-remotestation/conf/oe5xrx-fw-release.inc`
```
FW_RELEASE_URL_BASE ?= "https://github.com/OE5XRX/FW-RemoteStation/releases/download"
FW_RELEASE_TAG ?= "26.07.21-01"
```
Liegt unter `conf/` → via `require conf/oe5xrx-fw-release.inc` von jedem Consumer auflösbar (`BBPATH .= ":${LAYERDIR}"`).

### 2. Recipes — statische Dateinamen, Tag interpoliert
Alle drei `require` den Include, bauen `SRC_URI` aus `${FW_RELEASE_URL_BASE}/${FW_RELEASE_TAG}/<asset>`, leiten `PV = "${@d.getVar('FW_RELEASE_TAG').split('-')[0]}"` ab (dotted Datumsteil), behalten nur ihren eigenen `SRC_URI[…sha256sum]`:
- `oe5xrx-native-sim-fm.bb` (kein `_PV` mehr) → `fm-sa818-2m.native_sim`
- `oe5xrx-fm-firmware.bb` (kein `_PV` mehr) → `fm-sa818-2m.bin`
- `oe5xrx-sim-harness_1.0.bb` → die eine `https`-Zeile → `fm-sa818-2m.sa818-sim.py` (named checksum `sa818sim.sha256sum`)

Statische Namen ⇒ `release.yml`-Gate und Test referenzieren Pfade, die sich **nie** ändern.

### 3. Skript `scripts/bump-fw-release.sh` (ersetzt `pin-fw-artifact.sh`)
- `<tag>`: schreibt `FW_RELEASE_TAG`; fetch + cosign-verify + sha für **alle drei** Assets; schreibt die drei shas in die Recipes. Idempotent.
- `--check`: liest aktuellen Tag + shas, re-fetcht, cosign-verifiziert, prüft dass die aufgezeichneten shas noch matchen. **Kein** Rewrite. Wird vom Release-Gate aufgerufen.

cosign-Identity/Issuer-Contract wie zuvor (`…/release.yml@refs/heads/main`, Issuer `token.actions.githubusercontent.com`).

### 4. Consumer angepasst
- `release.yml`: handgeschriebener Verify-Block → `scripts/bump-fw-release.sh --check`. Deckt jetzt **alle drei** Assets ab (vorher fehlte der Emulator-Pin). cosign-Installer bleibt.
- `tests/sim-harness/test_sim_harness.sh`: Base + `FW_RELEASE_TAG` aus dem Include lesen, URLs rekonstruieren; shas aus den Recipes.
- `ci.yml`: shellcheck-Liste `pin-fw-artifact.sh` → `bump-fw-release.sh`.
- `sim-station.md`: Prosa referenziert den Include statt Tag-Literal.

## Bump-Workflow danach
```
scripts/bump-fw-release.sh 26.08.03-01
```
→ editiert 1 Tag-Zeile + 3 shas, cosign-verifiziert. Kein Rename, kein Gate/Test/URL-Edit.

## Verifikation
- `tests/sim-harness/test_sim_harness.sh` grün gegen die echten gepinnten Assets (rekonstruiert URLs aus dem Include → beweist den Interpolationspfad end-to-end).
- `bump-fw-release.sh --check` grün (cosign + sha für alle drei Assets).
- `bump-fw-release.sh <same-tag>` idempotent (kein Diff bei Re-Run).
- shellcheck sauber auf das neue Skript + Harness + Test.

## Bewusst außerhalb Scope
- Der Include hält nur FW-RemoteStation-Pins; `station-agent`-SRCREV bleibt wie es ist (schon single-source).
