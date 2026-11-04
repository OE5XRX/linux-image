# Boot-Stufe 2 + DT-Overlays aus dem A/B-Slot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CM4-Boot in zwei Stufen: eingefrorene Stufe 1 (`boot.scr` auf FAT) lädt Stufe 2 (`/boot/boot-stage2.scr`) aus dem aktiven Slot; Stufe 2 wendet die Slot-Overlays (`/boot/overlays/*.dtbo`) auf eine Kopie des Firmware-DTB an und bootet. Abgesichert durch U-Boot-Sandbox-Tests in CI.

**Architecture:** Stufe 1 behält Env/Bootcount/Rollback/Watchdog unverändert und fällt bei fehlender/zurückkehrender Stufe 2 exakt auf das heutige Booten zurück (+ Marker-bootarg). Stufe 2 ist per OTA austauschbar, maßgebliche bootargs-Quelle, arbeitet nur auf einer DTB-Kopie. Sandbox-Tests fahren die *echten* Skripttexte, nur `booti`/`wdt`/`reset`/`saveenv` und das Boot-Gerät werden vom Harness textuell ersetzt.

**Tech Stack:** U-Boot v2026.01 hush scripts, BitBake, dtc, pytest, U-Boot sandbox, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-04-slot-boot-stage2-overlays-design.md` (verbindlich; §5 = Agent, nicht hier).

## Global Constraints

- Stufe 1 fasst Rollback-Logik nicht an (Defaults, `setexpr bootcount + 1`, `saveenv`, Rollback-Block bleiben textgleich).
- Watchdog (`wdt dev …`/`wdt start 15000`) ist vor `source` der Stufe 2 scharf.
- Stufe 2: kein `saveenv`, kein Schreiben von `bootcount`/`upgrade_available`/`boot_part`.
- Overlays nur auf Kopie anwenden; bei Fehler frisch aus `${fdt_addr}` kopieren, **ohne alle** Overlays booten.
- Marker: `oe5xrx.stage2=ok|missing|failed`, `oe5xrx.overlays=ok:<a>[,<b>…]|failed:<name>` (leere Overlay-Liste ⇒ kein overlays-Marker).
- Fallback-bootargs in Stufe 1 = heutige bootargs-Zeile textgleich + ` oe5xrx.stage2=${oe5xrx_stage2}`.
- Bestehende Guards (ENV_REDUNDANT, ENV_OFFSET 0x4005000 / 0x4105000) bleiben.
- U-Boot-Sandbox = v2026.01, `sandbox_defconfig` + `OF_LIBFDT_OVERLAY CMD_FDT CMD_EXT4 CMD_PART`, `--disable EFI_CAPSULE_AUTHENTICATE`, `make NO_SDL=1`.
- Test-Fault-Schalter nie in Release-Builds (bbfatal, wenn gesetzt und `OE5XRX_RELEASE_TAG != dev`; Release-Gate prüft Artefakt).
- Tests: `tests/ota-integration/test_*.py`; Marker `unit` (jeder PR), `sandbox` (neuer CI-Job), `rpi_artifact` (Release-Gate).
- Workflow-Actions SHA-gepinnt (`actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0`).

## Review Focus

1. Stufe 2 verbiegt vor dem Zurückkehren `fdt_addr`/`kernel_addr_r`/`root_partnum`/`boot_part` → Stufe-1-Fallback muss trotzdem mit den Original-Werten booten (Task 3 `test_stage2_clobbering_vars_does_not_break_fallback`).
2. Zwei Overlays, das zweite scheitert → kein halb gepatchter Baum (kein ina226-Knoten), DTB valide (Task 3 `test_second_overlay_failure_boots_without_any_overlay`).
3. Persistiertes Env enthält fremde `oe5xrx_devtype`/`oe5xrx_stage2`-Werte → Stufe 1 überschreibt sie (Task 3 `test_stale_env_vars_are_overridden`).
4. Overlay-Datei fehlt im Slot → wie Anwendungsfehler, `failed:<name>` (Task 3 `test_missing_overlay_file_marks_failed`).
5. Rollback-Fall: Trial-Boot ohne Commit über mehrere simulierte Boots → nach `bootlimit` Slot-Wechsel, `upgrade_available=0` persistiert (Task 3 `test_trial_without_commit_rolls_back_after_bootlimit`).

---

### Task 1: Stufe 1 + Stufe 2 Skripte + Text-Regeln

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`
- Create: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot-stage2.cmd.in`
- Test: `tests/ota-integration/test_boot_scripts_static.py` (`unit`)

**Interfaces:**
- Produces: Stufe 1 setzt vor `source` unbedingt `oe5xrx_devtype mmc`, `oe5xrx_devnum 0` (je eigene Zeile, exakt `setenv oe5xrx_devtype mmc` / `setenv oe5xrx_devnum 0`), `root_partnum`, `boot_part`; lädt `/boot/boot-stage2.scr` nach `${scriptaddr}`. Stage-2-Template-Platzhalter `@OE5XRX_DT_OVERLAYS@` (leerzeichengetrennt) und `@OE5XRX_DT_OVERLAYS_CSV@` (kommagetrennt). Hilfsfunktion im Test-Modul: `render_stage2(template: str, overlays: list[str]) -> str` (wird von Task 2 Recipe gespiegelt und von Task 3/4 importiert; Ort: `tests/ota-integration/boot_scripts.py`).

- [ ] **Step 1: Failing tests** in `test_boot_scripts_static.py`:
  - `test_stage1_keeps_rollback_block_verbatim` — Defaults-Zeilen, `setexpr bootcount ${bootcount} + 1`, erster `saveenv`, Rollback-Block (`setenv bootcount 1`, `setenv upgrade_available 0`) vorhanden und vor `source`.
  - `test_stage1_arms_watchdog_before_source` — Index von `wdt start 15000` < Index von `source ${scriptaddr}`.
  - `test_stage1_fallback_bootargs_frozen_copy` — Fallback-`setenv bootargs` enthält die heutige Zeile (Konstante im Test, kopiert aus main) + ` oe5xrx.stage2=${oe5xrx_stage2}`.
  - `test_stage1_sets_device_unconditionally` — Zeilen `setenv oe5xrx_devtype mmc` und `setenv oe5xrx_devnum 0` existieren nicht innerhalb eines `if`.
  - `test_stage1_saves_and_restores_vars_around_source` — `fdt_addr kernel_addr_r fdt_addr_r root_partnum boot_part` werden vor `source` gesichert und danach zurückgesetzt.
  - `test_stage2_never_touches_rollback_state` — kein `saveenv`, kein `setenv bootcount|upgrade_available|boot_part`, kein `setexpr bootcount`, kein `env save`.
  - `test_stage2_works_on_copy` — `fdt move ${fdt_addr} ${fdt_addr_r}` vor jedem `fdt apply`; kein `fdt apply` während `fdt addr ${fdt_addr}` aktiv; `booti` nur mit `${fdt_addr_r}`.
  - `test_release_scripts_call_booti_wdt_directly` — keine `run oe5xrx_t_`-Strings; `booti`/`wdt`/`reset` als direkte Befehle.
  - `test_render_stage2_substitutes_and_rejects_bad_names` — Platzhalter ersetzt; Namen außerhalb `[a-z0-9-]+` → `ValueError`; leere Liste ⇒ kein `oe5xrx.overlays=`-Marker im Ergebnis.
  - `test_scripts_build_with_mkimage` (skip lokal ohne `mkimage`, fail mit `CI`).
- [ ] **Step 2: Run** `python -m pytest tests/ota-integration/test_boot_scripts_static.py -q` → FAIL.
- [ ] **Step 3: Implement.** Kopfkommentar in `boot.cmd`: „STAGE 1 — FROZEN after this change, only changeable by reflash; keep minimal." Neuer Ablauf nach `part number`-Check: Variablen sichern (`oe5xrx_s1_*`), `setenv oe5xrx_stage2 missing`; `if ext4load ${oe5xrx_devtype} ${oe5xrx_devnum}:${root_partnum} ${scriptaddr} /boot/boot-stage2.scr; then setenv oe5xrx_stage2 failed; source ${scriptaddr}; fi`; Variablen zurücksetzen; danach heutiger Kernel-Lade-/booti-/Rootfs-DTB-/reset-Pfad textgleich, nur `mmc 0` → `${oe5xrx_devtype} ${oe5xrx_devnum}` und bootargs + Marker. Stufe 2 (`boot-stage2.cmd.in`): Kernel laden (`return`-los: bei Fehler einfach Skriptende), `test -n "${fdt_addr}"` sonst Ende; `fdt addr ${fdt_addr}; fdt header get oe5xrx_fdt_size totalsize; fdt move ${fdt_addr} ${fdt_addr_r} ${oe5xrx_fdt_size}; fdt resize 0x10000`; `for o in @OE5XRX_DT_OVERLAYS@` mit Fehler-Flag `oe5xrx_ovl_failed` (Laden nach `${ramdisk_addr_r}` + `fdt apply`, nach erstem Fehler Rest überspringen); bei Fehler erneut `fdt move` + `resize`; bootargs = heutige Zeile + ` oe5xrx.stage2=ok` + overlays-Marker; `booti ${kernel_addr_r} - ${fdt_addr_r}`. `boot_scripts.render_stage2` implementieren (Regex `^[a-z0-9-]+$`; leere Liste entfernt die Marker-Zeile über einen zweiten Platzhalter `@OE5XRX_OVERLAYS_BOOTARG@` = `oe5xrx.overlays=ok:<csv>` bzw. leer — konkret: Template enthält Marker nur via Platzhalter).
- [ ] **Step 4: Run** → PASS. `uvx ruff@0.16.8 check tests/ota-integration` sauber (falls ruff im Repo nicht genutzt: überspringen).
- [ ] **Step 5: Commit** `feat(boot): two-stage CM4 boot — frozen stage 1 + slot stage 2`.

### Task 2: Recipes, U-Boot-Fragment, Overlay-Umzug, Test-Fault-Schalter

**Files:**
- Create: `meta-oe5xrx-remotestation/conf/oe5xrx-boot.inc` (`OE5XRX_DT_OVERLAYS ??= "oe5xrx-ina226"`, `OE5XRX_BOOT_TEST ??= ""`)
- Modify: `recipes-bsp/u-boot-ab/u-boot-ab_1.0.bb` (render stage 2 per sed, mkimage → `/boot/boot-stage2.scr` + `.cmd` im Rootfs, FILES; `do_compile[vardeps]`)
- Create: `recipes-bsp/u-boot/files/oe5xrx-fdt-overlay.cfg` (`CONFIG_OF_LIBFDT_OVERLAY=y`, `CONFIG_CMD_FDT=y`); Modify `u-boot_%.bbappend` (SRC_URI + bbfatal-Guard für beide)
- Modify: `recipes-bsp/oe5xrx-dt-overlays/oe5xrx-dt-overlays_1.0.bb` (do_install nach `/boot/overlays/<name>.dtbo` für jeden Eintrag aus `OE5XRX_DT_OVERLAYS`; kein deploy mehr), Kommentar in der dts
- Create: `recipes-bsp/oe5xrx-dt-overlays/files/oe5xrx-test-broken-overlay.dts` (Ziel `&oe5xrx_no_such_label`), `oe5xrx-test-marker-overlay.dts` (`target-path = "/"`, `oe5xrx,test-marker = "slot-overlay";`)
- Modify: `recipes-core/images/oe5xrx-remotestation-image.bb` (dtbo raus aus `IMAGE_BOOT_FILES`/`WKS_FILE_DEPENDS`; `oe5xrx-dt-overlays` in `IMAGE_INSTALL:append:raspberrypi4-64`; Kommentar), `raspberrypi4-64.yml` (`dtoverlay=oe5xrx-ina226` raus, Kommentar Regel „eigene Overlays nur im Slot")
- Create: `include/boot-test-marker.yml`, `include/boot-test-stage2-broken.yml`, `include/boot-test-overlay-broken.yml` (kas-Overlays, setzen `OE5XRX_BOOT_TEST`)
- Test: `tests/ota-integration/test_ina226_static.py` (anpassen), `tests/ota-integration/test_boot_recipes_static.py` (`unit`)

**Interfaces:**
- Consumes: `boot-stage2.cmd.in` + Platzhalter aus Task 1.
- Produces: Rootfs-Pfade `/boot/boot-stage2.scr`, `/boot/overlays/<name>.dtbo`; `OE5XRX_BOOT_TEST ∈ {"", "marker", "stage2-broken", "overlay-broken"}`: `marker` ⇒ Liste += `oe5xrx-test-marker`; `overlay-broken` ⇒ Liste += `oe5xrx-test-broken`; `stage2-broken` ⇒ Stufe 2 = nur `echo` (kehrt zurück).

- [ ] **Step 1: Failing tests**: `test_overlay_installed_into_rootfs_not_fat` (kein `oe5xrx-ina226.dtbo` in `IMAGE_BOOT_FILES`, `oe5xrx-dt-overlays` in rpi-`IMAGE_INSTALL`, Recipe installiert nach `/boot/overlays`), `test_config_txt_has_no_own_overlays` (kein `dtoverlay=oe5xrx-` in `RPI_EXTRA_CONFIG`; `otg_mode=1` + `ENABLE_I2C` bleiben), `test_uboot_fdt_overlay_fragment_and_guard` (Fragment im `SRC_URI:append:raspberrypi4-64`, Guard greppt `^CONFIG_OF_LIBFDT_OVERLAY=y` und `^CONFIG_CMD_FDT=y` mit `bbfatal`, ENV-Guards unverändert), `test_stage2_recipe_installs_to_rootfs_boot`, `test_boot_test_switch_guarded_against_release` (Recipe enthält bbfatal für `OE5XRX_BOOT_TEST` ≠ "" bei `OE5XRX_RELEASE_TAG` ≠ `dev`; jede kas-Overlay-Datei setzt genau einen gültigen Wert), `test_test_overlays_compile` (dtc; broken kompiliert, hat `__fixups__/oe5xrx_no_such_label`). Bestehende INA-Tests umstellen von FAT/config.txt auf Rootfs.
- [ ] **Step 2: Run** `python -m pytest tests/ota-integration -m unit -q` → neue FAIL.
- [ ] **Step 3: Implement** wie Files-Liste. Recipe-Render per `sed` mit identischer Semantik zu `render_stage2` (Task 1); Namensprüfung im Recipe per Python-Anonymous-Function (`bb.fatal` bei Namen außerhalb `[a-z0-9-]+`).
- [ ] **Step 4: Run** → PASS; `kas dump raspberrypi4-64.yml` und `kas dump raspberrypi4-64.yml:include/boot-test-marker.yml` parsen (falls kas lokal fehlt: CI `validate` deckt den Basis-Dump ab).
- [ ] **Step 5: Commit** `feat(image): slot-borne DT overlays + stage-2 recipe + fdt-overlay U-Boot guard`.

### Task 3: U-Boot-Sandbox-Harness + Tests + CI-Job

**Files:**
- Create: `scripts/build-uboot-sandbox.sh` (Klon v2026.01 → Config wie Global Constraints → `make NO_SDL=1`; Ausgabeverzeichnis Arg 1; idempotent)
- Create: `tests/ota-integration/uboot_sandbox.py` (Harness), `tests/ota-integration/test_boot_sandbox.py` (Marker `sandbox`)
- Modify: `tests/ota-integration/pytest.ini` (Marker `sandbox`, `rpi_artifact`), `.github/workflows/ci.yml` (Job `uboot-sandbox`), `.github/workflows/pr.yml` nicht (ci.yml läuft auf jedem PR)

**Interfaces:**
- Consumes: `boot_scripts.render_stage2`; Skripttexte aus Task 1.
- Produces (für Task 4):
  - `make_test_disk(path, slots: dict[str, dict[str, bytes]]) -> None` — GPT (`sgdisk -o`) mit `firmware`, `uboot_env`, `uboot_envr`, `root_a`, `root_b` (Partitionsnummern 1..5, Reihenfolge wie wks), ext4 via `mkfs.ext4 -d <dir>` + `dd` an Offset.
  - `rewrite_for_sandbox(script: str, *, stage1: bool) -> str` — ersetzt `booti A - B` → `setenv oe5xrx_t_kernel A; setenv oe5xrx_t_fdt B; run oe5xrx_t_booti`; Zeilenanfang `wdt ` → `echo OE5XRX_T_WDT `; Befehl `reset` → `run oe5xrx_t_reset`; `saveenv` → `run oe5xrx_t_saveenv`; nur stage1: `setenv oe5xrx_devtype mmc` → `setenv oe5xrx_devtype host`. Assert, dass jede Ersetzung ≥1 Treffer hat (Stufe 1: booti, wdt, reset, saveenv; Stufe 2: booti).
  - `run_boot(workdir, disk, stage1_text, base_dtb, env: dict[str,str]) -> BootResult` — mkimage der (umgeschriebenen) Skripte; Prelude-Skript setzt rpi_arm64-ähnliche Adressen (`kernel_addr_r 0x00080000`, `scriptaddr 0x02400000`, `fdt_addr_r 0x02600000`, `ramdisk_addr_r 0x02700000`, `fdt_addr 0x0e000000`), lädt Base-DTB nach `${fdt_addr}`, importiert `env.txt` (`env import -t`), definiert `oe5xrx_t_*` (booti: bootargs ausgeben, Kernel-Bytes + Ergebnis-DTB + DTB an `${fdt_addr}` per `host save`, `poweroff`; saveenv: `env export -t … boot_part bootcount upgrade_available bootlimit` → `env.txt`; reset: Marker + `poweroff`), `host bind 0 disk.img`, `source` Stufe 1. Ein Prozess pro simuliertem Boot, `timeout` 30 s.
  - `BootResult`: `booted: bool`, `reset: bool`, `bootargs: str`, `kernel: bytes` (erste 16 Bytes), `fdt_path: Path|None`, `fdt_addr_after: Path|None`, `env: dict[str,str]` (persistiert), `output: str`.
  - Env: `UBOOT_SANDBOX` (Pfad zum Build-Dir mit `u-boot` + `tools/mkimage`), `CM4_BASE_DTB`; fehlt eins ⇒ skip lokal, `pytest.fail` bei `CI`.
- [ ] **Step 1: Failing tests** (`test_boot_sandbox.py`), Slots enthalten `/boot/Image` = `b"KERNEL-SLOT-A..."`/`B`:
  - `test_normal_boot_applies_slot_overlay` — booted, kernel Slot A, bootargs enthalten `root=PARTLABEL=root_a`, `oe5xrx.stage2=ok`, `oe5xrx.overlays=ok:oe5xrx-ina226`; Ergebnis-DTB `/soc/i2c@7e804000/ina226@40|@41` `shunt-resistor` = 10000; persistiert `bootcount=1`; `OE5XRX_T_WDT start 15000` erscheint im Output vor der ersten Stufe-2-Ausgabe.
  - `test_stage2_missing_falls_back` — booted, `oe5xrx.stage2=missing`, kein overlays-Marker, `fdt=${fdt_addr}`-Wert, kein ina226-Knoten.
  - `test_stage2_returning_falls_back_failed` — Stufe 2 = `echo broken` ⇒ `oe5xrx.stage2=failed`.
  - `test_broken_overlay_boots_without_overlays` — Liste `oe5xrx-ina226 oe5xrx-test-broken` (Review Focus 2) ⇒ `oe5xrx.stage2=ok`, `oe5xrx.overlays=failed:oe5xrx-test-broken`, Ergebnis-DTB valide (fdtget liest `/compatible`), kein ina226-Knoten, DTB an `${fdt_addr}` byte-gleich zur Base.
  - `test_missing_overlay_file_marks_failed` (Review Focus 4).
  - `test_trial_rollback_when_bootcount_exceeds_limit` — Env `boot_part=b upgrade_available=1 bootcount=3 bootlimit=3` ⇒ booted Slot A, persistiert `boot_part=a bootcount=1 upgrade_available=0`.
  - `test_trial_without_commit_rolls_back_after_bootlimit` — Start `boot_part=b upgrade_available=1 bootcount=0`, 4 Boots ohne Commit ⇒ Boots 1–3 Slot B, Boot 4 Slot A (Review Focus 5).
  - `test_stage2_clobbering_vars_does_not_break_fallback` — Stufe 2 setzt `fdt_addr 0`, `kernel_addr_r 0x5000000`, `root_partnum 99`, `boot_part z` und kehrt zurück ⇒ booted Slot A mit Original-`fdt_addr` (Review Focus 1).
  - `test_stale_env_vars_are_overridden` — env.txt enthält `oe5xrx_devtype=bogus oe5xrx_stage2=ok` ⇒ normal gebootet (Review Focus 3).
  - `test_missing_slot_partition_resets` — `boot_part=c` ⇒ `reset`.
  - `test_rewrite_hits_every_indirection` — `rewrite_for_sandbox` auf echte Skripte, keine verbleibenden `booti `/`saveenv`/Zeilenanfang-`wdt `.
- [ ] **Step 2: Run** lokal in Docker (`debian:trixie` mit Deps aus Spec §7a + `gdisk e2fsprogs device-tree-compiler`): `UBOOT_SANDBOX=… CM4_BASE_DTB=… python -m pytest tests/ota-integration -m sandbox -q` → FAIL (Harness fehlt).
- [ ] **Step 3: Implement** Harness + Build-Skript + CI-Job `uboot-sandbox`: apt-Deps, `actions/cache` (Key: `uboot-sandbox-v2026.01-${{ hashFiles('scripts/build-uboot-sandbox.sh') }}`), Build, CM4-DTB von `raspberrypi/firmware@6f0881cba8bea8ec24956a5718714730e9936ec5` (`boot/bcm2711-rpi-cm4.dtb`, sha256 `dda5429988864e911304acae4c60c9866628bf8175fb6361ccbaceafedcd1c75`, prüfen), `pytest -m sandbox`. `shellcheck` für das Build-Skript in den Lint-Step.
- [ ] **Step 4: Run** → PASS (lokal Docker). Danach `-m unit` weiterhin grün.
- [ ] **Step 5: Commit** `test(boot): U-Boot sandbox tests for stage 1/2 + overlays (CI)`.

### Task 4: Release-Gate gegen echte rpi-Artefakte

**Files:**
- Create: `tests/ota-integration/rpi_artifact.py` (GPT-Parse in Python, FAT-Dateien per `mcopy -i img@@off`, ext4-Dateien per `debugfs -R "dump <p> <out>"`, mkimage-Script-Header entfernen: `script_text(scr_bytes) -> str`), `tests/ota-integration/test_rpi_artifact.py` (Marker `rpi_artifact`, Env `RPI_ARTIFACT_DIR`)
- Modify: `.github/workflows/release.yml` (Job `rpi-artifact-gate`, needs `build-rpi`; `release` needs ihn; läuft auch bei `dry_run`)

**Interfaces:**
- Consumes: Harness aus Task 3 (`make_test_disk`, `run_boot`, `rewrite_for_sandbox`), `scripts/build-uboot-sandbox.sh`.
- [ ] **Step 1: Tests**: `test_rootfs_carries_stage2_and_overlays` (root_a: `/boot/boot-stage2.scr`, `/boot/overlays/oe5xrx-ina226.dtbo`, kein `oe5xrx-test-*`), `test_fat_has_no_own_overlays` (FAT `config.txt` ohne `dtoverlay=oe5xrx-`, kein `overlays/oe5xrx-*`; `boot.scr` vorhanden), `test_release_stage2_has_no_test_fault`, `test_base_dtb_has_symbols_and_overlay_applies` (FAT-`bcm2711-rpi-cm4.dtb` hat `/__symbols__/i2c1`; `fdtoverlay` + Knoten @40/@41 shunt 10000), `test_sandbox_boot_with_built_scripts` (echte `boot.scr` + `boot-stage2.scr` + dtbo + FAT-DTB in den Sandbox-Harness ⇒ `oe5xrx.stage2=ok`, `oe5xrx.overlays=ok:oe5xrx-ina226`, ina226-Knoten). Unit-Test `test_script_text_strips_mkimage_header` (`unit`, mit lokal gebautem Skript; skip ohne mkimage).
- [ ] **Step 2–4:** implementieren; lokal gegen ein selbst zusammengestelltes Fake-wic (aus `make_test_disk` + FAT via `mkfs.vfat`/`mcopy`) prüfen, sofern kein echtes Artefakt verfügbar; echte Verifikation per `gh workflow run release.yml --ref feature/slot-boot-stage2 -f dry_run=true`.
- [ ] **Step 5: Commit** `ci(release): rpi artifact gate — slot overlays, FAT clean, sandbox boot of built scripts`.

### Task 5: Doku + Pin

**Files:**
- Modify: `README.md` (Abschnitt „Boot-Stufen + DT-Overlays": Regel eigene Overlays nur im Slot, config.txt nur für Firmware-Belange; Migration §6; Test-Build-Schalter), Projektstruktur-Baum
- Modify (zuletzt, SHA vom Parent): `scripts/pin-station-agent.sh <sha>` → `station-agent_0.1.0.bb`
- [ ] Doku schreiben, commit `docs: boot stages + slot overlays`.
- [ ] Nach Teil-A-SHA: Pin, CI grün, commit `Bump station-agent to <sha8> (boot commit gate)`.

PR-Body enthält die HW-Checkliste (Spec §7 Hardware 1–5) mit den kas-Overlays für Szenarien 2–4.
