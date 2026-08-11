#!/bin/bash
#
# shadowclip-daemon.sh
#
# Watches the X11 clipboard and saves each new value into the history
# directory, keeping only the most recent MAX_ENTRIES and deleting anything
# older than EXPIRY_MINUTES.
#
# Polling is used rather than an event-driven watcher (xclip has no change
# notification, and clipnotify would be another dependency). At a 0.5s
# interval the cost is negligible and the script stays readable, at the price
# of up to a 0.5s delay before a fresh copy appears in the list.
#
# Expiry is checked every EXPIRY_CHECK_LOOPS iterations rather than every
# poll. Running `find` twice a second would be wasteful for a deadline that
# is measured in minutes.
#
# Capturing can be paused by creating the pause file, either through the
# picker, through shadowclip-toggle.sh, or by hand. While paused the daemon
# keeps running so that expiry of already-saved entries continues.
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
PAUSE_FILE="$HISTDIR/.paused"
DEFAULT_MAX_ENTRIES=15
DEFAULT_EXPIRY_MINUTES=30
POLL_INTERVAL=0.5
EXPIRY_CHECK_LOOPS=20

# setup
#
# Permissions are set on every start, not just on creation, so an existing
# install from an earlier version gets hardened on first run of this one.

mkdir -p "$HISTDIR" "$CONFIG_DIR"
chmod 700 "$HISTDIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    {
        echo "MAX_ENTRIES=$DEFAULT_MAX_ENTRIES"
        echo "EXPIRY_MINUTES=$DEFAULT_EXPIRY_MINUTES"
    } > "$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"

# helpers

read_config() {
    MAX_ENTRIES="$DEFAULT_MAX_ENTRIES"
    EXPIRY_MINUTES="$DEFAULT_EXPIRY_MINUTES"
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
}

is_paused() {
    [[ -f "$PAUSE_FILE" ]]
}

prune_old_entries() {
    read_config
    ls -t "$HISTDIR" 2>/dev/null | grep -v '^\.paused$' | tail -n +"$((MAX_ENTRIES + 1))" | while read -r old_file; do
        rm -f "$HISTDIR/$old_file"
    done
}

expire_stale_entries() {
    read_config
    [[ "$EXPIRY_MINUTES" -le 0 ]] && return 0
    find "$HISTDIR" -maxdepth 1 -type f ! -name '.paused' -mmin +"$EXPIRY_MINUTES" -delete 2>/dev/null || true
}

# main loop

last_value=""
loop_count=0

while true; do
    if ! is_paused; then
        current_value=$(xclip -selection clipboard -o 2>/dev/null || true)

        if [[ -n "$current_value" && "$current_value" != "$last_value" ]]; then
            last_value="$current_value"
            timestamp=$(date +%s%N)
            printf '%s' "$current_value" > "$HISTDIR/$timestamp"
            chmod 600 "$HISTDIR/$timestamp"
            prune_old_entries
        fi
    fi

    loop_count=$((loop_count + 1))
    if [[ $((loop_count % EXPIRY_CHECK_LOOPS)) -eq 0 ]]; then
        expire_stale_entries
    fi

    sleep "$POLL_INTERVAL"
done
