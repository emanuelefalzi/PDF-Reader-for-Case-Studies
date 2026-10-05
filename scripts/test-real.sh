#!/bin/zsh
# Runs ONCE the chosen suite with real calls to Claude (SPEC §10.2):
# `toc` = RealClaudeTocTests (generated contents of Draghi/Merck, 2 calls);
# `analysis` (default) = RealBlockAnalysisTests (5 consecutive Merck blocks +
# 3 Draghi blocks, 8 calls, quality measurements of §7.5); `all` = all of
# them. The default is `analysis` on purpose (not `all`): rerunning this
# script without arguments must not spend again the calls of the contents
# generation, which were already made and verified.
#
# Usage: scripts/test-real.sh [toc|analysis|chat|format|stili|grana|all]
#   format = prompt comparison for the point/sub-point format
#   stili  = style prompt/schema (point, sub-point, explanation, note, formula, consequence, subheading)
#   grana  = density of the Chapter vs Paragraph prompt
#
# The real CLI is used (normally ~/.local/bin/claude, SPEC §5.11): no
# LELEPDF_CLAUDE_PATH variable must be set for this script.
#
# The raw responses are saved by the test in
# ~/Library/Caches/LelePdf/test-staging/fixtures-real/ (the test host cannot
# write into the repository on the Desktop): this script then copies them
# into LelePdfTests/Fixtures/real/ (git-ignored), from where scripts/test.sh
# offers them to the fake CLI for replay.
set -euo pipefail

SUITE="${1:-analysis}"
case "$SUITE" in
  toc) TEST_FILTER="LelePdfTests/RealClaudeTocTests" ;;
  analysis) TEST_FILTER="LelePdfTests/RealBlockAnalysisTests" ;;
  chat) TEST_FILTER="LelePdfTests/ChatRealTests" ;;
  # Old vs new prompt comparison for the point/sub-point format, on
  # Merck/Draghi/Wii.
  format) TEST_FILTER="LelePdfTests/RealFormatComparisonTests" ;;
  # The new prompt/schema (point/sub-point/explanation/note/formula/
  # consequence/subheading), 3 calls on Merck/Draghi/Wii.
  stili) TEST_FILTER="LelePdfTests/RealF7StyleTests" ;;
  # Density of the Chapter vs Paragraph prompt, 4 calls on Merck/Draghi.
  grana) TEST_FILTER="LelePdfTests/RealGranularityDensityTests" ;;
  all) TEST_FILTER="" ;;
  *) echo "test-real: usage: scripts/test-real.sh [toc|analysis|chat|format|stili|grana|all]" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${LELEPDF_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/LelePdf-cli}"
FIXTURES_CACHE="$HOME/Library/Caches/LelePdf/test-staging/fixtures-real"
FIXTURES_REPO="$ROOT/LelePdfTests/Fixtures/real"

# Same staging as scripts/test.sh (macOS privacy on the Desktop for the
# ad-hoc-signed test app).
STAGING="$HOME/Library/Caches/LelePdf/test-staging"
mkdir -p "$STAGING/pdfs" "$FIXTURES_CACHE"
# Same isolated test data folder as in scripts/test.sh, independent of the
# suite order, in case this script is launched without a filter (`all`) and
# ends up including a suite that creates a
# `DocumentModel(document:fileURL:)`.
APPSTORE_STAGING="$STAGING/appstore-data"
mkdir -p "$APPSTORE_STAGING"
# Test PDFs: expected directly in this folder, with the file names of SPEC §4.
PDF_DIR="${LELEPDF_TEST_PDF_DIR:-$HOME/LelePdf-test-pdfs}"
stage_pdf() {
  local src="$1" dest="$2"
  [[ -f "$src" ]] || { echo "test-real: test PDF missing: $src" >&2; return 0; }
  brctl download "$src" >/dev/null 2>&1 || true
  if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
    cp -c "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
    chmod 444 "$dest"
  fi
}
stage_pdf "$PDF_DIR/Draghi M., The future of European competitiveness.pdf" "$STAGING/pdfs/draghi.pdf"
stage_pdf "$PDF_DIR/Strategy in the twenty-first century pharmaceutical industry Merck & Co. and Pfizer Inc.pdf" "$STAGING/pdfs/merck.pdf"
# Third test PDF for the format comparison (TestPDFs.wii).
stage_pdf "$PDF_DIR/TIS-Nintendo Wii.pdf" "$STAGING/pdfs/wii.pdf"
# Same reason as in `scripts/test.sh` (privacy trap): `RealWordTemplateCheck`
# reads the user's personal Word template, staged here instead of by the
# test itself.
stage_pdf "${LELEPDF_WORD_TEMPLATE:-$PDF_DIR/word-template.docx}" "$STAGING/word-template-source.docx"

