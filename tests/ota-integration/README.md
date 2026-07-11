# Boot & OTA integration test

Boots the OE5XRX image in QEMU and drives the **real** `station-agent` through a
full cross-build A/B OTA cycle against a standalone dummy OTA server. It would
have caught both shipped OTA bugs (#36 fs-label, #37 ESP-by-UUID). Design +
rationale: `docs/superpowers/specs/2026-07-11-boot-ota-integration-test-design.md`.

## Layout

| File | Purpose |
|---|---|
| `dummy_server.py` | Stdlib HTTP server mirroring the agent's real protocol; records every interaction. |
| `target.py` | `Target` interface + `QemuTarget` (now) + `Cm4Target` stub (future bench). |
| `image_ops.py` | Rootfs extraction (root_a → bz2 + sha256), decompress, checksum. |
| `seed.py` | Config render + Ed25519 keygen + data-partition preseed. |
| `test_dummy_server.py`, `test_image_ops.py`, `test_target.py`, `test_l0a_lint.py`, `test_compute_version.py` | **unit** tests (no QEMU/root). |
| `test_boot.py` (T1), `test_ota_cycle.py` (T2), `test_rollback.py` (T3, skipped) | **qemu** tests. |

## Running

```bash
pip install -r tests/ota-integration/requirements.txt

# fast, local, no root:
python -m pytest tests/ota-integration -m unit

# full boot/OTA (needs qemu-system-x86_64 + ovmf + root for loop-mount):
export OTA_IT_WIC=/path/to/build-under-test.wic.bz2
export OTA_IT_EXPECTED_TAG=2026.07.11-15
export OTA_IT_LAST_RELEASE_WIC=/path/to/previous-release.wic.bz2   # T2 only
sudo -E env "PATH=$PATH" python -m pytest tests/ota-integration -m qemu -v
```

`T2` requires `OTA_IT_LAST_RELEASE_WIC` (slot A) to be a **different build** than
`OTA_IT_WIC` (slot B) — same-build A/B coincidentally matches ESP UUIDs and hides
#37. Without `OTA_IT_LAST_RELEASE_WIC`, T2 skips and only T1 runs.

## CI cadence

- **Every PR:** L0a static UUID-mount lint + the `unit` tests (`ci.yml`, seconds).
- **Boot-critical PRs** (`boot-ota-pr.yml`, path-filtered): build x86 + **T1**.
- **Release** (`release.yml`, `workflow_dispatch`): build both + **T1+T2 gate** →
  publish only if green. Version is computed server-side.

## Runner (no KVM → TCG)

`boot-ota-test.yml` takes a `runner_label` input, default GH-hosted
`ubuntu-latest` (TCG). Run **`boot-ota-spike.yml`** (`workflow_dispatch`) to
measure a TCG boot's wall-clock + RAM + disk on GH-hosted. If it's too slow /
disk-tight, set `runner_label` to a self-hosted Hetzner label (still TCG, just
more cores). Both GH-hosted and Hetzner Cloud lack nested virt — true KVM would
need bare metal.

## Verifying the test itself

A test that can't catch the known bug is worthless. On a throwaway branch (never
main):

- Revert #37 (re-add `--use-uuid`, drop `--no-fstab-update` in the x64 wks) →
  **L0a red**, **L0b red** (build), **T2 red** (emergency mode / rollback).
- Revert #36 (skip the slot relabel in the agent) → **T2 red** (slot B
  unbootable → rollback to the old tag).

Revert both back out; the suite goes green.

## CM4 (future)

`Cm4Target` is a stub. The physical bench (rpiboot/SD-mux flash, UART console,
controllable power) is future work — see the spec's "CM4 HIL bench" section. It
closes the RPi release-gate gap and covers the u-boot path + real hardware.
