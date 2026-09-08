# Robust A/B U-Boot Env + Larger Symmetric Slots + data-grow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make u-boot actually use its redundant environment (so OTA trial-boot arming/commit works on the CM4), enlarge the A/B rootfs slots to 2.5 GB symmetrically (rpi + x64), and implement the missing `data-grow` so one image fits both 8 GB eMMC and large SD.

**Architecture:** Fix the u-boot Kconfig fragment so `CONFIG_SYS_REDUNDAND_ENVIRONMENT=y` lands in the built `.config`, backed by a build-time guard that fails the build if it ever regresses. Bump `root_a`/`root_b` to `--fixed-size 2560` in both wks files and shrink build-time `data` to `512` so it flashes onto the smallest 8 GB eMMC; a new sentinel-guarded `data-grow.service` then grows `data` to fill the device on first boot. Rollout is a one-time reflash (bigger slots can't be OTA'd in); redundant env self-initializes on first boot.

**Tech Stack:** Yocto (kas-based, `oe5xrx.yml` + lockfiles), U-Boot 2026.01 (`meta-oe5xrx-remotestation/recipes-bsp/u-boot`), systemd, `parted`/`sgdisk`/`resize2fs`, pytest OTA-integration harness (`tests/ota-integration`, qemux86-64).

**Spec:** `docs/superpowers/specs/2026-09-08-robust-ab-env-larger-slots-design.md`

## Global Constraints

- Versions: use current stable; never pin `station-agent` with `AUTOREV` (CI preflight rejects it).
- U-Boot env offsets are absolute and MUST stay in lockstep with the wks: `CONFIG_ENV_OFFSET=0x4005000`, `CONFIG_ENV_OFFSET_REDUND=0x4105000`. Do NOT change `firmware`/`uboot_env`/`uboot_envr`/`efi` partitions — only `root_a`/`root_b`/`data`.
- `fw_env.config` stays two-line / redundant (`meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/fw_env.config`) — it was correct; do not touch it.
- Symmetric: every size change to the rpi wks is mirrored in the x64 wks and vice versa.
- Build via `just local build <machine> [--dev]` (local, sstate from R2 mirror) or `bash scripts/ydev/remote-build.sh <machine> [--both]` (Hetzner). Boot/OTA tests run on `qemux86-64` only (`scripts/run-qemu.sh`, `tests/ota-integration`). The rpi/u-boot redundant path is verified by the build guard + HIL on real CM4.
- HIL honesty rule: the u-boot redundant env + OTA cycle is only "done" when green on a real CM4, not just sim.
- Commits: Conventional Commits; end every commit message with the `Co-Authored-By` trailer per repo convention. All work on branch `feat/robust-ab-env-larger-slots`; one PR at the end.

## File Structure

- Modify `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend` — add `do_configure:append` build guard.
- Modify `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg` — make redundant symbols land.
- Modify `meta-oe5xrx-remotestation/files/wic/oe5xrx-remotestation-ab.wks.in` — rpi slots.
- Modify `meta-oe5xrx-remotestation/files/wic/oe5xrx-remotestation-ab-x64.wks.in` — x64 slots.
- Create `meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-grow.sh` — grow logic.
- Create `meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-grow.service` — systemd unit.
- Modify `meta-oe5xrx-remotestation/recipes-core/ab-layout/ab-layout_1.0.bb` — install + enable + RDEPENDS.
- Modify `tests/ota-integration/test_ota_cycle.py` (+ helper) — assert commit clears trial flags and slot size is 2.5 GB.
- Create `docs/superpowers/…` handback + update versioning notes (Task 8).

---

### Task 1: Build-time redundant-env guard (the failing test)

