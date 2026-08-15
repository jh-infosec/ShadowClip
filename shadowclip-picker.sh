#!/bin/bash
#
# shadowclip-picker.sh
#
# Pops up a searchable list of recent clipboard entries and restores the
# selected one to the clipboard. Pinned entries are listed first, in their
# own colour, and are never pruned or expired.
#
# Rofi is invoked with `-format i`, so what comes back is a row index rather
# than the row text. That matters: entry previews are truncated and escaped
# for Pango markup, so the displayed text cannot be matched back to a file.
#
# Every rendered row has a matching entry in the `actions` array, appended in
# the same call that appends the row. Dispatch is a lookup, not arithmetic.
# Versions up to 0.3.0 computed action indices from the entry count, which
# broke the moment a row appeared that was not an entry: the empty-history
# placeholder shifted every action down by one. A parallel array cannot
# drift, because a row and its action are added together or not at all.
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
PINDIR="$HISTDIR/pinned"
CONFIG_DIR="$SHADOWCLIP_CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config"
PAUSE_FILE="$HISTDIR/.paused"
THEME="$(dirname "$(readlink -f "$0")")/shadowclip.rasi"
DEFAULT_MAX_ENTRIES=15
DEFAULT_EXPIRY_MINUTES=30
DEFAULT_SECRET_FILTER=1
DEFAULT_WINDOW_WIDTH=650
DEFAULT_LIST_LINES=17
PREVIEW_CHARS=80

# Pinned rows are cyan against the green of ordinary entries, and structural
# rows are dimmed. Colour is applied per row with Pango markup because a rofi
# theme styles row states, not individual rows.
PIN_COLOUR='#00E5FF'
DIM_COLOUR='#00994D'

# The key that pins or unpins the highlighted row. Rofi reports it as exit
# code 10. If rofi ever refuses to start with a binding conflict, change
# this to something free, or to rofi's own default of Alt+1.
PIN_KEY='Alt+p'
PIN_EXIT_CODE=10

# setup

mkdir -p "$HISTDIR" "$PINDIR" "$CONFIG_DIR"
chmod 700 "$HISTDIR" "$PINDIR"
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

list_dir_entries() {
    # list_dir_entries DIR -- newest first, one absolute path per line.
    #
    # `-maxdepth 1 -type f` is what keeps the pinned subdirectory out of the
    # history listing, and matching on '[0-9]*' excludes the pause flag.
    # The daemon's prune and expiry use the same two constraints, which is
    # why pinned entries survive both without the daemon knowing they exist.
    find "$1" -maxdepth 1 -type f -name '[0-9]*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2-
}

count_entries() {
    list_dir_entries "$1" | grep -c . || true
}

is_paused() {
    [[ -f "$PAUSE_FILE" ]]
}

# escape text for safe use inside Pango markup (rofi -markup-rows)
escape_markup() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

preview_of() {
    # preview_of PATH -- one escaped, single-line, truncated preview
    head -c "$PREVIEW_CHARS" "$1" | tr '\n' ' ' | tr -s ' ' | escape_markup
}

notify() {
    notify-send "ShadowClip" "$1" 2>/dev/null || echo "$1"
}

# rofi helpers

theme_override() {
    # Window size is a setting rather than a theme edit, so it can be changed
    # from the popup. Rofi has no draggable window, so this is as close to
    # resizing as the toolkit allows.
    local width lines
    width=$(config_get_int WINDOW_WIDTH "$DEFAULT_WINDOW_WIDTH")
    lines=$(config_get_int LIST_LINES "$DEFAULT_LIST_LINES")
    printf 'window { width: %spx; } listview { lines: %s; }' "$width" "$lines"
}

run_rofi() {
    # run_rofi PROMPT ROWS -- sets ROFI_INDEX and ROFI_STATUS
    #
    # Deliberately returns its result in globals rather than on stdout. A
    # caller writing `i=$(run_rofi ...)` would run this in a subshell, and
    # ROFI_STATUS would be set and discarded there, so the pin key would
    # never be seen by the dispatch.
    #
    # set -e is lifted around the call on purpose. Rofi exits 1 when the menu
    # is cancelled and 10 when the pin key is pressed, and both are ordinary
    # outcomes rather than failures.
    local prompt="$1" rows="$2"
    set +e
    ROFI_INDEX=$(printf '%s' "$rows" | rofi -dmenu -markup-rows -i \
        -p "$prompt" -theme "$THEME" -theme-str "$(theme_override)" \
        -format i -kb-custom-1 "$PIN_KEY")
    ROFI_STATUS=$?
    set -e
}

