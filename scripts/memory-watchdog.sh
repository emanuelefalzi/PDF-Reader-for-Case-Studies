#!/bin/zsh
# Kills the test/benchmark LelePdf processes (never the app installed in
# /Applications) that exceed the memory limit. On an 8 GB Mac a runaway
# process fills the swap and then the disk (2026-09-21: 31 GB and then 38 GB,
# Mac frozen).
# It measures the footprint (the MEM column of `top`), not the RSS: when macOS
# compresses memory or pages it out to disk, the RSS stays small (16 MB with
# 38 GB of footprint), which is why the first version of this guard did not
# see the process.
LIMIT_MB=${LIMIT_MB:-2500}
LOG=${LOG:-$HOME/Library/Caches/LelePdf/memory-watchdog.log}
mkdir -p "$(dirname "$LOG")"
while true; do
  for pid in $(pgrep -f "DerivedData/.*/LelePdf.app/Contents/MacOS/LelePdf"); do
    mem=$(top -l 1 -pid "$pid" -stats mem 2>/dev/null | tail -1 | tr -d ' +-')
    num=${mem%[KMGB]*}; unit=${mem##*[0-9.]}
    case "$unit" in
      G*) mb=$(( ${num%.*} * 1024 )) ;;
      M*) mb=${num%.*} ;;
      *)  mb=0 ;;
    esac
    if [ "${mb:-0}" -gt "$LIMIT_MB" ]; then
      kill -9 "$pid" 2>/dev/null
      # Stop xcodebuild too: otherwise it relaunches the test process
      # ("Restarting after unexpected exit") and the memory blows up again.
      pkill -9 -f xcodebuild 2>/dev/null
      echo "$(date '+%F %T') killed pid $pid at ${mem} of footprint; stopped xcodebuild" >> "$LOG"
      # Signal for whoever coordinates the runs: while it exists, do not launch anything else.
      touch "$HOME/Library/Caches/LelePdf/STOP-MEMORY"
    fi
  done
  sleep 2
done
