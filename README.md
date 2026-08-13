# ShadowClip

> Clipboard History That Knows When to Stop Recording

---

## Why ShadowClip?

A clipboard history tool is genuinely useful and genuinely a security
tradeoff. It turns something normally ephemeral into something that persists.

For anyone regularly copying passwords, tokens, hashes or payloads — during
HTB machines, CTFs or client work — that tradeoff is worth taking seriously
rather than ignoring.

ShadowClip keeps the convenience and adds the controls that make the tradeoff
manageable: history held in memory rather than written to disk, automatic
expiry, a filter that skips things that look like credentials, and a one-key
pause before a session full of secrets.

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
- History held in tmpfs, so nothing is written to the SSD
- Secret filter that skips likely credentials and tells you when it does
- Auto-expiry of entries older than a configurable deadline
- Pause and resume capturing, from the popup or a dedicated hotkey
- Configurable maximum entries, changed from the popup
- Owner-only permissions on the history directory and every entry
- One-command install that binds both hotkeys for you
- Black and green terminal theme with alternating row shading

---

## Architecture

```
        X11 Clipboard
              │
              │ poll
              ▼
           Daemon ──── pause flag ────┐
        secret filter                 │
              │                       │
              ▼                       │
      History Directory ◄─────────────┤
       (XDG_RUNTIME_DIR)              │
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

- History lives in `XDG_RUNTIME_DIR`, which is tmpfs, so entries are held in
  memory and never written to the SSD
- The whole history is destroyed on logout
- History directory is `700`, entries and config are `600`, owner-only
- Permissions are reapplied on every start, so upgrading hardens an existing
  install
- Values matching known credential formats are never captured at all
- Entries older than `EXPIRY_MINUTES` (default 30) are deleted automatically
- Capturing can be paused entirely
- The config file is parsed, not executed, so a tampered config cannot run
  code on your next clipboard poll

**What it does not do**

History is plain, unencrypted text while it exists. Permissions limit who can
read it; they do not make it unreadable. Root can read it, and tmpfs pages can
reach swap under memory pressure.

The secret filter is pattern matching, not classification. It catches private
keys, JWTs, cloud access keys, provider tokens and password-style assignments.
A password that looks like an ordinary word will be stored.

It deliberately does not match bare hex or base64. Hashes, payloads and
encoded blobs are working material, and silently dropping them would make the
tool useless in the situation it was built for.

The pause flag is an ordinary file in a user-writable directory. It is a
convenience, not a security control.

**The practical habit**

Pause before a session involving real secrets, rather than clearing after.
Not capturing a secret is reliable. Deleting one is not.

---

## Technology

Current stack

- Bash
- xclip
- rofi
- systemd user services
- xfconf for hotkey binding

Planned

- wl-clipboard for Wayland

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
- Secret Filter
- tmpfs Storage

### v0.4

- Wayland Support
- Entry Pinning
- User-Editable Secret Patterns

### v1.0

- Automated Tests
- Encrypted Persistent History
- Packaged Install

---

## Running ShadowClip

Install the dependencies

```bash
sudo apt update
sudo apt install xclip rofi
```

Run the installer

```bash
./shadowclip-install.sh
```

It copies the scripts and theme to `~/bin`, enables the systemd user service,
and binds `Ctrl+Alt+V` for the picker and `Ctrl+Alt+P` for pause and resume.
Existing shortcuts are never overwritten — if a combination is already taken,
the installer says so and leaves it alone.

Nothing here needs root, and it is safe to re-run.

To use different keys or a different install directory:

```bash
SHADOWCLIP_BINDIR=~/.local/bin \
SHADOWCLIP_PICKER_KEY='<Primary><Shift>v' \
./shadowclip-install.sh
```

Check the daemon is running

```bash
systemctl --user status shadowclip.service
```

On desktops other than Xfce the installer prints the two commands to bind by
hand in your keyboard settings.

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
   🛡  Secret filter: on
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
SECRET_FILTER=1
```

Set `EXPIRY_MINUTES=0` to disable expiry, `SECRET_FILTER=0` to capture
everything. Changes take effect immediately, with no daemon restart, because
config is read at the point of use rather than cached at startup.

Any value that is not a non-negative integer falls back to its default rather
than being used.

Paths can be overridden from the environment with `SHADOWCLIP_HISTDIR` and
`SHADOWCLIP_CONFIG_DIR`. Pointing `SHADOWCLIP_HISTDIR` at somewhere under
`$HOME` trades the tmpfs protection for history that survives logout.

---

## Upgrading from v0.2

The history location has moved. An existing directory at
`~/.cache/shadowclip` is no longer read — the installer reports it so you can
remove it when you are ready:

```bash
rm -rf ~/.cache/shadowclip
```

Your existing config file is kept. `SECRET_FILTER` is added the first time
you change it from the popup, and defaults to on until then.

---

## Philosophy

ShadowClip is a convenience tool that admits what it costs.

Every mitigation is described by what it actually does. tmpfs keeps entries
off the disk, expiry limits how long one lingers, the filter prevents some
from being captured at all, and pause prevents all of them. None of them make
stored history unreadable, and the documentation says so rather than implying
otherwise.

The secret filter never drops something quietly. A history that silently omits
an entry is worse than one that stores it, because you cannot tell the
difference between "not captured" and "not copied".

Polling every 0.5 seconds is a deliberate choice: a dependency-light daemon
that anyone can read in one sitting is worth more here than an event-driven
one that shaves half a second.
