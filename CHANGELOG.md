# Changelog

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
