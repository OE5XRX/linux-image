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
