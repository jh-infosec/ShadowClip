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
# The config helpers below are duplicated in the picker and toggle scripts.
# That is deliberate: each script stays independently runnable, so copying
# one of them somewhere on its own still works.
#
# Requires: xclip   (sudo apt install xclip)

set -euo pipefail

# config
#
# History defaults to XDG_RUNTIME_DIR, which is tmpfs on systemd systems and
# already owner-only. Entries therefore live in memory and vanish on logout
# rather than being written to the SSD. Falls back to ~/.cache when
# XDG_RUNTIME_DIR is unset.

: "${SHADOWCLIP_HISTDIR:=${XDG_RUNTIME_DIR:-$HOME/.cache}/shadowclip}"
: "${SHADOWCLIP_CONFIG_DIR:=$HOME/.config/shadowclip}"

HISTDIR="$SHADOWCLIP_HISTDIR"
CONFIG_DIR="$SHADOWCLIP_CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config"
PAUSE_FILE="$HISTDIR/.paused"
DEFAULT_MAX_ENTRIES=15
DEFAULT_EXPIRY_MINUTES=30
DEFAULT_SECRET_FILTER=1
POLL_INTERVAL=0.5
EXPIRY_CHECK_LOOPS=20
SECRET_SCAN_CHARS=4096

# Patterns for values that are almost certainly credentials. Deliberately
# narrow: bare hex and base64 are excluded because hashes and payloads are
# working material for pentest and CTF use, and silently dropping them would
# make the tool untrustworthy.
SECRET_PATTERNS=(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+'
    'A(KIA|SIA)[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'glpat-[A-Za-z0-9_-]{20,}'
    '(password|passwd|api[_-]?key|secret|token)[[:space:]]*[=:][[:space:]]*[^[:space:]]{6,}'
)

# setup
#
# Permissions are set on every start, not just on creation, so an existing
# install from an earlier version gets hardened on first run of this one.

# Owner-only by default. The explicit chmods below already do this, but a
# umask closes the brief window between a file being created and being
# chmod'd, and covers any path added later that forgets the chmod.
umask 077

mkdir -p "$HISTDIR" "$CONFIG_DIR"
chmod 700 "$HISTDIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# config helpers

config_get_int() {
    # config_get_int KEY DEFAULT
    #
    # Reads one integer setting. The config file is parsed, never sourced:
    # sourcing would execute it as shell on every poll, which is a code
    # execution path nobody wants in a tool that handles secrets.
    local key="$1" default="$2" value
    value=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
    if [[ ! "$value" =~ ^[0-9]{1,9}$ ]]; then
        printf '%s' "$default"
        return 0
    fi
    # 10# forces base ten. Without it a hand-edited MAX_ENTRIES=08 is read as
    # octal by the arithmetic that uses it, bash aborts with "value too great
    # for base", set -e kills the daemon, and systemd restarts it straight
    # back into the same failure on the next poll. A leading zero in a config
    # file turning into a restart loop that drops clips is not a failure mode
    # worth keeping. The length bound stops a very long digit string reaching
    # arithmetic at all.
    printf '%s' "$((10#$value))"
}

config_get_bool() {
    # config_get_bool KEY DEFAULT
    #
    # Separate from config_get_int, because a switch has two valid values
    # rather than any integer. SECRET_FILTER=2 passed the integer check and
    # then failed the -eq 1 test at the point of use, which silently turned
    # the filter off -- the one setting where a typo must never quietly
    # disable protection. Anything that is not exactly 0 or 1 falls back to
    # the default, and the default for the filter is on.
    local key="$1" default="$2" value
    value=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
    case "$value" in
        0|1) printf '%s' "$value" ;;
        *)   printf '%s' "$default" ;;
    esac
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

newest_entry_is_file() {
    # True when the newest stored entry is byte-for-byte this file.
    #
    # The loop's own last-seen copy only knows what this process has seen, so
    # it cannot tell that the picker just wrote an entry and put the same text
    # on the clipboard. Without this check that lands twice: once from the
    # picker, once from the next poll. The newest entry only, so restoring an
    # older clip still bumps it back to the top.
    local newest
    newest=$(list_entries | head -n 1)
    [[ -n "$newest" ]] || return 1
    cmp -s "$1" "$newest"
}

