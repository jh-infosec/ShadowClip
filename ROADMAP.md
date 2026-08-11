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

- [ ] Bind toggle script to a hotkey during install
- [ ] Parse the config file instead of sourcing it
- [ ] Install script to replace the manual copy steps
- [ ] Secret detection to skip capturing likely credentials
- [ ] Optional tmpfs-backed history directory
- [ ] Shellcheck clean across all scripts

---

## Version 0.4

- [ ] Wayland support via wl-clipboard
- [ ] Per-entry pinning so a chosen entry survives pruning and expiry
- [ ] Entry search across full content rather than the preview
- [ ] Configurable preview length

---

## Version 1.0

- [ ] Encrypted history at rest
- [ ] Automated test suite
- [ ] Packaged install
- [ ] Configuration documented in one place
