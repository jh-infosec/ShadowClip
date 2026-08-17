#!/usr/bin/env python3
#
# shadowclip-picker.py
#
# The ShadowClip picker: a GTK3 window listing recent clipboard entries, with
# pinned entries first. Replaces the rofi front end from 0.4.x, which could
# not offer a toolbar that stayed put while the list scrolled, per-row pin
# icons, or a right-click menu. Those three are the whole reason for the move.
#
# This is only the front end. The daemon, the tmpfs history directory, the
# pinned subdirectory, the secret filter, the config file and the systemd
# service are unchanged. This program reads the same files the daemon writes
# and follows the same rules:
#
#   - history entries are files named with a nanosecond timestamp, directly
#     inside the history directory
#   - a pinned entry is the same file moved into the pinned/ subdirectory,
#     which the daemon's prune and expiry never look into
#   - restoring puts the entry back on the clipboard and the program exits
#
# The config file is read and written with the same parse-never-source rule
# as the shell scripts: plain KEY=VALUE lines, integers validated, anything
# unexpected ignored in favour of the default.
#
# Requires: python3-gi, gir1.2-gtk-3.0, xclip
#   sudo apt install python3-gi gir1.2-gtk-3.0 xclip

import os
import re
import shutil
import signal
import subprocess
import sys
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib, Pango  # noqa: E402


# paths, matching the shell scripts exactly

def _runtime_base():
    # Same resolution order as the daemon: XDG_RUNTIME_DIR if set (tmpfs),
    # otherwise ~/.cache. Keeping this identical is what lets the GUI and the
    # daemon share state without either knowing about the other.
    return os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~/.cache")


HISTDIR = os.environ.get("SHADOWCLIP_HISTDIR", os.path.join(_runtime_base(), "shadowclip"))
PINDIR = os.path.join(HISTDIR, "pinned")
CONFIG_DIR = os.environ.get("SHADOWCLIP_CONFIG_DIR", os.path.expanduser("~/.config/shadowclip"))
CONFIG_FILE = os.path.join(CONFIG_DIR, "config")

DEFAULTS = {
    "MAX_ENTRIES": 15,
    "EXPIRY_MINUTES": 30,
    "SECRET_FILTER": 1,
    "WINDOW_WIDTH": 650,
    "WINDOW_HEIGHT": 520,
    "PREVIEW_CHARS": 120,
}

PIN_ICON = "\U0001F4CC"     # 📌
ENTRY_RE = re.compile(r"^[0-9]+$")


# config: parsed, never executed

def config_get_int(key):
    default = DEFAULTS.get(key, 0)
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return default
    value = None
    for line in lines:
        if line.startswith(key + "="):
            value = line.split("=", 1)[1].strip()
    if value is not None and re.fullmatch(r"[0-9]+", value):
        return int(value)
    return default


