#!/bin/zsh
# Build Proof.iconset and AppIcon.icns from the two SVG masters.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Render an SVG at an exact pixel size. The viewBox stays 1024; only the
# width/height attributes change, so Chrome rasterises the vectors at the
# target size instead of downscaling a large screenshot.
shot() {
  local src="$1" size="$2" out="$3"
  local tmp="$TMP/$(basename "$src" .svg)-$size.svg"
  sed -E "s/(<svg[^>]* width=\")[0-9]+(\" height=\")[0-9]+/\1$size\2/" "$src" > "$tmp"
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 --window-size="$size,$size" \
    --screenshot="$out" "file://$tmp" >/dev/null 2>&1
}

rm -rf Proof.iconset
mkdir -p Proof.iconset

shot proof-icon.svg        1024 "$TMP/1024.png"
shot proof-icon.svg         512 "$TMP/512.png"
shot proof-icon.svg         256 "$TMP/256.png"
shot proof-icon.svg         128 "$TMP/128.png"
shot proof-icon.svg          64 "$TMP/64.png"
shot proof-icon-small.svg    32 "$TMP/32.png"
shot proof-icon-small-16.svg 16 "$TMP/16.png"

cp "$TMP/16.png"   Proof.iconset/icon_16x16.png
cp "$TMP/32.png"   Proof.iconset/icon_16x16@2x.png
cp "$TMP/32.png"   Proof.iconset/icon_32x32.png
cp "$TMP/64.png"   Proof.iconset/icon_32x32@2x.png
cp "$TMP/128.png"  Proof.iconset/icon_128x128.png
cp "$TMP/256.png"  Proof.iconset/icon_128x128@2x.png
cp "$TMP/256.png"  Proof.iconset/icon_256x256.png
cp "$TMP/512.png"  Proof.iconset/icon_256x256@2x.png
cp "$TMP/512.png"  Proof.iconset/icon_512x512.png
cp "$TMP/1024.png" Proof.iconset/icon_512x512@2x.png
cp "$TMP/1024.png" proof-icon-1024.png

iconutil -c icns Proof.iconset -o AppIcon.icns

echo "Built Proof.iconset and AppIcon.icns"
