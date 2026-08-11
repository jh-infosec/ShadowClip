#!/bin/bash
#
# shadowclip-daemon.sh
#
# Watches the X11 clipboard and saves each new value into the history
# directory, keeping only the most recent MAX_ENTRIES.
#
# Polling is used rather than an event-driven watcher (xclip has no change
# notification, and clipnotify would be another dependency). At a 0.5s
# interval the cost is negligible and the script stays readable, at the price
# of up to a 0.5s delay before a fresh copy appears in the list.
#
# MAX_ENTRIES is re-read from the config file on every prune, so changing it
# takes effect immediately without restarting the daemon.
#
# Requires: xclip   (sudo apt install xclip)

set -euo pipefail

# config
#
# Every tunable lives here and can be overridden from the environment, so the
# service unit or a test harness can point the daemon somewhere else without
# editing this file.

: "${SHADOWCLIP_HISTDIR:=$HOME/.cache/shadowclip}"
: "${SHADOWCLIP_CONFIG_DIR:=$HOME/.config/shadowclip}"

HISTDIR="$SHADOWCLIP_HISTDIR"
CONFIG_DIR="$SHADOWCLIP_CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_MAX_ENTRIES=15
POLL_INTERVAL=0.5

mkdir -p "$HISTDIR" "$CONFIG_DIR"

# create a default config file the first time this runs
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "MAX_ENTRIES=$DEFAULT_MAX_ENTRIES" > "$CONFIG_FILE"
fi

# helpers

read_max_entries() {
    local max_entries="$DEFAULT_MAX_ENTRIES"
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null || true
        max_entries="${MAX_ENTRIES:-$DEFAULT_MAX_ENTRIES}"
    fi
    echo "$max_entries"
}

prune_old_entries() {
    local max_entries
    max_entries=$(read_max_entries)
    ls -t "$HISTDIR" 2>/dev/null | tail -n +"$((max_entries + 1))" | while read -r old_file; do
        rm -f "$HISTDIR/$old_file"
    done
}

# main loop

last_value=""

while true; do
    current_value=$(xclip -selection clipboard -o 2>/dev/null || true)

    if [[ -n "$current_value" && "$current_value" != "$last_value" ]]; then
        last_value="$current_value"
        timestamp=$(date +%s%N)
        printf '%s' "$current_value" > "$HISTDIR/$timestamp"
        prune_old_entries
    fi

    sleep "$POLL_INTERVAL"
done
