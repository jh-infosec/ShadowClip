# Changelog

## Version 0.2.0

Security hardening release.

### Added

- Auto-expiry of entries older than `EXPIRY_MINUTES` (default 30)
- Pause and resume capturing, from the picker or a dedicated hotkey
- `shadowclip-toggle.sh` for menu-free pause and resume
- "Set auto-expiry minutes" action in the picker
- `[PAUSED]` indicator in the picker prompt
- Entry count and limit shown on the pause row

### Changed

- History directory created with `700` permissions
- Config file and history entries created with `600` permissions
- Permissions reapplied on every start, so existing installs are hardened
- `MAX_ENTRIES` updated in place rather than rewriting the config file,
  so changing one setting no longer discards the other
- Clear history now excludes the pause flag rather than removing everything

### Notes

Pausing stops new entries being written. It does not stop expiry of entries
already saved, which continues while paused.

History remains plain, unencrypted text. Clear and expiry unlink files; they
do not erase the underlying blocks. Pausing before a session involving real
secrets is the practical mitigation.
