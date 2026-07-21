#!/bin/sh
# OE5XRX sim harness (qemux86-64/Proxmox, D2 camp-slice).
# Runs the pinned native_sim FM binary. native_sim self-creates two ptys and
# announces them on stdout:
#   uart connected to pseudotty: /dev/pts/N     <- console/shell  (slot1/control)
#   uart_1 connected to pseudotty: /dev/pts/M   <- SA818 radio link
# We symlink the CONSOLE pty at the canonical slot-contract path
# /dev/oe5xrx/slot1/control, and attach exactly ONE SA818 AT-emulator to the
# radio-link pty so that `set`-type commands (which native_sim translates into
# real SA818 AT commands like AT+DMOSETGROUP) get answered — otherwise they
# driver_error on an unanswered UART. This is the SIM populator; on real HW udev
# creates the identical slot path (spec §3c) and a real SA818 answers the AT
# link. No socat: native_sim owns the ptys.
#
# Lifecycle: this script owns BOTH children (native_sim + the SA818 emulator).
# systemd owns this script. The cleanup trap kills both on every exit path, so
# there can never be a stray/duplicate emulator on the radio pty — duplicate
# emulators each answer every command and desync the AT request/response stream.
#
# SLOT_DIR is overridable for host testing (default is the canonical /dev path).
set -eu

SIM_BIN="${SIM_BIN:-/usr/libexec/oe5xrx/native-sim-fm}"
SA818_SIM="${SA818_SIM:-/usr/libexec/oe5xrx/sa818-sim.py}"
SLOT_DIR="${SLOT_DIR:-/dev/oe5xrx/slot1}"
SLOT_LINK="${SLOT_DIR}/control"
RUNDIR="${RUNDIR:-/run/oe5xrx/native-sim-fm}"
LOG="${RUNDIR}/sim.log"
SA818_LOG="${RUNDIR}/sa818-sim.log"

[ -x "$SIM_BIN" ] || { echo "sim-harness: native_sim binary missing: $SIM_BIN" >&2; exit 1; }

mkdir -p "$SLOT_DIR" "$RUNDIR"
cd "$RUNDIR"
: > "$LOG"

# Start native_sim, stdout+stderr to a regular file (never blocks the child).
"$SIM_BIN" > "$LOG" 2>&1 &
SIM_PID=$!
SA818_PID=""

cleanup() {
    rm -f "$SLOT_LINK"
    if [ -n "$SA818_PID" ]; then
        kill "$SA818_PID" 2>/dev/null || true
    fi
    kill "$SIM_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# Resolve a native_sim pty announcement line to its /dev/pts path, waiting up to
# ~10s. $1 is the exact announcement prefix. Prints the pty path on success.
wait_pty() {
    _prefix="$1"
    _j=0
    while [ "$_j" -lt 100 ]; do
        _line="$(grep -m1 "^${_prefix}" "$LOG" 2>/dev/null || true)"
        if [ -n "$_line" ]; then
            printf '%s' "${_line#"$_prefix"}"
            return 0
        fi
        kill -0 "$SIM_PID" 2>/dev/null || { echo "sim-harness: native_sim exited early; log:" >&2; cat "$LOG" >&2; return 1; }
        sleep 0.1
        _j=$((_j + 1))
    done
    return 1
}

# --- SA818 radio-link emulator (uart_1) ------------------------------------
# Attach it FIRST/EARLY so native_sim's startup AT handshake is answered.
UART1="$(wait_pty 'uart_1 connected to pseudotty: ' || true)"
if [ -z "$UART1" ] || [ ! -e "$UART1" ]; then
    echo "sim-harness: no SA818 (uart_1) pty found; log:" >&2
    cat "$LOG" >&2
    exit 1
fi
if command -v python3 >/dev/null 2>&1 && [ -f "$SA818_SIM" ]; then
    # python3 -u: unbuffered, so sa818-sim.log reflects the AT exchange live.
    python3 -u "$SA818_SIM" "$UART1" > "$SA818_LOG" 2>&1 &
    SA818_PID=$!
    echo "sim-harness: SA818 emulator on $UART1 (pid $SA818_PID)" >&2
else
    echo "sim-harness: WARNING python3 or $SA818_SIM missing — SA818 link unanswered; set commands will driver_error" >&2
fi

# --- console pty -> slot1/control ------------------------------------------
PTY="$(wait_pty 'uart connected to pseudotty: ' || true)"
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
