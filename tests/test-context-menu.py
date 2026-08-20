#!/usr/bin/env python3
"""Check that right-clicking a row actually opens a menu.

This test used to stub out the popup and assert only on the menu's contents.
It passed while right click was completely broken in the running app, because
the part it skipped -- getting the menu on screen -- was the part that failed.
It now drives the real handler with a real button event and asserts on what
that handler hands to GTK, not just on what it builds.

Two specific regressions are pinned here:

- popup_at_pointer must receive the actual event. Passing None makes GTK fall
  back to gtk_get_current_event(), which can be empty, and an empty fallback
  means the menu is built and then never shown.
- The handler must resolve the row under the pointer itself. The per-row
  gesture this replaced never fired, because a Gtk.ListBoxRow draws no window
  of its own and had no button-press mask.

Needs a display. Run under xvfb-run if there is not one.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, load_picker  # noqa: E402

picker = load_picker()

import gi  # noqa: E402
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk  # noqa: E402


def settle():
    while Gtk.events_pending():
        Gtk.main_iteration()


def press_event(button, y):
    """Build a button-press event the way GTK delivers one.

    The fields have to be set through the .button union member. Assigning
    event.button directly does not set the button number -- reading it back
    returns the union member itself -- so an event built that way silently
    fails every "is this button 3?" test it is given.
    """
    event = Gdk.Event.new(Gdk.EventType.BUTTON_PRESS)
    event.button.button = button
    event.button.x = 20.0
    event.button.y = float(y)
    event.button.time = 0
    return event.button


class Popups:
    """Record every popup_at_pointer call and the event it was given."""

    def __init__(self):
        self.calls = []
        self._original = Gtk.Menu.popup_at_pointer
        outer = self

        def spy(menu, event):
            outer.calls.append({
                "labels": [c.get_label() for c in menu.get_children()],
                "event": event,
            })

        Gtk.Menu.popup_at_pointer = spy

    def restore(self):
        Gtk.Menu.popup_at_pointer = self._original


def main():
    results = Results("context menu")

    picker.add_entry("first clip, stays unpinned")
    picker.add_entry("second clip, gets pinned")
    picker.pin(picker.list_history()[0])

    window = picker.PickerWindow()
    window.show_all()
    settle()

    rows = [r for r in window.listbox.get_children() if hasattr(r, "path")]
    results.check("both clips are listed", len(rows), 2)

    popups = Popups()
    try:
        window.on_list_button_press(window.listbox, press_event(1, 10))
        results.check("left click opens no menu", len(popups.calls), 0)

        # Right click each row using that row's own allocation, so the
        # handler has to resolve the row from the y coordinate itself.
        for row in rows:
            alloc = row.get_allocation()
            handled = window.on_list_button_press(
                window.listbox, press_event(3, alloc.y + alloc.height // 2))
            results.check("right click on a row is handled", handled, True)

        results.check("a menu was popped up for each row", len(popups.calls), 2)

        for call in popups.calls:
            results.check("popup_at_pointer got a real event, not None",
                          call["event"] is not None, True)
            results.check("menu has exactly two items", len(call["labels"]), 2)
            results.check("second item is Delete", call["labels"][1], "Delete")
            results.check("Delete is not the first item",
                          call["labels"][0] != "Delete", True)
            results.check("Restore is gone",
                          any("Restore" in i for i in call["labels"]), False)

        firsts = [call["labels"][0] for call in popups.calls]
        results.note("first items: %r" % (firsts,))
        results.check("the pinned row offers Unpin",
                      any("Unpin" in item for item in firsts), True)
        results.check("the unpinned row offers Pin",
                      any("Unpin" not in item and "Pin" in item
                          for item in firsts), True)

        before = len(popups.calls)
        window.on_list_button_press(window.listbox, press_event(3, 100000))
        results.check("right click below the last row opens no menu",
                      len(popups.calls), before)
    finally:
        popups.restore()

    window.destroy()
    results.finish()


if __name__ == "__main__":
    main()
