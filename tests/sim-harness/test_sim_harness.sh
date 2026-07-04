#!/usr/bin/env bash
# Real-binary E2E: download the PINNED native_sim, run the harness against it in a
# temp slot dir, assert the control symlink appears and answers `describe`.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
recipe="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm_26.07.04.bb"
harness="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh"

url="$(sed -nE 's/^SRC_URI = "([^";]*).*/\1/p' "$recipe")"
sha="$(sed -nE 's/^SRC_URI\[sha256sum\] = "([0-9a-f]+)".*/\1/p' "$recipe")"
if [ -z "$url" ] || [ -z "$sha" ]; then echo "FAIL: could not read pinned URL/sha from recipe"; exit 1; fi

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
    if [ -L "${slot_dir}/control" ]; then
        break
    fi
    if ! kill -0 "$harness_pid" 2>/dev/null; then
        echo "FAIL: harness exited early"
        exit 1
    fi
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
        idx = buf.find(b"MODULE-DESCRIBE")
        if idx != -1 and b"\n" in buf[idx:]:
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
