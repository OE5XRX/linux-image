# CM4 USB Host Enable (DTB) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake USB host mode into the CM4 rootfs DTB so the BusBoard hub + FM module enumerate and the station-agent reports modules.

**Architecture:** u-boot `ext4load`s `/boot/broadcom/bcm2711-rpi-cm4.dtb` from the active slot and boots it as-is (no overlays, no `config.txt`). We patch that compiled DTB at image build time (`fdtput` in a `ROOTFS_POSTPROCESS_COMMAND`) to enable `/soc/usb@7e980000`, bind the mainline `dwc2` driver, and force `dr_mode = "host"` — equivalent to `dtoverlay=dwc2,dr_mode=host`, baked in. Separately, drop the now-inert `otg_mode=1` from `config.txt`.

**Tech Stack:** Yocto (kas/bitbake), meta-raspberrypi (linux-raspberrypi 6.6.63), `dtc`/`fdtput`/`fdtget` (device-tree tools), u-boot A/B.

## Global Constraints

- **Machine scope:** `raspberrypi4-64` only. `qemux86-64` (x86) MUST stay untouched — use `:append:raspberrypi4-64` overrides.
- **Design source:** `docs/superpowers/specs/2026-07-23-cm4-usb-host-dtb.md`.
- **Lands on:** branch `fix/cm4-ab-boot` (PR #44) as additional commits.
- **No build/flash/HIL in these tasks.** Verification is code review + structural checks; the on-target `fdtget`/USB acceptance is build-gated and run by the user on the Hetzner build server / CM4 afterward.
- **DTB node:** `/soc/usb@7e980000`. Target properties: `compatible = "brcm,bcm2835-usb"`, `dr_mode = "host"`, `status = "okay"`. Do NOT set gadget-mode `g-*` FIFO properties (peripheral-only, unused).
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: DTB post-process — enable dwc2 host mode

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`

**Interfaces:**
- Consumes: `KERNEL_DEVICETREE = "broadcom/bcm2711-rpi-cm4.dtb"` (from `raspberrypi4-64.yml`) installs the DTB at `${IMAGE_ROOTFS}/boot/broadcom/bcm2711-rpi-cm4.dtb`. `fdtput` from `dtc-native`.
- Produces: a rootfs DTB whose `/soc/usb@7e980000` has `status=okay`, `compatible=brcm,bcm2835-usb`, `dr_mode=host`. Task 2 relies on nothing from here except that USB host no longer depends on `config.txt`.

- [ ] **Step 1: Add the `dtc-native` build dependency**

In `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`, near the other RPi-specific block (after the `IMAGE_BOOT_FILES` lines added by #44, before the `# ---- Station agent dirs ----` section), add:

```python
# CM4 USB host: fdtput (from dtc-native) patches the rootfs DTB below. Make it
# available on PATH during do_rootfs.
do_rootfs[depends] += "dtc-native:do_populate_sysroot"
```

- [ ] **Step 2: Add the post-process function**

Immediately after the dependency line from Step 1, add the function and register it RPi-only:

```python
# Enable + hard-force host mode on the CM4 USB 2.0 controller in the DTB that
# u-boot ext4loads from the active slot's rootfs. u-boot applies no overlays and
# never reads config.txt, and the stock bcm2711-rpi-cm4.dtb ships
# /soc/usb@7e980000 as status="disabled" with the legacy brcm,bcm2708-usb
# (dwc_otg) compatible. We bind the mainline dwc2 driver and force dr_mode=host
# so the ambiguous carrier OTG-ID divider (HW-Module-CM4Carrier R202/R203) is
# irrelevant. This is exactly `dtoverlay=dwc2,dr_mode=host`, baked into the
# compiled dtb. See docs/superpowers/specs/2026-07-23-cm4-usb-host-dtb.md.
python enable_usb_host_dtb() {
    import os
    import subprocess
    # boot.cmd ext4loads the dtb from /boot/broadcom/ first, then falls back to
    # a flat /boot/ path — the exact install location depends on how
    # kernel-devicetree lays it out. Patch every copy that exists so we match
    # whichever one u-boot actually boots; fail only if none is found.
    rootfs = d.getVar('IMAGE_ROOTFS')
    candidates = [
        os.path.join(rootfs, 'boot/broadcom/bcm2711-rpi-cm4.dtb'),
        os.path.join(rootfs, 'boot/bcm2711-rpi-cm4.dtb'),
    ]
    dtbs = [p for p in candidates if os.path.exists(p)]
    if not dtbs:
        bb.fatal('enable_usb_host_dtb: no bcm2711-rpi-cm4.dtb under /boot or '
                 '/boot/broadcom — did KERNEL_DEVICETREE change? Checked: %s'
                 % ', '.join(candidates))
    node = '/soc/usb@7e980000'
    for dtb in dtbs:
        for prop, val in (
            ('compatible', 'brcm,bcm2835-usb'),
            ('dr_mode', 'host'),
            ('status', 'okay'),
        ):
            subprocess.check_call(['fdtput', '-t', 's', dtb, node, prop, val])
        bb.note('enable_usb_host_dtb: forced %s to dwc2 host mode in %s'
                % (node, dtb))
}
ROOTFS_POSTPROCESS_COMMAND:append:raspberrypi4-64 = " enable_usb_host_dtb;"
```

- [ ] **Step 3: Structural review (no build)**

Confirm by reading the edited file:
- The `do_rootfs[depends]` line and the function are present, and the
  `ROOTFS_POSTPROCESS_COMMAND` registration uses `:append:raspberrypi4-64` (so
  x86 never runs it).
- The three properties match the Global Constraints exactly; no `g-*` props.
- `bb.fatal` guards a missing DTB (fails the build loudly if `KERNEL_DEVICETREE`
  ever moves the path).

Run (grep sanity):

```bash
grep -n "enable_usb_host_dtb\|dtc-native\|brcm,bcm2835-usb\|dr_mode" \
  meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
```
Expected: the dep line, the function body (compatible/dr_mode/status), and the `:append:raspberrypi4-64` registration all present.

- [ ] **Step 4: Deferred build-gated verification (run on the Hetzner build host, NOT part of this commit)**

Documented here so the user can confirm after a build. After `kas build` produces the image, read the DTB back from the built rootfs (`/boot/broadcom/bcm2711-rpi-cm4.dtb`, or the flat `/boot/bcm2711-rpi-cm4.dtb` fallback — whichever the build produced; a loop-mounted `root_a` works too):

```bash
fdtget <built-rootfs>/boot/broadcom/bcm2711-rpi-cm4.dtb \
  /soc/usb@7e980000 status compatible dr_mode
```
Expected output:
```
okay
brcm,bcm2835-usb
host
```

- [ ] **Step 5: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "fix(cm4-usb): enable dwc2 host mode in rootfs DTB via post-process

u-boot ext4loads bcm2711-rpi-cm4.dtb as-is (no overlays, no config.txt),
and it ships /soc/usb@7e980000 disabled with the legacy dwc_otg compatible,
so the USB host never comes up and the agent reports no modules. Bake the
equivalent of dtoverlay=dwc2,dr_mode=host into the compiled rootfs DTB with
fdtput: bind mainline dwc2, force host (ignores the ambiguous carrier
OTG-ID divider), enable the node. raspberrypi4-64-only.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Drop the inert `otg_mode=1`

**Files:**
- Modify: `raspberrypi4-64.yml`

**Interfaces:**
- Consumes: nothing from Task 1 at build time; this is an independent cleanup that documents where USB host now comes from.
- Produces: no `otg_mode=1` in the generated `config.txt`; a comment pointing to `enable_usb_host_dtb`.

- [ ] **Step 1: Replace the inert setting with a pointer comment**

In `raspberrypi4-64.yml`, in the `local_conf_header.rpi` block, remove the line:

```
    RPI_EXTRA_CONFIG = "\notg_mode=1\n"
```

and replace it with:

```
    # USB host is enabled by the enable_usb_host_dtb post-process in
    # oe5xrx-remotestation-image.bb — u-boot ignores config.txt / DT overlays,
    # so the former `RPI_EXTRA_CONFIG = "\notg_mode=1\n"` never reached Linux
    # and is dropped. config.txt itself is still generated (firmware needs it).
```

- [ ] **Step 2: Structural review (no build)**

```bash
grep -n "otg_mode\|RPI_EXTRA_CONFIG\|enable_usb_host_dtb" raspberrypi4-64.yml
```
Expected: no `otg_mode=1` assignment remains; the comment referencing `enable_usb_host_dtb` is present. (`RPI_EXTRA_CONFIG` is unset now — it was the only user of it; meta-raspberrypi handles an unset value fine.)

- [ ] **Step 3: Commit**

```bash
git add raspberrypi4-64.yml
git commit -m "chore(cm4): drop inert otg_mode=1 from RPI_EXTRA_CONFIG

u-boot loads its own DTB from ext4 and never reads config.txt, so the
otg_mode=1 firmware DT patch was discarded before Linux. USB host is now
enabled via the enable_usb_host_dtb DTB post-process. Comment records why.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Goal 1 (USB enabled + host-forced in every built image) → Task 1.
- Goal 2 (host mode independent of OTG-ID divider: dwc2 + dr_mode=host) → Task 1 (`compatible=brcm,bcm2835-usb`, `dr_mode=host`).
- Goal 3 (remove misleading `otg_mode=1`) → Task 2.
- Spec "Affected files" (image recipe + `raspberrypi4-64.yml`) → Tasks 1 and 2. No other files touched. ✓
- Non-goals (no HW change, no gadget mode, no `usbutils`, no build/flash in task) → honored; Global Constraints forbids `g-*` props and build steps. ✓
- Rollout (reflash current card, OTA after) → captured in the spec; no code task needed. ✓

**Placeholder scan:** No TBD/TODO; every code/step shows exact content and commands. ✓

**Type/name consistency:** Function `enable_usb_host_dtb`, node `/soc/usb@7e980000`, and the three property/value pairs are identical across Global Constraints, Task 1 code, and the verification step. `RPI_EXTRA_CONFIG` referenced consistently in Task 2. ✓
