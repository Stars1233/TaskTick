#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# Build AppIcon.icns from the three SVG sources.
# Usage: ./scripts/make-icon.sh
# ─────────────────────────────────────────────
#
# macOS stores one image per size slot in an .icns and picks the slot that
# matches where the icon is being drawn. That means each slot can carry a
# different amount of detail — and has to, because detail that looks crisp at
# 512px turns to mush at 16px. The previous icon shipped one 1024px artwork
# scaled into every slot, which is why it read as a grey smudge in the menu bar.
#
#   docs/icon.svg         full detail       → 256 / 512 / 1024
#   docs/icon-medium.svg  fewer markers     → 64 / 128
#   docs/icon-small.svg   dial + badge      → 32
#   docs/icon-tiny.svg    badge as dot only → 16
#
# Edit the SVGs, re-run this, rebuild. Nothing else reads the .icns directly.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LARGE="${PROJECT_ROOT}/docs/icon.svg"
MEDIUM="${PROJECT_ROOT}/docs/icon-medium.svg"
SMALL="${PROJECT_ROOT}/docs/icon-small.svg"
TINY="${PROJECT_ROOT}/docs/icon-tiny.svg"
OUT="${PROJECT_ROOT}/Sources/Resources/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "Error: rsvg-convert not found — brew install librsvg" >&2
  exit 1
fi

for f in "${LARGE}" "${MEDIUM}" "${SMALL}" "${TINY}"; do
  [ -f "$f" ] || { echo "Error: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"

# render <svg> <pixels> <slot filename>
render() {
  rsvg-convert -w "$2" -h "$2" "$1" -o "${ICONSET}/$3"
  echo "  $3  ←  $(basename "$1")"
}

echo "── Rendering icon slots ──"
render "${TINY}"   16   "icon_16x16.png"
render "${SMALL}"  32   "icon_16x16@2x.png"
render "${SMALL}"  32   "icon_32x32.png"
render "${MEDIUM}" 64   "icon_32x32@2x.png"
render "${MEDIUM}" 128  "icon_128x128.png"
render "${LARGE}"  256  "icon_128x128@2x.png"
render "${LARGE}"  256  "icon_256x256.png"
render "${LARGE}"  512  "icon_256x256@2x.png"
render "${LARGE}"  512  "icon_512x512.png"
render "${LARGE}"  1024 "icon_512x512@2x.png"

iconutil -c icns "${ICONSET}" -o "${OUT}"

echo ""
echo "── Done ──"
echo "  ${OUT}  ($(du -h "${OUT}" | cut -f1))"
