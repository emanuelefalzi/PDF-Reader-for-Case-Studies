#!/bin/zsh
# Memory measurement (SPEC §9): opening time and memory footprint on a
# synthetic 600-page PDF, built ONLY with PDFKit (make-synthetic-pdf.swift) by
# concatenating the already staged pages of Draghi and Merck: never the
# original PDFs, never in the repository.
# Same verification build/bundle id as scripts/measure-sync.sh
# (com.emanuele.LelePdfVerify), so no second installation is needed and
# /Applications/LelePdf.app or the user's real data are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA_VERIFY="$HOME/Library/Developer/Xcode/DerivedData/LelePdf-verify-cli"
BUNDLE_ID="com.emanuele.LelePdfVerify"
APP_PATH="$DERIVED_DATA_VERIFY/Build/Products/Debug/LelePdf.app"
VERIFY_DIR="$HOME/Library/Application Support/LelePdf-verify-memory"
STAGING_DIR="$HOME/Library/Caches/LelePdf/test-staging/pdfs"
SYNTHETIC="$STAGING_DIR/synthetic-600.pdf"

if [[ ! -r "$SYNTHETIC" ]]; then
  echo "measure: synthetic PDF missing — generate it with: swift scripts/make-synthetic-pdf.swift $STAGING_DIR/draghi.pdf $STAGING_DIR/merck.pdf $SYNTHETIC 600" >&2
  exit 1
fi

if pgrep -f "/Applications/LelePdf.app" >/dev/null 2>&1; then
  echo "measure: note — /Applications/LelePdf.app is running (probably in use): not touching it." >&2
fi

echo "measure: xcodegen…"
xcodegen generate --spec project.yml --quiet
echo "measure: verification build (bundle id $BUNDLE_ID)…"
xcodebuild -scheme LelePdf -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_VERIFY" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build \
  > /tmp/lelepdf-measure-memory-build.log 2>&1 || { echo "measure: build failed, see /tmp/lelepdf-measure-memory-build.log" >&2; tail -40 /tmp/lelepdf-measure-memory-build.log >&2; exit 1; }

if pgrep -fl "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "measure: a previous verification instance ($BUNDLE_ID) is still running — aborting." >&2
  exit 1
fi

rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"

t0=$(date +%s.%N)
open --env LELEPDF_DATA_DIR="$VERIFY_DIR" -a "$APP_PATH" "$SYNTHETIC"

pid=""
waited=0
while (( waited < 20 )); do
  pid=$(pgrep -f "$APP_PATH/Contents/MacOS/" | head -1 || true)
  [[ -n "$pid" ]] && break
  sleep 0.5
  waited=$((waited + 1))
done
if [[ -z "$pid" ]]; then
  echo "measure: the process never started" >&2
  exit 1
fi

# Wait for the window (a proxy for the first visible page: the window only
# appears after `DocumentWindowView`/`PDFKitView` are already mounted).
window_seen=0
elapsed_window=""
for _ in $(seq 1 40); do
  count=$(osascript -e "tell application \"System Events\" to count windows of (first process whose bundle identifier is \"$BUNDLE_ID\")" 2>/dev/null || echo 0)
  if [[ "$count" -ge 1 ]]; then
    t1=$(date +%s.%N)
    elapsed_window=$(echo "$t1 - $t0" | bc)
    window_seen=1
    break
  fi
  sleep 0.1
done

echo "measure: window appeared after ${elapsed_window:-unknown} s (pid $pid)"

# Wait for a real completion signal, not a fixed interval: on a cold cache
# the extraction of 600 pages can take a different time than a reopening with
# `layout.json` already present. The data folder is empty at the start of the
# measurement; `documento.json` only appears after PipelineRunner has
# published the structure and `attachStructureToStore` has registered it.
pipeline_ready=0
pipeline_wait_ticks=0
while (( pipeline_wait_ticks < 240 )); do
  if [[ -n "$(find "$VERIFY_DIR" -name documento.json -print -quit 2>/dev/null)" ]]; then
    pipeline_ready=1
    break
  fi
  sleep 0.5
  pipeline_wait_ticks=$((pipeline_wait_ticks + 1))
done
if (( pipeline_ready == 0 )); then
  echo "measure: pipeline not completed within 120 s — invalid measurement" >&2
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -f "$APP_PATH" >/dev/null 2>&1 || true
  exit 1
fi

# Short settling time after the temporaries are published/removed.
sleep 3

echo "measure: memory footprint…"
FOOTPRINT_OUTPUT=$(footprint -s "$pid" 2>&1 || true)
echo "$FOOTPRINT_OUTPUT"

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
killWaited=0
while pgrep -f "$BUNDLE_ID" >/dev/null 2>&1 && (( killWaited < 10 )); do
  sleep 1
  killWaited=$((killWaited + 1))
done
pkill -f "$APP_PATH" >/dev/null 2>&1 || true

pipeline_wait=$(echo "$pipeline_wait_ticks * 0.5" | bc)
echo "measure: window=${elapsed_window:-unknown}s window_seen=$window_seen pipeline_ready=$pipeline_ready pipeline_wait=${pipeline_wait}s — see the footprint output above for the physical footprint."