prompt_number() {
    # prompt_number PROMPT -- prints a non-negative integer, or nothing
    #
    # This function never fails, and that is the point. Rofi exits non-zero
    # when the prompt is cancelled, and a non-numeric answer used to leave
    # the function returning 1. Either way the caller's `x=$(prompt_number)`
    # assignment failed, and under set -e the picker ended right there,
    # before the caller could tell the user that nothing had changed.
    local answer
    answer=$(printf '' | rofi -dmenu -theme "$THEME" \
        -theme-str "$(theme_override)" -p "$1" || true)
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
        printf '%s' "$answer"
    fi
    return 0
}

# row building

add_row() {
    # add_row DISPLAY ACTION
    #
    # The two arrays are only ever appended together, which is what makes
    # index drift between what is shown and what is dispatched impossible.
    ROWS+=("$1")
    ACTIONS+=("$2")
}

rows_as_list() {
    local row out=""
    for row in "${ROWS[@]}"; do
        out+="${row}"$'\n'
    done
    printf '%s' "$out"
}

# actions

restore_entry() {
    # `-l 1` makes xclip serve the selection once and then exit. Without it
    # some builds hand ownership back as soon as the picker exits, so the
    # first paste succeeds and the clipboard is then empty.
    xclip -selection clipboard -i -l 1 < "$1" &
    disown
}

pin_entry() {
    # Moved rather than copied, so an entry appears in exactly one section.
    # Moving into the pinned subdirectory is the whole mechanism: the daemon
    # only ever looks at files directly inside the history directory, so a
    # pinned entry is invisible to pruning and expiry without the daemon
    # needing to know that pinning exists.
    local source_path="$1" target
    target="$PINDIR/$(basename "$source_path")"
    mv "$source_path" "$target"
    chmod 600 "$target"
    notify "Pinned -- kept until you unpin it"
}

unpin_entry() {
    # Back into the history directory, subject to pruning and expiry again.
    local source_path="$1" target
    target="$HISTDIR/$(basename "$source_path")"
    mv "$source_path" "$target"
    chmod 600 "$target"
    notify "Unpinned -- back in normal history"
}

unpin_all() {
    local path count=0
    while read -r path; do
        [[ -n "$path" ]] || continue
        mv "$path" "$HISTDIR/$(basename "$path")"
        count=$((count + 1))
    done < <(list_dir_entries "$PINDIR")
    notify "Unpinned $count entries"
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
    list_dir_entries "$HISTDIR" | tail -n +"$((new_max + 1))" | while read -r old_file; do
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

change_window_width() {
    local current new_width
    current=$(config_get_int WINDOW_WIDTH "$DEFAULT_WINDOW_WIDTH")
    new_width=$(prompt_number "Window width in pixels (current: ${current}):")
    if [[ -z "${new_width:-}" || "$new_width" -lt 200 ]]; then
        notify "Unchanged -- width must be at least 200"
        return 0
    fi
    config_set WINDOW_WIDTH "$new_width"
    notify "Window width set to ${new_width}px"
}

change_list_lines() {
    local current new_lines
    current=$(config_get_int LIST_LINES "$DEFAULT_LIST_LINES")
    new_lines=$(prompt_number "Rows shown before scrolling (current: ${current}):")
    if [[ -z "${new_lines:-}" || "$new_lines" -lt 1 ]]; then
        notify "Unchanged -- rows must be a positive integer"
        return 0
    fi
    config_set LIST_LINES "$new_lines"
    notify "Showing ${new_lines} rows before scrolling"
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
    # Pinned entries live one directory down and are deliberately untouched.
    # That is the point of pinning: clearing is the routine action, and the
    # entries marked as worth keeping should survive it.
    find "$HISTDIR" -maxdepth 1 -type f -name '[0-9]*' -delete 2>/dev/null || true
    notify "History cleared -- pinned entries kept"
}

# settings menu

show_settings() {
    local max_entries expiry filter_on width lines pinned_count
    max_entries=$(config_get_int MAX_ENTRIES "$DEFAULT_MAX_ENTRIES")
    expiry=$(config_get_int EXPIRY_MINUTES "$DEFAULT_EXPIRY_MINUTES")
    filter_on=$(config_get_int SECRET_FILTER "$DEFAULT_SECRET_FILTER")
    width=$(config_get_int WINDOW_WIDTH "$DEFAULT_WINDOW_WIDTH")
    lines=$(config_get_int LIST_LINES "$DEFAULT_LIST_LINES")
    pinned_count=$(count_entries "$PINDIR")

    ROWS=()
    ACTIONS=()

    add_row "⚙  Set max entries stored  (currently: ${max_entries})" "max_entries"
    add_row "⏱  Set auto-expiry minutes  (currently: ${expiry})" "expiry"
    if [[ "$filter_on" -eq 1 ]]; then
        add_row "🛡  Secret filter: on" "filter"
    else
        add_row "🛡  Secret filter: off" "filter"
    fi
    if is_paused; then
        add_row "▶  Resume capturing" "pause"
    else
        add_row "⏸  Pause capturing" "pause"
    fi
    add_row "↔  Window width  (currently: ${width}px)" "width"
    add_row "↕  Rows before scrolling  (currently: ${lines})" "lines"
    add_row "📌  Unpin all  (${pinned_count} pinned)" "unpin_all"
    add_row "🗑  Clear all history  (pinned entries kept)" "clear"
    add_row "<span foreground='${DIM_COLOUR}'>←  Back to clips</span>" "back"

    run_rofi "Settings:" "$(rows_as_list)"
    [[ -z "${ROFI_INDEX:-}" ]] && return 0
    [[ "$ROFI_STATUS" -eq $PIN_EXIT_CODE ]] && return 0

    case "${ACTIONS[$ROFI_INDEX]}" in
        max_entries) change_max_entries ;;
        expiry)      change_expiry_minutes ;;
        filter)      toggle_secret_filter ;;
        pause)       toggle_pause ;;
        width)       change_window_width ;;
        lines)       change_list_lines ;;
        unpin_all)   unpin_all ;;
        clear)       clear_history ;;
        back)        show_picker ;;
    esac
}

