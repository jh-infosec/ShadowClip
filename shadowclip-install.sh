#!/bin/bash
#
# shadowclip-install.sh
#
# Installs ShadowClip: copies the scripts and theme into the install
# directory, enables the systemd user service, and binds both hotkeys.
#
# Hotkey binding is the reason this script exists. Every previous version
# ended with a README instruction to bind the toggle by hand, and it was
# never done. On Xfce the shortcut store is xfconf, which can be written
# from a script, so the step no longer depends on remembering it.
#
# Existing shortcuts are never overwritten. If a key combination is already
# bound to something else, this script says so and moves on rather than
# silently stealing it.
#
# Safe to re-run. Nothing here needs root.

set -euo pipefail

# config

: "${SHADOWCLIP_BINDIR:=$HOME/bin}"
: "${SHADOWCLIP_PICKER_KEY:=<Primary><Alt>v}"
: "${SHADOWCLIP_TOGGLE_KEY:=<Primary><Alt>p}"

SOURCE_DIR="$(dirname "$(readlink -f "$0")")"
BINDIR="$SHADOWCLIP_BINDIR"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
SCRIPTS=(shadowclip-daemon.sh shadowclip-picker.sh shadowclip-toggle.sh)
EXTRA=(shadowclip-picker.py)
ICON_SIZES=(16 24 32 48 64 128 256)

# helpers

say() {
    printf '%s\n' "$1"
}

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        say "missing dependency: $1 -- install it with: sudo apt install $2"
        return 1
    fi
}

# steps

check_dependencies() {
    say "== dependencies =="
    local failed=0
    require xclip xclip || failed=1
    require python3 python3 || failed=1
    # Heredoc rather than an inline -c string. The nested quoting the latter
    # needs is unreadable and one edit away from silently testing nothing.
    if ! python3 - <<'PYCHECK' 2>/dev/null; then
import gi
gi.require_version('Gtk', '3.0')
PYCHECK
        say "missing dependency: GTK3 for Python -- install it with:"
        say "  sudo apt install python3-gi gir1.2-gtk-3.0"
        failed=1
    fi
    command -v notify-send >/dev/null 2>&1 \
        || say "note: notify-send not found, notifications will be skipped"
    if [[ $failed -eq 1 ]]; then
        say "install the missing packages and re-run this script"
        exit 1
    fi
    say "ok"
}

install_files() {
    say ""
    say "== scripts =="
    # Stop the daemon first. `install` truncates and rewrites the destination
    # in place, and bash reads a script incrementally as it runs, so
    # overwriting shadowclip-daemon.sh underneath a live daemon can feed it
    # half of the old file and half of the new one.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop shadowclip.service 2>/dev/null || true
    fi
    mkdir -p "$BINDIR"
    for script in "${SCRIPTS[@]}"; do
        install -m 755 "$SOURCE_DIR/$script" "$BINDIR/$script"
        say "installed $BINDIR/$script"
    done
    for extra in "${EXTRA[@]}"; do
        install -m 755 "$SOURCE_DIR/$extra" "$BINDIR/$extra"
        say "installed $BINDIR/$extra"
    done
}

install_icons() {
    say ""
    say "== icons =="
    if [ ! -d "$SOURCE_DIR/icons" ]; then
        say "no icons directory in the release -- skipping"
        return 0
    fi
    # Into the user's hicolor theme, so the window manager, the task
    # switcher and any dock find the logo by name rather than the picker
    # having to hand them a file. The picker falls back to the release
    # folder when this step has not run, so it is safe to skip.
    local n=0
    for size in "${ICON_SIZES[@]}"; do
        src="$SOURCE_DIR/icons/shadowclip-$size.png"
        [ -f "$src" ] || continue
        mkdir -p "$ICON_DIR/${size}x${size}/apps"
        install -m 644 "$src" "$ICON_DIR/${size}x${size}/apps/shadowclip.png"
        n=$((n + 1))
    done
    if [ -f "$SOURCE_DIR/icons/shadowclip.svg" ]; then
        mkdir -p "$ICON_DIR/scalable/apps"
        install -m 644 "$SOURCE_DIR/icons/shadowclip.svg" \
            "$ICON_DIR/scalable/apps/shadowclip.svg"
        n=$((n + 1))
    fi
    say "installed $n icon files under $ICON_DIR"
    # Refresh the theme cache if the tool is present. Without it a running
    # session can keep showing the old icon, or none, until the next login.
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t -f "$ICON_DIR" 2>/dev/null || true
        say "refreshed the icon cache"
    fi
}

