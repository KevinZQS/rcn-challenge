#!/usr/bin/env python3
"""
deploy.py -- one command for a complete fresh start.

  1. Forces the topology "name:" field to rcn-challenge.
  2. Destroys any existing deployment (including old rcn-lab1 / rcn-lab2
     leftovers) and removes orphaned containers.
  3. Deploys.
  4. Waits for the nodes to settle.
  5. Regenerates the Telegraf and Grafana configs with the current
     container IPs, then restarts those two containers.

Every router is Arista cEOS and boots with its config already applied, so
there is no post-boot configuration step.

Usage:
    python3 deploy.py              # full fresh start
    python3 deploy.py --no-monitor # skip the Telegraf/Grafana refresh
"""

import re
import subprocess
import sys
import time
from pathlib import Path

YAML_FILE = "rcn.clab.yaml"
LAB_NAME = "rcn-challenge"
STALE_NAMES = ["rcn-lab1", "rcn-lab2", "rcn-challenge"]
PREFIX = f"clab-{LAB_NAME}-"
SETTLE_SECONDS = 60


def run(cmd, check=True, capture=False):
    print(f"\n$ {cmd}")
    if capture:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return r.stdout, r.returncode
    r = subprocess.run(cmd, shell=True)
    if check and r.returncode != 0:
        print(f"\n!! command failed ({r.returncode}): {cmd}")
        sys.exit(r.returncode)
    return "", r.returncode


def force_correct_name(path: Path) -> None:
    text = path.read_text()
    pattern = re.compile(r"^name:\s*\S+", re.MULTILINE)
    m = pattern.search(text)
    if not m:
        print("!! no top-level 'name:' line found -- check the file by hand")
        sys.exit(1)
    current, correct = m.group(0).strip(), f"name: {LAB_NAME}"
    if current == correct:
        print(f"[ok] name is correct: '{current}'")
        return
    print(f"[fix] name was '{current}' -> rewriting to '{correct}'")
    path.write_text(pattern.sub(correct, text, count=1))


def cleanup_orphans() -> None:
    for name in STALE_NAMES:
        out, _ = run(
            f"docker ps -a --format '{{{{.Names}}}}' | grep -E '^clab-{name}-' || true",
            check=False, capture=True,
        )
        names = out.split()
        if names:
            print(f"[cleanup] removing {len(names)} leftover container(s) from '{name}'")
            run(f"docker rm -f {' '.join(names)}", check=False)
        else:
            print(f"[ok] nothing left over from '{name}'")


def refresh_monitoring() -> None:
    gen = Path("generate_configs.sh")
    if not gen.exists():
        print("[skip] generate_configs.sh not found")
        return
    run("bash generate_configs.sh", check=False)
    run(f"docker restart {PREFIX}Telegraf {PREFIX}Grafana", check=False)


def ensure_bind_paths() -> None:
    """Create any bind source that does not exist yet.

    containerlab refuses to deploy if a bind source is missing, but some of
    ours are GENERATED after the lab is up (configs/telegraf.conf and the two
    grafana provisioning directories are written by generate_configs.sh, which
    needs the container IPs that only exist post-deploy). On a fresh clone that
    is a deadlock, so we place empty stand-ins first; the real contents are
    written in step 6 and the containers restarted to pick them up.
    """
    import yaml
    topo = yaml.safe_load(Path(YAML_FILE).read_text())
    made = 0
    for node, cfg in (topo["topology"]["nodes"] or {}).items():
        for bind in (cfg.get("binds") or []):
            src = Path(bind.split(":")[0])
            if src.exists():
                continue
            if src.suffix:                      # looks like a file
                src.parent.mkdir(parents=True, exist_ok=True)
                if src.name.endswith(".conf"):
                    src.write_text('[agent]\n  interval = "10s"\n')
                else:
                    src.touch()
                print(f"[bind] created placeholder file  {src}  (for {node})")
            else:                               # a directory
                src.mkdir(parents=True, exist_ok=True)
                print(f"[bind] created directory        {src}  (for {node})")
            made += 1
    print("[bind] all bind paths present" if not made
          else f"[bind] created {made} missing bind path(s)")


def main():
    path = Path(YAML_FILE)
    if not path.exists():
        print(f"!! {YAML_FILE} not found in {Path.cwd()}")
        print("   cd into the lab directory first.")
        sys.exit(1)

    print("=== 1. Force-correct the topology name ===")
    force_correct_name(path)

    print("\n=== 1b. Ensure every bind path exists ===")
    ensure_bind_paths()

    print("\n=== 2. Destroy any existing deployment ===")
    run(f"sudo containerlab destroy -t {YAML_FILE} --cleanup", check=False)
    cleanup_orphans()

    print("\n=== 3. Verify the name before deploying ===")
    out, _ = run(f"grep '^name:' {YAML_FILE}", capture=True)
    print(f"[verify] {out.strip()}")
    if LAB_NAME not in out:
        print("!! name still wrong -- aborting")
        sys.exit(1)

    print("\n=== 4. Deploy ===")
    run(f"sudo containerlab deploy -t {YAML_FILE}")

    print(f"\n=== 5. Settling for {SETTLE_SECONDS}s ===")
    time.sleep(SETTLE_SECONDS)

    if "--no-monitor" in sys.argv:
        print("\n[skip] --no-monitor given")
    else:
        print("\n=== 6. Refresh monitoring configs with current IPs ===")
        refresh_monitoring()

    print("\n=== Containers ===")
    run(f"docker ps --format 'table {{{{.Names}}}}\\t{{{{.Status}}}}' | grep {LAB_NAME}",
        check=False)
    print("\nDone. Give routing 1-2 minutes to converge, then run ./check_ready.sh")


if __name__ == "__main__":
    main()
