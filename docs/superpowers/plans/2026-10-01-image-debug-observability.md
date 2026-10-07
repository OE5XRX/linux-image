# linux-image Debug-Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the OS-level diagnostic sources (kernel crash capture, persistent journald with boot separation, `vcgencmd`, `mmc-utils`) a bench CM4 needs so spontaneous reboots can be diagnosed — the Provider side of `contract/station-telemetry-interface`.

**Architecture:** Kernel pstore/ramoops via a `.cfg` fragment in both kernel bbappends + a `reserve_mem`/`ramoops.mem_name` cmdline (same mechanism on arm64 and x86). Persistent journald by seeding `/var/log/journal` on the already-persistent `/var` bind mount + a `journald.conf.d` drop-in. `vcgencmd` (`userland`) and an rpi-only throttle-log timer. `mmc-utils` in the base image. Verified by cheap static unit guards on every PR plus the existing qemu boot gate, with one new qemu assertion.

**Tech Stack:** Yocto (Kas, wrynose), BitBake recipes, kernel kconfig fragments, systemd units, POSIX shell, pytest (ota-integration harness).

**Spec:** `docs/superpowers/specs/2026-10-01-image-debug-observability-design.md`

## Global Constraints

- **Pure OS enablement.** Do NOT touch `recipes-core/station-agent/**` or bump its `SRCREV`. (Coordinator pins the agent later.)
- **Both targets must keep booting:** `raspberrypi4-64` and `qemux86-64`. A bad reserved-memory / kernel-config / cmdline change must never send qemu to emergency mode (the T1/T2 boot gate boots qemu).
- Kernel version is pinned `6.18.%` (both `linux-yocto` and `linux-raspberrypi`) — `reserve_mem`/`ramoops.mem_name` (merged 6.12) are available.
- Reuse existing patterns: kernel `.cfg` fragments + the two bbappends; the `oe5xrx-boot-robustness` recipe shape; `data-init.sh` seeding; cmdline edits in `boot.cmd` and `files/wic/oe5xrx-grub.cfg`.
- Exact ramoops cmdline (verbatim, both bootloaders): `reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000`
- CI must stay green: `validate` (kas dump parse + shellcheck `meta-oe5xrx-remotestation/**/*.sh` + yamllint `.github/workflows/ *.yml` + wks/udev checks + `-m unit` pytest), `sim-harness`, `ydev-scripts`, `dev-isolation`, `image-variant`, `dev-launch`, plus the PR build + boot gate.
- Any new shell script under `meta-oe5xrx-remotestation` is auto-shellchecked by `validate` (flags `-e SC1091 -e SC2039`) — keep it clean.
- Squash-merge, one PR against `main`. Spec + plan + code on this one branch.

## Review Focus

- **qemu boot regression from the ramoops cmdline:** a malformed `reserve_mem`/`ramoops.*` token must not stop qemu booting to login. → Task 7 (qemu test asserts boot-to-login still works + `/sys/fs/pstore` mounts).
- **Throttle-log timer entering `failed` when `vcgencmd` errors/missing:** a oneshot that exits non-zero shows systemd `degraded`. The script must log once and `exit 0`. → Task 5 (test asserts the script handles missing `vcgencmd` with exit 0).
- **`data-init.sh` regressing boot if the new `mkdir` fails:** the script is `set -eu` and runs before `local-fs.target`. The added entry must be a plain relative dir in the existing loop (cannot fail on a writable `/mnt/data`). → Task 3 (test asserts `log/journal` is in the seeded loop list, not a separate fragile statement).
- **systemd deleting pstore records before Consumer B reads them:** default `Unlink=yes` moves records out of `/sys/fs/pstore`. → Task 3 (test asserts `pstore.conf` ships `Unlink=no`).
- **Both bootloaders drifting out of sync:** the rpi `boot.cmd` and qemu `oe5xrx-grub.cfg` must carry the *same* ramoops tokens, or capture works on only one target. → Task 2 (one test parametrized over both files asserts identical tokens).

---

