#!/usr/bin/env bash
# Check the systemd unit points at wherever the scripts were actually installed.
#
# SHADOWCLIP_BINDIR is documented and honoured by the installer, but the unit
# was copied verbatim and hardcodes ExecStart=%h/bin/shadowclip-daemon.sh. So
# installing into ~/.local/bin produced a service that either failed to start
# or -- the worse case -- silently kept running an older daemon still sitting
# in ~/bin, while the installer reported success either way.
#
# The unit is now generated with the chosen bindir and verified before it is
# installed. This exercises the installer's own function against a throwaway
# HOME rather than reimplementing the substitution, so the test fails if the
# installer stops doing it.

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")" || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failed=0
total=0

check() {
    # check NAME EXPECTED ACTUAL
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s\n          expected: %s\n          got:      %s\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

printf '=== installer service unit ===\n'

# systemctl is stubbed so install_service runs its real path to completion.
# The unit generation is what is under test, not systemd.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$TMP/stub/systemctl"
export PATH="$TMP/stub:$PATH"

# Definitions only: everything above the "# main" marker, so sourcing does not
# run a real install.
main_line=$(grep -n '^# main$' ../shadowclip-install.sh | head -n 1 | cut -d: -f1)
if [ -z "$main_line" ]; then
    printf '  FAIL  could not find the main marker in the installer\n'
    exit 1
fi

run_case() {
    # run_case LABEL BINDIR
    local label="$1" bindir="$2"
    local home="$TMP/home-$label"
    mkdir -p "$home" "$bindir"

    # A daemon has to exist and be executable, since the installer verifies it.
    printf '#!/bin/sh\nexit 0\n' > "$bindir/shadowclip-daemon.sh"
    chmod +x "$bindir/shadowclip-daemon.sh"

    (
        export HOME="$home"
        export SHADOWCLIP_BINDIR="$bindir"
        head -n "$((main_line - 1))" ../shadowclip-install.sh > "$TMP/defs-$label.sh"
        # shellcheck disable=SC1090
        source "$TMP/defs-$label.sh"
        set +e
        # Consumed by install_service, which was sourced above.
        # shellcheck disable=SC2034
        SOURCE_DIR="$(cd .. && pwd)"
        # shellcheck disable=SC2034
        SYSTEMD_USER_DIR="$home/.config/systemd/user"
        # shellcheck disable=SC2034
        BINDIR="$bindir"
        install_service >/dev/null 2>&1
    )
    grep -h '^ExecStart=' "$home/.config/systemd/user/shadowclip.service" 2>/dev/null \
        || printf '(no unit installed)'
}

got=$(run_case "localbin" "$TMP/localbin")
check "a custom bindir reaches ExecStart" \
      "ExecStart=$TMP/localbin/shadowclip-daemon.sh" "$got"

got=$(run_case "spaced" "$TMP/dir with spaces/bin")
check "a bindir containing spaces survives" \
      "ExecStart=$TMP/dir with spaces/bin/shadowclip-daemon.sh" "$got"

# The shipped unit keeps a sensible default for anyone installing by hand.
shipped=$(grep -h '^ExecStart=' ../shadowclip.service)
check "the shipped unit still carries a usable default" \
      "ExecStart=%h/bin/shadowclip-daemon.sh" "$shipped"

# And the generated unit must not still contain the placeholder it replaced.
home="$TMP/home-localbin"
if grep -q '%h/bin' "$home/.config/systemd/user/shadowclip.service" 2>/dev/null; then
    check "no leftover %h/bin in the generated unit" "absent" "present"
else
    check "no leftover %h/bin in the generated unit" "absent" "absent"
fi

# A missing daemon must abort rather than install a unit pointing at nothing.
emptydir="$TMP/empty/bin"
mkdir -p "$emptydir"
home="$TMP/home-missing"
mkdir -p "$home"
(
    export HOME="$home"
    head -n "$((main_line - 1))" ../shadowclip-install.sh > "$TMP/defs-missing.sh"
    # shellcheck disable=SC1090
    source "$TMP/defs-missing.sh"
    set +e
    # Consumed by install_service, which was sourced above.
    # shellcheck disable=SC2034
    SOURCE_DIR="$(cd .. && pwd)"
    # shellcheck disable=SC2034
    SYSTEMD_USER_DIR="$home/.config/systemd/user"
    # shellcheck disable=SC2034
    BINDIR="$emptydir"
    install_service >/dev/null 2>&1
)
if [ -f "$home/.config/systemd/user/shadowclip.service" ]; then
    check "no unit is installed when the daemon is missing" "no unit" "unit installed"
else
    check "no unit is installed when the daemon is missing" "no unit" "no unit"
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'all %d checks passed\n' "$total"
    exit 0
fi
printf '%d of %d checks FAILED\n' "$failed" "$total"
exit 1
