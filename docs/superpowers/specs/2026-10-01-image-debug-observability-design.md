# linux-image Debug-Observability — Design

**Date:** 2026-10-01
**Status:** Design
**Repo:** OE5XRX/linux-image
**Targets:** `raspberrypi4-64` (CM4/BCM2711) **and** `qemux86-64`

## Motivation

A bench station (CM4) reboots spontaneously and we cannot determine the cause.
The OS currently hides every signal that would explain it:

- `journalctl -b -1` / `--list-boots` show only **one** boot — the journal is
  not persistent, so each reboot wipes the prior boot's log.
- No kernel-panic/oops capture survives a reboot — a panic is lost with the RAM
  that printed it to a dead serial console.
- No undervoltage/throttle visibility on the CM4 (`vcgencmd get_throttled`).
- No eMMC/SD health tooling for later wear/error diagnosis.

This feature turns on the **OS-level sources** for all of the above so the
diagnosis data simply *exists and is readable*. Interpreting it (building a
`last_reboot_reason`, alerting) is the parallel **station-manager telemetry**
feature's job — see the binding contract below.

## Scope & Contract

This is **pure OS enablement**. It is the **Provider (Kind A)** side of
`contract/station-telemetry-interface` (project memory). It does **not** touch
the station-agent recipe or its `SRCREV` — the coordinator pins the agent as a
later step once the Consumer (Kind B) telemetry feature merges.

The contract requires A to make these sources readable; B feature-detects each
and degrades gracefully when absent (qemu / pre-merge / SD-not-eMMC):

| # | Source | Interface A must provide |
|---|--------|--------------------------|
| 1 | Kernel crash capture | pstore/ramoops records under `/sys/fs/pstore/` |
| 2 | journald boot separation | `journalctl --list-boots` shows separate boots; `-b -1` yields the prior boot |
| 3 | Undervoltage/throttle | `vcgencmd` on `PATH` (rpi) |
| 4 | Storage health | `mmc-utils` (`mmc` binary) installed |

**Out of scope:** reboot-reason enum logic, heartbeat fields, server alerting
(all Consumer-B); bootloader-env / active-slot / os-release / uptime / df /
meminfo / CPU-temp (contract lists these as already present — no A work).

## Constraints

- **Must not break boot on either target.** The qemu boot/OTA gate (T1/T2 in
  `tests/ota-integration -m qemu`) boots `qemux86-64`; a bad reserved-memory /
  kernel-config / cmdline change must not send qemu to emergency mode.
- **Machine-conditional where the mechanism differs** (rpi firmware vs qemu).
- **Reuse existing patterns:** kernel `.cfg` fragments + the two kernel
  bbappends; the `oe5xrx-boot-robustness` recipe shape; `data-init.sh` for
  persistent-partition seeding; cmdline edits in `boot.cmd` (rpi) and
  `files/wic/oe5xrx-grub.cfg` (qemu, the live config).
- **CI must stay green** (`validate` parse/lint, `sim-harness`, `ydev`,
  `dev-isolation`, `image-variant`, `dev-launch`) and the PR build + boot gate.
- Things only verifiable on real CM4 (ramoops capture across reboot,
  undervoltage) are documented **needs-HW**; builds + qemu-boot are verified in
  CI.

## Architecture

Four independent units, each with one purpose and a clear on-target interface.

### Unit 1 — pstore/ramoops (kernel crash capture)

**Kernel config fragment** `recipes-kernel/linux/files/oe5xrx-pstore.cfg`,
added to **both** `linux-raspberrypi_%.bbappend` and `linux-yocto_%.bbappend`
(SoC-agnostic; the pstore RAM backend is generic):

```
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y
CONFIG_PSTORE_COMPRESS=y
```

`CONFIG_PSTORE_RAM` pulls in `CONFIG_REED_SOLOMON` for the `ecc=1` option. On
x86 `CONFIG_EFI_VARS_PSTORE` may be built, but pstore registers only ONE backend
and the built-in ramoops registers first, so EFI pstore does not activate — there
is no separate EFI capture path.

