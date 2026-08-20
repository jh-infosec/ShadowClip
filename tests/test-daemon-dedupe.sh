#!/usr/bin/env bash
# Check the daemon does not record a clip the picker already stored.
#
# The picker writes an entry and puts the same text on the clipboard, because
# a clip you typed in by hand is one you want to paste now. The daemon's own
# last_value only knows what that process has seen, so without a check
# against what is already on disk the same text lands twice: once from the
# picker, once from the next poll half a second later.
#
# The daemon is a script with a `while true` at the bottom, so it cannot be
# sourced whole. Everything above the main loop is sourced instead, which is
# the function definitions and nothing that runs forever.

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"

DAEMON="../shadowclip-daemon.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SHADOWCLIP_HISTDIR="$TMP/hist"
export SHADOWCLIP_CONFIG_DIR="$TMP/config"
mkdir -p "$SHADOWCLIP_HISTDIR" "$SHADOWCLIP_CONFIG_DIR"

failed=0
total=0

check() {
    # check NAME EXPECTED_RC ACTUAL_RC
    total=$((total + 1))
    if [ "$2" -eq "$3" ]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

printf '=== daemon dedupe ===\n'

# Source the definitions only: everything before the main loop.
main_loop_line=$(grep -n '^# main loop' "$DAEMON" | head -n 1 | cut -d: -f1)
if [ -z "$main_loop_line" ]; then
    printf '  FAIL  could not find the main loop marker in %s\n' "$DAEMON"
    exit 1
fi
head -n "$((main_loop_line - 1))" "$DAEMON" > "$TMP/defs.sh"
# shellcheck disable=SC1090
source "$TMP/defs.sh"
# The daemon sets -e for its own run. Inheriting it here would abort this
# script the first time a check expects a non-zero return, which is most of
# them: "does this text match?" answering "no" is a pass, not a failure.
set +e

if ! declare -F newest_entry_is >/dev/null; then
    printf '  FAIL  newest_entry_is is not defined\n'
    exit 1
fi

# Empty history: nothing can match.
newest_entry_is "anything"
check "empty history matches nothing" 1 $?

printf '%s' "first clip" > "$SHADOWCLIP_HISTDIR/1700000000000000001"
sleep 0.05
printf '%s' "second clip" > "$SHADOWCLIP_HISTDIR/1700000000000000002"

newest_entry_is "second clip"
check "the newest entry matches its own text" 0 $?

newest_entry_is "first clip"
check "an older entry does not match, so restoring it still records" 1 $?

newest_entry_is "never stored"
check "unrelated text does not match" 1 $?

# Multi-line and whitespace must compare exactly, since a clip added by hand
# is commonly a block of output.
printf 'line one\nline two' > "$SHADOWCLIP_HISTDIR/1700000000000000003"
newest_entry_is "$(printf 'line one\nline two')"
check "multi-line text compares exactly" 0 $?

newest_entry_is "$(printf 'line one\nline three')"
check "a near-miss on line two does not match" 1 $?

# A pinned entry is in a subdirectory and is not the newest history entry,
# so it must not suppress a fresh capture of the same text.
mkdir -p "$SHADOWCLIP_HISTDIR/pinned"
printf '%s' "pinned text" > "$SHADOWCLIP_HISTDIR/pinned/1700000000000000009"
newest_entry_is "pinned text"
check "a pinned clip does not count as the newest entry" 1 $?

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'all %d checks passed\n' "$total"
    exit 0
fi
printf '%d of %d checks FAILED\n' "$failed" "$total"
exit 1
