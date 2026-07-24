# CM4 USB: switch host controller dwc2 → dwc_otg (FIQ) — Design

**Date:** 2026-07-24
**Status:** Approved (design), pending on-target verification
**Machine affected:** `raspberrypi4-64` (CM4). x86 untouched.
**Supersedes the driver choice in:** `2026-07-23-cm4-usb-host-dtb.md` (that fix
correctly brought the USB host up via mainline dwc2; this changes only which
in-tree driver binds, to fix full-speed bulk transfers).

## Problem

With the USB host enabled via mainline **dwc2** (`brcm,bcm2835-usb` + host, the
2026-07-23 fix), the CM4 enumerates the FM module but **cannot exchange CDC data
with it** — the station-agent's `module list` probe gets no response, so no
modules are reported.

### Traced on hardware (verified, not assumed)

- The FM module is a **full-speed (12 Mbit/s)** device behind the BusBoard's
  **high-speed (480 Mbit/s)** FE1.1s hub on the dwc2 host:
  `usb1: 480`, `1-1 (hub): 480`, `1-1.3 (module): 12`. A full-speed device
  behind a high-speed hub forces the host to issue **split transactions**.
- **Control** transfers work (enumeration reads all descriptors). **Bulk** CDC
  transfers are silent: a passive read yields 0 bytes and a persistent,
  DTR-asserted terminal (`microcom`) gets no prompt — same result as the agent.
- The **same module, through the same FE1.1s hub, works from a laptop USB host**
  (the developer's bench test went laptop → debug board in the CM4 slot →
  BusBoard → FE1.1s → module). So the differentiator is the **host controller**,
  not the module, the hub, the firmware, or the probe method.
- `dmesg` shows a clean enumeration with **no transfer errors** on `1-1.3` — i.e.
  dwc2 fails the bulk splits **silently** (NAK/timeout), which matches its
  well-known weak split-transaction support.
- mainline dwc2 has **no devicetree property to force full-speed** in host mode
  (`maximum-speed` is honoured by dwc3, not dwc2; `params.speed` comes from
  hardware), so "run the tree at full-speed to avoid splits" is not reachable
  from the DTB with dwc2.

## Goal

The CM4 host must exchange CDC bulk data with the full-speed FM module behind the
high-speed hub, so the agent's `module list` probe returns `MODULE-LIST` and the
module appears in station-manager.

## Design

Bind the **legacy RPi `dwc_otg`** driver instead of mainline dwc2, by patching
the same rootfs DTB node `/soc/usb@7e980000` in the existing
`enable_usb_host_dtb` post-process:

- `compatible = "brcm,bcm2708-usb"` (was `brcm,bcm2835-usb`) → binds `dwc_otg`.
- `status = "okay"`, `dr_mode = "host"` unchanged.

Why dwc_otg fixes it:

- The RPi `dwc_otg` driver has a **FIQ split-transaction FSM** engineered
  specifically for full-speed/low-speed devices behind high-speed hubs — the
  exact topology here. It is the default RPi USB host driver and handles this
  case where mainline dwc2 does not.
- **Host mode is not a concern (verified in schematic):** the CM4 OTG-ID pin
  sits at a clean logic-low. On `HW-Module-CM4Carrier`, R203 (2k2) pulls it to
  GND; R202 (2k2) goes to the `USB_ID` net, but `HW-Module-BusBoard` leaves that
  net **unrouted** (terminates on a no-connect pin of J201, no pull-up, no
  drive), so R202 is an open circuit with no drop. The pin is therefore a clean
  host-low and dwc_otg comes up host via native OTG detection. As
  belt-and-suspenders, dwc_otg also forces host by default — verified in
  linux-raspberrypi 6.6.y (`drivers/usb/host/dwc_otg/dwc_otg_driver.c`):
  `bool cil_force_host = true;` / `MODULE_PARM_DESC(cil_force_host, "On a
  connector-ID status change, force Host Mode regardless of OTG state.")`.
  `dwc_otg` does not read DT `dr_mode`; leaving `dr_mode=host` set is harmless.

Only the driver selection changes; the node's `reg`/`interrupts`/`clocks`/`phy`
are already dwc_otg-compatible (that is the stock `brcm,bcm2708-usb` node).

## Risk & revert

- **Risk is low.** Host mode is settled in hardware (clean OTG-ID low, see above)
  and dwc_otg is the long-proven RPi host driver with the FIQ split FSM. The main
  unknown is simply that this is a driver swap verified only on-target.
- **Revert:** one-line — set `compatible` back to `brcm,bcm2835-usb` (dwc2, known
  to enumerate). No other change needed.
- **No HW fix needed:** the OTG-ID is already a clean host-low (R203 to GND,
  BusBoard leaves `USB_ID` open). The earlier "ground the OTG-ID" idea is moot.

## Non-Goals (YAGNI)

- No change to the agent, the udev slot rules, or the FM firmware.
- No attempt to force full-speed on dwc2 (not reachable from the DTB).
- No `usbutils`.

## Affected files

- `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`
  — `enable_usb_host_dtb`: `compatible` value + comments/note.

## Verification (on-target; code review only in-tree)

Deferred, run after OTA + reboot:
1. `dmesg` shows `dwc_otg` bound to `fe980000.usb` and a USB root hub; the FE1.1s
   hub and the FM module (`1-1.3`, idVendor 2fe3) enumerate.
2. A CDC probe on `/dev/oe5xrx/slot3/control` (`module list\r\n`) returns
   `MODULE-LIST {...}` — no reboot, actual data.
3. The station-agent heartbeat lists the module; the control appears in
   station-manager.

If host does not come up (`/sys/bus/usb/devices/` empty or no `1-1.3`), revert to
dwc2 and pursue the HW OTG-ID fix.

## Rollout

OTA-deliverable (rootfs DTB) — the station has the #44 baseline, so no reflash:
build → OTA → reboot → verify.
