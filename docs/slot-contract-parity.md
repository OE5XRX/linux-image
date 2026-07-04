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
