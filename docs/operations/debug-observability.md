# Debug Observability

## How it works

Four OS-level sources give operators and the station-agent enough signal to
diagnose spontaneous reboots, undervoltage events, and storage wear without
needing a serial console attached:

1. **Kernel crash capture** (`/sys/fs/pstore`) — pstore/ramoops survives a warm
   reset so a panic or oops is readable after the reboot.
2. **Persistent journal** — journald stores entries across reboots; separate
   boots are queryable by `boot_id`.
3. **Undervoltage/throttle log** (rpi only) — a timer logs `vcgencmd
   get_throttled` to the persistent journal every 5 minutes.
4. **Storage health** — `mmc-utils` ships on both targets; Consumer B reads
   eMMC life-time on demand.

This is pure OS enablement (Provider side of `contract/station-telemetry-interface`).
Interpreting the sources and sending them in the heartbeat is the Consumer side
(station-agent / station-manager). See also:
`docs/superpowers/specs/2026-10-01-image-debug-observability-design.md`.

---

## Source 1 — Kernel crash capture (`/sys/fs/pstore`)

**Mechanism:** `CONFIG_PSTORE_RAM=y` + kernel cmdline:

```
reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1 \
  ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000
```

`reserve_mem` carves a 2 MiB region (page-aligned, labelled `oops`) out of
memblock early in boot — no fixed physical address and no device-tree overlay
required. ramoops binds to it by name. Three 256 KiB slots (oops, console,
pmsg) fit comfortably in the 2 MiB region.

`systemd-pstore.service` normally moves records to `/var/lib/systemd/pstore/`
and unlinks them from `/sys/fs/pstore`. The image ships
`/etc/systemd/pstore.conf` with `Unlink=no`, so records stay in
`/sys/fs/pstore` where Consumer B can read and delete them per the contract.
`/sys/fs/pstore` itself is mounted automatically by systemd (no fstab entry
needed) when `CONFIG_PSTORE=y`.

**On-target verification:**

```bash
# list pstore records (empty = no crash since last clear, not an error)
cat /sys/fs/pstore/* 2>/dev/null

# confirm the filesystem is mounted
mountpoint /sys/fs/pstore
```

After a panic or oops, expect `dmesg-ramoops-0` (and possibly `console-ramoops-0`).

### Platform matrix

| | CM4 (rpi) | qemu |
|---|---|---|
| `CONFIG_PSTORE_RAM` | yes | yes |
| `/sys/fs/pstore` mounts | yes | yes |
| Cross-reboot RAM capture | yes (DRAM retained on warm reset) | best-effort (VM reset may clear RAM; no EFI fallback — built-in ramoops is the sole pstore backend) |

**needs-HW:** The kernel docs note that `reserve_mem` placement "cannot be
relied upon" on every machine. Verify on a real CM4 that the region lands at a
stable address and a ramoops record appears after an induced crash. If the
region is unstable, the contingency is to switch the rpi target to a
`config.txt` DT overlay (`dtoverlay=`) carrying an explicit fixed-`reg`
`reserved-memory` ramoops node.

---

## Source 2 — Persistent journal

**Mechanism:** `/var` is bind-mounted onto the persistent data partition. The
fix seeds `log/journal` inside that partition (via `data-init.sh`) and adds a
journald drop-in (`journald-persistent.conf`) that explicitly sets:

```
[Journal]
Storage=persistent
SystemMaxUse=64M
RuntimeMaxUse=16M
```

With `Storage=persistent` and the directory present, journald writes to
`/var/log/journal/` (persistent across reboots) rather than `/run/log/journal/`
(wiped on every boot). Boot separation is keyed on the kernel `boot_id`, which
is always present regardless of persistence.

**On-target verification:**

```bash
# list all boots (should grow after each reboot)
journalctl --list-boots

# read logs from the previous boot
journalctl -b -1

# confirm the journal directory is on the persistent partition
ls /var/log/journal/
```

**Epoch / no-RTC note:** The CM4 has no RTC. Until NTP syncs after a boot,
early journal entries carry a wrong wall-clock time (typically 1970 or a stale
firmware timestamp). This does **not** affect boot separation — `--list-boots`
and boot selection by `-b N` key on `boot_id`, not wall-clock time — but
timestamp correlation between boots reads oddly until NTP corrects.

---

## Source 3 — Undervoltage / throttle log (rpi only)

**Mechanism:** The `userland` package puts `vcgencmd` on PATH. The
`oe5xrx-throttle-log` timer runs a oneshot service every 5 minutes that logs
the raw hex and decoded bits of `vcgencmd get_throttled` to the persistent
journal. This builds a history that survives a spontaneous reboot even if
Consumer B was not polling at that instant.

**On-target verification:**

```bash
# check timer status
systemctl status oe5xrx-throttle-log.timer

# read undervoltage live
vcgencmd get_throttled
# e.g. throttled=0x0  → no events; 0x50005 → undervoltage has occurred

# read history from journal
journalctl -u oe5xrx-throttle-log.service
```

**needs-HW:** `vcgencmd` output and undervoltage history are only meaningful on
a real CM4 with the VideoCore firmware present. On qemu this service is not
installed.

### Platform matrix

| | CM4 (rpi) | qemu |
|---|---|---|
| `vcgencmd` on PATH | yes | no |
| `oe5xrx-throttle-log` timer | yes | not installed |

---

## Source 4 — Storage health (`mmc extcsd`)

**Mechanism:** `mmc-utils` is installed on both targets. It provides the `mmc`
binary for reading eMMC Extended CSD registers, which include life-time
estimation and pre-EOL state.

**On-target verification:**

```bash
# read full extcsd; grep for life-time fields
mmc extcsd read /dev/mmcblk0 | grep -i life
# e.g.
# eMMC Life Time Estimation A [EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_A]: 0x01
# eMMC Life Time Estimation B [EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_B]: 0x01
# eMMC Pre EOL information [EXT_CSD_PRE_EOL_INFO]: 0x01  (Normal)
```

Values 0x01–0x0A map to 0–100 % estimated lifetime used in 10 % bands; 0x0B =
exceeded. `PRE_EOL_INFO` 0x01 = normal, 0x02 = warning (>80 %), 0x03 = urgent.

### Platform matrix

| | CM4 (rpi) | qemu |
|---|---|---|
| `mmc-utils` installed | yes | yes |
| `/dev/mmcblk0` present | yes (eMMC) | no (virtio root) |
| Useful output | yes | n/a — no mmc device |
