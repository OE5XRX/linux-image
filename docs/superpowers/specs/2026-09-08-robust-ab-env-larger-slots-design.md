# Robust A/B U-Boot Env + Larger Symmetric Slots + data-grow — Design

Date: 2026-09-08
Status: Approved (design), pending implementation plan
Repo: `linux-image` (with a follow-up guard note for `station-manager`)

## Problem

OTA upgrades on the Raspberry Pi / CM4 (u-boot) target fail at the
**trial-boot arming step**. The agent writes the new rootfs to the
inactive slot successfully, then `set_upgrade_pending()` calls
`fw_setenv` and it fails with:

```
Cannot read environment, using default
Cannot read default environment from file
```

so the deployment ends as *"Failed to write firmware to inactive
partition"* (a generic catch-all). This affected every deployment
(observed on station 192.168.88.211: deployments 23, 27, 28).

### Root cause (proven)

The u-boot environment on-device is written in **single (non-redundant)
format**: `[CRC32 4B][data…]`. Verified by CRC math on the raw
`uboot_env` partition — the stored CRC (`0x29bf51db`) matches
`crc32(bytes[4:])` (single layout) and does **not** match
`crc32(bytes[5:])` (redundant layout, which has a 1-byte flags field
after the CRC).

But `/etc/fw_env.config` declares **two partitions = redundant mode**,
so `fw_printenv`/`fw_setenv` expect the flags byte, compute the CRC
over the wrong byte range, get a mismatch, and refuse to read/write.

Confirmed the fix direction read-only on the live station: pointing
`fw_printenv` at a **single-mode** config read the env correctly
(`boot_part=a, bootcount=3, upgrade_available=0`, rc=0).

The design intent was redundant (the wks reserves `uboot_env` +
`uboot_envr`, and `recipes-bsp/u-boot/files/oe5xrx-env.cfg` sets
`CONFIG_ENV_REDUNDANT=y`), but the built u-boot only picks
up the MMC part of the fragment (`ENV_IS_IN_MMC` + `ENV_OFFSET` — those
work; the station reads/writes at the raw offset) and **drops the
redundant part** (`ENV_REDUNDANT` + `ENV_OFFSET_REDUND`).
Classic `merge_config` behaviour: an **unknown** symbol is silently
discarded. The trap: the fragment historically set the pre-rename name
`CONFIG_SYS_REDUNDAND_ENVIRONMENT`, which u-boot 2026.01 renamed to
`CONFIG_ENV_REDUNDANT` — so the old key merged to nothing and redundancy
stayed at its default `n`. The build guard below now enforces the
current name so this cannot silently regress again.

The config is byte-identical between `2026.07.25` and `2026.09.06`, so
this is a **latent, fleet-wide** bug on the u-boot target. It never
surfaced in CI because the boot-OTA integration test runs on
`qemux86-64`, which uses GRUB (`grub-editenv`), not u-boot.

## Decision: fix it "properly" — redundant done right

We keep the redundant design (power-fail-safe env writes — the right
choice for an unattended remote station whose `boot.cmd` does
`saveenv` on every boot) and make the build actually deliver it. In
the same reflash-forcing change we also **enlarge the rootfs slots**
and **implement the missing `data-grow`** so one image fits both an
8 GB CM4 eMMC and a large SD card.

Sizing rationale (8 GB eMMC is the production floor; A/B doubles every
rootfs GB): `root_a/root_b = 2.5 GB` gives ~5× headroom over the
current dev rootfs (460 MB used of a 957 MB fs) while leaving ~2.1 GB
for a grown `data` on 8 GB eMMC. OTA install cost scales with slot size
(the agent decompresses on the fly and writes the full raw slot to the
block device — ~3.75 min/GB on SD, faster on eMMC); the compressed
transfer (~150 MB `.rootfs.bz2`) is unaffected. 2.5 GB ≈ ~9 min
install on SD — acceptable.

## Scope — three workstreams + rollout

### 1. Redundant u-boot env (rpi / u-boot only)

- **Diagnose** at build time: inspect `${B}/.config` from a real
  u-boot build to confirm *why* `CONFIG_ENV_REDUNDANT` is
  dropped (dependency / env-location choice / symbol ordering).
- **Fix** `recipes-bsp/u-boot/files/oe5xrx-env.cfg` so the redundant
  symbols land: `CONFIG_ENV_IS_IN_MMC=y`, `CONFIG_ENV_OFFSET`,
  `CONFIG_ENV_REDUNDANT=y`, `CONFIG_ENV_OFFSET_REDUND`.
  Adjust whatever dependency/choice the diagnosis reveals (e.g.
  explicitly disabling `CONFIG_ENV_IS_IN_FAT` if the env-location
  choice is the blocker).
- **Build guard** (defense-in-depth, matches project culture —
  template-comment guard, AUTOREV preflight): a `do_configure:append`
  in the u-boot bbappend greps `${B}/.config` and **fails the build**
  if `CONFIG_ENV_REDUNDANT=y` is absent. This makes the
  invariant self-enforcing against future silent regression.
- `fw_env.config` stays two-line / redundant — it was correct all
  along; no change.
- **Offsets unchanged:** `uboot_env`/`uboot_envr` precede the root
  slots, so `CONFIG_ENV_OFFSET=0x4005000` /
  `CONFIG_ENV_OFFSET_REDUND=0x4105000` remain valid after resizing
  root (see §2).

