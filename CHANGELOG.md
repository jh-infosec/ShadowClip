# Changelog

## Version 0.1.0

Initial release.

### Added

- Clipboard daemon polling X11 every 0.5 seconds
- Rofi picker with numbered history, newest entry emphasised
- Configurable maximum entries, changed from the popup
- Clear all history action
- Black and green terminal theme with alternating row shading
- systemd user service for start on login

### Notes

History is stored as plain, unencrypted text in `~/.cache/shadowclip/` with
default permissions. Clear the history after copying anything sensitive.

There is no automatic expiry and no way to pause capturing in this version.
Both arrive in v0.2.