notify() {
    notify-send "ShadowClip" "$1" 2>/dev/null || true
}

looks_like_secret_file() {
    # Scans the first SECRET_SCAN_CHARS bytes of a file.
    #
    # Reading from the file rather than a shell variable, for the same reason
    # the capture loop does: a variable cannot hold arbitrary clipboard bytes
    # faithfully, and the filter has to see what will actually be stored.
    local file="$1" pattern
    for pattern in "${SECRET_PATTERNS[@]}"; do
        if head -c "$SECRET_SCAN_CHARS" "$file" | grep -Eqi -- "$pattern"; then
            return 0
        fi
    done
    return 1
}

prune_old_entries() {
    local max_entries
    max_entries=$(config_get_int MAX_ENTRIES "$DEFAULT_MAX_ENTRIES")
    list_entries | tail -n +"$((max_entries + 1))" | while read -r old_file; do
        rm -f "$old_file"
    done
}

expire_stale_entries() {
    local expiry
    expiry=$(config_get_int EXPIRY_MINUTES "$DEFAULT_EXPIRY_MINUTES")
    [[ "$expiry" -le 0 ]] && return 0
    find "$HISTDIR" -maxdepth 1 -type f -name '[0-9]*' -mmin +"$expiry" -delete 2>/dev/null || true
}

# main loop
#
# The clipboard is held in files, never in a shell variable. Command
# substitution strips every trailing newline, so `x=$(xclip -o)` silently
# rewrites the clip: copy a block of shell output ending in a blank line and
# what comes back out of history is not what went in. For a tool whose whole
# job is to hand back exactly what was copied, that is a correctness bug, and
# it cannot be fixed by quoting -- the newlines are gone before the assignment
# happens. A temp file plus cmp compares bytes and keeps them.

CURRENT_CLIP=$(mktemp "${TMPDIR:-/tmp}/shadowclip-current.XXXXXX")
LAST_CLIP=$(mktemp "${TMPDIR:-/tmp}/shadowclip-last.XXXXXX")
chmod 600 "$CURRENT_CLIP" "$LAST_CLIP"
# These hold clipboard contents, so they are removed on every exit path, not
# just a clean one.
trap 'rm -f "$CURRENT_CLIP" "$LAST_CLIP"' EXIT INT TERM

loop_count=0

while true; do
    if ! is_paused; then
        xclip -selection clipboard -o > "$CURRENT_CLIP" 2>/dev/null || true

        if [[ -s "$CURRENT_CLIP" ]] && ! cmp -s "$CURRENT_CLIP" "$LAST_CLIP"; then
            # Record the value as seen either way, so a skipped secret is not
            # re-tested on every single poll until the clipboard changes.
            cp "$CURRENT_CLIP" "$LAST_CLIP"

            filter_on=$(config_get_bool SECRET_FILTER "$DEFAULT_SECRET_FILTER")
            if newest_entry_is_file "$CURRENT_CLIP"; then
                # Already the top of the history -- the picker put it there,
                # by adding a clip or restoring the newest one. Nothing to do
                # but note that we have seen it.
                :
            elif [[ "$filter_on" -eq 1 ]] && looks_like_secret_file "$CURRENT_CLIP"; then
                notify "Skipped a copied value that looks like a credential"
            else
                timestamp=$(date +%s%N)
                # Create with the right mode rather than chmod after: between
                # the write and the chmod the clip is briefly readable, and
                # this is the one file in the project most likely to hold a
                # credential.
                (umask 077 && cp "$CURRENT_CLIP" "$HISTDIR/$timestamp")
                prune_old_entries
            fi
        fi
    fi

    loop_count=$((loop_count + 1))
    if [[ $((loop_count % EXPIRY_CHECK_LOOPS)) -eq 0 ]]; then
        expire_stale_entries
    fi

    sleep "$POLL_INTERVAL"
done