Add the guard first so the current (broken) build fails loudly and proves the bug — then Task 2 makes it pass.

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend`

**Interfaces:**
- Produces: a `do_configure:append:raspberrypi4-64` task that aborts the build unless `${B}/.config` contains `CONFIG_SYS_REDUNDAND_ENVIRONMENT=y`.

- [ ] **Step 1: Add the guard to the bbappend**

Append to `meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend`:

```bash
# Guard: the redundant U-Boot environment MUST be compiled in. A Kconfig
# fragment can be silently dropped by merge_config when a dependency/choice
# is unmet — that regression previously made every CM4 OTA fail at
# fw_setenv trial-boot arming. Fail the build here instead of shipping a
# station that can't arm/commit an OTA. See docs/superpowers/specs/
# 2026-09-08-robust-ab-env-larger-slots-design.md.
do_configure:append:raspberrypi4-64() {
    if ! grep -q '^CONFIG_SYS_REDUNDAND_ENVIRONMENT=y' "${B}/.config"; then
        bbfatal "CONFIG_SYS_REDUNDAND_ENVIRONMENT not enabled in built .config — redundant env fragment did not land (see oe5xrx-env.cfg)."
    fi
    if ! grep -q '^CONFIG_ENV_OFFSET_REDUND=' "${B}/.config"; then
        bbfatal "CONFIG_ENV_OFFSET_REDUND missing in built .config — redundant env offset not set."
    fi
}
```

- [ ] **Step 2: Build u-boot and verify the guard FAILS on the current tree**

Run: `bash scripts/ydev/remote-build.sh raspberrypi4-64` (or `just local build raspberrypi4-64`)
Expected: build FAILS in u-boot `do_configure` with `bbfatal: CONFIG_SYS_REDUNDAND_ENVIRONMENT not enabled…`. This confirms the guard works and reproduces the root cause.

- [ ] **Step 3: Capture the built `.config` for diagnosis**

Run: `find build/tmp/work -path '*u-boot*/.config' -print -quit | xargs grep -E 'ENV_IS_IN|ENV_OFFSET|REDUND|ENV_IS_IN_FAT'`
Expected: shows `CONFIG_ENV_IS_IN_MMC=y` + `CONFIG_ENV_OFFSET=0x4005000` present, but `CONFIG_SYS_REDUNDAND_ENVIRONMENT` / `CONFIG_ENV_OFFSET_REDUND` absent (and note whether `CONFIG_ENV_IS_IN_FAT` is still set — the likely blocker). Record the finding in the commit message.

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot/u-boot_%.bbappend
git commit -m "build(u-boot): guard that redundant env is compiled in

Fails the build unless CONFIG_SYS_REDUNDAND_ENVIRONMENT=y and
CONFIG_ENV_OFFSET_REDUND are in the built .config. Currently RED —
reproduces the CM4 OTA-arming root cause; Task 2 makes it green.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Make the redundant symbols land (turn the guard green)

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg`

**Interfaces:**
- Consumes: the guard from Task 1 and the `.config` diagnosis from Task 1 Step 3.
- Produces: a u-boot build where `CONFIG_SYS_REDUNDAND_ENVIRONMENT=y` and `CONFIG_ENV_OFFSET_REDUND=0x4105000` are set.

- [ ] **Step 1: Apply the fix indicated by the diagnosis**

Edit `oe5xrx-env.cfg`. Keep the existing MMC settings and make the redundant ones survive `merge_config`. Most likely the env-location choice needs `ENV_IS_IN_FAT` explicitly off so the MMC/redundant branch is selected:

```
# CONFIG_ENV_IS_IN_FAT is not set
CONFIG_ENV_IS_IN_MMC=y
CONFIG_SYS_MMC_ENV_DEV=0
CONFIG_ENV_SIZE=0x10000
CONFIG_ENV_OFFSET=0x4005000
CONFIG_SYS_REDUNDAND_ENVIRONMENT=y
CONFIG_ENV_OFFSET_REDUND=0x4105000
```

If the diagnosis shows a different blocker (e.g. the symbol is gated behind `CONFIG_ENV_IS_NOWHERE` or a defconfig hard-set), adjust accordingly — explicitly negate the conflicting symbol(s) in this fragment. Do NOT switch to a full defconfig unless the fragment provably cannot carry the symbol (spec fallback).

- [ ] **Step 2: Rebuild — guard must now PASS**

Run: `bash scripts/ydev/remote-build.sh raspberrypi4-64`
Expected: u-boot `do_configure` passes the guard; full image build succeeds.

- [ ] **Step 3: Confirm in the built `.config`**

