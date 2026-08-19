# Changelog

## Version 0.5.4

A readable selected row, and a logo.

### Changed

- The selected row is amber now, matching the Reset button: a dark amber
  fill under bright amber text, with an amber bar down the left edge. It was
  a bright green fill under black text, which put dark text on a light row
  in a UI that is otherwise light text on dark, and read as a hole punched
  in the list rather than as a highlight.
- A selected row keeps its own text colour. Pinned rows stay red while
  selected instead of turning white, so pinned is still legible as pinned
  without having to deselect the row to check. The left bar is what marks
  the selection, which is why the text colour no longer has to.
- The row number on a selected row is a dimmed amber, holding the same
  quieter-than-the-text relationship it has when the row is unselected.

### Added

- A logo. A clipboard casting a hard-offset shadow of itself, drawn in the
  two greens already in the palette rather than a third colour. Installed
  into the user's hicolor icon theme at seven sizes plus a scalable copy, so
  the window manager, the task switcher and any dock pick it up by name.
- A separate drawing for 16px and 24px, solid shapes with the detail knocked
  out rather than outlines. An outline loses its interior below about 32px,
  where the stroke and the gap it encloses land on the same pixel and the
  icon fills into a green blob.
- A wordmark lockup for the README header.

### Fixed

- Every hover state now has a backdrop twin, closing the last of the gaps
  that produced the 0.5.3 selection bug. The stylesheet is checked against
  that rule directly: every selector that sets a colour must have a matching
  `:backdrop` rule, and the new colours clear WCAG AA against the background
  they actually sit on.

### Notes

The picker looks for its icon in the hicolor theme first and falls back to
the `icons/` directory beside the script, so a release folder run without
installing still has a logo. The fallback tries PNG before SVG: gdk-pixbuf
only reads SVG when the librsvg loader is present, which is usual but not
guaranteed, and a machine without it raises rather than degrading quietly.

Worth knowing if you are coming from 0.5.2: the grey selected row with black
text is the 0.5.2 backdrop bug, which 0.5.3 already fixed. Installing this
release fixes it whether or not you like amber.

## Version 0.5.3

Interaction fixes in the picker. Nothing else changed.

### Fixed

- The selected row was unreadable while the window was unfocused. GTK applies
  a `:backdrop` state when a window loses focus, and the stylesheet had no
  rules for it, so the desktop theme supplied the selection colour: grey,
  under black text meant for bright green. Pinned rows escaped it only
  because their red label colour happens to survive on grey, which is why
  pinning appeared to fix it. Every visible state now has a backdrop twin,
  including the toolbar buttons.

### Changed

- Single click selects a row, double click restores it and closes. GTK's
  default activates on a single click, so a stray click restored an entry and
  closed the window before the row had been read. Enter still activates the
  selected row, so the keyboard path is unchanged and remains the fastest.
- Clicking away from the picker closes it, the same as Escape.

### Notes

Clicking away closes rather than minimises. The picker is single-instance
through a PID lock held by the process, so a hidden window would still hold
the lock and the next hotkey press would take the toggle path and kill it
instead of showing it: press the key, get nothing. The window opens
instantly, so there is nothing to gain by keeping it around.

Dialogs and the right-click menu take focus from the main window, which would
otherwise close the picker out from underneath them. A counted guard
suppresses close-on-focus-out while any child window is up, counted rather
than a flag because reset opens a confirmation and then a summary, and the
inner one closing must not re-arm the outer.

The close check is deferred by one main-loop pass, because a click that moves
focus to our own menu can arrive before that menu registers as focused.

## Version 0.5.2

A reset button, and the three bulk actions the 0.5.0 rewrite dropped.

### Added

- **Reset** in the toolbar, between Pin selected and Settings. Deletes every
  clip and starts fresh. It confirms first, states the counts, and puts each
  destructive part behind its own checkbox: delete pinned clips as well, empty
  the clipboard itself, and remove any on-disk history found outside tmpfs.
- Emptying the live X11 clipboard as part of a reset. Clearing history never
  touched the selection itself, so a credential copied a moment earlier stayed
  pasteable by any application. The result is read back and reported honestly,
  including when it fails.
- Sweeping a legacy on-disk history directory at `~/.cache/shadowclip`, left
  by a pre-0.3 install or a session with no `XDG_RUNTIME_DIR`. It is only
  offered when it exists and is not the directory currently in use.

### Fixed

- **Clear all history** was lost in the 0.5.0 move from rofi to GTK and is
  back, in the settings dialog. It spares pinned clips, as it always did.
- **Unpin all** was lost in the same rewrite and is back.
- **Pause and resume from the picker** was lost in the same rewrite and is
  back as a switch in the settings dialog. The dedicated hotkey never stopped
  working, but the README claimed the popup could do it too.
- The `SettingsDialog` comment claimed pause and clear lived there. They did
  not. Now they do.

### Notes

Reset and Clear are deliberately separate. Clearing is the routine action and
spares pinned clips, following the same rule as pruning and expiry. Reset is
the one action that destroys entries you deliberately marked as worth keeping,
which is why it confirms and why deleting pins is a checkbox rather than an
assumption.

Every bulk delete removes only entry files, which are named as a pure
timestamp. `.paused` and `.picker.pid` cannot match that pattern, so they
survive by construction rather than by a filter that could be forgotten.
Removing the PID lock underneath a running picker would break single-instance
and let the hotkey stack a second window.

Emptying the clipboard means there is nothing left to paste. That is the
point when the reason for resetting is a copied secret, and it is worth
knowing before ticking the box.

## Version 0.5.1

### Added

- The picker is single-instance. Pressing the hotkey while it is open closes
  it instead of stacking another window. Implemented with a PID lock file in
  the history directory; a stale lock from a crashed instance is ignored, so
  a crash never wedges the picker shut.

### Changed

- `umask 077` in the daemon, so history files are owner-only from creation,
  ahead of the explicit chmod that already set the same bits.

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