### Task 1: pstore kernel config fragment, wired into both kernel bbappends

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-kernel/linux/files/oe5xrx-pstore.cfg`
- Modify: `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-raspberrypi_%.bbappend`
- Modify: `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend`
- Test: `tests/ota-integration/test_observability_static.py`

**Interfaces:**
- Consumes: nothing.
- Produces: the fragment file `oe5xrx-pstore.cfg` and the fact that both bbappends `SRC_URI:append` it — later tasks don't depend on this, but the static test suite file created here is extended by Tasks 2–5.

- [ ] **Step 1: Write the failing test**

Create `tests/ota-integration/test_observability_static.py`:

```python
"""Static guards for the debug-observability OS enablement (spec
2026-10-01-image-debug-observability-design.md). Pure file-content checks —
run on every PR via `-m unit`; no build/qemu needed."""

import os

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LAYER = os.path.join(_REPO, "meta-oe5xrx-remotestation")


def _read(*parts):
    with open(os.path.join(_REPO, *parts)) as f:
        return f.read()


# ---- Task 1: pstore kernel fragment -------------------------------------

_PSTORE_CFG = ("meta-oe5xrx-remotestation", "recipes-kernel", "linux",
               "files", "oe5xrx-pstore.cfg")


def test_pstore_fragment_enables_ram_backend():
    cfg = _read(*_PSTORE_CFG)
    for sym in ("CONFIG_PSTORE=y", "CONFIG_PSTORE_RAM=y",
                "CONFIG_PSTORE_CONSOLE=y", "CONFIG_PSTORE_PMSG=y"):
        assert sym in cfg, f"{sym} missing from oe5xrx-pstore.cfg"


@pytest.mark.parametrize("bbappend", [
    "linux-raspberrypi_%.bbappend",
    "linux-yocto_%.bbappend",
])
def test_pstore_fragment_wired_into_both_kernels(bbappend):
    txt = _read("meta-oe5xrx-remotestation", "recipes-kernel", "linux", bbappend)
    assert "oe5xrx-pstore.cfg" in txt, (
        f"{bbappend} does not SRC_URI:append file://oe5xrx-pstore.cfg"
    )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -m unit -q`
Expected: FAIL — `FileNotFoundError` for `oe5xrx-pstore.cfg`.

- [ ] **Step 3: Create the fragment**

Create `meta-oe5xrx-remotestation/recipes-kernel/linux/files/oe5xrx-pstore.cfg`:

```
# Kernel crash capture that survives a reboot: pstore with the RAM backend
# (ramoops). A panic/oops is written to a reserved RAM region and reread from
# /sys/fs/pstore after the reboot (DRAM retains contents across a warm reset).
# The reserved region + record sizes are configured on the kernel cmdline via
# reserve_mem=/ramoops.mem_name= (boot.cmd + oe5xrx-grub.cfg), which works
# without a device-tree node — important on RPi, where u-boot boots the FIRMWARE
# DTB, not a rootfs DTB. SoC-agnostic, so this fragment is shared by both the
# linux-raspberrypi (CM4) and linux-yocto (qemux86-64) kernels.
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y
# Compress pstore records (zlib/deflate) — default y in 6.18; set explicit.
CONFIG_PSTORE_COMPRESS=y
```

- [ ] **Step 4: Wire into the RPi kernel bbappend**

In `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-raspberrypi_%.bbappend`, after the existing `SRC_URI:append = " file://oe5xrx-ikconfig.cfg"` line, add:

```
# Kernel crash capture (pstore/ramoops). SoC-agnostic fragment shared with the
# qemu kernel; the reserved RAM region is set on the cmdline in boot.cmd.
SRC_URI:append = " file://oe5xrx-pstore.cfg"
```

- [ ] **Step 5: Wire into the qemu kernel bbappend**

In `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend`, after the `oe5xrx-snd-aloop.cfg` line, add:

```
# Kernel crash capture (pstore/ramoops). Shared fragment; the reserved RAM
# region is set on the cmdline in files/wic/oe5xrx-grub.cfg.
SRC_URI:append = " file://oe5xrx-pstore.cfg"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -m unit -q`
Expected: PASS (3 tests: fragment + 2 bbappends).

- [ ] **Step 7: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-kernel/linux/files/oe5xrx-pstore.cfg \
        meta-oe5xrx-remotestation/recipes-kernel/linux/linux-raspberrypi_%.bbappend \
        meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend \
        tests/ota-integration/test_observability_static.py
git commit -m "feat(kernel): pstore/ramoops config fragment for both kernels"
```

