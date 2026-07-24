# CM4 USB: boot the firmware DTB (otg_mode=1 → XHCI) — Design

**Date:** 2026-07-24
**Status:** Approved (design), pending on-target verification (reflash)
**Machine affected:** `raspberrypi4-64` (CM4). x86 untouched.
**Supersedes:** the rootfs-DTB USB-host patching from `2026-07-23-cm4-usb-host-dtb.md`
(dwc2) and `2026-07-24-cm4-usb-dwc-otg.md` (dwc_otg). Both are removed here.

## Problem

The CM4 must talk to the full-speed FM module behind the BusBoard's high-speed
FE1.1s hub. On-target we proved that **neither CM4-native USB2 driver works**:

- **dwc2** (`brcm,bcm2835-usb`): enumerates the whole tree, but silently fails the
  CDC *bulk* split transfers — the agent's `module list` gets no reply.
- **dwc_otg** (`brcm,bcm2708-usb`, RPi FIQ): hosts (root hub up) but never even
  detects the downstream FE1.1s hub — `/sys/bus/usb/devices/` shows only the root
  hub.

The **same module, through the same hub, works from a laptop USB host** — whose
xHCI controller handles the full-speed-behind-high-speed-hub split transactions
correctly. On the CM4 the standards-compliant controller is the **XHCI** enabled
by `otg_mode=1` (the developer confirmed the USB hub worked on the official RPi
OS with that flag). So the fix is: use the firmware's XHCI, not a rootfs-DTB
driver hack.

### Root cause of "otg_mode=1 never worked for us"

Our image boots via **u-boot**, and `boot.cmd` `ext4load`s its OWN DTB from the
rootfs, then boots that. u-boot loading its own DTB **discards the DTB the RPi GPU
firmware built from config.txt** (dtparams, overlays, `otg_mode`). This is a
well-documented RPi+u-boot pitfall, and the documented fix is to boot the
firmware-provided DTB, whose address u-boot exposes in **`${fdt_addr}`** (vs
`${fdt_addr_r}`, where u-boot loads its own).

## Goal

`otg_mode=1` takes effect → firmware enables XHCI → the FE1.1s hub and the FM
module enumerate and the agent's `module list` returns `MODULE-LIST`.

## Design

Three coordinated changes (`raspberrypi4-64`-only):

1. **Restore `otg_mode=1`** in `RPI_EXTRA_CONFIG` (`raspberrypi4-64.yml`) so the
   firmware enables XHCI and bakes it into the DTB it hands to u-boot.
2. **`boot.cmd`: boot the firmware DTB.** Keep loading the kernel from the active
   rootfs slot (A/B preserved), but boot with `${fdt_addr}` (firmware DTB) instead
   of `ext4load`ing the rootfs DTB into `${fdt_addr_r}`. A **fallback** remains:
   if `${fdt_addr}` is unset or the firmware-DTB boot returns, load the rootfs DTB
   (boots without config.txt effects — degraded but not bricked).
3. **Remove the obsolete rootfs-DTB post-process** (`enable_usb_host_dtb`) and its
   `dtc-native` build dep from the image recipe: u-boot no longer boots the rootfs
   DTB, so patching it is dead code.

## Trade-offs (accepted; explicitly guarded)

- **DTB now comes from the firmware (FAT partition), not the rootfs.** OTA updates
  the rootfs (kernel + userspace) but **not** the FAT firmware DTB. Practical
  impact:
  - Day-to-day operation and software/kernel OTA updates: **unchanged**.
  - **New modules: no impact** — they are USB devices, discovered at runtime, not
    in the DTB.
  - Only a **CM4 hardware-description change** (new SoC peripheral / overlay, or a
    kernel bump that needs a matching new DTB) requires a **reflash** instead of a
    remote OTA.
  - The "kernel + DTB always travel together" property of the kernel-in-rootfs A/B
    design is weakened. In practice RPi DTBs are stable across kernel versions.
- **Guards (separate tickets, not in this PR):**
  - `station-manager #106` — userspace hardware-health gate on the OTA A/B commit
    ("FE1.1s hub reached"): a kernel OTA that regresses USB fails the gate → A/B
    rolls back + reports, instead of committing a broken image.
  - `linux-image #46` — kernel version pin review + DTB-compatibility policy.

## Non-Goals (YAGNI)

- No `fdt apply dwc2.dtbo` overlay-in-u-boot (known-buggy: FDT_ERR_NOTFOUND on
  local labels).
- No baking the firmware's XHCI transformation into the rootfs DTB (fragile,
  firmware-version-dependent — explicitly rejected).
- No agent / udev / FM-firmware change.

## Affected files

- `raspberrypi4-64.yml` — restore `otg_mode=1` in `RPI_EXTRA_CONFIG`.
- `meta-oe5xrx-remotestation/recipes-bsp/u-boot-ab/files/boot.cmd` — boot
  `${fdt_addr}` with rootfs-DTB fallback.
- `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb` —
  remove `enable_usb_host_dtb` + `dtc-native` dep.

## Verification

In-tree: code review only (boot.cmd is not build-verifiable; the `${fdt_addr}`
population is standard RPi u-boot but confirmed on-target).

Deferred on-target (requires a **reflash** — config.txt + boot.cmd live on FAT):
1. `dmesg` shows the **xhci** host bound (not dwc2/dwc_otg); the FE1.1s hub
   (`1-1`, idVendor 1a40) and FM module (`1-1.3`, idVendor 2fe3) enumerate.
2. A CDC probe on `/dev/oe5xrx/slot3/control` (`module list\r\n`) returns
   `MODULE-LIST {...}`.
3. The station-agent lists the module; it appears in station-manager.
4. Confirm the u-boot log line "Booting with firmware DTB at ..." (i.e. the
   fallback was NOT taken).

## Rollout

**Requires a one-time reflash** (config.txt + boot.cmd are on the FAT partition,
which OTA does not touch). After that, kernel/rootfs updates continue via OTA;
only DTB-level changes need a future reflash.