Run: `find build/tmp/work -path '*u-boot*/.config' -print -quit | xargs grep -E 'REDUND'`
Expected: `CONFIG_SYS_REDUNDAND_ENVIRONMENT=y` and `CONFIG_ENV_OFFSET_REDUND=0x4105000`.

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-bsp/u-boot/files/oe5xrx-env.cfg
git commit -m "fix(u-boot): actually enable redundant MMC environment

<one line naming the exact blocker found in Task 1 Step 3, e.g.
'ENV_IS_IN_FAT choice shadowed ENV_IS_IN_MMC; negate it explicitly'>.
Guard from previous commit now green.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Enlarge rpi rootfs slots

**Files:**
- Modify: `meta-oe5xrx-remotestation/files/wic/oe5xrx-remotestation-ab.wks.in`

**Interfaces:**
- Produces: rpi wic with `root_a`/`root_b` = 2560 MB, `data` = 512 MB (pre-grow).

- [ ] **Step 1: Edit the three root/data lines**

In `oe5xrx-remotestation-ab.wks.in`, change ONLY these (leave `firmware`, `uboot_env`, `uboot_envr` untouched):

```
part / --source rootfs --ondisk mmcblk0 --fstype=ext4 --label root_a --fixed-size 2560 --align 4
part --ondisk mmcblk0 --fstype=ext4 --label root_b --fixed-size 2560 --source empty --align 4
part --ondisk mmcblk0 --fstype=ext4 --label data --fixed-size 512 --align 4
```

Also update the layout comment block (`root_a (ext4, 2560 MB)`, `root_b (ext4, 2560 MB)`, `data (ext4, 512 MB — grows to fill device on first boot)`).

- [ ] **Step 2: Build the rpi image**

Run: `bash scripts/ydev/remote-build.sh raspberrypi4-64`
Expected: build succeeds; rootfs (≈460–600 MB) still fits the 2560 MB slot.

- [ ] **Step 3: Verify partition sizes in the produced wic**

Run: `wic="$(find build/tmp/deploy/images/raspberrypi4-64 -name '*.wic' -print -quit)"; sgdisk -p "$wic" 2>/dev/null || parted -s "$wic" unit MiB print`
Expected: `root_a` and `root_b` ≈ 2560 MiB each; `data` ≈ 512 MiB; env partitions unchanged at their original start sectors (0x4005000 / 0x4105000 region).

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/files/wic/oe5xrx-remotestation-ab.wks.in
git commit -m "feat(wic): grow rpi A/B rootfs slots to 2.5G, data pre-grow 512M

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Enlarge x64 rootfs slots + verify A/B OTA still works

**Files:**
- Modify: `meta-oe5xrx-remotestation/files/wic/oe5xrx-remotestation-ab-x64.wks.in`

**Interfaces:**
- Consumes: x64 wks layout (1=efi, 2=root_a, 3=root_b, 4=data).
- Produces: x64 wic with `root_a`/`root_b` = 2560 MB, `data` = 512 MB.

- [ ] **Step 1: Edit the three root/data lines (mirror Task 3)**

```
part / --source rootfs --ondisk vda --fstype=ext4 --label root_a --fixed-size 2560 --align 4
part --ondisk vda --fstype=ext4 --label root_b --fixed-size 2560 --align 4
part --ondisk vda --fstype=ext4 --label data --fixed-size 512 --align 4
```

Leave the `efi` partition untouched.

- [ ] **Step 2: Build + boot qemux86-64**

Run: `just local build qemux86-64 --dev && just local qemu --local --dev`
Expected: boots to login; `lsblk -b` inside the VM shows `root_a`/`root_b` ≈ 2684354560 bytes (2560 MiB).

- [ ] **Step 3: Run the OTA-cycle integration test (A/B still functions with bigger slots)**

Run: `cd tests/ota-integration && python -m pytest test_ota_cycle.py test_rollback.py -v`
Expected: PASS — agent downloads, writes the (now larger) inactive slot, reboots, and commits at the new tag; rollback test still rolls back.

- [ ] **Step 4: Commit**