---

### Task 2: ramoops cmdline in both bootloaders

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd` (the `setenv bootargs` line)
- Modify: `meta-oe5xrx-remotestation/files/wic/oe5xrx-grub.cfg` (the `linux` line)
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/grub-ab/files/grub.cfg` (the `linux` line — reference parity)
- Test: `tests/ota-integration/test_observability_static.py` (extend)

**Interfaces:**
- Consumes: the `oops` region name must match `ramoops.mem_name=oops` (string constant, not a cross-task symbol).
- Produces: nothing downstream depends on this at the code level.

- [ ] **Step 1: Write the failing test** — append to `test_observability_static.py`:

```python
# ---- Task 2: ramoops cmdline in both bootloaders ------------------------

_RAMOOPS_TOKENS = [
    "reserve_mem=2M:4096:oops",
    "ramoops.mem_name=oops",
    "ramoops.ecc=1",
    "ramoops.record_size=0x40000",
    "ramoops.console_size=0x40000",
    "ramoops.pmsg_size=0x40000",
]

_BOOTLOADERS = [
    ("meta-oe5xrx-remotestation", "recipes-bsp", "u-boot-ab", "files", "boot.cmd"),
    ("meta-oe5xrx-remotestation", "files", "wic", "oe5xrx-grub.cfg"),
    ("meta-oe5xrx-remotestation", "recipes-bsp", "grub-ab", "files", "grub.cfg"),
]


@pytest.mark.parametrize("path", _BOOTLOADERS, ids=lambda p: p[-1] + ":" + p[-2])
def test_ramoops_cmdline_present_in_every_bootloader(path):
    txt = _read(*path)
    for tok in _RAMOOPS_TOKENS:
        assert tok in txt, f"{'/'.join(path)} missing ramoops token {tok!r}"
```

Note: the two `grub.cfg` files share a basename, so the `ids` lambda includes the parent dir to keep test IDs unique.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k ramoops -q`
Expected: FAIL — tokens absent from all three bootloaders.

- [ ] **Step 3: Add tokens to the RPi `boot.cmd`**

In `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd`, the `setenv bootargs` line currently ends:
`... panic=5 softlockup_panic=1 console=tty1 console=serial0,115200"`
Insert the ramoops tokens right after `softlockup_panic=1` (keep the console args last):

```
    setenv bootargs "root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000 console=tty1 console=serial0,115200"
```

- [ ] **Step 4: Add tokens to the live qemu `oe5xrx-grub.cfg`**

In `meta-oe5xrx-remotestation/files/wic/oe5xrx-grub.cfg`, the `linux` line currently ends:
`... panic=5 softlockup_panic=1 console=tty0 console=ttyS0,115200`
Insert the same tokens after `softlockup_panic=1`:

```
    linux /boot/bzImage root=PARTLABEL=${root_label} ro rootwait fsck.repair=yes net.ifnames=0 panic=5 softlockup_panic=1 reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000 console=tty0 console=ttyS0,115200
```

- [ ] **Step 5: Add tokens to the reference `grub-ab/files/grub.cfg` (parity)**

In `meta-oe5xrx-remotestation/recipes-bsp/grub-ab/files/grub.cfg`, the `linux` line (around line 74) currently ends `... console=tty0 console=ttyS0,115200 net.ifnames=0`. Insert the ramoops tokens before `net.ifnames=0`:

```
linux /bzImage root=PARTLABEL=${root_label} ro rootwait reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000 console=tty0 console=ttyS0,115200 net.ifnames=0
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k ramoops -q`
Expected: PASS (3 parametrized cases).

- [ ] **Step 7: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd \
        meta-oe5xrx-remotestation/files/wic/oe5xrx-grub.cfg \
        meta-oe5xrx-remotestation/recipes-bsp/grub-ab/files/grub.cfg \
        tests/ota-integration/test_observability_static.py
