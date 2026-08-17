#!/bin/bash
#
# shadowclip-picker.sh
#
# Thin launcher for the GTK picker. The hotkey and the systemd-free callers
# invoke this name, so keeping it means the install and the key binding do not
# have to change when the front end moved from rofi to Python in 0.5.0.
#
# It resolves the real script next to itself and execs it, so there is only
# ever one implementation to maintain.

set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"
exec python3 "$here/shadowclip-picker.py" "$@"
