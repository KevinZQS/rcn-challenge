#!/usr/bin/env python3
"""
reach.py -- read, change and verify every router programmatically. No CLI.

Uses Arista's eAPI (JSON-RPC over HTTPS, served inside the MGMT VRF), which
every device in this topology enables via:

    management api http-commands
       protocol https
       vrf MGMT
          no shutdown

Device addresses are discovered from Docker, so nothing is hardcoded.

READ
    ./reach.py                          reachability check on all routers
    ./reach.py --quiet                  exit code only (used by the checklists)
    ./reach.py --health                 adjacencies, routes, CPU
    ./reach.py --cmd "show ip route"    run any show command everywhere
    ./reach.py --cmd "show version" R1 R5      ...on just these
    ./reach.py --pull                   save each running-config to running/

CHANGE  (this is the fast path -- seconds, versus ~4 minutes for a redeploy)
    ./reach.py --apply "interface Ethernet3" "description LINK_TO_X" R1
    ./reach.py --apply-file change.txt R1 R2
    ./reach.py --apply ... --save R1    also write memory
    ./reach.py --apply ... --yes R1     skip the confirmation prompt

VERIFY
    ./reach.py --drift                  is every line of my intent still live?

Needs: requests  (pip install requests)
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

try:
    import requests
    from requests.auth import HTTPBasicAuth
except ImportError:
    sys.exit("!! needs the requests library:  pip3 install requests")

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

LAB = "clab-rcn-challenge"
ROUTERS = ["R1", "R2", "R3", "R4", "R5", "S1", "S2", "S3", "S4"]
USER, PASS = "admin", "admin"
TIMEOUT = 15

ROOT = Path(__file__).resolve().parent.parent
NSOT_CONFIGS = ROOT / "nsot" / "configs"
RUNNING_DIR = ROOT / "running"

G, R, Y, C, D, B, N = ("\033[1;32m", "\033[1;31m", "\033[1;33m",
                       "\033[1;36m", "\033[2m", "\033[1m", "\033[0m")


# ------------------------------------------------------------------ plumbing
def device_ip(name):
    """Find a device's management address without hardcoding anything."""
    try:
        out = subprocess.run(
            ["docker", "inspect", f"{LAB}-{name}",
             "--format", "{{.NetworkSettings.Networks.clab.IPAddress}}"],
            capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip() or None
    except Exception:
        return None


def eapi(ip, cmds, fmt="json"):
    """One eAPI call. Returns (result_list, error_string)."""
    body = {
        "jsonrpc": "2.0",
        "method": "runCmds",
        "params": {"version": 1, "cmds": cmds, "format": fmt},
        "id": "reach.py",
    }
    try:
        r = requests.post(
            f"https://{ip}/command-api",
            data=json.dumps(body),
            auth=HTTPBasicAuth(USER, PASS),
            headers={"Content-Type": "application/json"},
            verify=False, timeout=TIMEOUT,
        )
    except requests.exceptions.RequestException as e:
        return None, type(e).__name__
    if r.status_code != 200:
        return None, f"HTTP {r.status_code}"
    payload = r.json()
    if "error" in payload:
        msg = payload["error"].get("message", "eAPI error")
        data = payload["error"].get("data")
        if isinstance(data, list) and data and isinstance(data[-1], dict):
            msg = data[-1].get("errors", [msg])[0] if data[-1].get("errors") else msg
        return None, str(msg)[:90]
    return payload["result"], None


def targets(names):
    out = []
    for n in names:
        ip = device_ip(n)
        if not ip:
            print(f"  {R}FAIL{N}  {n:<4} no container address -- is the lab up?")
        out.append((n, ip))
    return out


def intent_lines(dev):
    """The meaningful lines of a device's rendered config."""
    p = NSOT_CONFIGS / f"{dev}.cfg"
    if not p.exists():
        return None
    out = []
    for raw in p.read_text().splitlines():
        line = raw.rstrip()
        if not line or line.strip() == "!":
            continue
        out.append(line)
    return out


# ------------------------------------------------------------------ read
def mode_reach(names, quiet):
    if not quiet:
        print(f"\n{C}eAPI reachability -- {len(names)} routers, no CLI{N}\n")
    failures = 0
    for name, ip in targets(names):
        if not ip:
            failures += 1
            continue
        res, err = eapi(ip, ["show version"])
        if err:
            failures += 1
            if not quiet:
                print(f"  {R}FAIL{N}  {name:<4} {ip:<15} {err}")
            continue
        v = res[0]
        if not quiet:
            print(f"  {G}OK{N}    {name:<4} {ip:<15} "
                  f"EOS {v.get('version','?'):<10} "
                  f"{D}uptime {int(v.get('uptime',0))//60} min{N}")
    if not quiet:
        print()
        print(f"  {R}{failures} router(s) unreachable{N}\n" if failures
              else f"  {G}All {len(names)} routers answered over eAPI.{N}\n")
    return 1 if failures else 0


def _probe(ip, candidates, *needles):
    """Count matching lines. None = feature not configured on this device.

    eAPI fails a WHOLE batch if any command errors, so each command gets its
    own call -- a router without BGP must not blank out its OSPF counts.
    """
    for cmd in candidates:
        res, err = eapi(ip, [cmd], fmt="text")
        if err:
            continue
        low = [w.lower() for w in needles]
        return sum(1 for l in res[0].get("output", "").splitlines()
                   if any(w in l.lower() for w in low))
    return None


def _total(ip, cmd):
    res, err = eapi(ip, [cmd], fmt="text")
    if err:
        return None
    for line in res[0].get("output", "").splitlines():
        if "Total" in line:
            parts = line.split()
            if parts and parts[-1].isdigit():
                return int(parts[-1])
    return None


def _cpu(ip):
    res, err = eapi(ip, ["show processes top once"], fmt="text")
    if err:
        return None
    for line in res[0].get("output", "").splitlines():
        if "Cpu(s)" in line or "%Cpu" in line:
            for part in line.replace(",", " ").split():
                try:
                    return float(part)
                except ValueError:
                    continue
    return None


def mode_health(names):
    print(f"\n{C}Health check -- adjacencies, routes, CPU{N}")
    print(f"{D}  '-' means that protocol is not configured on the device.{N}")
    print(f"{D}  CPU% is user time from 'show processes top once'.{N}\n")
    hdr = (f"  {'':4} {'BGPv4':>6} {'BGPv6':>6} {'OSPFv2':>7} {'OSPFv3':>7} "
           f"{'IS-IS':>6} {'v4 rts':>7} {'v6 rts':>7} {'CPU%':>6}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    cell = lambda v: "-" if v is None else str(v)
    failures = 0
    for name, ip in targets(names):
        if not ip:
            failures += 1
            continue
        _, err = eapi(ip, ["show hostname"], fmt="text")
        if err:
            print(f"  {R}{name:<4}{N} unreachable over eAPI: {err}")
            failures += 1
            continue
        bgp4 = _probe(ip, ["show ip bgp summary"], "Estab")
        bgp6 = _probe(ip, ["show ipv6 bgp summary"], "Estab")
        osp2 = _probe(ip, ["show ip ospf neighbor"], "FULL")
        osp3 = _probe(ip, ["show ipv6 ospf neighbor", "show ospfv3 neighbor"], "FULL")
        isis = _probe(ip, ["show isis neighbors"], "UP")
        v4, v6, cpu = (_total(ip, "show ip route summary"),
                       _total(ip, "show ipv6 route summary"), _cpu(ip))
        print(f"  {name:<4} {cell(bgp4):>6} {cell(bgp6):>6} {cell(osp2):>7} "
              f"{cell(osp3):>7} {cell(isis):>6} {cell(v4):>7} {cell(v6):>7} "
              f"{('-' if cpu is None else f'{cpu:.1f}'):>6}")
    print()
    return 1 if failures else 0


def mode_cmd(names, command, as_text):
    fmt = "text" if as_text else "json"
    print(f"\n{C}Running on {len(names)} routers:{N} {command}\n")
    failures = 0
    for name, ip in targets(names):
        if not ip:
            failures += 1
            continue
        res, err = eapi(ip, [command], fmt=fmt)
        print(f"{C}--- {name} ({ip}) {'-' * max(4, 50 - len(name))}{N}")
        if err:
            print(f"  {R}{err}{N}\n")
            failures += 1
            continue
        print(res[0].get("output", "").rstrip() or "  (no output)" if as_text
              else json.dumps(res[0], indent=2))
        print()
    return 1 if failures else 0


def mode_pull(names):
    RUNNING_DIR.mkdir(exist_ok=True)
    print(f"\n{C}Pulling running-config from {len(names)} routers{N}\n")
    failures = 0
    for name, ip in targets(names):
        if not ip:
            failures += 1
            continue
        res, err = eapi(ip, ["enable", "show running-config"], fmt="text")
        if err:
            print(f"  {R}FAIL{N}  {name:<4} {err}")
            failures += 1
            continue
        text = res[-1].get("output", "")
        dest = RUNNING_DIR / f"{name}.cfg"
        dest.write_text(text)
        print(f"  {G}OK{N}    {name:<4} -> running/{name}.cfg "
              f"({len(text.splitlines())} lines)")
    print()
    return 1 if failures else 0


# ------------------------------------------------------------------ verify
def mode_drift(names):
    """Is every line of my intent still present on the device?

    This asks 'did my configuration survive', NOT 'is anything extra there'.
    A running-config contains hundreds of platform defaults the NSOT never
    sets, so a full two-way diff would be unreadable. Missing intent is the
    failure mode that matters during a challenge.
    """
    print(f"\n{C}Drift check -- every line of the NSOT config, live on the device{N}")
    print(f"{D}  Reports intent that is MISSING. Extra platform defaults are ignored.{N}\n")
    bad = 0
    for name, ip in targets(names):
        if not ip:
            bad += 1
            continue
        want = intent_lines(name)
        if want is None:
            print(f"  {Y}SKIP{N}  {name:<4} no nsot/configs/{name}.cfg -- run render.py")
            continue
        res, err = eapi(ip, ["enable", "show running-config"], fmt="text")
        if err:
            print(f"  {R}FAIL{N}  {name:<4} {err}")
            bad += 1
            continue
        live = {l.rstrip() for l in res[-1].get("output", "").splitlines()}
        missing = [l for l in want if l not in live]
        if not missing:
            print(f"  {G}OK{N}    {name:<4} all {len(want)} intent lines present")
        else:
            print(f"  {R}DRIFT{N} {name:<4} {len(missing)} of {len(want)} intent "
                  f"lines MISSING from the device:")
            for l in missing[:12]:
                print(f"           {R}-{N} {l}")
            if len(missing) > 12:
                print(f"           {D}... and {len(missing)-12} more{N}")
            bad += 1
    print()
    print(f"  {R}{bad} device(s) drifted from the source of truth{N}\n" if bad
          else f"  {G}Every device matches the source of truth.{N}\n")
    return 1 if bad else 0


# ------------------------------------------------------------------ change
def mode_apply(names, lines, save, assume_yes):
    """Push configuration lines. The fast path for a config-only change."""
    print(f"\n{B}About to configure {len(names)} device(s):{N} {', '.join(names)}\n")
    for l in lines:
        print(f"    {l}")
    if save:
        print(f"\n  {D}...then 'write memory' on each.{N}")

    if not assume_yes:
        print()
        try:
            a = input(f"  Send this? [y/N] ")
        except (EOFError, KeyboardInterrupt):
            print("\n  aborted\n")
            return 1
        if a.strip().lower() not in ("y", "yes"):
            print("  aborted -- nothing sent\n")
            return 1

    print()
    failures = 0
    for name, ip in targets(names):
        if not ip:
            failures += 1
            continue
        cmds = ["enable", "configure"] + list(lines) + ["end"]
        if save:
            cmds.append("write memory")
        _, err = eapi(ip, cmds, fmt="json")
        if err:
            print(f"  {R}FAIL{N}  {name:<4} {err}")
            failures += 1
        else:
            print(f"  {G}OK{N}    {name:<4} {len(lines)} line(s) applied"
                  f"{' and saved' if save else ''}")
    print()
    if failures:
        print(f"  {R}{failures} device(s) rejected the change.{N}")
        print(f"  {D}Nothing is rolled back automatically -- check with --drift.{N}\n")
    else:
        print(f"  {G}Applied to all {len(names)} device(s).{N}")
        print(f"  {D}Verify with:  ./reach.py --health   or   ./reach.py --drift{N}\n")
    return 1 if failures else 0


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("devices", nargs="*")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--health", action="store_true")
    ap.add_argument("--pull", action="store_true")
    ap.add_argument("--drift", action="store_true")
    ap.add_argument("--cmd")
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--apply", nargs="+", metavar="LINE")
    ap.add_argument("--apply-file", metavar="FILE")
    ap.add_argument("--save", action="store_true", help="write memory after --apply")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation")
    a = ap.parse_args()

    names = a.devices or ROUTERS
    unknown = [n for n in names if n not in ROUTERS]
    if unknown:
        sys.exit(f"!! unknown device(s): {', '.join(unknown)}\n"
                 f"   known: {', '.join(ROUTERS)}")

    if a.apply_file:
        p = Path(a.apply_file)
        if not p.exists():
            sys.exit(f"!! {p} not found")
        lines = [l.rstrip() for l in p.read_text().splitlines()
                 if l.strip() and not l.strip().startswith("#")]
        return mode_apply(names, lines, a.save, a.yes)
    if a.apply:
        return mode_apply(names, a.apply, a.save, a.yes)
    if a.drift:
        return mode_drift(names)
    if a.pull:
        return mode_pull(names)
    if a.cmd:
        return mode_cmd(names, a.cmd, a.text)
    if a.health:
        return mode_health(names)
    return mode_reach(names, a.quiet)


if __name__ == "__main__":
    sys.exit(main())