# Same privacy trap, for `~/Documents/LelePdf`: see `scripts/test.sh`.
OCKHAM_REAL_DIR="$HOME/Documents/LelePdf/Ockham Technologies (A)- Building the Team [d91f0fdd]"
OCKHAM_STAGED_DIR="$STAGING/ockham-real-analysis"
if [[ -f "$OCKHAM_REAL_DIR/documento.json" && -f "$OCKHAM_REAL_DIR/analisi.json" ]]; then
  mkdir -p "$OCKHAM_STAGED_DIR"
  for name in documento.json analisi.json; do
    stage_pdf "$OCKHAM_REAL_DIR/$name" "$OCKHAM_STAGED_DIR/$name"
  done
fi

echo "test-real: xcodegen…"
xcodegen generate --spec project.yml --quiet

echo "test-real: WARNING — this run really calls Claude (suite: $SUITE)."
echo "test-real: xcodebuild test (Debug, arm64, suite: $SUITE)…"
LOG="$(mktemp)"
set +e
# TEST_RUNNER_<NAME> must be a TRUE environment variable of the xcodebuild
# process, not a "KEY=VALUE" on the command line: the latter is read as an
# override of the build settings (it shows up in the build log) but for this
# "app-hosted" test target (BUNDLE_LOADER/TEST_HOST, not a separate XCTest
# runner) it does not reach the process that actually runs the tests.
# Verified in practice: with the "command line" form LELEPDF_REAL_CLAUDE was
# nil inside the test even though the build setting was present.
ONLY_TESTING=()
[[ -n "$TEST_FILTER" ]] && ONLY_TESTING=(-only-testing:"$TEST_FILTER")
TEST_RUNNER_LELEPDF_REAL_CLAUDE=1 TEST_RUNNER_LELEPDF_DATA_DIR="$APPSTORE_STAGING" xcodebuild \
    -scheme LelePdf \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    "${ONLY_TESTING[@]}" \
    test > "$LOG" 2>&1
STATUS=$?
set -e

echo "test-real: --- real results recorded ---"
grep -E "^=== |^CHAT |^  \[" "$LOG" || echo "test-real: no real output found in the log"

if [[ $STATUS -ne 0 ]]; then
  echo "test-real: FAILED — details:" >&2
  grep -E "error:|Issue recorded|✘ Test" "$LOG" >&2 || true
  rm -f "$LOG"
  exit 1
fi

mkdir -p "$FIXTURES_REPO"
# zsh, not bash: "(N)" is zsh's nullglob qualifier for this one pattern (the
# array stays empty instead of erroring out when there is nothing).
new_fixtures=("$FIXTURES_CACHE"/*.json(N))
if (( ${#new_fixtures} > 0 )); then
  cp -f "${new_fixtures[@]}" "$FIXTURES_REPO/"
  echo "test-real: fixtures copied to $FIXTURES_REPO ($(ls "$FIXTURES_REPO" | wc -l | tr -d ' ') files)"
else
  echo "test-real: WARNING — no fixture found in $FIXTURES_CACHE" >&2
fi

rm -f "$LOG"
echo "test-real: done. Record the calls made (SPEC §10.2) and update the budget counter."
exit 0
