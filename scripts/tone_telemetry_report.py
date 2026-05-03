#!/usr/bin/env python3
import json
import math
import os
import sys
from collections import Counter


def default_audit_path():
    return os.path.expanduser("~/Library/Application Support/SPZ/audit.jsonl")


def bucket(mean):
    if mean is None:
        return "missing"
    lo = int(max(0, min(1, mean)) * 10) / 10
    hi = min(1.0, lo + 0.1)
    return f"{lo:.1f}-{hi:.1f}"


def corr(xs, ys):
    if len(xs) < 2:
        return None
    mx = sum(xs) / len(xs)
    my = sum(ys) / len(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    denx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    deny = math.sqrt(sum((y - my) ** 2 for y in ys))
    if denx == 0 or deny == 0:
        return None
    return num / (denx * deny)


def load_events(path):
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else default_audit_path()
    commits = []
    lost = []
    for event in load_events(path):
        tone = event.get("tone")
        if not isinstance(tone, dict):
            continue
        name = event.get("event")
        if name == "pipeline_commit":
            commits.append(event)
        elif name == "tracker_lost_with_tone":
            lost.append(event)

    def summarize(label, events):
        means = [e["tone"].get("mean") for e in events if isinstance(e.get("tone"), dict)]
        means = [m for m in means if isinstance(m, (int, float))]
        darkness = [e["tone"].get("darkness", 0) for e in events if isinstance(e.get("tone"), dict)]
        upscales = [e["tone"].get("upscale", 1) for e in events if isinstance(e.get("tone"), dict)]
        fired = sum(1 for e in events if e.get("tone", {}).get("backlightFired") is True)
        print(f"\n{label}: {len(events)} events")
        print("  mean histogram:")
        hist = Counter(bucket(m) for m in means)
        for key in sorted(hist):
            print(f"    {key}: {hist[key]}")
        if events:
            print(f"  backlight fired: {fired}/{len(events)} ({fired / len(events) * 100:.1f}%)")
        if darkness:
            print(f"  avg darkness: {sum(darkness) / len(darkness):.3f}")
        if upscales:
            print(f"  avg upscale: {sum(upscales) / len(upscales):.2f}")

    summarize("commits", commits)
    summarize("lost", lost)

    xs = []
    ys = []
    for event in commits:
        tone = event.get("tone", {})
        mean = tone.get("mean")
        conf = event.get("displayConf")
        if isinstance(mean, (int, float)) and isinstance(conf, (int, float)):
            xs.append(mean)
            ys.append(conf)
    r = corr(xs, ys)
    print("\ncorrelation:")
    print(f"  commit tone.mean vs displayConf: {r:.3f}" if r is not None else "  insufficient data")


if __name__ == "__main__":
    main()
