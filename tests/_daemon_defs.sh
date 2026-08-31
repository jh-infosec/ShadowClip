#!/usr/bin/env bash
# shellcheck shell=bash
# Shared loader for the daemon's functions.
#
# The daemon ends in `while true`, so it cannot be sourced whole. Everything
# above the main loop is definitions and constants, which is what these tests
# need. Sourced with `set +e` afterwards because the daemon sets -e for its
# own run, and most checks here expect a non-zero return as a pass.

load_daemon_defs() {
    local daemon="$1" dest="$2" line
    line=$(grep -n '^# main loop' "$daemon" | head -n 1 | cut -d: -f1)
    if [ -z "$line" ]; then
        printf 'could not find the main loop marker in %s\n' "$daemon"
        return 1
    fi
    head -n "$((line - 1))" "$daemon" > "$dest"
}
