#!/usr/bin/env python3
"""
golden.py -- Golden configuration snapshots.

Copies the current rendered configs into golden/<timestamp>/ so every
known-good state is retained and diffable. Also writes/updates
golden/latest as a pointer to the newest snapshot.

Usage:
    python3 scripts/golden.py               # snapshot current configs
    python3 scripts/golden.py --list        # list snapshots
    python3 scripts/golden.py --diff R1     # diff R1 against newest snapshot
"""
import sys
import shutil
import difflib
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIGS = ROOT / "configs"
GOLDEN = ROOT / "golden"


def snapshots():
    if not GOLDEN.exists():
        return []
    return sorted(d for d in GOLDEN.iterdir() if d.is_dir())


def save():
    if not CONFIGS.exists() or not any(CONFIGS.glob("*.cfg")):
        print("!! no configs to snapshot -- run render.py first")
        sys.exit(1)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = GOLDEN / stamp
    dest.mkdir(parents=True)
    count = 0
    for cfg in sorted(CONFIGS.glob("*.cfg")):
        shutil.copy2(cfg, dest / cfg.name)
        count += 1
    (GOLDEN / "latest").write_text(stamp + "\n")
    print(f"[golden] saved {count} config(s) to golden/{stamp}")


def list_snapshots():
    snaps = snapshots()
    if not snaps:
        print("[golden] no snapshots yet")
        return
    for s in snaps:
        n = len(list(s.glob("*.cfg")))
        print(f"  {s.name}  ({n} configs)")


def diff(hostname):
    snaps = snapshots()
    if not snaps:
        print("!! no snapshots to compare against")
        sys.exit(1)
    newest = snaps[-1]
    old = newest / f"{hostname}.cfg"
    new = CONFIGS / f"{hostname}.cfg"
    if not old.exists() or not new.exists():
        print(f"!! {hostname}.cfg missing in one side")
        sys.exit(1)
    delta = list(difflib.unified_diff(
        old.read_text().splitlines(),
        new.read_text().splitlines(),
        fromfile=f"golden/{newest.name}/{hostname}.cfg",
        tofile=f"configs/{hostname}.cfg",
        lineterm="",
    ))
    if not delta:
        print(f"[golden] {hostname} matches golden snapshot {newest.name}")
    else:
        print("\n".join(delta))


if __name__ == "__main__":
    if "--list" in sys.argv:
        list_snapshots()
    elif "--diff" in sys.argv:
        i = sys.argv.index("--diff")
        diff(sys.argv[i + 1])
    else:
        save()