install_service() {
    say ""
    say "== service =="
    if ! command -v systemctl >/dev/null 2>&1; then
        say "systemd not found -- add $BINDIR/shadowclip-daemon.sh to your"
        say "desktop's autostart instead"
        return 0
    fi
    mkdir -p "$SYSTEMD_USER_DIR"
    # The unit is generated, not copied. The shipped file carries the default
    # path so it still works if someone installs it by hand, but SHADOWCLIP_BINDIR
    # can move the scripts anywhere -- and a unit copied verbatim would keep
    # pointing at ~/bin. Installing into ~/.local/bin then produced a service
    # that either failed to start or, worse, silently kept running an older
    # copy left in ~/bin while the installer reported success.
    local unit="$SYSTEMD_USER_DIR/shadowclip.service"
    local tmp_unit="$unit.tmp.$$"
    sed "s|^ExecStart=.*|ExecStart=$BINDIR/shadowclip-daemon.sh|" \
        "$SOURCE_DIR/shadowclip.service" > "$tmp_unit"

    # Verify before installing. A unit naming a path that is not there fails
    # at start time with a message that points at systemd rather than at the
    # real cause, so it is caught here instead.
    if ! grep -q "^ExecStart=$BINDIR/shadowclip-daemon.sh$" "$tmp_unit"; then
        rm -f "$tmp_unit"
        say "could not set ExecStart in the service unit -- aborting"
        return 1
    fi
    if [ ! -x "$BINDIR/shadowclip-daemon.sh" ]; then
        rm -f "$tmp_unit"
        say "$BINDIR/shadowclip-daemon.sh is missing or not executable -- aborting"
        return 1
    fi
    install -m 644 "$tmp_unit" "$unit"
    rm -f "$tmp_unit"
    say "service points at $BINDIR/shadowclip-daemon.sh"
    systemctl --user daemon-reload
    # enable, then restart rather than `enable --now`. `--now` starts a
    # stopped service but leaves a running one alone, so re-running the
    # installer to pick up new scripts left the old daemon in memory.
    systemctl --user enable shadowclip.service
    systemctl --user restart shadowclip.service
    say "enabled and restarted shadowclip.service"
    if systemctl --user is-active --quiet shadowclip.service; then
        say "daemon is running"
    else
        say "daemon is not running -- check: systemctl --user status shadowclip.service"
    fi
}

bind_hotkey() {
    # bind_hotkey KEY COMMAND LABEL
    local key="$1" command="$2" label="$3" property existing
    property="/commands/custom/${key}"
    existing=$(xfconf-query -c xfce4-keyboard-shortcuts -p "$property" 2>/dev/null || true)

    if [[ -z "$existing" ]]; then
        xfconf-query -c xfce4-keyboard-shortcuts -p "$property" -n -t string -s "$command"
        say "bound $label to $key"
    elif [[ "$existing" == "$command" ]]; then
        say "$label already bound to $key"
    else
        say "$key is already bound to: $existing"
        say "  leaving it alone -- bind $label by hand, or set"
        say "  SHADOWCLIP_${label^^}_KEY and re-run"
    fi
}

install_hotkeys() {
    say ""
    say "== hotkeys =="
    if ! command -v xfconf-query >/dev/null 2>&1; then
        say "xfconf-query not found, so this is not Xfce"
        say "bind these two commands by hand in your desktop's keyboard settings:"
        say "  picker  $BINDIR/shadowclip-picker.sh"
        say "  toggle  $BINDIR/shadowclip-toggle.sh"
        return 0
    fi
    bind_hotkey "$SHADOWCLIP_PICKER_KEY" "$BINDIR/shadowclip-picker.sh" "picker"
    bind_hotkey "$SHADOWCLIP_TOGGLE_KEY" "$BINDIR/shadowclip-toggle.sh" "toggle"
}

report_storage() {
    say ""
    say "== storage =="
    local histdir="${XDG_RUNTIME_DIR:-$HOME/.cache}/shadowclip"
    say "history directory: $histdir"
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        say "this is tmpfs, so history is held in memory and cleared on logout"
    else
        say "XDG_RUNTIME_DIR is unset, so history is written to disk under ~/.cache"
    fi
    local legacy="$HOME/.cache/shadowclip"
    if [[ "$histdir" != "$legacy" && -d "$legacy" ]]; then
        say ""
        say "an older on-disk history exists at $legacy"
        say "it is no longer read -- remove it when you are ready:"
        say "  rm -rf $legacy"
    fi
}

# main

say "ShadowClip installer"
say ""
check_dependencies
install_files
install_icons
install_service
install_hotkeys
report_storage
say ""
say "done -- press ${SHADOWCLIP_PICKER_KEY} to open the picker"
