# OE5XRX Linux Image

[![CI](https://github.com/OE5XRX/linux-image/actions/workflows/ci.yml/badge.svg)](https://github.com/OE5XRX/linux-image/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Yocto](https://img.shields.io/badge/Yocto-Scarthgap_5.0-brightgreen)](https://docs.yoctoproject.org/scarthgap/)

Yocto-based Linux image for the [OE5XRX Amateurfunkclub für Remote
Stationen](https://www.oe5xrx.at) (Austria) remote amateur radio station
fleet. Each station runs a Raspberry Pi Compute Module 4 connected to a
custom STM32 mainboard plus pluggable RF/audio modules.

The image is paired with the [station-manager][sm] server which handles
fleet management, OTA rollouts, live monitoring, and a browser-based
remote terminal.

[sm]: https://github.com/OE5XRX/station-manager

---

## Design highlights

- **A/B root filesystems** with bootcount + automatic rollback. A bad
  update reverts to the previous known-good slot after three failed boot
  attempts.
- **Read-only rootfs** with a dedicated persistent `data` partition.
  `/var`, `/home`, `/root` and `/etc/station-agent` are bind-mounted
  onto it so application state survives rootfs swaps.
- **Bootloader abstraction** — U-Boot on the Raspberry Pi target,
  GRUB-EFI on the x86-64 target. Both expose the same three env vars
  (`boot_part`, `bootcount`, `upgrade_available`) so the station agent
  doesn't care which board it's running on.
- **Station-agent integrated** as a Yocto recipe. Pulls directly from
  the `station-manager` repo's `station_agent/` subdir at build time.
- **On-demand CI builds** on Hetzner Cloud — a fresh CX43 server is
  spun up, builds the image into a persistent sstate-cache volume,
  uploads the artifact, and is deleted. About €0.02 per build after
  the cache is warm.

---

## Targets

| Machine | Config | Purpose |
|---------|--------|---------|
| `qemux86-64` | [`qemux86-64.yml`](qemux86-64.yml) | Development image, bootable in QEMU. GRUB-EFI + full A/B layout for offline testing. |
| `raspberrypi4-64` | [`raspberrypi4-64.yml`](raspberrypi4-64.yml) | Production image for Raspberry Pi Compute Module 4. U-Boot + A/B + read-only rootfs. |

Both targets share everything via `oe5xrx.yml`; only machine-specific
bits differ.

---

## Building locally

Prerequisites:

- [Kas](https://kas.readthedocs.io/) (`pip install kas`)
- Standard Yocto dependencies (see the [Yocto quick build
  guide](https://docs.yoctoproject.org/brief-yoctoprojectqs/))
- ~50 GB free disk for build + sstate-cache

```bash
# QEMU x86-64 (fast, useful for iterating)
kas build qemux86-64.yml

# Raspberry Pi CM4 (production)
kas build raspberrypi4-64.yml
```

Outputs land in `build/tmp/deploy/images/<machine>/`.

### Booting the qemux86-64 image in QEMU

```bash
IMG=$(ls build/tmp/deploy/images/qemux86-64/*.wic | head -1)
qemu-system-x86_64 \
    -enable-kvm -cpu IvyBridge -machine q35 \
    -m 2048 -smp 2 -nographic -serial mon:stdio \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=ovmf-vars.fd \
    -drive file="$IMG",if=virtio,format=raw \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=n0
```

SSH in once booted: `ssh -p 2222 root@localhost`

---

## CI

Two workflows:

- **`ci.yml`** — runs on every pull request and push to `main`. Parses
  all kas configs with `kas dump`, shellchecks the scripts, yamllints
  the YAML, sanity-checks the wks files. No Hetzner, no artifact.
- **`build.yml`** — runs on tag pushes (`v*`) and manual dispatch.
  Full Yocto build on an on-demand Hetzner CX43. Uploads the image
  artifact with 7-day retention.

### Required GitHub Secrets

| Secret | Used by | Description |
|--------|---------|-------------|
| `HCLOUD_TOKEN` | `build.yml` | Hetzner Cloud API token |
| `HCLOUD_SSH_KEY_NAME` | `build.yml` | Name of an SSH key registered in Hetzner Cloud (for logging into the build server) |
| `HCLOUD_SSH_PRIVATE_KEY` | `build.yml` | Private half of the above key, used by GitHub's runner |
| `GH_PAT` | `build.yml` | Personal access token with `repo` scope — used to fetch a short-lived runner registration token |

The build server is disposable; only sstate-cache and download caches
are persisted via a named Hetzner volume (`oe5xrx-yocto-cache`).

---

## Image contents

Each image ships with:

- [`station-agent`](https://github.com/OE5XRX/station-manager/tree/main/station_agent)
  — management agent (heartbeat, OTA, remote terminal). Authenticates
  via Ed25519 signatures.
- Python 3 + agent runtime dependencies
- OpenSSH, dfu-util (STM32 flashing), i2c-tools, htop
- systemd as init
- GRUB-EFI (x86) or U-Boot (RPi) with A/B boot logic

---

## Repository layout

```
.
├── oe5xrx.yml                           shared kas config
├── qemux86-64.yml                       x86-64 target
├── raspberrypi4-64.yml                  RPi CM4 target
├── include/raspberrypi.yml              meta-raspberrypi glue
├── meta-oe5xrx-remotestation/
│   ├── conf/layer.conf
│   ├── recipes-bsp/
│   │   ├── grub/                        grub-efi bbappend + embedded cfg
│   │   ├── grub-ab/                     seed grubenv with A/B defaults
│   │   └── u-boot-ab/                   U-Boot A/B boot.scr + fw_env.config
│   ├── recipes-core/
│   │   ├── ab-layout/                   systemd mount units + first-boot init
│   │   ├── base-files/                  fstab tweaks (RPi)
│   │   ├── images/                      production + development images
│   │   └── station-agent/               agent recipe
│   └── wic/                             partition layouts (x64 + RPi)
└── .github/workflows/
    ├── ci.yml                           fast PR / main checks
    └── build.yml                        full Hetzner build (tags + dispatch)
```

---

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b fix/my-thing`)
3. Commit, push, open a PR
4. Wait for `ci.yml` to go green — it enforces recipe parsing, shellcheck, yamllint
5. A maintainer reviews + merges (squash or rebase; no merge commits)

The `main` branch is protected — direct pushes are blocked, every
change goes through PR review.

### Releases

Tags `vX.Y.Z` trigger a full build + artifact upload. That's how you
ship a stable image.

```bash
git tag v1.0.0
git push origin v1.0.0
```

---

## License

[GPL-3.0-or-later](LICENSE). Same spirit as the Linux kernel + GNU
userland that the image is built from — improvements flow back to the
community.
