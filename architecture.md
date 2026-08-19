# ShadowClip Architecture

## Overview

ShadowClip is a clipboard history tool for X11 desktops. A background daemon
records clipboard changes, and a GTK picker lets the user search that
history and restore any entry.

This document is the source of truth for the project architecture. Where this
document and the code disagree, one of them is wrong and should be corrected
deliberately rather than left to drift.

The picker is a GTK3 program; the daemon and the rest are shell. The
project consists of these components:

```
        X11 Clipboard
              │
              │ poll every 0.5s
              ▼
     ┌─────────────────┐
     │     Daemon      │──── pause flag ────┐
     │  secret filter  │                    │
     └────────┬────────┘                    │
              │ write                       │
              ▼                              │
     ┌──────────────────┐                   │
     │ History Directory│◄──────────────────┤
     │  XDG_RUNTIME_DIR │                   │
     └────────┬─────────┘                   │
              │ read                        │
              ▼                              │
     ┌─────────────────┐              ┌──────┴──────┐
     │     Picker      │              │   Toggle    │
     │    (GTK3)       │              │  (hotkey)   │
     └────────┬────────┘              └─────────────┘
              │ restore
              ▼
        X11 Clipboard
```

There is no daemon-to-picker communication. Every component reads and writes
the same three pieces of filesystem state: the history directory, the config
file and the pause flag.

## Design Principles

These are the invariants the rest of the system depends on. Changing any of
them is a redesign, not a refactor.

### The filesystem is the only shared state

The daemon, the picker and the toggle script never talk to each other. They
coordinate entirely through files: entries in the history directory, settings
in the config file, and the presence or absence of the pause flag.

This is why any component can be started, stopped or replaced independently,
and why a crashed daemon loses nothing.

### Every script is self-contained

The config helpers, entry listing and pause check are duplicated across the
three scripts rather than shared through a sourced library.

This is deliberate. A shared library would add a second co-location
requirement alongside the theme file, and would mean any script copied
somewhere on its own silently breaks. The duplicated block is short and
changes rarely. If it grows, that is the signal to revisit this decision.

### Config is parsed, never sourced

`config_get_int` reads a single key with `grep` and validates it as an
integer. The config file is never executed as shell.

Sourcing it, as versions 0.1 and 0.2 did, made every clipboard poll a code
execution path in a tool that exists to handle secrets. Any value that fails
validation falls back to the built-in default rather than propagating
garbage into arithmetic.

### Config writes are atomic upserts

`config_set` writes to a temporary file in the same directory and renames it
over the original. A key that is absent is appended; a key that is present is
replaced; every other key survives untouched.

In-place `sed` silently did nothing when a key was missing, which presents as
a setting that saves and never takes effect.

### Config is read live, never cached

Every function that needs a setting calls `config_get_int` at the point of
use. Nothing is read once at startup and held.

This is what lets the picker change `MAX_ENTRIES` and have the running daemon
respect the new value on its next prune, with no restart and no signal.

### History lives in memory by default

The history directory defaults to `XDG_RUNTIME_DIR`, which is tmpfs on
systemd systems and already owner-only. Entries are never written to the SSD
and the whole directory is destroyed on logout.

This replaces the v0.2 problem that clearing history unlinked files without
erasing the underlying blocks. It falls back to `~/.cache` when
`XDG_RUNTIME_DIR` is unset.

### Polling over event subscription

xclip offers no change notification, and an event-driven watcher would mean
another dependency. A 0.5 second poll costs almost nothing and keeps the
daemon readable, at the price of up to a 0.5 second delay before a fresh copy
appears in the list.

### Pause is a flag file, not a process state

Pausing creates a file. It survives a daemon restart, can be set by hand, and
requires no IPC.

While paused the daemon keeps running so that expiry of already-saved entries
continues. Pausing stops new secrets being written; it does not stop old ones
being cleaned up.

### The secret filter is narrow and never silent

`looks_like_secret` matches unambiguous credential formats only: private key
headers, JWTs, cloud access keys, provider tokens, and assignments to keys
named like passwords or API keys.

Bare hex and base64 are deliberately excluded. Hashes, payloads and encoded
blobs are working material for pentest and CTF use, and dropping them would
make the tool untrustworthy in exactly the situation it was built for.

When a value is skipped the user is notified. A history that silently omits
something is worse than one that stores it, because the user cannot tell the
difference between "not captured" and "not copied".

### The picker is a separate front end

The picker is the only component a person interacts with, and the only one
that is not shell. It reads the same history directory, pinned subdirectory
and config file the daemon uses, by the same rules, and never talks to the
daemon directly.

Because the contract is entirely on the filesystem, the front end was swapped
from rofi to GTK in 0.5.0 without the daemon changing at all. Anything that
reads those files the same way could replace it again.

### Pinning is a subdirectory, not a flag

A pinned entry is moved into `pinned/` beneath the history directory.

The daemon's prune and expiry both select with `-maxdepth 1 -type f`, so a
pinned entry is invisible to them without the daemon containing a single
line about pinning. Clearing history uses the same constraint and therefore
leaves pins alone, which is the point: clearing is the routine action and
pinned entries are the ones marked as worth surviving it.

