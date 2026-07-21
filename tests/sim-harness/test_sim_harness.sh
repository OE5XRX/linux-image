#!/usr/bin/env bash
# Real-binary E2E: download the PINNED native_sim, run the harness against it in a
# temp slot dir, assert the control symlink appears and answers `describe`.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
recipe="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm.bb"
harness_recipe="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/oe5xrx-sim-harness_1.0.bb"
harness="${repo_root}/meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/files/sim-harness.sh"
inc="${repo_root}/meta-oe5xrx-remotestation/conf/oe5xrx-fw-release.inc"

# The release tag is single-sourced in the include; recipe SRC_URIs interpolate it,
# so reconstruct the asset URLs here the same way BitBake would (base/tag/asset).
url_base="$(sed -nE 's/^FW_RELEASE_URL_BASE[[:space:]]*\?=[[:space:]]*"([^"]+)".*/\1/p' "$inc")"
tag="$(sed -nE 's/^FW_RELEASE_TAG[[:space:]]*\?=[[:space:]]*"([^"]+)".*/\1/p' "$inc")"
if [ -z "$url_base" ] || [ -z "$tag" ]; then echo "FAIL: could not read FW_RELEASE_URL_BASE/TAG from $inc"; exit 1; fi

# sha regexes tolerate flexible spacing and hex case (normalized to lowercase) so a
# harmless recipe reformat never false-fails the test.
url="${url_base}/${tag}/fm-sa818-2m.native_sim"
sha="$(sed -nE 's/^SRC_URI\[sha256sum\][[:space:]]*=[[:space:]]*"([0-9a-fA-F]+)".*/\1/p' "$recipe" | tr 'A-F' 'a-f')"
if [ -z "$sha" ]; then echo "FAIL: could not read native_sim sha from recipe"; exit 1; fi

# The SA818 emulator is pinned as a co-versioned FW release asset (same tag). Download
# the EXACT pinned bytes so the test exercises what the image ships.
sa818_url="${url_base}/${tag}/fm-sa818-2m.sa818-sim.py"
sa818_sha="$(sed -nE 's/^SRC_URI\[sa818sim\.sha256sum\][[:space:]]*=[[:space:]]*"([0-9a-fA-F]+)".*/\1/p' "$harness_recipe" | tr 'A-F' 'a-f')"
if [ -z "$sa818_sha" ]; then echo "FAIL: could not read SA818 sha from harness recipe"; exit 1; fi

work="$(mktemp -d "${TMPDIR:-/tmp}/sim-harness.XXXXXX")"
trap 'kill "${harness_pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

bin="${work}/native-sim-fm"
echo "Downloading pinned native_sim ..."
curl -fsSL "$url" -o "$bin"
echo "${sha}  ${bin}" | sha256sum -c - || { echo "FAIL: sha256 mismatch vs recipe pin"; exit 1; }
chmod +x "$bin"

sa818_sim="${work}/sa818-sim.py"
echo "Downloading pinned SA818 emulator ..."
curl -fsSL "$sa818_url" -o "$sa818_sim"
echo "${sa818_sha}  ${sa818_sim}" | sha256sum -c - || { echo "FAIL: sha256 mismatch vs harness recipe pin"; exit 1; }

# Run the ACTUAL harness script against a temp slot dir (proves the shipped script).
# Point SA818_SIM at the shipped emulator so the harness attaches it to uart_1 —
# exercising the real path where `set` commands are answered (they'd otherwise
# driver_error on the unanswered SA818 UART).
slot_dir="${work}/slot1"
# Invoke via `sh` so the test doesn't depend on the source file's git exec bit.
SIM_BIN="$bin" SA818_SIM="$sa818_sim" SLOT_DIR="$slot_dir" RUNDIR="${work}/run" sh "$harness" &
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

echo "describe response: $resp"
case "$resp" in
    MODULE-DESCRIBE\ *fm_transceiver*) : ;;  # describe OK — continue to the set check
    *) echo "FAIL: unexpected describe response"; exit 1 ;;
esac

# The real regression this recipe fixes: a `set` reaches native_sim's SA818
# driver, which emits AT+DMOSETGROUP on uart_1. Without an emulator on that pty
# it driver_errors on a 2s AT timeout; with the harness-managed emulator it gets
# +DMOSETGROUP:0 and the module reports ok. Assert the whole path end to end.
setresp="$(python3 - "${slot_dir}/control" <<'PY'
import os, sys, select, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
os.write(fd, b"module fm set frequency 145.5\r\n")
buf = b""; deadline = time.time() + 6
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], deadline - time.time())
    if r:
        buf += os.read(fd, 4096)
        i = buf.find(b"MODULE-RESULT")
        if i != -1 and b"\n" in buf[i:]:
            break
os.close(fd)
for ln in buf.splitlines():
    i = ln.find(b"MODULE-RESULT ")
    if i != -1 and b'"op":"set"' in ln:
        print(ln[i:].decode(errors="replace")); break
PY
)"
echo "set response: $setresp"
case "$setresp" in
    *'"ok":true'*) echo "PASS"; exit 0 ;;
    *) echo "FAIL: set frequency did not succeed — SA818 emulator not answering the AT link"; exit 1 ;;
esac
