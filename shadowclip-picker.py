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

import contextlib
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
PAUSE_FILE = os.path.join(HISTDIR, ".paused")
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
APP_ID = "shadowclip"       # icon theme name, installed under hicolor


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


# bulk actions
#
# Every one of these deletes only entry files, which are named as a pure
# timestamp. `.paused` and `.picker.pid` are not, so they are untouched by
# construction rather than by a filter that could be forgotten. Removing the
# PID lock while the picker is running would break single-instance and let the
# hotkey stack a second window.

def clear_history():
    """Delete unpinned entries. Pinned ones survive.

    This is the routine action, and it follows the same rule as prune and
    expiry: pinned entries are the ones marked as worth surviving it.
    """
    removed = 0
    for path in list_history():
        delete(path)
        removed += 1
    return removed


def clear_pinned():
    removed = 0
    for path in list_pinned():
        delete(path)
        removed += 1
    return removed


def unpin_all():
    moved = 0
    for path in list_pinned():
        try:
            unpin(path)
            moved += 1
        except OSError:
            pass
    return moved


def legacy_disk_dirs():
    """On-disk history directories that are not the one currently in use.

    History normally lives in tmpfs, so there is nothing on disk to clear.
    The exception is `~/.cache/shadowclip`, left by a pre-0.3 install or by a
    session where XDG_RUNTIME_DIR was unset. A reset that claims to clear
    everything has to account for it, or the claim is false.

    Compared by real path, so when ~/.cache IS the active history directory it
    is not listed as legacy and not removed twice.
    """
    active = os.path.realpath(HISTDIR)
    found = []
    for path in (os.path.expanduser("~/.cache/shadowclip"),):
        if os.path.isdir(path) and os.path.realpath(path) != active:
            found.append(path)
    return found


def remove_disk_history():
    removed = []
    for path in legacy_disk_dirs():
        try:
            shutil.rmtree(path)
            removed.append(path)
        except OSError:
            pass
    return removed


# pause, the same flag file the daemon and toggle script use

def is_paused():
    return os.path.exists(PAUSE_FILE)


