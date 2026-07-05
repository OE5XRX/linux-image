# D2 — Co-located Module-Sim Layer: FM-Serial-Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default for this project) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. `forge` agent for linux-image/Yocto tasks (L*), `gateway` agent for station_agent tasks (S*).

**Goal:** Pin the FW-RemoteStation release `26.07.04-01` artifacts (real firmware `.bin` = DFU source + `native_sim` = simulator) into the linux-image by URL+sha256, cosign-verified before embedding; run the pinned `native_sim` as a dev-only service that materializes the slot contract `/dev/oe5xrx/slot1/control`; ship the real-HW udev half of the same contract; and have the `station_agent` discover the slot, run `describe`, and report the module inventory — end-to-end against the real `native_sim` binary, no hardware.

**Architecture:** Two repos, two branches, two PRs.
- **linux-image** (`feature/d2-sim-harness`): (a) `oe5xrx-fm-firmware` recipe — pins the real `fm-sa818-2m.bin` (DFU source) by URL+sha256; goes into base/prod+dev images. (b) `oe5xrx-native-sim-fm` recipe — pins the real `fm-sa818-2m.native_sim` by URL+sha256; **dev-only**. (c) A shared `scripts/pin-fw-artifact.sh` that fetches an asset + its cosign `.bundle` + `SHA256SUMS`, **cosign-verifies**, cross-checks sha256, and writes URL+sha256 into a recipe. (d) `oe5xrx-sim-harness` — a systemd service that runs the pinned `native_sim`, parses the console pty it prints on stdout, and symlinks it at `/dev/oe5xrx/slot1/control`. **No socat.** (e) `oe5xrx-slot-udev` ruleset (real-HW half, USB hub port → slot). (f) the sim stack (`packagegroup-oe5xrx-sim`) ships in the standard `qemux86-64` image (Proxmox/VM) via `IMAGE_INSTALL:append:qemux86-64`; `native_sim` is x86-only (`COMPATIBLE_MACHINE`) so it never reaches the RPi image. *(Superseded the originally-planned separate `oe5xrx-remotestation-sim-image` + `qemux86-64-sim.yml`, which CI never built.)* (g) release-preflight that rejects unpinned/unsigned FM artifacts. (h) a real-binary harness E2E test in CI + a 2-minute Proxmox doc + a parity doc. `Closes #23`.
- **station-manager** (`feature/d2-agent-discovery`): `station_agent/slot_discovery.py` scans `/dev/oe5xrx/slot*/control`, opens each, sends `module fm describe`, parses the `MODULE-DESCRIBE <json>` line, and folds the result into the existing heartbeat inventory (persisted server-side in `StationInventory.data` — a `JSONField`, so no server model change). This branch already carries the design spec; it rides to main with this PR.

**Tech Stack:** Yocto (kas, scarthgap), BitBake recipes, systemd, udev, cosign (keyless/Sigstore), shellcheck; Python 3.14, pytest, `os`/`termios`/`select` pty I/O; Zephyr `native_sim` (consumed as a **prebuilt, pinned release artifact**, never built here).

## Global Constraints