def config_set_int(key, value):
    # Atomic upsert, same contract as the shell config_set: replace the key if
    # present, append if absent, leave every other key untouched, and never
    # leave a half-written file behind.
    os.makedirs(CONFIG_DIR, exist_ok=True)
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        lines = []
    kept = [ln for ln in lines if not ln.startswith(key + "=")]
    kept.append("{}={}\n".format(key, value))
    tmp = CONFIG_FILE + ".{}.tmp".format(os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.writelines(kept)
    os.replace(tmp, CONFIG_FILE)
    os.chmod(CONFIG_FILE, 0o600)


# history model

def _list_dir(path):
    # Newest first. Only files named as a pure timestamp count, which excludes
    # the pause flag and the pinned/ subdirectory, exactly as the daemon's
    # find -maxdepth 1 -type f -name '[0-9]*' does.
    try:
        names = os.listdir(path)
    except OSError:
        return []
    entries = []
    for name in names:
        if not ENTRY_RE.match(name):
            continue
        full = os.path.join(path, name)
        if os.path.isfile(full):
            entries.append(full)
    entries.sort(key=lambda p: os.path.basename(p), reverse=True)
    return entries


def list_history():
    return _list_dir(HISTDIR)


def list_pinned():
    return _list_dir(PINDIR)


def read_entry(path, limit):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except OSError:
        return ""


def is_pinned(path):
    return os.path.dirname(path) == PINDIR


def pin(path):
    os.makedirs(PINDIR, exist_ok=True)
    os.chmod(PINDIR, 0o700)
    target = os.path.join(PINDIR, os.path.basename(path))
    shutil.move(path, target)
    os.chmod(target, 0o600)
    return target


def unpin(path):
    target = os.path.join(HISTDIR, os.path.basename(path))
    shutil.move(path, target)
    os.chmod(target, 0o600)
    return target


def delete(path):
    try:
        os.remove(path)
    except OSError:
        pass


def restore_to_clipboard(path):
    # setsid detaches xclip into its own session so it outlives this process,
    # which exits immediately after. No -l limit: the daemon polls the
    # clipboard twice a second and would consume a single-serving selection
    # before the user could paste. That was the 0.4.x paste bug.
    data = read_entry(path, 10 * 1024 * 1024)
    proc = subprocess.Popen(
        ["setsid", "xclip", "-selection", "clipboard", "-i"],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    proc.stdin.write(data.encode("utf-8", "replace"))
    proc.stdin.close()


# preview text

def preview_of(path, limit):
    # Read generously before collapsing. Whitespace runs collapse to single
    # spaces, so reading only limit+1 chars can leave fewer than limit after
    # collapse and skip truncation entirely. Reading 4x the limit (with a
    # floor) guarantees enough surviving characters to fill the preview.
    raw = read_entry(path, max(limit * 4, 256))
    collapsed = " ".join(raw.split())
    if len(collapsed) > limit:
        collapsed = collapsed[:limit].rstrip() + "\u2026"
    return collapsed or "(empty)"


# the window

class PickerWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="ShadowClip")
        self.preview_chars = config_get_int("PREVIEW_CHARS")
        self.set_default_size(config_get_int("WINDOW_WIDTH"),
                              config_get_int("WINDOW_HEIGHT"))
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_keep_above(True)

        self.connect("destroy", Gtk.main_quit)
        self.connect("key-press-event", self.on_key)
        # Persist the size the user drags to, so the window remembers it.
        self.connect("configure-event", self.on_configure)
        self._save_pending = False

        self._build_css()

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)

        # Toolbar. This is a sibling of the scrolled list, not inside it, which
        # is the whole point: it never scrolls off. The rofi version could not
        # do this because rofi is one scrolling list with nothing fixed.
        outer.pack_start(self._build_toolbar(), False, False, 0)

        # Search box, also fixed above the scrolling area.
        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text("search clipboard history...")
        self.search.connect("search-changed", lambda *_: self.refresh())
        search_box = Gtk.Box()
        search_box.get_style_context().add_class("searchbar")
        search_box.pack_start(self.search, True, True, 0)
        outer.pack_start(search_box, False, False, 0)

        # The only scrolling region.
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.listbox.connect("row-activated", self.on_row_activated)
        scroller.add(self.listbox)
        outer.pack_start(scroller, True, True, 0)

        self.status = Gtk.Label(xalign=0.0)
        self.status.get_style_context().add_class("statusbar")
        outer.pack_start(self.status, False, False, 0)

        self.refresh()

    def _build_css(self):
        css = b"""
        window { background-color: #000000; }
        .toolbar { background-color: #000000; border-bottom: 2px solid #00FF41;
                   padding: 6px; }
        .searchbar { background-color: #000000; padding: 4px 8px; }
        entry { background-color: #001a00; color: #00FF41;
                border: 1px solid #007A3D; }
        .statusbar { color: #007A3D; padding: 4px 8px; font-size: 90%; }
        list { background-color: #000000; }
        row { border-bottom: 1px solid #001a00; }
        row:selected { background-color: #00FF41; }
        row:selected label { color: #000000; }
        label { color: #00CC33; }
        .num { color: #007A3D; }
        .pinbtn { color: #FF3355; background: none; border: none;
                  padding: 0 8px 0 0; }
        .pinned label { color: #FF3355; }
        .pinned:selected { background-color: #FF3355; }
        .pinned:selected label { color: #FFFFFF; }
        .toolbtn { color: #00FF41; background-color: #001a00;
                   border: 1px solid #007A3D; padding: 4px 14px; margin: 0 4px; }
        .toolbtn:hover { background-color: #002a00; }
        .pin-tool { color: #FF3355; border-color: #FF3355; }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _build_toolbar(self):
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        bar.get_style_context().add_class("toolbar")

        title = Gtk.Label(label="ShadowClip")
        title.get_style_context().add_class("num")
        bar.pack_start(title, False, False, 4)

        spacer = Gtk.Box()
        bar.pack_start(spacer, True, True, 0)

        pin_btn = Gtk.Button(label=PIN_ICON + " Pin selected")
        pin_btn.get_style_context().add_class("toolbtn")
        pin_btn.get_style_context().add_class("pin-tool")
        pin_btn.connect("clicked", self.on_pin_selected)
        bar.pack_start(pin_btn, False, False, 0)

        settings_btn = Gtk.Button(label="\u2699 Settings")
        settings_btn.get_style_context().add_class("toolbtn")
        settings_btn.connect("clicked", self.on_settings)
        bar.pack_start(settings_btn, False, False, 0)

        return bar

    # row construction

    def _make_row(self, path, number, pinned):
        row = Gtk.ListBoxRow()
        row.path = path
        row.pinned = pinned
        if pinned:
            row.get_style_context().add_class("pinned")

        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        box.set_margin_start(6)
        box.set_margin_end(6)
        box.set_margin_top(4)
        box.set_margin_bottom(4)

        # Per-row pin toggle. Click it and only it to pin or unpin, without
        # touching the row's own restore action. This is the "little pin emoji
        # to the left" that toggles in place.
        pin_btn = Gtk.Button(label=PIN_ICON)
        pin_btn.get_style_context().add_class("pinbtn")
        pin_btn.set_relief(Gtk.ReliefStyle.NONE)
        pin_btn.set_tooltip_text("Unpin" if pinned else "Pin")
        if not pinned:
            pin_btn.set_opacity(0.25)
        pin_btn.connect("clicked", self.on_toggle_pin, path)
        box.pack_start(pin_btn, False, False, 0)

        num = Gtk.Label(label=str(number), xalign=0.0)
        num.get_style_context().add_class("num")
        num.set_width_chars(3)
        box.pack_start(num, False, False, 0)

        text = Gtk.Label(label=preview_of(path, self.preview_chars), xalign=0.0)
        text.set_ellipsize(Pango.EllipsizeMode.END)
        box.pack_start(text, True, True, 0)

        row.add(box)

        # Right-click menu on the row.
        gesture = Gtk.GestureMultiPress.new(row)
        gesture.set_button(3)
        gesture.connect("pressed", self.on_right_click, row)
        row._gesture = gesture  # keep a reference so it is not collected

        return row

    def refresh(self, reselect_path=None):
        for child in self.listbox.get_children():
            self.listbox.remove(child)

        needle = self.search.get_text().lower()
        pinned = list_pinned()
        history = list_history()

        shown = 0
        first_row = None

        def add(path, number, is_pin):
            nonlocal shown, first_row
            if needle:
                if needle not in read_entry(path, 4096).lower():
                    return
            row = self._make_row(path, number, is_pin)
            self.listbox.add(row)
            if first_row is None:
                first_row = row
            if reselect_path and path == reselect_path:
                self.listbox.select_row(row)
            shown += 1

        for i, path in enumerate(pinned, 1):
            add(path, i, True)
        for i, path in enumerate(history, 1):
            add(path, i, False)

        self.listbox.show_all()
        if reselect_path is None and first_row is not None:
            self.listbox.select_row(first_row)

        total = len(pinned) + len(history)
        pin_note = "  \u00b7  {} pinned".format(len(pinned)) if pinned else ""
        filt = "  \u00b7  filtered" if needle else ""
        self.status.set_text("{} entries{}{}".format(total, pin_note, filt))

    # actions

    def _selected_path(self):
        row = self.listbox.get_selected_row()
        return row.path if row else None

    def on_row_activated(self, listbox, row):
        # Left-click or Enter on the row: restore and close, the fast path.
        restore_to_clipboard(row.path)
        self.destroy()

    def on_toggle_pin(self, button, path):
        # Toggle in place and stay open, reselecting the same entry so it does
        # not feel like the list jumped.
        new_path = unpin(path) if is_pinned(path) else pin(path)
        self.refresh(reselect_path=new_path)

    def on_pin_selected(self, button):
        path = self._selected_path()
        if not path:
            return
        new_path = unpin(path) if is_pinned(path) else pin(path)
        self.refresh(reselect_path=new_path)

    def on_right_click(self, gesture, n_press, x, y, row):
        self.listbox.select_row(row)
        menu = Gtk.Menu()

        label = "Unpin" if row.pinned else "Pin"
        item_pin = Gtk.MenuItem(label="{} {}".format(PIN_ICON, label))
        item_pin.connect("activate", lambda *_: self.on_toggle_pin(None, row.path))
        menu.append(item_pin)

        item_restore = Gtk.MenuItem(label="Restore to clipboard")
        item_restore.connect("activate", lambda *_: self.on_row_activated(self.listbox, row))
        menu.append(item_restore)

        item_del = Gtk.MenuItem(label="Delete")
        item_del.connect("activate", lambda *_: self._delete_row(row.path))
        menu.append(item_del)

        menu.show_all()
        menu.popup_at_pointer(None)

    def _delete_row(self, path):
        delete(path)
        self.refresh()

    def on_settings(self, button):
        SettingsDialog(self).run_and_apply()
        self.preview_chars = config_get_int("PREVIEW_CHARS")
        self.refresh()

    def on_key(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        # Ctrl+P pins the selected row, a keyboard equivalent for anyone who
        # wants one. Everything the toolbar does stays reachable without a
        # mouse.
        ctrl = event.state & Gdk.ModifierType.CONTROL_MASK
        if ctrl and event.keyval in (Gdk.KEY_p, Gdk.KEY_P):
            self.on_pin_selected(None)
            return True
        return False

    def on_configure(self, widget, event):
        # Debounce: a drag fires many configure events, and writing the config
        # on each one would hammer the file. Save once, shortly after the last.
        if self._save_pending:
            return False
        self._save_pending = True
        GLib.timeout_add(400, self._save_size)
        return False

    def _save_size(self):
        self._save_pending = False
        width, height = self.get_size()
        config_set_int("WINDOW_WIDTH", width)
        config_set_int("WINDOW_HEIGHT", height)
        return False


class SettingsDialog:
    # A plain form for the integer settings the rofi version handled through a
    # submenu. Pause and clear live here too, since they are actions rather
    # than list navigation.
    FIELDS = [
        ("MAX_ENTRIES", "Max entries stored"),
        ("EXPIRY_MINUTES", "Auto-expiry minutes (0 = never)"),
        ("PREVIEW_CHARS", "Preview length (characters)"),
    ]

    def __init__(self, parent):
        self.parent = parent
        self.dialog = Gtk.Dialog(title="ShadowClip settings", transient_for=parent, flags=0)
        self.dialog.add_buttons(
            "Cancel", Gtk.ResponseType.CANCEL,
            "Save", Gtk.ResponseType.OK,
        )
        self.dialog.set_default_size(360, -1)
        box = self.dialog.get_content_area()
        box.set_spacing(6)
        box.set_margin_top(10)
        box.set_margin_bottom(10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        self.spins = {}
        for key, label_text in self.FIELDS:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            label = Gtk.Label(label=label_text, xalign=0.0)
            row.pack_start(label, True, True, 0)
            adj = Gtk.Adjustment(value=config_get_int(key), lower=0,
                                 upper=100000, step_increment=1)
            spin = Gtk.SpinButton(adjustment=adj, climb_rate=1, digits=0)
            row.pack_start(spin, False, False, 0)
            self.spins[key] = spin
            box.pack_start(row, False, False, 0)

        # Secret filter as a switch.
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.pack_start(Gtk.Label(label="Secret filter", xalign=0.0), True, True, 0)
        self.filter_switch = Gtk.Switch()
        self.filter_switch.set_active(config_get_int("SECRET_FILTER") == 1)
        row.pack_start(self.filter_switch, False, False, 0)
        box.pack_start(row, False, False, 0)

    def run_and_apply(self):
        self.dialog.show_all()
        response = self.dialog.run()
        if response == Gtk.ResponseType.OK:
            for key, spin in self.spins.items():
                config_set_int(key, int(spin.get_value()))
            config_set_int("SECRET_FILTER", 1 if self.filter_switch.get_active() else 0)
        self.dialog.destroy()


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    if not shutil.which("xclip"):
        sys.stderr.write("shadowclip-picker: xclip not found (sudo apt install xclip)\n")
        return 1
    os.makedirs(HISTDIR, exist_ok=True)
    win = PickerWindow()
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
