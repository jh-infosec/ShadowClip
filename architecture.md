# ShadowClip Architecture

## Overview

ShadowClip is a clipboard history tool for X11 desktops. A background daemon
records clipboard changes to disk, and a rofi-based picker lets the user
search that history and restore any entry.

This document is the source of truth for the project architecture. Where this
document and the code disagree, one of them is wrong and should be corrected
deliberately rather than left to drift.

The project consists of four files:

```
        X11 Clipboard
              │
              │ poll every 0.5s
              ▼
     ┌─────────────────┐
     │     Daemon      │
     └────────┬────────┘
              │ write
              ▼
     ┌──────────────────┐
     │ History Directory│
     │  ~/.cache/       │
     └────────┬─────────┘
              │ read
              ▼
     ┌─────────────────┐
     │     Picker      │
     │  (rofi + rasi)  │
     └────────┬────────┘
              │ restore
              ▼
        X11 Clipboard
```

There is no daemon-to-picker communication. Both components read and write
the same two pieces of filesystem state: the history directory and the config
file.

## Design Principles

These are the invariants the rest of the system depends on. Changing any of
them is a redesign, not a refactor.

### The filesystem is the only shared state

The daemon and the picker never talk to each other. They coordinate entirely
through files: entries in the history directory and settings in the config
file.

This is why either can be started, stopped or replaced independently, and why
a crashed daemon loses nothing.

### Config is read live, never cached

Every function that needs a setting reads the config file at the point of
use. Nothing is read once at startup and held.

This is what lets the picker change `MAX_ENTRIES` and have the running daemon
respect the new value on its next prune, with no restart and no signal.

### Polling over event subscription

xclip offers no change notification, and an event-driven watcher would mean
another dependency. A 0.5 second poll costs almost nothing and keeps the
daemon readable, at the price of up to a 0.5 second delay before a fresh copy
appears in the list.

### Row index, not row text

The picker calls rofi with `-format i` and matches the returned index against
the entry count. Previews are truncated and escaped for Pango markup, so the
displayed text cannot be matched back to a file. The index is the only
reliable link between what the user picked and what is on disk.

Action rows are appended after the entries, so any index below the entry
count is an entry and anything above it is an action.

## Components

### shadowclip-daemon.sh

Polls the X11 clipboard, writes each new value to the history directory and
prunes anything beyond `MAX_ENTRIES`.

### shadowclip-picker.sh

Builds the rofi menu, handles the selection and owns the user-facing actions:
restore an entry, set max entries, clear history.

### shadowclip.rasi

The rofi theme. Black background, green text, alternating row shading so
entries stay distinguishable, and an inverted selected row.

### shadowclip.service

systemd user unit that starts the daemon on login and restarts it on failure.

## State

| Path | Purpose |
|---|---|
| `~/.cache/shadowclip/` | history directory, one file per entry |
| `~/.cache/shadowclip/<ns-timestamp>` | one clipboard entry, plain text |
| `~/.config/shadowclip/config` | `MAX_ENTRIES` |

Entry filenames are nanosecond timestamps, which gives ordering for free and
guarantees no spaces or shell metacharacters in a filename.

## Capture Flow

1. Daemon wakes on its poll interval
2. Current clipboard value read with xclip
3. If the value is empty or unchanged, sleep and repeat
4. Value written to the history directory under a nanosecond timestamp
5. History pruned to `MAX_ENTRIES`, oldest first
6. Sleep and repeat

## Recall Flow

1. Picker invoked by hotkey
2. History listed newest first
3. Each entry truncated to `PREVIEW_CHARS` and escaped for Pango markup
4. Entry rows built, newest emphasised
5. Action rows appended and their indices recorded
6. Rofi displays the menu and returns a row index
7. Index below the entry count restores that entry to the clipboard
8. Index above the entry count dispatches the matching action

## Known Constraints

These are accepted limitations of the current design, recorded so they are
not rediscovered as bugs.

### History is stored as plain, unencrypted text

Entries are written with default permissions and are not restricted to the
owner. Anything copied stays on disk until pruned or cleared by hand.

### No expiry and no pause

History persists until `MAX_ENTRIES` pushes it out or the user clears it.
There is no way to stop capturing short of stopping the daemon. Both are
addressed in v0.2.

### Config is sourced, not parsed

The config file is executed as shell. This is a code execution path in a
security-adjacent tool.

### Setting max entries rewrites the whole config file

`change_max_entries` writes the file from scratch, so any other setting in it
is discarded. Harmless while `MAX_ENTRIES` is the only key, but it does not
survive a second setting being added.

### X11 only

xclip is an X11 client. Wayland sessions require wl-clipboard and a different
selection model.

### Up to a 0.5 second capture delay

A copy made immediately before the hotkey may not appear yet. This is the
accepted cost of polling.

## Required Files

The following files are part of the project structure and must be preserved:

```
shadowclip-daemon.sh    shadowclip-picker.sh    shadowclip.rasi
shadowclip.service      architecture.md         README.md
CHANGELOG.md            ROADMAP.md
```