**Reserved-memory mechanism — identical on both targets** via the kernel-6.12+
`reserve_mem` + `ramoops.mem_name` cmdline pair (we run 6.18, so it is
present). This reserves a named region **early from memblock** — no fixed
physical address to collide with, no device-tree overlay, and it sidesteps the
RPi problem that u-boot boots the *firmware* DTB (`${fdt_addr}`), not the
rootfs DTB, so a rootfs `reserved-memory` node would never take effect.

Cmdline tokens added to **both** bootloaders:

```
reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000
```

`reserve_mem` size/align/label match the kernel-doc example form
(`reserve_mem=2M:4096:oops ramoops.mem_name=oops`). The explicit
`record_size`/`console_size`/`pmsg_size` are required: module-parameter
ramoops defaults these to 0, which would register the region but capture
nothing. 3×256 KiB fits comfortably in the 2 MiB region (negligible on a
≥1 GiB CM4).

**Keep records readable for Consumer B.** `systemd-pstore.service` defaults to
`Unlink=yes`, which moves records out of `/sys/fs/pstore` (into
`/var/lib/systemd/pstore/`) and deletes them there — hiding fresh records from
B. Ship `/etc/systemd/pstore.conf` with `[PStore] Unlink=no` so systemd still
archives to `/var` (bonus persistence) but **leaves the record in
`/sys/fs/pstore`** for B to read and delete per the contract. This Yocto `systemd` is built without the pstore PACKAGECONFIG, so it does NOT auto-mount `/sys/fs/pstore` (and `systemd-pstore.service` is absent). The image therefore ships a `sys-fs-pstore.mount` unit (in `oe5xrx-boot-robustness`, enabled) that mounts the pstore filesystem at boot. Because `systemd-pstore` is absent, nothing deletes records from `/sys/fs/pstore`, so `pstore.conf` (`Unlink=no`) is inert here but kept as a harmless future-proofing guard should a later systemd enable that service. `pstore.conf` is folded into the
`oe5xrx-boot-robustness` recipe (same "diagnosable across reboots" purpose).

- rpi: appended to `bootargs` in `recipes-bsp/u-boot-ab/files/boot.cmd`.
- qemu: appended to the `linux` line in
  `meta-oe5xrx-remotestation/files/wic/oe5xrx-grub.cfg` (the live config). The
  reference-only `recipes-bsp/grub-ab/files/grub.cfg` is updated in lockstep for
  parity (it is documented as non-authoritative, but keeping it accurate is
  cheap).

**Platform reality:**
- **rpi:** real capture. DRAM retains contents across a warm reset (panic=5
  reboot / watchdog reset), so an oops written to the `oops` region is readable
  as `/sys/fs/pstore/dmesg-ramoops-0` after the reboot. **needs-HW** to confirm
  the region lands at a stable address and survives (the kernel docs caveat
  that `reserve_mem` placement "cannot be relied upon" on every machine — hence
  HW verification, with the EFI/DT fallback noted below if it regresses).
