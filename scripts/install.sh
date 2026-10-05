#!/bin/zsh
# Builds the Release configuration and installs it into /Applications, signed
# with your own "Apple Development" certificate if one is configured in
# project.yml. With a stable signature macOS recognizes the app as the same
# one at every reinstall and does not ask for the Desktop permission again
# (with an ad-hoc signature every build is a new app).
#   scripts/install.sh            -> /Applications/LelePdf F4.app
#   scripts/install.sh "Name" id  -> /Applications/Name.app with bundle id "id"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-LelePdf F4}"
BUNDLE_ID="${2:-com.emanuele.LelePdfF4}"
DERIVED="${LELEPDF_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/LelePdf-main}"
cd "$ROOT"
if [[ "${3:-}" == "--pending" || "${1:-}" == "--pending" ]]; then
  [[ "${1:-}" == "--pending" ]] && NAME="LelePdf F4" && BUNDLE_ID="com.emanuele.LelePdfF4"
  PENDING="$HOME/Library/Application Support/LelePdf-versions/pending/$NAME.app"
  [[ -d "$PENDING" ]] || { echo "no pending build for $NAME"; exit 0; }
  mkdir -p "$DERIVED/Build/Products/Release"
  rm -rf "$DERIVED/Build/Products/Release/LelePdf.app"
  ditto "$PENDING" "$DERIVED/Build/Products/Release/LelePdf.app"
else
  LELEPDF_DERIVED_DATA="$DERIVED" scripts/build.sh Release
fi
DEST="/Applications/$NAME.app"
# Never quit the app while the user is using it. If it is open, the new build
# stays ready in Application Support and the installation is postponed: repeat
# it when the app is closed (scripts/install.sh --pending installs it without
# rebuilding).
PENDING="$HOME/Library/Application Support/LelePdf-versions/pending/$NAME.app"
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
  mkdir -p "$(dirname "$PENDING")"
  rm -rf "$PENDING"
  ditto "$DERIVED/Build/Products/Release/LelePdf.app" "$PENDING"
  echo "postponed: $NAME is open; build ready in $PENDING"
  exit 3
fi
rm -rf "$DEST"
ditto "$DERIVED/Build/Products/Release/LelePdf.app" "$DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DEST/Contents/Info.plist"
codesign --force --deep --sign "Apple Development" "$DEST"
codesign --verify --strict "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
rm -rf "$HOME/Library/Application Support/LelePdf-versions/pending/$NAME.app"
echo "installed: $DEST ($(codesign -dv "$DEST" 2>&1 | grep TeamIdentifier))"
