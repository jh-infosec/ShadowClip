# ShadowClip

> Clipboard History Popup for Kali and other X11 Desktops

---

## Why ShadowClip?

The X11 clipboard holds one thing at a time. Copy something else and the
previous value is gone.

ShadowClip records recent clipboard values in the background and puts them
behind a hotkey, so anything copied in the last few minutes is one keypress
and one keystroke of search away.

---

## Project Goals

ShadowClip is designed to answer two questions:

- What did I copy recently?
- How do I get it back instantly?

It is a convenience tool. Security controls arrive in v0.2.

---

## Current Features

- Numbered history, 1 is most recent, newest entry emphasised in bold
- Searchable popup on a hotkey, type to filter
- Configurable maximum entries, changed from the popup
- Clear all history on demand
- Black and green terminal theme with alternating row shading

---

## Architecture

```
        X11 Clipboard
              │
              │ poll
              ▼
           Daemon
              │
              ▼
      History Directory
              │
              ▼
           Picker
              │
              ▼
        X11 Clipboard
```

There is no daemon-to-picker communication. Both components coordinate
through the same filesystem state: the history directory and the config file.

See `architecture.md` for the full design.

---

## Security

History lives in `~/.cache/shadowclip/` as plain, unencrypted text files with
default permissions.

There is no expiry and no way to pause capturing in this version, so anything
copied stays on disk until it is pushed out by newer entries or cleared by
hand.

Clear the history after copying anything sensitive, either from the popup or
with `rm -rf ~/.cache/shadowclip/*`.

If this matters for your use, v0.2 adds owner-only permissions, automatic
expiry and a pause hotkey.

---

## Technology

- Bash
- xclip
- rofi
- systemd user services

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
cp shadowclip-daemon.sh shadowclip-picker.sh shadowclip.rasi ~/bin/
chmod +x ~/bin/shadowclip-daemon.sh ~/bin/shadowclip-picker.sh
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

Bind the picker to a hotkey, in Xfce under Settings, Keyboard, Application
Shortcuts

- Command `~/bin/shadowclip-picker.sh`
- Shortcut `Ctrl+Alt+V`

On GNOME the equivalent is Settings, Keyboard, View and Customize Shortcuts,
Custom Shortcuts.

Without systemd, add `~/bin/shadowclip-daemon.sh` to Xfce's Session and
Startup, Application Autostart.

---

## Using ShadowClip

Copy as normal, then press the hotkey:

```
➤ 1   most recent thing you copied
   2   second most recent
   3   third most recent
   ──────────────────────
   ⚙  Set max entries stored  (currently: 15)
   🗑  Clear all history
```

Type to filter, arrows and Enter to select. Selecting an entry restores it to
the clipboard, ready to paste with `Ctrl+Shift+V` in most terminals.

---

## Configuration

Settings live in `~/.config/shadowclip/config` and can be edited by hand:

```
MAX_ENTRIES=15
```

Changes take effect immediately, with no daemon restart, because config is
read at the point of use rather than cached at startup.

Paths can be overridden from the environment with `SHADOWCLIP_HISTDIR` and
`SHADOWCLIP_CONFIG_DIR`.

---

## Philosophy

ShadowClip is deliberately small. Two scripts, a theme and a unit file, each
readable in one sitting.

Polling every 0.5 seconds rather than subscribing to clipboard events is a
choice, not an oversight: a dependency-light daemon anyone can read is worth
more here than one that shaves half a second off capture latency.
