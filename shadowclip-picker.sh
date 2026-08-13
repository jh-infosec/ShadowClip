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
# The config helpers below are duplicated in the daemon and toggle scripts.
# That is deliberate: each script stays independently runnable, so copying
# one of them somewhere on its own still works.
#
# Requires: rofi, xclip   (sudo apt install rofi xclip)

set -euo pipefail

# config

: "${SHADOWCLIP_HISTDIR:=${XDG_RUNTIME_DIR:-$HOME/.cache}/shadowclip}"
: "${SHADOWCLIP_CONFIG_DIR:=$HOME/.config/shadowclip}"

HISTDIR="$SHADOWCLIP_HISTDIR"
CONFIG_DIR="$SHADOWCLIP_CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config"
PAUSE_FILE="$HISTDIR/.paused"
THEME="$(dirname "$(readlink -f "$0")")/shadowclip.rasi"
DEFAULT_MAX_ENTRIES=15
DEFAULT_EXPIRY_MINUTES=30
DEFAULT_SECRET_FILTER=1
PREVIEW_CHARS=80

# setup

mkdir -p "$HISTDIR" "$CONFIG_DIR"
chmod 700 "$HISTDIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# config helpers

config_get_int() {
    # config_get_int KEY DEFAULT
    #
    # Reads one integer setting. The config file is parsed, never sourced:
    # sourcing would execute it as shell, which is a code execution path
    # nobody wants in a tool that handles secrets.
    local key="$1" default="$2" value
    value=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

config_set() {
    # config_set KEY VALUE
    #
    # Upserts one key and rewrites the file atomically. An in-place `sed`
    # would silently do nothing when the key is absent, which looks like a
    # saved setting that never took effect.
    local key="$1" value="$2" tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    chmod 600 "$tmp"
    grep -vE "^${key}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

# entry helpers

list_entries() {
    # Newest first, one absolute path per line.
    #
    # Matching on '[0-9]*' selects timestamp-named entries and excludes the
    # pause flag without needing to filter it out afterwards.
    find "$HISTDIR" -maxdepth 1 -type f -name '[0-9]*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2-
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

prompt_number() {
    # prompt_number PROMPT -- returns a non-negative integer, or nothing
    local answer
    answer=$(printf '' | rofi -dmenu -theme "$THEME" -p "$1")
    [[ "$answer" =~ ^[0-9]+$ ]] && printf '%s' "$answer"
}

# actions

restore_entry() {
    # `-l 1` makes xclip serve the selection once and then exit. Without it
    # some builds hand ownership back as soon as the picker exits, so the
    # first paste succeeds and the clipboard is then empty.
    xclip -selection clipboard -i -l 1 < "$1" &
    disown
}

change_max_entries() {
    local current new_max
    current=$(config_get_int MAX_ENTRIES "$DEFAULT_MAX_ENTRIES")
    new_max=$(prompt_number "New max entries (current: ${current}):")
    if [[ -z "${new_max:-}" || "$new_max" -lt 1 ]]; then
        notify "Unchanged -- max entries must be a positive integer"
        return 0
    fi
    config_set MAX_ENTRIES "$new_max"
    list_entries | tail -n +"$((new_max + 1))" | while read -r old_file; do
        rm -f "$old_file"
    done
    notify "Now storing up to $new_max entries"
}

change_expiry_minutes() {
    local current new_expiry
    current=$(config_get_int EXPIRY_MINUTES "$DEFAULT_EXPIRY_MINUTES")
    new_expiry=$(prompt_number "New auto-expiry in minutes, 0=never (current: ${current}):")
    if [[ -z "${new_expiry:-}" ]]; then
        notify "Unchanged -- expiry must be 0 or a positive integer"
        return 0
    fi
    config_set EXPIRY_MINUTES "$new_expiry"
    notify "Entries now expire after ${new_expiry} minute(s) (0 = never)"
}

toggle_secret_filter() {
    local current
    current=$(config_get_int SECRET_FILTER "$DEFAULT_SECRET_FILTER")
    if [[ "$current" -eq 1 ]]; then
        config_set SECRET_FILTER 0
        notify "Secret filter off -- everything copied will be stored"
    else
        config_set SECRET_FILTER 1
        notify "Secret filter on -- likely credentials will be skipped"
    fi
}

toggle_pause() {
    if is_paused; then
        rm -f "$PAUSE_FILE"
        notify "Capturing resumed"
    else
        touch "$PAUSE_FILE"
        chmod 600 "$PAUSE_FILE"
        notify "Capturing paused -- nothing new will be saved until resumed"
    fi
}

clear_history() {
    find "$HISTDIR" -maxdepth 1 -type f -name '[0-9]*' -delete 2>/dev/null || true
    notify "History cleared"
}

# picker

show_picker() {
    local max_entries expiry filter_on
    max_entries=$(config_get_int MAX_ENTRIES "$DEFAULT_MAX_ENTRIES")
    expiry=$(config_get_int EXPIRY_MINUTES "$DEFAULT_EXPIRY_MINUTES")
    filter_on=$(config_get_int SECRET_FILTER "$DEFAULT_SECRET_FILTER")

    mapfile -t files < <(list_entries)

    local list=""
    local n=${#files[@]}

    if [[ $n -eq 0 ]]; then
        list="(no clipboard history yet)"$'\n'
    else
        local i raw_preview preview num
        for i in "${!files[@]}"; do
            raw_preview=$(head -c "$PREVIEW_CHARS" "${files[$i]}" | tr '\n' ' ' | tr -s ' ')
            preview=$(printf '%s' "$raw_preview" | escape_markup)
            num=$((i + 1))

            if [[ $i -eq 0 ]]; then
                # latest entry: bold + marker, made visually prominent
                list+="<b>➤ ${num}   ${preview}</b>"$'\n'
            else
                list+="   ${num}   ${preview}"$'\n'
            fi
        done
    fi

    local pause_label filter_label
    if is_paused; then
        pause_label="▶  Resume capturing"
    else
        pause_label="⏸  Pause capturing  (expires in ${expiry}m, currently ${n}/${max_entries} stored)"
    fi
    if [[ "$filter_on" -eq 1 ]]; then
        filter_label="🛡  Secret filter: on"
    else
        filter_label="🛡  Secret filter: off"
    fi

    # action rows, always appended at the bottom in this order:
    #   [n]   separator (inert)
    #   [n+1] set max entries stored
    #   [n+2] set auto-expiry minutes
    #   [n+3] secret filter on / off
    #   [n+4] pause / resume capturing
    #   [n+5] clear all history
    list+="<span foreground='#006618'>──────────────────────</span>"$'\n'
    list+="⚙  Set max entries stored  (currently: ${max_entries})"$'\n'
    list+="⏱  Set auto-expiry minutes  (currently: ${expiry})"$'\n'
    list+="${filter_label}"$'\n'
    list+="${pause_label}"$'\n'
    list+="🗑  Clear all history"$'\n'

    local separator_row_index=$n
    local settings_row_index=$((n + 1))
    local expiry_row_index=$((n + 2))
    local filter_row_index=$((n + 3))
    local pause_row_index=$((n + 4))
    local clear_row_index=$((n + 5))

    local prompt="ShadowClip"
    is_paused && prompt="ShadowClip [PAUSED]"

    local choice_index
    choice_index=$(printf '%s' "$list" | rofi -dmenu -markup-rows -i \
        -p "$prompt" -theme "$THEME" -format i)

    [[ -z "${choice_index:-}" ]] && return 0

    if [[ $choice_index -lt $n ]]; then
        restore_entry "${files[$choice_index]}"
        notify "Entry #$((choice_index + 1)) restored to clipboard"
    elif [[ $choice_index -eq $separator_row_index ]]; then
        return 0
    elif [[ $choice_index -eq $settings_row_index ]]; then
        change_max_entries
    elif [[ $choice_index -eq $expiry_row_index ]]; then
        change_expiry_minutes
    elif [[ $choice_index -eq $filter_row_index ]]; then
        toggle_secret_filter
    elif [[ $choice_index -eq $pause_row_index ]]; then
        toggle_pause
    elif [[ $choice_index -eq $clear_row_index ]]; then
        clear_history
    fi
}

# main

show_picker