```bash
git add meta-oe5xrx-remotestation/files/wic/oe5xrx-remotestation-ab-x64.wks.in
git commit -m "feat(wic): grow x64 A/B rootfs slots to 2.5G, data pre-grow 512M (symmetric)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Implement `data-grow` (script + unit + recipe wiring)

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-grow.sh`
- Create: `meta-oe5xrx-remotestation/recipes-core/ab-layout/files/data-grow.service`
- Modify: `meta-oe5xrx-remotestation/recipes-core/ab-layout/ab-layout_1.0.bb`

**Interfaces:**
- Consumes: `mnt-data.mount` (mounts `/mnt/data`), `data-init.service` (seeds layout), the `data` PARTLABEL.
- Produces: `/usr/sbin/data-grow.sh`, `data-grow.service` enabled via `SYSTEMD_SERVICE`; sentinel `/mnt/data/.data-grown`.

- [ ] **Step 1: Write `data-grow.sh`**

```sh
#!/bin/sh
# One-time first-boot grow of the persistent data partition to fill the
# device. Behind a sentinel; ROBUST-FAIL — a grow failure must never block
# boot (data-init already made /mnt/data usable at its built size).
#
# Device/partnum are derived from the `data` PARTLABEL so this works on both
# mmcblk0 (rpi, data=p6) and vda (x64, data=p4).
set -u

SENTINEL=/mnt/data/.data-grown
[ -f "$SENTINEL" ] && exit 0

DATA_DEV="$(readlink -f /dev/disk/by-partlabel/data)" || exit 0
BASE="$(basename "$DATA_DEV")"
DISK="/dev/$(lsblk -no PKNAME "$DATA_DEV" 2>/dev/null)"
PARTNUM="$(cat "/sys/class/block/${BASE}/partition" 2>/dev/null)"
[ -n "$DISK" ] && [ -n "$PARTNUM" ] || { echo "data-grow: could not resolve disk/partnum"; exit 0; }

# Move the GPT backup header to the end of the (now larger) device. On QEMU
# the backup header is often misplaced after flashing a small wic onto a big
# disk; `sgdisk -e` fixes it. timeout guards against a parted/sgdisk hang.
timeout 30 sgdisk -e "$DISK" || { echo "data-grow: sgdisk -e failed/timed out"; exit 0; }
partprobe "$DISK" 2>/dev/null || true

# Grow the last (data) partition to fill the disk, then grow the filesystem
# online (data is mounted at /mnt/data).
timeout 30 parted -s "$DISK" resizepart "$PARTNUM" 100% || { echo "data-grow: resizepart failed"; exit 0; }
partprobe "$DISK" 2>/dev/null || true
timeout 60 resize2fs "$DATA_DEV" || { echo "data-grow: resize2fs failed"; exit 0; }

touch "$SENTINEL"
echo "data-grow: grew $DATA_DEV to fill $DISK"
exit 0
```

- [ ] **Step 2: Write `data-grow.service`**

```ini
[Unit]
Description=Grow persistent data partition to fill device (one-time)
Requires=mnt-data.mount
After=mnt-data.mount data-init.service
Before=local-fs.target
DefaultDependencies=no
ConditionPathIsMountPoint=/mnt/data
ConditionPathExists=!/mnt/data/.data-grown

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
ExecStart=/usr/sbin/data-grow.sh

[Install]
WantedBy=local-fs.target
```

- [ ] **Step 3: Wire into `ab-layout_1.0.bb`**

Add `file://data-grow.sh` and `file://data-grow.service` to `SRC_URI`; add `data-grow.service` to `SYSTEMD_SERVICE:${PN}`; add `gptfdisk` (sgdisk) to `RDEPENDS:${PN}`; in `do_install()` add:

```bash
    install -m 0644 ${UNPACKDIR}/data-grow.service  ${D}${systemd_system_unitdir}/
    install -m 0755 ${UNPACKDIR}/data-grow.sh        ${D}${sbindir}/data-grow.sh
```

- [ ] **Step 4: Build + boot qemux86-64 on an oversized disk and verify grow**