git commit -m "feat(boot): reserve ramoops RAM region on the kernel cmdline (both targets)"
```

---

### Task 3: Persistent journald + pstore-record retention

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-init.sh` (the `/var` subtree loop)
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/journald-persistent.conf`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/pstore.conf`
- Modify: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/oe5xrx-boot-robustness_1.0.bb`
- Test: `tests/ota-integration/test_observability_static.py` (extend)

**Interfaces:**
- Consumes: the existing `/var` bind mount (`var.mount` → `/mnt/data/var`) and `data-init.sh`'s `for d in … ; do mkdir -p "${DATA}/var/${d}"; done` loop.
- Produces: `/var/log/journal` on the persistent partition; `/etc/systemd/journald.conf.d/journald-persistent.conf`; `/etc/systemd/pstore.conf`.

- [ ] **Step 1: Write the failing test** — append to `test_observability_static.py`:

```python
# ---- Task 3: persistent journald + pstore retention --------------------

_BR = ("meta-oe5xrx-remotestation", "recipes-core", "oe5xrx-boot-robustness")


def test_data_init_seeds_journal_dir():
    sh = _read("meta-oe5xrx-remotestation", "recipes-core", "ab-layout",
               "files", "data-init.sh")
    # Must be an entry in the existing `for d in ... log/journal ...` loop,
    # not a separate fragile statement (set -eu runs before local-fs.target).
    assert "log/journal" in sh, "data-init.sh does not seed /var/log/journal"


def test_journald_dropin_is_persistent():
    conf = _read(*_BR, "files", "journald-persistent.conf")
    assert "[Journal]" in conf
    assert "Storage=persistent" in conf


def test_pstore_conf_keeps_records_for_consumer():
    conf = _read(*_BR, "files", "pstore.conf")
    assert "[PStore]" in conf
    assert "Unlink=no" in conf


def test_boot_robustness_recipe_ships_both_dropins():
    bb = _read(*_BR, "oe5xrx-boot-robustness_1.0.bb")
    for f in ("journald-persistent.conf", "pstore.conf"):
        assert f in bb, f"{f} not referenced in oe5xrx-boot-robustness_1.0.bb"
    # Installed to the right dirs.
    assert "journald.conf.d" in bb
    assert "${sysconfdir}/systemd/pstore.conf" in bb
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k "journal or pstore_conf or boot_robustness or data_init" -q`
Expected: FAIL — drop-in files missing, `log/journal` not in `data-init.sh`.

- [ ] **Step 3: Seed `/var/log/journal` in `data-init.sh`**

In `meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-init.sh`, change the `/var` subtree loop line from:

```sh
for d in log lib lib/systemd lib/dbus lib/station-agent lib/station-agent/downloads cache spool tmp local backups; do
```

to add `log/journal` right after `log`:

```sh
for d in log log/journal lib lib/systemd lib/dbus lib/station-agent lib/station-agent/downloads cache spool tmp local backups; do
```

Also add a short comment above the loop noting `log/journal` makes journald persistent (it is the dir whose existence journald needs even with `Storage=persistent`).

- [ ] **Step 4: Create the journald drop-in**

Create `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/journald-persistent.conf`:

```ini
# Persistent systemd journal so `journalctl --list-boots` / `-b -1` can show
# PRIOR boots — essential for diagnosing a spontaneous reboot. /var is bind-
# mounted onto the persistent data partition (ab-layout var.mount), and
# data-init.sh seeds /var/log/journal, so journald persists there and survives
# reboots. Size caps keep the journal from filling a small data partition.
[Journal]
Storage=persistent
SystemMaxUse=64M
RuntimeMaxUse=16M
```

- [ ] **Step 5: Create the pstore drop-in**

Create `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/files/pstore.conf`:

```ini
# Keep kernel-crash records in /sys/fs/pstore for the station-agent telemetry
# consumer to read and delete. systemd-pstore defaults to Unlink=yes, which
# moves records into /var/lib/systemd/pstore and removes them from
# /sys/fs/pstore — hiding fresh crashes from the agent. Unlink=no archives to
# /var (bonus) AND leaves the record in /sys/fs/pstore. See
# contract/station-telemetry-interface §1.
[PStore]
Unlink=no
```

- [ ] **Step 6: Install both drop-ins from the recipe**

In `meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/oe5xrx-boot-robustness_1.0.bb`:

Update `SRC_URI` to add the two files:
```
SRC_URI = "file://50-oe5xrx-panic.conf \
           file://watchdog.conf \
           file://journald-persistent.conf \
           file://pstore.conf \
"
```

Add to `do_install()` (after the existing installs):
```
    install -d ${D}${sysconfdir}/systemd/journald.conf.d
    install -m 0644 ${UNPACKDIR}/journald-persistent.conf ${D}${sysconfdir}/systemd/journald.conf.d/

    install -m 0644 ${UNPACKDIR}/pstore.conf ${D}${sysconfdir}/systemd/pstore.conf
