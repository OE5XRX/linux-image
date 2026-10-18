# Module-firmware flash — image ↔ station_agent contract

The station_agent (`module_ota`) flashes FM-module firmware. This image provides
the OS side of that; this file is the interface the agent codes against. Two
backends, one per deployment:

| | Real HW (raspberrypi4-64) | Sim (qemux86-64 / Proxmox) |
|---|---|---|
| Artifact | `<asset>.bin` (DFU payload) | `<asset>.native_sim` (host ELF) |
| Mechanism | `dfu-util -p <port>` | swap the native_sim binary + restart the harness |
| Image provides | `dfu-util`, `/etc/oe5xrx/slots.conf` | `/var/lib/oe5xrx/sim/`, harness override |

## Real HW: slot → USB port

The BusBoard FE1.1s hub ports are fixed-wired: hub port N = slot N. The mapping is
single-sourced in **`/etc/oe5xrx/slots.conf`** (shipped by `oe5xrx-slot-udev`):

    slot1=1-1.1
    slot2=1-1.2
    slot3=1-1.3
    slot4=1-1.4

One `slot<N>=<usb-port-path>` per line; `#` comments and blank lines are ignored.
The agent addresses the module in a slot with `dfu-util -p <port>` — by port path,
never by serial (two identical modules differ only in where they sit), and it works
while the module sits in its DFU bootloader, when there is no `ttyACM` and hence no
`/dev/oe5xrx/slotN/control` to derive the port from.

The udev rules (`90-oe5xrx-slots.rules`) hardcode the same mapping; CI
(`tests/ota-integration/test_module_flash_static.py`) fails if the two drift.

## Sim: native_sim override

`sim-harness.sh` (`oe5xrx-sim-harness.service`) picks its binary on every start:

1. `/var/lib/oe5xrx/sim/native-sim-fm` — if it is a regular file (not a symlink),
   executable, owned by root and not group/world-writable (otherwise it is ignored
   with a log line);
2. otherwise the image-baked `/usr/libexec/oe5xrx/native-sim-fm`.

It logs the choice (`sim-harness: using native_sim <path>`). `/var` is the
persistent data partition, so a flashed sim binary survives reboots **and** OTA.
`data-init` creates `/var/lib/oe5xrx/sim/` and re-asserts `root:root 0755` on
every boot — the harness runs whatever lands there as root, so only root may write
it. The agent runs as root.

### Agent flash procedure (contract)

    D=/var/lib/oe5xrx/sim
    1. write + verify the new binary to   $D/native-sim-fm.new   (same dir => same fs)
       chown root:root; chmod 0755
    2. if $D/native-sim-fm exists:        mv -f $D/native-sim-fm $D/native-sim-fm.prev
       else:                              rm -f $D/native-sim-fm.prev
    3. mark the flash in flight:          touch $D/pending   (fsync the dir)
    4. atomic install:                    mv -f $D/native-sim-fm.new $D/native-sim-fm   (rename(2))
    5. systemctl restart oe5xrx-sim-harness
    6. health check over /dev/oe5xrx/slot1/control (describe → expected version)
    7. health OK:                         rm -f $D/pending

Step 2's `else` matters: a `.prev` left over from an earlier flash (e.g. before a
factory reset) must never become the rollback target of a flash that replaced the
image binary.

Rollback (health check failed, **or** the agent finds `$D/pending` on startup — it
crashed / the station rebooted between steps 3 and 7, so the live override was never
verified):

- `.prev` exists → `mv -f $D/native-sim-fm.prev $D/native-sim-fm`, restart.
- no `.prev` (the flash replaced the image binary) → `rm -f $D/native-sim-fm`,
  restart — the harness falls back to the image binary.
- then `rm -f $D/pending` and report the flash as rolled back.

"Factory reset" to the image-baked firmware: `rm -f $D/native-sim-fm
$D/native-sim-fm.prev $D/pending`, restart.

Limitation: only `native-sim-fm` is overridable. The SA818 AT-emulator
(`/usr/libexec/oe5xrx/sa818-sim.py`) stays the image-baked one from the pinned FW
release, so a flashed native_sim runs against that emulator. Fine as long as the
SA818 AT link protocol is unchanged between FW releases; if a FW release changes it,
the image must be bumped (`bump-fw-release.sh`) rather than sim-flashed.

Between steps 2 and 4 there is briefly no override; a harness (re)start in that
window runs the image binary — harmless, step 5 restarts onto the new one.

## Firmware release pin

The image-baked artifacts (`/lib/firmware/oe5xrx/<asset>.bin`, the native_sim and the
SA818 emulator) come from the one FW-RemoteStation release pinned in
`meta-oe5xrx-remotestation/conf/oe5xrx-fw-release.inc` (`FW_RELEASE_TAG`). The asset
basename is `FW_FM_ASSET` in the same file: `fm-sa818-2m` up to and including FW
release 26.07.25-01, `fm-sa818-vhf` for releases cut after FW #66.
`scripts/bump-fw-release.sh <tag>` detects which the release carries and rewrites both
lines, so the rename takes no recipe edit.
