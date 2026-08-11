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
# count is a real clipboard entry and anything above it is an action.
#
# Requires: rofi, xclip   (sudo apt install rofi xclip)

set -euo pipefail

# config

: "${SHADOWCLIP_HISTDIR:=$HOME/.cache/shadowclip}"
: "${SHADOWCLIP_CONFIG_DIR:=$HOME/.config/shadowclip}"

HISTDIR="$SHADOWCLIP_HISTDIR"
CONFIG_DIR="$SHADOWCLIP_CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config"
THEME="$(dirname "$(readlink -f "$0")")/shadowclip.rasi"
DEFAULT_MAX_ENTRIES=15
PREVIEW_CHARS=80

mkdir -p "$HISTDIR" "$CONFIG_DIR"
[[ -f "$CONFIG_FILE" ]] || echo "MAX_ENTRIES=$DEFAULT_MAX_ENTRIES" > "$CONFIG_FILE"

# helpers

get_max_entries() {
    local max_entries="$DEFAULT_MAX_ENTRIES"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
    echo "${MAX_ENTRIES:-$DEFAULT_MAX_ENTRIES}"
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
    local current_max
    current_max=$(get_max_entries)
    local new_max
    new_max=$(printf '' | rofi -dmenu -theme "$THEME" \
        -p "New max entries (current: ${current_max}):")

    [[ -z "${new_max:-}" ]] && return 0

    if ! [[ "$new_max" =~ ^[0-9]+$ ]] || [[ "$new_max" -lt 1 ]]; then
        notify "Invalid number -- must be a positive integer"
        return 0
    fi

    echo "MAX_ENTRIES=$new_max" > "$CONFIG_FILE"

    # apply immediately if the new limit is smaller than current history
    ls -t "$HISTDIR" 2>/dev/null | tail -n +"$((new_max + 1))" | while read -r old_file; do
        rm -f "$HISTDIR/$old_file"
    done

    notify "Now storing up to $new_max entries"
}

clear_history() {
    rm -f "$HISTDIR"/*
    notify "History cleared"
}

# picker

show_picker() {
    mapfile -t files < <(ls -t "$HISTDIR" 2>/dev/null)
    local current_max
    current_max=$(get_max_entries)

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

    # action rows, always appended at the bottom in this order:
    #   [n]   separator (inert)
    #   [n+1] set max entries stored
    #   [n+2] clear all history
    list+="<span foreground='#006618'>──────────────────────</span>"$'\n'
    list+="⚙  Set max entries stored  (currently: ${current_max})"$'\n'
    list+="🗑  Clear all history"$'\n'

    local separator_row_index=$n
    local settings_row_index=$((n + 1))
    local clear_row_index=$((n + 2))

    local choice_index
    choice_index=$(printf '%s' "$list" | rofi -dmenu -markup-rows -i \
        -p "ShadowClip" -theme "$THEME" -format i)

    [[ -z "${choice_index:-}" ]] && return 0

    if [[ $choice_index -lt $n ]]; then
        local selected_file="${files[$choice_index]}"
        xclip -selection clipboard -i < "$HISTDIR/$selected_file"
        notify "Entry #$((choice_index + 1)) restored to clipboard"
    elif [[ $choice_index -eq $separator_row_index ]]; then
        return 0
    elif [[ $choice_index -eq $settings_row_index ]]; then
        change_max_entries
    elif [[ $choice_index -eq $clear_row_index ]]; then
        clear_history
    fi
}

# main

show_picker