Fallback: if the diagnosis shows the fragment approach can't reliably
carry the symbol, switch to a full custom `rpi_oe5xrx_defconfig`. The
build guard stays regardless.

### 2. Larger symmetric slots (rpi + x64)

Both `meta-oe5xrx-remotestation/files/wic/`:
- `oe5xrx-remotestation-ab.wks.in` (rpi):
  `root_a`/`root_b` `--fixed-size 1024 → 2560`;
  `data` `--fixed-size 2048 → 512` (small at build, grows on first
  boot — see §3).
- `oe5xrx-remotestation-ab-x64.wks.in` (x64):
  `root_a`/`root_b` `--fixed-size 1024 → 2560`;
  `data` `--fixed-size 2048 → 512`.
- `firmware`, `efi`, `uboot_env`, `uboot_envr` **unchanged** → every
  absolute offset stays put.

8 GB eMMC budget (≈7.3 GiB usable): `2560 ×2 + ~70 MB` fixed +
grown `data` ~2.1 GB → fits. Build-time wic stays small (data 512 MB)
so it flashes onto the smallest 8 GB eMMC with margin; `data` then
grows to fill whatever medium is present (≈26 GB on a 32 GB SD).

x64 uses GRUB env (a file under the EFI/GRUB partition), so the
redundant-env work of §1 does **not** apply there; x64 only gets the
size changes to stay symmetric.

### 3. `data-grow.service` (both machines)

The missing service the code already anticipates (`data-init.sh`
comment references a *"separate data-grow.service (run once, behind a
sentinel)"*). Add it to `recipes-core/ab-layout`:

- **oneshot**, **sentinel-guarded** (a marker file on `/mnt/data` so it
  runs exactly once), **robust-fail** (grow failure must never break
  boot — the documented reason for keeping it separate from
  `data-init`).
- Steps: move the GPT backup header to the end of the (larger) device
  (`sgdisk -e` — the QEMU misplaced-backup-header caveat the comment
  warns about), grow the last partition (`data`) to fill the device,
  then `resize2fs` (online, on mounted `/mnt/data`).
- Ordered after `mnt-data.mount`; wired via `SYSTEMD_SERVICE` like the
  other units.
- Add `gptfdisk` (sgdisk) to `RDEPENDS` if the chosen tool needs it
  (`parted`/`e2fsprogs-resize2fs` already present).

### 4. Rollout / migration

- **One-time reflash of all stations.** Larger slots cannot be
  delivered via OTA (a 2.5 GB image will not fit an existing 1 GB
  slot — exactly the `install_to_slot` ENOSPC we must avoid).
- **No env-migration tooling needed:** a correctly-built redundant
  u-boot self-initializes its redundant env on first boot (empty env
  partitions → built-in default env → first `saveenv` writes redundant
  format). The reflash gives us redundant env "for free".
- Station 192.168.88.211 (the live-patched dev box) is reflashed too;
  its temporary single-mode `fw_env.config` patch on `root_b` becomes
  moot.
- After reflash, normal OTA (arm → trial → commit → auto-rollback)
  works end-to-end.

## Testing

- **Build guard** proves `CONFIG_ENV_REDUNDANT=y` in the
  built `.config` on every u-boot build.
- **Boot-OTA integration test** (existing, `qemux86-64`): keep GRUB
  path green; extend to assert the post-OTA commit clears the trial
  flags. Add a u-boot/qemuarm64-flavoured check if feasible so the
  redundant path gets CI coverage (it currently has none).
- **`data-grow` on QEMU**: verify it survives the misplaced GPT backup
  header and grows `data` without hanging.
- **Real CM4 (HIL honesty rule — necessary, not just sim-green):**
  - `fw_printenv` reads the env with the shipped two-line redundant
    `fw_env.config` (flags byte present, CRC valid).
  - Full OTA cycle: arm → reboot → trial boot → agent commit
    (`upgrade_available=0, bootcount=0`) → durable; and a forced-fail
    trial rolls back after `bootlimit`.
  - `data` fills the eMMC after first boot.
  - Slots are 2.5 GB; a real 2.5 GB rootfs OTA installs and boots.

## Risks & mitigations

- **Exact redundant-drop cause unknown until a diagnostic build** —
  treat §1 diagnosis as a spike; if the fragment can't carry it, fall
  back to a full defconfig (guard stays either way).
- **parted/sgdisk hang on QEMU** (misplaced GPT backup) — `sgdisk -e`
  first + robust-fail; grow failure never blocks boot.
- **8 GB eMMC size variance across vendors** — keep build-time `data`
  small (512 MB) so the wic comfortably fits the smallest 8 GB part;
  `data-grow` handles the rest.
- **Rootfs growth beyond ~1.5 GB** (heavy audio/ML) would make 8 GB
  eMMC tight (2.5 GB ×2 = 5 GB roots); document 16 GB eMMC as the
  escape hatch for such stations.

## Out of scope

- Content-proportional OTA writes (rsync/sized-to-content instead of
  full-slot raw write) — a larger OTA redesign; note as future work.
- Reducing `saveenv`-every-boot frequency (flash wear) — negligible at
  station boot cadence; redundant env already handles the power-fail
  window.
- `station-manager` changes — none required; the server already
  extracts `root_a` by its actual partition size, so a larger slot
  produces a correspondingly larger artifact automatically.
