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
- [ ] Wayland support via wl-clipboard
- [ ] Search across full entry content rather than the preview
- [ ] Configurable preview length
- [ ] User-editable secret patterns in the config file
- [ ] Uninstall script

---

## Version 1.0

- [ ] Automated test suite for config parsing and secret matching
- [ ] Encrypted history for the persistent storage mode
- [ ] Packaged install
- [ ] Configuration documented in one place
