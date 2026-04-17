# OE5XRX Linux Image

Yocto-based Linux image for OE5XRX remote amateur radio stations.

## Targets

| Machine | Config | Description |
|---------|--------|-------------|
| `qemux86-64` | `qemux86-64.yml` | x64 test image for QEMU (development/CI) |
| `raspberrypi4-64` | `raspberrypi4-64.yml` | Raspberry Pi CM4 production image |

## Building locally

Prerequisites: [Kas](https://kas.readthedocs.io/) + Yocto dependencies

```bash
# x64 test image
kas build qemux86-64.yml

# RPi CM4 image
kas build raspberrypi4-64.yml
```

## CI Build

Push to `main` triggers an automated build via GitHub Actions using an
on-demand Hetzner Cloud server (CX42). The server is created, builds the
image, uploads artifacts, and is deleted automatically.

Manual trigger: Actions → "Build Yocto Image" → Run workflow → Select machine

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `HCLOUD_TOKEN` | Hetzner Cloud API token |
| `HCLOUD_SSH_KEY_NAME` | Name of SSH key registered in Hetzner Cloud |
| `GH_RUNNER_TOKEN` | GitHub Actions runner registration token |

## Image contents

- **Station Agent** — OE5XRX management agent (heartbeat, OTA, terminal)
- **Python 3** — Agent runtime
- **OpenSSH** — Remote access
- **dfu-util** — STM32 module firmware updates
- **i2c-tools** — Hardware module communication
- **systemd** — Init system

## Custom Layer: meta-oe5xrx-remotestation

- `recipes-core/images/` — Image definitions (prod + dev)
- `recipes-core/station-agent/` — Station Agent recipe + systemd service
