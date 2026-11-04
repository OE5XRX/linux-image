# Boot-Stufe 2 + DT-Overlays aus dem A/B-Slot (CM4)

Datum: 2026-11-04 · Branch `feature/slot-boot-stage2` · PR in `linux-image` (Spec + Plan + Code) + vorgelagerter Agent-PR in `station-manager` (§5)

## Warum

Auf dem CM4 liegt heute alles, was vor dem Kernel passiert, auf der FAT-Partition
`firmware` (`/boot/firmware`): GPU-Firmware, `config.txt`, `overlays/*.dtbo`,
U-Boot und `boot.scr`. Die FAT-Partition gibt es nur einmal, OTA tauscht nur die
Root-Slots. Jede Änderung an Overlays oder an der Boot-Logik braucht deshalb einen
**Neuflash vor Ort** — zuletzt beim INA226-Overlay (#112).

Ziel: Was sich ändern kann, reist mit dem A/B-Slot (per OTA, rollback-sicher). Die
FAT-Partition enthält danach nur noch, was sich praktisch nie ändert.

User-Entscheidungen (Brainstorm 2026-11-04):
- **Umsetzen:** Boot-Logik in zwei Stufen (Stufe 2 im Slot) + Overlays aus dem Slot,
  angewendet von U-Boot.
- **Nicht umsetzen:** Laufzeit-Instanziierung des INA226 ohne Overlay; RPi-eigenes
  A/B für die FAT-Partition (`tryboot`/`autoboot.txt`).
- **Umsetzen (nachgeschoben, nach erfolgreichem Spike 2026-11-04):** U-Boot-Sandbox-Tests der
  Boot-Logik in der CI (§7a).

## Ziele

1. Ein neues oder geändertes DT-Overlay erreicht eine Station **per OTA**, ohne Neuflash.
2. Änderungen an der Boot-Logik nach Kernel-Auswahl (Overlays, bootargs, DTB-Behandlung)
   erreichen die Station **per OTA**.
3. Ein kaputtes Update (kaputte Stufe 2, nicht anwendbares Overlay) macht die Station
   **nicht unerreichbar**: entweder bootet sie ohne Overlay, oder der bestehende
   Bootcount-Rollback greift.
4. Das INA226-Overlay zieht vom FAT in den Slot.
5. Ein fehlgeschlagenes Overlay ist **sichtbar** (nicht still).

## Nicht-Ziele

- GPU-Firmware, `config.txt`, U-Boot-Binary per OTA aktualisieren (bleibt Neuflash).
- Basis-DTB aus dem Slot statt aus der Firmware (heutige Entscheidung bleibt: Firmware-DTB,
  weil `config.txt`-Effekte wie `otg_mode=1` nur dort ankommen; siehe Kommentar in `boot.cmd`).
- x86/GRUB-Pfad (qemux86-64) — dort gibt es keine DT-Overlays; unverändert.
- Emulation/Sandbox des CM4-Bootpfads.

## Anti-Ziele

- Stufe 1 hängt von Stufe 2 ab, um überhaupt booten zu können.
- Rollback-Logik (bootcount / upgrade_available / boot_part) wandert in Stufe 2 —
  dann könnte ein kaputtes Update den Rollback selbst kaputt machen.
- Ein fehlerhaftes Overlay führt zu einem halb gepatchten Devicetree, mit dem gebootet wird.

## 1. Stufe 1 — `boot.scr` auf FAT (danach eingefroren)

Bleibt in `u-boot-ab`, wird aus `boot.cmd` gebaut. Verantwortlich für alles, was
**nie** von einem Update abhängen darf:

- Env-Defaults, `bootcount`-Inkrement + `saveenv`, Watchdog scharf schalten (wie heute).
- Rollback-Entscheidung (wie heute, unverändert).
- `part number mmc 0 root_${boot_part} root_partnum` (wie heute).
- **Neu:** `ext4load mmc 0:${root_partnum} ${scriptaddr} /boot/boot-stage2.scr` und
  bei Erfolg `source ${scriptaddr}`. Vor dem `source` setzt Stufe 1 die Variablen,
  die Stufe 2 braucht (`root_partnum`, `boot_part`, Laufwerk `mmc 0`), als Env-Variablen.
- **Fallback:** Fehlt `boot-stage2.scr`, oder kehrt `source` zurück (Stufe 2 fehlgeschlagen,
  ohne selbst zu booten), bootet Stufe 1 **exakt wie heute** (Kernel aus dem Slot,
  Firmware-DTB `${fdt_addr}`, Rootfs-DTB-Fallback, sonst `reset`) — mit zusätzlichem
  bootarg `oe5xrx.stage2=missing` bzw. `=failed`.
- Der Watchdog ist vor `source` scharf → hängt Stufe 2, resettet der Watchdog, der
  Bootcount steigt, der bestehende Rollback greift.
- Der Fallback-Pfad bootet mit der eingefrorenen bootargs-Kopie (siehe §2.6).
- Stufe 1 so klein und defensiv wie möglich halten; sie wird nach diesem PR nur noch per
  Neuflash geändert. Kommentar im Kopf von `boot.cmd`, der das sagt.

## 2. Stufe 2 — `/boot/boot-stage2.scr` im Rootfs (per OTA)

Neues Artefakt im Rootfs (Rezept nach Wahl des Builders, z. B. in `u-boot-ab` oder
eigenes Rezept), per `mkimage -T script` gebaut. Ablauf:

1. Kernel laden: `ext4load mmc 0:${root_partnum} ${kernel_addr_r} /boot/Image`.
2. Firmware-DTB `${fdt_addr}` in einen Arbeitsbereich **kopieren** (`fdt move` nach
   `${fdt_addr_r}` o. ä.), `fdt addr` + `fdt resize` mit genug Reserve.
3. Für jedes Overlay der **zur Build-Zeit festgelegten Liste** (Bitbake-Variable, z. B.
   `OE5XRX_DT_OVERLAYS = "oe5xrx-ina226"`, in Stufe 2 eingebacken):
   `ext4load` aus `/boot/overlays/<name>.dtbo` → `fdt apply`.
4. **Schlägt Laden oder Anwenden eines Overlays fehl:** Arbeitskopie verwerfen, frisch aus
   `${fdt_addr}` kopieren und **ohne alle Overlays** booten (nie mit halb gepatchtem Baum —
   `fdt apply` kann den Basisbaum bei Fehlern beschädigen). bootarg
   `oe5xrx.overlays=failed:<name>`.
5. Erfolg: bootarg `oe5xrx.overlays=ok:<name>[,<name>…]`, `booti` mit der Arbeitskopie.
6. bootargs: **Stufe 2 ist die maßgebliche Quelle** (damit per OTA änderbar). Stufe 1 behält
   eine **eingefrorene Kopie** der heutigen bootargs nur für ihren Fallback-Pfad — bewusste,
   dokumentierte Duplizierung (Fallback muss ohne Stufe 2 funktionieren). *(Entscheidung Spec-Autor)*
7. Kehrt `booti` zurück → Stufe 2 endet, Stufe 1 übernimmt den Fallback.

Stufe 2 fasst `bootcount`, `upgrade_available`, `boot_part` **nicht** an und ruft kein
`saveenv`.

## 3. U-Boot-Konfiguration

- Neues Fragment (z. B. `oe5xrx-fdt-overlay.cfg`): `CONFIG_OF_LIBFDT_OVERLAY=y` und was
  `fdt apply` sonst braucht (`CMD_FDT`).
- Build-Guard in `u-boot_%.bbappend` wie beim Env: `bbfatal`, wenn
  `CONFIG_OF_LIBFDT_OVERLAY=y` nicht im gebauten `.config` steht (Fragmente können still
  verloren gehen — siehe Env-Vorfall).
- Overlays werden mit `dtc -@` gebaut (wie heute). Voraussetzung: der Firmware-DTB enthält
  `__symbols__` — im Plan als erstes verifizieren (aus dem gebauten
  `bcm2711-rpi-cm4.dtb` bzw. dem, was die Firmware lädt). **Falls nicht:** Overlays mit
  pfadbasierten Zielen (`target-path = "/soc/i2c@7e804000"`) schreiben, die keine Symbol-Fixups
  brauchen. *(Entscheidung Spec-Autor)*

## 4. INA226-Overlay umziehen

- `oe5xrx-dt-overlays` installiert `oe5xrx-ina226.dtbo` nach `/boot/overlays/` **im Rootfs**.
- Aus `IMAGE_BOOT_FILES` (FAT `overlays/`) und aus `RPI_EXTRA_CONFIG`
  (`dtoverlay=oe5xrx-ina226`) entfernen. `ENABLE_I2C=1` (`dtparam=i2c_arm=on`) bleibt in
  `config.txt` — der i2c1-Controller muss im Firmware-DTB aktiv sein.
- Regel für die Zukunft (in Doku/README festhalten): **eigene** Overlays nur noch im Slot;
  `config.txt` nur für Dinge, die die Firmware selbst braucht (`otg_mode`, `dtparam`).

## 5. Fehler sichtbar machen + Rollback (User-Entscheidung: Option a)

- Stufe 1/2 setzen bootargs `oe5xrx.stage2=ok|missing|failed` und
  `oe5xrx.overlays=ok:<namen>|failed:<name>`; landen in `/proc/cmdline`.
- **Commit-Gate im station-agent:** Während eines OTA-Trials (`upgrade_available=1`)
  bestätigt der Agent das Update **nicht**, wenn `oe5xrx.stage2` ≠ `ok` oder
  `oe5xrx.overlays=failed:…`. Er behandelt das genau wie einen fehlgeschlagenen
  Pre-Commit-Health-Check (`station_agent/health_check.py` → `run_health_checks`, Aufrufer
  `commit_boot` in `ota.py`): gleicher Fehlerpfad, gleiche Rollback-Mechanik, OTA-Ergebnis
  `rolled_back` mit Grund an den Server.
- **Kein Rollback** bei reinen Hardware-Zuständen: PowerBoard fehlt, INA antwortet nicht,
  I²C aus. Das Overlay wird dann trotzdem erfolgreich angewendet; der Treiber findet nur
  nichts → Agent lässt die `pwr.*`-Metriken weg (wie bisher).
- Fehlt der cmdline-Marker ganz (Station mit altem FAT/Stufe 1 ohne Marker): **kein**
  Blocker — als „alter Bootpfad" werten und normal committen (sonst würde jede noch nicht
  neu geflashte Station jedes Update zurückrollen).