- **Pin the existing FW-RemoteStation release, do not build firmware.** Both FM artifacts come from FW-RemoteStation release **`26.07.04-01`**, pinned by **release-download URL + `sha256sum`** (values taken from that release's `SHA256SUMS`). No Zephyr/west build anywhere in this plan; no FW-RemoteStation changes.
  - `fm-sa818-2m.bin` → sha256 `f7263b6b99014c95cfeeff84601be5f6e17a3e0861fef29d208e5a42ed4d71f7`
  - `fm-sa818-2m.native_sim` → sha256 `5506c0668f3c6b3ef09f8b3d7a0c923d54d2addb30ecc19f71c06c03616e39bc`
  - Download URL base: `https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.04-01/<asset>`
- **cosign-verify before embedding.** Each asset ships a keyless cosign `.bundle`. Verified identity (from the release cert SAN) is `https://github.com/OE5XRX/FW-RemoteStation/.github/workflows/release.yml@refs/heads/main`, OIDC issuer `https://token.actions.githubusercontent.com`. Verification happens (1) at pin time in `pin-fw-artifact.sh` and (2) at release-preflight time in CI. The recipe's `sha256sum` is BitBake's fetch-time integrity gate; cosign is the authenticity gate.
- **Release-preflight rejects unpinned/unsigned FM artifacts** (mirrors the existing station-agent AUTOREV preflight): fails if a recipe's `SRC_URI`/`sha256sum` is still a placeholder, or if cosign verification of the pinned asset fails.
- **`native_sim` self-creates its pty; no socat.** When the pinned binary runs (no `-uart_stdinout`), it prints two lines to stdout: `uart connected to pseudotty: /dev/pts/N` (the **console/shell** — where `module fm describe` works) and `uart_1 connected to pseudotty: /dev/pts/M` (the SA818 radio link — irrelevant to D2). The harness symlinks the **console** pty (the `^uart connected to pseudotty: ` line) at `/dev/oe5xrx/slot1/control`.
- **`native_sim` is x86-only and ships only in the `qemux86-64` image.** The sim stack (`packagegroup-oe5xrx-sim`) is added to the standard `qemux86-64` image (the Proxmox/VM deployment, which has no real FM hardware — the simulator IS the module) via `IMAGE_INSTALL:append:qemux86-64`; `COMPATIBLE_MACHINE = "qemux86-64"` keeps it off the RPi hardware image. The **real firmware `.bin`** (DFU source) and the **udev ruleset** (harmless without hardware) go into the base image for all machines. *(This superseded the originally-planned separate `oe5xrx-remotestation-sim-image` variant — see task L5.)*
- **Slot contract path is one documented truth:** `/dev/oe5xrx/slotN/control`. Sim (harness) and real (udev) both materialize the identical path; the agent scans only that path and never touches USB topology.
- **Camp-slice scope = ONE slot, FM control-serial only.** No audio (`snd-aloop`/#30), no DFU-sim, no multi-slot/manifest generics, no server-side manifest generator, no control-command translation (that is D3). D2 ends at discover + describe + report.
- **linux-image:** shell scripts must pass `shellcheck -e SC1091 -e SC2039` (existing CI gate). Recipes follow the existing `station-agent`/`ab-layout` patterns.
- **station-manager:** agent code is `threading`-based (not asyncio for the main loop); heartbeat carries an `inventory` dict; discovery must **fail closed** on device/timeout errors (never crash the heartbeat loop). Squash-merge, one commit per PR on main.
- **Versions:** always newest stable; verify before pinning.

---

## Reference: verified upstream facts (read before implementing)

**FM `native_sim` protocol — empirically verified against the real `26.07.04-01` binary:**
- Run `./fm-sa818-2m.native_sim` (NO `-uart_stdinout`). Stdout prints (order as observed):
  ```
  uart_1 connected to pseudotty: /dev/pts/3      # SA818 radio link — ignore
  uart connected to pseudotty: /dev/pts/4        # CONSOLE/SHELL — this is slotN/control
  ... a few <inf> log lines ...
  *** Booting Zephyr OS build ... ***
  ```
- The binary is a **statically linked** x86-64 ELF (`ldd` → "not a dynamic executable"), so it runs in any x86-64 rootfs with no glibc/interpreter dependency. It keeps running with stdin unused (console is on the pty, not stdin).
- Open the console pty (`/dev/pts/4`), write `module fm describe\n` (LF or CRLF both work; the Zephyr shell echoes input). The response line is:
  ```
  MODULE-DESCRIBE {"schema":1,"module":"fm","identity":{"type":"fm_transceiver","model":"SA818-V","version":"vhf"},"capabilities":[ ...12 caps... ]}
  ```
  The `MODULE-DESCRIBE {...}` line itself carries no ANSI codes; the surrounding `fm> ` prompt does. Parse by locating the `MODULE-DESCRIBE ` prefix in a line and `json.loads` the remainder.
- `version\n` → `APP-VERSION YY.MM.DD-NN`. (Not needed for D2 but confirms the shell.)
- Protocol source in FW: `FW-RemoteStation/subsys/module/devices/sa818/sa818_module.cpp` (`cmd_module`, `describe` at `argv[2]`); identity strings are compile-time (`fm_transceiver` / `SA818-V` / `vhf`).

**Release assets & signing (from release `26.07.04-01`):**
- `SHA256SUMS` format: `<sha256>  <filename>` (two spaces), standard `sha256sum -c` format.
- Each asset has a sibling `<asset>.bundle` (cosign keyless bundle: `base64Signature` + `cert` + `rekorBundle`). Cert SAN = `https://github.com/OE5XRX/FW-RemoteStation/.github/workflows/release.yml@refs/heads/main`; OIDC issuer OID `1.3.6.1.4.1.57264.1.1` = `https://token.actions.githubusercontent.com`.

**linux-image recipe patterns:**
- systemd service recipe: `meta-oe5xrx-remotestation/recipes-core/station-agent/station-agent_0.1.0.bb` + `files/station-agent.service`.
- script + oneshot/mount units: `meta-oe5xrx-remotestation/recipes-core/ab-layout/ab-layout_1.0.bb` + `files/data-init.{sh,service}`.
- dev image extends prod: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb` (`require oe5xrx-remotestation-image.bb`).
- prod image: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`.
- pin script convention: `scripts/pin-station-agent.sh` (in-place recipe rewrite, `--dry-run`, shellcheck-clean).
- Release preflight (AUTOREV rejection) job to mirror: `.github/workflows/release.yml` `preflight` job.
- CI lint gates: `.github/workflows/ci.yml` (kas validate, shellcheck, yamllint).

**station_agent structure (station-manager):**
- `station_agent/inventory.py::collect_inventory()` returns the inventory dict.
- `station_agent/heartbeat.py::collect_system_info()` embeds `inventory` + `module_versions`; `send_heartbeat()` → `POST /api/v1/heartbeat/`.
- `station_agent/config.py::AgentConfig` dataclass + `load_config()`; `station_agent/config.example.yml`.
- `station_agent/terminal.py` — reference for raw pty fd I/O (`os.read`/`os.write`, termios).
- Server: `apps/api/views.py::HeartbeatView` stores `data["inventory"]` via `StationInventory.objects.update_or_create(...)`. `apps/stations/models.py::StationInventory.data` is a `JSONField` → arbitrary keys pass through.
- Tests: `tests/conftest.py` (`station_with_key`, `device_auth_headers`), `tests/test_heartbeat_inventory.py`.

---

# Part A — linux-image (`feature/d2-sim-harness`)

Worktree: `/home/pbuchegger/OE5XRX/linux-image/.worktrees/d2-sim-harness`
Layer root: `meta-oe5xrx-remotestation/`

### Task L1: udev slot ruleset (real-HW half of the slot contract)

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/oe5xrx-slot-udev_1.0.bb`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: udev rules that, on real HW, create `/dev/oe5xrx/slot1/control` … `/dev/oe5xrx/slot4/control` from CDC-ACM ttys behind BusBoard hub ports `1-1.1`…`1-1.4`. Same path the sim harness (L4) creates and the agent (S1) consumes.

- [ ] **Step 1: Add the failing syntax gate to CI**

Add to the lint job in `.github/workflows/ci.yml`:

```yaml
      - name: Verify udev slot rules syntax
        run: |
          sudo apt-get update -qq && sudo apt-get install -y udev
          udevadm verify meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules
```

- [ ] **Step 2: Run it to verify it fails**

Run: `udevadm verify meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Write the rules file**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules`:

```
# OE5XRX slot contract — real-HW half (D2, spec §3a).
# BusBoard FE1.1s hub ports are fixed-wired: port = slot.
# The FM module's CDC-ACM (control) interface is a child of the hub port.
# Two identical modules are told apart by PORT PATH only, never serial.
# Only slotN/control (CDC-ACM/tty) is in D2 scope. audio (UAC2) and dfu are later deliverables.
ACTION=="remove", GOTO="oe5xrx_slots_end"

SUBSYSTEM=="tty", SUBSYSTEMS=="usb", KERNELS=="1-1.1", SYMLINK+="oe5xrx/slot1/control"
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", KERNELS=="1-1.2", SYMLINK+="oe5xrx/slot2/control"
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", KERNELS=="1-1.3", SYMLINK+="oe5xrx/slot3/control"
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", KERNELS=="1-1.4", SYMLINK+="oe5xrx/slot4/control"

LABEL="oe5xrx_slots_end"
```

- [ ] **Step 4: Write the recipe**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/oe5xrx-slot-udev_1.0.bb`:

```bitbake
SUMMARY = "OE5XRX slot contract udev rules (USB hub port -> /dev/oe5xrx/slotN/control)"
DESCRIPTION = "Real-HW half of the D2 slot contract. Maps fixed BusBoard hub ports to \
canonical slot control symlinks so the station_agent sees the same path in sim and real."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-oe5xrx-slots.rules"

S = "${WORKDIR}"

inherit allarch

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/90-oe5xrx-slots.rules ${D}${sysconfdir}/udev/rules.d/90-oe5xrx-slots.rules
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/90-oe5xrx-slots.rules"
```

- [ ] **Step 5: Run the gate to verify it passes**

Run: `udevadm verify meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules`
Expected: PASS (no syntax errors reported).

- [ ] **Step 6: Add the ruleset to the base/prod image**

In `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`, append `oe5xrx-slot-udev` to `IMAGE_INSTALL` (match the file's existing `IMAGE_INSTALL = " ... "` block style):

```bitbake
IMAGE_INSTALL:append = " oe5xrx-slot-udev"
```

- [ ] **Step 7: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev .github/workflows/ci.yml \
  meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "feat(udev): slot-contract ruleset (real-HW half, port->slotN/control)"
```

---

### Task L2: shared cosign pin helper + `oe5xrx-fm-firmware` recipe (real .bin, DFU source)

**Files:**
- Create: `scripts/pin-fw-artifact.sh`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-fm-firmware/oe5xrx-fm-firmware_26.07.04.bb`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`

**Interfaces:**
- Produces:
  - `scripts/pin-fw-artifact.sh <recipe-path> <download-url>` — fetches the asset + `<asset>.bundle` + the release `SHA256SUMS`, runs `cosign verify-blob` (identity + issuer above), cross-checks the sha256 against `SHA256SUMS`, and rewrites the recipe's `SRC_URI` + `SRC_URI[sha256sum]`. `--dry-run` prints without writing. Reused by L3. Must be shellcheck-clean.
  - Installs `/lib/firmware/oe5xrx/fm-sa818-2m.bin` (the DFU payload). Not executed in D2; bundled for later DFU use. Goes into base/prod+dev images.

- [ ] **Step 1: Write the shared pin helper**

`scripts/pin-fw-artifact.sh`:

```bash
#!/usr/bin/env bash
#
# Pin a FW-RemoteStation release asset (URL + sha256) into a Yocto recipe.
#
# Fetches the asset, its cosign .bundle, and the release SHA256SUMS; verifies
# the cosign keyless signature (authenticity) and cross-checks the sha256
# (integrity) against SHA256SUMS; then rewrites the recipe's SRC_URI and
# SRC_URI[sha256sum]. The recipe's sha256sum is BitBake's fetch-time gate.
#
# Usage:
#   scripts/pin-fw-artifact.sh <recipe-path> <asset-download-url>
#   scripts/pin-fw-artifact.sh <recipe-path> <asset-download-url> --dry-run
#
# Requires: cosign, curl, sha256sum on PATH.
set -euo pipefail

RECIPE="${1:-}"
URL="${2:-}"
DRY_RUN=0
[ "${3:-}" = "--dry-run" ] && DRY_RUN=1

readonly COSIGN_IDENTITY_RE='^https://github.com/OE5XRX/FW-RemoteStation/\.github/workflows/release\.yml@refs/.+$'
readonly COSIGN_ISSUER='https://token.actions.githubusercontent.com'

fail() { echo "pin-fw-artifact: $*" >&2; exit 1; }

[ -n "$RECIPE" ] && [ -n "$URL" ] || fail "usage: $0 <recipe-path> <asset-url> [--dry-run]"
[ -f "$RECIPE" ] || fail "recipe not found: $RECIPE"
command -v cosign >/dev/null 2>&1 || fail "cosign not on PATH"

asset="$(basename "$URL")"
base_url="${URL%/*}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching $asset, $asset.bundle, SHA256SUMS ..." >&2
curl -fsSL "$URL"                 -o "$tmp/$asset"
curl -fsSL "$URL.bundle"          -o "$tmp/$asset.bundle"
curl -fsSL "$base_url/SHA256SUMS" -o "$tmp/SHA256SUMS"

echo "Verifying cosign signature ..." >&2
cosign verify-blob \
    --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_ISSUER" \
    --bundle "$tmp/$asset.bundle" \
    "$tmp/$asset" >/dev/null 2>&1 \
    || fail "cosign verification FAILED for $asset"

sha="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
expected="$(awk -v f="$asset" '$2==f {print $1}' "$tmp/SHA256SUMS")"
[ -n "$expected" ] || fail "$asset not listed in SHA256SUMS"
[ "$sha" = "$expected" ] || fail "sha256 mismatch: computed $sha, SHA256SUMS $expected"

echo "OK  asset=$asset  sha256=$sha  (cosign verified)" >&2

if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run) $RECIPE not modified" >&2
    exit 0
fi

# Rewrite the two pinned lines. Recipe must already contain SRC_URI = "..." and
# SRC_URI[sha256sum] = "..." lines (placeholders are fine on first pin).
tmp_recipe="$(mktemp)"
awk -v url="$URL" -v sha="$sha" '
    /^SRC_URI\[sha256sum\][[:space:]]*=/ { print "SRC_URI[sha256sum] = \"" sha "\""; next }
    /^SRC_URI[[:space:]]*=/              { print "SRC_URI = \"" url "\""; next }
    { print }
' "$RECIPE" > "$tmp_recipe"
cat "$tmp_recipe" > "$RECIPE"   # preserve original mode
rm -f "$tmp_recipe"
echo "Pinned $RECIPE" >&2
```

- [ ] **Step 2: Make it executable and lint it**

Run:
```bash
chmod +x scripts/pin-fw-artifact.sh
shellcheck -e SC1091 -e SC2039 scripts/pin-fw-artifact.sh
```
Expected: no shellcheck findings.

- [ ] **Step 3: Write the firmware recipe (already pinned to the known release values)**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-fm-firmware/oe5xrx-fm-firmware_26.07.04.bb`:

```bitbake
SUMMARY = "OE5XRX FM transceiver firmware (SA818, 2m) — DFU payload"
DESCRIPTION = "Real FM module firmware (.bin) pinned from FW-RemoteStation release 26.07.04-01, \
cosign-verified. This is the DFU source flashed onto a real FM module; bundled into the image for \
later DFU use. Pin/re-pin with scripts/pin-fw-artifact.sh."
LICENSE = "CLOSED"

# Pinned FW-RemoteStation release 26.07.04-01 (URL + sha256 from SHA256SUMS, cosign-verified).
# Re-pin with: scripts/pin-fw-artifact.sh <this-recipe> <url>
SRC_URI = "https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.04-01/fm-sa818-2m.bin"
SRC_URI[sha256sum] = "f7263b6b99014c95cfeeff84601be5f6e17a3e0861fef29d208e5a42ed4d71f7"

PV = "26.07.04"

S = "${WORKDIR}"

inherit allarch

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/oe5xrx
    install -m 0644 ${WORKDIR}/fm-sa818-2m.bin ${D}${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-2m.bin
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-2m.bin"
```

- [ ] **Step 4: Verify the pin is authentic (idempotent re-pin, cosign)**

Run (requires cosign + network):
```bash
scripts/pin-fw-artifact.sh \
  meta-oe5xrx-remotestation/recipes-core/oe5xrx-fm-firmware/oe5xrx-fm-firmware_26.07.04.bb \
  https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.04-01/fm-sa818-2m.bin \
  --dry-run
```
Expected: `OK  asset=fm-sa818-2m.bin  sha256=f7263b6b...  (cosign verified)`, and the recipe already carries that exact sha256 (a real re-pin without `--dry-run` leaves the file byte-identical).

- [ ] **Step 5: Add the firmware to the base/prod image**

In `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb`, extend the `IMAGE_INSTALL:append` from L1:

```bitbake
IMAGE_INSTALL:append = " oe5xrx-slot-udev oe5xrx-fm-firmware"
```

- [ ] **Step 6: Commit**

```bash
git add scripts/pin-fw-artifact.sh \
  meta-oe5xrx-remotestation/recipes-core/oe5xrx-fm-firmware \
  meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb
git commit -m "feat(fw): pin cosign-verified FM firmware .bin (DFU source) + shared pin helper"
```

---

### Task L3: `oe5xrx-native-sim-fm` recipe (pinned native_sim, dev-only)

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm_26.07.04.bb`

**Interfaces:**
- Produces: `/usr/libexec/oe5xrx/native-sim-fm` (0755) — the describe-capable, statically-linked native_sim ELF from release `26.07.04-01`. Consumed by the harness (L4). Dev-only (never installed by prod/dev images; only via `packagegroup-oe5xrx-sim` in L5).

- [ ] **Step 1: Write the recipe (pinned to the known release values)**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm_26.07.04.bb`:

```bitbake
SUMMARY = "Prebuilt Zephyr native_sim FM binary (dev-only simulation)"
DESCRIPTION = "Statically-linked native_sim ELF pinned from FW-RemoteStation release 26.07.04-01, \
cosign-verified. Answers `module fm describe` on a self-created console pty. Consumed by \
oe5xrx-sim-harness. Never in prod or standard dev builds. Pin/re-pin with scripts/pin-fw-artifact.sh."
LICENSE = "CLOSED"

# Pinned FW-RemoteStation release 26.07.04-01 (URL + sha256 from SHA256SUMS, cosign-verified).
# Re-pin with: scripts/pin-fw-artifact.sh <this-recipe> <url>
SRC_URI = "https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.04-01/fm-sa818-2m.native_sim;downloadfilename=fm-sa818-2m.native_sim"
SRC_URI[sha256sum] = "5506c0668f3c6b3ef09f8b3d7a0c923d54d2addb30ecc19f71c06c03616e39bc"

PV = "26.07.04"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "qemux86-64"

# Prebuilt, statically-linked host-native x86-64 ELF (not cross-built by Yocto):
# bypass QA checks that assume cross-built, dynamically-linked artifacts.
INSANE_SKIP:${PN} = "already-stripped ldflags arch file-rdeps textrel staticdev"
EXCLUDE_FROM_SHLIBS = "1"

do_install() {
    install -d ${D}${libexecdir}/oe5xrx
    install -m 0755 ${WORKDIR}/fm-sa818-2m.native_sim ${D}${libexecdir}/oe5xrx/native-sim-fm
}

FILES:${PN} = "${libexecdir}/oe5xrx/native-sim-fm"
```

- [ ] **Step 2: Verify the pin is authentic (cosign, dry-run)**

Run (requires cosign + network):
```bash
scripts/pin-fw-artifact.sh \
  meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm_26.07.04.bb \
  https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.04-01/fm-sa818-2m.native_sim \
  --dry-run
```
Expected: `OK  asset=fm-sa818-2m.native_sim  sha256=5506c066...  (cosign verified)`.

- [ ] **Step 3: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm
git commit -m "feat(sim): pin cosign-verified native_sim FM artifact (dev-only)"
```

---

### Task L4: `oe5xrx-sim-harness` — parse native_sim pty + symlink slot1/control

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/oe5xrx-sim-harness_1.0.bb`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh`
- Create: `meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/oe5xrx-sim-harness.service`

**Interfaces:**
- Consumes: `/usr/libexec/oe5xrx/native-sim-fm` (L3).
- Produces: `/dev/oe5xrx/slot1/control` — a symlink to the native_sim **console** pty. Identical path to L1/udev; consumed by agent (S1).

- [ ] **Step 1: Write the harness script**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh`:

```bash
#!/bin/sh
# OE5XRX sim harness (dev-only, D2 camp-slice).
# Runs the pinned native_sim FM binary. native_sim self-creates two ptys and
# announces them on stdout:
#   uart connected to pseudotty: /dev/pts/N     <- console/shell  (slot1/control)
#   uart_1 connected to pseudotty: /dev/pts/M   <- SA818 radio link (ignored)
# We symlink the CONSOLE pty at the canonical slot-contract path
# /dev/oe5xrx/slot1/control. This is the SIM populator; on real HW udev creates
# the identical path (spec §3c). No socat: native_sim owns the pty.
#
# SLOT_DIR is overridable for host testing (default is the canonical /dev path).
set -eu

SIM_BIN="${SIM_BIN:-/usr/libexec/oe5xrx/native-sim-fm}"
SLOT_DIR="${SLOT_DIR:-/dev/oe5xrx/slot1}"
SLOT_LINK="${SLOT_DIR}/control"
RUNDIR="${RUNDIR:-/run/oe5xrx/native-sim-fm}"
LOG="${RUNDIR}/sim.log"

[ -x "$SIM_BIN" ] || { echo "sim-harness: native_sim binary missing: $SIM_BIN" >&2; exit 1; }

mkdir -p "$SLOT_DIR" "$RUNDIR"
cd "$RUNDIR"
: > "$LOG"

# Start native_sim, stdout+stderr to a regular file (never blocks the child).
"$SIM_BIN" > "$LOG" 2>&1 &
SIM_PID=$!

cleanup() {
    rm -f "$SLOT_LINK"
    kill "$SIM_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# Wait up to ~10s for the CONSOLE pty line (the one WITHOUT the _1 suffix).
PTY=""
i=0
while [ "$i" -lt 100 ]; do
    line="$(grep -m1 '^uart connected to pseudotty: ' "$LOG" 2>/dev/null || true)"
    if [ -n "$line" ]; then
        PTY="${line#uart connected to pseudotty: }"
        break
    fi
    kill -0 "$SIM_PID" 2>/dev/null || { echo "sim-harness: native_sim exited early; log:" >&2; cat "$LOG" >&2; exit 1; }
    sleep 0.1
    i=$((i + 1))
done

[ -n "$PTY" ] && [ -e "$PTY" ] || { echo "sim-harness: no console pty found; log:" >&2; cat "$LOG" >&2; exit 1; }

ln -sf "$PTY" "$SLOT_LINK"
chmod 660 "$PTY" 2>/dev/null || true
echo "sim-harness: slot1/control -> $PTY (native_sim pid $SIM_PID)" >&2

# Own the service lifecycle: block until native_sim exits (systemd sends TERM).
wait "$SIM_PID"
```

- [ ] **Step 2: Lint the script**

Run: `shellcheck -e SC1091 -e SC2039 meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh`
Expected: no findings.

- [ ] **Step 3: Write the systemd service**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/oe5xrx-sim-harness.service`:

```ini
[Unit]
Description=OE5XRX sim harness (native_sim FM -> slot1/control pty)
Documentation=https://oe5xrx.org/docs/remote-station/
After=local-fs.target
Before=station-agent.service

[Service]
Type=simple
ExecStart=/usr/sbin/sim-harness.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Write the recipe**

`meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/oe5xrx-sim-harness_1.0.bb`:

```bitbake
SUMMARY = "OE5XRX sim harness — native_sim FM behind slot1/control pty (dev-only)"
DESCRIPTION = "Sim populator of the D2 slot contract. Runs the pinned native_sim FM binary and \
symlinks its console pty at /dev/oe5xrx/slot1/control. No socat: native_sim owns the pty."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://sim-harness.sh \
    file://oe5xrx-sim-harness.service \
"

S = "${WORKDIR}"

inherit systemd

RDEPENDS:${PN} += "oe5xrx-native-sim-fm"

SYSTEMD_SERVICE:${PN} = "oe5xrx-sim-harness.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/sim-harness.sh ${D}${sbindir}/sim-harness.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/oe5xrx-sim-harness.service ${D}${systemd_system_unitdir}/oe5xrx-sim-harness.service
}

FILES:${PN} = " \
    ${sbindir}/sim-harness.sh \
    ${systemd_system_unitdir}/oe5xrx-sim-harness.service \
"
```

- [ ] **Step 5: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness
git commit -m "feat(sim): sim-harness service (parse native_sim pty -> slot1/control)"
```

---

### Task L5: dev-only sim image variant + packagegroup + kas convenience config

**Files:**
- Create: `meta-oe5xrx-remotestation/recipes-core/packagegroups/packagegroup-oe5xrx-sim.bb`
- Create: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-sim-image.bb`
- Create: `qemux86-64-sim.yml`

**Interfaces:**
- Consumes: L3 (`oe5xrx-native-sim-fm`), L4 (`oe5xrx-sim-harness`).
- Produces: `oe5xrx-remotestation-sim-image` target — dev image + sim stack. native_sim exists ONLY here.

- [ ] **Step 1: Write the packagegroup**

`meta-oe5xrx-remotestation/recipes-core/packagegroups/packagegroup-oe5xrx-sim.bb`:

```bitbake
SUMMARY = "OE5XRX co-located module simulation stack (dev-only)"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    oe5xrx-native-sim-fm \
    oe5xrx-sim-harness \
"
```

- [ ] **Step 2: Write the sim image recipe**

`meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-sim-image.bb`:

```bitbake
# Dev-only sim image: dev image + co-located module simulation stack.
# native_sim lives ONLY in this variant, never in prod or the plain dev image.
require oe5xrx-remotestation-dev-image.bb

SUMMARY = "OE5XRX RemoteStation dev image with co-located module simulation (native_sim FM)"

IMAGE_INSTALL:append = " packagegroup-oe5xrx-sim"
```

- [ ] **Step 3: Write the kas convenience config**

`qemux86-64-sim.yml`:

```yaml
header:
  version: 15
  includes:
    - qemux86-64.yml

target: oe5xrx-remotestation-sim-image
```

(Confirm the `header.version` matches the other kas files in the repo root; copy their value if it differs.)

- [ ] **Step 4: Validate kas config parses**

Run: `kas dump qemux86-64-sim.yml >/dev/null && echo OK`
Expected: `OK`. If `kas` is unavailable, validate with `yamllint qemux86-64-sim.yml`.

- [ ] **Step 5: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/packagegroups \
  meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-sim-image.bb \
  qemux86-64-sim.yml
git commit -m "feat(sim): dev-only sim image variant + packagegroup + kas config"
```

---

### Task L6: real-binary harness E2E test in CI

**Files:**
- Create: `tests/sim-harness/test_sim_harness.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Verifies the WHOLE sim path with the REAL pinned native_sim: downloads the exact URL+sha256 from the `oe5xrx-native-sim-fm` recipe, runs the harness script against it (with `SLOT_DIR`/`RUNDIR` overridden to a temp dir so it needs no root and no `/dev/oe5xrx`), and asserts (a) `slotdir/control` symlink appears and (b) sending `module fm describe` returns `MODULE-DESCRIBE ...fm_transceiver...`. Runs on the x86-64 CI runner (the binary is static → no rootfs deps). This is the automated E2E-against-native_sim required by DoD §9/§11.

- [ ] **Step 1: Write the failing test**

`tests/sim-harness/test_sim_harness.sh`:

```bash
#!/usr/bin/env bash
# Real-binary E2E: download the PINNED native_sim, run the harness against it in a
# temp slot dir, assert the control symlink appears and answers `describe`.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
recipe="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm_26.07.04.bb"
harness="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh"

url="$(sed -nE 's/^SRC_URI = "([^";]*).*/\1/p' "$recipe")"
sha="$(sed -nE 's/^SRC_URI\[sha256sum\] = "([0-9a-f]+)".*/\1/p' "$recipe")"
[ -n "$url" ] && [ -n "$sha" ] || { echo "FAIL: could not read pinned URL/sha from recipe"; exit 1; }

work="$(mktemp -d)"
trap 'kill "${harness_pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

bin="${work}/native-sim-fm"
echo "Downloading pinned native_sim ..."
curl -fsSL "$url" -o "$bin"
echo "${sha}  ${bin}" | sha256sum -c - || { echo "FAIL: sha256 mismatch vs recipe pin"; exit 1; }
chmod +x "$bin"

# Run the ACTUAL harness script against a temp slot dir (proves the shipped script).
slot_dir="${work}/slot1"
SIM_BIN="$bin" SLOT_DIR="$slot_dir" RUNDIR="${work}/run" "$harness" &
harness_pid=$!

for _ in $(seq 1 100); do
    [ -L "${slot_dir}/control" ] && break
    kill -0 "$harness_pid" 2>/dev/null || { echo "FAIL: harness exited early"; exit 1; }
    sleep 0.1
done
[ -L "${slot_dir}/control" ] || { echo "FAIL: control symlink not created"; exit 1; }

# Send describe over the symlinked control pty; capture the MODULE-DESCRIBE line.
resp="$(python3 - "${slot_dir}/control" <<'PY'
import os, sys, select, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
os.write(fd, b"module fm describe\r\n")
buf = b""; deadline = time.time() + 5
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], deadline - time.time())
    if r:
        buf += os.read(fd, 4096)
        if b"MODULE-DESCRIBE" in buf:
            break
os.close(fd)
for ln in buf.splitlines():
    i = ln.find(b"MODULE-DESCRIBE ")
    if i != -1:
        print(ln[i:].decode(errors="replace")); break
PY
)"

echo "response: $resp"
case "$resp" in
    MODULE-DESCRIBE\ *fm_transceiver*) echo "PASS"; exit 0 ;;
    *) echo "FAIL: unexpected describe response"; exit 1 ;;
esac
```

- [ ] **Step 2: Run it to verify it passes (needs L3 + L4 in place; network required)**

Run: `chmod +x tests/sim-harness/test_sim_harness.sh && tests/sim-harness/test_sim_harness.sh`
Expected: ends with `PASS`. (If run before L3/L4 exist, it FAILs reading the recipe/harness — that is the initial red state.)

- [ ] **Step 3: Wire into CI**

Add a job to `.github/workflows/ci.yml`:

```yaml
  sim-harness:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Real-binary harness E2E
        run: tests/sim-harness/test_sim_harness.sh
      - name: Shellcheck harness + pin scripts
        run: |
          sudo apt-get update -qq && sudo apt-get install -y shellcheck
          shellcheck -e SC1091 -e SC2039 \
            meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh \
            tests/sim-harness/test_sim_harness.sh \
            scripts/pin-fw-artifact.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/sim-harness .github/workflows/ci.yml
git commit -m "test(sim): real-binary harness E2E (native_sim pty + describe) in CI"
```

---

### Task L7: release-preflight rejects unpinned/unsigned FM artifacts

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Extends the existing `preflight` job: for each FM-artifact recipe, fail the release if `SRC_URI`/`sha256sum` is a placeholder OR if `cosign verify-blob` of the pinned asset fails. Mirrors the station-agent AUTOREV gate.

- [ ] **Step 1: Add the preflight step**

In `.github/workflows/release.yml`, in the `preflight` job (after the existing station-agent SRCREV check), add:

```yaml
    - name: Install cosign
      uses: sigstore/cosign-installer@v3

    - name: Fail if FM artifacts are unpinned or unsigned
      run: |
        set -euo pipefail
        id_re='^https://github.com/OE5XRX/FW-RemoteStation/\.github/workflows/release\.yml@refs/.+$'
        issuer='https://token.actions.githubusercontent.com'
        recipes="
          meta-oe5xrx-remotestation/recipes-core/oe5xrx-fm-firmware/oe5xrx-fm-firmware_26.07.04.bb
          meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm_26.07.04.bb
        "
        for recipe in $recipes; do
          [ -f "$recipe" ] || { echo "::error::missing $recipe"; exit 1; }
          url="$(sed -nE 's/^SRC_URI = "([^";]*).*/\1/p' "$recipe")"
          sha="$(sed -nE 's/^SRC_URI\[sha256sum\] = "([0-9a-fA-F]*)".*/\1/p' "$recipe")"
          case "$url" in *REPLACE*|"") echo "::error file=$recipe::SRC_URI unpinned"; exit 1;; esac
          printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || { echo "::error file=$recipe::sha256sum unpinned"; exit 1; }
          tmp="$(mktemp -d)"
          curl -fsSL "$url"        -o "$tmp/asset"
          curl -fsSL "$url.bundle" -o "$tmp/asset.bundle"
          echo "${sha}  ${tmp}/asset" | sha256sum -c -
          cosign verify-blob \
            --certificate-identity-regexp "$id_re" \
            --certificate-oidc-issuer "$issuer" \
            --bundle "$tmp/asset.bundle" "$tmp/asset"
          echo "OK — $recipe pinned + cosign-verified"
          rm -rf "$tmp"
        done
```

- [ ] **Step 2: Lint the workflow YAML**

Run: `yamllint .github/workflows/release.yml` (match repo yamllint config; if none, `python -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`).
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): preflight rejects unpinned/unsigned FM artifacts (cosign)"
```

---

### Task L8: 2-minute Proxmox sim-station doc

**Files:**
- Create: `docs/sim-station.md`

- [ ] **Step 1: Write the doc**

`docs/sim-station.md`:

```markdown
# Run a sim station in Proxmox (2 minutes)

The sim image boots the RemoteStation rootfs and starts a simulated FM module
(the pinned `native_sim` from FW-RemoteStation release 26.07.04-01) behind the
canonical slot contract `/dev/oe5xrx/slot1/control` — no hardware required. The
station_agent discovers it exactly as it would a real USB module.

## 1. Build the sim image
    kas build qemux86-64-sim.yml

## 2. Import the disk into Proxmox
Upload `build/tmp/deploy/images/qemux86-64/oe5xrx-remotestation-sim-image-*.wic`
to the node, then:
    qm create 9000 --name oe5xrx-sim --memory 2048 --net0 virtio,bridge=vmbr0
    qm importdisk 9000 oe5xrx-remotestation-sim-image-*.wic local-lvm
    qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0 --boot order=scsi0 --bios ovmf
    qm start 9000

(Local QEMU alternative: `scripts/run-qemu.sh` after pointing it at the sim wic.)

## 3. Verify the slot + describe
On the VM console:
    systemctl status oe5xrx-sim-harness      # active (running)
    ls -l /dev/oe5xrx/slot1/control          # symlink to a /dev/pts/N

Send a describe by hand:
    python3 - <<'PY'
    import os, time
    fd = os.open("/dev/oe5xrx/slot1/control", os.O_RDWR | os.O_NOCTTY)
    os.write(fd, b"module fm describe\r\n"); time.sleep(0.5)
    print(os.read(fd, 4096).decode(errors="replace"))
    PY
    # -> a line: MODULE-DESCRIBE {"schema":1,"module":"fm","identity":{"type":"fm_transceiver",...}}

The station_agent's heartbeat now reports the FM module under `inventory.modules`.

## Notes
- native_sim is dev-only: present only in `oe5xrx-remotestation-sim-image`.
- On real hardware the identical path `/dev/oe5xrx/slot1/control` is created by
  udev (`90-oe5xrx-slots.rules`) from the BusBoard hub port — see
  `docs/slot-contract-parity.md`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/sim-station.md
git commit -m "docs(sim): 2-minute Proxmox sim-station guide"
```

---

### Task L9: slot-contract parity doc

**Files:**
- Create: `docs/slot-contract-parity.md`

- [ ] **Step 1: Write the parity doc**

`docs/slot-contract-parity.md`:

```markdown
# Slot-contract parity: sim vs real

The station_agent consumes ONE canonical path — `/dev/oe5xrx/slotN/control` —
and never touches USB topology. Two populators fill that path identically:

| | Real HW | Sim |
|---|---|---|
| Populator | udev (`90-oe5xrx-slots.rules`) | sim-harness (`sim-harness.sh`) |
| Source | USB hub port `1-1.X` (fixed BusBoard wiring) | pinned native_sim FM binary |
| control endpoint | CDC-ACM `ttyACM*` | native_sim console pty |
| Agent behaviour | scan slots, `describe`, report | **identical** |

## Proving parity without hardware
Real side (udev rule resolves the same symlink for a matching port):
    udevadm verify meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules
    # On a host with a module plugged into hub port 1-1.1:
    udevadm test /sys/bus/usb/devices/1-1.1:1.0/tty/ttyACM0
    #   -> SYMLINK 'oe5xrx/slot1/control'

Sim side (harness resolves the same symlink):
    systemctl status oe5xrx-sim-harness
    readlink -f /dev/oe5xrx/slot1/control    # -> a /dev/pts/N

Both yield `/dev/oe5xrx/slot1/control`; the agent's `slot_discovery` opens that
path unchanged in either case (proven end-to-end by tests/sim-harness against the
real native_sim binary, and by the station_agent slot_discovery tests).
```

- [ ] **Step 2: Commit**

```bash
git add docs/slot-contract-parity.md
git commit -m "docs(sim): slot-contract sim<->real parity"
```

---

# Part B — station-manager (`feature/d2-agent-discovery`)

Worktree: `/home/pbuchegger/OE5XRX/station-manager/.worktrees/d2-agent-discovery`
(This branch already carries the design spec — it rides to main with this PR.)

### Task S1: `slot_discovery` module + describe protocol (TDD)

**Files:**
- Create: `station_agent/slot_discovery.py`
- Test: `tests/test_slot_discovery.py`

**Interfaces:**
- Produces:
  - `describe_slot(control_path: str, timeout: float = 3.0) -> dict | None` — opens the pty, sends `module fm describe\r\n`, returns the parsed JSON dict (keys `schema`, `module`, `identity`, `capabilities`) or `None` on timeout / unparseable / open error.
  - `discover_slots(base: str = "/dev/oe5xrx", timeout: float = 3.0) -> list[dict]` — for each `slotN/control`, returns `{"slot": N, "control": path, "identity": {...}, "capabilities": [...]}`; slots that fail to describe are omitted. Returns `[]` if `base` is absent.

- [ ] **Step 1: Write the failing tests**

`tests/test_slot_discovery.py`:

```python
import json
import os
import threading

from station_agent import slot_discovery

DESCRIBE_JSON = {
    "schema": 1,
    "module": "fm",
    "identity": {"type": "fm_transceiver", "model": "SA818-V", "version": "vhf"},
    "capabilities": [{"name": "frequency", "kind": "setting", "type": "float"}],
}


def _fake_module(slave_fd, stop):
    """Emit a MODULE-DESCRIBE line when it reads 'module fm describe'."""
    buf = b""
    os.write(slave_fd, b"fm> ")
    while not stop.is_set():
        try:
            chunk = os.read(slave_fd, 1024)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if b"module fm describe" in buf:
            line = "MODULE-DESCRIBE " + json.dumps(DESCRIBE_JSON) + "\r\n"
            os.write(slave_fd, line.encode())
            buf = b""


def _pty_with_module():
    master_fd, slave_fd = os.openpty()
    stop = threading.Event()
    t = threading.Thread(target=_fake_module, args=(slave_fd, stop), daemon=True)
    t.start()
    return master_fd, slave_fd, stop, t


def test_describe_slot_parses_identity(tmp_path):
    master_fd, slave_fd, stop, t = _pty_with_module()
    try:
        link = tmp_path / "control"
        link.symlink_to(os.ttyname(master_fd))
        result = slot_discovery.describe_slot(str(link), timeout=3.0)
    finally:
        stop.set()
        os.close(master_fd)
        os.close(slave_fd)
        t.join(timeout=1)
    assert result is not None
    assert result["identity"]["type"] == "fm_transceiver"
    assert result["module"] == "fm"


def test_describe_slot_timeout_returns_none(tmp_path):
    master_fd, slave_fd = os.openpty()  # nobody answers
    try:
        link = tmp_path / "control"
        link.symlink_to(os.ttyname(master_fd))
        result = slot_discovery.describe_slot(str(link), timeout=0.5)
    finally:
        os.close(master_fd)
        os.close(slave_fd)
    assert result is None


def test_describe_slot_missing_path_returns_none(tmp_path):
    assert slot_discovery.describe_slot(str(tmp_path / "nope"), timeout=0.5) is None


def test_discover_slots_missing_base_returns_empty(tmp_path):
    assert slot_discovery.discover_slots(str(tmp_path / "absent")) == []


def test_discover_slots_reports_slot(tmp_path):
    master_fd, slave_fd, stop, t = _pty_with_module()
    try:
        slot_dir = tmp_path / "slot1"
        slot_dir.mkdir()
        (slot_dir / "control").symlink_to(os.ttyname(master_fd))
        slots = slot_discovery.discover_slots(str(tmp_path), timeout=3.0)
    finally:
        stop.set()
        os.close(master_fd)
        os.close(slave_fd)
        t.join(timeout=1)
    assert len(slots) == 1
    assert slots[0]["slot"] == 1
    assert slots[0]["identity"]["type"] == "fm_transceiver"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/pbuchegger/OE5XRX/station-manager/.worktrees/d2-agent-discovery && python -m pytest tests/test_slot_discovery.py -v`
Expected: FAIL — `station_agent.slot_discovery` does not exist.

- [ ] **Step 3: Write the implementation**

`station_agent/slot_discovery.py`:

```python
"""Slot discovery: scan the OE5XRX slot contract, describe smart modules, report inventory.

The slot contract (`/dev/oe5xrx/slotN/control`) is filled identically by udev on real
hardware and by the sim-harness in simulation. This module only ever consumes that path;
it never touches USB topology. See docs/superpowers/specs/2026-07-04-module-simulation-layer-design.md.
"""
from __future__ import annotations

import glob
import json
import logging
import os
import re
import select
import termios
import time
import tty

logger = logging.getLogger(__name__)

_DESCRIBE_CMD = b"module fm describe\r\n"
_DESCRIBE_PREFIX = "MODULE-DESCRIBE "
_SLOT_RE = re.compile(r"slot(\d+)$")


def describe_slot(control_path: str, timeout: float = 3.0) -> dict | None:
    """Open a slot control pty, send `describe`, return the parsed JSON or None."""
    try:
        fd = os.open(control_path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as exc:
        logger.debug("slot describe: cannot open %s: %s", control_path, exc)
        return None
    try:
        try:
            tty.setraw(fd)
        except termios.error:
            pass  # not a tty (e.g. plain file in a test) — proceed anyway
        os.write(fd, _DESCRIBE_CMD)
        buf = b""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            readable, _, _ = select.select([fd], [], [], remaining)
            if not readable:
                continue
            try:
                chunk = os.read(fd, 4096)
            except (BlockingIOError, InterruptedError):
                continue
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            parsed = _extract_describe(buf)
            if parsed is not None:
                return parsed
        logger.debug("slot describe: timeout on %s", control_path)
        return None
    finally:
        os.close(fd)


def _extract_describe(buf: bytes) -> dict | None:
    text = buf.decode("utf-8", errors="replace")
    for line in text.splitlines():
        idx = line.find(_DESCRIBE_PREFIX)
        if idx == -1:
            continue
        payload = line[idx + len(_DESCRIBE_PREFIX):].strip()
        try:
            return json.loads(payload)
        except json.JSONDecodeError:
            continue  # line may be truncated; wait for more bytes
    return None


def discover_slots(base: str = "/dev/oe5xrx", timeout: float = 3.0) -> list[dict]:
    """Scan `base` for slotN/control, describe each, return inventory entries."""
    if not os.path.isdir(base):
        return []
    entries: list[dict] = []
    for control in sorted(glob.glob(os.path.join(base, "slot*", "control"))):
        slot_dir = os.path.basename(os.path.dirname(control))
        match = _SLOT_RE.match(slot_dir)
        if not match:
            continue
        described = describe_slot(control, timeout=timeout)
        if described is None:
            continue
        entries.append({
            "slot": int(match.group(1)),
            "control": control,
            "identity": described.get("identity", {}),
            "capabilities": described.get("capabilities", []),
        })
    return entries
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_slot_discovery.py -v`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add station_agent/slot_discovery.py tests/test_slot_discovery.py
git commit -m "feat(agent): slot discovery + describe protocol"
```

---

### Task S2: config knobs for slot discovery

**Files:**
- Modify: `station_agent/config.py` (`AgentConfig` dataclass + `load_config`)
- Modify: `station_agent/config.example.yml`
- Test: `tests/test_config.py` (create if absent, else extend)

**Interfaces:**
- Produces: `AgentConfig.slot_discovery_enabled: bool = True`, `AgentConfig.slot_dev_base: str = "/dev/oe5xrx"`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_config.py` (create the file if it does not exist; mirror how other config tests build an `AgentConfig`):

```python
from station_agent.config import AgentConfig


def test_slot_discovery_defaults():
    cfg = AgentConfig(
        server_url="https://example.test",
        station_id=1,
        ed25519_key_path="/tmp/k",
    )
    assert cfg.slot_discovery_enabled is True
    assert cfg.slot_dev_base == "/dev/oe5xrx"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest tests/test_config.py::test_slot_discovery_defaults -v`
Expected: FAIL — unexpected keyword / attribute missing.

- [ ] **Step 3: Add the fields**

In `station_agent/config.py`, add to the `AgentConfig` dataclass (after the existing optional fields, matching their default style):

```python
    slot_discovery_enabled: bool = True
    slot_dev_base: str = "/dev/oe5xrx"
```

And in `load_config()`, read them from the parsed YAML mapping alongside the other optional fields (mirror the existing `.get(...)` pattern; use the file's actual local variable name for the mapping):

```python
        slot_discovery_enabled=raw.get("slot_discovery_enabled", True),
        slot_dev_base=raw.get("slot_dev_base", "/dev/oe5xrx"),
```

- [ ] **Step 4: Update the example config**

Append to `station_agent/config.example.yml`:

```yaml
# Module slot discovery (D2). Scans slot_dev_base for slotN/control and reports
# the described module inventory in the heartbeat. Disable on stations with no modules.
slot_discovery_enabled: true
slot_dev_base: /dev/oe5xrx
```

- [ ] **Step 5: Run it to verify it passes**

Run: `python -m pytest tests/test_config.py::test_slot_discovery_defaults -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add station_agent/config.py station_agent/config.example.yml tests/test_config.py
git commit -m "feat(agent): slot discovery config knobs"
```

---

### Task S3: fold module inventory into the heartbeat

**Files:**
- Modify: `station_agent/inventory.py` (`collect_inventory`)
- Modify: `station_agent/heartbeat.py` (`collect_system_info`) and its caller in `station_agent/agent.py`
- Test: `tests/test_slot_inventory_integration.py`

**Interfaces:**
- Consumes: `slot_discovery.discover_slots` (S1), `AgentConfig.slot_discovery_enabled` / `slot_dev_base` (S2).
- Produces: `collect_inventory(config=None)` gains a `"modules"` key (list from `discover_slots`) when discovery is enabled; failures never raise (returns `[]`).

Note: check `collect_inventory`'s current signature. If it takes no args, add an optional `config=None` parameter and thread it from `heartbeat.py::collect_system_info`. Keep backward compatibility (`config=None` → skip discovery, `modules` empty).

- [ ] **Step 1: Write the failing integration test**

`tests/test_slot_inventory_integration.py`:

```python
from station_agent import inventory
from station_agent.config import AgentConfig


def _cfg(**kw):
    return AgentConfig(server_url="https://x.test", station_id=1, ed25519_key_path="/tmp/k", **kw)


def test_collect_inventory_includes_modules(monkeypatch):
    fake = [{"slot": 1, "control": "/dev/oe5xrx/slot1/control",
             "identity": {"type": "fm_transceiver"}, "capabilities": []}]
    monkeypatch.setattr("station_agent.inventory.discover_slots", lambda base, timeout=3.0: fake)
    data = inventory.collect_inventory(config=_cfg(slot_discovery_enabled=True))
    assert data["modules"] == fake


def test_collect_inventory_discovery_disabled(monkeypatch):
    monkeypatch.setattr("station_agent.inventory.discover_slots",
                        lambda base, timeout=3.0: (_ for _ in ()).throw(AssertionError("should not scan")))
    data = inventory.collect_inventory(config=_cfg(slot_discovery_enabled=False))
    assert data.get("modules", []) == []


def test_collect_inventory_discovery_failure_is_swallowed(monkeypatch):
    def boom(base, timeout=3.0):
        raise OSError("device gone")
    monkeypatch.setattr("station_agent.inventory.discover_slots", boom)
    data = inventory.collect_inventory(config=_cfg(slot_discovery_enabled=True))
    assert data.get("modules", []) == []  # did not raise
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python -m pytest tests/test_slot_inventory_integration.py -v`
Expected: FAIL — `discover_slots` not imported into `inventory`, and `collect_inventory` has no `config`/`modules` support.

- [ ] **Step 3: Implement**

In `station_agent/inventory.py`, add the import near the top:

```python
from station_agent.slot_discovery import discover_slots
```

Ensure a module-level `logger = logging.getLogger(__name__)` exists (add `import logging` + the logger if missing). Add a helper:

```python
def _collect_modules(config) -> list:
    if config is None or not getattr(config, "slot_discovery_enabled", False):
        return []
    try:
        return discover_slots(config.slot_dev_base)
    except Exception:  # noqa: BLE001 — discovery must never break the heartbeat
        logger.exception("slot discovery failed")
        return []
```

Change the signature to `def collect_inventory(config=None):` and add to the returned dict:

```python
        "modules": _collect_modules(config),
```

- [ ] **Step 4: Thread config from the heartbeat collector**

In `station_agent/heartbeat.py::collect_system_info`, pass the agent config into `collect_inventory`. If `collect_system_info` does not currently receive config, add a `config=None` parameter and update its caller in `station_agent/agent.py` (the `send_heartbeat`/`collect_system_info` call site) to pass the agent's config attribute (use the actual attribute name in `agent.py`, e.g. `self._config`). Keep the default `None` so existing callers/tests still work.

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_slot_inventory_integration.py tests/test_slot_discovery.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add station_agent/inventory.py station_agent/heartbeat.py station_agent/agent.py tests/test_slot_inventory_integration.py
git commit -m "feat(agent): report module inventory via heartbeat"
```

---

### Task S4: server persists module inventory (test-only; JSONField already accepts it)

**Files:**
- Test: `tests/test_heartbeat_inventory.py` (extend)
- Modify (only if the serializer rejects it): `apps/api/serializers.py`

**Interfaces:**
- Verifies `POST /api/v1/heartbeat/` with `inventory.modules` lands in `StationInventory.data["modules"]`. No production server change expected — `StationInventory.data` is a `JSONField` and `HeartbeatView` stores the whole inventory dict. If the `HeartbeatSerializer` rejects the `modules` key, relax the `inventory` field to pass arbitrary contents (minimal change), then re-run.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_heartbeat_inventory.py` (reuse existing fixtures `station_with_key`, `device_auth_headers`; mirror the existing heartbeat-post test in that file for URL, client, and signing convention):

```python
@pytest.mark.django_db
def test_heartbeat_stores_module_inventory(client, station_with_key):
    import json
    from apps.stations.models import StationInventory

    station, private_key = station_with_key
    payload = {
        "hostname": "sim",
        "inventory": {
            "modules": [
                {"slot": 1, "control": "/dev/oe5xrx/slot1/control",
                 "identity": {"type": "fm_transceiver", "model": "SA818-V"},
                 "capabilities": []}
            ]
        },
    }
    body = json.dumps(payload).encode()
    headers = device_auth_headers(private_key, station.pk, body)
    resp = client.post("/api/v1/heartbeat/", data=body,
                       content_type="application/json", **headers)
    assert resp.status_code == 200
    inv = StationInventory.objects.get(station=station)
    assert inv.data["modules"][0]["identity"]["type"] == "fm_transceiver"
```

(Match the exact header-passing convention and any serializer-required fields used by the sibling test in the file — e.g. `**headers` vs explicit `HTTP_*` kwargs, and whether `hostname`/`os_version`/etc. are required.)

- [ ] **Step 2: Run it**

Run: `python -m pytest tests/test_heartbeat_inventory.py::test_heartbeat_stores_module_inventory -v`
Expected: PASS if the serializer passes inventory through (likely). If FAIL due to serializer validation, make the minimal `HeartbeatSerializer` change to accept arbitrary `inventory` contents, then re-run to PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/test_heartbeat_inventory.py
git add apps/api/serializers.py 2>/dev/null || true
git commit -m "test(server): heartbeat persists module inventory"
```

---

## Verification before completion (both parts)

Run these and confirm real output BEFORE any "done" claim (superpowers:verification-before-completion).

**station-manager (automated, CI-green):**
- [ ] `cd .worktrees/d2-agent-discovery && python -m pytest tests/test_slot_discovery.py tests/test_slot_inventory_integration.py tests/test_config.py tests/test_heartbeat_inventory.py -v` → all pass.
- [ ] `ruff check station_agent/slot_discovery.py` (project linter) → clean.

**linux-image (automated, CI-green):**
- [ ] `tests/sim-harness/test_sim_harness.sh` → `PASS` (real native_sim binary; network required).
- [ ] `scripts/pin-fw-artifact.sh <recipe> <url> --dry-run` for BOTH FM recipes → `cosign verified` and the recipe already carries the printed sha256 (idempotent pin roundtrip).
- [ ] `udevadm verify meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/files/90-oe5xrx-slots.rules` → clean.
- [ ] `shellcheck -e SC1091 -e SC2039` on `scripts/pin-fw-artifact.sh`, `sim-harness.sh`, `tests/sim-harness/test_sim_harness.sh` → clean.
- [ ] `yamllint qemux86-64-sim.yml .github/workflows/ci.yml .github/workflows/release.yml` → clean.

**Cross-repo E2E against the REAL native_sim (proves DoD §9 "E2E gegen native_sim"):**
- [ ] The linux-image `tests/sim-harness/test_sim_harness.sh` job already runs the real binary through the shipped harness script and asserts `describe`. For the agent's OWN code path, additionally run from the station-manager worktree while the real binary runs under the harness in a temp slot dir:
      ```bash
      # terminal 1 (linux-image worktree): start real binary + symlink under /tmp/oe5xrx/slot1
      SIM_BIN=/tmp/native-sim-fm SLOT_DIR=/tmp/oe5xrx/slot1 RUNDIR=/tmp/oe5xrx/run \
        meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh &
      # terminal 2 (station-manager worktree):
      python -c "from station_agent.slot_discovery import discover_slots; import json; print(json.dumps(discover_slots('/tmp/oe5xrx'), indent=2))"
      ```
      → prints one slot with `identity.type == "fm_transceiver"`, confirming the SAME agent code path works against the real native_sim.
- [ ] (Optional, strongest) Build `oe5xrx-remotestation-sim-image`, boot in QEMU/Proxmox per `docs/sim-station.md`, confirm `systemctl status oe5xrx-sim-harness` active and the agent heartbeat reports `inventory.modules`.

## Definition of Done (spec §9) — traceability
- Release assets (real `.bin` + `native_sim`) pinned by URL+sha256, cosign-verified, bundled into the image → **L2 + L3** (+ L7 preflight gate).
- linux-image starts native_sim FM as a service; `slot1/control` materialized → **L3 + L4 + L5**.
- Agent opens `slot1/control` + `describe` E2E against native_sim (no HW) → **S1 + S3 + L6 real-binary test + cross-repo E2E**.
- Agent path identical to udev on real HW (parity checked; udev ruleset exists + udevadm-tested) → **L1 + L9**.
- Doc: 2-minute "start sim station in Proxmox" → **L8**.
- CI green → **L1/L6/L7 gates + S1–S4 pytest**.

## PR handoff
- **linux-image** PR: title references D2, body `Closes #23`. Squash-merge.
- **station-manager** PR: carries the spec (`docs/superpowers/specs/2026-07-04-module-simulation-layer-design.md`) + agent discovery; body references the spec and links the linux-image PR. Squash-merge.
- After each PR: run copilot-loop (4min initial, 1min poll, 10min total; code-quality on Opus), address findings.

## Self-review notes (author)
- Spec coverage: §3 slot contract → L1/L4; §3a udev → L1; §3b harness → L4; §3c parity → L9; §4 manifest (camp-slice = harness default, no manifest) → L4/L5; §7 camp-slice (1 slot, harness-default) → L4/L5; §8 datenfluss → S1/S3; §9 DoD → traceability above; §10 "native_sim in prod" risk → L3/L5 dev-only gating; §11 testing (native_sim integration, udevadm, parity, pin-roundtrip) → L6/L1/L9/L2-L3-L7.
- Task-scope coverage: pin real `.bin` (DFU source) → L2; pin native_sim → L3; cosign-verify before embedding → pin-fw-artifact.sh (L2) + preflight (L7); URL+sha256 from SHA256SUMS → L2/L3 exact values; harness materializes slot1/control → L4; udev ruleset udevadm-tested → L1; agent discover+describe+report → S1/S3/S4.
- Out of scope confirmed absent: no audio/snd-aloop, no DFU-sim (only bundling the `.bin`), no multi-slot/manifest, no server manifest generator, no control-command translation.
- Key correction vs the prior draft (now superseded): the shipped `26.07.04-01` `native_sim` is describe-capable and self-creates its console pty — verified by running the real binary — so there is NO socat bridge and NO self-published linux-image artifact; we pin the FW-RemoteStation release assets directly (real `.bin` + native_sim), cosign-verified.
```