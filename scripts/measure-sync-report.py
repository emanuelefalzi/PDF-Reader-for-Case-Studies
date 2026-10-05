#!/usr/bin/env python3
"""Statistics of the linked-scrolling measurement (SPEC §5.8) and update of the measurements log.

Usage: measure-sync-report.py <merck.json|-> <draghi.json|-> <measurements.md>
The two JSON files are `SyncMeasurement` reports (offsetPt/durationMs per
scroll frame, latencyMs per hover). A missing file is treated as "no data"
and reported as such, not as a fatal error.
"""
import json
import pathlib
import statistics
import sys
from datetime import date


def load(path):
    p = pathlib.Path(path)
    if not p.exists():
        return None
    return json.loads(p.read_text())


def stats(values):
    if not values:
        return None
    values = sorted(values)
    n = len(values)
    p95_index = min(n - 1, int(round(0.95 * (n - 1))))
    return {"min": values[0], "median": statistics.median(values), "p95": values[p95_index], "n": n}


def fmt(s, unit, threshold, ok):
    if s is None:
        return "n/a (no samples)"
    verdict = "OK" if ok(s["p95"], threshold) else "OVER THRESHOLD"
    return (
        f"min {s['min']:.2f}{unit} · median {s['median']:.2f}{unit} · "
        f"p95 {s['p95']:.2f}{unit} · n={s['n']} · p95 threshold {threshold}{unit} → {verdict}"
    )


def section(label, report):
    if report is None:
        return f"- **{label}**: no data (the measurement could not write the file, see the output of `scripts/measure-sync.sh`)\n"
    frames = report.get("frames", [])
    hovers = report.get("hovers", [])
    offset_stats = stats([f["offsetPt"] for f in frames])
    duration_stats = stats([f["durationMs"] for f in frames])
    hover_stats = stats([h["latencyMs"] for h in hovers])
    lines = [f"- **{label}** ({len(frames)} scroll samples, {len(hovers)} hover samples):"]
    lines.append(f"  - offset between the two sides: {fmt(offset_stats, ' pt', 40, lambda v, t: v <= t)}")
    lines.append(f"  - frame duration: {fmt(duration_stats, ' ms', 16.7, lambda v, t: v <= t)}")
    lines.append(f"  - hover→highlight latency: {fmt(hover_stats, ' ms', 50, lambda v, t: v < t)}")
    return "\n".join(lines) + "\n"


def main():
    merck_path, draghi_path, measurements_path = sys.argv[1], sys.argv[2], sys.argv[3]
    merck = load(merck_path)
    draghi = load(draghi_path)

    block = [f"\n## M6 · linked scrolling ({date.today().isoformat()})\n\n"]
    block.append(
        "SPEC §5.8 criteria: offset between the two sides p95 ≤ 40 pt; 60 fps ⇒ frame "
        "duration p95 ≤ 16.7 ms; hover→highlight latency p95 < 50 ms. Automatic "
        "run (`scripts/measure-sync.sh`, a fallback to an XCUITest target), "
        "verification data folder with the real analyses (0 calls to Claude "
        "for this measurement).\n\n"
    )
    block.append(section("Merck", merck))
    block.append(section("Draghi", draghi))
    text = "".join(block)

    measurements = pathlib.Path(measurements_path)
    measurements.parent.mkdir(parents=True, exist_ok=True)
    existing = measurements.read_text() if measurements.exists() else "# Measurements · LelePdf\n"
    measurements.write_text(existing.rstrip("\n") + "\n" + text)
    print(text)


if __name__ == "__main__":
    main()
