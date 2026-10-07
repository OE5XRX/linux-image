#!/bin/sh
# Log the Raspberry Pi throttle/undervoltage state to the (persistent) journal.
# Runs as a oneshot driven by oe5xrx-throttle-log.timer. Writing it into the
# journal gives an undervoltage HISTORY that survives a spontaneous reboot,
# complementing the station-agent reading vcgencmd live.
#
# Must never fail the unit (a failed oneshot shows systemd `degraded`): if
# vcgencmd is missing (non-rpi) or errors, log once and exit 0.
set -u

if ! command -v vcgencmd >/dev/null 2>&1; then
    echo "throttle-log: vcgencmd not available — skipping (non-rpi?)"
    exit 0
fi

raw=$(vcgencmd get_throttled 2>/dev/null) || {
    echo "throttle-log: vcgencmd get_throttled failed — skipping"
    exit 0
}

# raw looks like: throttled=0x50005
hex=${raw#*=}

# Validate the full value: 0x<hexdigits> or plain <decimaldigits>. Anything
# else (error text, partial output) would abort the arithmetic below and fail
# the oneshot — so bail cleanly (exit 0) instead.
case "$hex" in
    0x*)
        digits=${hex#0x}
        case "$digits" in
            ""|*[!0-9A-Fa-f]*)
                echo "throttle-log: unexpected vcgencmd output '${raw}' — skipping"
                exit 0 ;;
        esac ;;
    ""|*[!0-9]*)
        echo "throttle-log: unexpected vcgencmd output '${raw}' — skipping"
        exit 0 ;;
esac

echo "throttle-log: ${raw}"

# Decode the documented bits (0x1 undervolt now, 0x2 freq-capped now,
# 0x4 throttled now, 0x8 soft-temp-limit now; 0x10000.. = "has occurred").
val=$((hex))
[ $(( val & 0x1 )) -ne 0 ]     && echo "throttle-log:   under-voltage detected (now)"
[ $(( val & 0x2 )) -ne 0 ]     && echo "throttle-log:   arm frequency capped (now)"
[ $(( val & 0x4 )) -ne 0 ]     && echo "throttle-log:   currently throttled (now)"
[ $(( val & 0x8 )) -ne 0 ]     && echo "throttle-log:   soft temperature limit active (now)"
[ $(( val & 0x10000 )) -ne 0 ] && echo "throttle-log:   under-voltage has occurred since boot"
[ $(( val & 0x20000 )) -ne 0 ] && echo "throttle-log:   arm frequency capping has occurred"
[ $(( val & 0x40000 )) -ne 0 ] && echo "throttle-log:   throttling has occurred since boot"
[ $(( val & 0x80000 )) -ne 0 ] && echo "throttle-log:   soft temperature limit has occurred"

exit 0
