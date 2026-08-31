#!/usr/bin/env python3
"""Check ShadowClip never claims to have emptied a clipboard it did not.

Reset offers to empty the live selection, because clearing history does not:
a credential copied a moment ago is still pasteable by any application until
the selection itself is dropped. The dialog then reports what happened.

That report was not trustworthy. clipboard_text returned "" both when the
clipboard was empty and when it could not be read at all, and clear_clipboard
compared the read-back to "" -- so a machine where the read failed produced
"Clipboard emptied." with the credential untouched. The command's own exit
status was never checked either.

Of everything in this project this is the failure that matters most, because
the user acts on it: told the clipboard is clear, they stop worrying about a
secret that is still there. So the rule is now three separate conditions --
the clear ran, the read-back ran, and it came back empty -- and "could not
read" is a distinct answer from "empty".
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, load_picker  # noqa: E402


def with_display(display):
    """Run a fresh interpreter that reports what the picker decides.

    A subprocess, because DISPLAY has to be set before the module resolves
    anything and one process cannot honestly test both states.
    """
    script = (
        "import importlib.util, sys, json;"
        "spec = importlib.util.spec_from_file_location('p', %r);"
        "p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p);"
        "print(json.dumps({'text': p.clipboard_text(),"
        " 'cleared': p.clear_clipboard()}))"
        % os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       os.pardir, "shadowclip-picker.py")
    )
    env = dict(os.environ)
    if display is None:
        env.pop("DISPLAY", None)
    else:
        env["DISPLAY"] = display
    env["SHADOWCLIP_HISTDIR"] = "/tmp/shadowclip-clipboard-test/hist"
    env["SHADOWCLIP_CONFIG_DIR"] = "/tmp/shadowclip-clipboard-test/config"
    os.makedirs(env["SHADOWCLIP_HISTDIR"], exist_ok=True)
    result = subprocess.run([sys.executable, "-c", script], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=60)
    import json
    return json.loads(result.stdout.decode() or "{}")


def main():
    results = Results("clipboard safety")
    picker = load_picker()

    results.check("clipboard_text exists", callable(picker.clipboard_text), True)

    # No display: xclip is installed but cannot reach a server. This is the
    # exact shape of the false positive -- the read fails, and must not be
    # mistaken for an empty clipboard.
    broken = with_display(None)
    results.note("with no DISPLAY: %r" % (broken,))
    results.check("an unreadable clipboard reads as None, not empty string",
                  broken.get("text"), None)
    results.check("clear_clipboard does NOT claim success when unverifiable",
                  broken.get("cleared"), False)

    # A display that does not exist: same requirement, different failure.
    missing = with_display(":88")
    results.note("with DISPLAY=:88 (no server): %r" % (missing,))
    results.check("a dead display also reads as None", missing.get("text"), None)
    results.check("and still does not claim success", missing.get("cleared"), False)

    # With a real server the honest answer is available, so it must be given.
    if not shutil_which("Xvfb") or not shutil_which("xclip"):
        results.note("SKIP live check: needs Xvfb and xclip")
        results.finish()
        return

    server = subprocess.Popen(["Xvfb", ":89", "-screen", "0", "400x300x24"],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        env = dict(os.environ, DISPLAY=":89")
        proc = subprocess.Popen(["xclip", "-selection", "clipboard", "-i"],
                                stdin=subprocess.PIPE, env=env,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        proc.communicate(b"a-secret-value")
        time.sleep(0.5)

        live = with_display(":89")
        results.note("with a live clipboard holding text: %r" % (live,))
        results.check("a readable clipboard returns text, not None",
                      live.get("text") is not None, True)
        results.check("clearing a reachable clipboard succeeds",
                      live.get("cleared"), True)
    finally:
        server.terminate()
        server.wait(timeout=10)

    results.finish()


def shutil_which(name):
    import shutil
    return shutil.which(name)


if __name__ == "__main__":
    main()
