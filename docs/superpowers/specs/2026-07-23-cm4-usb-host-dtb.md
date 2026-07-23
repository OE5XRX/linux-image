# CM4 USB Host Enable (DTB) — Design

**Date:** 2026-07-23
**Status:** Approved (design), pending implementation plan
**Machine affected:** `raspberrypi4-64` (CM4). x86 (`qemux86-64`) untouched.
**Lands on:** branch `fix/cm4-ab-boot` (PR #44) as an additional commit — same
CM4-boot-correctness scope; makes a freshly flashed CM4 image usable end-to-end.

## Problem

On the deployed CM4 the USB host never comes up: `/sys/bus/usb/devices/` is
empty (no root hub at all), so no FE1.1s BusBoard hub and no FM-module CDC-ACM
enumerate. Consequently no `/dev/ttyACM*`, the `oe5xrx-slot-udev` rules create
no `/dev/oe5xrx/slot*/control` symlinks, and the station-agent's slot discovery
returns an empty inventory — the station reports **no modules** to
station-manager. (The absence of `lsusb` is unrelated: `usbutils` is
intentionally not in the image and the agent never uses it.)

### Root cause (traced end-to-end from the running card)

1. u-boot's `boot.cmd` `ext4load`s `/boot/broadcom/bcm2711-rpi-cm4.dtb` from the
   active `root_<slot>` and boots it **as-is** — it applies no device-tree
   overlays and does not read the firmware `config.txt`.
2. In that DTB the USB OTG node `/soc/usb@7e980000` ships
   `compatible = "brcm,bcm2708-usb"` (legacy RPi FIQ `dwc_otg` driver) with
   `status = "disabled"`. Live readout on the card confirmed exactly this:
   `compatible: brcm,bcm2708-usb`, `status: disabled`, and both
   `/sys/bus/usb/devices/` and `/sys/class/udc/` empty (controller in neither
   host nor device mode).
3. `RPI_EXTRA_CONFIG = "\notg_mode=1\n"` writes `otg_mode=1` into `config.txt`,
   but that only patches the **RPi firmware's** in-RAM DTB — which u-boot
   discards when it loads its own DTB from ext4. So `otg_mode=1` is inert on
   this u-boot boot path. It never reaches Linux.
4. Hardware aggravator (does not need fixing in SW, but explains the "neither
   host nor device" state if the node were merely enabled): on the
   `HW-Module-CM4Carrier` the CM4 OTG-ID pin is not a clean ground — it sits on
   a 2k2/2k2 divider (`R203` to GND, `R202` in series to the BusBoard `USB_ID`),
   so OTG auto-detect is ambiguous. Forcing host mode makes the ID pin
   irrelevant.

## Goals

1. Every built `raspberrypi4-64` image boots a DTB in which the CM4 USB 2.0
   controller is enabled and **hard-forced to host mode**, so the BusBoard hub
   and FM module enumerate and the agent reports modules.
2. Host mode is independent of the ambiguous carrier OTG-ID divider (bind the
   mainline `dwc2` driver with `dr_mode = "host"`, not OTG auto-detect).
3. No stale/misleading config: remove the inert `otg_mode=1` so no maintainer
   believes USB is configured via `config.txt`.

## Non-Goals (YAGNI)

- Any hardware change to the carrier OTG-ID divider (`R202`/`R203`). A real but
  separate concern for a future board respin; `dr_mode = "host"` overrides it in
  SW today. Noted here only for traceability.
- USB **device/peripheral** (gadget) mode. Per the station design, normal
  operation is always host; device mode would only matter for a hypothetical
  future eMMC-flash workflow, and that flashing runs in the BootROM
  (`rpiboot`/`usbboot`) before Linux — the Linux `dr_mode=host` does not block
  it. So fixing to host permanently is safe.
- Adding `usbutils`/`lsusb` to the image. The agent discovers modules via the
  slot-control symlinks, not USB enumeration tools.
- Rebuild / reflash / HIL as part of this task. Verification here is code review
  only; the user builds, flashes, and tests on the CM4 afterward.

## Design

Enable + host-force the USB node in the DTB **that u-boot actually boots** — the
rootfs copy at `/boot/broadcom/bcm2711-rpi-cm4.dtb`. Because u-boot loads a
precompiled DTB and applies no overlays, and `config.txt` never reaches Linux,
the enable must be baked into that compiled DTB at build time.

### Fix — build-time DTB post-process (`fdtput`)

Add a `ROOTFS_POSTPROCESS_COMMAND` function (RPi-only) to the image recipe,
mirroring the recipe's existing post-process pattern (`fix_firmware_fstab`,
`stamp_release`). It sets three properties on `/soc/usb@7e980000` of the
deployed rootfs DTB:

- `compatible = "brcm,bcm2835-usb"` — bind the mainline **dwc2** driver
  (honors `dr_mode`, ignores the OTG-ID pin) instead of the legacy `dwc_otg`.
- `dr_mode = "host"` — force host, independent of the carrier divider.
- `status = "okay"` — the node ships disabled.

The node already carries its reg/clocks/interrupts/PHY references (it is fully
formed, only disabled), so only these three properties change — exactly what
`dtoverlay=dwc2,dr_mode=host` would do, but baked in. Gadget-mode FIFO
properties (`g-*`) are not set: they apply only to peripheral mode, which we
explicitly do not use.

`fdtput` comes from `dtc-native`; the image recipe gains
`do_rootfs[depends] += "dtc-native:do_populate_sysroot"` so it is on PATH during
`do_rootfs`. The function targets the `broadcom/` rootfs path that
`KERNEL_DEVICETREE = "broadcom/bcm2711-rpi-cm4.dtb"` installs and that `boot.cmd`
loads first; the plan confirms the exact node path against a freshly built DTB
before trusting it (`fdtget` round-trip).

Only the **rootfs** DTB is patched. The DTB the RPi firmware loads onto the FAT
partition is discarded by u-boot and never reaches Linux, so it is out of scope.

### Cleanup — remove the inert `otg_mode=1`

In `raspberrypi4-64.yml`, drop `otg_mode=1` from `RPI_EXTRA_CONFIG` and replace
it with a comment stating that USB host is enabled by the DTB post-process
(`enable_usb_host_dtb` in the image recipe), because u-boot does not read
`config.txt`. `config.txt` itself stays — the RPi firmware still needs it
(kernel/u-boot selection, `enable_uart`, etc.); only the inert DT directive is
removed.

## Affected files (anticipated)

- `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`
  — new `enable_usb_host_dtb` post-process (RPi-only) + `dtc-native` build dep.
- `raspberrypi4-64.yml` — remove `otg_mode=1` from `RPI_EXTRA_CONFIG`; add
  pointer comment.

## Verification (code review only)

- Confirm the node path `/soc/usb@7e980000` and the disabled/`brcm,bcm2708-usb`
  starting state match the DTB the build produces (plan does an `fdtget`
  round-trip on the built dtb).
- Confirm the post-process runs RPi-only and against the same DTB path
  `boot.cmd` `ext4load`s (`/boot/broadcom/bcm2711-rpi-cm4.dtb`).
- No build/flash/HIL here. On-target acceptance (after the user builds + flashes)
  is the deferred checklist below.

### Deferred on-target acceptance (after flashing the #44 + USB image)

1. `/sys/bus/usb/devices/` is non-empty; `dmesg` shows `dwc2` bound and a new
   USB bus / root hub; the FE1.1s hub enumerates.
2. `/dev/ttyACM*` appears for the FM module; `oe5xrx-slot-udev` creates
   `/dev/oe5xrx/slot*/control`.
3. The station-agent's heartbeat inventory lists the module(s) in
   station-manager.

## Rollout

This fix (rootfs/DTB) is by itself OTA-deliverable — OTA streams the
`.rootfs.bz2` into the inactive slot, and the DTB travels inside the rootfs.
**But the currently deployed card must be reflashed once, not OTA'd**, because
it needs the full #44 baseline: Fix A (correct `boot.scr` on the FAT partition)
and Fix B (new u-boot binary with redundant raw-MMC env) live on the FAT
partition / in the u-boot binary, which OTA never touches. On the current
pre-#44 card the OTA commit/rollback path itself is unreliable (the Fix-B env
mismatch), so a one-time reflash establishes a correct baseline. After that,
this and future kernel/DTB/rootfs changes are fully OTA-deliverable; only
u-boot / FAT / partition-layout changes ever require a reflash again.
