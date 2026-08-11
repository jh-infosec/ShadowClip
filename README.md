# ShadowClip

> Clipboard History with a Pause Button, for Kali and other X11 Desktops

---

## Why ShadowClip?

A clipboard history tool is genuinely useful and genuinely a security
tradeoff. It turns something normally ephemeral into something that persists
on disk.

For anyone regularly copying passwords, tokens, hashes or payloads — during
HTB machines, CTFs or client work — that tradeoff is worth taking seriously
rather than ignoring.

ShadowClip keeps the convenience and adds the controls that make the tradeoff
manageable: restrictive permissions, automatic expiry, and a one-key pause
before a session full of secrets.

---

## Project Goals

ShadowClip is designed to answer three questions:

- What did I copy recently?
- How do I get it back instantly?
- How do I stop recording when I shouldn't be?

It is a convenience tool with security controls, not a secrets manager.

---

## Current Features

- Numbered history, 1 is most recent, newest entry emphasised in bold
- Searchable popup on a hotkey, type to filter
- Configurable maximum entries, changed from the popup
- Auto-expiry of entries older than a configurable deadline
- Pause and resume capturing, from the popup or a dedicated hotkey
- Owner-only permissions on the history directory and every entry
- Clear all history on demand
- Black and green terminal theme with alternating row shading

---

## Architecture

```
        X11 Clipboard
              │
              │ poll
              ▼
           Daemon ──── pause flag ────┐
              │                       │
              ▼                       │
      History Directory ◄─────────────┤
              │                       │
              ▼                       │
           Picker                  Toggle
              │
              ▼
        X11 Clipboard
```

There is no daemon-to-picker communication. Every component coordinates
through the same filesystem state: the history directory, the config file and
the pause flag.

See `architecture.md` for the full design.

---

## Security

Read this section if you use ShadowClip for pentest or CTF work.

**What it does**

- History directory is `700`, entries and config are `600`, owner-only
- Permissions are reapplied on every start, so upgrading hardens an existing
  install
- Entries older than `EXPIRY_MINUTES` (default 30) are deleted automatically
- Capturing can be paused entirely, so nothing new is written
- History can be wiped on demand

**What it does not do**

History is stored as plain, unencrypted text while it exists. Permissions
limit who can read it; they do not make it unreadable. Root can read it.

Clear and expiry both unlink files. They do not erase the underlying blocks,
and on an SSD deleted data can remain forensically recoverable for some time.

The pause flag is an ordinary file in a user-writable directory. It is a
convenience, not a security control.

**The practical habit**

Pause before a session involving real secrets, rather than clearing after.
Not writing a secret to disk is reliable. Deleting one is not.

---

## Technology

Current stack

- Bash
- xclip
- rofi
- systemd user services

Planned

- wl-clipboard for Wayland
- tmpfs-backed history

---

## Roadmap

### v0.1

- Daemon
- Picker
- Configurable History Size

### v0.2

- Permissions Hardening
- Auto-Expiry
- Pause and Resume

### v0.3

- Install Script
- Config Parsing
- Secret Detection

### v0.4

- Wayland Support
- Entry Pinning

### v1.0

- Encrypted History
- Automated Tests
- Packaged Install

---

## Running ShadowClip

Install the dependencies

```bash
sudo apt update
sudo apt install xclip rofi
```

Install the scripts

```bash
mkdir -p ~/bin
cp shadowclip-daemon.sh shadowclip-picker.sh shadowclip-toggle.sh shadowclip.rasi ~/bin/
chmod +x ~/bin/shadowclip-*.sh
```

`shadowclip-picker.sh` resolves `shadowclip.rasi` relative to its own
location, so keep both in the same directory.

Start the daemon on login

```bash
mkdir -p ~/.config/systemd/user
cp shadowclip.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now shadowclip.service
```

Check it is running

```bash
systemctl --user status shadowclip.service
```

Bind the hotkeys, in Xfce under Settings, Keyboard, Application Shortcuts

- `~/bin/shadowclip-picker.sh` on `Ctrl+Alt+V` for the popup
- `~/bin/shadowclip-toggle.sh` on `Ctrl+Alt+P` for instant pause and resume

On GNOME the equivalent is Settings, Keyboard, View and Customize Shortcuts,
Custom Shortcuts.

Without systemd, add `~/bin/shadowclip-daemon.sh` to Xfce's Session and
Startup, Application Autostart.

---

## Using ShadowClip

Copy as normal, then press the picker hotkey:

```
➤ 1   most recent thing you copied
   2   second most recent
   3   third most recent
   ──────────────────────
   ⚙  Set max entries stored  (currently: 15)
   ⏱  Set auto-expiry minutes  (currently: 30)
   ⏸  Pause capturing  (expires in 30m, currently 3/15 stored)
   🗑  Clear all history
```

Type to filter, arrows and Enter to select. Selecting an entry restores it to
the clipboard, ready to paste with `Ctrl+Shift+V` in most terminals.

While paused the prompt reads `ShadowClip [PAUSED]` and the pause row becomes
"Resume capturing".

---

## Configuration

Settings live in `~/.config/shadowclip/config` and can be edited by hand:

```
MAX_ENTRIES=15
EXPIRY_MINUTES=30
```

Set `EXPIRY_MINUTES=0` to disable expiry entirely. Changes take effect
immediately, with no daemon restart, because config is read at the point of
use rather than cached at startup.

Paths can be overridden from the environment with `SHADOWCLIP_HISTDIR` and
`SHADOWCLIP_CONFIG_DIR`.

---

## Philosophy

ShadowClip is a convenience tool that admits what it costs.

Every mitigation is described by what it actually does. Permissions restrict
access, expiry limits how long a secret lingers, and pause prevents a secret
being written at all. None of them make stored history unreadable, and the
documentation says so rather than implying otherwise.

Polling every 0.5 seconds is a deliberate choice: a dependency-light daemon
that anyone can read in one sitting is worth more here than an event-driven
one that shaves half a second.
