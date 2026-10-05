#!/bin/zsh
# Generates AppIcon.appiconset and ChatLogo.imageset from logo/E.png
# (SPEC §10.1). Large sizes: the whole logo on a rounded white square.
# Small sizes (<=64 px) and ChatLogo: only the cropped "EF" monogram.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/logo/E.png"
XCASSETS="$ROOT/LelePdf/Assets.xcassets"
APPICON="$XCASSETS/AppIcon.appiconset"
CHATLOGO="$XCASSETS/ChatLogo.imageset"
GEN_SWIFT="$ROOT/scripts/make-icons.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "make-icons: checking that logo/E.png is downloaded from iCloud…"
brctl download "$SOURCE" >/dev/null 2>&1 || true

if [[ ! -f "$SOURCE" ]]; then
  echo "error: cannot find $SOURCE" >&2
  exit 1
fi

# Crop rectangle of the "EF" monogram in logo/E.png (500x500), in "screen"
# coordinates (origin at the top left): x,y,width,height.
# Chosen by eye looking at logo/E.png: it includes the E/F letters and the
# name band, and excludes the caption below.
CROP_RECT="20,155,460,190"

echo "make-icons: generating the master images (monogram + logo on a white square)…"
xcrun swift "$GEN_SWIFT" "$SOURCE" "$WORK" "$CROP_RECT"

MONO="$WORK/monogram_master.png"
LARGE="$WORK/large_master.png"

resize() {
  local src="$1" px="$2" dst="$3"
  sips -z "$px" "$px" "$src" --out "$dst" >/dev/null
}

echo "make-icons: AppIcon (small sizes = monogram, large sizes = logo on white)…"
resize "$MONO"  16   "$APPICON/icon_16x16.png"
resize "$MONO"  32   "$APPICON/icon_16x16@2x.png"
resize "$MONO"  32   "$APPICON/icon_32x32.png"
resize "$MONO"  64   "$APPICON/icon_32x32@2x.png"
resize "$LARGE" 128  "$APPICON/icon_128x128.png"
resize "$LARGE" 256  "$APPICON/icon_128x128@2x.png"
resize "$LARGE" 256  "$APPICON/icon_256x256.png"
resize "$LARGE" 512  "$APPICON/icon_256x256@2x.png"
resize "$LARGE" 512  "$APPICON/icon_512x512.png"
resize "$LARGE" 1024 "$APPICON/icon_512x512@2x.png"

echo "make-icons: ChatLogo (monogram only)…"
resize "$MONO" 44  "$CHATLOGO/ChatLogo.png"
resize "$MONO" 88  "$CHATLOGO/ChatLogo@2x.png"
resize "$MONO" 132 "$CHATLOGO/ChatLogo@3x.png"

echo "make-icons: done."
