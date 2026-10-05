#!/usr/bin/env python3
"""
reach.py -- talk to every router programmatically over eAPI. No CLI.

Uses Arista's eAPI (JSON-RPC over HTTPS, served inside the MGMT VRF),
which every device in this topology enables via:

    management api http-commands
       protocol https
       vrf MGMT
          no shutdown

Device addresses are discovered from Docker, so nothing is hardcoded.

Usage
-----
    ./reach.py                            reachability check on all routers
    ./reach.py --quiet                    exit code only (used by check_ready.sh)
    ./reach.py --health                   BGP / OSPF / IS-IS neighbours + CPU
    ./reach.py --cmd "show ip route"      run any command on every router
    ./reach.py --cmd "show version" R1 R5 ...on just these routers
    ./reach.py --text                     ask for text output instead of JSON

Needs: requests  (pip install requests)
"""

import argparse
import json
import subprocess
import sys

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
TIMEOUT = 10

G, R, Y, C, D, N = ("\033[1;32m", "\033[1;31m", "\033[1;33m",
                    "\033[1;36m", "\033[2m", "\033[0m")


def device_ip(name):
    """Find a device's management address without hardcoding anything."""
    try:
        out = subprocess.run(
            ["docker", "inspect", f"{LAB}-{name}",
             "--format", "{{.NetworkSettings.Networks.clab.IPAddress}}"],
            capture_output=True, text=True, timeout=10,
        )
        ip = out.stdout.strip()
        return ip or None
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
        return None, f"{type(e).__name__}"
    if r.status_code != 200:
        return None, f"HTTP {r.status_code}"
    payload = r.json()
    if "error" in payload:
        return None, payload["error"].get("message", "eAPI error")[:60]
    return payload["result"], None


def targets(names):
    out = []
    for n in names:
        ip = device_ip(n)
        if not ip:
            print(f"  {R}FAIL{N}  {n:<4} could not find a container address")
            out.append((n, None))
        else:
            out.append((n, ip))
    return out


# ------------------------------------------------------------------ modes
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
        if failures:
            print(f"  {R}{failures} router(s) unreachable programmatically{N}\n")
        else:
            print(f"  {G}All {len(names)} routers answered over eAPI.{N}\n")
    return 1 if failures else 0


def _probe(ip, candidates, *needles):
    """Run each candidate command until one succeeds; count matching lines.

    Returns an int, or None when the feature is not configured on this device.
    eAPI fails a WHOLE batch if any single command errors, so every command
    gets its own call -- a router without BGP must not blank out its OSPF
    counts.
    """
    for cmd in candidates:
        res, err = eapi(ip, [cmd], fmt="text")
        if err:
            continue
        out = res[0].get("output", "")
        # Case-insensitive: EOS prints OSPFv2 state as "FULL" but the OSPFv3
        # equivalent as "Full", and IS-IS as "UP". Matching exactly would
        # silently report 0 adjacencies on a perfectly healthy device.
        low = [w.lower() for w in needles]
        return sum(1 for l in out.splitlines()
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

    def cell(v):
        return "-" if v is None else str(v)

    failures = 0
    for name, ip in targets(names):
        if not ip:
            failures += 1
            continue
        res, err = eapi(ip, ["show hostname"], fmt="text")
        if err:
            print(f"  {R}{name:<4}{N} unreachable over eAPI: {err}")
            failures += 1
            continue

        bgp4 = _probe(ip, ["show ip bgp summary"], "Estab")
        bgp6 = _probe(ip, ["show ipv6 bgp summary"], "Estab")
        osp2 = _probe(ip, ["show ip ospf neighbor"], "FULL")
        osp3 = _probe(ip, ["show ipv6 ospf neighbor",
                           "show ospfv3 neighbor"], "FULL")
        isis = _probe(ip, ["show isis neighbors"], "UP")
        v4   = _total(ip, "show ip route summary")
        v6   = _total(ip, "show ipv6 route summary")
        cpu  = _cpu(ip)

        print(f"  {name:<4} {cell(bgp4):>6} {cell(bgp6):>6} {cell(osp2):>7} "
              f"{cell(osp3):>7} {cell(isis):>6} {cell(v4):>7} {cell(v6):>7} "
              f"{('-' if cpu is None else f'{cpu:.1f}'):>6}")
    print()
    if failures:
        print(f"  {R}{failures} device(s) unreachable{N}\n")
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
        print(f"{C}--- {name} ({ip}) {'-'*(50-len(name))}{N}")
        if err:
            print(f"  {R}{err}{N}\n")
            failures += 1
            continue
        if as_text:
            print(res[0].get("output", "").rstrip() or "  (no output)")
        else:
            print(json.dumps(res[0], indent=2))
        print()
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("devices", nargs="*", default=None)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--health", action="store_true")
    ap.add_argument("--cmd")
    ap.add_argument("--text", action="store_true")
    a = ap.parse_args()

    names = a.devices or ROUTERS
    bad = [n for n in names if n not in ROUTERS]
    if bad:
        sys.exit(f"!! unknown device(s): {', '.join(bad)}\n   known: {', '.join(ROUTERS)}")

    if a.cmd:
        return mode_cmd(names, a.cmd, a.text)
    if a.health:
        return mode_health(names)
    return mode_reach(names, a.quiet)


if __name__ == "__main__":
    sys.exit(main())