Moving rather than copying means an entry appears in exactly one section,
so there is no question of which copy is current.

### Clearing spares pins, resetting does not

Two destructive actions, deliberately distinct.

Clearing is routine. It deletes unpinned entries and follows the same rule as
prune and expiry, so a pinned entry survives it. That is the whole point of
pinning.

Reset is the escape hatch. It is the only action that destroys entries the
user deliberately marked as worth keeping, so it confirms, states the counts,
and makes deleting pins a checkbox rather than an assumption.

Every bulk delete selects only entry files, which are named as a pure
timestamp. `.paused` and `.picker.pid` cannot match that pattern, so control
files survive by construction rather than by a filter that could be
forgotten. Removing the PID lock underneath a running picker would break
single-instance.

### Clearing history does not clear the clipboard

The history directory and the X11 selection are different things. Deleting
every entry leaves whatever was copied last still sitting in the selection,
where any application can still ask for it.

Reset therefore offers to empty the selection too, and reads it back to
confirm rather than assuming. There is no single portable way to disown an X
selection, and reporting success while a secret is still pasteable would be
the worst failure this tool could have.

### The stylesheet covers focused and unfocused alike

GTK applies a `:backdrop` state to every widget in a window that does not have
focus. A rule written without a backdrop twin is silently replaced by the
desktop theme's own colour in that state.

That is not cosmetic here. Until 0.5.3 the selected row kept its black text,
meant to sit on bright green, while the theme supplied a grey background:
unreadable, and only in the moment the user had clicked elsewhere. Pinned rows
escaped it by accident, because red survives on grey.

Every visible state therefore has a backdrop counterpart. Adding a rule means
adding two.

### Clicking away closes the picker

Losing focus closes the window, the same as Escape.

Closing rather than hiding follows from single-instance. The PID lock is held
by the process, so a hidden window still holds it and the next hotkey press
would take the toggle path and kill the hidden window instead of showing it.
Hiding would mean reworking the SIGTERM handler to show-if-hidden, for a
window that opens instantly.

Child windows are the complication. Dialogs and the right-click menu take
focus from the main window, so a counted guard suppresses the close while any
of them is up. Counted, not a flag: reset opens a confirmation and then a
summary, and the inner one closing must not re-arm the outer.

### Selecting and restoring are different clicks

Single click selects, double click restores and closes. Enter activates the
selected row.

GTK's default is activate-on-single-click, which made one stray click restore
an entry and close the window before the row had been read. Restoring is the
destructive-feeling action here, in that it replaces the clipboard, so it gets
the deliberate gesture.

### Settings live behind one row

The main list shows clips. Everything else is one "Settings and actions" row
that opens a second menu.

Entries are what the picker is for, and a hotkey pressed mid-task should
land on them, not on six configuration rows. The submenu is built by the
same `add_row` mechanism, so it inherits the same dispatch guarantees.

### Window size is a saved setting

`WINDOW_WIDTH` and `WINDOW_HEIGHT` are written when the user drags the window
and read back when it next opens, so the window remembers its size. GTK
handles the resize itself; the config only persists it.

### Honest about what it is

A clipboard history tool converts an ephemeral secret into a persistent one.
The documentation states plainly what the mitigations do and do not cover.
Features are never described as protecting against something they do not.

## Components

### shadowclip-daemon.sh

Polls the X11 clipboard, applies the secret filter, writes each accepted
value to the history directory, prunes beyond `MAX_ENTRIES` and deletes
entries older than `EXPIRY_MINUTES`.

Sets permissions on every start rather than only on creation, so an install
from an earlier version is hardened on first run of this one.

Expiry runs every `EXPIRY_CHECK_LOOPS` iterations rather than every poll,
because running `find` twice a second is wasteful for a deadline measured in
minutes.

A skipped secret is recorded in `last_value` anyway, so it is tested once
rather than on every poll until the clipboard changes.

### shadowclip-picker.py

The GTK3 picker. Lists pinned entries then history, each row carrying its
file path. Left-click or Enter restores an entry and closes. A per-row pin
icon, a "Pin selected" toolbar button, a right-click menu and Ctrl+P all
toggle pinning.

The toolbar carries Pin selected, Reset and Settings. Reset is amber rather
than the red used for pins, so a destructive control does not read as a
pinning one. The settings dialog holds the integer settings plus the bulk
actions: clear history, unpin all, and a capturing switch writing the same
pause flag the toggle hotkey uses. Settings apply on Save; the actions fire
immediately and confirm for themselves, because Cancel should never be the
thing standing between the user and a deletion that already looked like it
happened. The toolbar and search box are siblings of the scrolling
list, not inside it, so they stay put while it scrolls -- the specific thing
rofi could not do.

Config is read and written by the same parse-never-source rule as the shell:
`config_get_int` validates each value and falls back to the default,
`config_set_int` upserts atomically through a temp file and rename.

Restores with a detached `setsid xclip -i` and no read limit. A limit would
be consumed by the daemon's own poll before the user could paste, which was
the 0.4.x paste bug.

