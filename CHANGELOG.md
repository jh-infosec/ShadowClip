# Changelog

## Version 0.5.0

The picker is now a GTK3 window instead of a rofi menu. Everything behind it
is unchanged: same daemon, same tmpfs history, same pinned subdirectory, same
config file and secret filter. Only the front end changed.

### Why

Rofi is one scrolling list. It cannot keep a toolbar visible while the list
scrolls, has no per-row right-click, and no per-row clickable icon. Pinning
had become a button-then-list workaround for all three. Those interactions are
what a real window gives for free, so the front end moved to GTK.

### Added

- `shadowclip-picker.py`, a GTK3 picker. `shadowclip-picker.sh` is now a thin
  launcher that execs it, so the hotkey and installer did not change.
- Toolbar with "Pin selected" and "Settings", fixed above the list and always
  visible while scrolling.
- A pin icon on every row that toggles pin state in place on click. Pinned
  rows show it lit in red, unpinned rows dimmed.
- Right-click menu on each row: pin or unpin, restore, delete.
- Drag to resize. The window remembers its size in `WINDOW_HEIGHT` and
  `WINDOW_WIDTH`.
- Live search box that filters the full entry text, not just the preview.
- Settings dialog for max entries, expiry, preview length and the secret
  filter switch.
- `PREVIEW_CHARS` and `WINDOW_HEIGHT` config keys.

### Changed

- Left-click or Enter on a row restores it and closes, the same fast path as
  before.
- Dependency is now GTK3 for Python (`python3-gi`, `gir1.2-gtk-3.0`) instead
  of rofi. The installer checks for it.

### Removed

- `shadowclip.rasi`. Styling is now CSS inside the picker.
- The rofi dependency.

### Notes

Still X11 via xclip, still tmpfs history, still lost at logout. The move to
GTK does not change any of that. Ctrl+P pins the selected row and Escape
closes, so the common actions remain reachable from the keyboard.

## Version 0.4.1

Fixes a regression that made pasting impossible, and reworks how rows are
coloured.

### Fixed

- Restoring an entry left nothing to paste. Versions 0.3.0 to 0.4.0 restored
  with `xclip -l 1`, which serves the selection exactly once and then exits.
  The daemon reads the clipboard every 0.5 seconds, so the daemon's own next
  poll consumed that single serving and xclip was gone before the user could
  paste. Restoring is now unlimited, with `setsid` doing what `-l 1` was
  actually reaching for: keeping xclip alive after the picker exits.
- A highlighted pinned row was unreadable. Row colour came from a Pango span,
  which applies while the row is selected too, so cyan text sat on the bright
  green selection bar.

### Added

- "PIN or unpin a clip" row in the main menu, opening a list of clips to pin
  or unpin. Pinning no longer requires the keyboard.
- `PIN_KEY` config key, so the shortcut can be changed without editing the
  script.

### Changed

- Rows are marked with rofi's own `urgent` and `active` classes instead of
  Pango colour spans, so the theme defines each state including selected.
  Pinned rows and the PIN button are red, inverting to white on red when
  highlighted. Separators and menu rows are dimmed.
- Theme gains `urgent` and `active` rules with their selected variants.

### Notes

Rofi has no right-click context menu, so pinning by mouse is a button and
then a list rather than a context menu on the row itself.

## Version 0.4.0

Pinning, a settings menu, and a resizable popup.

### Added

- Pin an entry with `Alt+p` from the picker. Pinned entries are listed first
  in cyan, and are exempt from pruning, auto-expiry and "clear all history"
- `Alt+p` on an already-pinned entry unpins it, returning it to normal
  history
- "Unpin all" action in the settings menu
- Settings menu. The main list now shows clips and one row into a second
  menu holding every setting and action
- `WINDOW_WIDTH` and `LIST_LINES` config keys, both settable from the
  settings menu, so the popup can be resized without editing the theme
- Prompt now reads `ShadowClip:` with a separator before the search text

### Changed

- Picker rows and their actions are built together in `add_row` and
  dispatched by lookup, replacing the index arithmetic that caused the
  v0.3.0 empty-history bug. A row and its action can no longer drift apart
