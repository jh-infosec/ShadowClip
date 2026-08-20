#!/usr/bin/env python3
"""Check that the picker remembers where it was moved to.

The off-screen guard gets the most attention here. Restoring a position onto
a monitor that is no longer connected is not a cosmetic failure: the window
opens somewhere the user cannot see, and the way you would normally fix that
is by dragging the window you cannot see.

Needs a display. Run under xvfb-run if there is not one.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, load_picker  # noqa: E402

picker = load_picker()

import gi  # noqa: E402
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402


def centred(window):
    return window.get_property("window-position") == Gtk.WindowPosition.CENTER


def main():
    results = Results("window position")

    picker.config_set_int("WINDOW_X", 300)
    results.check("reads a positive coordinate",
                  picker.config_get_signed("WINDOW_X"), 300)

    picker.config_set_int("WINDOW_X", -1440)
    results.check("reads a negative coordinate, for a monitor to the left",
                  picker.config_get_signed("WINDOW_X"), -1440)

    results.check("returns None for a key that is not set",
                  picker.config_get_signed("WINDOW_NOT_SET"), None)

    picker.config_set_int("WINDOW_X", "not-a-number")
    results.check("returns None for a non-numeric value",
                  picker.config_get_signed("WINDOW_X"), None)

    picker.config_set_int("WINDOW_WIDTH", 650)
    picker.config_set_int("WINDOW_HEIGHT", 520)

    window = picker.PickerWindow()
    window.show_all()
    window.move(210, 140)
    while Gtk.events_pending():
        Gtk.main_iteration()
    window._save_geometry()
    saved = (picker.config_get_signed("WINDOW_X"),
             picker.config_get_signed("WINDOW_Y"))
    results.note("saved position: %r" % (saved,))
    results.check("a move writes both coordinates", None not in saved, True)
    results.check("size is saved alongside position",
                  picker.config_get_int("WINDOW_WIDTH") > 0, True)
    window.destroy()

    reopened = picker.PickerWindow()
    results.check("a saved position is used instead of centring",
                  centred(reopened), False)
    reopened.destroy()

    screen = picker.Gdk.Screen.get_default()
    width, height = screen.get_width(), screen.get_height()
    results.note("test screen: %dx%d" % (width, height))

    cases = [
        ("off the right edge", width + 500, 100, True),
        ("below the bottom edge", 100, height + 500, True),
        ("off the left edge entirely", -2000, 100, True),
        ("a normal on-screen position", 100, 100, False),
        ("nudged slightly past the left edge", -40, 100, False),
    ]
    for name, x, y, want_centre in cases:
        picker.config_set_int("WINDOW_X", x)
        picker.config_set_int("WINDOW_Y", y)
        candidate = picker.PickerWindow()
        results.check("%s -> %s" % (name, "centres" if want_centre else "restores"),
                      centred(candidate), want_centre)
        candidate.destroy()

    # A config holding only one coordinate is a half-finished save. Honouring
    # it would move the window on an axis the user never chose.
    picker.config_set_int("WINDOW_X", 400)
    with open(picker.CONFIG_FILE) as fh:
        kept = [line for line in fh if not line.startswith("WINDOW_Y=")]
    with open(picker.CONFIG_FILE, "w") as fh:
        fh.writelines(kept)
    partial = picker.PickerWindow()
    results.check("only one coordinate saved -> centres", centred(partial), True)
    partial.destroy()

    results.finish()


if __name__ == "__main__":
    main()