### shadowclip-picker.sh

A thin launcher that execs `shadowclip-picker.py` from the same directory, so
the hotkey binding and installer did not change when the front end did.

### shadowclip-toggle.sh

Pauses or resumes recording with no menu. Deliberately duplicates the
picker's pause action because the point of the feature is speed.

### shadowclip-install.sh

Copies the scripts and theme into the install directory, enables the systemd
user service, and binds both hotkeys through xfconf on Xfce.

Never overwrites an existing shortcut. A key combination already bound to
something else is reported and left alone.

Also the update path. It stops the daemon before replacing the scripts and
restarts it afterwards, so re-running it is how a new version is deployed.
Nothing has to be uninstalled first.

### shadowclip.service

systemd user unit that starts the daemon on login and restarts it on failure.
Ordered against `graphical-session.target`, so the daemon does not start
before an X display exists for xclip to talk to.

## State

| Path | Purpose | Permissions |
|---|---|---|
| `$XDG_RUNTIME_DIR/shadowclip/` | history directory, one file per entry | `700` |
| `$XDG_RUNTIME_DIR/shadowclip/pinned/` | pinned entries, exempt from prune, expiry and clear | `700` |
| `$XDG_RUNTIME_DIR/shadowclip/<ns-timestamp>` | one clipboard entry, plain text | `600` |
| `$XDG_RUNTIME_DIR/shadowclip/.paused` | pause flag, presence is the state | `600` |
| `~/.config/shadowclip/config` | `MAX_ENTRIES`, `EXPIRY_MINUTES`, `SECRET_FILTER`, `WINDOW_WIDTH`, `WINDOW_HEIGHT`, `PREVIEW_CHARS` | `600` |

Entry filenames are nanosecond timestamps. This gives ordering for free,
guarantees no spaces or shell metacharacters in a filename, and lets
`list_entries` select entries with a `[0-9]*` glob that excludes the pause
flag without a separate filter.

## Capture Flow

1. Daemon wakes on its poll interval
2. If the pause flag exists, skip to step 8
3. Current clipboard value read with xclip
4. If the value is empty or unchanged, skip to step 8
5. Value recorded as seen, so it is evaluated only once
6. If the secret filter is on and the value matches a credential pattern, the
   user is notified and nothing is written
7. Otherwise the value is written under a nanosecond timestamp and history is
   pruned to `MAX_ENTRIES`
8. Every `EXPIRY_CHECK_LOOPS` iterations, entries older than
   `EXPIRY_MINUTES` are deleted
9. Sleep and repeat

## Recall Flow

1. Picker invoked by hotkey
2. Settings read, history listed newest first
3. Each entry truncated to `PREVIEW_CHARS` and escaped for Pango markup
4. Entry rows built, newest emphasised
5. Action rows appended and their indices recorded
6. The window shows the rows and the user activates one
7. Activating a row restores that entry to the clipboard and closes
8. The toolbar, row icons and right-click menu drive pin, settings and delete

## Known Constraints

These are accepted limitations of the current design, recorded so they are
not rediscovered as bugs.

### History does not survive logout

Storing in `XDG_RUNTIME_DIR` is what keeps entries off the SSD. The cost is
that history is gone after logout or reboot. Set `SHADOWCLIP_HISTDIR` to a
path under `$HOME` to trade that back.

### History is still plain text while it exists

Entries are readable by the owning user and by root. Permissions limit who
can read them; they do not make the contents unreadable. Anything in tmpfs
can also reach swap if the system is under memory pressure.

### The secret filter is pattern matching, not classification

It catches known credential formats. A password that looks like an ordinary
word will be stored, and an unrecognised token format will be stored. It
reduces accidental capture; it does not prevent it.

### Reset cannot recover what it deletes

There is no undo and no recycle bin. History is in tmpfs, so a deleted entry
is gone from memory with nothing on disk to recover.

### Emptying the clipboard leaves nothing to paste

That is the intent when the reason for resetting is a copied secret, but it
also means an in-progress paste is lost. It is a checkbox for that reason.

### Pause is not enforced

The pause flag is an ordinary file in a user-writable directory. It is a
convenience, not a security control.

### X11 only

xclip is an X11 client. Wayland sessions require wl-clipboard and a different
selection model.

### Pinned entries do not survive logout either

Pinning exempts an entry from pruning, expiry and clearing. It does not move
it out of tmpfs, so a pin is lost at logout like everything else. Persistent
pins would mean writing chosen clipboard values to the SSD, which is the
tradeoff the storage design exists to avoid.

### Up to a 0.5 second capture delay

A copy made immediately before the hotkey may not appear yet. This is the
accepted cost of polling.

### Hotkey binding is Xfce only

The installer writes shortcuts through xfconf. Other desktops are detected
and the commands printed for manual binding.

## Required Files

The following files are part of the project structure and must be preserved:

```
shadowclip-daemon.sh    shadowclip-picker.sh    shadowclip-picker.py
shadowclip-toggle.sh    shadowclip-install.sh   shadowclip.service
architecture.md         README.md               CHANGELOG.md
ROADMAP.md
```