Run: `just local build qemux86-64 --dev` then boot with a disk larger than the wic (the run-qemu harness uses the wic directly; resize a copy first):
```bash
wic="$(find build/tmp/deploy/images/qemux86-64 -name '*.rootfs.wic' -print -quit)"
cp "$wic" /tmp/grow-test.wic && qemu-img resize -f raw /tmp/grow-test.wic 8G
scripts/run-qemu.sh --local --dev   # or point the harness at /tmp/grow-test.wic
```
Inside the VM:
Run: `df -h /mnt/data; ls -l /mnt/data/.data-grown`
Expected: `/mnt/data` grew from ~512 MB toward ~the disk size; sentinel present. Reboot → `data-grow.service` shows `condition failed`/skipped (sentinel), boot still clean.

- [ ] **Step 5: Verify robust-fail**

Temporarily rename `sgdisk` in the VM (or point `DATA_DEV` at a bogus value) and reboot without the sentinel:
Run: `systemctl status data-grow.service; systemctl is-system-running`
Expected: service logs the failure and exits 0; boot completes (not `degraded` because of data-grow); `/mnt/data` still mounted at its built size.

- [ ] **Step 6: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/ab-layout/
git commit -m "feat(ab-layout): add data-grow.service to fill the device on first boot

Implements the data-grow.service the data-init.sh comment already
references. Sentinel-guarded, robust-fail, sgdisk -e for the QEMU
misplaced-backup-header case. Works on mmcblk0 and vda.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Extend OTA integration test — commit clears trial flags + slot size

**Files:**
- Modify: `tests/ota-integration/test_ota_cycle.py`
- Modify (if a helper is needed): `tests/ota-integration/image_ops.py`

**Interfaces:**
- Consumes: `image_ops.loop_attach`, `ROOT_A_PARTNUM`, the running dummy OTA server + target fixtures already used by `test_t2_cross_build_ota_boots_new_slot_and_commits`.
- Produces: two assertions — slot size ≈ 2560 MiB, and post-commit env has `upgrade_available=0`/`bootcount=0` on the qemux86-64 (GRUB) path.

- [ ] **Step 1: Add a slot-size assertion test**

```python
def test_root_slots_are_2560_mib(build_under_test_wic):
    """The A/B rootfs slots must be 2.5 GiB after the resize (spec §2)."""
    import image_ops
    with image_ops.loop_attach(build_under_test_wic) as dev:
        # x64 layout: p2=root_a, p3=root_b
        for partnum in (2, 3):
            size = _part_size_bytes(f"{dev}p{partnum}")
            assert size == 2560 * 1024 * 1024, f"slot p{partnum} is {size} bytes, expected 2560 MiB"
```

Add `_part_size_bytes` to `image_ops.py`:

```python
def _part_size_bytes(part_dev: str) -> int:
    with open(f"/sys/class/block/{os.path.basename(part_dev)}/size") as fh:
        return int(fh.read().strip()) * 512
```

- [ ] **Step 2: Assert the GRUB commit clears the trial flags**

Extend `test_t2_cross_build_ota_boots_new_slot_and_commits` after the commit assertion:

```python
    # After commit the trial flags must be cleared (else a reboot would roll back).
    env = target.read_grubenv()  # helper: reads grubenv on the booted VM
    assert env.get("upgrade_available") == "0", f"upgrade_available not cleared: {env}"
    assert env.get("bootcount") == "0", f"bootcount not cleared: {env}"
```

If `target.read_grubenv()` does not exist, add it to `target.py` running `grub-editenv <path> list` over the VM's serial/ssh channel the harness already uses.

- [ ] **Step 3: Run the tests**

Run: `cd tests/ota-integration && python -m pytest test_ota_cycle.py -v`
Expected: PASS (both the size test and the extended commit test).

- [ ] **Step 4: Commit**

