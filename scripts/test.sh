#!/bin/zsh
# Generates the project and runs the unit tests (LelePdfTests) against the fake CLI.
# LELEPDF_REAL_CLAUDE is NOT set here: the regular suite always uses
# scripts/fake-claude/claude (SPEC §10.2).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${LELEPDF_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/LelePdf-cli}"

# The test app is ad-hoc signed: on every build macOS treats it as a new app,
# and any access it makes to the Desktop (protected by privacy) raises a
# prompt that nobody can approve, which blocks the suite. So the fake CLI and
# a read-only copy of the test PDFs are staged outside the Desktop, in a local
# cache that is never sent anywhere else.
STAGING="$HOME/Library/Caches/LelePdf/test-staging"
mkdir -p "$STAGING/fake-claude" "$STAGING/pdfs"

# `AppStore.shared` resolves the data folder ONCE, lazily, on the first call
# in the whole test process (LELEPDF_DATA_DIR, then
# UserDefaults.dataFolderPath, then ~/Documents/LelePdf, see
# DocumentStore.resolveDataFolder). Not every suite that creates a
# `DocumentModel(document:fileURL:)` sets UserDefaults.dataFolderPath first
# (only DocumentModelStoreIntegrationTests does, and only for itself): if one
# of the others (RewriteScrollHostTests, ScrollSyncReentrancyTests,
# ScrollSyncCoordinatorTests) touches AppStore.shared first in Swift
# Testing's execution order (not guaranteed, observed to vary from run to
# run), the whole test process falls back to the REAL data folder of the user
# (~/Documents/LelePdf), which is shared because the test app uses the same
# bundle id `com.emanuele.LelePdf` as the installed app (same root cause as
# the UserDefaults leak, here for the data folder). Setting LELEPDF_DATA_DIR
# as a true environment variable of the xcodebuild process (TEST_RUNNER_
# prefix: the "command line" form does not reach the process that runs the
# tests for this app-hosted target) makes the isolation independent of the
# suite order, for the whole run.
APPSTORE_STAGING="$STAGING/appstore-data"
mkdir -p "$APPSTORE_STAGING"
cp -f scripts/fake-claude/claude "$STAGING/fake-claude/claude"
chmod 755 "$STAGING/fake-claude/claude"
# Test PDFs: expected directly in this folder, with the file names of SPEC §4.
PDF_DIR="${LELEPDF_TEST_PDF_DIR:-$HOME/LelePdf-test-pdfs}"
stage_pdf() {
  local src="$1" dest="$2"
  [[ -f "$src" ]] || { echo "test: test PDF missing: $src" >&2; return 0; }
  brctl download "$src" >/dev/null 2>&1 || true
  if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
    cp -c "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
    chmod 444 "$dest"
  fi
}
stage_pdf "$PDF_DIR/Draghi M., The future of European competitiveness.pdf" "$STAGING/pdfs/draghi.pdf"
stage_pdf "$PDF_DIR/Strategy in the twenty-first century pharmaceutical industry Merck & Co. and Pfizer Inc.pdf" "$STAGING/pdfs/merck.pdf"
# Real case with doubled letters ("Buuildingg the Teeam"), taken from a
# different course than the two PDFs above.
stage_pdf "$PDF_DIR/L7 - Ockham.pdf" "$STAGING/pdfs/ockham.pdf"

# Same privacy trap as for the test PDFs above: `RealWordTemplateCheck` reads
# the user's personal Word template, so it is staged here, OUTSIDE the
# ad-hoc-signed test process, exactly like the PDFs. Never a direct Desktop
# access from inside the suite (silent hang, with nobody to approve the
# permission).
stage_pdf "${LELEPDF_WORD_TEMPLATE:-$PDF_DIR/word-template.docx}" "$STAGING/word-template-source.docx"

# Same privacy trap, but for `~/Documents/LelePdf` (the user's REAL data
# folder: never written, read only by this script, outside the ad-hoc-signed
# test process). `RealWordTemplateCheck` re-exports the user's real Ockham
# document with their real template, reading the `documento.json`/
# `analisi.json` staged here, never `~/Documents/LelePdf` from inside the
# suite.
OCKHAM_REAL_DIR="$HOME/Documents/LelePdf/Ockham Technologies (A)- Building the Team [d91f0fdd]"
OCKHAM_STAGED_DIR="$STAGING/ockham-real-analysis"
if [[ -f "$OCKHAM_REAL_DIR/documento.json" && -f "$OCKHAM_REAL_DIR/analisi.json" ]]; then
  mkdir -p "$OCKHAM_STAGED_DIR"
  for name in documento.json analisi.json; do
    stage_pdf "$OCKHAM_REAL_DIR/$name" "$OCKHAM_STAGED_DIR/$name"
  done
