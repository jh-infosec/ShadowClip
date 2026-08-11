#!/bin/bash
#
# shadowclip-picker.sh
#
# Pops up a searchable list of recent clipboard entries, numbered 1 (latest)
# through N (oldest), and restores the selected entry to the clipboard.
#
# Rofi is invoked with `-format i`, so what comes back is a row index rather
# than the row text. That matters: entry previews are truncated and escaped
# for Pango markup, so the displayed text cannot be matched back to a file.
# The index is the only reliable link between what the user picked and what
# is on disk.
#
# Action rows are appended after the entries, so any index below the entry
# count is a real clipboard entry and anything above it is an action. Adding
# a new action means adding a row and an index in the same order, in both
# places.
#
# Requires: rofi, xclip   (sudo apt install rofi xclip)

set -euo pipefail

# config

: "${SHADOWCLIP_HISTDIR:=$HOME/.cache/shadowclip}"
: "${SHADOWCLIP_CONFIG_DIR:=$HOME/.config/shadowclip}"

HISTDIR="$SHADOWCLIP_HISTDIR"
CONFIG_DIR="$SHADOWCLIP_CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config"
PAUSE_FILE="$HISTDIR/.paused"
THEME="$(dirname "$(readlink -f "$0")")/shadowclip.rasi"
DEFAULT_MAX_ENTRIES=15
DEFAULT_EXPIRY_MINUTES=30
PREVIEW_CHARS=80

# setup

mkdir -p "$HISTDIR" "$CONFIG_DIR"
chmod 700 "$HISTDIR"
if [[ ! -f "$CONFIG_FILE" ]]; then
    {
        echo "MAX_ENTRIES=$DEFAULT_MAX_ENTRIES"
        echo "EXPIRY_MINUTES=$DEFAULT_EXPIRY_MINUTES"
    } > "$CONFIG_FILE"
fi

# helpers

read_config() {
    MAX_ENTRIES="$DEFAULT_MAX_ENTRIES"
    EXPIRY_MINUTES="$DEFAULT_EXPIRY_MINUTES"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
}

is_paused() {
    [[ -f "$PAUSE_FILE" ]]
}

# escape text for safe use inside Pango markup (rofi -markup-rows)
escape_markup() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

notify() {
    notify-send "ShadowClip" "$1" 2>/dev/null || echo "$1"
}

# actions

change_max_entries() {
    read_config
    local new_max
    new_max=$(printf '' | rofi -dmenu -theme "$THEME" \
        -p "New max entries (current: ${MAX_ENTRIES}):")
    [[ -z "${new_max:-}" ]] && return 0
    if ! [[ "$new_max" =~ ^[0-9]+$ ]] || [[ "$new_max" -lt 1 ]]; then
        notify "Invalid number -- must be a positive integer"
        return 0
    fi
    sed -i "s/^MAX_ENTRIES=.*/MAX_ENTRIES=$new_max/" "$CONFIG_FILE"
    ls -t "$HISTDIR" 2>/dev/null | grep -v '^\.paused$' | tail -n +"$((new_max + 1))" | while read -r old_file; do
        rm -f "$HISTDIR/$old_file"
    done
    notify "Now storing up to $new_max entries"
}

change_expiry_minutes() {
    read_config
    local new_expiry
    new_expiry=$(printf '' | rofi -dmenu -theme "$THEME" \
        -p "New auto-expiry in minutes, 0=never (current: ${EXPIRY_MINUTES}):")
    [[ -z "${new_expiry:-}" ]] && return 0
    if ! [[ "$new_expiry" =~ ^[0-9]+$ ]]; then
        notify "Invalid number -- must be 0 or a positive integer"
        return 0
    fi
    sed -i "s/^EXPIRY_MINUTES=.*/EXPIRY_MINUTES=$new_expiry/" "$CONFIG_FILE"
    notify "Entries now expire after ${new_expiry} minute(s) (0 = never)"
}

toggle_pause() {
    if is_paused; then
        rm -f "$PAUSE_FILE"
        notify "Capturing resumed"
    else
        touch "$PAUSE_FILE"
        notify "Capturing paused -- nothing new will be saved until resumed"
    fi
}

clear_history() {
    find "$HISTDIR" -maxdepth 1 -type f ! -name '.paused' -delete 2>/dev/null || true
    notify "History cleared"
}

# picker

show_picker() {
    read_config
    mapfile -t files < <(ls -t "$HISTDIR" 2>/dev/null | grep -v '^\.paused$' || true)

    local list=""
    local n=${#files[@]}

    if [[ $n -eq 0 ]]; then
        list="(no clipboard history yet)"$'\n'
    else
        for i in "${!files[@]}"; do
            local raw_preview
            raw_preview=$(head -c "$PREVIEW_CHARS" "$HISTDIR/${files[$i]}" | tr '\n' ' ' | tr -s ' ')
            local preview
            preview=$(printf '%s' "$raw_preview" | escape_markup)
            local num=$((i + 1))

            if [[ $i -eq 0 ]]; then
                # latest entry: bold + marker, made visually prominent
                list+="<b>➤ ${num}   ${preview}</b>"$'\n'
            else
                list+="   ${num}   ${preview}"$'\n'
            fi
        done
    fi

    local pause_label
    if is_paused; then
        pause_label="▶  Resume capturing"
    else
        pause_label="⏸  Pause capturing  (expires in ${EXPIRY_MINUTES}m, currently ${n}/${MAX_ENTRIES} stored)"
    fi

    # action rows, always appended at the bottom in this order:
    #   [n]   separator (inert)
    #   [n+1] set max entries stored
    #   [n+2] set auto-expiry minutes
    #   [n+3] pause / resume capturing
    #   [n+4] clear all history
    list+="<span foreground='#006618'>──────────────────────</span>"$'\n'
    list+="⚙  Set max entries stored  (currently: ${MAX_ENTRIES})"$'\n'
    list+="⏱  Set auto-expiry minutes  (currently: ${EXPIRY_MINUTES})"$'\n'
    list+="${pause_label}"$'\n'
    list+="🗑  Clear all history"$'\n'

    local separator_row_index=$n
    local settings_row_index=$((n + 1))
    local expiry_row_index=$((n + 2))
    local pause_row_index=$((n + 3))
    local clear_row_index=$((n + 4))

    local prompt="ShadowClip"
    is_paused && prompt="ShadowClip [PAUSED]"

    local choice_index
    choice_index=$(printf '%s' "$list" | rofi -dmenu -markup-rows -i \
        -p "$prompt" -theme "$THEME" -format i)

    [[ -z "${choice_index:-}" ]] && return 0

    if [[ $choice_index -lt $n ]]; then
        local selected_file="${files[$choice_index]}"
        xclip -selection clipboard -i < "$HISTDIR/$selected_file"
        notify "Entry #$((choice_index + 1)) restored to clipboard"
    elif [[ $choice_index -eq $separator_row_index ]]; then
        return 0
    elif [[ $choice_index -eq $settings_row_index ]]; then
        change_max_entries
    elif [[ $choice_index -eq $expiry_row_index ]]; then
        change_expiry_minutes
    elif [[ $choice_index -eq $pause_row_index ]]; then
        toggle_pause
    elif [[ $choice_index -eq $clear_row_index ]]; then
        clear_history
    fi
}

# main

show_picker