- Zusätzlich meldet der Agent über die generischen Metriken (station-manager #177, kein
  Server-Code): `boot.stage2_ok` (1/0, nur wenn Marker vorhanden) und
  `boot.overlays_failed` (Anzahl), inkl. Descriptor.
- **Reihenfolge:** Die Agent-Änderung ist ein eigener PR in **station-manager** und wird
  **zuerst** gemergt; der linux-image-PR pinnt den Agent per `scripts/pin-station-agent.sh`
  auf diesen Stand (gleicher PR). So kommt nie eine Stufe 2 ohne Commit-Gate auf eine Station.

## 6. Migration / Rollout

- Stationen mit altem FAT (alte Stufe-1-lose `boot.scr`) ignorieren `boot-stage2.scr` und
  booten weiter wie bisher. Erst **ein Neuflash** mit dem neuen Image bringt Stufe 1 und
  das neue U-Boot. Danach nie wieder für Overlays/Boot-Logik.
- Stationen, die mit Release `2026.11.04-16` geflasht wurden, haben das INA226-Overlay
  noch über FAT/`config.txt`. Nach OTA auf ein neues Rootfs würde ihre alte `boot.scr`
  Stufe 2 nicht ausführen → kein doppeltes Anwenden. Beim Neuflash wird FAT sauber.

