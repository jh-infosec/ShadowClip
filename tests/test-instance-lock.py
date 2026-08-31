#!/usr/bin/env python3
"""Check the single-instance lock cannot signal an unrelated process.

The hotkey toggles the picker: pressing it while one is open closes that one
instead of stacking a second window. Closing it means sending SIGTERM to the
PID in the lock file.

That PID used only to be checked for existence. PIDs are reused, and a lock
file outliving a crashed picker could name a PID that now belongs to
something else entirely -- so the hotkey would terminate an unrelated program.
This was reproducible, not theoretical: a plain `sleep` was killed by it.

Two things changed. The lock is an advisory flock held on an open descriptor,
which the kernel releases when the process dies however it dies, so a crash
leaves nothing stale. And the PID is verified to be running this program,
by reading its command line, before anything is signalled.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, load_picker  # noqa: E402

picker = load_picker()
PICKER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           os.pardir, "shadowclip-picker.py")


def write_lock_file(pid):
    with open(picker.LOCK_FILE, "w") as fh:
        fh.write(str(pid))


def main():
    results = Results("instance lock")

    results.check("identity is verified before signalling",
                  hasattr(picker, "_is_our_picker"), True)
    results.check("the lock is a real advisory lock",
                  hasattr(picker, "acquire_lock"), True)

    # The regression, reproduced exactly: an unrelated process whose PID has
    # ended up in the lock file must survive a toggle.
    victim = subprocess.Popen(["sleep", "60"])
    time.sleep(0.3)
    try:
        write_lock_file(victim.pid)
        results.note("unrelated process pid: %d" % victim.pid)

        results.check("an unrelated live pid is not recognised as our picker",
                      picker._is_our_picker(victim.pid), False)
        results.check("so no running instance is reported",
                      picker.running_instance_pid(), None)

        toggled = picker.toggle_closed_existing()
        results.check("the toggle reports nothing to close", toggled, False)

        time.sleep(0.5)
        results.check("the unrelated process is still alive",
                      victim.poll() is None, True)
    finally:
        victim.kill()
        victim.wait(timeout=10)

    # A PID that does not exist at all.
    write_lock_file(999999)
    results.check("a dead pid is not our picker",
                  picker._is_our_picker(999999), False)
    results.check("a dead pid reports no instance",
                  picker.running_instance_pid(), None)

    # Garbage in the lock file must not raise.
    with open(picker.LOCK_FILE, "w") as fh:
        fh.write("not-a-pid")
    results.check("a corrupt lock file reports no instance",
                  picker.running_instance_pid(), None)

    # A real picker process IS recognised. This is the other half: the check
    # must not be so strict that the toggle stops working.
    env = dict(os.environ, DISPLAY=os.environ.get("DISPLAY", ""))
    real = subprocess.Popen([sys.executable, PICKER_PATH, "--never-runs"],
                            env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    try:
        recognised = picker._is_our_picker(real.pid)
        results.note("a real picker process pid %d recognised: %r"
                     % (real.pid, recognised))
        results.check("a genuine picker process is recognised", recognised, True)
    finally:
        real.kill()
        real.wait(timeout=10)

    # The lock itself. Held by another process, it must not be grantable.
    os.path.exists(picker.LOCK_FILE) and os.remove(picker.LOCK_FILE)
    holder_script = (
        "import fcntl, os, sys, time;"
        "fd = os.open(%r, os.O_RDWR | os.O_CREAT, 0o600);"
        "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB);"
        "os.write(fd, str(os.getpid()).encode());"
        "print('held', flush=True);"
        "time.sleep(30)" % picker.LOCK_FILE
    )
    holder = subprocess.Popen([sys.executable, "-c", holder_script],
                              stdout=subprocess.PIPE)
    try:
        holder.stdout.readline()          # wait until the lock is actually held
        results.check("a lock held by another process cannot be acquired",
                      picker.acquire_lock(), False)
    finally:
        holder.kill()
        holder.wait(timeout=10)

    # And once that process is gone the lock is free again, with no cleanup
    # step anywhere. This is what makes a crashed picker harmless.
    time.sleep(0.3)
    results.check("the lock frees itself when the holder dies",
                  picker.acquire_lock(), True)
    picker.clear_own_lock()

    results.finish()


if __name__ == "__main__":
    main()
