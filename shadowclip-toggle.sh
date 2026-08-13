#!/bin/bash
#
# shadowclip-toggle.sh
#
# Pauses or resumes clipboard recording without opening the picker.
#
# This duplicates the picker's pause action deliberately. The point of the
# feature is speed: a single hotkey you can hit reflexively before pasting a
# password, without a menu appearing and without taking focus from whatever
# you were doing.
#
# Pause state is a flag file rather than a signal or a config value, so the
# daemon, the picker and this script can all read and write it with no IPC
# and no shared process state. While paused the daemon keeps running, so
# expiry of already-saved entries continues.

set -euo pipefail

# config

: "${SHADOWCLIP_HISTDIR:=${XDG_RUNTIME_DIR:-$HOME/.cache}/shadowclip}"

HISTDIR="$SHADOWCLIP_HISTDIR"
PAUSE_FILE="$HISTDIR/.paused"

# setup

mkdir -p "$HISTDIR"
chmod 700 "$HISTDIR"

# helpers

notify() {
    notify-send "ShadowClip" "$1" 2>/dev/null || echo "$1"
}

# main

if [[ -f "$PAUSE_FILE" ]]; then
    rm -f "$PAUSE_FILE"
    notify "▶ Resumed -- clipboard recording is back on"
else
    touch "$PAUSE_FILE"
    chmod 600 "$PAUSE_FILE"
    notify "⏸ Paused -- clipboard is NOT being recorded"
fi