def set_paused(paused):
    if paused:
        os.makedirs(HISTDIR, exist_ok=True)
        os.close(os.open(PAUSE_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
    else:
        try:
            os.remove(PAUSE_FILE)
        except OSError:
            pass


# the live clipboard

def clipboard_text():
    try:
        result = subprocess.run(
            ["xclip", "-selection", "clipboard", "-o"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2,
        )
        return result.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""


def clear_clipboard():
    """Empty the X11 clipboard selection itself, and confirm it worked.

    Clearing history does not clear the clipboard. If the reason for resetting
    is that a credential was just copied, that credential is still sitting in
    the live selection and any application can still ask for it.

    There is no single portable way to disown an X selection, so the result is
    read back rather than assumed. Reporting success while the secret is still
    pasteable would be worse than not offering this at all.

    Returns True only if a read-back comes back empty.
    """
    try:
        if shutil.which("xsel"):
            # xsel has an explicit clear, which disowns the selection outright.
            subprocess.run(["xsel", "--clipboard", "--clear"], timeout=2,
                           stderr=subprocess.DEVNULL)
        else:
            # Take ownership serving zero bytes. Detached, for the same reason
            # restore is: this process is about to carry on or exit.
            proc = subprocess.Popen(
                ["setsid", "xclip", "-selection", "clipboard", "-i"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            proc.stdin.close()
    except (OSError, subprocess.SubprocessError):
        return False
    # The new owner needs a moment to answer the read-back.
    time.sleep(0.2)
    return clipboard_text() == ""


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

def _apply_icon(window):
    """Give the window the ShadowClip logo.

    Two sources, in order. An installed copy is in the hicolor icon theme
    under the name in APP_ID, which is what the window manager, the task
    switcher and any dock will look up. A copy run straight out of a release
    folder has no installed icon, so fall back to the icons directory beside
    this script -- otherwise the picker would show a generic placeholder for
    anyone trying it before installing.

    Failure here is cosmetic, so nothing raises: a missing icon should never
    stop the picker from opening.
    """
    try:
        if Gtk.IconTheme.get_default().has_icon(APP_ID):
            Gtk.Window.set_default_icon_name(APP_ID)
            window.set_icon_name(APP_ID)
            return
    except Exception:
        pass

    # PNG before SVG deliberately. gdk-pixbuf only reads SVG when the
    # librsvg loader is installed, which is common but not guaranteed, and a
    # box without it raises here rather than falling back on its own.
    here = os.path.dirname(os.path.abspath(__file__))
    for name in ("shadowclip-256.png", "shadowclip.svg", "shadowclip-48.png"):
        path = os.path.join(here, "icons", name)
        if not os.path.exists(path):
            continue
        try:
            Gtk.Window.set_default_icon_from_file(path)
            window.set_icon_from_file(path)
            return
        except (GLib.Error, OSError):
            continue


class PickerWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="ShadowClip")
        self.preview_chars = config_get_int("PREVIEW_CHARS")
        self.set_default_size(config_get_int("WINDOW_WIDTH"),
                              config_get_int("WINDOW_HEIGHT"))
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_keep_above(True)
        _apply_icon(self)

        self.connect("destroy", lambda *_: Gtk.main_quit())
        self.connect("key-press-event", self.on_key)
        # Clicking away closes the picker, the same as Escape.
        #
        # Closing rather than hiding is deliberate. The picker is
        # single-instance through a PID lock held by the process. A hidden
        # window still holds that lock, so the next hotkey press would take
        # the toggle path and kill the hidden window instead of showing it:
        # the user would press the key and get nothing. The window opens
        # instantly, so there is nothing to gain by keeping it around.
        # Dialogs and the right-click menu take focus from this window, which
        # would otherwise close the picker out from underneath them.
        self._modal_depth = 0
        self.connect("focus-out-event", self.on_focus_out)
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
        # Single click selects, double click restores. GTK's default is
        # activate-on-single-click, which made one stray click restore an
        # entry and close the window before the user had read the row.
        # Enter still activates the selected row, so the keyboard path is
        # unchanged and remains the fastest way through.
        self.listbox.set_activate_on_single_click(False)
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

        /* Every row carries a left bar that is transparent until the row is
           selected, so turning it amber costs no horizontal space and the
           text never shifts sideways as the selection moves. */
        row { background-color: #000000; background-image: none;
              border-bottom: 1px solid #001a00;
              border-left: 3px solid transparent; }
        label { color: #00CC33; }
        .num { color: #007A3D; }
        .pinbtn { color: #FF3355; background: none; background-image: none;
                  border: none; padding: 0 8px 0 0; }
        .pinned label { color: #FF3355; }

        /* Selection.

           background-image: none is the load-bearing declaration here, not
           tidiness. The desktop theme paints a selected row with a
           linear-gradient, and a gradient is a background *image*: it is
           drawn over background-color, so every colour this stylesheet set
           for a selected row was being covered by theme grey regardless of
           what we chose. That is why the selected row rendered grey while
           this file said #00FF41, and why 0.5.3's backdrop pass did not fix
           it -- that pass corrected label colours, which were never the
           problem. Clearing the image is the fix. The colours below are
           taste.

           Those colours: amber, matching the Reset button, and built the way
           every other surface in the picker is built -- a dark tinted fill
           under bright text, rather than a bright fill under dark text. The
           row keeps its own text colour, green normally and red when pinned,
           so a pinned row is still legible as pinned while selected. The bar
           down the left edge is what says "selected", which is why the text
           colour does not have to. */
        row:selected { background-color: #3A2A00; background-image: none;
                       border-left-color: #FFB000; }
        row:selected label { color: #FFB000; }
        row:selected .num { color: #C98A00; }
        row:selected .pinbtn { color: #FF3355; }
        .pinned:selected { background-color: #2A0A10; background-image: none;
                           border-left-color: #FFB000; }
        .pinned:selected label { color: #FF3355; }
        .pinned:selected .num { color: #C98A00; }

        /* Hover, kept quiet so it never reads as a selection. */
        row:hover { background-color: #0A0A0A; background-image: none; }
        row:selected:hover { background-color: #3A2A00; }
        .pinned:selected:hover { background-color: #2A0A10; }

        /* Backdrop: the state GTK applies when the window loses focus.
           Without these rules the desktop theme supplies the selection
           colour, and the picker looks different depending on which window
           the user clicked last. Every state above needs its twin. */
        window:backdrop { background-color: #000000; }
        list:backdrop { background-color: #000000; }
        label:backdrop { color: #00CC33; }
        .num:backdrop { color: #007A3D; }
        row:backdrop { background-color: #000000; background-image: none;
                       border-bottom-color: #001a00;
                       border-left-color: transparent; }
        row:selected:backdrop { background-color: #3A2A00;
                                background-image: none;
                                border-left-color: #FFB000; }
        row:selected:backdrop label { color: #FFB000; }
        row:selected:backdrop .num { color: #C98A00; }
        row:selected:backdrop .pinbtn { color: #FF3355; }
        .pinned:backdrop label { color: #FF3355; }
        .pinned:selected:backdrop { background-color: #2A0A10;
                                    background-image: none;
                                    border-left-color: #FFB000; }
        .pinned:selected:backdrop label { color: #FF3355; }
        .pinned:selected:backdrop .num { color: #C98A00; }
        row:hover:backdrop { background-color: #0A0A0A;
                             background-image: none; }
        row:selected:hover:backdrop { background-color: #3A2A00; }
        .pinned:selected:hover:backdrop { background-color: #2A0A10; }
        .toolbtn:hover:backdrop { background-color: #002a00; }
        .reset-tool:hover:backdrop { background-color: #2a1f00; }
        .toolbar:backdrop { background-color: #000000; }
        .searchbar:backdrop { background-color: #000000; }
        .statusbar:backdrop { color: #007A3D; }
        entry:backdrop { background-color: #001a00; color: #00FF41; }
        .pinbtn:backdrop { color: #FF3355; }
        .toolbtn:backdrop { color: #00FF41; background-color: #001a00;
                            border-color: #007A3D; }
        .pin-tool:backdrop { color: #FF3355; border-color: #FF3355; }
        .reset-tool:backdrop { color: #FFB000; border-color: #FFB000; }
        .danger label:backdrop { color: #FFB000; }
        .toolbtn { color: #00FF41; background-color: #001a00;
                   border: 1px solid #007A3D; padding: 4px 14px; margin: 0 4px; }
        .toolbtn:hover { background-color: #002a00; }
        .pin-tool { color: #FF3355; border-color: #FF3355; }
        .reset-tool { color: #FFB000; border-color: #FFB000; }
        .reset-tool:hover { background-color: #2a1f00; }
        .danger label { color: #FFB000; }
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

        reset_btn = Gtk.Button(label="\u21ba Reset")
        reset_btn.get_style_context().add_class("toolbtn")
        reset_btn.get_style_context().add_class("reset-tool")
        reset_btn.connect("clicked", self.on_reset)
        bar.pack_start(reset_btn, False, False, 0)

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

        # The menu is a separate window and takes focus, so guard for as long
        # as it is up rather than only while it is being built.
        self._modal_depth += 1
        menu.connect("deactivate", lambda *_: self._menu_closed())
        menu.show_all()
        menu.popup_at_pointer(None)

    def _menu_closed(self):
        self._modal_depth -= 1
        # Dismissing the menu by clicking elsewhere should still close the
        # picker, so re-test once the menu has gone.
        GLib.idle_add(self._close_if_still_unfocused)

    def _delete_row(self, path):
        delete(path)
        self.refresh()

    def on_settings(self, button):
        with self.modal():
            SettingsDialog(self).run_and_apply()
        self.preview_chars = config_get_int("PREVIEW_CHARS")
        self.refresh()

    def on_reset(self, button):
        with self.modal():
            changed = run_reset_dialog(self)
        if changed:
            self.refresh()

    @contextlib.contextmanager
    def modal(self):
        """Suppress close-on-focus-out for the duration of a child window.

        Counted rather than a boolean, because a dialog can open another one
        (reset opens its confirmation, then its summary) and the inner one
        closing must not re-arm the outer.
        """
        self._modal_depth += 1
        try:
            yield
        finally:
            self._modal_depth -= 1

    def on_focus_out(self, widget, event):
        if self._modal_depth > 0:
            return False
        # Defer by one main-loop pass. A click that moves focus to our own
        # menu or dialog can land here before that window registers, so
        # re-checking a moment later avoids closing on our own popups.
        GLib.idle_add(self._close_if_still_unfocused)
        return False

    def _close_if_still_unfocused(self):
        if self._modal_depth == 0 and not self.is_active():
            self.destroy()
        return False

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


# reset
#
# Reset is deliberately separate from "Clear history". Clearing is the routine
# action and spares pinned entries by design. Reset is the one action that
# destroys something the user deliberately marked as worth keeping, so it
# confirms, states the counts, and puts each destructive part behind its own
# checkbox rather than assuming.

def run_reset_dialog(parent):
    """Confirm and perform a reset. Returns True if anything was removed."""
    history_count = len(list_history())
    pinned_count = len(list_pinned())
    disk_dirs = legacy_disk_dirs()

    if not (history_count or pinned_count or disk_dirs):
        _message(parent, "Nothing to reset", "History is already empty.")
        return False

    dialog = Gtk.Dialog(title="Reset ShadowClip", transient_for=parent, flags=0)
    dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL,
                       "Reset", Gtk.ResponseType.OK)
    dialog.set_default_size(420, -1)
    box = dialog.get_content_area()
    box.set_spacing(8)
    box.set_margin_top(12)
    box.set_margin_bottom(12)
    box.set_margin_start(14)
    box.set_margin_end(14)

    heading = Gtk.Label(xalign=0.0)
    heading.set_markup(
        "<b>Delete {} clip{} and start fresh?</b>".format(
            history_count, "" if history_count == 1 else "s"))
    heading.get_style_context().add_class("danger")
    box.pack_start(heading, False, False, 0)

    note = Gtk.Label(xalign=0.0)
    note.set_line_wrap(True)
    note.set_text("This cannot be undone.")
    box.pack_start(note, False, False, 0)

    pinned_check = Gtk.CheckButton(
        label="Also delete {} pinned clip{}".format(
            pinned_count, "" if pinned_count == 1 else "s"))
    # Checked by default: deleting pins is the only thing that distinguishes
    # reset from clear, so someone who wants pins kept wants Clear history.
    pinned_check.set_active(True)
    pinned_check.set_sensitive(pinned_count > 0)
    if pinned_count == 0:
        pinned_check.set_active(False)
        pinned_check.set_label("No pinned clips")
    box.pack_start(pinned_check, False, False, 0)

    clipboard_check = Gtk.CheckButton(label="Also empty the clipboard itself")
    clipboard_check.set_active(True)
    clipboard_check.set_tooltip_text(
        "Clearing history does not clear the live X11 selection. If you just "
        "copied a credential it is still pasteable until this is done. You "
        "will have nothing to paste afterwards.")
    box.pack_start(clipboard_check, False, False, 0)

    disk_check = None
    if disk_dirs:
        disk_check = Gtk.CheckButton(
            label="Also remove on-disk history at {}".format(disk_dirs[0]))
        disk_check.set_active(True)
        box.pack_start(disk_check, False, False, 0)
    else:
        where = Gtk.Label(xalign=0.0)
        where.set_line_wrap(True)
        where.set_markup(
            "<small>History is in tmpfs at {}, so there is nothing on disk "
            "to clear.</small>".format(GLib.markup_escape_text(HISTDIR)))
        box.pack_start(where, False, False, 0)

    dialog.show_all()
    response = dialog.run()
    choices = {
        "pinned": pinned_check.get_active(),
        "clipboard": clipboard_check.get_active(),
        "disk": bool(disk_check and disk_check.get_active()),
    }
    dialog.destroy()

    if response != Gtk.ResponseType.OK:
        return False

    lines = []
    lines.append("Deleted {} clip{}.".format(
        clear_history(), "" if history_count == 1 else "s"))
    if choices["pinned"]:
        lines.append("Deleted {} pinned clip{}.".format(
            clear_pinned(), "" if pinned_count == 1 else "s"))
    if choices["disk"]:
        removed = remove_disk_history()
        lines.append("Removed on-disk history at {}.".format(", ".join(removed))
                     if removed else "On-disk history could not be removed.")
    if choices["clipboard"]:
        # Reported honestly either way. A confirmation that says the clipboard
        # is empty when it is not would be the worst possible failure here.
        lines.append("Clipboard emptied." if clear_clipboard()
                     else "Clipboard could NOT be emptied. The last copied "
                          "value is still pasteable.")

    _message(parent, "Reset complete", "\n".join(lines))
    return True


def _message(parent, title, text):
    dialog = Gtk.MessageDialog(
        transient_for=parent, flags=0, message_type=Gtk.MessageType.INFO,
        buttons=Gtk.ButtonsType.OK, text=title,
    )
    dialog.format_secondary_text(text)
    dialog.run()
    dialog.destroy()


def confirm(parent, title, text):
    dialog = Gtk.MessageDialog(
        transient_for=parent, flags=0, message_type=Gtk.MessageType.QUESTION,
        buttons=Gtk.ButtonsType.OK_CANCEL, text=title,
    )
    dialog.format_secondary_text(text)
    response = dialog.run()
    dialog.destroy()
    return response == Gtk.ResponseType.OK


class SettingsDialog:
    # A plain form for the integer settings the rofi version handled through a
    # submenu, plus the bulk actions below it.
    #
    # Settings are applied on Save. The actions are not: they fire immediately
    # and confirm for themselves, because "Cancel" on a dialog should never be
    # the thing standing between the user and a deletion that already looked
    # like it happened.
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

        # Capture pause, the same flag file the toggle hotkey writes.
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.pack_start(Gtk.Label(label="Capturing", xalign=0.0), True, True, 0)
        self.pause_switch = Gtk.Switch()
        self.pause_switch.set_active(not is_paused())
        self.pause_switch.connect("notify::active", self.on_pause_toggled)
        row.pack_start(self.pause_switch, False, False, 0)
        box.pack_start(row, False, False, 0)

        # Bulk actions. These were in the rofi settings submenu and were lost
        # in the 0.5.0 GTK rewrite; without them the only way to remove
        # anything was right-clicking rows one at a time.
        box.pack_start(Gtk.Separator(), False, False, 6)
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        clear_btn = Gtk.Button(label="Clear history")
        clear_btn.set_tooltip_text("Delete unpinned clips. Pinned clips are kept.")
        clear_btn.connect("clicked", self.on_clear_history)
        actions.pack_start(clear_btn, True, True, 0)
        unpin_btn = Gtk.Button(label="Unpin all")
        unpin_btn.connect("clicked", self.on_unpin_all)
        actions.pack_start(unpin_btn, True, True, 0)
        box.pack_start(actions, False, False, 0)

    def on_pause_toggled(self, switch, _param):
        # Switch on means capturing, so paused is the inverse.
        set_paused(not switch.get_active())

    def on_clear_history(self, button):
        count = len(list_history())
        pinned = len(list_pinned())
        if not count:
            _message(self.dialog, "Nothing to clear", "There are no unpinned clips.")
            return
        kept = "" if not pinned else " {} pinned clip{} will be kept.".format(
            pinned, "" if pinned == 1 else "s")
        if confirm(self.dialog, "Clear history?",
                   "Delete {} clip{}.{}".format(
                       count, "" if count == 1 else "s", kept)):
            clear_history()
            self.parent.refresh()

    def on_unpin_all(self, button):
        count = len(list_pinned())
        if not count:
            _message(self.dialog, "Nothing to unpin", "There are no pinned clips.")
            return
        if confirm(self.dialog, "Unpin all?",
                   "Return {} pinned clip{} to normal history, where pruning "
                   "and expiry apply again.".format(
                       count, "" if count == 1 else "s")):
            unpin_all()
            self.parent.refresh()

    def run_and_apply(self):
        self.dialog.show_all()
        response = self.dialog.run()
        if response == Gtk.ResponseType.OK:
            for key, spin in self.spins.items():
                config_set_int(key, int(spin.get_value()))
            config_set_int("SECRET_FILTER", 1 if self.filter_switch.get_active() else 0)
        self.dialog.destroy()


# single instance / toggle

LOCK_FILE = os.path.join(HISTDIR, ".picker.pid")


def _process_alive(pid):
    # Signal 0 tests for the process without touching it. ESRCH means gone,
    # EPERM means alive but not ours, which for our own picker will not happen.
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def running_instance_pid():
    # Returns the PID of a live picker holding the lock, or None. A lock left
    # behind by a crashed process is treated as stale and ignored, so a crash
    # never wedges the picker shut.
    try:
        with open(LOCK_FILE) as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return None
    if pid != os.getpid() and _process_alive(pid):
        return pid
    return None


def toggle_closed_existing():
    # If another picker is up, close it and report that we did. This is what
    # turns a second hotkey press into "close" rather than "open another".
    # SIGTERM lets the running instance clean up its own lock in the finally
    # below; we do not delete its lock for it.
    pid = running_instance_pid()
    if pid is None:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return False
    return True


def write_lock():
    os.makedirs(HISTDIR, exist_ok=True)
    fd = os.open(LOCK_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(str(os.getpid()))


def clear_own_lock():
    try:
        with open(LOCK_FILE) as fh:
            if int(fh.read().strip()) == os.getpid():
                os.remove(LOCK_FILE)
    except (OSError, ValueError):
        pass


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    if not shutil.which("xclip"):
        sys.stderr.write("shadowclip-picker: xclip not found (sudo apt install xclip)\n")
        return 1

    # Toggle: a second launch while one is open closes the open one and stops.
    if toggle_closed_existing():
        return 0

    os.makedirs(HISTDIR, exist_ok=True)
    write_lock()

    # SIGTERM from the toggling instance must exit the loop cleanly so the
    # finally can remove the lock. Quitting GTK is the graceful way out.
    signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())

    try:
        win = PickerWindow()
        win.show_all()
        Gtk.main()
    finally:
        clear_own_lock()
    return 0


if __name__ == "__main__":
    sys.exit(main())