```

Update `FILES:${PN}` to list them:
```
FILES:${PN} = "${sysconfdir}/sysctl.d/50-oe5xrx-panic.conf \
               ${sysconfdir}/systemd/system.conf.d/watchdog.conf \
               ${sysconfdir}/systemd/journald.conf.d/journald-persistent.conf \
               ${sysconfdir}/systemd/pstore.conf \
"
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k "journal or pstore_conf or boot_robustness or data_init" -q`
Expected: PASS.

- [ ] **Step 8: Verify `data-init.sh` still shellcheck-clean**

Run: `shellcheck -e SC1091 -e SC2039 meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-init.sh`
Expected: no output (clean), matching the `validate` CI job.

- [ ] **Step 9: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-init.sh \
        meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/ \
        tests/ota-integration/test_observability_static.py
git commit -m "feat(journald): persistent journal with boot separation + keep pstore records"
```

---

### Task 4: `mmc-utils` in the base image

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb` (base `IMAGE_INSTALL`)
- Test: `tests/ota-integration/test_observability_static.py` (extend)

**Interfaces:**
- Consumes: the base `IMAGE_INSTALL = " … "` block.
- Produces: `mmc` binary in the image (both machines).

- [ ] **Step 1: Write the failing test** — append to `test_observability_static.py`:

```python
# ---- Task 4: mmc-utils in base image -----------------------------------

_IMAGE = ("meta-oe5xrx-remotestation", "recipes-core", "images",
          "oe5xrx-remotestation-image.bb")


def test_mmc_utils_in_base_image():
    bb = _read(*_IMAGE)
    assert "mmc-utils" in bb, "mmc-utils not installed in the image"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k mmc -q`
Expected: FAIL.

- [ ] **Step 3: Add `mmc-utils` to the base `IMAGE_INSTALL`**

In `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`, add a line to the base `IMAGE_INSTALL = " … "` block (after `i2c-tools`):

```
    mmc-utils \
```

Add a brief comment: `mmc-utils` provides the `mmc` binary for eMMC/SD health reads (`mmc extcsd read`) used by the station telemetry feature; harmless on qemu (virtio root).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k mmc -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb \
        tests/ota-integration/test_observability_static.py
git commit -m "feat(image): add mmc-utils for eMMC/SD health tooling"
```

---

### Task 5: `vcgencmd` + rpi-only throttle-log timer

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/oe5xrx-throttle-log_1.0.bb`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/throttle-log.sh`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/oe5xrx-throttle-log.service`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/oe5xrx-throttle-log.timer`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb` (rpi-only installs)
- Modify: `.github/workflows/pr.yml` (path trigger for the new recipe dir)
- Test: `tests/ota-integration/test_observability_static.py` (extend)

**Interfaces:**
- Consumes: `vcgencmd` (from the meta-raspberrypi `userland` package) on `PATH` at runtime.
- Produces: the `oe5xrx-throttle-log.timer` + `.service` units and `/usr/sbin/throttle-log.sh`, installed on rpi only.

- [ ] **Step 1: Write the failing test** — append to `test_observability_static.py`:

```python
# ---- Task 5: vcgencmd + throttle-log (rpi-only) ------------------------

_TL = ("meta-oe5xrx-remotestation", "recipes-core", "oe5xrx-throttle-log")


