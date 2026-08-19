# ShadowClip Roadmap

## Version 0.1

- [x] Clipboard daemon
- [x] Rofi picker
- [x] Numbered history with emphasised newest entry
- [x] Configurable max entries
- [x] Clear all history
- [x] Terminal theme
- [x] systemd user service

---

## Version 0.2

- [x] Restrictive permissions on history and config
- [x] Auto-expiry of stale entries
- [x] Pause and resume capturing
- [x] Dedicated pause hotkey script
- [x] Configurable expiry from the picker

---

## Version 0.3

- [x] Bind both hotkeys during install
- [x] Parse the config file instead of sourcing it
- [x] Atomic config writes that upsert
- [x] Install script to replace the manual copy steps
- [x] Secret detection to skip capturing likely credentials
- [x] tmpfs-backed history directory
- [x] Shellcheck clean across all scripts

---

## Version 0.4

- [x] Per-entry pinning so a chosen entry survives pruning and expiry
- [x] Settings moved behind their own menu
- [x] Configurable window width and row count
- [x] GTK front end with fixed toolbar, row pin icons and right-click
- [ ] Wayland support via wl-clipboard
- [x] Search across full entry content rather than the preview
- [x] Configurable preview length
- [ ] User-editable secret patterns in the config file
- [ ] Uninstall script

---

## Version 0.5

- [x] GTK3 picker replacing rofi
- [x] Single-instance picker, hotkey toggles it closed
- [x] Reset button, with pinned clips and the live clipboard as options
- [x] Clear history, unpin all and pause restored after the GTK rewrite
- [x] Readable rows while the window is unfocused
- [x] Click away to close
- [x] Single click selects, double click restores
- [ ] Automated test for the bulk actions in the picker

---

## Version 1.0

- [ ] Automated test suite for config parsing and secret matching
- [ ] Encrypted history for the persistent storage mode
- [ ] Packaged install
- [ ] Configuration documented in one place
