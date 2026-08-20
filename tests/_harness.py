"""Shared helpers for the picker tests.

The picker is a script, not an importable module -- its filename has a hyphen
and it lives beside the other scripts rather than on the path. These helpers
load it by path, against a throwaway config and history directory, so a test
run can never touch a real clipboard history.
"""
import importlib.util
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PICKER = os.path.join(HERE, os.pardir, "shadowclip-picker.py")


def load_picker():
    """Import shadowclip-picker.py against a temporary config and history.

    The environment variables are set before the module is executed because
    the module resolves both directories at import time.
    """
    tmp = tempfile.mkdtemp(prefix="shadowclip-test-")
    os.environ["SHADOWCLIP_CONFIG_DIR"] = os.path.join(tmp, "config")
    os.environ["SHADOWCLIP_HISTDIR"] = os.path.join(tmp, "hist")
    os.makedirs(os.environ["SHADOWCLIP_HISTDIR"], exist_ok=True)

    spec = importlib.util.spec_from_file_location("shadowclip_picker", PICKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_css():
    """Pull the stylesheet out of the picker source as text.

    Read from the source rather than from the loaded module so this test can
    run without a display, and so it checks the bytes that actually ship.
    """
    with open(PICKER, encoding="utf-8") as fh:
        src = fh.read()
    match = re.search(r'css = b"""(.*?)"""', src, re.S)
    if match is None:
        raise SystemExit("could not find the stylesheet in " + PICKER)
    return match.group(1)


class Results:
    """Minimal pass/fail tally, so the tests need no test framework."""

    def __init__(self, title):
        self.failures = []
        self.count = 0
        print("=== %s ===" % title)

    def check(self, name, got, want):
        self.count += 1
        ok = got == want
        if ok:
            print("  PASS  %s" % name)
        else:
            print("  FAIL  %s\n          got:  %r\n          want: %r"
                  % (name, got, want))
            self.failures.append(name)
        return ok

    def note(self, message):
        print("  ....  %s" % message)

    def finish(self):
        print()
        if self.failures:
            print("%d of %d checks FAILED:" % (len(self.failures), self.count))
            for name in self.failures:
                print("  - %s" % name)
            sys.exit(1)
        print("all %d checks passed" % self.count)
        sys.exit(0)
