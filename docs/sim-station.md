# Run a sim station in Proxmox (2 minutes)

The qemux86-64 image boots the RemoteStation rootfs and starts a simulated FM
module (the pinned `native_sim` from FW-RemoteStation release 26.07.04-01) behind
the canonical slot contract `/dev/oe5xrx/slot1/control` — no hardware required.
The station_agent discovers it exactly as it would a real USB module.

The simulation stack is part of the **standard qemux86-64 image**: a Proxmox/VM
deployment has no real FM hardware, so the simulator is the module. (It is x86-only
via `COMPATIBLE_MACHINE`, so it never lands in the Raspberry Pi hardware image.)

## 1. Build the image
    kas build qemux86-64.yml

## 2. Import the disk into Proxmox
Upload `build/tmp/deploy/images/qemux86-64/oe5xrx-remotestation-image-*.wic`
to the node, then:
    qm create 9000 --name oe5xrx-sim --memory 2048 --net0 virtio,bridge=vmbr0
    qm importdisk 9000 oe5xrx-remotestation-image-*.wic local-lvm
    qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0 --boot order=scsi0 --bios ovmf
    qm start 9000

(Local QEMU alternative: `scripts/run-qemu.sh` after pointing it at the wic.)

## 3. Verify the slot + describe
On the VM console:
    systemctl status oe5xrx-sim-harness      # active (running)
    ls -l /dev/oe5xrx/slot1/control          # symlink to a /dev/pts/N

Enumerate + describe by hand (the firmware is self-describing):
    python3 - <<'PY'
    import os, time
    fd = os.open("/dev/oe5xrx/slot1/control", os.O_RDWR | os.O_NOCTTY)
    def cmd(c):
        os.write(fd, c + b"\r\n"); time.sleep(0.5)
        return os.read(fd, 4096).decode(errors="replace")
    print(cmd(b"module list"))            # -> MODULE-LIST {"modules":["fm"]}
    print(cmd(b"module fm describe"))      # -> MODULE-DESCRIBE {"schema":1,"module":"fm",...}
    PY

The station_agent's heartbeat now reports the module inventory under
`inventory.modules` (each slot lists its modules with identity + capabilities).

## Notes
- The sim stack (native_sim + sim-harness) ships in every qemux86-64 image; it is
  x86-only (`COMPATIBLE_MACHINE = "qemux86-64"`) and never reaches the RPi image.
- On real hardware the identical path `/dev/oe5xrx/slot1/control` is created by
  udev (`90-oe5xrx-slots.rules`) from the BusBoard hub port — see
  `docs/slot-contract-parity.md`.
