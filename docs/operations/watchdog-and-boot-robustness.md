# Watchdog and Boot Robustness

## How it works

Panics and hangs trigger reboots; the existing A/B `bootcount` machinery rolls
back a bad slot with no human intervention.

Three layers cooperate:

1. **Kernel cmdline** (`panic=5 softlockup_panic=1`): kernel panics reboot
   after 5 s; soft-lockups trigger a panic.
2. **sysctl drop-in** (`50-oe5xrx-panic.conf`): `hung_task_panic=1` turns
   silent hung tasks into panics; `hung_task_timeout_secs=60` sets the timeout.
3. **Hardware watchdog** (`/dev/watchdog`): systemd pets it every 30 s
   (`RuntimeWatchdogSec=30` in `watchdog.conf`). If systemd or the whole box
   wedges, the watchdog fires a hard reset after ~30 s.

## Proxmox VMs

Add a watchdog device to every VM that runs the OE5XRX image:

- **Hardware** tab > **Add** > **Watchdog**
- Model: `i6300esb`
- Action: `reset`

Without this, the VM has no hardware watchdog and a hung guest stays hung
indefinitely instead of resetting.

## RPi CM4

The BCM2835 SoC watchdog (`watchdog@7e100000`) is armed by u-boot before the
kernel is loaded (`wdt dev watchdog@7e100000; wdt start 15000`). This covers
the pre-systemd window where a DTB or initrd hang could stall the boot
indefinitely. The 15 s u-boot timeout is intentionally longer than the kernel
boot window; systemd's 30 s pet interval takes over once userspace is running.

## QEMU (development)

`scripts/run-qemu.sh` passes `-watchdog i6300esb -watchdog-action reset` so a
guest hang triggers a VM reset locally, matching Proxmox behaviour. The
watchdog stays disarmed until the guest driver arms it — running the script
without a watchdog-aware image is safe.
