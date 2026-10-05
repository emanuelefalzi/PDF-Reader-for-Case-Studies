#!/bin/zsh
# Launches LelePdf with one of the test PDFs (SPEC §4) or a path of your choice.
# Usage: scripts/run.sh [merck|draghi|<path.pdf>]
# The test PDFs are expected directly in $LELEPDF_TEST_PDF_DIR
# (default ~/LelePdf-test-pdfs), with the file names of SPEC §4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PDF_DIR="${LELEPDF_TEST_PDF_DIR:-$HOME/LelePdf-test-pdfs}"
MERCK="$PDF_DIR/Strategy in the twenty-first century pharmaceutical industry Merck & Co. and Pfizer Inc.pdf"
DRAGHI="$PDF_DIR/Draghi M., The future of European competitiveness.pdf"

TARGET="${1:-merck}"
case "$TARGET" in
  merck)  PDF="$MERCK" ;;
  draghi) PDF="$DRAGHI" ;;
  *)      PDF="$TARGET" ;;
esac

if [[ ! -f "$PDF" ]]; then
  echo "run: cannot find the PDF: $PDF" >&2
  exit 1
fi

echo "run: downloading from iCloud if needed…"
brctl download "$PDF" >/dev/null 2>&1 || true

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/LelePdf-cli"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/LelePdf.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "run: build not found, building…"
  "$ROOT/scripts/build.sh"
fi

echo "run: opening $PDF"
open -a "$APP_PATH" "$PDF"