def test_image_installs_vcgencmd_and_throttle_log_rpi_only():
    bb = _read(*_IMAGE)
    # Both must be appended under the raspberrypi4-64 override, never the base
    # IMAGE_INSTALL (qemu must stay a no-op).
    assert "IMAGE_INSTALL:append:raspberrypi4-64" in bb
    rpi_lines = [ln for ln in bb.splitlines()
                 if "IMAGE_INSTALL:append:raspberrypi4-64" in ln]
    joined = "\n".join(rpi_lines)
    assert "userland" in joined, "userland (vcgencmd) not installed on rpi"
    assert "oe5xrx-throttle-log" in joined, "throttle-log not installed on rpi"
    # Guard: neither leaks into the base IMAGE_INSTALL block.
    base = bb.split("IMAGE_INSTALL:append")[0]
    assert "userland" not in base
    assert "oe5xrx-throttle-log" not in base


def test_throttle_log_script_exits_zero_without_vcgencmd():
    sh = _read(*_TL, "files", "throttle-log.sh")
    # The script must not hard-fail when vcgencmd is absent (timer must never
    # enter `failed`): it checks command -v and exits 0.
    assert "command -v vcgencmd" in sh
    assert "exit 0" in sh


def test_throttle_log_timer_and_service_present():
    svc = _read(*_TL, "files", "oe5xrx-throttle-log.service")
    assert "Type=oneshot" in svc
    tmr = _read(*_TL, "files", "oe5xrx-throttle-log.timer")
    assert "[Timer]" in tmr and "OnUnitActiveSec" in tmr


def test_pr_workflow_triggers_on_throttle_log():
    pr = _read(".github", "workflows", "pr.yml")
    assert "oe5xrx-throttle-log/**" in pr
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tests/ota-integration && python -m pytest test_observability_static.py -k "throttle or vcgencmd or pr_workflow" -q`
Expected: FAIL — recipe/files/workflow entries missing.

- [ ] **Step 3: Create the throttle-log script**

Create `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/throttle-log.sh`:

```sh
#!/bin/sh
# Log the Raspberry Pi throttle/undervoltage state to the (persistent) journal.
# Runs as a oneshot driven by oe5xrx-throttle-log.timer. Writing it into the
# journal gives an undervoltage HISTORY that survives a spontaneous reboot,
# complementing the station-agent reading vcgencmd live.
#
# Must never fail the unit (a failed oneshot shows systemd `degraded`): if
# vcgencmd is missing (non-rpi) or errors, log once and exit 0.
set -u

if ! command -v vcgencmd >/dev/null 2>&1; then
    echo "throttle-log: vcgencmd not available — skipping (non-rpi?)"
    exit 0
fi

raw=$(vcgencmd get_throttled 2>/dev/null) || {
    echo "throttle-log: vcgencmd get_throttled failed — skipping"
    exit 0
}