## 7. Tests

**CI (statisch, ohne Hardware).** Tests, die echte Build-Artefakte brauchen (Basis-DTB,
Image-Inhalt, `.config`), laufen im **Build-Job gegen `DEPLOY_DIR_IMAGE`** des rpi-Builds —
kein eingecheckter Referenz-DTB (würde driften). Reine Quelltext-Checks (Overlay kompiliert,
Skript-Text-Regeln) bleiben `-m unit`. *(Entscheidung Spec-Autor)*
- Beide Skripte bauen mit `mkimage` (Build bricht sonst).
- `fdtoverlay` auf dem Host: jedes Slot-Overlay gegen den CM4-Basis-DTB aus dem Build
  anwenden; INA226-Knoten `@40`/`@41` mit `shunt-resistor = 10000` im Ergebnis
  (bestehender `test_ina226_static.py` wird angepasst/erweitert).
- Statische Checks auf das gebaute Image/Recipe-Ausgaben: `/boot/boot-stage2.scr` und
  `/boot/overlays/oe5xrx-ina226.dtbo` im Rootfs; **kein** `dtoverlay=oe5xrx-` in der
  FAT-`config.txt`; `CONFIG_OF_LIBFDT_OVERLAY=y` (bbfatal-Guard).
- Text-Checks auf `boot.cmd`/Stufe 2: Stufe 2 enthält kein `saveenv`/`bootcount`/
  `boot_part`-Schreiben; Stufe 1 armt den Watchdog vor `source`.

### 7a. U-Boot-Sandbox-Tests (CI, ohne Hardware)

**Spike 2026-11-04 (Koordinator, lokal im Container) — verifiziert:**
- U-Boot **v2026.01** (= Image-Stand) baut als Sandbox: `sandbox_defconfig` +
  `OF_LIBFDT_OVERLAY`, `CMD_FDT`, `CMD_EXT4`, `CMD_PART`; zusätzlich
  `--disable EFI_CAPSULE_AUTHENTICATE` (sonst bricht der Build an einem fehlenden
  EFI-Signatur-Tool ab); `make NO_SDL=1`. Build-Deps (Debian): build-essential bison flex
  libssl-dev libgnutls28-dev uuid-dev python3-dev python3-setuptools swig pkg-config bc.
