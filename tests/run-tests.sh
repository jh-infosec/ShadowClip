#!/usr/bin/env bash
# Run every picker test.
#
# Tests that build GTK windows need a display. If there is not one, this
# falls back to xvfb-run so the suite still works over SSH or in CI. The
# stylesheet test needs neither and always runs.

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")" || exit 1

RUNNER=()
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    if command -v xvfb-run >/dev/null 2>&1; then
        RUNNER=(xvfb-run -a)
        printf '%s\n' "no display found, running under xvfb-run"
    else
        printf '%s\n' "no display found and xvfb-run is not installed."
        printf '%s\n' "install it with: sudo apt install xvfb"
        printf '%s\n' "the stylesheet test will still run."
    fi
fi

failed=0
total=0

for test in test-*.sh test-*.py; do
    [ -e "$test" ] || continue
    total=$((total + 1))
    printf '\n----- %s -----\n' "$test"
    if [ "${test##*.}" = "sh" ]; then
        # Shell tests exercise the daemon's own functions. No display needed.
        bash "$test" || failed=$((failed + 1))
    elif [ "$test" = "test-stylesheet.py" ]; then
        python3 "$test" || failed=$((failed + 1))
    else
        "${RUNNER[@]}" python3 "$test" 2>&1 \
            | grep -v -E "Gtk-(WARNING|CRITICAL)|^$" || true
        # grep sits in the pipeline, so read the python exit status directly.
        if [ "${PIPESTATUS[0]}" -ne 0 ]; then
            failed=$((failed + 1))
        fi
    fi
done

printf '\n=====================================\n'
if [ "$failed" -eq 0 ]; then
    printf '%s\n' "all $total test files passed"
    exit 0
fi
printf '%s\n' "$failed of $total test files FAILED"
exit 1
