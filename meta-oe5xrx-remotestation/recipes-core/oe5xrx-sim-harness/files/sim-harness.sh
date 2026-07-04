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

if [ -z "$PTY" ] || [ ! -e "$PTY" ]; then
    echo "sim-harness: no console pty found; log:" >&2
    cat "$LOG" >&2
    exit 1
fi

ln -sf "$PTY" "$SLOT_LINK"
chmod 660 "$PTY" 2>/dev/null || true
echo "sim-harness: slot1/control -> $PTY (native_sim pid $SIM_PID)" >&2

# Own the service lifecycle: block until native_sim exits (systemd sends TERM).
wait "$SIM_PID"
