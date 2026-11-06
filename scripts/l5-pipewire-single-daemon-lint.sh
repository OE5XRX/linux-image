#!/usr/bin/env bash
# Guard: exactly ONE system-wide PipeWire daemon (oe5xrx-pipewire.service) and
# ONE WirePlumber (oe5xrx-wireplumber.service). Upstream's pipewire.service /
# pipewire.socket / pipewire-manager.socket bind the same /run/pipewire/pipewire-0
# socket; with both enabled the two daemons race for pipewire-0.lock at boot.
# The distro units are kept out of the build via PACKAGECONFIG:remove in the
# pipewire/wireplumber bbappends (a :remove beats any later append, so the
# bbappend line itself is what must stay) — this fails if it goes away or if a
# recipe enables a distro unit directly.
set -euo pipefail

ROOT="${1:-.}"
LAYER="${ROOT}/meta-oe5xrx-remotestation"
MM="${LAYER}/recipes-multimedia"
AUDIO="${MM}/oe5xrx-audio-system/oe5xrx-audio-system_1.0.bb"

fail=0
err() { echo "::error file=$1::$2"; fail=1; }

# Uncommented lines only (leading-# comment lines dropped).
code() { grep -vE '^[[:space:]]*#' "$1"; }

# 1) Both bbappends drop the upstream system + user units.
for recipe in pipewire wireplumber; do
    f="${MM}/${recipe}/${recipe}_%.bbappend"
    if [ ! -f "${f}" ]; then
        err "${f}" "missing (keeps the distro ${recipe} systemd units out of the image)"
        continue
    fi
    line=$(code "${f}" | grep -E '^PACKAGECONFIG:remove[[:space:]]*=' || true)
    for tok in systemd-system-service systemd-user-service; do
        if ! grep -Eq "[\" ]${tok}[\" ]" <<<"${line}"; then
            err "${f}" "PACKAGECONFIG:remove must list '${tok}'"
        fi
    done
done

# 2) No recipe enables a distro pipewire/wireplumber unit (only oe5xrx-* ones).
# Backslash-continued values are joined first so a multi-line SYSTEMD_SERVICE
# assignment is matched as one statement (reported at its first line).
while IFS= read -r -d '' f; do
    hits=$(awk '
        /^[[:space:]]*#/ && !cont { next }
        { if (!cont) { start = FNR; stmt = "" } }
        { line = $0; cont = sub(/\\[[:space:]]*$/, "", line); stmt = stmt " " line }
        !cont { print start ":" stmt }
    ' "${f}" | grep -E '^[0-9]+:[[:space:]]*SYSTEMD_SERVICE' \
             | grep -E '[" =](pipewire(-manager|-pulse)?|wireplumber)\.(service|socket)' || true)
    while IFS= read -r hit; do
        [ -n "${hit}" ] && err "${f}" "line ${hit%%:*} enables a distro PipeWire/WirePlumber unit:${hit#*:}"
    done <<<"${hits}"
done < <(find "${LAYER}" -type f \( -name '*.bb' -o -name '*.bbappend' -o -name '*.inc' \) -print0)

# 3) The audio recipe still owns + enables our single daemon pair.
svc=$(code "${AUDIO}" | grep -E '^SYSTEMD_SERVICE:\$\{PN\}[[:space:]]*=' || true)
for unit in oe5xrx-pipewire.service oe5xrx-wireplumber.service; do
    if ! grep -q "${unit}" <<<"${svc}"; then
        err "${AUDIO}" "SYSTEMD_SERVICE must enable ${unit}"
    fi
done

[ "${fail}" -eq 0 ] && echo "OK — single system-wide PipeWire/WirePlumber daemon"
exit "${fail}"
