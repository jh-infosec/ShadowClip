# ShadowClip Architecture

## Overview

ShadowClip is a clipboard history tool for X11 desktops. A background daemon
records clipboard changes to disk, and a rofi-based picker lets the user
search that history and restore any entry.

This document is the source of truth for the project architecture. Where this
document and the code disagree, one of them is wrong and should be corrected
deliberately rather than left to drift.

The project consists of five files:

```
        X11 Clipboard
              │
              │ poll every 0.5s
              ▼
     ┌─────────────────┐
     │     Daemon      │──── pause flag ────┐
     └────────┬────────┘                    │
              │ write                       │
              ▼                              │
     ┌─────────────────┐                    │
     │ History Directory│◄───────────────────┤
     │  ~/.cache/       │                    │
     └────────┬────────┘                    │
              │ read                        │
              ▼                              │
     ┌─────────────────┐              ┌──────┴──────┐
     │     Picker      │              │   Toggle    │
     │   (rofi + rasi) │              │   (hotkey)  │
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

### Config is read live, never cached

Every function that needs a setting calls `read_config` at the point of use.
Nothing is read once at startup and held.

This is what lets the picker change `MAX_ENTRIES` and have the running daemon
respect the new value on its next prune, with no restart and no signal.

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

### Row index, not row text

The picker calls rofi with `-format i` and matches the returned index against
the entry count. Previews are truncated and escaped for Pango markup, so the
displayed text cannot be matched back to a file. The index is the only
reliable link between what the user picked and what is on disk.

Action rows are appended after the entries, so any index below the entry
count is an entry and anything above it is an action.

### Honest about what it is

A clipboard history tool converts an ephemeral secret into a persistent one.
The documentation states plainly what the mitigations do and do not cover.
Features are never described as protecting against something they do not.

## Components

### shadowclip-daemon.sh

Polls the X11 clipboard, writes each new value to the history directory,
prunes beyond `MAX_ENTRIES` and deletes entries older than
`EXPIRY_MINUTES`.

Sets permissions on every start rather than only on creation, so an install
from an earlier version is hardened on first run of this one.

Expiry runs every `EXPIRY_CHECK_LOOPS` iterations rather than every poll,
because running `find` twice a second is wasteful for a deadline measured in
minutes.

### shadowclip-picker.sh

Builds the rofi menu, handles the selection and owns every user-facing
action: restore an entry, set max entries, set expiry minutes, pause or
resume, clear history.

### shadowclip-toggle.sh

Pauses or resumes recording with no menu. Deliberately duplicates the
picker's pause action because the point of the feature is speed.

### shadowclip.rasi

The rofi theme. Black background, green text, alternating row shading so
entries stay distinguishable, and an inverted selected row.

### shadowclip.service

systemd user unit that starts the daemon on login and restarts it on failure.

## State

| Path | Purpose | Permissions |
|---|---|---|
| `~/.cache/shadowclip/` | history directory, one file per entry | `700` |
| `~/.cache/shadowclip/<ns-timestamp>` | one clipboard entry, plain text | `600` |
| `~/.cache/shadowclip/.paused` | pause flag, presence is the state | `600` |
| `~/.config/shadowclip/config` | `MAX_ENTRIES` and `EXPIRY_MINUTES` | `600` |

Entry filenames are nanosecond timestamps, which gives ordering for free and
guarantees no spaces or shell metacharacters in a filename.

## Capture Flow

1. Daemon wakes on its poll interval
2. If the pause flag exists, skip to step 7
3. Current clipboard value read with xclip
4. If the value is empty or unchanged, skip to step 7
5. Value written to the history directory under a nanosecond timestamp
6. History pruned to `MAX_ENTRIES`, oldest first
7. Every `EXPIRY_CHECK_LOOPS` iterations, entries older than
   `EXPIRY_MINUTES` are deleted
8. Sleep and repeat

## Recall Flow

1. Picker invoked by hotkey
2. Config read, history listed newest first
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

Entries are readable by the owning user and by root. Permissions limit who
can read them; they do not make the contents unreadable.

### Deletion is unlink, not erasure

Clear and expiry both remove directory entries. On an SSD the underlying
blocks may remain recoverable for some time. Pausing before a session
involving real secrets is the practical mitigation, not clearing afterwards.

### Config is sourced, not parsed

`read_config` uses `source`, so the config file is executed as shell. The
file is owner-only, which limits exposure to the local user, but this is a
code execution path in a security-adjacent tool.

### X11 only

xclip is an X11 client. Wayland sessions require wl-clipboard and a different
selection model.

### Up to a 0.5 second capture delay

A copy made immediately before the hotkey may not appear yet. This is the
accepted cost of polling.

### Pause is not enforced

The pause flag is an ordinary file in a user-writable directory. It is a
convenience, not a security control.

## Required Files

The following files are part of the project structure and must be preserved:

```
shadowclip-daemon.sh    shadowclip-picker.sh    shadowclip-toggle.sh
shadowclip.rasi         shadowclip.service      architecture.md
README.md               CHANGELOG.md            ROADMAP.md
```