- **qemu:** `/sys/fs/pstore` mounts and ramoops registers (verifiable in the
  boot gate). Cross-reboot RAM capture is best-effort — a QEMU machine reset may
  clear RAM — which the contract explicitly accepts ("auf qemu reicht bricht
  nicht"). There is no EFI capture path (ramoops is the sole registered backend),
  so qemu cross-reboot capture relies on RAM retention alone and is best-effort.

**Fallback if HW shows `reserve_mem` unstable on CM4:** switch rpi to a
config.txt-applied device-tree overlay (`dtoverlay=`) carrying a fixed-`reg`
`reserved-memory` ramoops node. Documented as the contingency; not built now
because `reserve_mem` is the simpler mechanism and should work.

### Unit 2 — Persistent journald with boot separation

**Root cause:** `/var` is already bind-mounted onto the persistent data
partition (`var.mount` → `/mnt/data/var`), but **`/var/log/journal/` does not
exist**, so journald (default `Storage=auto`) stays volatile in
`/run/log/journal` and every reboot wipes it → only the current boot is ever
present. Boot *separation* itself is not broken (boots carry distinct kernel
`boot_id`s); persistence is the missing piece.

**Fix — two small changes:**

1. `recipes-core/ab-layout/files/data-init.sh`: add `log/journal` to the
   `/var` subtree it seeds on the persistent partition (one entry in the
   existing `for d in …` loop). Idempotent, runs every boot before the `/var`
   bind mount.
2. New drop-in
   `recipes-core/oe5xrx-boot-robustness/files/journald-persistent.conf`
   installed to `/etc/systemd/journald.conf.d/`, shipping:
   ```
   [Journal]
   Storage=persistent
   SystemMaxUse=64M
   RuntimeMaxUse=16M
   ```
   `Storage=persistent` makes the intent explicit (don't rely on dir-existence
   auto-detection); the size caps keep the journal from filling a small data
   partition. The install is folded into the existing `oe5xrx-boot-robustness`
   recipe (it is the natural home — same "keep the box diagnosable across
   reboots" purpose — avoiding a new recipe for one file).

`systemd-journald` writes to `/run` early, then stock
`systemd-journal-flush.service` migrates runtime logs to `/var/log/journal`
once `/var` is mounted; no custom ordering unit is needed because the
persistent dir now exists on the bind-mounted `/var`.

**Epoch caveat (documented, not fixed here):** the CM4 has no RTC and boots at
a fixed epoch until NTP corrects, so early entries of each boot carry a wrong
wall-clock time. This does **not** affect boot *separation* (`--list-boots`
keys on `boot_id`), but `-b -1` selection and timestamp correlation read oddly
until time-sync. Out of scope to fully fix; noted for Consumer B.

### Unit 3 — Undervoltage/throttle (rpi)

- **`vcgencmd` on PATH:** add the meta-raspberrypi `userland` package to the
  **rpi image only** (`IMAGE_INSTALL:append:raspberrypi4-64`). Satisfies the
  contract's hard requirement (#3).
- **Throttle-log service** (new recipe `oe5xrx-throttle-log`, installed
  **rpi-only**): a systemd `oneshot` + `timer` that runs a small script logging
  `vcgencmd get_throttled` (raw hex + decoded undervolt/throttle/freq-cap bits)
  to the **now-persistent** journal every 5 min. This gives an undervoltage
  *history* that survives the spontaneous reboot even when Consumer B was not
  polling at that instant — complementary to B reading `vcgencmd` live. Not
  installed on qemu → genuine no-op there. `RDEPENDS` on `userland`.

### Unit 4 — Storage health tooling

Add `mmc-utils` to the base `IMAGE_INSTALL` (both machines). Provides the `mmc`
binary for `mmc extcsd read /dev/mmcblkX` (eMMC life-time/PRE_EOL). Harmless on
qemu (virtio root, no mmc device — B reports "n/a"). `mmc-utils` is in
oe-core, already available to the build.

## Data flow

```
panic/oops ─► pstore RAM backend ─► (reboot, RAM retained) ─► /sys/fs/pstore/dmesg-ramoops-0
undervoltage ─► vcgencmd get_throttled ─► throttle-log timer ─► persistent journal
all boots ─► journald Storage=persistent (/var/log/journal) ─► journalctl --list-boots / -b -1
eMMC wear ─► mmc extcsd read ─► (Consumer B reads on demand)
```

Provider A stops at "readable on the box". Consumer B's station-agent reads
each source, feature-detecting and degrading, and sends it in the heartbeat.

## Error handling / fail-safe

- **Bootability is sacred.** `reserve_mem` failing to place the region makes
  ramoops registration fail *gracefully* (kernel logs a warning, no pstore) —
  it never blocks boot. The cmdline tokens are inert if the feature is
  unavailable.
- Kernel fragment symbols unsatisfiable on a given arch are dropped by the
  kconfig merge (same as the existing shared watchdog fragment's x86-only
  `I6300ESB_WDT`).
- `data-init.sh` stays idempotent and `set -eu`-safe; adding one `mkdir -p`
  entry cannot fail a clean boot.
- Throttle-log script: if `vcgencmd` is missing or errors, it logs a single
  notice and exits 0 — a timer unit must never enter `failed`.
- journald size caps prevent a runaway journal from filling the data partition.

## Testing

**Static unit guards** (`tests/ota-integration -m unit`, run on every PR,
cheap — the primary regression net):

- pstore kernel fragment exists and is wired into **both** kernel bbappends.
- Both bootloader configs (`boot.cmd`, `files/wic/oe5xrx-grub.cfg`) carry the
  `reserve_mem=…:oops` + `ramoops.mem_name=oops` cmdline tokens.
- `data-init.sh` seeds `log/journal`; the `journald-persistent.conf` drop-in
  ships `Storage=persistent` and `pstore.conf` ships `Unlink=no`, both in the
  recipe `SRC_URI` + `FILES`.
- Image recipe installs `mmc-utils` (base) and `userland` +
  `oe5xrx-throttle-log` (rpi-only); throttle-log script is shellcheck-clean.

**qemu boot gate** (`-m qemu`, PR build on Hetzner):

- Existing T1 (boots to login + agent checks in) already guards "doesn't break
  boot" — the strongest safety net for the kernel/cmdline changes.
- New `-m qemu` test `test_observability.py`: boot, log in as root (empty
  password), assert `/sys/fs/pstore` is a mountpoint and
  `journalctl --list-boots` succeeds (persistent journal active). Reuses the
  existing `QemuTarget` pexpect console.

**needs-HW (documented in PR, not automatable here):** ramoops capture across a
real CM4 reboot; `vcgencmd get_throttled` on real hardware.

## File-change summary

New:
- `recipes-kernel/linux/files/oe5xrx-pstore.cfg`
- `recipes-core/oe5xrx-boot-robustness/files/journald-persistent.conf`
- `recipes-core/oe5xrx-boot-robustness/files/pstore.conf`
- `recipes-core/oe5xrx-throttle-log/oe5xrx-throttle-log_1.0.bb`
- `recipes-core/oe5xrx-throttle-log/files/throttle-log.sh`
- `recipes-core/oe5xrx-throttle-log/files/oe5xrx-throttle-log.service`
- `recipes-core/oe5xrx-throttle-log/files/oe5xrx-throttle-log.timer`
- `tests/ota-integration/test_observability_static.py` (unit)
- `tests/ota-integration/test_observability.py` (qemu)
- `docs/operations/debug-observability.md`

Modified:
- `recipes-kernel/linux/linux-raspberrypi_%.bbappend` (+pstore fragment)
- `recipes-kernel/linux/linux-yocto_%.bbappend` (+pstore fragment)
- `recipes-bsp/u-boot-ab/files/boot.cmd` (+ramoops cmdline)
- `meta-oe5xrx-remotestation/files/wic/oe5xrx-grub.cfg` (+ramoops cmdline)
- `recipes-bsp/grub-ab/files/grub.cfg` (+ramoops cmdline, parity)
- `recipes-core/oe5xrx-boot-robustness/oe5xrx-boot-robustness_1.0.bb` (+journald drop-in)
- `recipes-core/ab-layout/files/data-init.sh` (+log/journal seed)
- `recipes-core/images/oe5xrx-remotestation-image.bb` (+mmc-utils base; +userland, +throttle-log rpi)
- `.github/workflows/pr.yml` — add the new `oe5xrx-throttle-log/**` path trigger
