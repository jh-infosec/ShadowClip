#!/usr/bin/env bash
# Check the daemon stores exactly what was copied.
#
# Clipboard contents used to pass through a shell variable:
#
#     current_value=$(xclip -selection clipboard -o)
#
# Command substitution strips every trailing newline, so a copied block of
# shell output ending in a blank line came back out of history shorter than it
# went in. No quoting fixes it -- the bytes are gone before the assignment
# happens. For a tool whose entire job is handing back what was copied, that
# is a correctness bug rather than a cosmetic one, so the loop now keeps the
# clipboard in a file and compares with cmp.
#
# The end-to-end section runs the real daemon against a real X clipboard,
# because the bug lived in the plumbing between them and a unit test of the
# helpers alone would have missed it entirely. It is skipped, not failed,
# where Xvfb or xclip is unavailable.

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# shellcheck source=_daemon_defs.sh
source ./_daemon_defs.sh

TMP="$(mktemp -d)"
DAEMON_PID=""
XVFB_PID=""
cleanup() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

export SHADOWCLIP_HISTDIR="$TMP/hist"
export SHADOWCLIP_CONFIG_DIR="$TMP/config"
mkdir -p "$SHADOWCLIP_HISTDIR" "$SHADOWCLIP_CONFIG_DIR"

failed=0
total=0
skipped=0

pass() { total=$((total + 1)); printf '  PASS  %s\n' "$1"; }
fail() { total=$((total + 1)); failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { skipped=$((skipped + 1)); printf '  SKIP  %s\n' "$1"; }
check_rc() {
    # check_rc NAME EXPECTED_RC ACTUAL_RC
    if [ "$2" -eq "$3" ]; then pass "$1"; else
        fail "$1 (expected rc=$2, got rc=$3)"
    fi
}

printf '=== daemon capture ===\n'

load_daemon_defs ../shadowclip-daemon.sh "$TMP/defs.sh" || exit 1
# shellcheck disable=SC1090
source "$TMP/defs.sh"
set +e

printf -- '--- dedupe compares bytes ---\n'

candidate="$TMP/candidate"

printf '%s' "anything" > "$candidate"
newest_entry_is_file "$candidate"
check_rc "empty history matches nothing" 1 $?

printf '%s' "first clip" > "$SHADOWCLIP_HISTDIR/1700000000000000001"
sleep 0.05
printf '%s' "second clip" > "$SHADOWCLIP_HISTDIR/1700000000000000002"

printf '%s' "second clip" > "$candidate"
newest_entry_is_file "$candidate"
check_rc "the newest entry matches its own bytes" 0 $?

printf '%s' "first clip" > "$candidate"
newest_entry_is_file "$candidate"
check_rc "an older entry does not match, so restoring it still records" 1 $?

# The case the old string comparison could not see: same text, different
# trailing whitespace. Those are different clips and must not dedupe.
printf 'second clip\n\n' > "$SHADOWCLIP_HISTDIR/1700000000000000003"
printf 'second clip' > "$candidate"
newest_entry_is_file "$candidate"
check_rc "trailing newlines make it a different clip" 1 $?

printf 'second clip\n\n' > "$candidate"
newest_entry_is_file "$candidate"
check_rc "identical trailing newlines still match" 0 $?

printf -- '--- the secret filter reads the file ---\n'

printf 'ghp_%s' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$candidate"
looks_like_secret_file "$candidate"
check_rc "a GitHub token is caught" 0 $?

printf '5f4dcc3b5aa765d61d8327deb882cf99\n\n' > "$candidate"
looks_like_secret_file "$candidate"
check_rc "an md5 hash with trailing newlines is not a secret" 1 $?

printf 'HTB{a_flag_value}\n' > "$candidate"
looks_like_secret_file "$candidate"
check_rc "a CTF flag is not a secret" 1 $?

printf -- '--- end to end: bytes survive a real capture ---\n'

if ! command -v Xvfb >/dev/null 2>&1 || ! command -v xclip >/dev/null 2>&1; then
    skip "needs Xvfb and xclip"
else
    export DISPLAY=:87
    Xvfb :87 -screen 0 400x300x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 2

    rm -f "$SHADOWCLIP_HISTDIR"/[0-9]*
    bash ../shadowclip-daemon.sh >/dev/null 2>&1 &
    DAEMON_PID=$!
    sleep 1

    # Trailing newlines are the whole point. Two of them, after real content.
    original="$TMP/original"
    printf 'total 12\ndrwxr-xr-x 2 kali kali 4096 Nov  8 08:43 .\n\n\n' > "$original"
    xclip -selection clipboard -i < "$original"

    stored=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        stored=$(find "$SHADOWCLIP_HISTDIR" -maxdepth 1 -type f -name '[0-9]*' 2>/dev/null | head -n 1)
        [ -n "$stored" ] && break
    done

    if [ -z "$stored" ]; then
        fail "the daemon captured the clip at all"
    else
        pass "the daemon captured the clip"
        if cmp -s "$original" "$stored"; then
            pass "stored bytes are identical to what was copied"
        else
            fail "stored bytes differ: $(wc -c < "$original") in, $(wc -c < "$stored") out"
        fi
        original_bytes=$(wc -c < "$original")
        stored_bytes=$(wc -c < "$stored")
        if [ "$original_bytes" -eq "$stored_bytes" ]; then
            pass "byte count matches ($original_bytes)"
        else
            fail "byte count differs: $original_bytes in, $stored_bytes out"
        fi
    fi

    kill "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""
    kill "$XVFB_PID" 2>/dev/null; XVFB_PID=""
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'all %d checks passed' "$total"
    [ "$skipped" -gt 0 ] && printf ' (%d skipped)' "$skipped"
    printf '\n'
    exit 0
fi
printf '%d of %d checks FAILED\n' "$failed" "$total"
exit 1