```bash
git add tests/ota-integration/
git commit -m "test(ota): assert 2.5G slots and post-commit trial-flag clear

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: HIL validation on real CM4 (hardware gate)

Not automatable — the honesty rule requires the redundant env + OTA cycle be green on real CM4. Execute on station `192.168.88.211` (reflash it with the new image first). This task is a checklist; each box is a manual verification.

**Files:** none (validation only). Record results in the Task 8 handback doc.

- [ ] **Step 1: Flash the new rpi image to the CM4 eMMC and boot.**
  Verify: `. /etc/os-release` shows the new tag; `systemctl is-system-running` not degraded by anything OTA-related.
- [ ] **Step 2: Redundant env is live.**
  Run: `fw_printenv | grep -E 'boot_part|bootcount|upgrade_available'` (uses the shipped **two-line** `/etc/fw_env.config`).
  Expected: reads cleanly (no "Cannot read environment"); `dd if=$(readlink -f /dev/disk/by-partlabel/uboot_env) bs=5 count=1 | od -An -tx1` shows CRC(4) + a flags byte (redundant format).
- [ ] **Step 3: `data` filled the eMMC.**
  Run: `df -h /mnt/data` → grew well beyond 512 MB; `/mnt/data/.data-grown` present.
- [ ] **Step 4: Full OTA cycle from the server.**
  Queue a deployment to a newer tag. Expected: agent arms (`fw_setenv` succeeds — the original failure is gone), trial-boots the new slot, commits (`upgrade_available=0, bootcount=0`), server marks success.
- [ ] **Step 5: Rollback safety.**
  Force a failing trial (e.g. arm a deliberately-bad slot) and confirm u-boot rolls back after `bootlimit=3` to the known-good slot.
- [ ] **Step 6: Record outcomes** in the handback doc (Task 8). If any step fails, STOP and return to systematic debugging — do not mark the feature done.

---

### Task 8: Docs, rollout notes, and PR

**Files:**
- Create: `docs/superpowers/2026-09-08-robust-ab-env-larger-slots-handback.md`
- Modify: the versioning/hardware doc if it states slot sizes (search first).

- [ ] **Step 1: Write the handback**

Summarize: root cause (single vs redundant env CRC), the build guard, the 2.5 GB symmetric slots, data-grow, and the **operator action: every station must be reflashed once** (bigger slots can't be OTA'd; redundant env self-initializes on reflash). Paste the Task 7 HIL results.

- [ ] **Step 2: Update slot-size references in docs**

Run: `grep -rniE '1024 MB|1 ?GB|root_a|slot' docs/ | grep -i size`
Update any doc that states the old 1 GB slot size to 2.5 GB.

- [ ] **Step 3: Commit**

```bash
git add docs/
git commit -m "docs: handback + slot-size update for robust A/B env + 2.5G slots

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Open the PR**

```bash
git push -u origin feat/robust-ab-env-larger-slots
```
Open one PR to `main` covering spec + plan + all commits. Body: link the spec, list the four workstreams, call out the **one-time reflash** rollout and the CM4 HIL results. Run the Copilot-review loop per repo convention.

---

## Self-Review

**Spec coverage:**
- §1 redundant env → Tasks 1 (guard), 2 (fix). ✓
- §2 larger symmetric slots → Tasks 3 (rpi), 4 (x64). ✓
- §3 data-grow → Task 5. ✓
- §4 rollout / reflash → Task 7 (flash + HIL), Task 8 (operator note). ✓
- Testing (build guard, QEMU A/B, HIL) → Tasks 1/2 guard, 4 & 6 QEMU, 7 HIL. ✓
- Offsets unchanged invariant → enforced by "only edit root/data" in Tasks 3/4 + verified in Task 3 Step 3. ✓

**Placeholder scan:** Task 2 Step 1 intentionally branches on the Task 1 diagnosis (the exact Kconfig blocker is only knowable from the real build) — the spec flagged this as a spike; the concrete default fix (negate `ENV_IS_IN_FAT`) is given, with an explicit fallback rule. Not a placeholder. No TBD/TODO elsewhere.

**Type/name consistency:** `data-grow.sh` path `/usr/sbin/data-grow.sh`, unit `data-grow.service`, sentinel `/mnt/data/.data-grown`, PARTLABEL `data` — consistent across Task 5 and Task 7. `_part_size_bytes` / `ROOT_A_PARTNUM` / `loop_attach` match `image_ops.py`. Slot size `2560 MiB` consistent in Tasks 3/4/6.
