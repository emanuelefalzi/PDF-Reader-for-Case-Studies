#!/bin/zsh
# Generates the project with XcodeGen and builds the LelePdf scheme (Debug by
# default; `scripts/build.sh Release` for a Release build). It ONLY builds:
# it never installs into /Applications by itself.
# DerivedData stays outside the Desktop (SPEC §2), as required for iCloud.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-Debug}"
if [[ "$CONFIGURATION" != "Debug" && "$CONFIGURATION" != "Release" ]]; then
  echo "build: unknown configuration \"$CONFIGURATION\" (Debug or Release only)" >&2
  exit 1
fi

DEFAULT_DERIVED_DATA_NAME="LelePdf-cli"
[[ "$CONFIGURATION" == "Release" ]] && DEFAULT_DERIVED_DATA_NAME="LelePdf-release"
DERIVED_DATA="${LELEPDF_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/$DEFAULT_DERIVED_DATA_NAME}"

echo "build: xcodegen…"
xcodegen generate --spec project.yml --quiet

echo "build: xcodebuild ($CONFIGURATION, arm64)…"
LOG="$(mktemp)"
if xcodebuild \
    -scheme LelePdf \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    build > "$LOG" 2>&1; then
  echo "build: OK"
  rm -f "$LOG"
  exit 0
else
  echo "build: FAILED — output:" >&2
  grep -E "error:|warning:|BUILD FAILED" "$LOG" >&2 || cat "$LOG" >&2
  rm -f "$LOG"
  exit 1
fi
