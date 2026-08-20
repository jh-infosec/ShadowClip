#!/usr/bin/env python3
"""Check the picker does not close itself while being dragged.

The picker closes when it loses focus, which is what makes clicking away
dismiss it. Moving a window makes the window manager take a pointer grab,
and on some window managers that also takes focus -- so close-on-focus-out
fired mid-drag and the window vanished the instant the user tried to move
it. From the outside that looks like a window that refuses to move.

The guard has to tell a drag apart from a genuine click-away using only what
is knowable at that moment: which buttons are held, and where the pointer is
relative to this window's frame. Every case below is one way that pair of
facts can come out.

Needs a display, because it builds a window to check the guard is wired in.
Run under xvfb-run if there is not one.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, load_picker  # noqa: E402

picker = load_picker()

import gi  # noqa: E402
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk  # noqa: E402

NONE = Gdk.ModifierType(0)
B1 = Gdk.ModifierType.BUTTON1_MASK
B3 = Gdk.ModifierType.BUTTON3_MASK
SHIFT = Gdk.ModifierType.SHIFT_MASK

# A window at 100,100 sized 400x300, so its frame spans x 100-499, y 100-399.
FRAME = (100, 100, 400, 300)

CASES = [
    # name, mask, pointer, expected
    ("button held, pointer over the title bar", B1, (300, 105), True),
    ("button held, pointer mid-window", B1, (300, 250), True),
    ("right button held over the window", B3, (300, 250), True),
    ("button held with a modifier", B1 | SHIFT, (300, 250), True),

    ("no button held, pointer over the window", NONE, (300, 250), False),
    ("no button held, pointer elsewhere", NONE, (900, 900), False),
    ("modifier only, no button", SHIFT, (300, 250), False),

    ("button held but pointer on another window", B1, (900, 900), False),
    ("button held, pointer just left of the frame", B1, (99, 250), False),
    ("button held, pointer just above the frame", B1, (300, 99), False),
    ("button held, pointer just past the right edge", B1, (500, 250), False),
    ("button held, pointer just past the bottom edge", B1, (300, 400), False),

    ("button held, pointer on the top-left corner", B1, (100, 100), True),
    ("button held, pointer on the last pixel inside", B1, (499, 399), True),
]


def main():
    results = Results("drag guard")

    for name, mask, (px, py), expected in CASES:
        got = picker.drag_in_progress(mask, px, py, *FRAME)
        results.check(name, got, expected)

    # The guard has to actually be consulted, not merely defined. A window
    # that is not being dragged and has lost focus must still close.
    window = picker.PickerWindow()
    window.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration()

    closed = {"yes": False}
    window.connect("destroy", lambda *_: closed.__setitem__("yes", True))
    # Force the unfocused state. Without a window manager the window reports
    # itself active, and the close check returns early on that -- so both
    # halves of this would "pass" without ever reaching the guard.
    window.is_active = lambda: False

    window._being_dragged = lambda: True
    window._close_if_still_unfocused()
    results.check("a window being dragged is not closed", closed["yes"], False)

    window._being_dragged = lambda: False
    window._close_if_still_unfocused()
    results.check("a window not being dragged still closes", closed["yes"], True)

    # A modal child still wins over everything else.
    other = picker.PickerWindow()
    other.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration()
    other_closed = {"yes": False}
    other.connect("destroy", lambda *_: other_closed.__setitem__("yes", True))
    other.is_active = lambda: False
    other._modal_depth = 1
    other._being_dragged = lambda: False
    other._close_if_still_unfocused()
    results.check("a window with a dialog open is not closed",
                  other_closed["yes"], False)
    other._modal_depth = 0
    other.destroy()

    results.finish()


if __name__ == "__main__":
    main()
