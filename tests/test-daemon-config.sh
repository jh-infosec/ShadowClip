#!/usr/bin/env bash
# Check the daemon survives a hand-edited config.
#
# The config file is meant to be editable by hand -- the README says so -- and
# two values in it could previously take the daemon down or turn a security
# control off without saying anything:
#
#   MAX_ENTRIES=08    a leading zero made bash read it as octal, arithmetic
#                     aborted with "value too great for base", set -e killed
#                     the daemon, and systemd restarted it into the same
#                     failure on the next poll.
#
#   SECRET_FILTER=2   passed the integer check, then failed the "-eq 1" test
#                     at the point of use, silently disabling the filter that
#                     stops credentials being written to history.
#
# The second is the one that matters: a typo must never quietly turn
# protection off, so anything that is not exactly 0 or 1 falls back to on.

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# shellcheck source=_daemon_defs.sh
source ./_daemon_defs.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SHADOWCLIP_HISTDIR="$TMP/hist"
export SHADOWCLIP_CONFIG_DIR="$TMP/config"
mkdir -p "$SHADOWCLIP_HISTDIR" "$SHADOWCLIP_CONFIG_DIR"

failed=0
total=0

check() {
    # check NAME EXPECTED ACTUAL
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

printf '=== daemon config ===\n'

load_daemon_defs ../shadowclip-daemon.sh "$TMP/defs.sh" || exit 1
# shellcheck disable=SC1090
source "$TMP/defs.sh"
set +e

set_config() { printf '%s\n' "$@" > "$SHADOWCLIP_CONFIG_DIR/config"; }

printf -- '--- integers ---\n'

set_config "MAX_ENTRIES=15"
check "a plain value reads back" 15 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES=08"
check "a leading zero is read as decimal 8, not octal" 8 "$(config_get_int MAX_ENTRIES 99)"

# The real regression: the value has to survive arithmetic, which is where
# the daemon actually used it.
value=$(config_get_int MAX_ENTRIES 99)
result=$(( value + 1 ))
check "the result is usable in arithmetic" 9 "$result"

set_config "MAX_ENTRIES=09"
check "09 is decimal 9" 9 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES=0018"
check "multiple leading zeros still decimal" 18 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES=-5"
check "a negative falls back to the default" 99 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES=abc"
check "a non-number falls back to the default" 99 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES="
check "an empty value falls back to the default" 99 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES=99999999999999999999"
check "an absurd value falls back rather than reaching arithmetic" \
      99 "$(config_get_int MAX_ENTRIES 99)"

set_config "MAX_ENTRIES=5" "MAX_ENTRIES=7"
check "the last line wins on a duplicated key" 7 "$(config_get_int MAX_ENTRIES 99)"

rm -f "$SHADOWCLIP_CONFIG_DIR/config"
check "a missing config file falls back" 99 "$(config_get_int MAX_ENTRIES 99)"

printf -- '--- the secret filter switch ---\n'

set_config "SECRET_FILTER=1"
check "1 means on" 1 "$(config_get_bool SECRET_FILTER 1)"

set_config "SECRET_FILTER=0"
check "0 means off, and off is respected" 0 "$(config_get_bool SECRET_FILTER 1)"

set_config "SECRET_FILTER=2"
check "2 does NOT disable the filter" 1 "$(config_get_bool SECRET_FILTER 1)"

set_config "SECRET_FILTER=01"
check "01 does not disable the filter" 1 "$(config_get_bool SECRET_FILTER 1)"

set_config "SECRET_FILTER=true"
check "a word does not disable the filter" 1 "$(config_get_bool SECRET_FILTER 1)"

set_config "SECRET_FILTER="
check "an empty value does not disable the filter" 1 "$(config_get_bool SECRET_FILTER 1)"

set_config "SECRET_FILTER=-1"
check "a negative does not disable the filter" 1 "$(config_get_bool SECRET_FILTER 1)"

rm -f "$SHADOWCLIP_CONFIG_DIR/config"
check "no config at all leaves the filter on" 1 "$(config_get_bool SECRET_FILTER 1)"

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'all %d checks passed\n' "$total"
    exit 0
fi
printf '%d of %d checks FAILED\n' "$failed" "$total"
exit 1