- `host bind 0 disk.img` mit GPT (`sgdisk -o …`; Partitionen `root_a`/`root_b`) →
  `part number host 0 root_b` liefert die Partition, `ext4load` liest aus dem Slot,
  `source` führt ein per `mkimage` gebautes Stufe-2-Skript aus.
- Echtes INA226-Overlay (`dtc -@`) auf den **echten CM4-Firmware-DTB**
  (raspberrypi/firmware `boot/bcm2711-rpi-cm4.dtb`, hat `__symbols__`) per `fdt apply`:
  `ina226@40/@41` mit `shunt-resistor = <10000>` unter `/soc/i2c@7e804000`.
- Kaputtes Overlay (unbekanntes Label): `fdt apply` scheitert mit `FDT_ERR_NOTFOUND` **und
  der Basisbaum ist danach beschädigt** (`FDT_ERR_BADMAGIC`) → bestätigt §2.4 zwingend:
  immer auf einer Kopie arbeiten, bei Fehler frisch aus `${fdt_addr}` kopieren.
- Env lässt sich zwischen simulierten Boots persistieren: `env export -t` + `host save` /
  `host load` + `env import` (Sandbox hat kein persistentes Env).

**Umsetzung:**
- CI-Job baut die Sandbox (gecacht) aus derselben U-Boot-Version wie das Image.
- Skripte (Stufe 1 + 2) bekommen das Boot-Gerät als Variable (`${bootdev}`, Default
  `mmc 0`); `booti` und `wdt` laufen über kleine Indirektionen, die im Test durch
  „Zustand ausgeben + beenden" ersetzt werden. **Die Indirektionen müssen im echten Image
  identisch zum heutigen Verhalten sein** (Text-Check im Test, dass Release-Skripte
  `booti`/`wdt` direkt bzw. unverändert aufrufen).
- Python-Testharness (pytest, `tests/…`) baut pro Fall ein GPT-Test-Image (root_a/root_b ext4,
  Stufe 2, Overlays, CM4-Basis-DTB aus dem Build bzw. dem Firmware-Repo-Pin) und ruft die
  Sandbox wiederholt auf (Env per Datei durchgereicht).
- Mindest-Fälle: normaler Boot (Slot, bootargs, Overlay-Knoten im Ergebnis-DTB);
  Stufe 2 fehlt → Fallback + `oe5xrx.stage2=missing`; Stufe 2 kehrt zurück → Fallback +
  `=failed`; Overlay kaputt → Boot mit **unbeschädigtem** Baum ohne Overlays +
  `oe5xrx.overlays=failed:…`; Trial mit `bootcount > bootlimit` → Slot-Wechsel +
  `upgrade_available=0`.
- Nicht abgedeckt (bleibt HW-Test): GPU-Firmware/`config.txt`, echter Kernel-Start, Watchdog.

**Hardware (einmalig, Test-Station; manuell mit User, Checkliste im PR):**
1. Neues Image flashen → bootet, `/proc/cmdline` enthält `oe5xrx.overlays=ok:oe5xrx-ina226`,
   INA226 unter `/sys/bus/i2c/devices/1-0040` + `1-0041`.
2. OTA auf ein Image mit **geändertem** Overlay (z. B. Test-Property) → Änderung kommt ohne
   Neuflash an.
3. OTA auf ein Image mit absichtlich kaputter Stufe 2 (Test-Build) → Fallback bootet
   (`oe5xrx.stage2=failed`), Agent verweigert den Commit → **Rollback auf den alten Slot**,
   Server sieht `rolled_back`; Station erreichbar.
4. OTA auf ein Image mit nicht anwendbarem Overlay → bootet ohne Overlays
   (`oe5xrx.overlays=failed:…`) → **Rollback** wie 3.
5. Station ohne gestecktes PowerBoard (oder Board abziehen) → Overlay `ok`, keine
   `pwr.*`-Metriken, **kein** Rollback.
Eine serielle Konsole an der Test-Station ist hilfreich (U-Boot-Ausgaben), aber keine
Voraussetzung — ohne sie zählt das Ergebnis (laufender Slot, `/proc/cmdline`).

## Dem Builder überlassen

- Rezept-Aufteilung, Dateinamen, Ladeadressen (aus den U-Boot-Defaults für rpi_arm64).
- Wo die bootargs-Definition lebt (eine Quelle).
- Format der Overlay-Liste im Build.
- Wie die Test-Builds für HW-Szenarien 3/4 erzeugt werden (z. B. Bitbake-Schalter, nicht in
  Release-Builds).

## Folge-Ideen (nicht hier)

- `qemuarm64`-Variante mit U-Boot für OTA/Rollback-Tests in CI.
- CM4-Bench mit Netboot (TFTP/NFS) + OTA für vollständige HW-CI.