fi

# Fixtures of REAL responses recorded by scripts/test-real.sh (SPEC §10.2):
# if present in LelePdfTests/Fixtures/real/ (git-ignored), they are offered
# to the fake CLI for replay, so that tests using the fake CLI can receive a
# response identical to the one seen with the real CLI instead of the default
# synthetic logic. No test in the regular suite sets FAKE_CLAUDE_FIXTURES_DIR
# on its own yet: this staging only makes the folder available, ready to use.
FIXTURES_REPO="$ROOT/LelePdfTests/Fixtures/real"
FIXTURES_STAGED="$STAGING/fixtures-real"
mkdir -p "$FIXTURES_STAGED"
# zsh, not bash: no compgen. "(N)" is zsh's nullglob qualifier for this one
# pattern (the array stays empty instead of erroring out when there is no
# fixture).
real_fixtures=("$FIXTURES_REPO"/*.json(N))
if (( ${#real_fixtures} > 0 )); then
  cp -f "${real_fixtures[@]}" "$FIXTURES_STAGED/"
fi

echo "test: xcodegen…"
xcodegen generate --spec project.yml --quiet

# The performance benchmark (`PerformanceBenchmarkTests`) wants numbers that
# are comparable with the installed app, so it accepts
# `LELEPDF_TEST_CONFIGURATION=Release` (`ENABLE_TESTABILITY=YES` is needed for
# `@testable import` even with -O), and `LELEPDF_TEST_ONLY=<Suite>` to run a
# single suite instead of the ~2 minutes of the whole run. The
# `LELEPDF_MEASURE_PERF`/`LELEPDF_BENCH_*` variables reach the test process
# with the TEST_RUNNER_ prefix. With the benchmark on, the Claude CLI seen by
# the right panel (`ClaudeStatusModel.refresh`, `auth status` only) is the
# staged fake one, so no real process starts during the measurements.
CONFIGURATION="${LELEPDF_TEST_CONFIGURATION:-Debug}"
EXTRA_ARGS=()
if [[ "$CONFIGURATION" == "Release" ]]; then
  EXTRA_ARGS+=(ENABLE_TESTABILITY=YES)
elif [[ "$CONFIGURATION" != "Debug" ]]; then
  echo "test: unknown LELEPDF_TEST_CONFIGURATION \"$CONFIGURATION\" (Debug or Release only)" >&2
  exit 1
fi
if [[ -n "${LELEPDF_TEST_ONLY:-}" ]]; then
  EXTRA_ARGS+=(-only-testing:"LelePdfTests/${LELEPDF_TEST_ONLY}")
fi
# The Claude CLI seen by the test process is ALWAYS the staged fake one (the
# regular suite uses scripts/fake-claude), not only with the benchmark on:
# the suites that mount the right panel (`AlignmentMemoryTests`) also call
# `ClaudeStatusModel.refresh`. The `LELEPDF_BENCH_*` variables are always
# passed through: without the benchmark they do nothing.
BENCH_ENV=(TEST_RUNNER_LELEPDF_CLAUDE_PATH="$STAGING/fake-claude/claude")
if [[ "${LELEPDF_MEASURE_PERF:-0}" == "1" ]]; then
  BENCH_ENV+=(TEST_RUNNER_LELEPDF_MEASURE_PERF=1)
fi
for name in LELEPDF_BENCH_PDF LELEPDF_BENCH_WINDOW LELEPDF_BENCH_REPS LELEPDF_BENCH_FRACTION LELEPDF_BENCH_MARKS LELEPDF_BENCH_ONSCREEN LELEPDF_BENCH_ONLY LELEPDF_BENCH_ALIGN_STEPS LELEPDF_BENCH_MEMLOG LELEPDF_BENCH_GROWTH_MB LELEPDF_BENCH_HOLD_SECONDS LELEPDF_BENCH_SIDEBAR_TAB; do
  if [[ -n "${(P)name:-}" ]]; then BENCH_ENV+=("TEST_RUNNER_${name}=${(P)name}"); fi
done

echo "test: xcodebuild test ($CONFIGURATION, arm64${LELEPDF_TEST_ONLY:+, only $LELEPDF_TEST_ONLY})…"
# LELEPDF_TEST_LOG: keeps the full xcodebuild log in that file (benchmark
# diagnostics: `[mem]` lines), otherwise it is temporary and removed.
LOG="${LELEPDF_TEST_LOG:-$(mktemp)}"
set +e

# Optional footprint sampler for the test process hosted in the app (same
# pattern as the memory watchdog: `top -l 1 -pid <pid> -stats mem`, not the
# RSS, which macOS compresses without showing it).
# LELEPDF_TEST_MEM_LOG=<path> writes a CSV "epoch_ms,mb", one sample per
# second for the whole run; without the variable nothing is started (no cost
# for the ordinary run).
MEM_LOG="${LELEPDF_TEST_MEM_LOG:-}"
SAMPLER_PID=""
if [[ -n "$MEM_LOG" ]]; then
  mkdir -p "$(dirname "$MEM_LOG")"
  echo "epoch_ms,mb" > "$MEM_LOG"
  APP_BIN="$DERIVED_DATA/Build/Products/$CONFIGURATION/LelePdf.app/Contents/MacOS/LelePdf"
  (
    while true; do
      pid=$(pgrep -f "$APP_BIN" 2>/dev/null | head -1)
      if [[ -n "$pid" ]]; then
        raw=$(top -l 1 -pid "$pid" -stats mem 2>/dev/null | tail -1 | tr -d ' +-')
        if [[ -n "$raw" && "$raw" != "mem" ]]; then
          num=${raw%[KMGB]*}
          unit=${raw##*[0-9.]}
          case "$unit" in
            G*) mb=$(echo "$num * 1024" | bc) ;;
            M*) mb="$num" ;;
            K*) mb=$(echo "$num / 1024" | bc) ;;
            *)  mb="" ;;
          esac
          [[ -n "$mb" ]] && echo "$(date +%s000),$mb" >> "$MEM_LOG"
        fi
      fi
      sleep 1
    done
  ) &
  SAMPLER_PID=$!
fi

XCODEBUILD_CMD=(
  env
  TEST_RUNNER_LELEPDF_DATA_DIR="$APPSTORE_STAGING"
  TEST_RUNNER_LELEPDF_MEASURE_MEMORY="${LELEPDF_MEASURE_MEMORY:-0}"
  "${BENCH_ENV[@]}"
  xcodebuild
    -scheme LelePdf
    -configuration "$CONFIGURATION"
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$DERIVED_DATA"
    "${EXTRA_ARGS[@]}"
    test
)
if [[ -n "$MEM_LOG" ]]; then
  # With the sampler on, every log line is prefixed with the epoch in ms (same
  # clock as the CSV): it correlates the peak with the running test without
  # touching the existing greps (substring matches, not anchored at the start
  # of the line).
  "${XCODEBUILD_CMD[@]}" 2>&1 | while IFS= read -r line; do
    printf '%s %s\n' "$(date +%s000)" "$line"
  done > "$LOG"
  STATUS=${pipestatus[1]}
else
  "${XCODEBUILD_CMD[@]}" > "$LOG" 2>&1
  STATUS=$?
fi
set -e

if [[ -n "$SAMPLER_PID" ]]; then
  kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  PEAK_MB=$(awk -F, 'NR>1 && $2+0>max{max=$2} END{print max+0}' "$MEM_LOG")
  echo "test: sampled peak footprint: ${PEAK_MB} MB (details in $MEM_LOG)"
fi

if [[ -n "${LELEPDF_TEST_KEEP_LOG:-}" ]]; then
  mkdir -p "$(dirname "${LELEPDF_TEST_KEEP_LOG}")"
  cp -f "$LOG" "${LELEPDF_TEST_KEEP_LOG}"
  echo "test: full log copied to ${LELEPDF_TEST_KEEP_LOG}"
fi
# The benchmark prints its own report between two markers: show it again
# here, otherwise it would only stay in the temporary log.
if [[ "${LELEPDF_MEASURE_PERF:-0}" == "1" ]]; then
  # The markers and status lines below are printed by PerformanceBenchmarkTests
  # (keep them in sync).
  sed -n -E '/===== F5 BENCH =====/,/===== END F5 BENCH =====/p' "$LOG" || true
  grep -E "F5 BENCH: report saved|PerformanceBenchmarkTests: skip|SKIP: PDF" "$LOG" || true
fi

SUMMARY_LINE=$(grep -E "Test run with .* tests? in .* suites? (passed|failed)" "$LOG" | tail -1 || true)
PASSED=$(grep -E "✔ Test \".*\" passed" "$LOG" | grep -c . || true)
FAILED=$(grep -E "✘ Test \".*\" failed" "$LOG" | grep -c . || true)

echo "test: summary — tests passed: $PASSED · tests failed: $FAILED"
[[ -n "$SUMMARY_LINE" ]] && echo "test: $SUMMARY_LINE"

if [[ $STATUS -ne 0 ]]; then
  echo "test: FAILED — error details:" >&2
  grep -E "error:|Assertion Failure|failed \(|✘ Test|Expectation failed|Issue recorded" "$LOG" >&2 || true
  [[ -z "${LELEPDF_TEST_LOG:-}" ]] && rm -f "$LOG"
  exit 1
fi

[[ -z "${LELEPDF_TEST_LOG:-}" ]] && rm -f "$LOG"
exit 0
