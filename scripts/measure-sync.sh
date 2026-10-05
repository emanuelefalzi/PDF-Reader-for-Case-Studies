#!/bin/zsh
# Measurement of the linked scrolling (SPEC §5.8 "How it is measured"):
# launches the app on Merck and Draghi with
# LELEPDF_MEASURE=1/LELEPDF_MEASURE_AUTORUN=1 (SyncMeasurementRunner scrolls
# both sides and generates a few synthetic hovers), reads the samples written
# to ~/Library/Caches/LelePdf/measure/ and updates the measurements log with
# minimum/median/95th percentile. Verification data folder with the real
# analyses already saved: 0 calls to Claude.
#
# This is a fallback to an XCUITest target: the ad-hoc-signed test app hangs
# on the privacy permissions in this environment, and a UI test target would
# need the Accessibility permission anyway to drive system events.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Separate verification bundle id: `pgrep` and UI automation cannot tell two
# processes with the same bundle id apart, and the installed app
# (`/Applications/LelePdf.app`, com.emanuele.LelePdf) may be open right now
# with its real documents: it must never be touched.
# `project.yml` stays unchanged: the override is only on the xcodebuild
# command line, in a separate DerivedData that is never installed into
# /Applications.
DERIVED_DATA_VERIFY="$HOME/Library/Developer/Xcode/DerivedData/LelePdf-verify-cli"
BUNDLE_ID="com.emanuele.LelePdfVerify"
APP_PATH="$DERIVED_DATA_VERIFY/Build/Products/Debug/LelePdf.app"
VERIFY_DIR="$HOME/Library/Application Support/LelePdf-verifica"
MEASURE_DIR="$HOME/Library/Caches/LelePdf/measure"
RESULTS_DIR="$HOME/Library/Caches/LelePdf/measure-results"

# Test PDFs: only the copies already staged outside Desktop/Documents (an
# ad-hoc-signed host hangs on the privacy permissions of ~/Desktop and
# ~/Documents). If they are not there yet, `scripts/test.sh` prepares them
# (same mechanism as `TestPDFs.stagingDir`); the original path is never
# touched here.
STAGING_DIR="$HOME/Library/Caches/LelePdf/test-staging/pdfs"
MERCK="$STAGING_DIR/merck.pdf"
DRAGHI="$STAGING_DIR/draghi.pdf"

if [[ ! -r "$MERCK" || ! -r "$DRAGHI" ]]; then
  echo "measure: staged PDFs missing in $STAGING_DIR — run scripts/test.sh first (it prepares them)." >&2
  exit 1
fi

if pgrep -f "/Applications/LelePdf.app" >/dev/null 2>&1; then
  echo "measure: note — /Applications/LelePdf.app is running (probably in use): not touching it, using only the separate verification bundle id ($BUNDLE_ID)." >&2
fi

echo "measure: xcodegen…"
xcodegen generate --spec project.yml --quiet
echo "measure: verification build (bundle id $BUNDLE_ID)…"
xcodebuild -scheme LelePdf -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_VERIFY" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build \
  > /tmp/lelepdf-measure-build.log 2>&1 || { echo "measure: verification build failed, see /tmp/lelepdf-measure-build.log" >&2; tail -40 /tmp/lelepdf-measure-build.log >&2; exit 1; }

if pgrep -fl "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "measure: a previous verification instance ($BUNDLE_ID) is still running — aborting." >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"

run_one() {
  local label="$1" pdf="$2"
  echo "measure: $label…"
  rm -rf "$MEASURE_DIR"
  mkdir -p "$MEASURE_DIR"
  brctl download "$pdf" >/dev/null 2>&1 || true

  # Retry once if macOS still considers the previous instance "running" (the
  # autorun now quits by itself, see
  # `DocumentModel.beginMeasurementAutorunIfNeeded`, but Launch Services can
  # lag a fraction of a second behind `pgrep`): without it, `open` with new
  # environment variables fails silently ("was already running and so the
  # additional environment variables could not be set"), observed when
  # moving from Merck to Draghi.
  local openTry=0
  while (( openTry < 2 )); do
    if open --env LELEPDF_DATA_DIR="$VERIFY_DIR" --env LELEPDF_MEASURE=1 --env LELEPDF_MEASURE_AUTORUN=1 -a "$APP_PATH" "$pdf" 2>/tmp/lelepdf-measure-open.log; then
      if ! grep -q "already running" /tmp/lelepdf-measure-open.log 2>/dev/null; then
        break
      fi
    fi
    openTry=$((openTry + 1))
    echo "measure: $label — previous instance still seen by Launch Services, retrying in 2s (attempt $openTry)…" >&2
    pkill -f "$APP_PATH" >/dev/null 2>&1 || true
    sleep 2
  done

  # SyncMeasurementRunner: waits for the data to be ready (up to ~10s), then
  # scrolls the two sides and generates synthetic hovers: wide margin before
  # giving up.
  local waited=0
  local found=0
  while (( waited < 45 )); do
    local files=("$MEASURE_DIR"/*.json(N))
    if (( ${#files} > 0 )); then
      found=1
      sleep 2 # let it finish writing
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local killWaited=0
  while pgrep -f "$BUNDLE_ID" >/dev/null 2>&1 && (( killWaited < 10 )); do
    sleep 1
    killWaited=$((killWaited + 1))
  done
  pkill -f "$APP_PATH" >/dev/null 2>&1 || true
  sleep 1 # let Launch Services catch up before the next `open`

  local files=("$MEASURE_DIR"/*.json(N))
  if (( found == 1 && ${#files} > 0 )); then
    cp -f "${files[1]}" "$RESULTS_DIR/$label.json"
    echo "measure: $label → $RESULTS_DIR/$label.json"
    local debugFiles=("$MEASURE_DIR"/debug-segments-*.txt(N))
    if (( ${#debugFiles} > 0 )); then
      cp -f "${debugFiles[1]}" "$RESULTS_DIR/$label-debug-segments.txt"
    fi
  else
    echo "measure: $label — no file written within the maximum time" >&2
    rm -f "$RESULTS_DIR/$label.json"
  fi
}

run_one merck "$MERCK"
run_one draghi "$DRAGHI"

echo "measure: computing statistics and updating the measurements log…"
python3 "$ROOT/scripts/measure-sync-report.py" "$RESULTS_DIR/merck.json" "$RESULTS_DIR/draghi.json" "$ROOT/docs/measurements.md"