# picker

show_picker() {
    local pinned files i num preview

    mapfile -t pinned < <(list_dir_entries "$PINDIR")
    mapfile -t files < <(list_dir_entries "$HISTDIR")

    ROWS=()
    ACTIONS=()

    if [[ ${#pinned[@]} -gt 0 ]]; then
        for i in "${!pinned[@]}"; do
            preview=$(preview_of "${pinned[$i]}")
            num=$((i + 1))
            add_row "<span foreground='${PIN_COLOUR}'>📌 ${num}   ${preview}</span>" \
                    "pinned:${pinned[$i]}"
        done
        add_row "<span foreground='${DIM_COLOUR}'>──────── history ────────</span>" "noop"
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        add_row "(no clipboard history yet)" "noop"
    else
        for i in "${!files[@]}"; do
            preview=$(preview_of "${files[$i]}")
            num=$((i + 1))
            if [[ $i -eq 0 ]]; then
                add_row "<b>➤ ${num}   ${preview}</b>" "entry:${files[$i]}"
            else
                add_row "   ${num}   ${preview}" "entry:${files[$i]}"
            fi
        done
    fi

    add_row "<span foreground='${DIM_COLOUR}'>─────────────────────────</span>" "noop"
    add_row "<span foreground='${DIM_COLOUR}'>⚙  Settings and actions   (${PIN_KEY} pins the highlighted clip)</span>" "settings"

    local prompt="ShadowClip:"
    is_paused && prompt="ShadowClip [PAUSED]:"

    local action
    run_rofi "$prompt" "$(rows_as_list)"
    [[ -z "${ROFI_INDEX:-}" ]] && return 0

    action="${ACTIONS[$ROFI_INDEX]}"

    # The pin key acts on whichever row is highlighted, so it is handled
    # before the ordinary dispatch and only where pinning means something.
    if [[ "$ROFI_STATUS" -eq $PIN_EXIT_CODE ]]; then
        case "$action" in
            entry:*)  pin_entry "${action#entry:}" ;;
            pinned:*) unpin_entry "${action#pinned:}" ;;
            *)        notify "Nothing to pin on that row" ;;
        esac
        return 0
    fi

    case "$action" in
        noop)     return 0 ;;
        settings) show_settings ;;
        entry:*)
            restore_entry "${action#entry:}"
            notify "Restored to clipboard"
            ;;
        pinned:*)
            restore_entry "${action#pinned:}"
            notify "Pinned entry restored to clipboard"
            ;;
    esac
}

# main

ROWS=()
ACTIONS=()
ROFI_INDEX=""
ROFI_STATUS=0
show_picker
