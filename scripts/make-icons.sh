#!/bin/zsh
# Regenerates every icon from assets/icon.svg:
#   assets/AppIcon.icns   app bundle icon
#   assets/favicon.ico    16/32/48 px favicon
#   assets/favicon.png    180 px (apple-touch-icon size)
set -euo pipefail
cd "${0:A:h}/.."

SVG=assets/icon.svg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -O scripts/render-icon.swift -o "$TMP/render" 2>/dev/null
render() { "$TMP/render" "$SVG" "$2" "$1"; }

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  render $size "$ICONSET/icon_${size}x${size}.png"
  render $((size * 2)) "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns

render 180 assets/favicon.png
render 48 "$TMP/favicon-48.png"
sips -s format ico "$TMP/favicon-48.png" --out assets/favicon.ico >/dev/null

echo "wrote assets/AppIcon.icns assets/favicon.ico assets/favicon.png"
