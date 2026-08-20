#!/usr/bin/env python3
"""Check clips added by hand are stored the way the daemon's are.

A manually added clip has to be indistinguishable from a captured one once
it is on disk, because everything downstream -- ordering, pruning, expiry --
reads the filename as a nanosecond timestamp and nothing carries a flag
saying where an entry came from.

Needs a display, because it builds the dialog. Run under xvfb-run if there
is not one.
"""
import os
import stat
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, load_picker  # noqa: E402

picker = load_picker()

import gi  # noqa: E402
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402


def main():
    results = Results("add clip")

    path = picker.add_entry("hello from the host")
    name = os.path.basename(path)

    results.check("the entry exists", os.path.exists(path), True)
    results.check("named as digits only, like a captured entry",
                  name.isdigit(), True)
    results.check("the name parses as a plausible nanosecond timestamp",
                  abs(int(name) / 1e9 - time.time()) < 60, True)
    results.check("matches the entry pattern the picker lists by",
                  bool(picker.ENTRY_RE.match(name)), True)

    mode = stat.S_IMODE(os.stat(path).st_mode)
    results.check("owner-only permissions", oct(mode), oct(0o600))

    results.check("content round-trips",
                  picker.read_entry(path, 4096), "hello from the host")

    results.check("it shows up in the history listing",
                  path in picker.list_history(), True)
    results.check("it is not in the pinned listing",
                  path in picker.list_pinned(), False)

    multi = "line one\nline two\n\tindented"
    multi_path = picker.add_entry(multi)
    results.check("multi-line text survives",
                  picker.read_entry(multi_path, 4096), multi)

    unicode_path = picker.add_entry("naïve — 🔐 ünïcode")
    results.check("non-ascii survives",
                  picker.read_entry(unicode_path, 4096), "naïve — 🔐 ünïcode")

    newest = picker.list_history()[0]
    results.check("the newest entry is the one just added",
                  newest, unicode_path)

    # A secret typed in deliberately must still be stored. The filter exists
    # to catch accidents, and this is not one.
    secret_path = picker.add_entry("ghp_deadbeefdeadbeefdeadbeefdeadbeef1234")
    results.check("a deliberate credential is stored, not filtered",
                  os.path.exists(secret_path), True)

    # The dialog returns None for cancel and for whitespace-only input, so
    # neither can create an empty clip.
    before = len(picker.list_history())

    class FakeDialog:
        """Stand in for Gtk.Dialog.run so the dialog can be driven headlessly."""

        def __init__(self, response):
            self.response = response
            self._original = Gtk.Dialog.run

        def __enter__(self):
            Gtk.Dialog.run = lambda dialog: self.response
            return self

        def __exit__(self, *exc):
            Gtk.Dialog.run = self._original

    with FakeDialog(Gtk.ResponseType.CANCEL):
        results.check("cancel returns nothing",
                      picker.run_add_dialog(None), None)
    with FakeDialog(Gtk.ResponseType.OK):
        # The buffer is empty, so OK on an empty box is also nothing.
        results.check("OK with an empty box returns nothing",
                      picker.run_add_dialog(None), None)

    results.check("no entries were created by cancelling",
                  len(picker.list_history()), before)

    results.finish()


if __name__ == "__main__":
    main()