# raw looks like: throttled=0x50005
hex=${raw#*=}
echo "throttle-log: ${raw}"

# Decode the documented bits (0x1 undervolt now, 0x2 freq-capped now,
# 0x4 throttled now, 0x8 soft-temp-limit now; 0x10000.. = "has occurred").
val=$((hex))
[ $(( val & 0x1 )) -ne 0 ]     && echo "throttle-log:   under-voltage detected (now)"
[ $(( val & 0x2 )) -ne 0 ]     && echo "throttle-log:   arm frequency capped (now)"
[ $(( val & 0x4 )) -ne 0 ]     && echo "throttle-log:   currently throttled (now)"
[ $(( val & 0x8 )) -ne 0 ]     && echo "throttle-log:   soft temperature limit active (now)"
[ $(( val & 0x10000 )) -ne 0 ] && echo "throttle-log:   under-voltage has occurred since boot"
[ $(( val & 0x20000 )) -ne 0 ] && echo "throttle-log:   arm frequency capping has occurred"
[ $(( val & 0x40000 )) -ne 0 ] && echo "throttle-log:   throttling has occurred since boot"
[ $(( val & 0x80000 )) -ne 0 ] && echo "throttle-log:   soft temperature limit has occurred"

exit 0
```

Note: `set -u` only (no `-e`) so a non-zero `[ … ]` test in the decode block cannot abort the script before `exit 0`.

- [ ] **Step 4: Create the service unit**

Create `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/oe5xrx-throttle-log.service`:

```ini
[Unit]
Description=Log RPi throttle/undervoltage state to the journal
# No hard dep on anything — the script self-guards when vcgencmd is absent.

[Service]
Type=oneshot
ExecStart=/usr/sbin/throttle-log.sh
```

- [ ] **Step 5: Create the timer unit**

Create `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/oe5xrx-throttle-log.timer`:

```ini
[Unit]
Description=Periodic RPi throttle/undervoltage logging

[Timer]
# First run shortly after boot, then every 5 minutes. Persistent=false: we want
# live samples, not a catch-up burst after downtime.
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

- [ ] **Step 6: Create the recipe**

Create `meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/oe5xrx-throttle-log_1.0.bb`:

```
SUMMARY = "OE5XRX RPi throttle/undervoltage logger (oneshot + timer)"
DESCRIPTION = "Periodically logs `vcgencmd get_throttled` to the journal so \
undervoltage/throttle history survives a spontaneous reboot. RPi-only; the \
script self-guards (exit 0) when vcgencmd is absent."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://throttle-log.sh \
    file://oe5xrx-throttle-log.service \
    file://oe5xrx-throttle-log.timer \
"

S = "${UNPACKDIR}"

inherit systemd allarch

# vcgencmd lives in meta-raspberrypi's userland package.
RDEPENDS:${PN} += "userland"

SYSTEMD_SERVICE:${PN} = "oe5xrx-throttle-log.timer"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/throttle-log.sh ${D}${sbindir}/throttle-log.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/oe5xrx-throttle-log.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/oe5xrx-throttle-log.timer   ${D}${systemd_system_unitdir}/
}

FILES:${PN} = " \
    ${sbindir}/throttle-log.sh \
    ${systemd_system_unitdir}/oe5xrx-throttle-log.service \
    ${systemd_system_unitdir}/oe5xrx-throttle-log.timer \
"
```

- [ ] **Step 7: Install on rpi only**

In `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`, in the Raspberry Pi section (near the existing `IMAGE_INSTALL:append:raspberrypi4-64 = " u-boot-ab u-boot-fw-utils"`), add:

```
# Undervoltage/throttle visibility (debug-observability): vcgencmd (userland)
# + a oneshot+timer that logs get_throttled to the persistent journal. RPi-only
# — the qemu image has no VideoCore firmware, so this stays a genuine no-op there.
IMAGE_INSTALL:append:raspberrypi4-64 = " userland oe5xrx-throttle-log"
```

- [ ] **Step 8: Add the pr.yml path trigger**

In `.github/workflows/pr.yml`, in the `paths:` list under the "image-affecting layer content" comment, add (keeping alphabetical-ish grouping with the other `recipes-core/**` entries):

```
      - 'meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/**'
```

- [ ] **Step 9: Run tests + shellcheck + yamllint**

```bash
cd tests/ota-integration && python -m pytest test_observability_static.py -k "throttle or vcgencmd or pr_workflow" -q
```
Expected: PASS.

```bash
cd "$(git rev-parse --show-toplevel)"
shellcheck -e SC1091 -e SC2039 meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/files/throttle-log.sh
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable, comments-indentation: disable, indentation: {check-multi-line-strings: false}}}" .github/workflows/
```
Expected: both clean (matches the `validate` CI job).

- [ ] **Step 10: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/oe5xrx-throttle-log/ \
        meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb \
        .github/workflows/pr.yml \
        tests/ota-integration/test_observability_static.py
git commit -m "feat(rpi): vcgencmd + throttle/undervoltage logging timer"
```

---

### Task 6: Operations documentation

**Files:**
- Create: `docs/operations/debug-observability.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Write the doc**

Create `docs/operations/debug-observability.md` covering, concisely:
- What each source is and where it surfaces: `/sys/fs/pstore` (crash capture), `journalctl --list-boots` / `-b -1` (persistent journal), `vcgencmd get_throttled` + the `oe5xrx-throttle-log` timer (undervoltage), `mmc extcsd read` (eMMC health).
- How to verify on-target (commands): `cat /sys/fs/pstore/* 2>/dev/null`, `journalctl --list-boots`, `systemctl status oe5xrx-throttle-log.timer`, `mmc extcsd read /dev/mmcblk0 | grep -i life`.
- Platform matrix: what works on CM4 vs qemu (ramoops cross-reboot capture = CM4; qemu boots + `/sys/fs/pstore` mounts; throttle-log = CM4 only).
- The **needs-HW** caveats: ramoops region placement/retention and `vcgencmd` output are only verifiable on a real CM4; the `reserve_mem` fallback (config.txt DT overlay) if HW shows instability.
- The epoch/no-RTC note: early per-boot timestamps are wrong until NTP syncs, but boots are still separated by `boot_id`.
- A pointer to `contract/station-telemetry-interface` and the spec.

- [ ] **Step 2: Commit**

```bash
git add docs/operations/debug-observability.md
git commit -m "docs(ops): debug-observability sources + on-target verification"
```

---

### Task 7: qemu boot-gate assertion

**Files:**
- Create: `tests/ota-integration/test_observability.py`

**Interfaces:**
- Consumes: the `qemu_target`, `dummy_factory`, `built_wic`, `expected_tag` fixtures (conftest.py) and `QemuTarget.power_on()` pexpect console + `boot_markers()`.
- Produces: nothing downstream.

- [ ] **Step 1: Write the test**

Create `tests/ota-integration/test_observability.py`:

```python
"""T-obs — debug-observability on-target smoke: the built qemu image boots to
login AND exposes the OS enablement (pstore mounted, persistent journal). Guards
the ramoops cmdline / kernel config / journald changes against boot regressions.
"""

import pytest

import seed

pytestmark = pytest.mark.qemu


def test_observability_sources_present(qemu_target, dummy_factory, built_wic,
                                       expected_tag):
    dummy = dummy_factory(target_tag=expected_tag, offer_update=False)

    qemu_target.flash(built_wic)
    qemu_target.reset_ab_state()

    url = qemu_target.dut_server_url(dummy.port)
    key_pem = qemu_target.work_dir + "/device_key.pem"
    seed.gen_ed25519_key(key_pem)
    qemu_target.seed_config(seed.render_config_yaml(url), key_pem)

    con = qemu_target.power_on()
    markers = qemu_target.boot_markers()

    # Boot must still reach login — the ramoops cmdline must not break boot.
    con.expect(markers["banner_re"], timeout=900)
    con.expect(markers["login_re"], timeout=180)

    # Log in on the serial console (dev image allows empty-password root).
    con.sendline("root")
    con.expect(r"[#$] ", timeout=60)

    # pstore filesystem is mounted (systemd mount-setup) once CONFIG_PSTORE=y —
    # proves the kernel fragment + reserve_mem wiring took effect on x86.
    con.sendline("mountpoint -q /sys/fs/pstore && echo PSTORE_OK || echo PSTORE_NO")
    con.expect(r"PSTORE_(OK|NO)", timeout=30)
    assert con.match.group(0) == "PSTORE_OK", "/sys/fs/pstore is not mounted"

    # Persistent journal active → --list-boots works and reports the storage.
    con.sendline("journalctl --list-boots >/dev/null 2>&1 && echo BOOTS_OK || echo BOOTS_NO")
    con.expect(r"BOOTS_(OK|NO)", timeout=30)
    assert con.match.group(0) == "BOOTS_OK", "journalctl --list-boots failed"
```

- [ ] **Step 2: Run the unit suite to confirm no accidental `-m unit` capture**

Run: `cd tests/ota-integration && python -m pytest -m unit -q`
Expected: PASS and this file is NOT collected (it is `-m qemu`). The qemu test itself runs in the PR build job on Hetzner (it `skip`s locally without `OTA_IT_WIC`).

- [ ] **Step 3: Commit**

```bash
git add tests/ota-integration/test_observability.py
git commit -m "test(qemu): assert pstore mounted + persistent journal on boot"
```

---

## Post-implementation (handled by subagent-driven-development, not a plan task)

- Open the PR against `main`; let the PR build + boot gate run.
- Fix-forward any Hetzner build surprises (most likely: `userland` needing a
  `LICENSE_FLAGS_ACCEPTED` entry in `raspberrypi4-64.yml` — add it if the build
  errors on a commercial-license flag; the rpi image is not boot-tested in CI,
  so this won't surface in the qemu gate).
- Request `copilot-pull-request-reviewer[bot]`; run copilot-loop to 0 (defer
  pure doc-nits after ~2 rounds).
- Report `done` to the coordinator with PR#, CI status, Copilot result, diff
  summary, and the explicit **needs-HW** list.