- `run_rofi` returns its result in globals. Returning it on stdout would put
  the call in a subshell, where the exit status carrying the pin key is
  discarded
- Settings prompts and both menus honour the configured window size

### Notes

Pinning exempts an entry from every automatic deletion, but it does not move
it out of tmpfs, so pins are still lost at logout. Persistent pins would mean
writing chosen clipboard values to the SSD, which is exactly the tradeoff the
storage design avoids.

Rofi has no draggable window. `WINDOW_WIDTH` and `LIST_LINES` are as close to
resizing as the toolkit allows, and take effect the next time the popup opens.

If rofi reports a keybinding conflict on startup, change `PIN_KEY` near the
top of the picker to something free, or to rofi's own default of `Alt+1`.

## Version 0.3.1

Fix release. No new features.

### Fixed

- Picker action rows were indexed from the entry count rather than the number
  of rows rendered. An empty history still draws a placeholder row, so every
  action was shifted down by one: "Set max entries" opened the expiry prompt,
  "Secret filter" toggled pause, and "Clear all history" matched nothing and
  did nothing. Only affected an empty history, which is the first screen a
  new install shows.
- Cancelling a number prompt, or answering it with something non-numeric,
  ended the picker. `prompt_number` returned non-zero and the caller's
  command substitution failed under `set -e`, so the "Unchanged" notification
  it was meant to trigger could never appear.
- Cancelling the main picker ended the script at the rofi assignment for the
  same reason, leaving the empty-selection check unreachable.
- Re-running the installer did not update a running daemon. `enable --now`
  starts a stopped service but leaves a running one alone, so the old script
  stayed in memory.
- The installer replaced `shadowclip-daemon.sh` while the daemon was running.
  `install` rewrites the destination in place and bash reads a script as it
  executes, so a live daemon could read across both versions.

### Changed

- Re-running `shadowclip-install.sh` is now the supported way to update.
  It stops the daemon, replaces the files and restarts.

## Version 0.3.0

Hardening and installation release.

### Added

- `shadowclip-install.sh`, which copies the scripts, enables the service and
  binds both hotkeys through xfconf on Xfce
- Secret filter that skips capturing values matching known credential
  formats, with a notification when something is skipped
- "Secret filter: on / off" action in the picker
- `SECRET_FILTER` config key, default `1`
- `SHADOWCLIP_BINDIR`, `SHADOWCLIP_PICKER_KEY` and `SHADOWCLIP_TOGGLE_KEY`
  environment overrides for the installer

### Changed

- History now defaults to `XDG_RUNTIME_DIR`, which is tmpfs, so entries are
  held in memory and never written to the SSD
- Config file is parsed with `grep` instead of being sourced, removing a
  shell execution path that ran on every clipboard poll
- Config writes are atomic upserts, so setting one key no longer discards
  another and no longer silently fails when the key is absent
- Entry listing uses `find` with a `[0-9]*` name match instead of
  `ls | grep`, which never actually excluded the pause flag because `ls`
  does not list dotfiles
- Picker now sets `600` on the config file, which only the daemon did before
- Restore uses `xclip -l 1`, so the clipboard is no longer emptied after the
  first paste on some xclip builds
- Invalid config values fall back to defaults instead of propagating into
  arithmetic
- Service unit ordered against `graphical-session.target`, so the daemon no
  longer starts before an X display exists
- All scripts are shellcheck clean

### Fixed

- Setting max entries in v0.2 could silently do nothing if the key was
  missing from a hand-edited config
- Clearing history removed the pause flag in v0.1

### Notes

History no longer survives logout. That is the point of moving it to tmpfs.
Set `SHADOWCLIP_HISTDIR` to a path under `$HOME` if you want persistence back.

An existing on-disk history at `~/.cache/shadowclip` is no longer read. The
installer reports it so you can remove it.

The secret filter is pattern matching, not classification. It deliberately
does not match bare hex or base64, because hashes and payloads are working
material. It reduces accidental capture; it does not prevent it.
