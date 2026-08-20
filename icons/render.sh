#!/usr/bin/env bash
# Regenerate the PNG icon set from the two SVG drawings.
#
# The PNGs in this directory are build output, not artwork: edit the SVGs and
# re-run this. Sizes at or below 32 come from shadowclip-small.svg, which is
# drawn as solid shapes because an outline fills in at that scale; everything
# above comes from shadowclip.svg.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    printf '%s\n' "missing dependency: rsvg-convert -- sudo apt install librsvg2-bin"
    exit 1
fi

for size in 16 24 32; do
    rsvg-convert -w "$size" -h "$size" shadowclip-small.svg -o "shadowclip-$size.png"
    printf '%s\n' "rendered shadowclip-$size.png (small drawing)"
done

for size in 48 64 128 256; do
    rsvg-convert -w "$size" -h "$size" shadowclip.svg -o "shadowclip-$size.png"
    printf '%s\n' "rendered shadowclip-$size.png"
done
