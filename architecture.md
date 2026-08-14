# ShadowClip Architecture

## Overview

ShadowClip is a clipboard history tool for X11 desktops. A background daemon
records clipboard changes, and a rofi-based picker lets the user search that
history and restore any entry.

This document is the source of truth for the project architecture. Where this
document and the code disagree, one of them is wrong and should be corrected
deliberately rather than left to drift.

The project consists of six files:

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
     │  (rofi + rasi)  │              │  (hotkey)   │
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

### Row index, not row text

The picker calls rofi with `-format i` and matches the returned index against
the entry count. Previews are truncated and escaped for Pango markup, so the
displayed text cannot be matched back to a file. The index is the only
reliable link between what the user picked and what is on disk.

Action rows are appended after the entries, so any index below the entry
count is an entry and anything above it is an action.

The two counts involved are not the same number. Entry indices are bounded
by the entry count, but action indices are offset by the number of rows
rendered above them, and an empty history still renders one row: the
placeholder. Any future row that is neither an entry nor an action has to be
added to that offset as well.

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

### shadowclip-picker.sh

Builds the rofi menu, handles the selection and owns every user-facing
action: restore an entry, set max entries, set expiry minutes, toggle the
secret filter, pause or resume, clear history.

Restores with `xclip -l 1` so the selection is served once and then released.
Without it some xclip builds hand ownership back when the picker exits,
leaving the clipboard empty after the first paste.

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

### shadowclip.rasi

The rofi theme. Black background, green text, alternating row shading so
entries stay distinguishable, and an inverted selected row.

### shadowclip.service

systemd user unit that starts the daemon on login and restarts it on failure.
Ordered against `graphical-session.target`, so the daemon does not start
before an X display exists for xclip to talk to.

## State

| Path | Purpose | Permissions |
|---|---|---|
| `$XDG_RUNTIME_DIR/shadowclip/` | history directory, one file per entry | `700` |
| `$XDG_RUNTIME_DIR/shadowclip/<ns-timestamp>` | one clipboard entry, plain text | `600` |
| `$XDG_RUNTIME_DIR/shadowclip/.paused` | pause flag, presence is the state | `600` |
| `~/.config/shadowclip/config` | `MAX_ENTRIES`, `EXPIRY_MINUTES`, `SECRET_FILTER` | `600` |

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
6. Rofi displays the menu and returns a row index
7. Index below the entry count restores that entry to the clipboard
8. Index above the entry count dispatches the matching action

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

### Pause is not enforced

The pause flag is an ordinary file in a user-writable directory. It is a
convenience, not a security control.

### X11 only

xclip is an X11 client. Wayland sessions require wl-clipboard and a different
selection model.

### Up to a 0.5 second capture delay

A copy made immediately before the hotkey may not appear yet. This is the
accepted cost of polling.

### Hotkey binding is Xfce only

The installer writes shortcuts through xfconf. Other desktops are detected
and the commands printed for manual binding.

## Required Files

The following files are part of the project structure and must be preserved:

```
shadowclip-daemon.sh    shadowclip-picker.sh    shadowclip-toggle.sh
shadowclip-install.sh   shadowclip.rasi         shadowclip.service
architecture.md         README.md               CHANGELOG.md
ROADMAP.md
```
